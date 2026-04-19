#!/usr/bin/env python3
"""Teacher-Only baseline data generation (no student interleaving).

Produces the comparison dataset for TESSY experiments: every training row
is authored end-to-end by the teacher model. Any stylistic drift the
student picks up from fine-tuning on this data is the regression TESSY is
supposed to avoid.

Differences from `generate_tessy_data.py`:

* No student model involved.
* Teacher's full ``{slot_updates, confidence, response_draft}`` is kept
  verbatim after JSON extraction + schema validation.
* Same `enable_thinking=False`, same output schema (MLX-LM chat rows), so
  downstream training can swap between TESSY and Teacher-Only datasets
  without any pipeline change.
"""
from __future__ import annotations

import argparse
import json
import os
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
from json_order import rewrite_messages_for_prose_first  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--teacher", required=True)
    parser.add_argument("--prompts", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--max-tokens", type=int, default=1024)
    parser.add_argument("--temperature", type=float, default=0.6)
    parser.add_argument("--top-p", type=float, default=0.95)
    parser.add_argument("--stats", type=Path, default=None)
    parser.add_argument(
        "--prose-first",
        action="store_true",
        help="Rewrite system prompt so JSON emits response_draft first (streaming-friendly)",
    )
    args = parser.parse_args()

    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler

    print(f"Loading teacher {args.teacher} …", flush=True)
    model, tokenizer = load(args.teacher)
    sampler = make_sampler(temp=args.temperature, top_p=args.top_p)

    with args.prompts.open("r", encoding="utf-8") as handle:
        prompts = [json.loads(line) for line in handle if line.strip()]
    if args.start:
        prompts = prompts[args.start :]
    if args.limit:
        prompts = prompts[: args.limit]

    args.output.parent.mkdir(parents=True, exist_ok=True)
    kept = 0
    rejected: dict[str, int] = {}
    total_prompt_t = 0
    total_gen_t = 0
    t_start = time.perf_counter()

    with args.output.open("w", encoding="utf-8") as out:
        for i, prompt_row in enumerate(prompts):
            messages = prompt_row["messages"]
            if args.prose_first:
                messages = rewrite_messages_for_prose_first(messages)
            formatted = format_prompt(tokenizer, messages, thinking=False)
            chunks: list[str] = []
            final = None
            for response in stream_generate(
                model, tokenizer, formatted,
                max_tokens=args.max_tokens, sampler=sampler,
            ):
                chunks.append(response.text)
                final = response
            if final is not None:
                total_prompt_t += final.prompt_tokens
                total_gen_t += final.generation_tokens

            raw = "".join(chunks)
            post_think = strip_think_blocks(raw)
            parsed, err = extract_last_json_object(post_think)
            if parsed is None:
                rejected[f"extract: {err}"] = rejected.get(f"extract: {err}", 0) + 1
                print(f"  [{i+1}/{len(prompts)}] skip — extract: {err}")
                continue
            ok, schema_err = validate_schema(parsed)
            if not ok:
                rejected[f"schema: {schema_err}"] = rejected.get(f"schema: {schema_err}", 0) + 1
                print(f"  [{i+1}/{len(prompts)}] skip — schema: {schema_err}")
                continue

            if args.prose_first:
                # Re-serialise with the prose-first key order so the
                # training row matches what the model was asked to emit.
                parsed = {
                    "response_draft": parsed["response_draft"],
                    "slot_updates": parsed["slot_updates"],
                    "confidence": parsed["confidence"],
                }
            row = {
                "prompt_id": prompt_row.get("prompt_id"),
                "messages": messages + [
                    {"role": "assistant", "content": json.dumps(parsed, ensure_ascii=False)}
                ],
            }
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
            out.flush()
            kept += 1

            if (i + 1) % 10 == 0 or (i + 1) == len(prompts):
                elapsed = time.perf_counter() - t_start
                rate = (i + 1) / elapsed if elapsed else 0
                print(f"  [{i+1}/{len(prompts)}] kept={kept} rejected={sum(rejected.values())} ({rate:.2f} rows/s)")

    total_wall = time.perf_counter() - t_start
    summary = {
        "teacher": args.teacher,
        "method": "teacher-only",
        "prompts_in": len(prompts),
        "rows_written": kept,
        "rejected": rejected,
        "total_wall_s": round(total_wall, 2),
        "teacher_prompt_tokens": total_prompt_t,
        "teacher_gen_tokens": total_gen_t,
    }
    print("\n=== Teacher-Only synthesis summary ===")
    for k, v in summary.items():
        print(f"  {k}: {v}")

    if args.stats:
        args.stats.parent.mkdir(parents=True, exist_ok=True)
        with args.stats.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(summary, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
