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
| Training examples (turn-level) | 922 |
| Validation examples | 159 |
| Test examples (held out) | 145 |
| Problem types | 8 |
| Caller personalities | 7 |
| Conversation paths | 8 |
| Conversation phases | 11 |

## Documentation

| Doc | What You'll Learn |
|-----|-------------------|
| **[Fine-Tuning Guide](docs/fine-tuning-guide.md)** | Start here. Plain-English explanation of every concept: MLX, LoRA, GGUF, quantization, unified memory. Written for someone new to ML fine-tuning. Covers the full pipeline from training data to deployed model. |
| **[Conversation Phases](docs/phases.md)** | The 11 phases every phone call can contain (greeting, problem determination, solution proposal, etc.). What the agent should do in each phase, what we train for, and how we evaluate quality. |
| **[Training Methodology](docs/training-methodology.md)** | How the data was generated, why we split 75/12.5/12.5, how stratified splitting works, phase balancing strategy, and the validation pipeline. |
| **[Training Pipeline Explorer](docs/html/seed-training-pipeline.html)** | Interactive HTML page — browse all 170 conversations, filter by phase/problem/personality, view transcripts, see distribution stats. Open in a browser. |
| **[Fine-Tuning Guide (HTML)](docs/html/fine-tuning-guide.html)** | Beautiful rendered version of the fine-tuning guide with diagrams, glossary cards, and the full pipeline walkthrough. |

**Reading order for newcomers:** Fine-Tuning Guide → Phases → Training Methodology

## Project Structure

```
training/
├── README.md                          ← you are here
├── docs/html/
│   ├── seed-training-pipeline.html    ← interactive data explorer (open in browser)
│   └── fine-tuning-guide.html         ← rendered fine-tuning guide
├── data/
│   ├── scenario_matrix.json           ← 8×7×8 scenario definitions
│   ├── conversations/                 ← raw generated conversations (12 batch files)
│   │   ├── batch_01.json ... batch_05.json       (original 100)
│   │   ├── batch_06_hard.json, batch_07_hard.json (30 hard cases)
│   │   └── batch_08-12_*.json                     (40 phase-targeted)
│   ├── all_conversations_normalized.json          (170, phase-normalized)
│   └── splits/
│       ├── train.json / train.jsonl   ← 128 conversations
│       ├── val.json / val.jsonl       ← 21 conversations
│       ├── test.json / test.jsonl     ← 21 conversations (held out)
│       ├── train_mlx.jsonl            ← 922 turn-level examples (MLX format)
│       ├── val_mlx.jsonl              ← 159 turn-level examples
│       └── test_mlx.jsonl             ← 145 turn-level examples
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
