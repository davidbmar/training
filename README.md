# Phone Agent Training Pipeline

Generate training data, fine-tune local LLMs, and deploy phone agent models that sound like real receptionists.

## What This Is

A complete pipeline for teaching small, fast AI models (3.8B-7B parameters) to answer phones for a plumbing business. Uses **knowledge distillation** — a large teacher model (Claude) generates realistic phone conversations, and small student models learn from those conversations via **LoRA fine-tuning** on Apple Silicon.

The result: models that run locally on a MacBook for $0/call, with receptionist quality approaching cloud-hosted models.

## Quick Start

```bash
# 1. Normalize data and create train/val/test splits
python3 scripts/normalize_and_split.py

# 2. Convert to MLX training format
python3 scripts/convert_to_chat_templates.py -i data/splits/train.json -f mlx -o data/splits/train_mlx.jsonl
python3 scripts/convert_to_chat_templates.py -i data/splits/val.json -f mlx -o data/splits/val_mlx.jsonl

# 3. Fine-tune (requires mlx-lm: pip install mlx-lm)
python -m mlx_lm.lora \
  --model microsoft/phi-4-mini-instruct \
  --data data/splits/ \
  --train \
  --batch-size 2 \
  --lora-rank 8 \
  --iters 600 \
  --adapter-path adapters/phi4-mini
```

## Dataset at a Glance

| Metric | Value |
|--------|-------|
| Total conversations | 170 |
| Training examples (with slot context) | ~1,200+ |
| Slot-specific edge cases | ~100 |
| Problem types | 8 |
| Caller personalities | 7 |
| Conversation paths | 8 |
| Conversation phases / FSM states | 11 / 7 |
| Scheduling mode | **24/7** — always accepts bookings |

## Slot Injection Training

Every training example includes structured context that matches what the model sees in production:

```
[CONTEXT]  — current day/time, available slots, caller mood, 24/7 scheduling mode
[SLOTS]    — 13 tracked values: issue_type, customer_name, date_time, address, etc.
[STATE]    — which FSM state we're in (GREETING, PROBLEM_DETERMINATION, FINALIZE, etc.)
[TASK]     — explicit instruction for this turn ("Read back all booking details")
```

This teaches the model to **use collected information** (never re-ask), **follow the workflow** (right response for the phase), and **always book** (24/7 answering service — never says "we're closed").

See the [Slot Injection Spec](docs/seed/slot_injection_training_spec.md) for the full design, including the 13-slot schema, real production failure examples, and training example format.

## Documentation

| Doc | What You'll Learn |
|-----|-------------------|
| **[Fine-Tuning Guide](docs/fine-tuning-guide.md)** | Start here. Plain-English explanation of MLX, LoRA, GGUF, quantization, unified memory. Full pipeline from training data to deployed model. |
| **[Conversation Phases](docs/phases.md)** | The 11 phases every phone call can contain. Agent behavior, training signal, and evaluation rubrics per phase. |
| **[Training Methodology](docs/training-methodology.md)** | Data generation, stratified splitting, phase balancing, and the validation pipeline. |
| **[Slot Injection Spec](docs/seed/slot_injection_training_spec.md)** | The [CONTEXT] + [SLOTS] + [STATE] + [TASK] system prompt format. 13-slot schema, real failure examples, training data design. |
| **[Training Data Explorer](docs/html/seed-training-pipeline.html)** | Interactive HTML — browse all 170 conversations, filter by phase/problem/personality. |

### HTML Versions (rendered with Afterburner dark theme)

| Page | Link |
|------|------|
| Fine-Tuning Guide | [docs/html/fine-tuning-guide.html](docs/html/fine-tuning-guide.html) |
| Conversation Phases | [docs/html/phases.html](docs/html/phases.html) |
| Training Methodology | [docs/html/training-methodology.html](docs/html/training-methodology.html) |
| Slot Injection Spec | [docs/html/slot-injection-spec.html](docs/html/slot-injection-spec.html) |
| Training Data Explorer | [docs/html/seed-training-pipeline.html](docs/html/seed-training-pipeline.html) |

**Reading order for newcomers:** Fine-Tuning Guide → Phases → Training Methodology → Slot Injection Spec

## Project Structure

```
training/
├── README.md                          ← you are here
├── docs/
│   ├── fine-tuning-guide.md           ← educational guide (MLX, LoRA, GGUF)
│   ├── phases.md                      ← the 11 conversation phases
│   ├── training-methodology.md        ← data generation and splitting
│   ├── seed/
│   │   └── slot_injection_training_spec.md  ← slot context training design
│   └── html/                          ← rendered HTML versions (Afterburner theme)
│       ├── fine-tuning-guide.html
│       ├── phases.html
│       ├── training-methodology.html
│       ├── slot-injection-spec.html
│       └── seed-training-pipeline.html ← interactive data explorer
├── data/
│   ├── scenario_matrix.json           ← 8×7×8 scenario definitions
│   ├── conversations/                 ← raw generated conversations (12 batch files)
│   ├── all_conversations_normalized.json          (170, phase-normalized)
│   ├── training/
│   │   ├── all_with_slots.jsonl       ← 1,210 examples with [CONTEXT]+[SLOTS]+[STATE]+[TASK]
│   │   └── slot_edge_cases.jsonl      ← 100 edge cases (after-hours, corrections, emergencies)
│   ├── splits/                        ← stratified train/val/test splits
│   └── mlx_data/                      ← final merged MLX-ready training files
│       ├── train.jsonl
│       ├── valid.jsonl
│       └── test.jsonl
├── scripts/
│   ├── normalize_and_split.py         ← phase normalization + stratified splitting
│   └── convert_to_chat_templates.py   ← turn-level decomposition + format conversion
├── docs/
│   ├── fine-tuning-guide.md           ← educational guide to the full pipeline
│   ├── phases.md                      ← the 11 conversation phases
│   └── training-methodology.md        ← data generation and splitting methodology
├── adapters/                          ← (created during fine-tuning) LoRA adapter weights
└── models/                            ← (created during fine-tuning) fused GGUF models
```

## Hardware Requirements

- **Apple Silicon Mac** (M1/M2/M3/M4) with 16+ GB unified memory
- Tested on: Apple M3 Pro, 36 GB
- Training time: ~65 minutes for all 3 models
- Disk space: ~30 GB for HuggingFace base weights + ~150 MB for adapters

## The Three Target Models

| Model | Params | Disk | Inference Latency | Why |
|-------|--------|------|------------------|-----|
| **Phi4-mini** (Microsoft) | 3.8B | 2.5 GB | ~2,602ms | Fastest. Benefits most from fine-tuning. |
| **Mistral 7B** (Mistral AI) | 7B | 4.4 GB | ~4,463ms | Current production model. Solid all-rounder. |
| **Gemma4 E2B** (Google) | 7B | 7.2 GB | TBD | Best base quality. Fine-tuning may fix hallucinations. |

All three are fine-tuned on the same training data — only the chat template conversion differs.

## TESSY (Teacher-Student Cooperation Data Synthesis) — `scripts/tessy/`

A second pipeline lives under `scripts/tessy/` that implements the
[TESSY paper](https://arxiv.org/abs/2604.14164) on the same phone-agent
data. Where the original pipeline above does straight self-distillation
on Phi4-mini / Mistral / Gemma4, TESSY is a teacher-student knowledge
distillation that produces a Qwen3.5-4B + LoRA adapter optimised for
streaming prose (response_draft tokens leave the LLM before slot_updates
are even generated, so TTS can start speaking earlier).

**What's here:**

| File / dir | Purpose |
|---|---|
| `scripts/tessy/extract_prompts.py` | Strip assistant turns from `data/mlx_data_slot_rewrite/*.jsonl` to produce prompt-only inputs for synthesis |
| `scripts/tessy/smoke_teacher_only.py` | 5-row Sprint-0 smoke test for any Qwen3.5 MLX model with strict `<think>`-aware JSON extraction |
| `scripts/tessy/streaming_json.py` | Incremental parser that yields `response_draft` chars as they arrive (the prose-first contract). Vendored into `~/src/phone-agent-scheduler/phone_agent/streaming_json.py` for production use |
| `scripts/tessy/json_order.py` | Helper that rewrites the system prompt's "Reply as JSON" example so `response_draft` is the first field |
| `scripts/tessy/generate_teacher_only.py` | Run Qwen3.5-9B alone over a prompt corpus to produce baseline training data + a teacher cache the TESSY pass can reuse |
| `scripts/tessy/generate_tessy_data.py` | The TESSY synthesis loop — student writes prose, teacher (or cached teacher) writes slot_updates, stitched into one row |
| `scripts/tessy/normalize_slots.py` | Slot-value normaliser used by the evaluator (sentinel handling, casefold, address prefix match, etc.) |
| `scripts/tessy/evaluate.py` | Slot-extraction F1 + JSON validity + p50/p95 latency on the 151-row test split |
| `scripts/tessy/phone_dogfood.py` | Replay scripted scenarios against any trained adapter for qualitative dogfood |
| `scripts/tessy/phone_dogfood_streaming.py` | Same but uses `StreamingPhoneJSONParser` and reports time-to-first-prose-token |
| `scripts/tessy/compare_dogfood.py` | Head-to-head report for two adapters' dogfood transcripts |
| `scripts/tessy/run_experiment.sh` | One-shot driver: train all four LoRA variants, then evaluate each |
| `scripts/tessy/scenarios.json` | Six hand-written caller scenarios used in dogfood (routine leak, emergency burst, reschedule, rude caller, confused caller, fast collector) |
| `scripts/tessy/README.md` | Repo-native dependency story (venv setup, model download instructions) |
| `configs/tessy/*.yaml` | LoRA training configs for all four variants (4B/2B × TESSY/Teacher-Only) |
| `requirements-tessy.txt` | Pinned `mlx-lm`, `mlx`, `transformers`, `huggingface-hub`, `jsonschema` versions verified on Apple Silicon Python 3.14 |

**Pipeline at a glance:**

```bash
# 0. (one-time) set up the venv
python3 -m venv .venv-tessy && source .venv-tessy/bin/activate
pip install -r requirements-tessy.txt

# 1. Extract prompt-only rows from the existing slot-rewrite splits
python3 scripts/tessy/extract_prompts.py \
    --input data/mlx_data_slot_rewrite/train.jsonl \
    --output data/tessy/prompts/train.jsonl

# 2. Generate teacher-only baseline (300 rows, ~25 min)
python3 scripts/tessy/generate_teacher_only.py \
    --teacher mlx-community/Qwen3.5-9B-MLX-4bit \
    --prompts data/tessy/prompts/train.jsonl \
    --output  data/tessy/teacher_only/train.jsonl \
    --limit   300 --prose-first

# 3. Run TESSY synthesis using cached teacher (300 rows, ~8 min for 4B)
python3 scripts/tessy/generate_tessy_data.py \
    --student mlx-community/Qwen3.5-4B-MLX-4bit \
    --prompts data/tessy/prompts/train.jsonl \
    --teacher-cache data/tessy/teacher_only/train.jsonl \
    --output  data/tessy/4b_tessy_streaming/train.jsonl \
    --prose-first

# 4. LoRA fine-tune (~22 min on 36 GB M-series)
python3 -m mlx_lm lora -c configs/tessy/qwen35-4b-tessy-streaming.yaml

# 5. Evaluate against the 151-row test split
python3 scripts/tessy/evaluate.py \
    --model mlx-community/Qwen3.5-4B-MLX-4bit \
    --adapter adapters/qwen35-4b-tessy-streaming \
    --test data/mlx_data_slot_rewrite/test.jsonl \
    --label qwen35-4b-tessy-streaming \
    --report data/tessy/eval_report.jsonl
```

**Headline measurements (from `docs/project-memory/sessions/S-2026-04-18-0937-tessy-first-experiment.md`):**

| Variant | Validation loss | Test JSON validity | Slot F1 | False positives |
|---|---:|---:|---:|---:|
| 2B base | — | 59% | 0.000 | 179 |
| 2B TESSY | 1.461 | 98% | 0.036 | 52 |
| 2B Teacher-Only | 1.526 | 100% | 0.047 | 81 |
| 4B base | — | 94% | 0.040 | 97 |
| **4B TESSY (winner)** | **1.497** | **100%** | **0.056** | **68** |
| 4B Teacher-Only | 1.626 | 98% | 0.041 | 94 |

The streaming-prose variant trained later (`qwen35-4b-tessy-streaming`)
got val loss **1.329** — the best of all variants — by emitting the
JSON in `response_draft`-first order.

**Documentation tree:**

- `docs/project-memory/sessions/S-2026-04-18-0513-tessy-sprint-0.md` — Sprint 0 feasibility gate (MLX runtime + smoke + GO/NO-GO per role)
- `docs/project-memory/sessions/S-2026-04-18-0937-tessy-first-experiment.md` — Four LoRA adapters trained + evaluated; first measured TESSY-vs-Teacher-Only delta
- `docs/project-memory/sessions/S-2026-04-19-2028-all-mlx-routing.md` — Integration into `phone-agent-scheduler`: routes every LLM call through the trained adapter, drops Ollama gemma4:26b dependency, eliminates 20 s cold-load timeouts

## Related Projects

- **[phone-agent-scheduler](../phone-agent-scheduler/)** — the production phone agent that consumes these models. Tonight's work routes its Gateway chat, step_engine fast/strong, and warmup all through the `qwen35-4b-tessy-streaming` adapter trained here. See its `phone_agent/mlx_client.py` for the loader and `phone_agent/streaming_json.py` for the prose-streaming parser (vendored from this repo).
- Training data will eventually be copied to `phone-agent-scheduler/training/` once the pipeline is validated
