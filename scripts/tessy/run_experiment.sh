#!/usr/bin/env bash
# One-shot driver: train the 4 LoRA variants (4B + 2B × TESSY + Teacher-Only)
# and evaluate each on the held-out test split.
#
# Assumes:
#   data/tessy/teacher_only/{train,valid,test}.jsonl exist
#   data/tessy/4b_tessy/{train,valid,test}.jsonl    exist
#   data/tessy/2b_tessy/{train,valid,test}.jsonl    exist
#
# Writes:
#   adapters/qwen35-{4b,2b}-{tessy,teacher-only}-phone/
#   data/tessy/eval_report.jsonl
#
# Re-runnable: training skips if adapter dir already has safetensors.
set -euo pipefail

cd "$(dirname "$0")/../.."

LIMIT_EVAL="${LIMIT_EVAL:-0}"   # 0 = full 151-row test split

train_variant () {
  local cfg="$1"
  local adapter="$2"
  if [ -f "$adapter/adapters.safetensors" ] && [ "${FORCE_TRAIN:-0}" != "1" ]; then
    echo "[skip] $adapter already trained (set FORCE_TRAIN=1 to retrain)"
    return
  fi
  echo "[train] $cfg -> $adapter"
  python3 -m mlx_lm lora -c "$cfg"
}

eval_variant () {
  local model="$1"
  local adapter="$2"
  local label="$3"
  echo "[eval] $label"
  local cmd=(python3 scripts/tessy/evaluate.py
    --model "$model"
    --test data/mlx_data_slot_rewrite/test.jsonl
    --label "$label"
    --report data/tessy/eval_report.jsonl)
  if [ -n "$adapter" ]; then
    cmd+=(--adapter "$adapter")
  fi
  if [ "$LIMIT_EVAL" != "0" ]; then
    cmd+=(--limit "$LIMIT_EVAL")
  fi
  "${cmd[@]}"
}

echo "=== Baselines: untrained base models ==="
eval_variant mlx-community/Qwen3.5-4B-MLX-4bit "" qwen35-4b-base
eval_variant mlx-community/Qwen3.5-2B-MLX-4bit "" qwen35-2b-base

echo
echo "=== Train 4 variants ==="
train_variant configs/tessy/qwen35-4b-tessy.yaml        adapters/qwen35-4b-tessy-phone
train_variant configs/tessy/qwen35-4b-teacher-only.yaml adapters/qwen35-4b-teacher-only-phone
train_variant configs/tessy/qwen35-2b-tessy.yaml        adapters/qwen35-2b-tessy-phone
train_variant configs/tessy/qwen35-2b-teacher-only.yaml adapters/qwen35-2b-teacher-only-phone

echo
echo "=== Eval trained adapters ==="
eval_variant mlx-community/Qwen3.5-4B-MLX-4bit adapters/qwen35-4b-tessy-phone        qwen35-4b-tessy
eval_variant mlx-community/Qwen3.5-4B-MLX-4bit adapters/qwen35-4b-teacher-only-phone qwen35-4b-teacher-only
eval_variant mlx-community/Qwen3.5-2B-MLX-4bit adapters/qwen35-2b-tessy-phone        qwen35-2b-tessy
eval_variant mlx-community/Qwen3.5-2B-MLX-4bit adapters/qwen35-2b-teacher-only-phone qwen35-2b-teacher-only

echo
echo "=== Summary (jq-style view of data/tessy/eval_report.jsonl) ==="
python3 - <<'PY'
import json, os
path = "data/tessy/eval_report.jsonl"
if not os.path.exists(path):
    print("(no report)")
    raise SystemExit
rows = [json.loads(l) for l in open(path) if l.strip()]
# keep only the latest run per label
latest = {}
for r in rows:
    latest[r.get("label", "unknown")] = r
header = f"{'label':40}  {'json_ok':>8}  {'slot_f1':>8}  {'p50_s':>7}  {'p95_s':>7}"
print(header)
print("-" * len(header))
for label, r in sorted(latest.items()):
    print(f"{label:40}  {r['json_valid']:>3}/{r['n_rows']:<3}  "
          f"{r['slot_f1']['f1']:>8.3f}  {r['latency_p50_s']:>7.2f}  {r['latency_p95_s']:>7.2f}")
PY
