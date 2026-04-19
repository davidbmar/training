#!/usr/bin/env python3
"""Sprint 0 smoke test: run any Qwen3.5 model on N prompts, parse the
`{slot_updates, confidence, response_draft}` JSON tail, and report measured
tokens/sec + peak GPU memory + JSON validity.

This is intentionally simple — it is not part of the TESSY alternating loop.
Its only job is to answer:

    * Does this model load on this Mac?
    * Does it emit a response we can parse after thinking-mode output?
    * What throughput and memory cost should Sprint 1+ expect?

JSON extraction follows the plan directive:

    1. Strip every ``<think>…</think>`` block from the raw output.
    2. Scan the remainder for the LAST brace-balanced substring that parses
       as JSON and is a ``dict``. Thinking traces frequently contain JSON-like
       examples; only the final one is considered the real answer.
    3. Validate schema ``{slot_updates: dict, confidence: number,
       response_draft: str}``.

Results are printed as a human-readable summary and also appended to an
optional ``--report`` JSON file for later aggregation into the Sprint 0
feasibility doc.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

# Silence tokenizer fork warning under default macOS multiprocessing setup.
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")


THINK_BLOCK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)
THINK_CLOSE_RE = re.compile(r"</think>", re.IGNORECASE)


def strip_think_blocks(text: str) -> str:
    """Remove every ``<think>…</think>`` span (including nested whitespace).

    Qwen3.5's chat template pre-fills the opening ``<think>`` tag inside the
    prompt, so the generated text often *starts* inside a thinking span with
    no visible opening tag. We handle that case first: if a ``</think>``
    appears and there is no matching opening before it, drop everything up to
    and including that close tag. Then strip any additional full
    ``<think>…</think>`` spans that may appear downstream.
    """
    match = THINK_CLOSE_RE.search(text)
    if match and "<think>" not in text[: match.start()].lower():
        text = text[match.end() :]
    return THINK_BLOCK_RE.sub("", text).strip()


def extract_last_json_object(text: str) -> tuple[dict | None, str]:
    """Return the last brace-balanced JSON object in ``text`` (or ``None``).

    Brace matching is linear-time: we push ``{`` indices onto a stack and
    pair them with the next ``}``. This yields every balanced span. We then
    try each candidate from last to first and return the first one that
    parses as a ``dict``. The second return value is a short human-readable
    reason when extraction fails (useful for the feasibility report).
    """
    stack: list[int] = []
    candidates: list[tuple[int, int]] = []
    in_string = False
    escape = False

    for i, ch in enumerate(text):
        if escape:
            escape = False
            continue
        if ch == "\\" and in_string:
            escape = True
            continue
        if ch == '"':
            in_string = not in_string
            continue
        if in_string:
            continue
        if ch == "{":
            stack.append(i)
        elif ch == "}" and stack:
            start = stack.pop()
            candidates.append((start, i + 1))

    if not candidates:
        return None, "no balanced { … } spans found"

    for start, end in reversed(candidates):
        snippet = text[start:end]
        try:
            obj = json.loads(snippet)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            return obj, ""
    return None, f"{len(candidates)} candidate spans, none parsed as dict"


def validate_schema(obj: dict) -> tuple[bool, str]:
    """Check ``{slot_updates: dict, confidence: number, response_draft: str}``."""
    missing = [key for key in ("slot_updates", "confidence", "response_draft") if key not in obj]
    if missing:
        return False, f"missing keys: {missing}"
    if not isinstance(obj["slot_updates"], dict):
        return False, "slot_updates is not an object"
    if not isinstance(obj["confidence"], (int, float)):
        return False, "confidence is not numeric"
    if not isinstance(obj["response_draft"], str):
        return False, "response_draft is not a string"
    return True, ""


@dataclass
class RowResult:
    prompt_id: str
    prompt_tokens: int
    generation_tokens: int
    prompt_tps: float
    generation_tps: float
    peak_memory_gb: float
    wall_time_s: float
    finish_reason: str
    json_valid: bool
    json_error: str
    raw_output_head: str
    parsed_obj: dict | None = field(default=None)


def format_prompt(tokenizer, messages: list[dict], thinking: bool = True) -> str:
    """Apply the Qwen3.5 chat template, optionally disabling thinking mode.

    ``enable_thinking`` is the Qwen3-family kwarg; we try it first and fall
    back to the plain call if the template does not accept the flag.
    """
    try:
        return tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True,
            enable_thinking=thinking,
        )
    except TypeError:
        return tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True,
        )


def run_single(model, tokenizer, prompt_row: dict, max_tokens: int, sampler, thinking: bool = True) -> RowResult:
    # Imported lazily so that ``--help`` works without mlx installed.
    from mlx_lm import stream_generate

    formatted = format_prompt(tokenizer, prompt_row["messages"], thinking=thinking)
    t0 = time.perf_counter()
    chunks: list[str] = []
    final = None
    for response in stream_generate(
        model,
        tokenizer,
        formatted,
        max_tokens=max_tokens,
        sampler=sampler,
    ):
        chunks.append(response.text)
        final = response
    wall = time.perf_counter() - t0

    raw_output = "".join(chunks)
    post_think = strip_think_blocks(raw_output)
    parsed, extract_err = extract_last_json_object(post_think)
    if parsed is not None:
        ok, schema_err = validate_schema(parsed)
        json_valid, json_error = ok, schema_err
    else:
        json_valid, json_error = False, extract_err

    return RowResult(
        prompt_id=prompt_row.get("prompt_id", "unknown"),
        prompt_tokens=final.prompt_tokens if final else 0,
        generation_tokens=final.generation_tokens if final else 0,
        prompt_tps=final.prompt_tps if final else 0.0,
        generation_tps=final.generation_tps if final else 0.0,
        peak_memory_gb=(final.peak_memory if final else 0.0),
        wall_time_s=wall,
        finish_reason=str(final.finish_reason) if final else "none",
        json_valid=json_valid,
        json_error=json_error,
        raw_output_head=raw_output[:400],
        parsed_obj=parsed,
    )


def load_prompts(path: Path, limit: int) -> list[dict]:
    rows: list[dict] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
            if len(rows) >= limit:
                break
    return rows


def summarize(model_id: str, results: Iterable[RowResult]) -> dict:
    results = list(results)
    valid = sum(1 for r in results if r.json_valid)
    gen_tps = [r.generation_tps for r in results if r.generation_tps]
    prompt_tps = [r.prompt_tps for r in results if r.prompt_tps]
    peak = max((r.peak_memory_gb for r in results), default=0.0)
    return {
        "model": model_id,
        "n_rows": len(results),
        "json_valid_count": valid,
        "json_valid_rate": round(valid / len(results), 3) if results else 0.0,
        "avg_generation_tps": round(sum(gen_tps) / len(gen_tps), 2) if gen_tps else 0.0,
        "avg_prompt_tps": round(sum(prompt_tps) / len(prompt_tps), 2) if prompt_tps else 0.0,
        "peak_memory_gb": round(peak, 2),
        "total_wall_time_s": round(sum(r.wall_time_s for r in results), 2),
        "rows": [
            {
                "prompt_id": r.prompt_id,
                "prompt_tokens": r.prompt_tokens,
                "generation_tokens": r.generation_tokens,
                "prompt_tps": round(r.prompt_tps, 2),
                "generation_tps": round(r.generation_tps, 2),
                "wall_time_s": round(r.wall_time_s, 2),
                "finish_reason": r.finish_reason,
                "json_valid": r.json_valid,
                "json_error": r.json_error,
                "raw_output_head": r.raw_output_head,
            }
            for r in results
        ],
    }


def print_summary(summary: dict) -> None:
    mode = "thinking" if summary.get("thinking", True) else "no-thinking"
    print(f"\n=== {summary['model']} [{mode}] ===")
    print(
        f"rows: {summary['n_rows']}  json_valid: {summary['json_valid_count']}/{summary['n_rows']} "
        f"({summary['json_valid_rate']:.0%})  "
        f"gen_tps: {summary['avg_generation_tps']}  prompt_tps: {summary['avg_prompt_tps']}  "
        f"peak_gpu_mem: {summary['peak_memory_gb']} GB  wall: {summary['total_wall_time_s']}s"
    )
    for row in summary["rows"]:
        flag = "OK" if row["json_valid"] else "FAIL"
        detail = "" if row["json_valid"] else f" -- {row['json_error']}"
        print(
            f"  [{flag}] {row['prompt_id']} | "
            f"prompt={row['prompt_tokens']}t ({row['prompt_tps']} t/s)  "
            f"gen={row['generation_tokens']}t ({row['generation_tps']} t/s)  "
            f"wall={row['wall_time_s']}s  finish={row['finish_reason']}{detail}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--model",
        required=True,
        help="HF repo id or local path, e.g. mlx-community/Qwen3.5-4B-MLX-4bit",
    )
    parser.add_argument(
        "--prompts",
        type=Path,
        default=Path("data/tessy/prompts/train.jsonl"),
        help="Prompt-only JSONL produced by extract_prompts.py",
    )
    parser.add_argument("--limit", type=int, default=5, help="How many prompts to run")
    parser.add_argument("--max-tokens", type=int, default=2048, help="Max generation tokens per row")
    parser.add_argument("--temperature", type=float, default=0.6, help="Paper uses 0.6 for Qwen3 family")
    parser.add_argument("--top-p", type=float, default=0.95)
    parser.add_argument(
        "--report",
        type=Path,
        default=None,
        help="If set, append the measured summary as a JSON line here",
    )
    parser.add_argument(
        "--no-thinking",
        action="store_true",
        help="Disable Qwen3.5 thinking mode (chat template fills <think></think> empty)",
    )
    args = parser.parse_args()
    use_thinking = not args.no_thinking

    # Import MLX lazily so --help works on machines without it.
    from mlx_lm import load
    from mlx_lm.sample_utils import make_sampler

    prompts = load_prompts(args.prompts, args.limit)
    if not prompts:
        print(f"No prompts in {args.prompts}", file=sys.stderr)
        sys.exit(1)

    print(f"Loading {args.model} …", flush=True)
    t_load = time.perf_counter()
    model, tokenizer = load(args.model)
    load_time = time.perf_counter() - t_load
    print(f"  loaded in {load_time:.1f}s")

    sampler = make_sampler(temp=args.temperature, top_p=args.top_p)

    results: list[RowResult] = []
    for row in prompts:
        results.append(run_single(model, tokenizer, row, args.max_tokens, sampler, thinking=use_thinking))

    summary = summarize(args.model, results)
    summary["load_time_s"] = round(load_time, 2)
    summary["thinking"] = use_thinking
    summary["max_tokens"] = args.max_tokens
    print_summary(summary)

    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        with args.report.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(summary, ensure_ascii=False) + "\n")
        print(f"\nAppended summary to {args.report}")


if __name__ == "__main__":
    main()
