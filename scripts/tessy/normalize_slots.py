#!/usr/bin/env python3
"""Slot-value normalizer for TESSY evaluation.

The existing phone-agent training rows contain raw strings, missing-value
sentinels (``"(not collected)"``, ``"not collected"``, ``"unknown"``,
``""``), casing variation, and truncated descriptions. Comparing predicted
vs reference slot values by exact equality over-counts mismatches that are
not real regressions (e.g. ``"Main St."`` vs ``"main st"``). This module
gives us one normalization contract used everywhere F1 is computed.

Principles:

* Never punish case / whitespace variation on string values.
* Collapse any "this slot was not collected" sentinel into a canonical
  ``None`` — missing-and-said-missing should compare equal.
* Accept partial address equality (first-N characters match) since callers
  often only give a street + city, and the teacher may extract one.
* Dates and times use a small alias table — ``"tomorrow"`` resolves
  against the ``current_day`` context when it is available.
"""
from __future__ import annotations

import re
import unicodedata
from datetime import date, timedelta
from typing import Iterable

SENTINELS: set[str] = {
    "",
    "null",
    "none",
    "n/a",
    "na",
    "unknown",
    "not collected",
    "(not collected)",
    "to be collected",
    "tbd",
    "pending",
}

DAY_OFFSETS: dict[str, int] = {
    "today": 0,
    "tonight": 0,
    "tomorrow": 1,
    "tomorrow morning": 1,
    "tomorrow afternoon": 1,
    "day after tomorrow": 2,
    "next day": 1,
}

DAY_NAMES = (
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
)

TIME_WORD_ALIASES: dict[str, str] = {
    "morning": "8am-12pm",
    "afternoon": "12pm-5pm",
    "evening": "5pm-8pm",
    "night": "8pm-10pm",
    "asap": "asap",
    "right now": "asap",
    "immediately": "asap",
}

URGENCY_ALIASES: dict[str, str] = {
    "emergency": "emergency",
    "urgent": "high",
    "high": "high",
    "medium": "medium",
    "normal": "medium",
    "low": "low",
    "routine": "low",
}

KEY_ALIASES: dict[str, str] = {
    # alternate spellings that may appear in teacher output
    "customername": "customer_name",
    "service_address1": "service_address",
    "serviceaddress": "service_address",
    "postcode": "address_postcode",
    "zip": "address_postcode",
    "zipcode": "address_postcode",
    "phone": "callback_number",
    "callback": "callback_number",
}


_PHONE_NON_DIGIT_RE = re.compile(r"\D+")
_WHITESPACE_RE = re.compile(r"\s+")


def _clean_text(value: str) -> str:
    value = unicodedata.normalize("NFKC", value)
    value = _WHITESPACE_RE.sub(" ", value).strip()
    return value


def normalize_key(key: str) -> str:
    key = key.strip().lower().replace("-", "_").replace(" ", "_")
    return KEY_ALIASES.get(key, key)


def _is_sentinel(text: str) -> bool:
    stripped = text.strip().lower()
    return stripped in SENTINELS or stripped.startswith("(not ") or stripped.endswith(" (not collected)")


def normalize_phone(value: str) -> str | None:
    digits = _PHONE_NON_DIGIT_RE.sub("", value)
    if len(digits) >= 10:
        return digits[-10:]  # strip country code
    return digits or None


def normalize_urgency(value: str) -> str | None:
    key = value.strip().lower()
    return URGENCY_ALIASES.get(key)


def normalize_date_time(value: str, current_day: str | None = None) -> str | None:
    """Return a canonical token for a rough time slot.

    Examples::

        normalize_date_time("tomorrow", current_day="Thursday") -> "friday"
        normalize_date_time("Monday afternoon")                  -> "monday 12pm-5pm"
        normalize_date_time("6:15 PM")                            -> "18:15"
    """
    original = value
    value = _clean_text(value).lower()
    if _is_sentinel(value):
        return None

    # Relative day → absolute (only if current_day provided)
    if current_day and current_day.strip().lower() in DAY_NAMES:
        cur_idx = DAY_NAMES.index(current_day.strip().lower())
        for phrase, offset in DAY_OFFSETS.items():
            if value == phrase or value.startswith(phrase + " "):
                new_day = DAY_NAMES[(cur_idx + offset) % 7]
                tail = value[len(phrase):].strip()
                return (new_day + " " + TIME_WORD_ALIASES.get(tail, tail)).strip() or new_day

    # Day + period
    for day in DAY_NAMES:
        if day in value:
            tail = value.replace(day, "").strip()
            tail = TIME_WORD_ALIASES.get(tail, tail)
            return (day + " " + tail).strip() if tail else day

    # Pure time of day
    for word, canonical in TIME_WORD_ALIASES.items():
        if word in value:
            return canonical

    # HH:MM am/pm → 24-hour
    m = re.match(r"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$", value)
    if m:
        hour = int(m.group(1))
        minute = int(m.group(2) or "0")
        meridiem = m.group(3)
        if meridiem == "pm" and hour < 12:
            hour += 12
        elif meridiem == "am" and hour == 12:
            hour = 0
        return f"{hour:02d}:{minute:02d}"

    return _clean_text(original).lower() or None


def normalize_address(value: str, prefix_chars: int = 24) -> str | None:
    """Normalize an address to lowercase + squashed whitespace.

    Downstream comparison uses a prefix match — see ``values_equal``.
    """
    value = _clean_text(value).lower()
    if _is_sentinel(value):
        return None
    return value or None


def normalize_string(value: str) -> str | None:
    value = _clean_text(value).casefold()
    if _is_sentinel(value):
        return None
    return value or None


def normalize_value(key: str, value, context: dict | None = None):
    """Dispatch a slot value through the right normalizer for its key."""
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value
    if not isinstance(value, str):
        # Unknown type — JSON-serialize for stable comparison
        import json as _json
        return _json.dumps(value, sort_keys=True, ensure_ascii=False).lower()

    key = normalize_key(key)
    ctx = context or {}
    current_day = ctx.get("current_day")

    if key in ("date_time", "selected_slot", "preferred_time_windows"):
        return normalize_date_time(value, current_day)
    if key in ("callback_number",):
        return normalize_phone(value)
    if key in ("urgency_level",):
        return normalize_urgency(value)
    if key in ("service_address", "validated_address"):
        return normalize_address(value)
    if key == "address_postcode":
        stripped = re.sub(r"\s+", "", value.upper())
        return stripped or None
    return normalize_string(value)


def normalize_slot_updates(
    updates: dict, context: dict | None = None
) -> dict[str, object]:
    """Normalize every key and value in a ``slot_updates`` dict. Drops keys
    whose values normalize to ``None`` so "said nothing" == "said not
    collected" for comparison purposes."""
    if not isinstance(updates, dict):
        return {}
    normalized: dict[str, object] = {}
    for raw_key, raw_value in updates.items():
        key = normalize_key(str(raw_key))
        norm = normalize_value(key, raw_value, context)
        if norm is None:
            continue
        normalized[key] = norm
    return normalized


def values_equal(key: str, predicted, reference) -> bool:
    """Soft equality used inside F1. Handles address prefix match and
    numeric tolerance for ``confidence``."""
    if predicted is None and reference is None:
        return True
    if predicted is None or reference is None:
        return False
    if key == "confidence":
        try:
            return abs(float(predicted) - float(reference)) <= 0.15
        except (TypeError, ValueError):
            return False
    if key in ("service_address", "validated_address"):
        ps = str(predicted)
        rs = str(reference)
        # prefix match either direction (teacher may have extracted the
        # full address while user only gave a fragment, or vice versa)
        return ps.startswith(rs[:20]) or rs.startswith(ps[:20]) or ps == rs
    return predicted == reference


def f1_for_row(
    predicted_updates: dict,
    reference_updates: dict,
    context: dict | None = None,
) -> tuple[int, int, int]:
    """Return (tp, fp, fn) for one row's slot predictions."""
    p = normalize_slot_updates(predicted_updates, context)
    r = normalize_slot_updates(reference_updates, context)
    tp = fp = fn = 0
    for key, ref in r.items():
        if key in p and values_equal(key, p[key], ref):
            tp += 1
        else:
            fn += 1
    for key, pred in p.items():
        if key not in r or not values_equal(key, pred, r[key]):
            fp += 1
    return tp, fp, fn


def aggregate_f1(triples: Iterable[tuple[int, int, int]]) -> dict:
    tp = fp = fn = 0
    for a, b, c in triples:
        tp += a
        fp += b
        fn += c
    precision = tp / (tp + fp) if (tp + fp) else 0.0
    recall = tp / (tp + fn) if (tp + fn) else 0.0
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) else 0.0
    return {
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "precision": round(precision, 4),
        "recall": round(recall, 4),
        "f1": round(f1, 4),
    }


if __name__ == "__main__":
    # Tiny self-test so this module stays honest.
    cases: list[tuple[dict, dict, dict, tuple[int, int, int]]] = [
        # (predicted, reference, context, expected_tp_fp_fn)
        (
            {"service_address": "123 Main St, Apt 4"},
            {"service_address": "123 main st"},
            {},
            (1, 0, 0),
        ),
        (
            {"urgency_level": "Urgent"},
            {"urgency_level": "high"},
            {},
            (1, 0, 0),
        ),
        (
            {"date_time": "tomorrow"},
            {"date_time": "Friday"},
            {"current_day": "Thursday"},
            (1, 0, 0),
        ),
        (
            {"customer_name": "(not collected)"},
            {"customer_name": ""},
            {},
            (0, 0, 0),
        ),
        (
            {"callback_number": "(555) 123-4567"},
            {"callback_number": "+1 555 123 4567"},
            {},
            (1, 0, 0),
        ),
        (
            {"confidence": 0.9},
            {"confidence": 0.95},
            {},
            (1, 0, 0),  # within 0.15 tolerance
        ),
        (
            {"random_slot": "x"},
            {},
            {},
            (0, 1, 0),
        ),
    ]
    for pred, ref, ctx, expected in cases:
        got = f1_for_row(pred, ref, ctx)
        status = "OK  " if got == expected else "FAIL"
        print(f"{status} pred={pred} ref={ref} ctx={ctx} expected={expected} got={got}")
