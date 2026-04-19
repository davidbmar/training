#!/usr/bin/env python3
"""Helpers for switching between the two JSON output orders.

* `slots_first` (original) — `{"slot_updates": ..., "confidence": ..., "response_draft": ...}`
* `prose_first` (streaming) — `{"response_draft": ..., "slot_updates": ..., "confidence": ...}`

The streaming architecture needs ``response_draft`` at the start of the
JSON object so a partial-JSON parser can forward prose to TTS as it
arrives, while the model is still generating ``slot_updates``.

Two functions are exported:

- ``rewrite_system_for_prose_first(text)`` — finds the "Reply as JSON:"
  example line inside a system prompt and rewrites it so the model emits
  the fields in ``prose_first`` order.
- ``rewrite_messages_for_prose_first(messages)`` — map over a messages
  list and rewrite every system message.

Both are idempotent: if the system message already reflects the
``prose_first`` order they are no-ops.
"""
from __future__ import annotations

import re

# The original example line that appears in every slot-rewrite system prompt.
_ORIGINAL_LINE = (
    'Reply as JSON: {"slot_updates": {"key": "value"}, '
    '"confidence": 0.9, "response_draft": "your spoken reply"}'
)
_PROSE_FIRST_LINE = (
    'Reply as JSON (emit the fields in THIS order — response_draft MUST come '
    'first so we can start speaking before the slots finalise): '
    '{"response_draft": "your spoken reply", "slot_updates": {"key": "value"}, '
    '"confidence": 0.9}'
)
_SLOT_FIRST_RE = re.compile(
    r'Reply as JSON: \{"slot_updates": \{"key": "value"\}, "confidence": 0\.9, '
    r'"response_draft": "your spoken reply"\}'
)


def rewrite_system_for_prose_first(text: str) -> str:
    """Return ``text`` with the JSON example line swapped to prose-first.

    Idempotent: if the prose-first line is already present the input is
    returned unchanged. Works on the original slot-rewrite prompts only —
    other prompts pass through untouched so we never damage unrelated
    instruction text.
    """
    if _PROSE_FIRST_LINE in text:
        return text
    return _SLOT_FIRST_RE.sub(_PROSE_FIRST_LINE, text, count=1)


def rewrite_messages_for_prose_first(messages: list[dict]) -> list[dict]:
    out: list[dict] = []
    for msg in messages:
        if msg.get("role") == "system" and isinstance(msg.get("content"), str):
            msg = {**msg, "content": rewrite_system_for_prose_first(msg["content"])}
        out.append(msg)
    return out


if __name__ == "__main__":
    sample_system = (
        "You are a friendly phone receptionist. Some context here. "
        'Reply as JSON: {"slot_updates": {"key": "value"}, '
        '"confidence": 0.9, "response_draft": "your spoken reply"}\n'
        "Include any NEW information the caller just provided."
    )
    rewritten = rewrite_system_for_prose_first(sample_system)
    assert _PROSE_FIRST_LINE in rewritten
    assert _ORIGINAL_LINE not in rewritten
    # Idempotent
    assert rewrite_system_for_prose_first(rewritten) == rewritten
    print("OK:", rewritten[:200] + "…")
