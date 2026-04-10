#!/usr/bin/env python3
"""Build final merged training data from slot-rewritten examples + edge cases.

Combines:
- data/training/all_with_slots.jsonl (~1,210 rewritten conversation examples)
- data/training/slot_edge_cases.jsonl (~100 edge case examples, oversampled 2x)

Outputs stratified train/val/test splits to data/mlx_data/
"""

import json
import random
from pathlib import Path
from collections import Counter, defaultdict

def extract_state(example):
    """Extract the [STATE: X] from the system prompt."""
    sys = example["messages"][0]["content"]
    for line in sys.split("\n"):
        if line.strip().startswith("[STATE:"):
            return line.strip().replace("[STATE: ", "").replace("]", "").strip()
    return "UNKNOWN"


def validate_example(example, idx):
    """Quick structural validation."""
    errors = []
    msgs = example.get("messages", [])
    if len(msgs) != 3:
        errors.append(f"Example {idx}: expected 3 messages, got {len(msgs)}")
        return errors
    if msgs[0]["role"] != "system":
        errors.append(f"Example {idx}: first message not system")
    if msgs[1]["role"] != "user":
        errors.append(f"Example {idx}: second message not user")
    if msgs[2]["role"] != "assistant":
        errors.append(f"Example {idx}: third message not assistant")

    sys = msgs[0]["content"]
    if "[SLOTS]" not in sys:
        errors.append(f"Example {idx}: missing [SLOTS] block")
    if "[STATE:" not in sys:
        errors.append(f"Example {idx}: missing [STATE] block")
    if "[TASK:" not in sys:
        errors.append(f"Example {idx}: missing [TASK] block")

    # Check for forbidden patterns
    assistant_text = msgs[2]["content"].lower()
    forbidden = ["we're closed", "we are closed", "call back during business hours",
                 "our office is closed", "not available right now", "call us back tomorrow"]
    for pat in forbidden:
        if pat in assistant_text:
            errors.append(f"Example {idx}: FORBIDDEN '{pat}' in assistant response")

    return errors


def stratified_split(examples, train_ratio=0.75, val_ratio=0.125, seed=42):
    """Split by state to ensure coverage in all sets."""
    random.seed(seed)

    by_state = defaultdict(list)
    for ex in examples:
        by_state[extract_state(ex)].append(ex)

    train, val, test = [], [], []

    for state, group in by_state.items():
        random.shuffle(group)
        n = len(group)
        n_test = max(1, round(n * (1 - train_ratio - val_ratio)))
        n_val = max(1, round(n * val_ratio))
        n_train = n - n_val - n_test

        if n_train < 1 and n > 2:
            n_train = 1
            n_test = max(1, (n - 1) // 2)
            n_val = n - n_train - n_test

        train.extend(group[:n_train])
        val.extend(group[n_train:n_train + n_val])
        test.extend(group[n_train + n_val:])

    random.shuffle(train)
    random.shuffle(val)
    random.shuffle(test)
    return train, val, test


def main():
    base = Path(__file__).parent.parent / "data"

    # Load rewritten examples
    rewritten = []
    with open(base / "training" / "all_with_slots.jsonl") as f:
        for line in f:
            if line.strip():
                rewritten.append(json.loads(line))
    print(f"Rewritten examples: {len(rewritten)}")

    # Load edge cases
    edge_cases = []
    with open(base / "training" / "slot_edge_cases.jsonl") as f:
        for line in f:
            if line.strip():
                edge_cases.append(json.loads(line))
    print(f"Edge case examples: {len(edge_cases)}")

    # Oversample edge cases 2x
    edge_oversampled = edge_cases * 2
    print(f"Edge cases after 2x oversample: {len(edge_oversampled)}")

    # Combine
    all_examples = rewritten + edge_oversampled
    print(f"Total combined: {len(all_examples)}")

    # Validate
    all_errors = []
    for i, ex in enumerate(all_examples):
        all_errors.extend(validate_example(ex, i))

    if all_errors:
        print(f"\nValidation errors ({len(all_errors)}):")
        for e in all_errors[:20]:
            print(f"  ✗ {e}")
    else:
        print("✓ All examples pass validation")

    # State distribution
    state_counts = Counter(extract_state(ex) for ex in all_examples)
    print("\nState distribution:")
    for state, count in sorted(state_counts.items(), key=lambda x: -x[1]):
        bar = "█" * (count // 10)
        print(f"  {state:30s} {count:5d} {bar}")

    # Check after-hours percentage
    after_hours = 0
    for ex in all_examples:
        sys = ex["messages"][0]["content"]
        for line in sys.split("\n"):
            if "current_time:" in line:
                time_str = line.split("current_time:")[1].strip()
                # Parse hour
                try:
                    if ":" in time_str:
                        hour = int(time_str.split(":")[0])
                        if hour < 8 or hour >= 17:
                            after_hours += 1
                    elif "PM" in time_str.upper() or "AM" in time_str.upper():
                        parts = time_str.replace(":", " ").split()
                        hour = int(parts[0])
                        if "PM" in time_str.upper() and hour != 12:
                            hour += 12
                        if "AM" in time_str.upper() and hour == 12:
                            hour = 0
                        if hour < 8 or hour >= 17:
                            after_hours += 1
                except (ValueError, IndexError):
                    pass
                break

    print(f"\nAfter-hours examples: {after_hours}/{len(all_examples)} ({100*after_hours/len(all_examples):.1f}%)")

    # Stratified split
    train, val, test = stratified_split(all_examples)

    # Write output
    mlx_dir = base / "mlx_data"
    mlx_dir.mkdir(exist_ok=True)

    for name, data in [("train", train), ("valid", val), ("test", test)]:
        path = mlx_dir / f"{name}.jsonl"
        with open(path, "w") as f:
            for ex in data:
                f.write(json.dumps(ex) + "\n")

        states = Counter(extract_state(ex) for ex in data)
        print(f"\n{name}: {len(data)} examples")
        print(f"  States: {dict(states)}")

    print(f"\n✓ Final training data written to {mlx_dir}/")
    print(f"  train.jsonl: {len(train)}")
    print(f"  valid.jsonl: {len(val)}")
    print(f"  test.jsonl:  {len(test)}")


if __name__ == "__main__":
    main()
