#!/usr/bin/env bash
# toolkit/brief/brief-gen.sh — Modular sprint brief generator
#
# 3-phase pipeline:
#   Phase A: LLM plans sprint goal + agent roster
#   Phase B: LLM generates per-agent task sections in batches
#   Phase C: Scripts assemble constraints, phase2 agents, merge order
#
# Usage:
#   ./brief-gen.sh --sprint N --output PATH [--root PATH]
#
# Reads project config from .sprint/config/ (created by toolkit/setup.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="${SCRIPT_DIR}/modules"

# Resolve ROOT: when installed at .sprint/scripts/brief/, go up 3 levels
# When run from toolkit/brief/, go up 2 levels
if [ -d "$SCRIPT_DIR/../../.." ] && [ -f "$SCRIPT_DIR/../sprint-merge.sh" ]; then
  ROOT="${ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
else
  ROOT="${ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
fi

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SPRINT_NUM=""
OUTPUT_FILE=""

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --sprint)  shift; SPRINT_NUM="${1:-}"; shift ;;
    --output)  shift; OUTPUT_FILE="${1:-}"; shift ;;
    --root)    shift; ROOT="${1:-$ROOT}"; shift ;;
    *)         shift ;;
  esac
done

if [ -z "$SPRINT_NUM" ]; then
  echo "ERROR: --sprint NUMBER required" >&2; exit 1
fi
if [ -z "$OUTPUT_FILE" ]; then
  echo "ERROR: --output PATH required" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# Project config
# ---------------------------------------------------------------------------
CONFIG_DIR="${ROOT}/.sprint/config"
export PROJECT_NAME="${PROJECT_NAME:-$(basename "$ROOT")}"
export ROOT SPRINT_NUM CONFIG_DIR
export LLM_CALL="${SCRIPT_DIR}/llm-call.sh"
export SCRIPT_DIR MODULE_DIR

# Validate config exists
if [ ! -d "$CONFIG_DIR" ]; then
  echo "ERROR: .sprint/config/ not found. Run toolkit/setup.sh first." >&2
  exit 1
fi

# Source project-specific brief config (if any)
if [ -f "${CONFIG_DIR}/brief-config.sh" ]; then
  source "${CONFIG_DIR}/brief-config.sh"
fi

# Read config files into env vars for modules
export PHASES_FILE="${CONFIG_DIR}/phases.md"
export FILE_CONVENTIONS="${CONFIG_DIR}/file-conventions.md"
export CONSTRAINTS_FILE="${CONFIG_DIR}/constraints.md"
export PHASE2_AGENTS_FILE="${CONFIG_DIR}/phase2-agents.md"
export CAPABILITIES_FILE="${CONFIG_DIR}/capabilities-built.md"

# Auto-discover previous status doc
PREV_STATUS=""
for f in "${ROOT}"/docs/PROJECT_STATUS_*.md; do
  [ -f "$f" ] && PREV_STATUS="$f"
done
export PREV_STATUS

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
now_s() { date +%s; }

format_duration() {
  local secs=$1
  if [ "$secs" -lt 60 ]; then
    echo "${secs}s"
  elif [ "$secs" -lt 3600 ]; then
    echo "$((secs / 60))m $((secs % 60))s"
  else
    echo "$((secs / 3600))h $((secs % 3600 / 60))m $((secs % 60))s"
  fi
}

# ---------------------------------------------------------------------------
# Module runner
# ---------------------------------------------------------------------------
TMPDIR=$(mktemp -d)
METRICS_LOG="${ROOT}/.brief-gen-metrics.txt"
LLM_CALLS=0
LLM_FAILURES=0
TOTAL_START=$(now_s)

# Write metrics header
cat > "$METRICS_LOG" <<EOF
# Brief Generation Metrics — Sprint ${SPRINT_NUM}
# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Project: ${PROJECT_NAME}

EOF

run_module() {
  local module_name="$1"
  local module_path="${MODULE_DIR}/${module_name}"
  local output_path="${TMPDIR}/${module_name%.sh}.md"

  if [ ! -x "$module_path" ]; then
    echo "  [SKIP] ${module_name} — not executable" >&2
    echo "" > "$output_path"
    return 0
  fi

  local start_s
  start_s=$(now_s)
  echo -n "  [RUN]  ${module_name}..." >&2

  if "$module_path" > "$output_path" 2>>"${TMPDIR}/${module_name%.sh}.log"; then
    local elapsed=$(( $(now_s) - start_s ))
    local lines
    lines=$(wc -l < "$output_path" | tr -d ' ')
    echo " OK (${elapsed}s, ${lines} lines)" >&2
    echo "module	${module_name}	${elapsed}s	${lines} lines	OK" >> "$METRICS_LOG"
  else
    local elapsed=$(( $(now_s) - start_s ))
    echo " FAILED (${elapsed}s)" >&2
    echo "module	${module_name}	${elapsed}s	0 lines	FAILED" >> "$METRICS_LOG"
    LLM_FAILURES=$((LLM_FAILURES + 1))
    echo "" > "$output_path"
  fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo "" >&2
echo "  ┌─────────────────────────────────────────────┐" >&2
echo "  │  Brief Generator — Sprint ${SPRINT_NUM}              │" >&2
echo "  └─────────────────────────────────────────────┘" >&2
echo "" >&2
echo "  Project:  ${PROJECT_NAME}" >&2
echo "  Config:   ${CONFIG_DIR}" >&2
echo "  Output:   ${OUTPUT_FILE}" >&2
echo "" >&2

# ---------------------------------------------------------------------------
# Phase A: Sprint planning (LLM)
# ---------------------------------------------------------------------------
echo "  ── Phase A: Sprint Planning ──" >&2
run_module "01-sprint-plan.sh"

# Export roster for subsequent phases
ROSTER_FILE="${TMPDIR}/01-sprint-plan.roster.tsv"
export ROSTER_FILE
export SPRINT_GOAL_FILE="${TMPDIR}/01-sprint-plan.goal.txt"

# ---------------------------------------------------------------------------
# Phase B: Agent detail generation (LLM, batched)
# ---------------------------------------------------------------------------
echo "" >&2
echo "  ── Phase B: Agent Details ──" >&2
run_module "02-agent-batch.sh"

# ---------------------------------------------------------------------------
# Phase C: Assembly (deterministic)
# ---------------------------------------------------------------------------
echo "" >&2
echo "  ── Phase C: Assembly ──" >&2
run_module "03-phase2-agents.sh"
run_module "04-constraints.sh"
run_module "05-merge-order.sh"

# ---------------------------------------------------------------------------
# Assemble final brief
# ---------------------------------------------------------------------------
echo "" >&2
echo "  ── Assembling Brief ──" >&2

{
  # Header
  echo "# Sprint ${SPRINT_NUM}"
  echo ""

  # Sprint goal (from Phase A)
  if [ -f "${TMPDIR}/01-sprint-plan.md" ] && [ -s "${TMPDIR}/01-sprint-plan.md" ]; then
    cat "${TMPDIR}/01-sprint-plan.md"
  else
    echo "Goal"
    echo "- TODO: Define sprint goal"
    echo ""
  fi

  # Constraints (from Phase C)
  if [ -f "${TMPDIR}/04-constraints.md" ] && [ -s "${TMPDIR}/04-constraints.md" ]; then
    cat "${TMPDIR}/04-constraints.md"
  fi

  # Merge order (from Phase C)
  if [ -f "${TMPDIR}/05-merge-order.md" ] && [ -s "${TMPDIR}/05-merge-order.md" ]; then
    cat "${TMPDIR}/05-merge-order.md"
  fi

  echo "Merge Verification"
  # Try to detect test command from .sprint/config.sh
  if [ -f "${ROOT}/.sprint/config.sh" ]; then
    TEST_CMD=$(grep -E '^DEFAULT_TEST_CMD=' "${ROOT}/.sprint/config.sh" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "")
    if [ -n "$TEST_CMD" ]; then
      echo "- ${TEST_CMD}"
    else
      echo "- npm test"
    fi
  else
    echo "- npm test"
  fi
  echo ""

  # Agent sections (from Phase B)
  if [ -f "${TMPDIR}/02-agent-batch.md" ] && [ -s "${TMPDIR}/02-agent-batch.md" ]; then
    cat "${TMPDIR}/02-agent-batch.md"
  fi

  # Phase 2 agents (from Phase C, optional)
  if [ -f "${TMPDIR}/03-phase2-agents.md" ] && [ -s "${TMPDIR}/03-phase2-agents.md" ]; then
    cat "${TMPDIR}/03-phase2-agents.md"
  fi
} > "$OUTPUT_FILE"

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
echo "" >&2
echo "  ── Validation ──" >&2

AGENT_COUNT=$(grep -c '^## agent' "$OUTPUT_FILE" 2>/dev/null || echo "0")
LINE_COUNT=$(wc -l < "$OUTPUT_FILE" | tr -d ' ')
HAS_GOAL=$(grep -c '^Goal' "$OUTPUT_FILE" 2>/dev/null || echo "0")
HAS_MERGE=$(grep -c '^Merge Order' "$OUTPUT_FILE" 2>/dev/null || echo "0")
HAS_CONSTRAINTS=$(grep -c '^Constraints' "$OUTPUT_FILE" 2>/dev/null || echo "0")

VALID=true
if [ "$AGENT_COUNT" -lt 1 ]; then
  echo "  [WARN] No agents found in brief" >&2
  VALID=false
fi
if [ "$LINE_COUNT" -lt 20 ]; then
  echo "  [WARN] Brief is very short (${LINE_COUNT} lines)" >&2
  VALID=false
fi
if [ "$HAS_GOAL" -lt 1 ]; then
  echo "  [WARN] Missing Goal section" >&2
fi
if [ "$HAS_MERGE" -lt 1 ]; then
  echo "  [WARN] Missing Merge Order section" >&2
fi

echo "  Agents: ${AGENT_COUNT}" >&2
echo "  Lines:  ${LINE_COUNT}" >&2
echo "  Valid:  ${VALID}" >&2

# ---------------------------------------------------------------------------
# Final metrics
# ---------------------------------------------------------------------------
TOTAL_ELAPSED=$(( $(now_s) - TOTAL_START ))

cat >> "$METRICS_LOG" <<EOF

# Summary
total_duration	$(format_duration $TOTAL_ELAPSED)
agents	${AGENT_COUNT}
lines	${LINE_COUNT}
llm_failures	${LLM_FAILURES}
valid	${VALID}
EOF

echo "" >&2
echo "  ┌─────────────────────────────────────────────┐" >&2
echo "  │  Brief Generated ($(format_duration $TOTAL_ELAPSED))                   │" >&2
echo "  └─────────────────────────────────────────────┘" >&2
echo "" >&2
echo "  Output:  ${OUTPUT_FILE}" >&2
echo "  Agents:  ${AGENT_COUNT}" >&2
echo "  Lines:   ${LINE_COUNT}" >&2
echo "  Metrics: ${METRICS_LOG}" >&2
echo "" >&2

# Cleanup
rm -rf "$TMPDIR"
