#!/usr/bin/env python3
"""Head-to-head analysis of two dogfood transcripts.

Given the JSONL outputs from ``phone_dogfood.py`` for two labels
(typically TESSY vs Teacher-Only on the same scenarios), compute:

* JSON validity rate (overall + per-outcome, per-mood, per-urgency)
* Mean / median response length (characters in response_draft)
* Mean response latency
* Slot-extraction FP rate — count of slot values the model asserted where
  the reference (original call scenario metadata) carries a sentinel. A
  "phantom slot" is any non-empty slot_updates value whose key is in the
  standard set but whose value was never provided in the scenario turns.
* Win/loss categorization — for each scenario, who hallucinated fewer
  slots, who produced more natural prose (by heuristic), and who
  responded faster.

Usage:
    python3 scripts/tessy/compare_dogfood.py \\
        --tessy data/tessy/dogfood_700_tessy.jsonl \\
        --teacher data/tessy/dogfood_700_teacher.jsonl \\
        --scenarios /Users/davidmar/src/riff/data/call_scenarios/scenarios_700.json \\
        --report data/tessy/dogfood_700_comparison.md
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path


EXPECTED_SLOT_KEYS = {
    "issue_type", "issue_description", "urgency_level", "customer_name",
    "callback_number", "service_address", "validated_address",
    "address_confidence", "preferred_time_windows", "date_time",
    "selected_slot", "confirmation_status", "address_postcode",
}

CALLER_INFO_KEYS = {
    "customer_name": "name",
    "callback_number": "phone",
    "service_address": "address",
    "date_time": "time",
    "selected_slot": "time",
}

SENTINELS = {
    "", "null", "None", "none", "(not collected)", "not collected",
    "unknown", "N/A", "n/a", "tbd", "pending",
}


def load_transcripts(path: Path) -> dict:
    """Return {scenario_id: record} from a dogfood JSONL file."""
    records = {}
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            records[r.get("scenario_id")] = r
    return records


def load_scenarios(path: Path) -> dict:
    """Return {scenario_id: metadata} from the scenarios file."""
    meta = {}
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    for s in data:
        meta[s["id"]] = s
    return meta


def caller_said_info(turns: list[str]) -> dict[str, bool]:
    """Light heuristic: did any caller turn carry name / phone / address /
    time info? Used to flag phantom slot_updates."""
    import re

    joined = " ".join(turns).lower()
    return {
        "name": bool(re.search(r"\b(i'm|my name is|this is|it's|name's)\s+[A-Z]", " ".join(turns))),
        "phone": bool(re.search(r"\d{3}[-.\s]?\d{3}[-.\s]?\d{4}", joined)),
        "address": bool(re.search(r"\d+\s+[a-z]+\s+(st|ave|drive|blvd|rd|road|ln|way|ct|circle|place)", joined)),
        "time": bool(re.search(
            r"\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|today|morning|afternoon|evening|asap)\b",
            joined,
        )),
    }


def count_phantom_slots(record: dict, scenario_turns: list[str]) -> int:
    """How many times did the model write a slot_updates value for a
    category the caller never provided?"""
    said = caller_said_info(scenario_turns)
    phantom = 0
    for turn in record.get("turns", []):
        updates = turn.get("slot_updates") or {}
        for key, value in updates.items():
            if not isinstance(value, str):
                continue
            if value.strip() in SENTINELS:
                continue
            category = CALLER_INFO_KEYS.get(key)
            if category and not said.get(category):
                phantom += 1
    return phantom


def summarize_transcripts(records: dict, scenarios: dict) -> dict:
    """Compute aggregate + sliced statistics for one adapter's run."""
    total_turns = 0
    json_valid_turns = 0
    phantom_total = 0
    response_lens: list[int] = []
    latencies: list[float] = []

    # Per-dimension slices: key -> list of phantom counts
    phantom_by_mood: defaultdict[str, list[int]] = defaultdict(list)
    phantom_by_urgency: defaultdict[str, list[int]] = defaultdict(list)
    phantom_by_outcome: defaultdict[str, list[int]] = defaultdict(list)
    jsonrate_by_mood: defaultdict[str, list[int]] = defaultdict(list)

    for sid, rec in records.items():
        meta = scenarios.get(sid, {})
        smd = meta.get("metadata", {})
        caller_turns = meta.get("turns", [])
        phantom = count_phantom_slots(rec, caller_turns)
        phantom_total += phantom
        phantom_by_mood[smd.get("mood", "?")].append(phantom)
        phantom_by_urgency[smd.get("urgency", "?")].append(phantom)
        phantom_by_outcome[smd.get("outcome_type", "?")].append(phantom)

        for turn in rec.get("turns", []):
            total_turns += 1
            response_lens.append(len(turn.get("response_draft", "")))
            latencies.append(turn.get("wall_s", 0.0))
            jvalid = 1 if turn.get("json_valid") else 0
            json_valid_turns += jvalid
            jsonrate_by_mood[smd.get("mood", "?")].append(jvalid)

    def pct(a, b):
        return round(100 * a / b, 1) if b else 0.0

    def avg(xs):
        return round(sum(xs) / len(xs), 2) if xs else 0.0

    return {
        "scenarios": len(records),
        "total_turns": total_turns,
        "json_valid_turns": json_valid_turns,
        "json_valid_rate": pct(json_valid_turns, total_turns),
        "phantom_slot_total": phantom_total,
        "phantom_slots_per_scenario": round(phantom_total / len(records), 2) if records else 0.0,
        "response_len_mean": avg(response_lens),
        "response_len_p50": statistics.median(response_lens) if response_lens else 0,
        "latency_mean_s": avg(latencies),
        "latency_p50_s": round(statistics.median(latencies), 2) if latencies else 0.0,
        "phantom_by_mood": {k: avg(v) for k, v in phantom_by_mood.items()},
        "phantom_by_urgency": {k: avg(v) for k, v in phantom_by_urgency.items()},
        "phantom_by_outcome": {k: avg(v) for k, v in phantom_by_outcome.items()},
        "json_valid_rate_by_mood": {
            k: pct(sum(v), len(v)) for k, v in jsonrate_by_mood.items()
        },
    }


def head_to_head(tessy: dict, teacher: dict, scenarios: dict) -> dict:
    """For each scenario present in both runs, attribute a winner on each
    dimension."""
    common = sorted(set(tessy) & set(teacher))
    wins = Counter()

    for sid in common:
        t = tessy[sid]
        r = teacher[sid]
        caller_turns = scenarios.get(sid, {}).get("turns", [])
        tp = count_phantom_slots(t, caller_turns)
        rp = count_phantom_slots(r, caller_turns)
        if tp < rp:
            wins["phantom_slots:tessy"] += 1
        elif rp < tp:
            wins["phantom_slots:teacher"] += 1
        else:
            wins["phantom_slots:tie"] += 1

        tj = sum(1 for tt in t["turns"] if tt["json_valid"]) / max(1, len(t["turns"]))
        rj = sum(1 for tt in r["turns"] if tt["json_valid"]) / max(1, len(r["turns"]))
        if tj > rj:
            wins["json_validity:tessy"] += 1
        elif rj > tj:
            wins["json_validity:teacher"] += 1
        else:
            wins["json_validity:tie"] += 1

        tl = sum(tt.get("wall_s", 0) for tt in t["turns"]) / max(1, len(t["turns"]))
        rl = sum(tt.get("wall_s", 0) for tt in r["turns"]) / max(1, len(r["turns"]))
        if tl < rl:
            wins["latency:tessy"] += 1
        elif rl < tl:
            wins["latency:teacher"] += 1
        else:
            wins["latency:tie"] += 1

    return dict(wins)


def render_report(tessy_sum: dict, teacher_sum: dict, head_wins: dict, n_scenarios: int) -> str:
    lines: list[str] = []
    lines.append("# 700-Scenario Head-to-Head: 4B TESSY vs 4B Teacher-Only")
    lines.append("")
    lines.append(f"Scenarios evaluated by both: **{n_scenarios}**")
    lines.append("")

    lines.append("## Aggregate totals")
    lines.append("")
    lines.append("| Metric                       | 4B TESSY | 4B Teacher-Only | Winner |")
    lines.append("|------------------------------|---------:|----------------:|:-------|")
    rows = [
        ("Scenarios", tessy_sum["scenarios"], teacher_sum["scenarios"], None),
        ("Total turns", tessy_sum["total_turns"], teacher_sum["total_turns"], None),
        ("JSON validity rate (%)",
         tessy_sum["json_valid_rate"], teacher_sum["json_valid_rate"],
         "higher"),
        ("Phantom slots / scenario",
         tessy_sum["phantom_slots_per_scenario"],
         teacher_sum["phantom_slots_per_scenario"], "lower"),
        ("Total phantom slots",
         tessy_sum["phantom_slot_total"], teacher_sum["phantom_slot_total"], "lower"),
        ("Mean response length (chars)",
         tessy_sum["response_len_mean"], teacher_sum["response_len_mean"], None),
        ("Median response length (chars)",
         tessy_sum["response_len_p50"], teacher_sum["response_len_p50"], None),
        ("Mean latency / turn (s)",
         tessy_sum["latency_mean_s"], teacher_sum["latency_mean_s"], "lower"),
        ("Median latency / turn (s)",
         tessy_sum["latency_p50_s"], teacher_sum["latency_p50_s"], "lower"),
    ]
    for name, tv, rv, better in rows:
        if better == "higher":
            winner = "TESSY" if tv > rv else "Teacher-Only" if rv > tv else "tie"
        elif better == "lower":
            winner = "TESSY" if tv < rv else "Teacher-Only" if rv < tv else "tie"
        else:
            winner = "—"
        lines.append(f"| {name} | {tv} | {rv} | {winner} |")
    lines.append("")

    lines.append("## Head-to-head per-scenario wins")
    lines.append("")
    lines.append("| Dimension | TESSY wins | Teacher-Only wins | Ties |")
    lines.append("|-----------|-----------:|------------------:|-----:|")
    for dim in ("phantom_slots", "json_validity", "latency"):
        t = head_wins.get(f"{dim}:tessy", 0)
        r = head_wins.get(f"{dim}:teacher", 0)
        ties = head_wins.get(f"{dim}:tie", 0)
        lines.append(f"| {dim} | {t} | {r} | {ties} |")
    lines.append("")

    lines.append("## Phantom slots by caller mood (average per scenario)")
    lines.append("")
    lines.append("| Mood | 4B TESSY | 4B Teacher-Only | Δ (TESSY − Teacher) |")
    lines.append("|------|---------:|----------------:|--------------------:|")
    moods = sorted(set(tessy_sum["phantom_by_mood"]) | set(teacher_sum["phantom_by_mood"]))
    for mood in moods:
        t = tessy_sum["phantom_by_mood"].get(mood, 0.0)
        r = teacher_sum["phantom_by_mood"].get(mood, 0.0)
        lines.append(f"| {mood} | {t} | {r} | {round(t - r, 2)} |")
    lines.append("")

    lines.append("## Phantom slots by urgency")
    lines.append("")
    lines.append("| Urgency | 4B TESSY | 4B Teacher-Only | Δ |")
    lines.append("|---------|---------:|----------------:|---:|")
    for u in ("emergency", "high", "medium", "low"):
        t = tessy_sum["phantom_by_urgency"].get(u, 0.0)
        r = teacher_sum["phantom_by_urgency"].get(u, 0.0)
        lines.append(f"| {u} | {t} | {r} | {round(t - r, 2)} |")
    lines.append("")

    lines.append("## Phantom slots by outcome")
    lines.append("")
    lines.append("| Outcome | 4B TESSY | 4B Teacher-Only | Δ |")
    lines.append("|---------|---------:|----------------:|---:|")
    outcomes = sorted(set(tessy_sum["phantom_by_outcome"]) | set(teacher_sum["phantom_by_outcome"]))
    for o in outcomes:
        t = tessy_sum["phantom_by_outcome"].get(o, 0.0)
        r = teacher_sum["phantom_by_outcome"].get(o, 0.0)
        lines.append(f"| {o} | {t} | {r} | {round(t - r, 2)} |")
    lines.append("")

    lines.append("## JSON validity by caller mood (%)")
    lines.append("")
    lines.append("| Mood | 4B TESSY | 4B Teacher-Only | Δ |")
    lines.append("|------|---------:|----------------:|---:|")
    moods_j = sorted(
        set(tessy_sum["json_valid_rate_by_mood"])
        | set(teacher_sum["json_valid_rate_by_mood"])
    )
    for mood in moods_j:
        t = tessy_sum["json_valid_rate_by_mood"].get(mood, 0.0)
        r = teacher_sum["json_valid_rate_by_mood"].get(mood, 0.0)
        lines.append(f"| {mood} | {t} | {r} | {round(t - r, 2)} |")
    lines.append("")

    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tessy", type=Path, required=True)
    ap.add_argument("--teacher", type=Path, required=True)
    ap.add_argument(
        "--scenarios",
        type=Path,
        default=Path("/Users/davidmar/src/riff/data/call_scenarios/scenarios_700.json"),
    )
    ap.add_argument(
        "--report",
        type=Path,
        default=Path("data/tessy/dogfood_700_comparison.md"),
    )
    args = ap.parse_args()

    tessy = load_transcripts(args.tessy)
    teacher = load_transcripts(args.teacher)
    scenarios = load_scenarios(args.scenarios)

    tessy_sum = summarize_transcripts(tessy, scenarios)
    teacher_sum = summarize_transcripts(teacher, scenarios)
    head_wins = head_to_head(tessy, teacher, scenarios)

    common = set(tessy) & set(teacher)
    report = render_report(tessy_sum, teacher_sum, head_wins, len(common))
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(report, encoding="utf-8")

    # Also dump the raw summaries for machine consumption
    json_dump = args.report.with_suffix(".json")
    with json_dump.open("w", encoding="utf-8") as handle:
        json.dump(
            {
                "tessy": tessy_sum,
                "teacher_only": teacher_sum,
                "head_to_head_wins": head_wins,
                "common_scenarios": len(common),
            },
            handle,
            indent=2,
            ensure_ascii=False,
        )
    print(report)
    print(f"\nReport: {args.report}")
    print(f"Raw summaries: {json_dump}")


if __name__ == "__main__":
    main()
