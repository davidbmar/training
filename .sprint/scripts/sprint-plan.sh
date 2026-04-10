#!/usr/bin/env bash
# sprint-plan.sh — Generate planning context for the next sprint.
#
# Reads the most recent PROJECT_STATUS doc + backlog/README.md and outputs
# a structured summary that feeds into writing the next SPRINT_BRIEF.md.
#
# Usage:
#   .sprint/scripts/sprint-plan.sh              # auto-detect last sprint
#   .sprint/scripts/sprint-plan.sh --sprint 5   # plan sprint 6 based on sprint 5
#   .sprint/scripts/sprint-plan.sh --output plan.md  # write to file instead of stdout
#
# This script closes the feedback loop:
#   Sprint N merge → PROJECT_STATUS → sprint-plan.sh → SPRINT_BRIEF.md (Sprint N+1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"

# Parse arguments
SPECIFIC_SPRINT=""
OUTPUT_FILE=""
for arg in "$@"; do
  case "$arg" in
    --sprint) shift; SPECIFIC_SPRINT="${1:-}"; shift || true ;;
    --output) shift; OUTPUT_FILE="${1:-}"; shift || true ;;
  esac
done

# ─── Find the most recent PROJECT_STATUS doc ────────────────────────────────

STATUS_DIR="${ROOT}/docs"
BACKLOG_FILE="${ROOT}/docs/project-memory/backlog/README.md"

if [ -n "$SPECIFIC_SPRINT" ]; then
  # Find status doc for specific sprint number
  LAST_STATUS=$(ls -1 "${STATUS_DIR}"/PROJECT_STATUS_*-sprint${SPECIFIC_SPRINT}.md 2>/dev/null | tail -1)
  LAST_SPRINT_NUM="$SPECIFIC_SPRINT"
else
  # Find the most recent PROJECT_STATUS doc by sprint number
  LAST_STATUS=$(ls -1 "${STATUS_DIR}"/PROJECT_STATUS_*-sprint*.md 2>/dev/null | \
    sed 's/.*sprint\([0-9]*\)\.md/\1 &/' | sort -n | tail -1 | awk '{print $2}')
  LAST_SPRINT_NUM=$(echo "$LAST_STATUS" | grep -oE 'sprint[0-9]+' | grep -oE '[0-9]+')
fi

if [ -z "$LAST_STATUS" ] || [ ! -f "$LAST_STATUS" ]; then
  echo "No PROJECT_STATUS docs found in ${STATUS_DIR}/"
  echo "Run a sprint first, or create PROJECT_STATUS docs manually."
  exit 1
fi

NEXT_SPRINT_NUM=$((LAST_SPRINT_NUM + 1))
REPO_NAME=$(basename "${ROOT}")

# ─── Extract data from last sprint ──────────────────────────────────────────

# Sprint summary
last_summary=$(awk '
  /^## Sprint.*Summary/ { found=1; next }
  /^---/ { if (found) exit }
  found && /[^ ]/ { print }
' "$LAST_STATUS")

# What changed (agent sections)
last_changes=$(awk '
  /^## What Changed/ { found=1; next }
  /^---/ { if (found) exit }
  found { print }
' "$LAST_STATUS")

# Next steps from last sprint (these become candidate items for this sprint)
last_next_steps=$(awk '
  /^## Next Steps/ { found=1; next }
  /^---/ { if (found) exit }
  /^#/ { if (found) exit }
  found && /^-/ { print }
' "$LAST_STATUS")

# Merge results table
last_merge_table=$(awk '
  /^## Merge Results/ { found=1; next }
  /^---/ { if (found) exit }
  found && /^\|/ { print }
' "$LAST_STATUS")

# ─── Extract backlog data ───────────────────────────────────────────────────

backlog_bugs=""
backlog_features=""
backlog_open_bugs=""
backlog_open_features=""

if [ -f "$BACKLOG_FILE" ]; then
  # All bugs
  backlog_bugs=$(awk '
    /^## Bugs/ { found=1; next }
    /^## / { if (found) exit }
    found && /^\|/ && !/^\|[-]+/ && !/^\| ID/ { print }
  ' "$BACKLOG_FILE")

  # All features
  backlog_features=$(awk '
    /^## Feature/ { found=1; next }
    /^## / { if (found) exit }
    found && /^\|/ && !/^\|[-]+/ && !/^\| ID/ { print }
  ' "$BACKLOG_FILE")

  # Open bugs (not Fixed/Complete)
  backlog_open_bugs=$(echo "$backlog_bugs" | grep -vE '(Fixed|Complete)' || true)

  # Open features (not Complete)
  backlog_open_features=$(echo "$backlog_features" | grep -vE 'Complete' || true)
fi

# ─── Extract roadmap sprint goals ──────────────────────────────────────────

ROADMAP_FILE="${ROOT}/docs/lifecycle/ROADMAP.md"
roadmap_sprint_goals=""
roadmap_extension_note=""

if [ -f "$ROADMAP_FILE" ]; then
  # Extract Sprint Plan section
  roadmap_sprint_plan=$(awk '
    /^### Sprint Plan/ { found=1; next }
    /^### [^S]|^## / { if (found) exit }
    found { print }
  ' "$ROADMAP_FILE")

  # Find goals for the specific next sprint
  if [ -n "$roadmap_sprint_plan" ]; then
    roadmap_sprint_goals=$(echo "$roadmap_sprint_plan" | awk -v num="$NEXT_SPRINT_NUM" '
      $0 ~ "\\*\\*Sprint " num ":" { found=1; print; next }
      /\*\*Sprint [0-9]+:/ { if (found) exit }
      found { print }
    ')
  fi

  # Check if this is a roadmap extension sprint (sprint 5 or every 4th after)
  if [ "$((NEXT_SPRINT_NUM % 4))" -eq 1 ] && [ "$NEXT_SPRINT_NUM" -ge 5 ]; then
    roadmap_extension_note="**Roadmap Extension Checkpoint:** This is Sprint ${NEXT_SPRINT_NUM} — time to extend the roadmap with 4+ additional sprints based on progress and learnings."
  fi
fi

# ─── Generate planning context ──────────────────────────────────────────────

generate_plan() {
cat << PLANEOF
# Sprint ${NEXT_SPRINT_NUM} Planning Context — ${REPO_NAME}

> Auto-generated by sprint-plan.sh from Sprint ${LAST_SPRINT_NUM} results + backlog.
> Use this as input when writing SPRINT_BRIEF.md for Sprint ${NEXT_SPRINT_NUM}.

---

## Previous Sprint (Sprint ${LAST_SPRINT_NUM}) Results

### Summary
${last_summary:-_No summary available_}

### What Was Delivered
${last_changes:-_No change details available_}

### Merge Results
${last_merge_table:-_No merge data available_}

---

## Carry-Forward Items

These were listed as "Next Steps" in Sprint ${LAST_SPRINT_NUM} and should be considered first:

${last_next_steps:-_None specified_}

---

## Open Backlog

### Open Bugs
${backlog_open_bugs:-_No open bugs_}

### Open Features (not yet complete)
${backlog_open_features:-_No open features_}

---

## Roadmap Goals for Sprint ${NEXT_SPRINT_NUM}

${roadmap_sprint_goals:-_No roadmap sprint goals found. Check docs/lifecycle/ROADMAP.md Sprint Plan section._}

${roadmap_extension_note}

---

## Sprint Cycle Checklist

- [ ] Build: implement sprint brief deliverables
- [ ] Review: PM + customer review delivered components
- [ ] Customer Test: simulate real user journeys with Playwright
- [ ] Backlog: triage bugs and feature requests from review
- [ ] Plan: write next sprint brief using roadmap + backlog

---

## Suggested Sprint ${NEXT_SPRINT_NUM} Scope

Based on roadmap goals, carry-forward items, and open backlog, consider:

PLANEOF

  # Generate suggestions from carry-forward + high-priority backlog
  suggestion_num=0

  if [ -n "$last_next_steps" ]; then
    echo "### From Carry-Forward (Sprint ${LAST_SPRINT_NUM} Next Steps)"
    echo "$last_next_steps"
    echo ""
  fi

  if [ -n "$backlog_open_bugs" ]; then
    echo "### From Open Bugs"
    echo "$backlog_open_bugs" | head -5 | while IFS= read -r line; do
      [ -z "$line" ] && continue
      # Extract bug ID and title from table row
      bug_id=$(echo "$line" | awk -F'|' '{gsub(/^ +| +$/, "", $2); print $2}')
      bug_title=$(echo "$line" | awk -F'|' '{gsub(/^ +| +$/, "", $3); print $3}')
      echo "- ${bug_id}: ${bug_title}"
    done
    echo ""
  fi

  if [ -n "$backlog_open_features" ]; then
    echo "### From Open Features"
    echo "$backlog_open_features" | head -5 | while IFS= read -r line; do
      [ -z "$line" ] && continue
      feature_id=$(echo "$line" | awk -F'|' '{gsub(/^ +| +$/, "", $2); print $2}')
      feature_title=$(echo "$line" | awk -F'|' '{gsub(/^ +| +$/, "", $3); print $3}')
      feature_priority=$(echo "$line" | awk -F'|' '{gsub(/^ +| +$/, "", $4); print $4}')
      echo "- ${feature_id}: ${feature_title} (${feature_priority})"
    done
    echo ""
  fi

cat << PLANEOF2

---

## Template Reminder

Write SPRINT_BRIEF.md following this structure:

\`\`\`
# Sprint ${NEXT_SPRINT_NUM}

Goal
- <what this sprint will accomplish>

Constraints
- No two agents may modify the same files
- <file ownership rules>

Merge Order
1. <agent with fewest dependencies first>
2. <agent that builds on #1>
3. <agent with broadest scope last>

Merge Verification
- <test command>

## agentA-name

Objective
- <what this agent builds>

Tasks
- <specific implementation tasks>

Acceptance Criteria
- <how to verify it works>
\`\`\`
PLANEOF2
}

# ─── Output ─────────────────────────────────────────────────────────────────

if [ -n "$OUTPUT_FILE" ]; then
  generate_plan > "$OUTPUT_FILE"
  echo "Sprint ${NEXT_SPRINT_NUM} planning context written to: ${OUTPUT_FILE}"
else
  generate_plan
fi
