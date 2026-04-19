#!/usr/bin/env python3
"""Strip the assistant turn from slot-rewrite JSONL, leaving prompt-only rows.

The existing `data/mlx_data_slot_rewrite/{train,valid,test}.jsonl` files are
turn-level `{"messages": [system, user, assistant]}` rows where the assistant
content is a JSON string. TESSY regenerates the assistant turn, so we produce
prompt-only rows here and preserve the original assistant as `reference` for
downstream evaluation.

Output schema (one JSON object per line):

    {
      "prompt_id": "<source-basename>:<0-indexed-row>",
      "messages": [<system>, <user>],
      "reference": "<original assistant content string>" | null
    }

Round-trip self-test runs on --self-test: reads 5 random input rows, writes to
a tempfile, re-reads, confirms each output parses and carries an identical
system+user payload.
"""
from __future__ import annotations

import argparse
import json
import random
import sys
import tempfile
from pathlib import Path


def extract_row(row: dict, source_name: str, index: int) -> dict | None:
    messages = row.get("messages")
    if not isinstance(messages, list) or len(messages) < 2:
        return None

    prompt_messages: list[dict] = []
    reference: str | None = None
    for msg in messages:
        if not isinstance(msg, dict):
            return None
        role = msg.get("role")
        content = msg.get("content", "")
        if role == "assistant":
            reference = content if isinstance(content, str) else json.dumps(content)
            continue
        if role in ("system", "user"):
            prompt_messages.append({"role": role, "content": content})

    if not prompt_messages or prompt_messages[-1]["role"] != "user":
        return None

    return {
        "prompt_id": f"{source_name}:{index}",
        "messages": prompt_messages,
        "reference": reference,
    }


def extract_file(input_path: Path, output_path: Path) -> tuple[int, int]:
    source_name = input_path.stem
    output_path.parent.mkdir(parents=True, exist_ok=True)
    kept = skipped = 0
    with input_path.open("r", encoding="utf-8") as src, output_path.open("w", encoding="utf-8") as dst:
        for index, line in enumerate(src):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                skipped += 1
                continue
            extracted = extract_row(row, source_name, index)
            if extracted is None:
                skipped += 1
                continue
            dst.write(json.dumps(extracted, ensure_ascii=False) + "\n")
            kept += 1
    return kept, skipped


def run_self_test(input_path: Path, sample_size: int = 5) -> None:
    source_rows: list[dict] = []
    with input_path.open("r", encoding="utf-8") as src:
        for line in src:
            line = line.strip()
            if line:
                source_rows.append(json.loads(line))
    if len(source_rows) < sample_size:
        print(f"self-test: source has only {len(source_rows)} rows; using all of them", file=sys.stderr)
        sample_size = len(source_rows)

    rng = random.Random(0)
    chosen_indices = rng.sample(range(len(source_rows)), sample_size)
    source_name = input_path.stem

    with tempfile.TemporaryDirectory() as tmp:
        tmp_in = Path(tmp) / "in.jsonl"
        tmp_out = Path(tmp) / "out.jsonl"
        with tmp_in.open("w", encoding="utf-8") as handle:
            for idx in chosen_indices:
                handle.write(json.dumps(source_rows[idx], ensure_ascii=False) + "\n")
        kept, skipped = extract_file(tmp_in, tmp_out)
        if kept != sample_size or skipped:
            raise SystemExit(f"self-test failed: kept={kept} skipped={skipped} expected_kept={sample_size}")

        with tmp_out.open("r", encoding="utf-8") as handle:
            out_rows = [json.loads(line) for line in handle if line.strip()]

    for sampled_pos, idx in enumerate(chosen_indices):
        original_prompt = [m for m in source_rows[idx]["messages"] if m.get("role") in ("system", "user")]
        produced = out_rows[sampled_pos]
        if produced["messages"] != original_prompt:
            raise SystemExit(f"self-test failed at row {idx}: prompt mismatch")
    print(f"self-test passed on {sample_size} rows from {input_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--input", type=Path, help="Source slot-rewrite JSONL file")
    parser.add_argument("--output", type=Path, help="Destination prompt-only JSONL file")
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Round-trip a random 5-row sample from --input and exit",
    )
    args = parser.parse_args()

    if args.self_test:
        if not args.input:
            parser.error("--self-test requires --input")
        run_self_test(args.input)
        return

    if not args.input or not args.output:
        parser.error("--input and --output are required (or pass --self-test)")

    kept, skipped = extract_file(args.input, args.output)
    print(f"wrote {kept} rows to {args.output} (skipped {skipped})")


if __name__ == "__main__":
    main()
