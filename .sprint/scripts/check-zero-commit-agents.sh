#!/usr/bin/env bash
set -euo pipefail

# Check all agent branches for zero commits relative to main.
# Usage: scripts/check-zero-commit-agents.sh
#
# Sources sprint-parse.sh to discover agents and their branches.
# Exits non-zero if any agent branch has zero commits.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./sprint-parse.sh
source "${SCRIPT_DIR}/sprint-parse.sh"

FAILED=()
PASSED=()

for AGENT in "${AGENTS[@]}"; do
  BRANCH="${AGENT}"
  COMMIT_COUNT=$(git log "main..${BRANCH}" --oneline 2>/dev/null | wc -l | tr -d ' ')

  if [ "$COMMIT_COUNT" -eq 0 ]; then
    echo "FAILED AGENT: ${AGENT} produced no commits"
    FAILED+=("$AGENT")
  else
    echo "OK: ${AGENT} — ${COMMIT_COUNT} commit(s)"
    PASSED+=("$AGENT")
  fi
done

echo ""
echo "=== Summary ==="
echo "Passed: ${#PASSED[@]} / ${#AGENTS[@]}"
echo "Failed: ${#FAILED[@]} / ${#AGENTS[@]}"

if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  echo "Failed agents:"
  for a in "${FAILED[@]}"; do
    echo "  - $a"
  done
  exit 1
fi

echo "All agents produced commits."
exit 0
