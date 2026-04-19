#!/usr/bin/env python3
"""Replay scripted phone-call scenarios against a trained adapter.

This is the qualitative counterpart to `evaluate.py`. It runs the same FSM
(from scripts/test_chat.py) on canned caller turns, so TESSY and Teacher-
Only adapters can be compared side-by-side on identical conversations.

Usage:
    python scripts/tessy/phone_dogfood.py \\
        --model mlx-community/Qwen3.5-4B-MLX-4bit \\
        --adapter adapters/qwen35-4b-tessy-phone \\
        --label 4b-tessy \\
        --scenarios scripts/tessy/scenarios.json \\
        --output data/tessy/dogfood.jsonl

Each scenario is a list of caller turns. The script:

* walks the FSM (GREETING → PROBLEM_DETERMINATION → …) using the same
  heuristics as `scripts/test_chat.py`;
* formats the system prompt from the slot state;
* calls the model (no thinking) to produce the JSON response;
* logs each turn so you can replay it later for comparison.
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
from smoke_teacher_only import extract_last_json_object, format_prompt, strip_think_blocks  # noqa: E402


SLOTS_TEMPLATE: dict[str, str] = {
    "issue_type": "(not collected)",
    "issue_description": "(not collected)",
    "urgency_level": "(not collected)",
    "customer_name": "(not collected)",
    "callback_number": "(not collected)",
    "service_address": "(not collected)",
    "validated_address": "(not collected)",
    "address_confidence": "(not collected)",
    "preferred_time_windows": "(not collected)",
    "date_time": "(not collected)",
    "selected_slot": "(not collected)",
    "confirmation_status": "pending",
    "address_postcode": "(not collected)",
}

STATES = [
    "GREETING", "PROBLEM_DETERMINATION", "SOLUTION_FRAMING",
    "INTERNAL_SCHEDULING", "PROPOSE_SCHEDULING",
    "FINALIZE_SCHEDULING", "GOODBYE",
]

TASKS = {
    "GREETING": "Greet the caller warmly and ask how you can help.",
    "PROBLEM_DETERMINATION": "Identify the plumbing issue. Ask clarifying questions with empathy.",
    "SOLUTION_FRAMING": "Briefly explain what we'll do and move toward scheduling.",
    "INTERNAL_SCHEDULING": "Ask when they'd like someone to come out.",
    "PROPOSE_SCHEDULING": "Present available time slots. Ask which works.",
    "FINALIZE_SCHEDULING": "Read back ALL booking details — name, service, date/time, address. Ask to confirm.",
    "GOODBYE": "Warm goodbye. Use their name. Keep it short.",
}


def infer_slots(caller_text: str, slots: dict) -> dict:
    """Lightweight slot inference, ported from scripts/test_chat.py."""
    text = caller_text.lower()

    if slots["issue_type"] == "(not collected)":
        issue_map = {
            "leak": "leak_repair", "leaking": "leak_repair", "drip": "leak_repair",
            "clog": "drain_cleaning", "backed up": "drain_cleaning", "drain": "drain_cleaning",
            "toilet": "toilet", "running": "toilet",
            "water heater": "water_heater", "no hot water": "water_heater", "hot water": "water_heater",
            "faucet": "faucet", "garbage disposal": "garbage_disposal", "disposal": "garbage_disposal",
            "sewer": "sewer_line", "emergency": "emergency", "burst": "emergency", "flooding": "emergency",
        }
        for kw, issue in issue_map.items():
            if kw in text:
                slots["issue_type"] = issue
                slots["issue_description"] = caller_text[:80]
                slots["urgency_level"] = "emergency" if issue == "emergency" else "low"
                break

    if slots["customer_name"] == "(not collected)":
        for pat in (
            r"(?:my name is|i'm|this is|it's) ([A-Z][a-z]+ [A-Z][a-z]+)",
            r"(?:my name is|i'm|this is|it's) ([A-Z][a-z]+)",
        ):
            m = re.search(pat, caller_text)
            if m:
                slots["customer_name"] = m.group(1)
                break

    if slots["callback_number"] == "(not collected)":
        phone = re.search(r"(\d{3}[-.\s]?\d{3}[-.\s]?\d{4})", caller_text)
        if phone:
            slots["callback_number"] = phone.group(1)

    if slots["date_time"] == "(not collected)":
        m = re.search(
            r"((?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|today)[\w\s]*?(?:\d{1,2}(?::\d{2})?\s*(?:am|pm)?)?)",
            text,
        )
        if m:
            slots["date_time"] = m.group(1).strip()
            slots["selected_slot"] = slots["date_time"]

    if slots["service_address"] == "(not collected)":
        addr = re.search(
            r"(\d+\s+[A-Za-z\s]+(?:drive|street|avenue|road|lane|blvd|way|court|circle|place)\b)",
            text,
            re.I,
        )
        if addr:
            slots["service_address"] = addr.group(1).strip()

    return slots


def advance_state(slots: dict, idx: int) -> int:
    if idx == 0:
        return 1
    if idx == 1 and slots["issue_type"] != "(not collected)":
        return 2
    if idx == 2:
        return 3
    if idx == 3 and slots["date_time"] != "(not collected)":
        return 4
    if idx == 4 and slots["selected_slot"] != "(not collected)":
        return 5
    return idx


def build_system_prompt(slots: dict, state: str, turn_number: int) -> str:
    task = TASKS.get(state, "Help the caller.")
    if state == "FINALIZE_SCHEDULING":
        missing = [
            k for k, v in slots.items()
            if v == "(not collected)" and k in ("customer_name", "service_address", "date_time")
        ]
        if missing:
            task = f"Collect missing info: {', '.join(missing)}. Then read back all details to confirm."

    slot_block = "\n".join(f"- {k}: {v}" for k, v in slots.items())
    return (
        "You are a friendly phone receptionist for Smith Plumbing. You answer calls 24/7 and "
        "can always schedule appointments. Keep responses brief — one to two short sentences. "
        "Be warm and casual.\n\n"
        "[CONTEXT]\n"
        "- current_day: Wednesday\n"
        "- current_time: 7:30 PM\n"
        "- operating_hours: Mon-Fri 8am-5pm, Sat 9am-1pm (for reference if asked)\n"
        "- scheduling_mode: 24/7 — always accept bookings\n"
        "- available_slots: Thursday 10am, Thursday 2pm, Friday 9am, Friday 3pm\n"
        f"- turn_number: {turn_number}\n"
        "- caller_mood: neutral\n\n"
        "[SLOTS]\n"
        f"{slot_block}\n\n"
        f"[STATE: {state}]\n"
        f"[TASK: {task}]\n\n"
        'Reply as JSON: {"slot_updates": {"key": "value"}, "confidence": 0.9, '
        '"response_draft": "your spoken reply"}\n'
        "Include any NEW information the caller just provided in slot_updates. The "
        "response_draft is what you say out loud — keep it warm, brief, and USE the slot "
        "values listed above."
    )


def run_scenario(scenario: dict, model, tokenizer, sampler, label: str) -> dict:
    from mlx_lm import stream_generate

    slots = dict(SLOTS_TEMPLATE)
    state_idx = 0
    turn = 0
    transcript: list[dict] = []

    # First turn: agent greets before caller speaks (scripts/test_chat.py
    # starts at turn 1 with GREETING state).
    for caller in scenario["turns"]:
        turn += 1
        slots = infer_slots(caller, slots)
        state = STATES[state_idx]
        system_prompt = build_system_prompt(slots, state, turn)

        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": caller},
        ]
        formatted = format_prompt(tokenizer, messages, thinking=False)

        chunks: list[str] = []
        final = None
        t0 = time.perf_counter()
        for response in stream_generate(
            model, tokenizer, formatted, max_tokens=512, sampler=sampler
        ):
            chunks.append(response.text)
            final = response
        wall = time.perf_counter() - t0

        raw = "".join(chunks)
        parsed, err = extract_last_json_object(strip_think_blocks(raw))
        if parsed is not None:
            slot_updates = parsed.get("slot_updates", {}) or {}
            # Merge model's slot extractions into our FSM state
            for k, v in slot_updates.items():
                if k in slots and isinstance(v, str) and v.strip():
                    slots[k] = v
            response_text = parsed.get("response_draft", "(no draft)")
            confidence = parsed.get("confidence", 0.0)
            json_valid = True
        else:
            slot_updates = {}
            response_text = raw[:160]  # fallback surface
            confidence = 0.0
            json_valid = False
            err = err or "non-json"

        turn_record = {
            "turn": turn,
            "state": state,
            "caller": caller,
            "response_draft": response_text,
            "slot_updates": slot_updates,
            "slots_after": copy.deepcopy(slots),
            "confidence": confidence,
            "json_valid": json_valid,
            "json_error": err if not json_valid else "",
            "wall_s": round(wall, 2),
            "gen_tokens": final.generation_tokens if final else 0,
        }
        transcript.append(turn_record)
        state_idx = advance_state(slots, state_idx)

    return {
        "scenario_id": scenario.get("id", "unnamed"),
        "scenario_title": scenario.get("title", ""),
        "label": label,
        "turns": transcript,
        "final_slots": slots,
        "final_state": STATES[state_idx],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model", required=True)
    parser.add_argument("--adapter", type=Path, default=None)
    parser.add_argument("--scenarios", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--temperature", type=float, default=0.6)
    parser.add_argument("--top-p", type=float, default=0.95)
    args = parser.parse_args()

    from mlx_lm import load
    from mlx_lm.sample_utils import make_sampler

    print(f"Loading {args.model}" + (f" + {args.adapter}" if args.adapter else ""))
    if args.adapter:
        model, tokenizer = load(args.model, adapter_path=str(args.adapter))
    else:
        model, tokenizer = load(args.model)
    sampler = make_sampler(temp=args.temperature, top_p=args.top_p)

    with args.scenarios.open("r", encoding="utf-8") as handle:
        scenarios = json.load(handle)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("a", encoding="utf-8") as out:
        for i, scenario in enumerate(scenarios):
            print(f"\n[{i+1}/{len(scenarios)}] {scenario.get('title', 'scenario')}")
            record = run_scenario(scenario, model, tokenizer, sampler, args.label)
            out.write(json.dumps(record, ensure_ascii=False) + "\n")
            out.flush()
            for t in record["turns"]:
                flag = "OK" if t["json_valid"] else "FAIL"
                print(f"  T{t['turn']} [{t['state']}] ({flag} {t['wall_s']}s) caller: {t['caller']}")
                print(f"       agent: {t['response_draft']}")

    print(f"\nWrote transcripts to {args.output}")


if __name__ == "__main__":
    main()
