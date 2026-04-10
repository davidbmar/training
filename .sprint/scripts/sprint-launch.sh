#!/usr/bin/env bash
set -euo pipefail

# Allow launching Claude from within a parent Claude session (e.g. via tmux)
unset CLAUDECODE 2>/dev/null || true

if [ $# -ne 1 ]; then
  echo "Usage: scripts/sprint-launch.sh <agent-name>"
  exit 1
fi

AGENT="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./sprint-parse.sh
source "${SCRIPT_DIR}/sprint-parse.sh"

WT="${SPRINT_BASE}/${AGENT}"
PROMPT_FILE="${SCRIPT_DIR}/CLAUDE_RUN_PROMPT.txt"
SPRINT_NOTES="${ROOT}/Sprint-Notes.md"

if [ ! -d "${WT}" ]; then
  echo "Worktree not found: ${WT}"
  echo "Run: ./scripts/sprint-init.sh"
  exit 1
fi

if [ ! -f "${PROMPT_FILE}" ]; then
  echo "Prompt file not found: ${PROMPT_FILE}"
  exit 1
fi

PROMPT="$(cat "${PROMPT_FILE}")"

cd "${WT}"
echo "=== [$AGENT] Sprint ${SPRINT_NUM} — Launching Claude in: ${WT} ==="

# --- Phase 1: Run Claude agent and capture output ---
OUTPUT_FILE="${WT}/.claude-output.txt"
# 45-minute timeout prevents indefinite hangs (SSH, MCP plugin fetch, etc.)
# NOTE: GNU timeout/gtimeout causes SIGSTOP on Claude processes in tmux sessions
# (process group signal handling conflict). Use a background PID + sleep approach instead.
AGENT_TIMEOUT=${AGENT_TIMEOUT:-2700}

set +e
claude --dangerously-skip-permissions -p "$PROMPT" > "$OUTPUT_FILE" 2>&1 &
CLAUDE_PID=$!

# Background watchdog: kill Claude if it exceeds the timeout
(
  sleep "$AGENT_TIMEOUT"
  if kill -0 "$CLAUDE_PID" 2>/dev/null; then
    echo "=== [$AGENT] Claude TIMED OUT after ${AGENT_TIMEOUT}s — sending SIGTERM ==="
    kill "$CLAUDE_PID" 2>/dev/null
    sleep 5
    kill -9 "$CLAUDE_PID" 2>/dev/null
  fi
) &
WATCHDOG_PID=$!

wait "$CLAUDE_PID"
CLAUDE_EXIT=$?

# Clean up watchdog
kill "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null
set -e

echo ""
echo "=== [$AGENT] Claude finished (exit $CLAUDE_EXIT) ==="

# --- Phase 2: Append summary to Sprint-Notes.md ---
{
  echo ""
  echo "---"
  echo ""
  echo "## ${AGENT}"
  echo ""
  echo "*Completed: $(date -u '+%Y-%m-%d %H:%M UTC')*"
  echo ""
  # Extract the summary section (everything after the last "Files changed" heading)
  # If that's not found, include the last 60 lines as a fallback
  if grep -qn "Files changed" "$OUTPUT_FILE"; then
    sed -n '/Files changed/,$p' "$OUTPUT_FILE" | tail -200
  else
    echo '```'
    tail -60 "$OUTPUT_FILE"
    echo '```'
  fi
  echo ""
} >> "$SPRINT_NOTES"

echo "=== [$AGENT] Summary appended to Sprint-Notes.md ==="

# --- Phase 3: Ensure Claude's work is committed ---
# Claude agents run their own tests and commit during execution. This phase
# catches any uncommitted changes (e.g., if Claude forgot to commit or made
# late changes). No npm test here — sprint-run.sh runs the authoritative
# test suite after merging, which avoids 16+ concurrent test runs hammering
# Postgres and causing the system to stall.
echo ""
echo "=== [$AGENT] Checking for uncommitted work ==="

git add -A
if git diff --cached --quiet; then
  echo "All work already committed by Claude."
else
  echo "Found uncommitted changes — committing now."
  SESSION_ID="S-$(date -u +%Y-%m-%d-%H%M)-${AGENT}"
  git commit -m "$(cat <<EOF
${AGENT}: implement sprint ${SPRINT_NUM} tasks

Session: ${SESSION_ID}
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
  echo "=== [$AGENT] Committed on branch $(git branch --show-current) ==="
fi

# --- Phase 4: Zero-commit validation ---
BRANCH="$(git branch --show-current)"
COMMIT_COUNT=$(git log "main..${BRANCH}" --oneline 2>/dev/null | wc -l | tr -d ' ')
if [ "$COMMIT_COUNT" -eq 0 ]; then
  echo ""
  echo "FAILED AGENT: ${AGENT} produced no commits"
  echo "=== [$AGENT] Done (FAILED — zero commits) ==="
  touch "${ROOT}/.agent-done-${AGENT}"
  exit 1
fi

echo ""
echo "=== [$AGENT] Done ($COMMIT_COUNT commit(s)) ==="

# --- Signal completion to sprint-run.sh ---
touch "${ROOT}/.agent-done-${AGENT}"
