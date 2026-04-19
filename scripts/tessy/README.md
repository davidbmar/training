# TESSY pipeline

Implements the Teacher–Student Cooperation Data Synthesis framework
(https://arxiv.org/abs/2604.14164) on this repo's phone-agent training data.

See the approved plan at `~/.claude/plans/ok-look-at-this-misty-beacon.md`.

## Sprint 0 scope (current)

Only three artifacts are created in Sprint 0:

- `scripts/tessy/extract_prompts.py` — strips assistant turns from the existing
  slot-rewrite training JSONL, leaving prompt-only rows for teacher/student
  generation.
- `scripts/tessy/smoke_teacher_only.py` — runs a 5-row smoke test on any Qwen3.5
  variant via `--model`. Strips `<think>…</think>` and parses the last valid
  JSON object from the response, validating the
  `{slot_updates, confidence, response_draft}` schema.
- `docs/project-memory/sessions/S-<ts>-tessy-sprint-0.md` — the feasibility
  report with GO/NO-GO per model role.

Sprint 1+ files are **not** created until Sprint 0 passes and the report is
accepted.

## Environment setup

This repository had no `requirements.txt` / `pyproject.toml` before TESSY; the
file `requirements-tessy.txt` at the repo root pins the dependency set used
here. Future sprints must activate this environment rather than rely on the
global site-packages.

```bash
# Create and activate (one time)
python3 -m venv .venv-tessy
source .venv-tessy/bin/activate
pip install --upgrade pip
pip install -r requirements-tessy.txt

# Later sessions
source .venv-tessy/bin/activate
```

The pinned versions have been verified on Darwin arm64 + Python 3.14 + 36 GB
unified memory (Apple Silicon). If Metal initialization fails in a venv, run
the smoke script with the system Python first to isolate whether the issue is
specific to the venv.

## Sprint 0 usage

```bash
# 1. Extract prompt-only rows from the existing training splits
python scripts/tessy/extract_prompts.py \
  --input data/mlx_data_slot_rewrite/train.jsonl \
  --output data/tessy/prompts/train.jsonl

python scripts/tessy/extract_prompts.py \
  --input data/mlx_data_slot_rewrite/valid.jsonl \
  --output data/tessy/prompts/valid.jsonl

python scripts/tessy/extract_prompts.py \
  --input data/mlx_data_slot_rewrite/test.jsonl  \
  --output data/tessy/prompts/test.jsonl

# 2. Smoke test each model variant on 5 prompts
python scripts/tessy/smoke_teacher_only.py \
  --model mlx-community/Qwen3.5-9B-MLX-4bit \
  --prompts data/tessy/prompts/train.jsonl \
  --limit 5

# Repeat for each student size we intend to train
python scripts/tessy/smoke_teacher_only.py --model mlx-community/Qwen3.5-4B-MLX-4bit   --limit 5
python scripts/tessy/smoke_teacher_only.py --model mlx-community/Qwen3.5-2B-MLX-4bit   --limit 5
python scripts/tessy/smoke_teacher_only.py --model mlx-community/Qwen3.5-0.8B-MLX-4bit --limit 5
```

## Verified Qwen3.5 artifact names (from HF, April 2026)

Runtime-thinking family (no separate `-Thinking` repo — thinking is toggled at
call time through the tokenizer's `enable_thinking` chat-template flag):

| Role           | HF upstream repo            | MLX 4-bit conversion                        |
|----------------|-----------------------------|---------------------------------------------|
| Teacher        | `Qwen/Qwen3.5-9B`           | `mlx-community/Qwen3.5-9B-MLX-4bit`         |
| Student (4B)   | `Qwen/Qwen3.5-4B`           | `mlx-community/Qwen3.5-4B-MLX-4bit`         |
| Student (2B)   | `Qwen/Qwen3.5-2B`           | `mlx-community/Qwen3.5-2B-MLX-4bit`         |
| Student (0.8B) | `Qwen/Qwen3.5-0.8B`         | `mlx-community/Qwen3.5-0.8B-MLX-4bit`       |
| Base (Sprint 1+, if boundary classifier used) | `Qwen/Qwen3.5-0.8B-Base` | (no MLX 4-bit at this time; may need local conversion) |

Source: https://huggingface.co/mlx-community (Qwen3.5 collection, verified
April 17 2026). The MLX conversions ship with the upstream chat template
including `<think>…</think>` delimiters; thinking mode defaults on.
