#!/usr/bin/env python3
"""Streaming-aware single-turn benchmark for a TESSY adapter.

This is the minimum demo that proves the streaming architecture works:
given a prose-first trained adapter, measure

* **Time To First Prose Token (TTFPT)** — how quickly the first audible
  character leaves the LLM. This is the number a phone caller feels.
* **Time to Response-Draft Close** — when the full sentence is ready.
  TTS has everything it needs at this point.
* **Time to Slots Ready** — when ``slot_updates`` + ``confidence`` are
  parsed. The FSM can act on intent.
* **Total wall** — when the LLM emits its last token.

By "streaming" we mean: tokens leave the LLM one at a time, are fed to
``StreamingPhoneJSONParser``, and the ``on_prose`` callback fires with
each character of the eventual ``response_draft`` value as soon as the
parser confirms we're inside that string.

No TTS is invoked here. The goal is to measure the llm-side latencies
so we know what TTS has to work with once we wire it up in riff.

Usage::

    python3 scripts/tessy/phone_dogfood_streaming.py \\
        --model   mlx-community/Qwen3.5-4B-MLX-4bit \\
        --adapter adapters/qwen35-4b-tessy-streaming \\
        --scenarios scripts/tessy/scenarios.json \\
        --output data/tessy/streaming_demo.jsonl
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import time
from pathlib import Path

os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

_this_dir = Path(__file__).resolve().parent
if str(_this_dir) not in sys.path:
    sys.path.insert(0, str(_this_dir))
from smoke_teacher_only import format_prompt, strip_think_blocks  # noqa: E402
from streaming_json import StreamingPhoneJSONParser  # noqa: E402
from json_order import rewrite_messages_for_prose_first  # noqa: E402
from phone_dogfood import (  # noqa: E402
    SLOTS_TEMPLATE, STATES, TASKS,
    infer_slots, advance_state, build_system_prompt,
)


class TimingProbe:
    """Tracks the four canonical times for one streaming turn."""

    def __init__(self) -> None:
        self.t_start = time.perf_counter()
        self.t_first_prose: float | None = None
        self.t_prose_close: float | None = None
        self.t_slots_ready: float | None = None
        self.t_end: float | None = None
        self._prose_chars: list[str] = []
        self._saw_prose = False

    def on_prose(self, ch: str) -> None:
        if not self._saw_prose:
            self.t_first_prose = time.perf_counter()
            self._saw_prose = True
        self._prose_chars.append(ch)

    def mark_prose_close(self) -> None:
        if self.t_prose_close is None:
            self.t_prose_close = time.perf_counter()

    def mark_slots_ready(self) -> None:
        if self.t_slots_ready is None:
            self.t_slots_ready = time.perf_counter()

    def mark_end(self) -> None:
        self.t_end = time.perf_counter()

    def as_dict(self) -> dict:
        def delta(t: float | None) -> float | None:
            return round((t - self.t_start) * 1000, 1) if t is not None else None
        return {
            "ttfpt_ms": delta(self.t_first_prose),
            "prose_close_ms": delta(self.t_prose_close),
            "slots_ready_ms": delta(self.t_slots_ready),
            "total_wall_ms": delta(self.t_end),
            "prose_text": "".join(self._prose_chars),
        }


def run_turn(
    model,
    tokenizer,
    system_prompt: str,
    caller: str,
    sampler,
    max_tokens: int = 512,
    prose_first: bool = True,
) -> dict:
    """Run one LLM turn with streaming JSON parsing. Returns timing dict."""
    from mlx_lm import stream_generate

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": caller},
    ]
    if prose_first:
        messages = rewrite_messages_for_prose_first(messages)
    formatted = format_prompt(tokenizer, messages, thinking=False)

    probe = TimingProbe()
    parser = StreamingPhoneJSONParser(on_prose=probe.on_prose, strict=False)

    # Track whether we've seen the close-quote of response_draft + closing brace
    prose_closed_flag = {"flag": False}

    buffered = []
    for response in stream_generate(model, tokenizer, formatted, max_tokens=max_tokens, sampler=sampler):
        text = response.text
        buffered.append(text)
        # Thinking mode shouldn't fire (we set enable_thinking=False) but
        # strip just in case.
        stripped = strip_think_blocks(text) if "<think>" in "".join(buffered)[-30:] else text
        parser.feed(stripped)
        # Detect when we cross out of IN_PROSE → POST_PROSE (i.e. the
        # closing quote of response_draft was consumed).
        if not prose_closed_flag["flag"] and parser._state.value in ("post_prose", "done"):
            probe.mark_prose_close()
            prose_closed_flag["flag"] = True
    probe.mark_end()

    final = parser.finalize()
    if final.slot_updates or final.confidence is not None:
        probe.mark_slots_ready()

    result = probe.as_dict()
    result["response_draft"] = final.response_draft
    result["slot_updates"] = final.slot_updates
    result["confidence"] = final.confidence
    result["parser_error"] = final.error
    result["raw_tokens"] = response.generation_tokens if response else 0
    result["raw_prompt_tokens"] = response.prompt_tokens if response else 0
    result["peak_memory_gb"] = float(response.peak_memory or 0) if response else 0
    return result


def run_scenario(scenario: dict, model, tokenizer, sampler) -> dict:
    slots = dict(SLOTS_TEMPLATE)
    state_idx = 0
    turn = 0
    transcript: list[dict] = []
    for caller in scenario["turns"]:
        turn += 1
        slots = infer_slots(caller, slots)
        state = STATES[state_idx]
        system_prompt = build_system_prompt(slots, state, turn)
        res = run_turn(model, tokenizer, system_prompt, caller, sampler)
        # fold slot_updates into our FSM state
        for k, v in (res.get("slot_updates") or {}).items():
            if k in slots and isinstance(v, str) and v.strip():
                slots[k] = v
        state_idx = advance_state(slots, state_idx)
        res["turn"] = turn
        res["state"] = state
        res["caller"] = caller
        res["slots_after"] = copy.deepcopy(slots)
        transcript.append(res)
    return {
        "scenario_id": scenario.get("id", "unnamed"),
        "scenario_title": scenario.get("title", ""),
        "turns": transcript,
        "final_slots": slots,
    }


def print_timing_summary(transcripts: list[dict]) -> None:
    all_turns = [t for rec in transcripts for t in rec["turns"]]
    if not all_turns:
        print("(no turns)")
        return
    def pick(metric):
        vals = [t[metric] for t in all_turns if t.get(metric) is not None]
        if not vals:
            return None, None, None
        s = sorted(vals)
        return round(sum(vals) / len(vals), 1), s[len(s) // 2], s[int(0.95 * len(s))]

    print("\n=== Streaming timing (ms) — mean / p50 / p95 ===")
    print(f"  Time to first prose token:    {pick('ttfpt_ms')}")
    print(f"  Time to prose close:          {pick('prose_close_ms')}")
    print(f"  Time to slots ready:          {pick('slots_ready_ms')}")
    print(f"  Total LLM wall:               {pick('total_wall_ms')}")
    parsed = sum(1 for t in all_turns if t.get("response_draft"))
    err = sum(1 for t in all_turns if t.get("parser_error"))
    print(f"\n  Turns with parsed prose:   {parsed}/{len(all_turns)}")
    print(f"  Turns with parser errors:  {err}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--model", required=True)
    ap.add_argument("--adapter", type=Path, default=None)
    ap.add_argument("--scenarios", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--max-tokens", type=int, default=512)
    ap.add_argument("--temperature", type=float, default=0.6)
    ap.add_argument("--top-p", type=float, default=0.95)
    args = ap.parse_args()

    from mlx_lm import load
    from mlx_lm.sample_utils import make_sampler

    print(f"Loading {args.model}" + (f" + adapter {args.adapter}" if args.adapter else ""))
    if args.adapter:
        model, tokenizer = load(args.model, adapter_path=str(args.adapter))
    else:
        model, tokenizer = load(args.model)
    sampler = make_sampler(temp=args.temperature, top_p=args.top_p)

    with args.scenarios.open("r", encoding="utf-8") as handle:
        scenarios = json.load(handle)
    if args.limit:
        scenarios = scenarios[: args.limit]

    args.output.parent.mkdir(parents=True, exist_ok=True)
    transcripts: list[dict] = []
    with args.output.open("w", encoding="utf-8") as out:
        for i, scen in enumerate(scenarios):
            print(f"\n[{i+1}/{len(scenarios)}] {scen.get('title', scen.get('id'))}")
            rec = run_scenario(scen, model, tokenizer, sampler)
            out.write(json.dumps(rec, ensure_ascii=False) + "\n")
            out.flush()
            transcripts.append(rec)
            for t in rec["turns"]:
                print(
                    f"  T{t['turn']} [{t['state']}] TTFPT={t['ttfpt_ms']}ms  "
                    f"close={t['prose_close_ms']}ms  slots={t['slots_ready_ms']}ms  "
                    f"total={t['total_wall_ms']}ms"
                )
                print(f"       prose: {t['response_draft']}")

    print_timing_summary(transcripts)


if __name__ == "__main__":
    main()
