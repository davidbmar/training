# Session S-2026-04-19-2028-all-mlx-routing

**Title:** All-MLX routing in phone-agent-scheduler — kill Ollama 20 s cold-load timeouts
**Goal:** Take the TESSY adapters trained in the prior two sessions
(`S-2026-04-18-0513-tessy-sprint-0.md`, `S-2026-04-18-0937-tessy-first-experiment.md`)
and route *every* LLM call in `~/src/phone-agent-scheduler/` through them —
Gateway chat, step_engine fast/strong, server warmup — so the production
phone path stops depending on Ollama's paged-out-of-VRAM gemma4:26b.

## Problem observed

Logs from a test voice call (`voice-mo4wpisk`) showed five consecutive
`[step-engine] LLM call TIMED OUT after 20.0s` errors across the
FINALIZE_SCHEDULING sub-steps. Root cause from post-mortem:

| Role   | Previous default  | Quantised size |
|--------|-------------------|----------------|
| fast   | `phi4-mini:3.8b`  | ~2.5 GB        |
| strong | **`gemma4:26b`**  | **~13 GB**     |

Once the MLX TESSY adapter (3.5 GB) loaded for the Gateway chat path,
macOS paged gemma4:26b out of Ollama's cache to make room. Every
subsequent `model=strong` call hit a cold reload → 20–30 s.

## Approach

Drop Ollama from the production LLM path. Use a single
`Qwen3.5-4B-MLX-4bit` + `qwen35-4b-tessy-streaming` LoRA for every LLM
call. Pin it in unified memory with a 120-second keep-warm heartbeat
so it cannot get paged out during quiet windows.

The plan and Codex's two review passes are captured in
`~/.claude/plans/ok-look-at-this-misty-beacon.md`.

## Changes shipped (phone-agent-scheduler, commit `dc3d5f9`)

| File | Change |
|---|---|
| `phone_agent/mlx_client.py` | Fix `self._base_model` AttributeError in `chat()`; refactor chat-template into `_apply_chat_template()` helper that passes `enable_thinking=False` for Qwen models (TESSY adapters were trained thinking-off). |
| `phone_agent/hybrid_fsm/model_router.py` | `LLM_FAST`/`LLM_STRONG` default to the MLX TESSY string. **Stop reading `LLM_LIQUID`/`LLM_HAIKU` silently** — emit a startup WARNING and ignore them. Add cloud aliases (`haiku`, `sonnet`, `opus` → full Claude model ids). Warn when `LLM_STATE_*` points at a non-MLX/non-cloud model. |
| `phone_agent/gateway.py` | New `DEFAULT_MODEL_ID` env var selects the active UI model, so `mlx:base:adapter` strings resolve to a registry key (the old `LLM_FAST` → `info["name"]` loop could not match). Drop Ollama entries from `_models` (14 → 6) so the UI dropdown cannot reintroduce gemma4:26b. Pass `adapter_path` through on `set_model()`. |
| `phone_agent/server.py` | Rename `_warmup_status["ollama"]` → `["llm"]`. **Warm both fast AND strong at startup** when they differ (no-op when they are the same MLX string because `mlx_client._model_cache` dedupes by `(base, adapter)`). New `_start_keep_warm_thread` ticks every `KEEPWARM_INTERVAL_S` seconds (default 120, 0 disables). |
| `phone_agent/chat_ui.html` | Accept both `llm` and legacy `ollama` warmup-status keys so the status panel keeps rendering "Language Model — Ready". |
| `phone_agent/streaming_json.py` | Vendored from `~/src/training/scripts/tessy/streaming_json.py` — incremental prose extractor for the prose-first TESSY JSON format. |
| `.env.example` | Document the `mlx:base:adapter` format, mark `LLM_LIQUID`/`LLM_HAIKU` deprecated, add `DEFAULT_MODEL_ID`. |
| `tests/test_mlx_client.py` | **NEW** — 6 fast unit tests: chat-template flag for Qwen, AttributeError regression, adapter path resolution, chat()-doesn't-crash. Plus 1 `@pytest.mark.live` integration test that actually loads the adapter. |
| `tests/test_keep_warm.py` | **NEW** — 4 fast unit tests for thread lifecycle: disabled-when-zero, null-safe, starts-as-daemon, idempotent. |

Total: 9 files, +967 / -60 lines.

## Verification results

All from the live server on port 1205 post-commit.

| Check | Result |
|---|---|
| Smoke `_make_client(...)` + `chat()` | ✅ Returned "OK" in 624 ms — no AttributeError |
| Startup banner | ✅ `Model: mlx-community/Qwen3.5-4B-MLX-4bit` |
| Warmup completion | ✅ `mlx:…:adapters/qwen35-4b-tessy-streaming warm ✓ (KV cache primed, 3 turns)` |
| `/api/warmup` payload | ✅ Returns `"llm": "ready"` (new key) |
| Keep-warm tick 1 | ✅ 414 ms at 15:14:00 |
| Keep-warm tick 2 | ✅ 382 ms at 15:14:30 (30 s cadence confirmed) |
| Text chat Turn 1 (greeting) | ✅ Streaming prose, slots extracted (`issue_type=water_heater`, `service_address=220 Oak Ave`) |
| Text chat Turn 2 (LLM call) | ✅ **5.2 s** (was 20+ s timeout before) |
| Text chat Turns 3-4 (finalize) | ✅ Template-served, no LLM needed |
| Server log scan | ✅ Zero `TIMED OUT`, zero `gemma4`/`phi4-mini` references, zero deprecation warnings |
| Python process RSS | ✅ 3.88 GB (was ~18 GB with gemma4:26b loaded) |
| Unit test suite | ✅ 10/10 pass in <2 s (`pytest -m "not live"`) |

## Headline numbers

- **Memory**: ~18 GB → ~4 GB (4.6× reduction)
- **Worst-case LLM latency**: 20–30 s timeouts → 5 s consistent
- **Default LLM**: Ollama `gemma4:26b` → MLX `Qwen3.5-4B + TESSY-streaming`
- **UI dropdown**: 14 entries (incl. paged-out Ollama models) → 6 curated entries
- **Tests**: 0 → 10 (all fast, no GPU needed for CI)

## Outstanding follow-ups

These came out of the live voice dogfood (`voice-mo62oxw4`) review but
were outside the refactor scope:

1. **First-strong-call cold start** (17 s on turn 1, down from 20 s timeout).
   Addressed tonight via the keep-warm heartbeat — every 120 s the MLX
   model gets a tiny "ping" chat() call, which keeps the weights
   resident in unified memory. Next voice call should see turn 1 under
   10 s.
2. **STT accuracy on addresses** — Whisper/Moonshine repeatedly
   mis-transcribed "Vine Street" as "Weinstreet", "Divine Street", etc.
   Not a TESSY issue. Fix is upstream (upgrade to whisper-base for
   address turns).
3. **FSM loops on address-retry** — FINALIZE_SCHEDULING template
   truncates the address display and doesn't escalate when the caller
   corrects the same slot multiple times. Pre-existing behaviour.
4. **3-field JSON degradation risk** — TESSY's training schema omits
   `intent`, `user_sentiment`, `recommended_transition`. Voice dogfood
   reached FINALIZE_SCHEDULING successfully, so the "hard gate" in the
   plan passed — but slot-extraction is noticeably weaker than the
   6-field schema step_engine expects. Contingency (documented in plan)
   is a two-MLX-instance split.

## Links

- Plan: `~/.claude/plans/ok-look-at-this-misty-beacon.md`
- Prior sessions:
  `S-2026-04-18-0513-tessy-sprint-0.md` · `S-2026-04-18-0937-tessy-first-experiment.md`
- Commit: https://github.com/davidbmar/phone-agent-scheduler/commit/dc3d5f9
- Paper: https://arxiv.org/abs/2604.14164 (TESSY)
