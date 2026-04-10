#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./sprint-parse.sh
source "${SCRIPT_DIR}/sprint-parse.sh"

# Parse --phase argument
PHASE="all"
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --phase) shift; PHASE="${1:-all}"; shift || true ;;
    1|2) PHASE="$arg" ;;
    --force) FORCE=true ;;
  esac
done

# Select agents for this phase
if [ "$PHASE" = "1" ]; then
  LAUNCH_AGENTS=("${PHASE1_AGENTS[@]}")
elif [ "$PHASE" = "2" ]; then
  if [ ${#PHASE2_AGENTS[@]} -eq 0 ]; then
    echo "No Phase 2 agents found. This sprint uses single-phase mode."
    exit 0
  fi
  LAUNCH_AGENTS=("${PHASE2_AGENTS[@]}")
else
  LAUNCH_AGENTS=("${AGENTS[@]}")
fi

# Ensure file descriptor limit is high enough for concurrent agent sessions
MIN_FD=10240
CURRENT_FD=$(ulimit -n)
if [ "$CURRENT_FD" -lt "$MIN_FD" ]; then
  ulimit -n "$MIN_FD" 2>/dev/null || true
  NEW_FD=$(ulimit -n)
  if [ "$NEW_FD" -lt "$MIN_FD" ]; then
    echo "Error: File descriptor limit is ${NEW_FD} (need ${MIN_FD} for ${#LAUNCH_AGENTS[@]} agents)."
    echo "Run 'ulimit -n ${MIN_FD}' before launching, or add it to ~/.zshrc."
    exit 1
  fi
  echo "Raised file descriptor limit: ${CURRENT_FD} → ${NEW_FD}"
fi

SESSION="sprint${SPRINT_NUM}p${PHASE}"
LAUNCH_CMD="${SCRIPT_DIR}/sprint-launch.sh"
SPRINT_NOTES="${ROOT}/Sprint-Notes.md"

# Handle existing session
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Session '$SESSION' already exists."
  echo "  Attach:  tmux attach -t $SESSION"
  echo "  Kill:    tmux kill-session -t $SESSION"
  echo "  Force:   $0 --force"
  if $FORCE; then
    tmux kill-session -t "$SESSION"
    echo "Killed existing session."
  else
    exit 1
  fi
fi

# Initialize Sprint-Notes.md (only for Phase 1 or all)
if [ "$PHASE" = "1" ] || [ "$PHASE" = "all" ]; then
  cat > "$SPRINT_NOTES" <<EOF
# Sprint ${SPRINT_NUM} — Agent Notes

*Started: $(date -u '+%Y-%m-%d %H:%M UTC')*

Phase 1 Agents: ${#PHASE1_AGENTS[@]}
$(printf -- '- %s\n' "${PHASE1_AGENTS[@]}")

Phase 2 Agents: ${#PHASE2_AGENTS[@]}
$([ ${#PHASE2_AGENTS[@]} -gt 0 ] && printf -- '- %s\n' "${PHASE2_AGENTS[@]}" || echo "(none)")

Automated summaries from each agent are appended below as they complete.
EOF
  echo "Created ${SPRINT_NOTES}"
fi

# Create tmux session with first agent tab
first_agent="${LAUNCH_AGENTS[0]}"
tmux new-session -d -s "$SESSION" -n "$first_agent" \
  "unset CLAUDECODE; bash -lc '${LAUNCH_CMD} ${first_agent}; echo; echo === DONE — scroll up to review. This tab stays open. ===; exec bash'"

# Create a tab for each remaining agent
for agent in "${LAUNCH_AGENTS[@]:1}"; do
  tmux new-window -t "$SESSION" -n "$agent" \
    "unset CLAUDECODE; bash -lc '${LAUNCH_CMD} ${agent}; echo; echo === DONE — scroll up to review. This tab stays open. ===; exec bash'"
done

# Select the first tab
tmux select-window -t "$SESSION:0"

NUM=${#LAUNCH_AGENTS[@]}
LAST_IDX=$((NUM - 1))

echo ""
echo "=== Sprint ${SPRINT_NUM} Phase ${PHASE} — ${NUM} agents launched ==="
echo ""
for i in "${!LAUNCH_AGENTS[@]}"; do
  echo "  [$i] ${LAUNCH_AGENTS[$i]}"
done
echo ""
echo "Each agent will:"
echo "  1. Run Claude to implement its brief"
echo "  2. Append its summary to Sprint-Notes.md"
echo "  3. Run tests (npm test)"
echo "  4. Auto-commit if tests pass"
echo ""
echo "Navigation:"
echo "  Ctrl+B then n/p    — next/prev tab"
echo "  Ctrl+B then 0-${LAST_IDX}    — jump to tab by number"
echo "  Ctrl+B then w      — tab picker"
echo "  Ctrl+B then d      — detach (agents keep running)"
echo ""
echo "Lifecycle:"
echo "  tmux attach -t $SESSION       — reattach"
echo "  tmux kill-session -t $SESSION — stop everything"
echo ""
echo "Attaching now..."
exec tmux attach -t "$SESSION"
