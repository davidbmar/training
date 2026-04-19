#!/usr/bin/env python3
"""Domain-adapted TESSY data synthesis for the phone-agent task.

Sprint 0 found that Qwen3.5 thinking mode is incompatible with this domain
(see `docs/project-memory/sessions/S-2026-04-18-0513-tessy-sprint-0.md`), so
TESSY here operates on the **JSON-vs-prose** split rather than the paper's
thinking-vs-answer split:

* **Capability tokens** — `slot_updates` keys and values, `confidence`
  numeric, JSON structural characters. Teacher generates these.
* **Style tokens** — `response_draft` prose. Student generates these, so
  the training data carries the student's natural phrasing style.

Both models run with ``enable_thinking=False``. For each prompt:

1. Teacher emits the full ``{slot_updates, confidence, response_draft}``
   JSON. We parse it and keep only the ``slot_updates`` + ``confidence``
   decision — the teacher's prose is discarded.
2. We build an "assistant prefix" containing the teacher's JSON opening
   plus the string ``"response_draft": "`` and feed it to the student as
   a continuation prompt. The student only writes the prose content of
   ``response_draft``; we stop at the first unescaped ``"``.
3. We stitch the teacher's capability decisions and the student's prose
   back into a single JSON object and write one training row.

Usage::

    python scripts/tessy/generate_tessy_data.py \\
        --teacher mlx-community/Qwen3.5-9B-MLX-4bit \\
        --student mlx-community/Qwen3.5-4B-MLX-4bit \\
        --prompts data/tessy/prompts/train.jsonl \\
        --output  data/tessy/4b/train.jsonl \\
        --limit   20

Each output row follows the existing MLX-LM chat-format training schema so
it can be fed straight to `mlx_lm.lora`::

    {"messages": [<system>, <user>, {"role": "assistant",
                                     "content": "<stitched JSON string>"}]}
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path

os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

# Reuse the Sprint-0 JSON-extraction helpers.
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


TEACHER_MAX_TOKENS = 1024
STUDENT_PROSE_MAX_TOKENS = 256


@dataclass
class GenerationStats:
    teacher_prompt_tokens: int = 0
    teacher_gen_tokens: int = 0
    student_prompt_tokens: int = 0
    student_gen_tokens: int = 0
    teacher_wall_s: float = 0.0
    student_wall_s: float = 0.0

    def add_teacher(self, prompt_t: int, gen_t: int, wall: float) -> None:
        self.teacher_prompt_tokens += prompt_t
        self.teacher_gen_tokens += gen_t
        self.teacher_wall_s += wall

    def add_student(self, prompt_t: int, gen_t: int, wall: float) -> None:
        self.student_prompt_tokens += prompt_t
        self.student_gen_tokens += gen_t
        self.student_wall_s += wall


def find_unescaped_quote(text: str) -> int:
    """Return the index of the first unescaped ``"`` in ``text``, or -1.

    Backslash-escapes are interpreted one level deep — enough for JSON
    string literal termination. This is called on the student's raw
    continuation output, which never re-enters a JSON string after we
    stop it, so we don't need to track more complex state.
    """
    escape = False
    for i, ch in enumerate(text):
        if escape:
            escape = False
            continue
        if ch == "\\":
            escape = True
            continue
        if ch == '"':
            return i
    return -1


def generate_teacher_json(
    teacher_model,
    teacher_tok,
    prompt_messages: list[dict],
    sampler,
    stats: GenerationStats,
):
    """Run the teacher on a prompt, return the parsed+validated JSON dict."""
    from mlx_lm import stream_generate

    formatted = format_prompt(teacher_tok, prompt_messages, thinking=False)
    chunks: list[str] = []
    final = None
    t0 = time.perf_counter()
    for response in stream_generate(
        teacher_model,
        teacher_tok,
        formatted,
        max_tokens=TEACHER_MAX_TOKENS,
        sampler=sampler,
    ):
        chunks.append(response.text)
        final = response
    wall = time.perf_counter() - t0

    if final is not None:
        stats.add_teacher(final.prompt_tokens, final.generation_tokens, wall)

    raw = "".join(chunks)
    post_think = strip_think_blocks(raw)
    parsed, extract_err = extract_last_json_object(post_think)
    if parsed is None:
        return None, f"teacher-json-extract: {extract_err}", raw
    ok, schema_err = validate_schema(parsed)
    if not ok:
        return None, f"teacher-schema: {schema_err}", raw
    return parsed, "", raw


def generate_student_prose(
    student_model,
    student_tok,
    prompt_messages: list[dict],
    teacher_json: dict,
    sampler,
    stats: GenerationStats,
    prose_first: bool = False,
) -> tuple[str | None, str]:
    """Continue from a teacher-authored assistant prefix; return the student's
    ``response_draft`` prose (without the closing ``"``).

    When ``prose_first`` is set, the assistant prefix opens with
    ``{"response_draft": "`` so the student writes the prose FIRST — the
    streaming JSON parser can then forward these tokens to TTS before the
    ``slot_updates`` object is even sampled.
    """
    from mlx_lm import stream_generate

    if prose_first:
        # Prefix is literally `{"response_draft": "` — student writes prose
        # until it closes the string. The rest of the JSON (slot_updates +
        # confidence) is supplied by the teacher after the fact.
        prefix_str = '{"response_draft": "'
    else:
        # Original ordering: slots + confidence, then open response_draft.
        prefix_obj = {
            "slot_updates": teacher_json.get("slot_updates", {}),
            "confidence": teacher_json.get("confidence", 0.9),
        }
        prefix_str = json.dumps(prefix_obj, ensure_ascii=False)[:-1]  # drop closing `}`
        prefix_str += ', "response_draft": "'

    formatted_messages = prompt_messages
    if prose_first:
        formatted_messages = rewrite_messages_for_prose_first(prompt_messages)
    base_prompt = format_prompt(student_tok, formatted_messages, thinking=False)
    continuation_prompt = base_prompt + prefix_str

    chunks: list[str] = []
    final = None
    t0 = time.perf_counter()
    for response in stream_generate(
        student_model,
        student_tok,
        continuation_prompt,
        max_tokens=STUDENT_PROSE_MAX_TOKENS,
        sampler=sampler,
    ):
        chunks.append(response.text)
        accumulated = "".join(chunks)
        # Stop as soon as the student closes the string literal with an
        # unescaped ``"``. We do NOT rely on mlx-lm's stop_strings (not a
        # native argument in 0.31.2) — we just break out of the loop.
        idx = find_unescaped_quote(accumulated)
        if idx >= 0:
            final = response
            wall = time.perf_counter() - t0
            if final is not None:
                stats.add_student(final.prompt_tokens, final.generation_tokens, wall)
            return accumulated[:idx], ""
        final = response
    wall = time.perf_counter() - t0
    if final is not None:
        stats.add_student(final.prompt_tokens, final.generation_tokens, wall)
    # Reached max_tokens without closing the string — reject this row.
    return None, "student-prose-unterminated"


def assemble_row(prompt_row: dict, stitched: dict, prose_first: bool = False) -> dict:
    """Produce an MLX-LM training row. Assistant content is the stitched JSON
    as a string. When ``prose_first`` is set the JSON is re-serialised with
    ``response_draft`` first so the model learns that key order at training
    time."""
    if prose_first:
        stitched = {
            "response_draft": stitched["response_draft"],
            "slot_updates": stitched["slot_updates"],
            "confidence": stitched["confidence"],
        }
    assistant_content = json.dumps(stitched, ensure_ascii=False)
    messages = prompt_row["messages"]
    if prose_first:
        messages = rewrite_messages_for_prose_first(messages)
    return {
        "prompt_id": prompt_row.get("prompt_id"),
        "messages": messages + [
            {"role": "assistant", "content": assistant_content}
        ],
    }


def load_model(repo_id: str):
    """Load an MLX-LM model + tokenizer. Silences the 'Fetching …' chatter
    on repeat loads since we only care about timing."""
    from mlx_lm import load

    t0 = time.perf_counter()
    model, tokenizer = load(repo_id)
    wall = time.perf_counter() - t0
    return model, tokenizer, wall


def load_teacher_cache(path: Path) -> dict[str, dict]:
    """Parse a previously-generated teacher-only JSONL into a dict keyed by
    ``prompt_id`` → validated assistant JSON. Rows that don't parse are
    skipped; the caller decides what to do with prompts that lack cached
    output (typically: fall back to fresh teacher generation)."""
    cache: dict[str, dict] = {}
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            asst = row["messages"][-1]
            if asst.get("role") != "assistant":
                continue
            try:
                parsed = json.loads(asst["content"])
            except json.JSONDecodeError:
                continue
            ok, _ = validate_schema(parsed)
            if ok:
                cache[row.get("prompt_id", "")] = parsed
    return cache


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--teacher",
        required=False,
        default=None,
        help="Teacher MLX repo id or path (not required if --teacher-cache covers all prompts)",
    )
    parser.add_argument("--student", required=True, help="Student MLX repo id or path")
    parser.add_argument(
        "--prompts",
        type=Path,
        required=True,
        help="Prompt-only JSONL produced by extract_prompts.py",
    )
    parser.add_argument("--output", type=Path, required=True, help="Output JSONL path")
    parser.add_argument("--limit", type=int, default=0, help="0 = all prompts")
    parser.add_argument("--temperature", type=float, default=0.6)
    parser.add_argument("--top-p", type=float, default=0.95)
    parser.add_argument(
        "--start",
        type=int,
        default=0,
        help="Skip the first N prompts (resume mode)",
    )
    parser.add_argument(
        "--stats",
        type=Path,
        default=None,
        help="Optional JSON file for per-run aggregate stats",
    )
    parser.add_argument(
        "--teacher-cache",
        type=Path,
        default=None,
        help="JSONL produced by generate_teacher_only.py; reuse cached teacher JSON per prompt_id instead of regenerating. Misses fall back to the loaded teacher model if --teacher is also given.",
    )
    parser.add_argument(
        "--prose-first",
        action="store_true",
        help="Emit training rows with response_draft first (streaming-friendly order).",
    )
    args = parser.parse_args()

    from mlx_lm.sample_utils import make_sampler

    teacher_cache: dict[str, dict] = {}
    if args.teacher_cache:
        teacher_cache = load_teacher_cache(args.teacher_cache)
        print(f"Loaded {len(teacher_cache)} cached teacher rows from {args.teacher_cache}")

    teacher_model = teacher_tok = None
    if args.teacher:
        print(f"Loading teacher {args.teacher} …", flush=True)
        teacher_model, teacher_tok, teacher_load_s = load_model(args.teacher)
        print(f"  teacher loaded in {teacher_load_s:.1f}s")

    print(f"Loading student {args.student} …", flush=True)
    student_model, student_tok, student_load_s = load_model(args.student)
    print(f"  student loaded in {student_load_s:.1f}s")

    sampler = make_sampler(temp=args.temperature, top_p=args.top_p)

    with args.prompts.open("r", encoding="utf-8") as handle:
        prompts = [json.loads(line) for line in handle if line.strip()]
    if args.start:
        prompts = prompts[args.start :]
    if args.limit:
        prompts = prompts[: args.limit]

    args.output.parent.mkdir(parents=True, exist_ok=True)
    stats = GenerationStats()
    kept = 0
    rejected: dict[str, int] = {}
    t_start = time.perf_counter()

    with args.output.open("w", encoding="utf-8") as out:
        for i, prompt_row in enumerate(prompts):
            pid = prompt_row.get("prompt_id", "")
            teacher_json = teacher_cache.get(pid)
            err = ""
            if teacher_json is None:
                if teacher_model is None:
                    err = "teacher-cache-miss (no live teacher loaded)"
                    rejected[err] = rejected.get(err, 0) + 1
                    print(f"  [{i+1}/{len(prompts)}] skip — {err}")
                    continue
                teacher_json, err, _raw = generate_teacher_json(
                    teacher_model, teacher_tok, prompt_row["messages"], sampler, stats
                )
            if teacher_json is None:
                rejected[err] = rejected.get(err, 0) + 1
                print(f"  [{i+1}/{len(prompts)}] skip — {err}")
                continue

            prose, err = generate_student_prose(
                student_model, student_tok, prompt_row["messages"], teacher_json, sampler, stats,
                prose_first=args.prose_first,
            )
            if prose is None:
                rejected[err] = rejected.get(err, 0) + 1
                print(f"  [{i+1}/{len(prompts)}] skip — {err}")
                continue

            stitched = {
                "slot_updates": teacher_json["slot_updates"],
                "confidence": teacher_json["confidence"],
                "response_draft": prose,
            }
            row = assemble_row(prompt_row, stitched, prose_first=args.prose_first)
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
            out.flush()
            kept += 1
            if (i + 1) % 10 == 0 or (i + 1) == len(prompts):
                elapsed = time.perf_counter() - t_start
                rate = (i + 1) / elapsed if elapsed else 0
                print(
                    f"  [{i+1}/{len(prompts)}] kept={kept} rejected={sum(rejected.values())} "
                    f"({rate:.2f} rows/s, teacher_wall={stats.teacher_wall_s:.1f}s, "
                    f"student_wall={stats.student_wall_s:.1f}s)"
                )

    total_wall = time.perf_counter() - t_start
    summary = {
        "teacher": args.teacher,
        "student": args.student,
        "prompts_in": len(prompts),
        "rows_written": kept,
        "rejected": rejected,
        "total_wall_s": round(total_wall, 2),
        "teacher_wall_s": round(stats.teacher_wall_s, 2),
        "student_wall_s": round(stats.student_wall_s, 2),
        "teacher_gen_tokens": stats.teacher_gen_tokens,
        "student_gen_tokens": stats.student_gen_tokens,
    }
    print("\n=== TESSY synthesis summary ===")
    for k, v in summary.items():
        print(f"  {k}: {v}")

    if args.stats:
        args.stats.parent.mkdir(parents=True, exist_ok=True)
        with args.stats.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(summary, ensure_ascii=False) + "\n")
        print(f"\nAppended stats to {args.stats}")


if __name__ == "__main__":
    main()
