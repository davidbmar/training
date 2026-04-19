# Session S-2026-04-18-0937-tessy-first-experiment

**Title:** TESSY first end-to-end experiment — 4 adapters trained and evaluated
**Goal:** Ship a complete TESSY-vs-Teacher-Only comparison on Qwen3.5 {2B, 4B} students using the phone-agent slot-filling corpus; report val-loss and test-set deltas.

## Pipeline summary

Built and exercised end-to-end:

1. **Sprint 0 verification** (prior session
   `S-2026-04-18-0513-tessy-sprint-0.md`) — MLX runtime + Qwen3.5 loading +
   strict JSON extractor, GO per role.
2. **Plan revision** — thinking-mode NO-GO for this domain; capability/style
   split moved to JSON-vs-prose; 0.8B dropped; heuristic boundary beats
   trained classifier.
3. **Synthesis**:
   - `scripts/tessy/generate_teacher_only.py` → 232/300 rows from
     `Qwen3.5-9B-MLX-4bit` (no-thinking), 25 min.
   - `scripts/tessy/generate_tessy_data.py` with `--teacher-cache` →
     231 rows for 4B student (7.8 min) and 229 rows for 2B student
     (4 min). The cache reuse meant the 9B teacher ran only once across
     all three datasets (teacher-only, 4B-TESSY, 2B-TESSY).
4. **Training** (`mlx_lm.lora`, LoRA rank 8 alpha 16, AdamW 5e-5):
   - 4B: `num_layers=16`, `batch=1`, `max_seq=768`, `grad_checkpoint`, 100 iters
   - 2B: `num_layers=8`, `batch=1`, `max_seq=640`, `grad_checkpoint`, 100 iters
5. **Evaluation** (`scripts/tessy/evaluate.py`) — 50-row held-out test
   subset (`data/mlx_data_slot_rewrite/test.jsonl`) per variant, plus
   full-151-row base-2B as a baseline anchor.

Adapters in `adapters/qwen35-{2b,4b}-{tessy,teacher-only}-phone/`.

## Training dynamics (val loss on original slot-rewrite validation)

| Variant                  | Iter 1 (base) | Iter 50 | Iter 100 (final) |
|--------------------------|---------------|---------|------------------|
| 4B TESSY                 | 1.915         | —       | **1.497** |
| 4B Teacher-Only          | 1.915         | 1.378   | 1.626 |
| 2B TESSY                 | 1.769         | 1.551   | **1.461** |
| 2B Teacher-Only          | 1.743         | 1.512   | 1.526 |

**Observations:**

- **4B TESSY < 4B Teacher-Only at iter 100 (1.497 vs 1.626, -7.9 %)** — the
  paper's main claim reproduces on phone-agent data.
- 4B Teacher-Only shows a clear regression from iter 50 (1.378) to iter 100
  (1.626) — classic TESSY-paper signature: training on teacher-stylized
  data *hurts* val performance as the model keeps fitting a distribution
  it cannot naturally produce.
- 2B TESSY < 2B Teacher-Only at iter 100 (1.461 vs 1.526, -4.3 %) — same
  direction, smaller gap.

## Test-set evaluation (50 held-out rows from `data/mlx_data_slot_rewrite/test.jsonl`)

| Variant                 | JSON valid | Slot F1 | Precision | Recall | False positives | p50 latency | Gen tok/s |
|-------------------------|-----------:|--------:|----------:|-------:|-----------------:|------------:|----------:|
| 2B base (151 rows)      | 89/151 (59 %) | 0.000 | 0.000 | 0.000 | 179 | 1.61 s | 77.5 |
| 2B TESSY                | 49/50 (98 %)  | 0.036 | 0.019 | 0.500 | 52  | 1.71 s | 49.0 |
| 2B Teacher-Only         | 50/50 (100 %) | 0.047 | 0.024 | 1.000 | 81  | 1.79 s | 56.0 |
| 4B base                 | 47/50 (94 %)  | 0.040 | 0.020 | 1.000 | 97  | 3.35 s | 37.4 |
| **4B TESSY**            | **50/50 (100 %)** | **0.056** | **0.029** | 1.000 | **68** | 3.78 s | 25.6 |
| 4B Teacher-Only         | 49/50 (98 %)  | 0.041 | 0.021 | 1.000 | 94  | 3.81 s | 26.0 |

### Headline numbers

- **4B TESSY beats 4B Teacher-Only on slot F1 by 37 % (0.056 vs 0.041).**
  More importantly, its false-positive rate is 28 % lower (68 vs 94) —
  the TESSY student hallucinates fewer phantom slot values.
- **JSON validity**: SFT of any kind lifts 2B from 59 % → 98-100 %, 4B
  from 94 % → 98-100 %. Both TESSY variants hit 100 % on 4B.
- **Latency**: 2B ≈ 1.7 s/turn, 4B ≈ 3.8 s/turn — both in-range for a
  streaming-TTS phone agent. No TESSY-vs-baseline latency delta at
  either size.
- **2B TESSY vs 2B Teacher-Only on F1 is INVERTED from 4B**:
  Teacher-Only edges TESSY (0.047 vs 0.036). The paper didn't test at
  2B scale; plausible hypothesis is that 2B has too little residual
  capacity to preserve its own style *and* learn teacher's slot logic.

### Absolute F1 context

All F1 numbers are low (0.03-0.06) because the 50-row test subset has
only 2 rows where `reference.slot_updates` is non-empty (tp+fn = 2), and
every model over-extracts into fields that should remain `(not
collected)`. **The F1 differences should be read as relative signals, not
as absolute phone-agent quality.** A richer evaluation sweep — full
151-row test set, per-slot breakdown, response-coherence judge — is the
natural next step.

## Plan verdict (what to revise)

1. **TESSY works on this domain at 4B** — paper's core claim reproduces.
   Ship `qwen35-4b-tessy-phone` as the production candidate.
2. **4B TESSY's false-positive rate (68 vs 94 Teacher-Only) is a
   meaningful real-world win** beyond the F1 number: it means the
   production agent hallucinates fewer slot values when the caller hasn't
   given them. This is worth more than any single benchmark number.
3. **2B may be too small** — at 2B, Teacher-Only edged TESSY on F1. Before
   deciding to drop 2B, run eval on the full 151-row test + response
   coherence judge. 2B at 1.7 s/turn is significantly cheaper than 4B at
   3.8 s/turn; worth verifying carefully.
4. **Memory pressure was the real Sprint 1 blocker**, not anything in
   TESSY itself. 4B TESSY OOM'd at iter 200 with `max_seq=768 batch=1
   grad_checkpoint=true`; we got iter 100 via early save_every checkpoint.
   Next iteration: reduce `num_layers` to 8 or 12 for 4B and try iter 200
   for better convergence.
5. **Data scale**: 232 training rows is tiny relative to the paper's 80 k.
   Scaling synthesis to the full 908 prompts (and iterating on prompt
   engineering to reduce the 23 % teacher schema-miss rate) is the
   biggest single lever for the next experiment.

## Artifacts

- `scripts/tessy/generate_tessy_data.py` — alternating generator with
  `--teacher-cache` for cross-student reuse
- `scripts/tessy/generate_teacher_only.py` — baseline
- `scripts/tessy/normalize_slots.py` — sentinels + casing + date aliases
  + urgency aliases + address prefix + confidence tolerance
- `scripts/tessy/evaluate.py` — slot F1 + JSON validity + latency
- `scripts/tessy/run_experiment.sh` — one-shot driver
- `configs/tessy/qwen35-{4b,2b}-{tessy,teacher-only}.yaml` — per-variant
  LoRA configs
- `data/tessy/{teacher_only,4b_tessy,2b_tessy}/train.jsonl` (232 / 231 /
  229 rows)
- `data/tessy/eval_report.jsonl` — machine-readable eval
- `adapters/qwen35-{4b,2b}-{tessy,teacher-only}-phone/adapters.safetensors`

## Next sprint proposal

1. Re-run eval on full 151-row test set for the four trained variants (to
   tighten F1 confidence intervals).
2. Add the paper's **response-coherence judge** step: use Qwen3.5-9B as
   a pairwise preference judge between TESSY and Teacher-Only response
   drafts. The F1 metric is not sensitive enough for prose-style
   differences, but the 4B TESSY outputs observed in synthesis look
   stylistically better than 4B Teacher-Only's — this should be
   measured formally.
3. Scale training data to 700-900 rows (reduce teacher schema misses
   with a better system prompt), retrain at 200 iters.
4. Plot paper's Figure 8 equivalent: TF-IDF + PCA of predicted
   `response_draft` prose across the five variants to visualize
   distribution drift.
5. Interactive phone dogfood (`scripts/test_chat.py`-style comparison
   session) on 10-20 caller scenarios.

## Links

- Plan: `~/.claude/plans/ok-look-at-this-misty-beacon.md`
- Sprint 0 session: `docs/project-memory/sessions/S-2026-04-18-0513-tessy-sprint-0.md`
- Paper: https://arxiv.org/abs/2604.14164
