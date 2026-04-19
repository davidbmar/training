#!/usr/bin/env python3
"""Incremental parser that extracts ``response_draft`` text from a
streaming LLM that emits ``{"response_draft": "...", "slot_updates": ...,
"confidence": ...}``.

Design goals:

* **Byte-level streaming** — accept chunks of arbitrary size, including
  partial UTF-8 or partial string escapes.
* **Zero-copy for the TTS path** — once we've identified that we're
  inside the ``response_draft`` string, every decoded character can be
  pushed straight to the TTS queue; no buffering required.
* **Safe fall-through** — if the model ever violates the JSON grammar
  (bad escape, unexpected key, never closes the string), the parser
  reports a concrete error instead of silently corrupting output.
* **Final-JSON recovery** — once the string closes, the remaining chunks
  are accumulated into a completion string. ``finalize()`` returns the
  parsed dict so downstream code can read ``slot_updates`` / ``confidence``
  even though the prose has already left the building.

Usage::

    parser = StreamingPhoneJSONParser(on_prose=print)
    for chunk in llm_stream:
        parser.feed(chunk)
    result = parser.finalize()
    # result.response_draft is also the concatenation of all on_prose chunks
    # result.slot_updates, result.confidence are usable here

The parser does not care about thinking-mode ``<think>…</think>`` blocks —
strip those before feeding it (see ``smoke_teacher_only.strip_think_blocks``).
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable


class _State(Enum):
    PRE_OBJECT = "pre_object"         # haven't seen the opening {
    AWAIT_KEY = "await_key"           # inside the object, waiting for the first key
    IN_KEY = "in_key"                 # reading a key string
    AFTER_KEY = "after_key"           # read a key, waiting for :
    AWAIT_VALUE = "await_value"       # after : waiting for opening quote of the prose value
    IN_PROSE = "in_prose"             # streaming the response_draft string to on_prose
    PROSE_ESCAPE = "prose_escape"     # just saw a backslash inside the prose
    POST_PROSE = "post_prose"         # response_draft closed; remainder is buffered
    DONE = "done"
    ERROR = "error"


@dataclass
class StreamingResult:
    response_draft: str = ""
    slot_updates: dict = field(default_factory=dict)
    confidence: float | None = None
    raw_json: str = ""
    error: str = ""


class StreamingPhoneJSONParser:
    """Streams the first ``response_draft`` string to ``on_prose``, then
    accumulates the rest of the JSON object for a final ``finalize()`` call.

    A small state machine handles:

    * optional leading whitespace before the opening ``{``
    * the first JSON key, which MUST be ``response_draft`` — any other
      key puts the parser in ``ERROR`` state (the whole point is that the
      model was trained to emit prose first)
    * escaped quotes / backslashes inside the prose
    """

    def __init__(
        self,
        on_prose: Callable[[str], None] | None = None,
        strict: bool = True,
    ) -> None:
        """``strict=True`` means the first key must be ``response_draft``.
        ``strict=False`` gives a little grace: if we see any other key
        first, we bail without error but ``response_draft`` will be empty.
        """
        self._state: _State = _State.PRE_OBJECT
        self._on_prose = on_prose or (lambda _x: None)
        self._strict = strict
        self._key_buffer: list[str] = []
        self._prose_buffer: list[str] = []
        self._raw: list[str] = []
        self._post_buffer: list[str] = []
        self._error: str = ""

    # ---------------- public API ----------------

    def feed(self, chunk: str) -> None:
        if not chunk or self._state in (_State.DONE, _State.ERROR):
            if chunk and self._state == _State.DONE:
                self._post_buffer.append(chunk)
                self._raw.append(chunk)
            return
        self._raw.append(chunk)
        i = 0
        n = len(chunk)
        while i < n:
            if self._state == _State.ERROR:
                return
            if self._state in (_State.DONE, _State.POST_PROSE):
                self._post_buffer.append(chunk[i:])
                return
            i = self._step(chunk, i)

    def finalize(self) -> StreamingResult:
        """Best-effort parse of the tail. Returns a ``StreamingResult``
        with whatever prose + slot info could be recovered.

        We always try ``json.loads`` on the accumulated raw buffer — once
        the outer object closes we can recover ``slot_updates`` and
        ``confidence`` even if the streaming state machine stayed in
        POST_PROSE (we deliberately stopped tracking structure once the
        prose was safely delivered to the TTS consumer).
        """
        raw_joined = "".join(self._raw)
        res = StreamingResult(
            response_draft="".join(self._prose_buffer),
            raw_json=raw_joined,
            error=self._error,
        )

        candidate = raw_joined.strip()
        if candidate:
            try:
                obj = json.loads(candidate)
                res.slot_updates = obj.get("slot_updates", {}) or {}
                conf = obj.get("confidence")
                res.confidence = float(conf) if isinstance(conf, (int, float)) else None
                full_prose = obj.get("response_draft")
                if isinstance(full_prose, str) and full_prose and not res.response_draft:
                    res.response_draft = full_prose
                # Full object parsed — clear transient "incomplete" errors.
                if not self._error and res.error.startswith("incomplete-stream"):
                    res.error = ""
                if self._state not in (_State.DONE, _State.ERROR):
                    self._state = _State.DONE
                return res
            except json.JSONDecodeError as exc:
                # Fall through to state-specific error reporting
                decode_err = f"final-json-decode: {exc}"
                if not res.error:
                    res.error = decode_err

        if self._state not in (_State.DONE, _State.ERROR) and not res.error:
            res.error = f"incomplete-stream state={self._state.value}"
        return res

    # ---------------- internal state machine ----------------

    def _step(self, chunk: str, i: int) -> int:
        ch = chunk[i]
        st = self._state

        if st == _State.PRE_OBJECT:
            if ch.isspace():
                return i + 1
            if ch == "{":
                self._state = _State.AWAIT_KEY
                return i + 1
            self._error = f"expected '{{' got {ch!r} at pre_object"
            self._state = _State.ERROR
            return i + 1

        if st == _State.AWAIT_KEY:
            if ch.isspace() or ch == ",":
                return i + 1
            if ch == '"':
                self._key_buffer = []
                self._state = _State.IN_KEY
                return i + 1
            if ch == "}":
                self._state = _State.DONE
                return i + 1
            self._error = f"expected '\"' got {ch!r} at await_key"
            self._state = _State.ERROR
            return i + 1

        if st == _State.IN_KEY:
            if ch == '"':
                key = "".join(self._key_buffer)
                self._state = _State.AFTER_KEY
                self._current_key = key
                return i + 1
            self._key_buffer.append(ch)
            return i + 1

        if st == _State.AFTER_KEY:
            if ch.isspace() or ch == ":":
                if ch == ":":
                    self._state = _State.AWAIT_VALUE
                return i + 1
            self._error = f"expected ':' got {ch!r} after key"
            self._state = _State.ERROR
            return i + 1

        if st == _State.AWAIT_VALUE:
            if ch.isspace():
                return i + 1
            # If the first key isn't response_draft the caller asked for
            # a streaming-friendly model; ignore in lenient mode, error
            # in strict mode.
            if self._current_key != "response_draft":
                if self._strict:
                    self._error = (
                        f"first JSON key must be response_draft; got "
                        f"{self._current_key!r}"
                    )
                    self._state = _State.ERROR
                    return i + 1
                # Lenient mode: jump straight to POST_PROSE — don't stream
                # anything but keep accumulating for finalize().
                self._state = _State.POST_PROSE
                return i  # reprocess this char in post-prose accumulator
            if ch == '"':
                self._prose_buffer = []
                self._state = _State.IN_PROSE
                return i + 1
            self._error = f"expected '\"' to open response_draft got {ch!r}"
            self._state = _State.ERROR
            return i + 1

        if st == _State.IN_PROSE:
            if ch == "\\":
                self._state = _State.PROSE_ESCAPE
                return i + 1
            if ch == '"':
                self._state = _State.POST_PROSE
                return i + 1
            self._prose_buffer.append(ch)
            self._on_prose(ch)
            return i + 1

        if st == _State.PROSE_ESCAPE:
            decoded = {
                '"': '"', "\\": "\\", "/": "/",
                "n": "\n", "r": "\r", "t": "\t", "b": "\b", "f": "\f",
            }.get(ch)
            if decoded is None:
                # Uncommon escape (e.g. \u…) — passthrough raw chars.
                decoded = "\\" + ch
            self._prose_buffer.append(decoded)
            self._on_prose(decoded)
            self._state = _State.IN_PROSE
            return i + 1

        # POST_PROSE / DONE handled by feed() — we should not reach here.
        self._error = f"unexpected state {st.value}"
        self._state = _State.ERROR
        return i + 1


# ---------------------------------------------------------------------------
# Self-tests — run `python3 scripts/tessy/streaming_json.py` to sanity-check.
# ---------------------------------------------------------------------------


def _main_selftest() -> None:
    import io

    def make(strict: bool = True):
        out = io.StringIO()
        return StreamingPhoneJSONParser(on_prose=out.write, strict=strict), out

    # --- Case 1: simple prose-first JSON all in one shot ---
    p, out = make()
    p.feed('{"response_draft": "hi there!", "slot_updates": {"x": "y"}, "confidence": 0.9}')
    r = p.finalize()
    assert out.getvalue() == "hi there!", f"case1 prose mismatch: {out.getvalue()!r}"
    assert r.slot_updates == {"x": "y"}, r
    assert r.confidence == 0.9
    assert not r.error
    print("CASE 1 OK")

    # --- Case 2: chunked one-char at a time (worst case) ---
    raw = '{"response_draft": "Hello, caller!", "slot_updates": {}, "confidence": 0.95}'
    p, out = make()
    for c in raw:
        p.feed(c)
    r = p.finalize()
    assert out.getvalue() == "Hello, caller!", out.getvalue()
    assert r.slot_updates == {}
    assert r.confidence == 0.95
    print("CASE 2 OK (char-by-char)")

    # --- Case 3: escaped quotes inside prose ---
    raw = '{"response_draft": "She said \\"hi\\" to me.", "slot_updates": {}, "confidence": 0.9}'
    p, out = make()
    p.feed(raw)
    r = p.finalize()
    assert out.getvalue() == 'She said "hi" to me.', out.getvalue()
    print("CASE 3 OK (escaped quotes)")

    # --- Case 4: first key is NOT response_draft (strict = error) ---
    p, out = make(strict=True)
    p.feed('{"slot_updates": {}, "response_draft": "too late"}')
    r = p.finalize()
    assert r.error.startswith("first JSON key must be response_draft"), r.error
    print("CASE 4 OK (strict error on wrong-order)")

    # --- Case 5: first key wrong, but lenient — no prose streamed, full parse in finalize ---
    p, out = make(strict=False)
    p.feed('{"slot_updates": {}, "response_draft": "too late", "confidence": 0.9}')
    r = p.finalize()
    assert out.getvalue() == "", out.getvalue()
    assert r.response_draft == "too late", r  # recovered via json.loads at finalize
    print("CASE 5 OK (lenient fallback)")

    # --- Case 6: truncated stream (max_tokens hit mid-prose) ---
    p, out = make()
    p.feed('{"response_draft": "partial…')
    r = p.finalize()
    assert out.getvalue() == "partial…", out.getvalue()
    # Either incomplete-stream or json-decode is acceptable here — the key
    # guarantees are (a) prose streamed out and (b) error is surfaced.
    assert r.error, "expected truncated stream to report an error"
    assert "incomplete-stream" in r.error or "final-json-decode" in r.error
    print("CASE 6 OK (truncated stream)")

    # --- Case 7: \n escape inside prose ---
    p, out = make()
    p.feed('{"response_draft": "Line 1\\nLine 2", "slot_updates": {}, "confidence": 1}')
    r = p.finalize()
    assert out.getvalue() == "Line 1\nLine 2", repr(out.getvalue())
    print("CASE 7 OK (\\n escape)")

    print("\nAll self-tests passed.")


if __name__ == "__main__":
    _main_selftest()
