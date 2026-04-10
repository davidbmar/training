#!/usr/bin/env bash
# Module 04: Constraints — Output canonical constraints + migration table
set -euo pipefail

echo "Constraints"

# Read canonical constraints from config
if [ -f "${CONSTRAINTS_FILE:-}" ]; then
  # Output each non-comment, non-empty line as a constraint
  while IFS= read -r line; do
    # Skip markdown headings, HTML comments, and empty lines
    case "$line" in
      '#'*|'<!--'*|'') continue ;;
      '- '*) echo "$line" ;;  # Already formatted as list item
      *) echo "- $line" ;;     # Add list marker
    esac
  done < "$CONSTRAINTS_FILE"
else
  # Default constraints
  echo "- No two agents may modify the same files"
  echo "- All agents must write tests for new functionality"
  echo "- No breaking changes to existing APIs without migration plan"
fi

echo ""

# Generate migration table from agent roster (if roster exists)
if [ -f "${ROSTER_FILE:-}" ]; then
  # Check if any agents might need migrations by scanning common dirs
  HAS_MIGRATIONS=false
  for mig_dir in "${ROOT}/migrations" "${ROOT}/db/migrate" "${ROOT}/prisma/migrations" "${ROOT}/alembic/versions"; do
    if [ -d "$mig_dir" ]; then
      HAS_MIGRATIONS=true
      break
    fi
  done

  if [ "$HAS_MIGRATIONS" = true ]; then
    echo "Migration Ownership"
    echo ""
    echo "| # | Agent | Migration File | Description |"
    echo "|---|-------|---------------|-------------|"

    MIG_NUM=1
    while IFS='|' read -r letter slug desc; do
      [ -z "$letter" ] && continue
      # Only include agents whose description suggests DB work
      case "$desc" in
        *database*|*migration*|*schema*|*model*|*table*|*API*|*api*|*backend*|*data*)
          printf "| %d | agent%s-%s | TODO | %s |\n" "$MIG_NUM" "$letter" "$slug" "$desc"
          MIG_NUM=$((MIG_NUM + 1))
          ;;
      esac
    done < "$ROSTER_FILE"

    echo ""
  fi
fi
