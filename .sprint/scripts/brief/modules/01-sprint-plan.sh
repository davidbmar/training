#!/usr/bin/env bash
# Module 01: Sprint Planning — LLM generates sprint goal + agent roster
# Outputs: sprint goal markdown to stdout
# Side effects: writes agent-roster.tsv and goal.txt to TMPDIR
set -euo pipefail

TMPDIR_BASE="$(dirname "$(mktemp -u)")"

# Gather context from project config
PHASE_CONTEXT=""
if [ -f "$PHASES_FILE" ]; then
  PHASE_CONTEXT=$(cat "$PHASES_FILE")
fi

PREV_STATUS_CONTEXT=""
if [ -n "${PREV_STATUS:-}" ] && [ -f "$PREV_STATUS" ]; then
  # Take first 200 lines to keep prompt reasonable
  PREV_STATUS_CONTEXT=$(head -200 "$PREV_STATUS")
fi

CAPABILITIES_CONTEXT=""
if [ -f "$CAPABILITIES_FILE" ]; then
  CAPABILITIES_CONTEXT=$(cat "$CAPABILITIES_FILE")
fi

PROMPT="You are a sprint planning assistant for the ${PROJECT_NAME} project.

Generate a sprint plan for Sprint ${SPRINT_NUM}.

## Project Phases
${PHASE_CONTEXT}

## Previous Status
${PREV_STATUS_CONTEXT}

## Capabilities Already Built
${CAPABILITIES_CONTEXT}

## Instructions
1. Write a clear sprint GOAL (2-3 bullet points of high-level objectives)
2. Decompose the goal into 2-6 independent agents. Each agent should:
   - Have a name in format: agent<LETTER>-<descriptive-slug> (e.g., agentA-auth-api, agentB-dashboard-ui)
   - Handle a distinct, non-overlapping area of work
   - Be ordered by isolation level (most isolated first, most shared-file agents last)

## Output Format
Output EXACTLY this format (no extra text before or after):

Goal
- <objective 1>
- <objective 2>
- <objective 3>

ROSTER_START
<LETTER>|<slug>|<one-line description>
ROSTER_END

Example:
Goal
- Implement user authentication with JWT tokens
- Add dashboard UI with project list
- Set up CI/CD pipeline

ROSTER_START
A|auth-api|Implement JWT authentication endpoints and middleware
B|dashboard-ui|Build React dashboard with project list and navigation
C|ci-pipeline|Configure GitHub Actions for test, lint, and deploy
ROSTER_END"

RESPONSE=$("$LLM_CALL" --prompt "$PROMPT" --section "sprint-plan" --max-tokens 2048 2>/dev/null) || {
  echo "Goal"
  echo "- TODO: Define sprint ${SPRINT_NUM} goal (LLM call failed)"
  echo ""

  # Write fallback roster
  ROSTER_OUT="${TMPDIR_BASE}/brief-gen-roster.tsv"
  echo "A|placeholder|TODO: Define agent work" > "$ROSTER_OUT"
  # Export for other modules
  if [ -n "${ROSTER_FILE:-}" ]; then
    cp "$ROSTER_OUT" "$ROSTER_FILE"
  fi
  exit 0
}

# Extract Goal section
GOAL=$(printf '%s' "$RESPONSE" | sed -n '/^Goal/,/^ROSTER_START/{/^ROSTER_START/d;p}')
if [ -z "$GOAL" ]; then
  GOAL="Goal
- TODO: Parse sprint goal from LLM response"
fi

# Extract roster
ROSTER=$(printf '%s' "$RESPONSE" | sed -n '/^ROSTER_START$/,/^ROSTER_END$/{/^ROSTER_/d;p}' | grep -E '^[A-Z]\|' || echo "")
if [ -z "$ROSTER" ]; then
  ROSTER="A|placeholder|TODO: Define agent work"
fi

# Output goal section
echo "$GOAL"
echo ""

# Write roster file for other modules
if [ -n "${ROSTER_FILE:-}" ]; then
  printf '%s\n' "$ROSTER" > "$ROSTER_FILE"
fi

# Write goal text for other modules
if [ -n "${SPRINT_GOAL_FILE:-}" ]; then
  echo "$GOAL" > "$SPRINT_GOAL_FILE"
fi
