#!/usr/bin/env python3
"""Run a model (optionally with a LoRA adapter) against the slot-rewrite
test split and report slot-F1, JSON validity, and latency.

Intended to be called once per model × method variant::

    python scripts/tessy/evaluate.py --model mlx-community/Qwen3.5-4B-MLX-4bit \
        --adapter adapters/qwen35-4b-tessy-phone \
        --test data/mlx_data_slot_rewrite/test.jsonl \
        --label "qwen35-4b-tessy" \
        --report data/tessy/eval_report.jsonl

Compiles:

- ``json_valid_count/total`` — after strip <think> + scan for last
  balanced JSON + schema-validate (same contract as Sprint 0).
- ``slot_f1`` — uses ``normalize_slots.py`` to collapse sentinels, fold
  casing, resolve relative dates against the row's ``current_day`` context,
  and allow address prefix match / urgency aliases / ±0.15 confidence.
- ``latency`` — p50 / p95 over all test rows on this Mac.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
import time
from pathlib import Path

os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

_this_dir = Path(__file__).resolve().parent
if str(_this_dir) not in sys.path:
    sys.path.insert(0, str(_this_dir))

from smoke_teacher_only import (  # noqa: E402
    extract_last_json_object,
    format_prompt,
    strip_think_blocks,
    validate_schema,
)
from normalize_slots import aggregate_f1, f1_for_row  # noqa: E402


_CONTEXT_DAY_RE = re.compile(r"current_day:\s*([A-Za-z]+)")


def extract_context(system_content: str) -> dict:
    """Pull the bits of the system prompt that the slot normalizer needs
    (currently just ``current_day`` for relative-date resolution)."""
    ctx: dict = {}
    m = _CONTEXT_DAY_RE.search(system_content)
    if m:
        ctx["current_day"] = m.group(1).strip()
    return ctx


def evaluate(model_repo: str, adapter_path: Path | None, test_path: Path,
             max_tokens: int, temperature: float, top_p: float,
             limit: int = 0) -> dict:
    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler

    print(f"Loading {model_repo}" + (f" + adapter {adapter_path}" if adapter_path else ""))
    if adapter_path:
        model, tokenizer = load(model_repo, adapter_path=str(adapter_path))
    else:
        model, tokenizer = load(model_repo)
    sampler = make_sampler(temp=temperature, top_p=top_p)

    rows: list[dict] = []
    with test_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    if limit > 0:
        rows = rows[:limit]

    latencies: list[float] = []
    f1_triples: list[tuple[int, int, int]] = []
    json_valid = 0
    gen_tps_vals: list[float] = []
    prompt_tps_vals: list[float] = []
    peak_mem = 0.0
    extraction_failures: dict[str, int] = {}

    for i, row in enumerate(rows):
        messages = row["messages"]
        prompt_msgs = [m for m in messages if m.get("role") in ("system", "user")]
        ref_asst = next((m for m in messages if m.get("role") == "assistant"), None)
        if ref_asst is None:
            continue
        try:
            ref_obj = json.loads(ref_asst["content"])
        except json.JSONDecodeError:
            continue
        ref_slots = ref_obj.get("slot_updates", {}) or {}
        ctx = extract_context(next(m for m in prompt_msgs if m["role"] == "system")["content"])

        formatted = format_prompt(tokenizer, prompt_msgs, thinking=False)
        t0 = time.perf_counter()
        chunks: list[str] = []
        final = None
        for response in stream_generate(
            model, tokenizer, formatted,
            max_tokens=max_tokens, sampler=sampler,
        ):
            chunks.append(response.text)
            final = response
        wall = time.perf_counter() - t0
        latencies.append(wall)
        if final is not None:
            gen_tps_vals.append(final.generation_tps)
            prompt_tps_vals.append(final.prompt_tps)
            peak_mem = max(peak_mem, float(final.peak_memory or 0))

        raw = "".join(chunks)
        parsed, err = extract_last_json_object(strip_think_blocks(raw))
        if parsed is not None:
            ok, schema_err = validate_schema(parsed)
            if not ok:
                extraction_failures[f"schema: {schema_err}"] = (
                    extraction_failures.get(f"schema: {schema_err}", 0) + 1
                )
                parsed = None
        else:
            extraction_failures[f"extract: {err}"] = (
                extraction_failures.get(f"extract: {err}", 0) + 1
            )

        if parsed is None:
            pred_slots = {}
        else:
            pred_slots = parsed.get("slot_updates", {}) or {}
            json_valid += 1

        f1_triples.append(f1_for_row(pred_slots, ref_slots, ctx))

        if (i + 1) % 25 == 0 or (i + 1) == len(rows):
            p50 = statistics.median(latencies) if latencies else 0
            print(
                f"  [{i+1}/{len(rows)}] json_valid={json_valid}/{i+1} "
                f"median_latency={p50:.2f}s"
            )

    totals = aggregate_f1(f1_triples)
    quantile = lambda xs, q: sorted(xs)[max(0, int(len(xs) * q) - 1)] if xs else 0.0
    summary = {
        "model": model_repo,
        "adapter": str(adapter_path) if adapter_path else None,
        "test": str(test_path),
        "n_rows": len(rows),
        "json_valid": json_valid,
        "json_valid_rate": round(json_valid / len(rows), 4) if rows else 0.0,
        "slot_f1": totals,
        "extraction_failures": extraction_failures,
        "latency_p50_s": round(statistics.median(latencies), 3) if latencies else 0.0,
        "latency_p95_s": round(quantile(latencies, 0.95), 3) if latencies else 0.0,
        "avg_gen_tps": round(sum(gen_tps_vals) / len(gen_tps_vals), 2) if gen_tps_vals else 0.0,
        "avg_prompt_tps": round(sum(prompt_tps_vals) / len(prompt_tps_vals), 2) if prompt_tps_vals else 0.0,
        "peak_memory_gb": round(peak_mem, 2),
    }
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model", required=True, help="Base MLX repo id or path")
    parser.add_argument(
        "--adapter",
        type=Path,
        default=None,
        help="Optional LoRA adapter directory (evaluates base model alone if omitted)",
    )
    parser.add_argument(
        "--test",
        type=Path,
        default=Path("data/mlx_data_slot_rewrite/test.jsonl"),
    )
    parser.add_argument(
        "--label",
        type=str,
        default=None,
        help="Human-readable label for the report (defaults to adapter basename or model)",
    )
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--temperature", type=float, default=0.6)
    parser.add_argument("--top-p", type=float, default=0.95)
    parser.add_argument(
        "--report",
        type=Path,
        default=Path("data/tessy/eval_report.jsonl"),
    )
    parser.add_argument("--limit", type=int, default=0, help="0 = all test rows")
    args = parser.parse_args()

    t0 = time.perf_counter()
    summary = evaluate(
        args.model,
        args.adapter,
        args.test,
        args.max_tokens,
        args.temperature,
        args.top_p,
        args.limit,
    )
    summary["label"] = args.label or (args.adapter.name if args.adapter else args.model.split("/")[-1])
    summary["eval_wall_s"] = round(time.perf_counter() - t0, 2)

    print("\n=== EVAL SUMMARY ===")
    for k, v in summary.items():
        print(f"  {k}: {v}")

    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(summary, ensure_ascii=False) + "\n")
    print(f"\nAppended summary to {args.report}")


if __name__ == "__main__":
    main()
