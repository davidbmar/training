#!/usr/bin/env bash
# Shared parsing logic for SPRINT_BRIEF.md
# Source this file — do not execute directly.
#
# After sourcing, these are available:
#   SPRINT_NUM      — integer sprint number
#   SPRINT_META     — goal/constraints text from the meta block
#   AGENTS          — array of all agent names (from ## headings)
#   PHASE1_AGENTS   — array of Phase 1 agent names
#   PHASE2_AGENTS   — array of Phase 2 agent names
#   MERGE_ORDER     — array of agent names in merge order (from Merge Order section)
#   MERGE_VERIFY    — array of verification commands (from Merge Verification section)
#   BRIEF_FILE      — path to SPRINT_BRIEF.md
#
# Functions:
#   get_agent_brief <agent-name>  — prints that agent's brief content
#   get_agent_phase <agent-name>  — prints "1" or "2" (defaults to "1" if not specified)
#   get_sprint_meta               — prints the meta block

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
BRIEF_FILE="${ROOT}/SPRINT_BRIEF.md"

if [ ! -f "$BRIEF_FILE" ]; then
  echo "Error: SPRINT_BRIEF.md not found at ${BRIEF_FILE}"
  echo "Create it in the repo root before running sprint scripts."
  exit 1
fi

# Parse sprint number from first # heading
SPRINT_NUM=$(grep -m1 '^# Sprint ' "$BRIEF_FILE" | sed -E 's/^# Sprint ([0-9]+).*/\1/')
if [ -z "$SPRINT_NUM" ]; then
  echo "Error: Could not find '# Sprint <number>' heading in ${BRIEF_FILE}"
  exit 1
fi

# Parse agent names from ## headings (only those matching agent naming pattern)
# Also accepts any ## heading that isn't a known meta-block section
KNOWN_META_SECTIONS="Goal|Constraints|Merge Order|Merge Verification|Agent Commit Policy|Autonomous Execution Rules|Previous Sprint"
AGENTS=()
while IFS= read -r line; do
  agent_name=$(echo "$line" | sed 's/^## //')
  # Skip known meta-block sections that GPT sometimes formats as ## headings
  if echo "$agent_name" | grep -qE "^(${KNOWN_META_SECTIONS})$"; then
    continue
  fi
  AGENTS+=("$agent_name")
done < <(grep '^## ' "$BRIEF_FILE")

if [ ${#AGENTS[@]} -eq 0 ]; then
  echo "Error: No agent sections (## headings) found in ${BRIEF_FILE}"
  exit 1
fi

# Load project config if available
# Check .sprint/scripts/sprint-config.sh first, then fall back to .sprint/config.sh
# (setup.sh installs config one level up at .sprint/config.sh, not inside scripts/)
SPRINT_CONFIG="${SCRIPT_DIR}/sprint-config.sh"
if [ ! -f "$SPRINT_CONFIG" ]; then
  SPRINT_CONFIG="${SCRIPT_DIR}/../config.sh"
fi
if [ -f "$SPRINT_CONFIG" ]; then
  source "$SPRINT_CONFIG"
fi
_SLUG="${PROJECT_SLUG:-$(basename "$(cd "${ROOT}/.." && pwd -P)")}"

# Derived paths — worktrees live alongside the project root
SPRINT_BASE="${ROOT}/../${_SLUG}-agents-sprint${SPRINT_NUM}"

# Extract the sprint meta block (everything between # Sprint N and the first ## agent heading)
# Handles both plain-text meta labels (Goal, Constraints) and ## meta headings
get_sprint_meta() {
  awk '
    BEGIN { found=0 }
    /^# Sprint / { found=1; next }
    /^## agent/ { exit }
    /^## / {
      # Check if this is a known meta section or an agent section
      heading = substr($0, 4)
      if (heading ~ /^(Goal|Constraints|Merge Order|Merge Verification|Agent Commit Policy|Autonomous Execution Rules|Previous Sprint)/) {
        # Strip the ## and print as plain text (normalize to spec format)
        print heading
        next
      } else {
        exit
      }
    }
    found { print }
  ' "$BRIEF_FILE"
}

SPRINT_META=$(get_sprint_meta)

# Extract only the agent-facing parts of the meta block (excludes Merge Order and Merge Verification)
get_agent_meta() {
  echo "$SPRINT_META" | awk '
    /^Merge Order/ { skip=1 }
    /^Merge Verification/ { skip=1 }
    /^Previous Sprint/ { skip=1 }
    /^[A-Z]/ && !/^Merge/ && !/^Previous/ { skip=0 }
    !skip { print }
  '
}

AGENT_META=$(get_agent_meta)

# Warn if meta block uses table format (not parseable)
if echo "$SPRINT_META" | grep -q '^|'; then
  echo "Warning: SPRINT_BRIEF.md meta block appears to use table format (| ... |)."
  echo "The parser expects plain text format. Example:"
  echo "  Merge Order"
  echo "  1. agentA-foo"
  echo "  2. agentB-bar"
  echo "  Merge Verification"
  echo "  - npm test"
  echo ""
  echo "See docs/project-memory/tools/SPRINT_BRIEF_SPEC.md for the correct format."
fi

# Parse merge order from the meta block (lines after "Merge Order" that start with a number)
MERGE_ORDER=()
while IFS= read -r line; do
  # Strip leading number, dot, and whitespace: "1. agentC-foo" -> "agentC-foo"
  agent_name=$(echo "$line" | sed 's/^[0-9][0-9]*\.[[:space:]]*//')
  MERGE_ORDER+=("$agent_name")
done < <(echo "$SPRINT_META" | awk '
  /^Merge Order/ { found=1; next }
  /^[A-Z]/ { if (found) exit }
  /^$/ { if (found) exit }
  found && /^[0-9]/ { print }
')

# If no merge order specified, fall back to agent order from ## headings
if [ ${#MERGE_ORDER[@]} -eq 0 ]; then
  MERGE_ORDER=("${AGENTS[@]}")
fi

# Parse merge verification commands (lines after "Merge Verification" that start with -)
MERGE_VERIFY=()
while IFS= read -r line; do
  cmd=$(echo "$line" | sed 's/^-[[:space:]]*//')
  MERGE_VERIFY+=("$cmd")
done < <(echo "$SPRINT_META" | awk '
  /^Merge Verification/ { found=1; next }
  /^[A-Z]/ { if (found) exit }
  /^$/ { if (found) exit }
  found && /^-/ { print }
')

# Default verification if none specified — use DEFAULT_TEST_CMD from config
if [ ${#MERGE_VERIFY[@]} -eq 0 ]; then
  if [ -n "${DEFAULT_TEST_CMD:-}" ] && [ "$DEFAULT_TEST_CMD" != "npm test" ]; then
    MERGE_VERIFY=("$DEFAULT_TEST_CMD")
  else
    MERGE_VERIFY=("npm test")
  fi
fi

# Normalize `python ` → `python3 ` when `python` is not on PATH (common on macOS).
# Also handles `python -` patterns (e.g., `python -c`, `python -m`).
if ! command -v python >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  for i in "${!MERGE_VERIFY[@]}"; do
    MERGE_VERIFY[$i]="${MERGE_VERIFY[$i]//python /python3 }"
    MERGE_VERIFY[$i]="${MERGE_VERIFY[$i]//python-/python3-}"
  done
fi

# Include security audit in verification if the project uses Node (has package-lock.json)
if [ -f "${ROOT}/package-lock.json" ]; then
  HAS_AUDIT=false
  for cmd in "${MERGE_VERIFY[@]}"; do
    if [[ "$cmd" == *"npm audit"* ]]; then
      HAS_AUDIT=true
      break
    fi
  done
  if ! $HAS_AUDIT; then
    MERGE_VERIFY+=("npm audit --audit-level=high")
  fi
fi

# Extract the brief content for a given agent (everything between its ## and the next agent ## or EOF)
get_agent_brief() {
  local agent="$1"
  awk -v agent="$agent" '
    BEGIN { found=0 }
    /^## / {
      if (found) {
        # Check if this is another agent heading (not a meta section)
        heading = substr($0, 4)
        if (heading !~ /^(Goal|Constraints|Merge Order|Merge Verification|Agent Commit Policy|Autonomous Execution Rules)/) {
          exit
        }
      }
      if ($0 == "## " agent) { found=1; next }
    }
    found { print }
  ' "$BRIEF_FILE"
}

# Extract the phase for a given agent (looks for "Phase: N" in agent's section)
# Returns "1" if not specified (backward compatible with pre-phase briefs)
get_agent_phase() {
  local agent="$1"
  local brief
  brief=$(get_agent_brief "$agent")
  local phase
  phase=$(echo "$brief" | grep -m1 '^Phase:' | sed 's/^Phase:[[:space:]]*//' | tr -d '[:space:]')
  if [ -z "$phase" ]; then
    echo "1"
  else
    echo "$phase"
  fi
}

# Extract the role for a given agent (looks for "Role: <name>" in agent's section)
# Returns "implementer" if not specified (backward compatible with pre-role briefs)
# The role name must match a file in toolkit/roles/ (e.g. "qa" → toolkit/roles/qa.md)
get_agent_role() {
  local agent="$1"
  local brief
  brief=$(get_agent_brief "$agent")
  local role
  role=$(echo "$brief" | grep -m1 '^Role:' | sed 's/^Role:[[:space:]]*//' | tr -d '[:space:]')
  if [ -z "$role" ]; then
    echo "implementer"
  else
    echo "$role"
  fi
}

# Split agents into phase arrays
PHASE1_AGENTS=()
PHASE2_AGENTS=()
for agent in "${AGENTS[@]}"; do
  phase=$(get_agent_phase "$agent")
  if [ "$phase" = "2" ]; then
    PHASE2_AGENTS+=("$agent")
  else
    PHASE1_AGENTS+=("$agent")
  fi
done

# Also split merge order by phase
PHASE1_MERGE_ORDER=()
PHASE2_MERGE_ORDER=()
for agent in "${MERGE_ORDER[@]}"; do
  phase=$(get_agent_phase "$agent")
  if [ "$phase" = "2" ]; then
    PHASE2_MERGE_ORDER+=("$agent")
  else
    PHASE1_MERGE_ORDER+=("$agent")
  fi
done
