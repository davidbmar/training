#!/usr/bin/env python3
"""Normalize phase labels, validate business behavior, and create stratified splits."""

import json
import random
import re
from pathlib import Path
from collections import Counter, defaultdict

# ─── Phase Normalization ─────────────────────────────────────────────────────

PHASE_MAP = {
    "greeting": "greeting", "greet": "greeting",
    "problem_determination": "problem_determination", "discovery": "problem_determination",
    "problem_description": "problem_determination", "info_gathering": "problem_determination",
    "information_gathering": "problem_determination", "intent": "problem_determination",
    "request": "problem_determination", "inquiry": "problem_determination",
    "empathy": "problem_determination",
    "problem_discovery": "problem_determination",
    "triage": "problem_determination",
    "solution_proposal": "solution_proposal", "advice": "solution_proposal",
    "diy_recommendation": "solution_proposal", "education": "solution_proposal",
    "referral": "solution_proposal", "pricing": "solution_proposal",
    "question": "solution_proposal", "response": "solution_proposal",
    "reconsider": "solution_proposal", "reconsideration": "solution_proposal",
    "objection": "solution_proposal", "decline": "solution_proposal",
    "changes_mind": "solution_proposal",
    "time_preference": "time_preference", "scheduling": "time_preference",
    "match_propose": "match_propose", "alternative": "match_propose",
    "no_availability": "match_propose", "hold": "match_propose",
    "confirmation": "confirmation", "booking": "confirmation",
    "summarize_book": "summarize_book", "resolution": "summarize_book",
    "goodbye": "goodbye", "closing": "goodbye", "follow_up": "goodbye",
    "emergency_escalation": "emergency_escalation",
    "emergency_assessment": "emergency_escalation",
    "emergency_dispatch": "emergency_escalation",
    "emergency_triage": "emergency_escalation",
    "urgency": "emergency_escalation", "escalation": "emergency_escalation",
    "cancellation": "cancellation",
    "caller_hangup": "caller_hangup", "hangup": "caller_hangup",
    "retention_attempt": "cancellation",
    "question_only": "solution_proposal",
    "diy_advice": "solution_proposal",
    "diy": "solution_proposal",
    "safety": "emergency_escalation",
    "safety_warning": "emergency_escalation",
    "frustration": "problem_determination",
    "clarification": "problem_determination",
    "cost_discussion": "solution_proposal",
    "negotiation": "solution_proposal",
    "rebooking": "time_preference",
    "rescheduling": "time_preference",
    "wrap_up": "goodbye",
    "farewell": "goodbye",
    "objection_handling": "solution_proposal",
    "no_slots": "match_propose",
    "complaint": "problem_determination",
    "apology": "problem_determination",
    "de_escalation": "problem_determination",
    "service_inquiry": "solution_proposal",
    "offer_alternative": "match_propose",
    "offer_alternatives": "match_propose",
    "waitlist": "match_propose",
    "cancellation_list": "match_propose",
}

CANONICAL_PHASES = [
    "greeting", "problem_determination", "solution_proposal",
    "time_preference", "match_propose", "confirmation",
    "summarize_book", "goodbye",
    "emergency_escalation", "cancellation", "caller_hangup",
]


def normalize_conversation(conv):
    for turn in conv["turns"]:
        raw = turn.get("phase", "").lower().strip()
        turn["phase"] = PHASE_MAP.get(raw, raw)
    phases = list(dict.fromkeys(t["phase"] for t in conv["turns"]))
    conv["metadata"]["phases_covered"] = phases
    conv["metadata"]["turn_count"] = len(conv["turns"])
    return conv


# ─── Structural Validation ───────────────────────────────────────────────────

def validate_structure(conv):
    """Basic structural checks."""
    errors = []
    turns = conv["turns"]
    cid = conv["id"]

    has_booking = conv.get("booking_details") is not None
    min_turns = 6 if has_booking else 4
    if len(turns) < min_turns:
        errors.append(f"{cid}: only {len(turns)} turns (need {min_turns}+)")

    if turns and turns[0]["role"] != "agent":
        errors.append(f"{cid}: first turn is not agent")

    forbidden = ["as an ai", "as a language model", "i'm an ai", "i am an ai"]
    for t in turns:
        if t["role"] == "agent":
            lower = t["text"].lower()
            for pat in forbidden:
                if pat in lower:
                    errors.append(f"{cid}: forbidden pattern '{pat}'")

    for t in turns:
        if t["phase"] not in CANONICAL_PHASES:
            errors.append(f"{cid}: unknown phase '{t['phase']}'")

    return errors


# ─── Business Behavior Validation ────────────────────────────────────────────

def validate_business(conv):
    """Check business-level quality, not just structure."""
    warnings = []
    cid = conv["id"]
    turns = conv["turns"]
    path = conv["scenario"]["path"]
    problem = conv["scenario"]["problem"]
    booking = conv.get("booking_details")

    agent_turns = [t for t in turns if t["role"] == "agent"]

    # 1. Agent reply length: phone calls should be brief
    for i, t in enumerate(agent_turns):
        words = len(t["text"].split())
        if words > 50:
            warnings.append(f"{cid}: agent turn {i} is {words} words (>50, too long for phone)")

    # 2. Emergency calls must escalate quickly
    if problem == "emergency" or path == "emergency_escalation":
        emergency_phases = [t["phase"] for t in turns]
        if "emergency_escalation" not in emergency_phases:
            warnings.append(f"{cid}: emergency scenario but no emergency_escalation phase")
        # Should not drag on too long before escalation
        pre_escalation = 0
        for t in turns:
            if t["phase"] == "emergency_escalation":
                break
            pre_escalation += 1
        if pre_escalation > 6:
            warnings.append(f"{cid}: {pre_escalation} turns before emergency escalation (>6)")

    # 3. Booking confirmations must include key details
    if booking:
        missing_fields = []
        for field in ["service", "date", "time", "caller_name"]:
            if not booking.get(field):
                missing_fields.append(field)
        if missing_fields:
            warnings.append(f"{cid}: booking missing {missing_fields}")

        # Agent should echo back details in confirmation phase
        confirm_turns = [t for t in agent_turns if t["phase"] == "confirmation"]
        if confirm_turns:
            confirm_text = " ".join(t["text"].lower() for t in confirm_turns)
            if booking.get("caller_name") and booking["caller_name"].split()[0].lower() not in confirm_text:
                warnings.append(f"{cid}: confirmation doesn't use caller's name")

    # 4. DIY advice should be for safe tasks only
    if path == "diy_recommendation":
        unsafe_problems = ["sewer_line", "water_heater", "emergency"]
        if problem in unsafe_problems:
            diy_turns = [t for t in agent_turns if t["phase"] == "solution_proposal"]
            diy_text = " ".join(t["text"].lower() for t in diy_turns)
            # Should still recommend professional for unsafe tasks
            pro_keywords = ["plumber", "professional", "technician", "send someone", "come out"]
            if not any(kw in diy_text for kw in pro_keywords):
                warnings.append(f"{cid}: DIY for {problem} without recommending professional")

    # 5. Pricing should stay within policy ($75-$150 service call)
    for t in agent_turns:
        # Look for dollar amounts
        prices = re.findall(r'\$(\d+)', t["text"])
        for price in prices:
            p = int(price)
            if p > 500:
                warnings.append(f"{cid}: agent quotes ${p} (seems too high)")

    # 6. Agent should never promise specific availability without checking
    for i, t in enumerate(agent_turns):
        if t["phase"] == "greeting" or t["phase"] == "problem_determination":
            if "definitely" in t["text"].lower() and ("tomorrow" in t["text"].lower() or "today" in t["text"].lower()):
                warnings.append(f"{cid}: agent promises availability before checking calendar")

    return warnings


# ─── Stratified Splitting ────────────────────────────────────────────────────

def stratified_split(convos, train_ratio=0.75, val_ratio=0.125, test_ratio=0.125, seed=42):
    """Split conversations ensuring each split has representation of all paths,
    problems, and personalities. Uses the conversation path as the primary
    stratification key since it's the most behaviorally distinct axis."""

    random.seed(seed)

    # Group by path (primary stratification axis)
    by_path = defaultdict(list)
    for c in convos:
        by_path[c["scenario"]["path"]].append(c)

    train, val, test = [], [], []

    for path, group in by_path.items():
        random.shuffle(group)
        n = len(group)

        # Ensure at least 1 in val and test for every path
        n_test = max(1, round(n * test_ratio))
        n_val = max(1, round(n * val_ratio))
        n_train = n - n_val - n_test

        # If group is too small, prioritize train > test > val
        if n_train < 1 and n > 2:
            n_train = 1
            n_test = max(1, (n - 1) // 2)
            n_val = n - n_train - n_test
        elif n <= 2:
            # Very small group: put in train, duplicate one to test
            train.extend(group)
            if group:
                test.append(group[0])
            continue

        train.extend(group[:n_train])
        val.extend(group[n_train:n_train + n_val])
        test.extend(group[n_train + n_val:])

    # Shuffle within each split
    random.shuffle(train)
    random.shuffle(val)
    random.shuffle(test)

    return train, val, test


def print_split_coverage(name, data):
    """Print coverage stats for a split."""
    paths = Counter(c["scenario"]["path"] for c in data)
    problems = Counter(c["scenario"]["problem"] for c in data)
    personalities = Counter(c["scenario"]["personality"] for c in data)
    bookings = sum(1 for c in data if c.get("booking_details"))

    print(f"\n{name}: {len(data)} conversations, {bookings} bookings")
    print(f"  Paths: {dict(paths)}")
    print(f"  Problems: {len(problems)} types covered")
    print(f"  Personalities: {len(personalities)} types covered")


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    base = Path(__file__).parent.parent / "data"

    # Load all batches
    all_convos = []
    for batch_file in sorted((base / "conversations").glob("batch_*.json")):
        with open(batch_file) as f:
            all_convos.extend(json.load(f))

    print(f"Loaded {len(all_convos)} conversations")

    # Normalize phases
    all_convos = [normalize_conversation(c) for c in all_convos]

    # Structural validation
    struct_errors = []
    for c in all_convos:
        struct_errors.extend(validate_structure(c))

    if struct_errors:
        print(f"\nStructural errors ({len(struct_errors)}):")
        for e in struct_errors[:20]:
            print(f"  ✗ {e}")
    else:
        print("✓ All conversations pass structural validation")

    # Business validation
    biz_warnings = []
    for c in all_convos:
        biz_warnings.extend(validate_business(c))

    if biz_warnings:
        print(f"\nBusiness warnings ({len(biz_warnings)}):")
        for w in biz_warnings[:30]:
            print(f"  ⚠ {w}")
    else:
        print("✓ All conversations pass business validation")

    # Phase distribution
    phase_counts = Counter()
    for c in all_convos:
        for t in c["turns"]:
            phase_counts[t["phase"]] += 1
    print("\nPhase distribution:")
    for phase in CANONICAL_PHASES:
        count = phase_counts.get(phase, 0)
        bar = "█" * (count // 10)
        print(f"  {phase:25s} {count:4d} {bar}")

    # Stratified split
    train, val, test = stratified_split(all_convos)

    splits_dir = base / "splits"
    splits_dir.mkdir(exist_ok=True)

    for name, data in [("train", train), ("val", val), ("test", test)]:
        # JSON (readable)
        with open(splits_dir / f"{name}.json", "w") as f:
            json.dump(data, f, indent=2)
        # JSONL (one per line)
        with open(splits_dir / f"{name}.jsonl", "w") as f:
            for conv in data:
                f.write(json.dumps(conv) + "\n")
        print_split_coverage(name, data)

    # Save normalized master file
    with open(base / "all_conversations_normalized.json", "w") as f:
        json.dump(all_convos, f, indent=2)

    print("\n✓ Files written:")
    print("  data/all_conversations_normalized.json")
    print("  data/splits/{train,val,test}.{json,jsonl}")


if __name__ == "__main__":
    main()
