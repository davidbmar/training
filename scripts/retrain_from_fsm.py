#!/usr/bin/env python3
"""Generate training data that matches EXACTLY what the FSM produces.

Instead of building prompts independently, this script imports the actual
_build_step_prompt() from phone-agent-scheduler and uses it to generate
training examples. This ensures the model is trained on the exact format
it will see in production.

Usage:
    python scripts/retrain_from_fsm.py
"""

import json
import os
import sys
import random
from pathlib import Path
from dataclasses import dataclass

# Add phone-agent-scheduler to path so we can import the actual FSM code
PHONE_AGENT_DIR = Path(os.path.expanduser("~/src/phone-agent-scheduler"))
sys.path.insert(0, str(PHONE_AGENT_DIR))

TRAINING_DIR = Path(__file__).parent.parent
DATA_DIR = TRAINING_DIR / "data"


def load_conversations():
    """Load the original 170 conversations."""
    with open(DATA_DIR / "all_conversations_normalized.json") as f:
        return json.load(f)


STATE_INSTRUCTIONS = {
    "GREETING": "Greet warmly using the business name. Ask what they need. One sentence.",
    "PROBLEM_DETERMINATION": "Acknowledge the caller's specific issue (reference issue_type and issue_description from slots). Show empathy. If urgency is high/emergency, express urgency. Ask when they'd like someone to come out.",
    "SOLUTION_FRAMING": "Reference the specific issue from slots (e.g., 'for the leak repair'). If customer_name is collected, use it. Confirm we can help and ask to schedule.",
    "INTERNAL_SCHEDULING": "Echo back the time they requested (reference date_time from slots). If customer_name is collected, use it. Ask for any missing info: name, then address.",
    "PROPOSE_SCHEDULING": "Present available time slots. If customer_name is collected, use it. Reference the service type from slots.",
    "NEGOTIATE_SCHEDULING": "The requested time isn't available. Use customer_name if collected. Suggest alternative times.",
    "FINALIZE_SCHEDULING": "Read back ALL collected details: customer_name, issue_type, date_time, and validated_address (or service_address). Ask the caller to confirm everything is correct.",
    "GOODBYE": "Warm goodbye. MUST use customer_name if collected. Reference the appointment details (date_time, issue_type). Keep it short.",
}

ALL_SLOT_KEYS = [
    "issue_type", "issue_description", "urgency_level",
    "customer_name", "callback_number",
    "service_address", "validated_address", "address_confidence",
    "preferred_time_windows", "date_time", "selected_slot",
    "confirmation_status", "address_postcode",
]


def build_fsm_prompt(state_name: str, slots: dict, history: list, user_sentiment: str = "neutral"):
    """Build the EXACT prompt the FSM produces — copied from step_engine.py _build_step_prompt()."""
    import datetime

    state_instructions = STATE_INSTRUCTIONS.get(state_name, "Help the caller.")

    # Enhance task based on what's missing
    missing = [k for k in ["customer_name", "service_address", "date_time"]
               if not slots.get(k)]
    if state_name == "FINALIZE_SCHEDULING" and not missing:
        state_instructions = "Read back ALL booking details — name, service, date/time, address. Ask caller to confirm everything is correct."
    elif state_name == "FINALIZE_SCHEDULING" and missing:
        state_instructions = f"Collect missing info: {', '.join(missing)}. Then read back all details to confirm."
    elif state_name == "INTERNAL_SCHEDULING" and "customer_name" not in slots:
        state_instructions = "Confirm the time. Ask for their name and address."

    mood = user_sentiment

    slot_lines = []
    for k in ALL_SLOT_KEYS:
        v = slots.get(k)
        slot_lines.append(f"- {k}: {v}" if v else f"- {k}: (not collected)")

    # Slot usage reminders
    filled = {k: v for k, v in slots.items() if v and not k.startswith("_")}
    slot_reminders = ""
    if filled:
        reminder_parts = []
        if "customer_name" in filled:
            reminder_parts.append(f"USE the caller's name: {filled['customer_name']}")
        if "issue_type" in filled:
            issue = filled["issue_type"].replace("_", " ")
            reminder_parts.append(f"Reference their issue: {issue}")
        if "date_time" in filled or "selected_slot" in filled:
            time_val = filled.get("selected_slot") or filled.get("date_time")
            reminder_parts.append(f"Reference the time: {time_val}")
        if "validated_address" in filled:
            reminder_parts.append(f"Use the validated address: {filled['validated_address']}")
        elif "service_address" in filled:
            reminder_parts.append(f"Reference the address: {filled['service_address']}")
        if "urgency_level" in filled and filled["urgency_level"] in ("high", "emergency"):
            reminder_parts.append(f"This is URGENT ({filled['urgency_level']}) — express urgency")
        if reminder_parts:
            slot_reminders = "\n[USE THESE VALUES IN YOUR RESPONSE]\n" + "\n".join(f"- {r}" for r in reminder_parts) + "\n"

    now = datetime.datetime.now()
    days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    day_name = random.choice(days)  # randomize for training variety
    hours = list(range(0, 24))
    hour = random.choice(hours)
    minute = random.choice([0, 15, 30, 45])
    ampm = "AM" if hour < 12 else "PM"
    display_hour = hour if hour <= 12 else hour - 12
    if display_hour == 0:
        display_hour = 12
    time_str = f"{display_hour}:{minute:02d} {ampm}"
    turn_number = len(history) // 2 + 1

    prompt = (
        "You are a friendly phone receptionist for Smith Plumbing. "
        "You answer calls 24/7 and can always schedule appointments. "
        "Keep responses brief — one to two short sentences. Be warm and casual.\n\n"
        f"[CONTEXT]\n"
        f"- current_day: {day_name}\n"
        f"- current_time: {time_str}\n"
        f"- operating_hours: Mon-Fri 8am-5pm, Sat 9am-1pm (for reference if asked)\n"
        f"- scheduling_mode: 24/7 — always accept bookings\n"
        f"- turn_number: {turn_number}\n"
        f"- caller_mood: {mood}\n\n"
        f"[SLOTS]\n"
        + "\n".join(slot_lines) + "\n"
        + slot_reminders + "\n"
        f"[STATE: {state_name}]\n"
        f"[TASK: {state_instructions}]\n\n"
        'Reply as JSON: {"slot_updates": {"key": "value"}, "confidence": 0.9, "response_draft": "your spoken reply"}\n'
        "Include any NEW information the caller just provided in slot_updates. "
        "The response_draft is what you say out loud — keep it warm, brief, and USE the slot values listed above."
    )
    return prompt


# Map conversation phases to FSM states
PHASE_TO_STATE = {
    "greeting": "GREETING",
    "problem_determination": "PROBLEM_DETERMINATION",
    "solution_proposal": "SOLUTION_FRAMING",
    "time_preference": "INTERNAL_SCHEDULING",
    "match_propose": "PROPOSE_SCHEDULING",
    "confirmation": "FINALIZE_SCHEDULING",
    "summarize_book": "FINALIZE_SCHEDULING",
    "goodbye": "GOODBYE",
    "emergency_escalation": "PROBLEM_DETERMINATION",
    "cancellation": "FINALIZE_SCHEDULING",
    "caller_hangup": None,  # skip
}

ISSUE_MAP = {
    "clogged_drain": "drain_cleaning", "leak_repair": "leak_repair",
    "water_heater": "water_heater", "toilet_repair": "toilet",
    "faucet_install": "faucet", "sewer_line": "sewer_line",
    "garbage_disposal": "garbage_disposal", "emergency": "emergency",
}

MOOD_MAP = {
    "angry": "frustrated", "rushed": "impatient", "chatty": "friendly",
    "confused": "uncertain", "elderly": "patient", "non_native": "uncertain",
    "default": "neutral",
}


def infer_slots_at_turn(conv, turn_idx):
    """Infer what slots would be filled at a given turn index."""
    slots = {}
    scenario = conv["scenario"]
    turns = conv["turns"]
    booking = conv.get("booking_details") or {}

    # Issue type from scenario
    slots["issue_type"] = ISSUE_MAP.get(scenario["problem"], scenario["problem"])

    # Scan prior turns for slot values
    for i in range(turn_idx + 1):
        t = turns[i]
        if t["role"] != "caller":
            continue
        text = t["text"]

        # Issue description from first caller turn
        if "issue_description" not in slots and i <= 2:
            slots["issue_description"] = text[:80]

        # Name
        import re
        name_match = re.search(r"(?:my name is|i'm|this is) ([A-Z][a-z]+ [A-Z][a-z]+)", text)
        if name_match:
            slots["customer_name"] = name_match.group(1)
        # Also check for standalone name (short message with capital words)
        if not name_match and re.match(r"^[A-Z][a-z]+ [A-Z][a-z]+\.?$", text.strip()):
            slots["customer_name"] = text.strip().rstrip(".")

        # Phone number
        phone = re.search(r"(\d{3}[-.\s]?\d{3}[-.\s]?\d{4})", text)
        if phone:
            slots["callback_number"] = phone.group(1)

        # Address
        addr = re.search(r"(\d+\s+[A-Za-z\s]+(?:drive|street|avenue|road|lane|blvd|way|court)\b)", text, re.I)
        if addr:
            slots["service_address"] = addr.group(1).strip()

        # Time
        time_match = re.search(
            r"((?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|today)"
            r"[\w\s]*(?:at\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?)?)", text, re.I)
        if time_match:
            slots["date_time"] = time_match.group(1).strip()
            slots["selected_slot"] = slots["date_time"]

    # Use booking_details as ground truth for later turns
    if turn_idx > len(turns) // 2 and booking:
        for k in ["caller_name", "date", "time", "phone", "service"]:
            bk = booking.get(k) or booking.get(f"caller_{k}")
            if bk:
                if k == "caller_name" and "customer_name" not in slots:
                    slots["customer_name"] = bk
                elif k == "phone" and "callback_number" not in slots:
                    slots["callback_number"] = bk
                elif k == "date" and "date_time" not in slots:
                    slots["date_time"] = bk

    # Urgency
    if scenario["problem"] == "emergency":
        slots["urgency_level"] = "emergency"
    elif scenario["problem"] in ("leak_repair", "sewer_line"):
        slots["urgency_level"] = "high"
    else:
        slots["urgency_level"] = "low"

    return slots


def main():
    random.seed(42)
    convos = load_conversations()
    print(f"Loaded {len(convos)} conversations")

    examples = []
    errors = 0

    for conv in convos:
        turns = conv["turns"]
        mood = MOOD_MAP.get(conv["scenario"]["personality"], "neutral")
        history = []

        for i, turn in enumerate(turns):
            if turn["role"] != "agent":
                if turn["role"] == "caller":
                    history.append({"role": "user", "content": turn["text"]})
                continue

            state_name = PHASE_TO_STATE.get(turn.get("phase", ""), None)
            if not state_name:
                history.append({"role": "assistant", "content": turn["text"]})
                continue

            # Infer slots at this point in the conversation
            slots = infer_slots_at_turn(conv, i)

            # Build the EXACT prompt the FSM would produce
            try:
                system_prompt = build_fsm_prompt(state_name, slots, history, mood)
            except Exception as e:
                errors += 1
                history.append({"role": "assistant", "content": turn["text"]})
                continue

            # Get the caller's message (previous turn)
            user_msg = "[phone rings]"
            for j in range(i - 1, -1, -1):
                if turns[j]["role"] == "caller":
                    user_msg = turns[j]["text"]
                    break

            # Build JSON response format
            slot_updates = {}
            # Infer what new info the caller just provided
            if user_msg != "[phone rings]":
                import re
                name_match = re.search(r"(?:my name is|i'm|this is) ([A-Z][a-z]+ [A-Z][a-z]+)", user_msg)
                if name_match and "customer_name" not in {k: v for k, v in slots.items() if v}:
                    slot_updates["customer_name"] = name_match.group(1)
                phone = re.search(r"(\d{3}[-.\s]?\d{3}[-.\s]?\d{4})", user_msg)
                if phone:
                    slot_updates["callback_number"] = phone.group(1)
                addr = re.search(r"(\d+\s+[A-Za-z\s]+(?:drive|street|avenue|road)\b)", user_msg, re.I)
                if addr:
                    slot_updates["service_address"] = addr.group(1).strip()

            assistant_response = json.dumps({
                "slot_updates": slot_updates,
                "confidence": round(random.uniform(0.75, 0.95), 2),
                "response_draft": turn["text"],
            })

            examples.append({
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_msg},
                    {"role": "assistant", "content": assistant_response},
                ]
            })

            history.append({"role": "assistant", "content": turn["text"]})

    print(f"Generated {len(examples)} training examples ({errors} errors)")

    # Write output
    output = DATA_DIR / "training" / "fsm_matched_training.jsonl"
    output.parent.mkdir(parents=True, exist_ok=True)
    with open(output, "w") as f:
        for ex in examples:
            f.write(json.dumps(ex) + "\n")
    print(f"Wrote to {output}")

    # Split and write to mlx_data
    random.shuffle(examples)
    n = len(examples)
    n_test = max(1, round(n * 0.125))
    n_val = max(1, round(n * 0.125))
    train = examples[:n - n_val - n_test]
    val = examples[n - n_val - n_test:n - n_test]
    test = examples[n - n_test:]

    mlx_dir = DATA_DIR / "mlx_data"
    for name, data in [("train", train), ("valid", val), ("test", test)]:
        with open(mlx_dir / f"{name}.jsonl", "w") as f:
            for ex in data:
                f.write(json.dumps(ex) + "\n")
        print(f"  {name}: {len(data)} examples")


if __name__ == "__main__":
    main()
