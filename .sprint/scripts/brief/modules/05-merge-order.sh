#!/usr/bin/env bash
# Module 05: Merge Order — Format merge order from agent roster
set -euo pipefail

echo "Merge Order"

if [ ! -f "${ROSTER_FILE:-}" ]; then
  echo "1. TODO: Define merge order"
  echo ""
  exit 0
fi

# Read roster and output numbered merge order
# Roster is already ordered by isolation (most isolated first)
ORDER_NUM=1
while IFS='|' read -r letter slug desc; do
  [ -z "$letter" ] && continue
  echo "${ORDER_NUM}. agent${letter}-${slug}"
  ORDER_NUM=$((ORDER_NUM + 1))
done < "$ROSTER_FILE"

# Append phase 2 agents if configured
if [ -f "${PHASE2_AGENTS_FILE:-}" ]; then
  # Extract agent names from phase2 agents file (look for ## agentX-slug headings)
  while IFS= read -r line; do
    case "$line" in
      '## agent'*)
        agent_name=$(echo "$line" | sed 's/^## //')
        echo "${ORDER_NUM}. ${agent_name}"
        ORDER_NUM=$((ORDER_NUM + 1))
        ;;
    esac
  done < "$PHASE2_AGENTS_FILE"
fi

echo ""
