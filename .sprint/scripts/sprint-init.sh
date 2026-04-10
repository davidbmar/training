#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./sprint-parse.sh
source "${SCRIPT_DIR}/sprint-parse.sh"

# ── Auto-archive existing sprint brief ─────────────────────────
# On Phase 1 init, archive the current SPRINT_BRIEF.md so it's never lost.
# Archives to .sprint/history/sprint-N-brief.md.
BRIEF_FILE="${ROOT}/SPRINT_BRIEF.md"
HISTORY_DIR="${ROOT}/.sprint/history"
if [ -f "$BRIEF_FILE" ] && [ -d "$(dirname "$HISTORY_DIR")" ]; then
  mkdir -p "$HISTORY_DIR"
  ARCHIVE_FILE="${HISTORY_DIR}/sprint-${SPRINT_NUM}-brief.md"
  if [ ! -f "$ARCHIVE_FILE" ]; then
    cp "$BRIEF_FILE" "$ARCHIVE_FILE"
    echo "[archive] SPRINT_BRIEF.md → .sprint/history/sprint-${SPRINT_NUM}-brief.md"
    echo ""
  fi
fi

# Determine which phase to initialize
PHASE="${1:-1}"

if [ "$PHASE" = "1" ] || [ "$PHASE" = "all" ]; then
  INIT_AGENTS=("${PHASE1_AGENTS[@]}")
  echo "=== Sprint ${SPRINT_NUM} — Initializing ${#INIT_AGENTS[@]} Phase 1 agents ==="
elif [ "$PHASE" = "2" ]; then
  INIT_AGENTS=("${PHASE2_AGENTS[@]}")
  if [ ${#INIT_AGENTS[@]} -eq 0 ]; then
    echo "No Phase 2 agents found in SPRINT_BRIEF.md"
    echo "This sprint may use the single-phase model (all agents are Phase 1)."
    exit 0
  fi
  echo "=== Sprint ${SPRINT_NUM} — Initializing ${#INIT_AGENTS[@]} Phase 2 agents ==="
else
  echo "Usage: sprint-init.sh [1|2|all]"
  echo "  1   — Initialize Phase 1 agents only (default)"
  echo "  2   — Initialize Phase 2 agents only (run after Phase 1 merges)"
  echo "  all — Initialize all agents (legacy single-phase mode)"
  exit 1
fi

echo ""

mkdir -p "${SPRINT_BASE}"

# ── Find previous sprint summary ──────────────────────────────────
# Look for the most recent PROJECT_STATUS_*.md to give agents context
# about what the previous sprint accomplished.
PREV_SPRINT_SUMMARY=""
PREV_STATUS_FILE=""

# Check for a "Previous Sprint" section in the sprint brief meta block first
MANUAL_PREV=$(echo "$SPRINT_META" | awk '
  /^Previous Sprint/ { found=1; next }
  /^[A-Z]/ { if (found) exit }
  found { print }
')

if [ -n "$(echo "$MANUAL_PREV" | tr -d '[:space:]')" ]; then
  PREV_SPRINT_SUMMARY="$MANUAL_PREV"
  echo "[context] Using 'Previous Sprint' section from SPRINT_BRIEF.md"
else
  # Auto-detect: find the latest PROJECT_STATUS file
  PREV_STATUS_FILE=$(find "${ROOT}/docs" -maxdepth 1 -name 'PROJECT_STATUS_*.md' 2>/dev/null | sort -r | head -1)
  if [ -n "$PREV_STATUS_FILE" ] && [ -f "$PREV_STATUS_FILE" ]; then
    PREV_SPRINT_SUMMARY=$(cat "$PREV_STATUS_FILE")
    echo "[context] Found previous sprint summary: $(basename "$PREV_STATUS_FILE")"
  fi
fi

for agent in "${INIT_AGENTS[@]}"; do
  WT="${SPRINT_BASE}/${agent}"

  # Create worktree if needed
  WT_ABS="$(cd "$WT" 2>/dev/null && pwd -P || echo "$WT")"
  if git worktree list | awk '{print $1}' | grep -qxF "$WT_ABS"; then
    echo "[exists]  ${agent}"
  elif [ -d "${WT}" ]; then
    echo "[error]   Directory exists but not a worktree: ${WT}"
    echo "          Remove it manually and rerun."
    exit 1
  else
    # If branch exists from a prior sprint (already merged), clean it up
    if git rev-parse --verify "${agent}" >/dev/null 2>&1; then
      if git merge-base --is-ancestor "${agent}" main 2>/dev/null; then
        # Branch is merged — safe to delete and recreate
        # First remove any stale worktree pointing to this branch
        stale_wt=$(git worktree list | grep "\[${agent}\]" | awk '{print $1}')
        if [ -n "$stale_wt" ]; then
          git worktree remove "$stale_wt" --force 2>/dev/null || true
          echo "[cleanup] Removed stale worktree: ${stale_wt}"
        fi
        git branch -D "${agent}" 2>/dev/null || true
        echo "[cleanup] Deleted stale branch '${agent}' (was merged in a prior sprint)"
      else
        echo "[error]   Branch '${agent}' exists with unmerged commits."
        echo "          Delete it manually: git branch -D ${agent}"
        exit 1
      fi
    fi
    git worktree add "${WT}" -b "${agent}"
    # Symlink .venv so agents can run tests in the worktree
    if [ -d "${ROOT}/.venv" ] && [ ! -e "${WT}/.venv" ]; then
      ln -sf "${ROOT}/.venv" "${WT}/.venv"
    fi
    # Symlink node_modules if present (JS projects)
    if [ -d "${ROOT}/node_modules" ] && [ ! -e "${WT}/node_modules" ]; then
      ln -sf "${ROOT}/node_modules" "${WT}/node_modules"
    fi
    echo "[created] ${agent}"
  fi

  # Write per-agent AGENT_BRIEF.md (with role profile + sprint-level constraints prepended)
  brief_content=$(get_agent_brief "$agent")
  agent_role=$(get_agent_role "$agent")

  # Locate role profile — check consumer project's .sprint/roles/ first, then framework toolkit/roles/
  role_file=""
  if [ -f "${ROOT}/.sprint/roles/${agent_role}.md" ]; then
    role_file="${ROOT}/.sprint/roles/${agent_role}.md"
  elif [ -f "${SCRIPT_DIR}/../roles/${agent_role}.md" ]; then
    role_file="${SCRIPT_DIR}/../roles/${agent_role}.md"
  elif [ -f "${SCRIPT_DIR}/roles/${agent_role}.md" ]; then
    role_file="${SCRIPT_DIR}/roles/${agent_role}.md"
  fi

  {
    echo "${agent} — Sprint ${SPRINT_NUM}"
    echo ""
    # Prepend role profile if found
    if [ -n "$role_file" ]; then
      cat "$role_file"
      echo ""
      echo "---"
      echo ""
    elif [ "$agent_role" != "implementer" ]; then
      echo "Warning: Role profile '${agent_role}' not found. Using default behavior."
      echo ""
    fi
    # Inject previous sprint summary so agents know what just shipped
    if [ -n "$(echo "$PREV_SPRINT_SUMMARY" | tr -d '[:space:]')" ]; then
      echo "Previous Sprint Summary"
      echo "─────────────────────────────────────────"
      echo "$PREV_SPRINT_SUMMARY"
      echo "─────────────────────────────────────────"
      echo ""
    fi
    # Inject sprint-level Goal + Constraints (not Merge Order/Verification)
    if [ -n "$(echo "$AGENT_META" | tr -d '[:space:]')" ]; then
      echo "Sprint-Level Context"
      echo "$AGENT_META"
      echo ""
    fi
    echo "$brief_content"
  } > "${WT}/AGENT_BRIEF.md"
  echo "          -> AGENT_BRIEF.md written (role: ${agent_role})"
done

echo ""
echo "Worktrees created under: ${SPRINT_BASE}"
echo ""
if [ "$PHASE" = "1" ] || [ "$PHASE" = "all" ]; then
  echo "Next: ./.sprint/scripts/sprint-tmux.sh"
elif [ "$PHASE" = "2" ]; then
  echo "Next: ./.sprint/scripts/sprint-tmux.sh --phase 2"
fi
