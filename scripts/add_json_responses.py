#!/usr/bin/env python3
"""Convert plain text assistant responses to JSON format for FSM compatibility.

Reads the slot-aware training data and wraps each assistant response in:
{"slot_updates": {...}, "confidence": 0.9, "response_draft": "the spoken text"}

The slot_updates are inferred from what changed between this turn and the
previous turn's slots (parsed from the system prompt).
"""

import json
import re
import random
from pathlib import Path


def extract_slots_from_system(system_text: str) -> dict:
    """Parse [SLOTS] block from system prompt."""
    slots = {}
    in_slots = False
    for line in system_text.split("\n"):
        if line.strip() == "[SLOTS]":
            in_slots = True
            continue
        if line.strip().startswith("[") and in_slots:
            break
        if in_slots and line.strip().startswith("- "):
            parts = line.strip()[2:].split(": ", 1)
            if len(parts) == 2:
                key, val = parts
                if val != "(not collected)":
                    slots[key] = val
    return slots


def extract_state_from_system(system_text: str) -> str:
    """Parse [STATE: X] from system prompt."""
    match = re.search(r"\[STATE:\s*(\w+)\]", system_text)
    return match.group(1) if match else ""


def infer_slot_updates(system_slots: dict, user_message: str, state: str) -> dict:
    """Infer what new slots the caller just provided."""
    updates = {}
    msg = user_message.lower()

    # Name detection
    name_match = re.search(r"(?:my name is|i'm|this is|it's) ([A-Z][a-z]+ [A-Z][a-z]+)", user_message)
    if name_match and "customer_name" not in system_slots:
        updates["customer_name"] = name_match.group(1)

    # Single name (e.g., just "David Marr" as the full message)
    if not name_match and re.match(r"^[A-Z][a-z]+ [A-Z][a-z]+\.?$", user_message.strip()):
        if "customer_name" not in system_slots:
            updates["customer_name"] = user_message.strip().rstrip(".")

    # Phone number
    phone = re.search(r"(\d{3}[-.\s]?\d{3}[-.\s]?\d{4})", user_message)
    if phone and "callback_number" not in system_slots:
        updates["callback_number"] = phone.group(1)

    # Address
    addr = re.search(r"(\d+\s+[A-Za-z\s]+(?:drive|street|avenue|road|lane|blvd|way|court)\b)", msg, re.I)
    if addr and "service_address" not in system_slots:
        updates["service_address"] = addr.group(1).strip().title()

    # Time preferences
    time_words = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
                  "sunday", "tomorrow", "morning", "afternoon", "evening"]
    if any(w in msg for w in time_words) and "date_time" not in system_slots:
        time_match = re.search(
            r"((?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow)"
            r"[\w\s]*(?:at\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?)?)", msg)
        if time_match:
            updates["date_time"] = time_match.group(1).strip()

    # Confirmation
    if state == "FINALIZE_SCHEDULING":
        affirm = re.search(r"\b(yes|yeah|yep|correct|right|sounds good|perfect)\b", msg, re.I)
        if affirm:
            updates["confirmation_status"] = "confirmed"

    return updates


def main():
    base = Path(__file__).parent.parent / "data" / "training"

    # Read the slot-aware training data
    input_file = base / "all_with_slots.jsonl"
    output_file = base / "all_with_slots_json.jsonl"

    examples = []
    with open(input_file) as f:
        for line in f:
            if line.strip():
                examples.append(json.loads(line))

    print(f"Loaded {len(examples)} examples")

    converted = []
    for ex in examples:
        msgs = ex["messages"]
        system_text = msgs[0]["content"]
        user_text = msgs[1]["content"]
        assistant_text = msgs[2]["content"]

        # Extract current slots and state from system prompt
        current_slots = extract_slots_from_system(system_text)
        state = extract_state_from_system(system_text)

        # Infer what new info the caller provided
        slot_updates = infer_slot_updates(current_slots, user_text, state)

        # Build JSON response
        confidence = round(random.uniform(0.75, 0.95), 2)
        json_response = json.dumps({
            "slot_updates": slot_updates,
            "confidence": confidence,
            "response_draft": assistant_text,
        })

        converted.append({
            "messages": [
                msgs[0],  # system (unchanged)
                msgs[1],  # user (unchanged)
                {"role": "assistant", "content": json_response},
            ]
        })

    # Write output
    with open(output_file, "w") as f:
        for ex in converted:
            f.write(json.dumps(ex) + "\n")

    print(f"Converted {len(converted)} examples → {output_file}")

    # Stats
    with_updates = sum(1 for ex in converted
                       if json.loads(ex["messages"][2]["content"]).get("slot_updates"))
    print(f"Examples with slot_updates: {with_updates}/{len(converted)} ({100*with_updates/len(converted):.0f}%)")

    # Sample
    sample = random.choice(converted)
    print(f"\nSample:")
    print(f"  System: ...{sample['messages'][0]['content'][-100:]}")
    print(f"  User: {sample['messages'][1]['content'][:80]}")
    print(f"  Assistant: {sample['messages'][2]['content'][:200]}")


if __name__ == "__main__":
    main()
