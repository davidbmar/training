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

## Related Projects

- **[phone-agent-scheduler](../phone-agent-scheduler/)** — the production phone agent that uses these models
- Training data will eventually be copied to `phone-agent-scheduler/training/` once the pipeline is validated
