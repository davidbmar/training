#!/usr/bin/env python3
"""
Rewrite all training conversations to include [CONTEXT] + [SLOTS] + [STATE] + [TASK]
in every system prompt, producing one JSONL training example per agent turn.
"""

import json
import os
import random
import re
from collections import Counter
from pathlib import Path

random.seed(42)

# ---------------------------------------------------------------------------
# Mappings
# ---------------------------------------------------------------------------

ISSUE_TYPE_MAP = {
    "clogged_drain": "drain_cleaning",
    "leak_repair": "leak_repair",
    "water_heater": "water_heater",
    "toilet_repair": "toilet",
    "faucet_install": "faucet",
    "sewer_line": "sewer_line",
    "garbage_disposal": "garbage_disposal",
    "emergency": "emergency",
}

URGENCY_MAP = {
    "emergency": "emergency",
    "leak_repair": "high",
    "sewer_line": "high",
    "clogged_drain": "low",
    "water_heater": "low",
    "toilet_repair": "low",
    "faucet_install": "low",
    "garbage_disposal": "low",
}

MOOD_MAP = {
    "angry": "frustrated",
    "rushed": "impatient",
    "chatty": "friendly",
    "confused": "uncertain",
    "elderly": "patient",
    "non_native": "uncertain",
    "default": "neutral",
}

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
}

DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def random_time(after_hours: bool) -> str:
    """Generate a random time string in HH:MM format."""
    if after_hours:
        # Evening/night/weekend times: 6pm-11pm or early morning 6am-8am
        choice = random.random()
        if choice < 0.6:
            hour = random.randint(18, 22)
        elif choice < 0.8:
            hour = random.randint(6, 7)
        else:
            hour = random.randint(21, 23)
        minute = random.choice([0, 15, 30, 45])
    else:
        hour = random.randint(8, 16)
        minute = random.choice([0, 15, 30, 45])
    return f"{hour:02d}:{minute:02d}"


def generate_slots(current_day: str, n_slots: int = None) -> str:
    """Generate 3-5 realistic available time slots for the next few days."""
    if n_slots is None:
        n_slots = random.randint(3, 5)
    day_idx = DAYS.index(current_day)
    slots = []
    for i in range(n_slots):
        offset = random.randint(1, 4)
        slot_day = DAYS[(day_idx + offset) % 7]
        hour = random.choice([8, 9, 10, 11, 13, 14, 15, 16])
        minute = random.choice(["00", "30"])
        ampm = "AM" if hour < 12 else "PM"
        display_hour = hour if hour <= 12 else hour - 12
        slots.append(f"{slot_day} {display_hour}:{minute} {ampm}")
    return ", ".join(slots)


def extract_name(text: str) -> str | None:
    """Try to extract a customer name from text."""
    patterns = [
        r"(?:my name is|name's|it's|i'm|this is|i am)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)",
        r"^([A-Z][a-z]+\s+[A-Z][a-z]+)\s*[.\!,]?\s*$",
    ]
    for pat in patterns:
        m = re.search(pat, text, re.IGNORECASE)
        if m:
            name = m.group(1).strip().rstrip(".,!")
            # Title-case it
            name = " ".join(w.capitalize() for w in name.split())
            if len(name.split()) >= 1 and len(name) > 2:
                return name
    return None


def extract_phone(text: str) -> str | None:
    """Try to extract a phone number from text."""
    m = re.search(r"\b(\d{3}[-.\s]?\d{4})\b", text)
    if m:
        return m.group(1)
    m = re.search(r"\b(\(\d{3}\)\s*\d{3}[-.\s]?\d{4})\b", text)
    if m:
        return m.group(1)
    m = re.search(r"\b(\d{3}[-.\s]\d{3}[-.\s]\d{4})\b", text)
    if m:
        return m.group(1)
    return None


def extract_address(text: str) -> str | None:
    """Try to extract an address from text."""
    m = re.search(r"\b(\d+\s+[A-Z][a-z]+(?:\s+[A-Z]?[a-z]+)*\s+(?:Street|St|Avenue|Ave|Road|Rd|Drive|Dr|Lane|Ln|Boulevard|Blvd|Way|Circle|Court|Ct|Place|Pl)\.?)\b", text, re.IGNORECASE)
    if m:
        return m.group(1)
    return None


def extract_datetime(text: str) -> str | None:
    """Try to extract date/time references from text."""
    patterns = [
        r"((?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+(?:at\s+)?\d{1,2}(?::\d{2})?\s*(?:AM|PM|am|pm|a\.m\.|p\.m\.)?)",
        r"(tomorrow\s+(?:morning|afternoon|evening|at\s+\d{1,2}(?::\d{2})?\s*(?:AM|PM|am|pm)?))",
        r"(today\s+(?:at\s+)?\d{1,2}(?::\d{2})?\s*(?:AM|PM|am|pm)?)",
        r"((?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)(?:\s+morning|\s+afternoon|\s+evening)?)",
        r"(tomorrow(?:\s+morning|\s+afternoon|\s+evening)?)",
        r"(\d{1,2}(?::\d{2})?\s*(?:AM|PM|am|pm|o'clock))",
    ]
    for pat in patterns:
        m = re.search(pat, text, re.IGNORECASE)
        if m:
            return m.group(1).strip()
    return None


def infer_slots(conversation: dict, turns: list, up_to_index: int) -> dict:
    """Infer slot values from all prior turns and booking_details."""
    scenario = conversation["scenario"]
    booking = conversation.get("booking_details") or {}
    has_booking = conversation.get("metadata", {}).get("has_booking", False)

    # Issue type and urgency are only known once a caller has spoken about the problem
    # Check if any prior caller turn exists
    has_prior_caller = any(turns[i]["role"] == "caller" for i in range(up_to_index))
    if has_prior_caller:
        issue_type = ISSUE_TYPE_MAP.get(scenario["problem"], "(not collected)")
        urgency = URGENCY_MAP.get(scenario["problem"], "low")
    else:
        issue_type = "(not collected)"
        urgency = "(not collected)"

    # Scan prior caller turns
    issue_description = "(not collected)"
    customer_name = "(not collected)"
    callback_number = "(not collected)"
    service_address = "(not collected)"
    date_time = "(not collected)"

    first_caller_problem = True
    for i in range(up_to_index):
        t = turns[i]
        text = t["text"]

        # Issue description from first caller turn
        if t["role"] == "caller" and first_caller_problem:
            issue_description = text[:50].strip()
            first_caller_problem = False

        if t["role"] == "caller":
            # Name extraction
            if customer_name == "(not collected)":
                name = extract_name(text)
                if name:
                    customer_name = name

            # Phone extraction
            if callback_number == "(not collected)":
                phone = extract_phone(text)
                if phone:
                    callback_number = phone

            # Address extraction
            if service_address == "(not collected)":
                addr = extract_address(text)
                if addr:
                    service_address = addr

            # Date/time extraction
            if date_time == "(not collected)":
                dt = extract_datetime(text)
                if dt:
                    date_time = dt

    # Also scan agent turns for confirmed info
    for i in range(up_to_index):
        t = turns[i]
        if t["role"] == "agent":
            if date_time == "(not collected)":
                dt = extract_datetime(t["text"])
                if dt:
                    date_time = dt

    # Use booking_details as ground truth overlay — only past midpoint of conversation
    # to avoid leaking future info into early turns
    past_midpoint = up_to_index > len(turns) // 2
    if booking and past_midpoint:
        if booking.get("caller_name") or booking.get("name"):
            bd_name = booking.get("caller_name") or booking.get("name")
            customer_name = bd_name
        if booking.get("phone"):
            callback_number = booking["phone"]
        if booking.get("address"):
            service_address = booking["address"]
        if booking.get("date") or booking.get("time") or booking.get("day"):
            bd_dt_parts = []
            if booking.get("date") or booking.get("day"):
                bd_dt_parts.append(booking.get("date") or booking.get("day"))
            if booking.get("time") or booking.get("time_window"):
                bd_dt_parts.append(booking.get("time") or booking.get("time_window"))
            bd_dt = " ".join(bd_dt_parts)
            date_time = bd_dt

    # Determine selected_slot and validated_address
    current_phase = turns[up_to_index]["phase"] if up_to_index < len(turns) else "goodbye"
    late_phases = {"confirmation", "summarize_book", "goodbye"}

    selected_slot = date_time if current_phase in late_phases and date_time != "(not collected)" else "(not collected)"
    validated_address = service_address if current_phase in late_phases and service_address != "(not collected)" else "(not collected)"

    # Confirmation status
    if current_phase == "goodbye" and has_booking:
        confirmation_status = "confirmed"
    elif current_phase == "cancellation":
        confirmation_status = "cancelled"
    elif current_phase in late_phases:
        confirmation_status = "pending"
    else:
        confirmation_status = "(not collected)"

    return {
        "issue_type": issue_type,
        "issue_description": issue_description,
        "urgency_level": urgency,
        "customer_name": customer_name,
        "callback_number": callback_number,
        "service_address": service_address,
        "validated_address": validated_address,
        "date_time": date_time,
        "selected_slot": selected_slot,
        "confirmation_status": confirmation_status,
    }


def generate_task(state: str, slots: dict, phase: str) -> str:
    """Generate the [TASK] instruction based on state and missing slots."""
    if state == "GREETING":
        return "Greet warmly and ask how you can help."

    if state == "PROBLEM_DETERMINATION":
        if slots["issue_description"] == "(not collected)" or slots["issue_type"] == "(not collected)":
            return "Identify the plumbing issue. Ask clarifying questions."
        else:
            return "Acknowledge the issue with empathy. Ask when they'd like someone to come."

    if state == "SOLUTION_FRAMING":
        return "Briefly explain what we'll do and move toward scheduling."

    if state == "INTERNAL_SCHEDULING":
        if slots["date_time"] == "(not collected)":
            return "Ask when they'd like someone to come out."
        elif slots["customer_name"] == "(not collected)":
            return "Confirm the time. Ask for their name and address."
        else:
            return "Ask when they'd like someone to come out."

    if state == "PROPOSE_SCHEDULING":
        return "Present available time slots. Ask which works."

    if state == "FINALIZE_SCHEDULING":
        missing = []
        if slots["customer_name"] == "(not collected)":
            missing.append("name")
        if slots["callback_number"] == "(not collected)":
            missing.append("callback number")
        if slots["service_address"] == "(not collected)":
            missing.append("service address")
        if slots["date_time"] == "(not collected)":
            missing.append("date/time")
        if missing:
            return f"Collect missing info: {', '.join(missing)}. Then confirm."
        else:
            return "Read back ALL booking details — name, service, date/time, address. Ask to confirm."

    if state == "GOODBYE":
        return "Warm goodbye. Use their name. Keep it short."

    return "Continue the conversation naturally."


def build_system_prompt(
    state: str,
    task: str,
    slots: dict,
    context: dict,
) -> str:
    """Build the full system prompt with [CONTEXT], [SLOTS], [STATE], [TASK]."""

    lines = [
        "You are a friendly phone receptionist for Smith Plumbing. You answer calls 24/7 and can always schedule appointments. Keep responses brief — one to two short sentences. Be warm and casual.",
        "",
        "[CONTEXT]",
        f"- current_day: {context['current_day']}",
        f"- current_time: {context['current_time']}",
        "- operating_hours: Mon-Fri 8am-5pm, Sat 9am-1pm (for reference if asked)",
        "- scheduling_mode: 24/7 — always accept bookings",
        f"- available_slots: {context['available_slots']}",
        f"- turn_number: {context['turn_number']}",
        f"- caller_mood: {context['caller_mood']}",
        "",
        "[SLOTS]",
        f"- issue_type: {slots['issue_type']}",
        f"- issue_description: {slots['issue_description']}",
        f"- urgency_level: {slots['urgency_level']}",
        f"- customer_name: {slots['customer_name']}",
        f"- callback_number: {slots['callback_number']}",
        f"- service_address: {slots['service_address']}",
        f"- validated_address: {slots['validated_address']}",
        f"- date_time: {slots['date_time']}",
        f"- selected_slot: {slots['selected_slot']}",
        f"- confirmation_status: {slots['confirmation_status']}",
        "",
        f"[STATE: {state}]",
        f"[TASK: {task}]",
    ]
    return "\n".join(lines)


def process_conversations(conversations: list) -> list:
    """Process all conversations and produce training examples."""
    examples = []
    after_hours_count = 0
    total_count = 0

    for conv in conversations:
        scenario = conv["scenario"]
        turns = conv["turns"]
        personality = scenario.get("personality", "default")
        mood = MOOD_MAP.get(personality, "neutral")

        # Generate context values for this conversation
        current_day = random.choice(DAYS)

        # 30% after-hours
        is_after_hours = random.random() < 0.30
        # Also count weekends as after-hours
        is_weekend = current_day in ("Saturday", "Sunday")
        if is_weekend:
            is_after_hours = True

        current_time = random_time(after_hours=is_after_hours)
        available_slots = generate_slots(current_day)

        turn_number = 0
        for i, turn in enumerate(turns):
            if turn["role"] != "agent":
                continue
            if turn["phase"] == "caller_hangup":
                continue

            turn_number += 1
            total_count += 1

            # Determine after-hours for stats
            hour = int(current_time.split(":")[0])
            if is_weekend or hour < 8 or hour >= 17:
                after_hours_count += 1

            # Find the user message (prior caller turn, or [phone rings])
            user_message = "[phone rings]"
            for j in range(i - 1, -1, -1):
                if turns[j]["role"] == "caller":
                    user_message = turns[j]["text"]
                    break

            # Infer slots from prior turns
            slots = infer_slots(conv, turns, i)

            # Map phase to state
            phase = turn["phase"]
            state = PHASE_TO_STATE.get(phase, "PROBLEM_DETERMINATION")

            # Special handling for emergency_escalation urgency
            if phase == "emergency_escalation":
                slots["urgency_level"] = "emergency"

            # Special handling for cancellation
            if phase == "cancellation":
                slots["confirmation_status"] = "cancelled"

            # Generate task
            task = generate_task(state, slots, phase)

            # Build context
            context = {
                "current_day": current_day,
                "current_time": current_time,
                "available_slots": available_slots,
                "turn_number": turn_number,
                "caller_mood": mood,
            }

            # Build system prompt
            system_prompt = build_system_prompt(state, task, slots, context)

            example = {
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_message},
                    {"role": "assistant", "content": turn["text"]},
                ]
            }
            examples.append(example)

    return examples, after_hours_count, total_count


def print_stats(examples: list, after_hours_count: int, total_count: int):
    """Print statistics about the generated training data."""
    print(f"\n{'='*60}")
    print(f"TRAINING DATA GENERATION STATS")
    print(f"{'='*60}")
    print(f"Total examples: {len(examples)}")

    # Examples per state
    state_counts = Counter()
    slot_fill_counts = Counter()
    slot_total_counts = Counter()

    slot_names = [
        "issue_type", "issue_description", "urgency_level",
        "customer_name", "callback_number", "service_address",
        "validated_address", "date_time", "selected_slot",
        "confirmation_status",
    ]

    for ex in examples:
        sys_content = ex["messages"][0]["content"]
        # Extract state
        m = re.search(r"\[STATE:\s*(\w+)\]", sys_content)
        if m:
            state_counts[m.group(1)] += 1

        # Extract slot fill rates
        for slot in slot_names:
            slot_total_counts[slot] += 1
            pattern = rf"- {re.escape(slot)}:\s*(.+)"
            m = re.search(pattern, sys_content)
            if m and m.group(1).strip() != "(not collected)":
                slot_fill_counts[slot] += 1

    print(f"\nExamples per state:")
    for state, count in sorted(state_counts.items(), key=lambda x: -x[1]):
        print(f"  {state:30s} {count:5d}")

    print(f"\nSlot fill rates:")
    for slot in slot_names:
        total = slot_total_counts[slot]
        filled = slot_fill_counts[slot]
        pct = (filled / total * 100) if total > 0 else 0
        print(f"  {slot:30s} {filled:5d}/{total:5d}  ({pct:.1f}%)")

    pct_after = (after_hours_count / total_count * 100) if total_count > 0 else 0
    print(f"\nAfter-hours examples: {after_hours_count}/{total_count} ({pct_after:.1f}%)")
    print(f"{'='*60}")


def main():
    base_dir = Path("/Users/davidmar/src/training")
    input_path = base_dir / "data" / "all_conversations_normalized.json"
    output_path = base_dir / "data" / "training" / "all_with_slots.jsonl"

    # Load conversations
    with open(input_path) as f:
        conversations = json.load(f)
    print(f"Loaded {len(conversations)} conversations")

    # Process
    examples, after_hours_count, total_count = process_conversations(conversations)

    # Write output
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        for ex in examples:
            f.write(json.dumps(ex) + "\n")
    print(f"Wrote {len(examples)} examples to {output_path}")

    # Print stats
    print_stats(examples, after_hours_count, total_count)


if __name__ == "__main__":
    main()
