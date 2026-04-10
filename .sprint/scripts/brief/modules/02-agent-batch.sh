#!/usr/bin/env bash
# Module 02: Agent Detail Generation — LLM generates per-agent task sections
# Reads agent roster from ROSTER_FILE, generates detailed sections in batches
set -euo pipefail

# Read roster
if [ ! -f "${ROSTER_FILE:-}" ]; then
  echo "<!-- No roster file found, skipping agent generation -->" >&2
  exit 0
fi

ROSTER=$(cat "$ROSTER_FILE")
if [ -z "$ROSTER" ]; then
  exit 0
fi

# Read file conventions for LLM context
FILE_CONV=""
if [ -f "${FILE_CONVENTIONS:-}" ]; then
  FILE_CONV=$(cat "$FILE_CONVENTIONS")
fi

# Read sprint goal for context
SPRINT_GOAL=""
if [ -f "${SPRINT_GOAL_FILE:-}" ]; then
  SPRINT_GOAL=$(cat "$SPRINT_GOAL_FILE")
fi

# Count agents for batching
AGENT_COUNT=$(printf '%s\n' "$ROSTER" | wc -l | tr -d ' ')
BATCH_SIZE=3

# Process agents in batches
BATCH_NUM=0
OFFSET=0

while [ "$OFFSET" -lt "$AGENT_COUNT" ]; do
  BATCH_NUM=$((BATCH_NUM + 1))
  # Extract batch of agents
  BATCH=$(printf '%s\n' "$ROSTER" | tail -n +$((OFFSET + 1)) | head -n "$BATCH_SIZE")
  OFFSET=$((OFFSET + BATCH_SIZE))

  # Build agent list for prompt
  AGENT_LIST=""
  while IFS='|' read -r letter slug desc; do
    [ -z "$letter" ] && continue
    AGENT_LIST="${AGENT_LIST}
- agent${letter}-${slug}: ${desc}"
  done <<< "$BATCH"

  PROMPT="Generate detailed sprint brief sections for the following agents in the ${PROJECT_NAME} project (Sprint ${SPRINT_NUM}).

${SPRINT_GOAL}

## File Conventions
${FILE_CONV}

## Agents to detail:
${AGENT_LIST}

## Output Format
For EACH agent, output exactly this format:

## agent<LETTER>-<slug>

Phase: 1

Objective
- <one-line goal>

Tasks
- Create \`path/to/file\` with <description>
- Add tests in \`tests/path/to/file.test\`
- <additional tasks>

Acceptance Criteria
- <how to verify task is done>
- All tests pass

Files
- \`path/to/file\` (create)
- \`tests/path/to/file.test\` (create)

---

Rules:
- Each agent gets its own ## heading
- Tasks should reference specific file paths using the file conventions
- Files section lists every file the agent will create or modify
- No two agents should modify the same files
- Output ONLY the agent sections, no preamble"

  RESPONSE=$("$LLM_CALL" --prompt "$PROMPT" --section "agent-batch-${BATCH_NUM}" --max-tokens 4096 2>/dev/null) || {
    # Fallback: generate skeleton for each agent in batch
    while IFS='|' read -r letter slug desc; do
      [ -z "$letter" ] && continue
      echo "## agent${letter}-${slug}"
      echo ""
      echo "Phase: 1"
      echo ""
      echo "Objective"
      echo "- ${desc}"
      echo ""
      echo "Tasks"
      echo "- TODO: Define tasks (LLM call failed)"
      echo ""
      echo "Acceptance Criteria"
      echo "- TODO: Define acceptance criteria"
      echo "- All tests pass"
      echo ""
    done <<< "$BATCH"
    continue
  }

  # Output the LLM response (should already be properly formatted)
  printf '%s\n\n' "$RESPONSE"
done
