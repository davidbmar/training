#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# sprint-fix.sh — Auto-correct common GPT formatting errors in SPRINT_BRIEF.md
#
# Fixes applied:
#   1. Sprint heading: "Sprint N" → "# Sprint N"
#   2. Numbered merge order (bare agent names → "1. agentA-...")
#   3. Agent headings: bare "agentX-slug" lines → "## agentX-slug"
#   4. Horizontal rules between agent sections (add --- if missing)
#   5. List prefixes on Constraints, Merge Verification, Tasks, Acceptance Criteria
#   6. Backtick-quote file paths in task lines
#   7. Remove "Depends on:" noise lines
#   8. Fix test file naming: "slug.agentX.test.ts" → "agentX_slug.test.ts"
#   9. Fix migration numbers to start after existing migrations
#  10. Ensure consistent Phase: line format
#
# Usage:
#   ./scripts/sprint-fix.sh           # Fix and show diff
#   ./scripts/sprint-fix.sh --dry-run # Show what would change without writing
#   ./scripts/sprint-fix.sh --quiet   # Fix silently (for automation)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
BRIEF="${ROOT}/SPRINT_BRIEF.md"
DRY_RUN=false
QUIET=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --quiet) QUIET=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [ ! -f "$BRIEF" ]; then
  echo "Error: SPRINT_BRIEF.md not found at ${BRIEF}"
  exit 1
fi

FIXES=0
fix() { FIXES=$((FIXES + 1)); $QUIET || echo "  [fix] $*"; }

# Save original for comparison
ORIG=$(mktemp)
TMP=$(mktemp)
cp "$BRIEF" "$ORIG"
cp "$BRIEF" "$TMP"

# ---------------------------------------------------------------------------
# 1. Sprint heading: ensure "# Sprint N" on first non-empty line
# ---------------------------------------------------------------------------
if head -5 "$TMP" | grep -qE '^Sprint [0-9]+' && ! head -5 "$TMP" | grep -qE '^# Sprint'; then
  sed -i '' 's/^Sprint \([0-9]\)/# Sprint \1/' "$TMP"
  fix "Added # to sprint heading"
fi

# ---------------------------------------------------------------------------
# 2. Numbered merge order (BEFORE heading fix — bare agent names in merge section)
# ---------------------------------------------------------------------------
MERGE_SECTION=$(awk '
  /^Merge Order/ { found=1; next }
  /^(Merge Verification|$)/ { if (found && seen) exit }
  found && /^agent[A-Z]-/ { print; seen=1 }
' "$TMP" || true)

if [ -n "$MERGE_SECTION" ]; then
  awk '
    /^Merge Order/ { found=1; num=0; print; next }
    found && /^agent[A-Z]-/ {
      num++
      printf "%d. %s\n", num, $0
      next
    }
    found && /^(Merge Verification|## |---|-[[:space:]])/ { found=0 }
    found && /^[0-9]+\. agent/ { found=0 }
    { print }
  ' "$TMP" > "${TMP}.mo" && mv "${TMP}.mo" "$TMP"
  fix "Numbered merge order entries"
fi

# ---------------------------------------------------------------------------
# 3. Agent headings: bare "agentX-slug" on its own line → "## agentX-slug"
#    Only converts lines that are NOT inside the Merge Order section
# ---------------------------------------------------------------------------
HAS_BARE=$(grep -cE '^agent[A-Z]-[a-z]' "$TMP" || true)
if [ "$HAS_BARE" -gt 0 ]; then
  # Only convert bare agent lines that aren't in Merge Order (already numbered)
  awk '
    /^Merge Order/ { in_mo=1 }
    /^(Merge Verification|## |---)/ { in_mo=0 }
    !in_mo && /^agent[A-Z]-[a-z]/ { print "## " $0; next }
    { print }
  ' "$TMP" > "${TMP}.ah" && mv "${TMP}.ah" "$TMP"
  NEW_BARE=$(grep -cE '^agent[A-Z]-[a-z]' "$TMP" || true)
  CONVERTED=$((HAS_BARE - NEW_BARE))
  if [ "$CONVERTED" -gt 0 ]; then
    fix "Added ## to ${CONVERTED} agent heading(s)"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Horizontal rules: ensure --- before each ## agent heading
# ---------------------------------------------------------------------------
awk '
  /^## agent/ {
    if (prev != "---" && prev != "" && NR > 1) {
      print "---"
      print ""
    }
  }
  { print; prev = $0 }
' "$TMP" > "${TMP}.hr" && mv "${TMP}.hr" "$TMP"

ORIG_HR=$(grep -c '^---$' "$ORIG" || true)
NEW_HR=$(grep -c '^---$' "$TMP" || true)
if [ "$NEW_HR" -gt "$ORIG_HR" ]; then
  fix "Added $((NEW_HR - ORIG_HR)) horizontal rule(s) between agent sections"
fi

# ---------------------------------------------------------------------------
# 5. List prefixes: Constraints, Verification, Tasks, Acceptance Criteria
# ---------------------------------------------------------------------------

# 5a. Constraints
awk '
  /^Constraints/ { in_c=1; print; next }
  /^(Merge Order|## |---)/ { in_c=0 }
  in_c && /^[A-Z]/ && !/^- / { print "- " $0; next }
  { print }
' "$TMP" > "${TMP}.cf" && mv "${TMP}.cf" "$TMP"

# 5b. Merge Verification
awk '
  /^Merge Verification/ { in_mv=1; print; next }
  /^(## |---)/ { in_mv=0 }
  in_mv && /^[a-z]/ && !/^- / { print "- " $0; next }
  { print }
' "$TMP" > "${TMP}.mv" && mv "${TMP}.mv" "$TMP"

# 5c. Tasks and Acceptance Criteria within agent sections
awk '
  /^(Tasks|Acceptance Criteria)$/ { in_list=1; print; next }
  /^(Phase:|Objective|Tasks|Acceptance Criteria|## |---)/ && !/^Tasks$/ && !/^Acceptance Criteria$/ { in_list=0 }
  in_list && /^[A-Z]/ && !/^- / { print "- " $0; next }
  { print }
' "$TMP" > "${TMP}.ta" && mv "${TMP}.ta" "$TMP"

ORIG_DASH=$(grep -c '^- ' "$ORIG" || true)
NEW_DASH=$(grep -c '^- ' "$TMP" || true)
if [ "$NEW_DASH" -gt "$ORIG_DASH" ]; then
  fix "Added - prefix to $((NEW_DASH - ORIG_DASH)) list item(s)"
fi

# ---------------------------------------------------------------------------
# 6. Backtick-quote file paths in task/create/modify lines
# ---------------------------------------------------------------------------
ORIG_TICKS=$( (grep -oE '`[a-zA-Z][a-zA-Z0-9/_.-]+\.(ts|sql|swift|json|js)`' "$TMP" || true) | wc -l | tr -d ' ')

# Use awk to backtick-quote file paths (macOS sed -E doesn't support alternation in addresses)
awk '
  /^- Create |^- Modify |^- Update |^- Register |^- Import |^- Export / {
    n = split($0, words, " ")
    result = ""
    for (i = 1; i <= n; i++) {
      w = words[i]
      trail = ""
      if (match(w, /[.,]$/)) { trail = substr(w, length(w)); w = substr(w, 1, length(w)-1) }
      if (w !~ /^`/ && w ~ /^(services|packages|client|docs)\/.*\.(ts|sql|swift|json|js|md)$/) {
        w = "`" w "`"
      }
      result = (result == "" ? "" : result " ") w trail
    }
    print result
    next
  }
  { print }
' "$TMP" > "${TMP}.bt" && mv "${TMP}.bt" "$TMP"

NEW_TICKS=$( (grep -oE '`[a-zA-Z][a-zA-Z0-9/_.-]+\.(ts|sql|swift|json|js)`' "$TMP" || true) | wc -l | tr -d ' ')
if [ "$NEW_TICKS" -gt "$ORIG_TICKS" ]; then
  fix "Backtick-quoted $((NEW_TICKS - ORIG_TICKS)) file path(s)"
fi

# ---------------------------------------------------------------------------
# 7. Remove "Depends on:" noise lines
# ---------------------------------------------------------------------------
DEPENDS_COUNT=$(grep -c '^Depends on:' "$TMP" || true)
if [ "$DEPENDS_COUNT" -gt 0 ]; then
  sed -i '' '/^Depends on:/d' "$TMP"
  fix "Removed ${DEPENDS_COUNT} 'Depends on:' line(s)"
fi

# ---------------------------------------------------------------------------
# 8. Fix test file naming convention
# ---------------------------------------------------------------------------
# GPT patterns: "slug.agentX.test.ts" or "slug-agentX.test.ts"
# Our convention: "agentX_slug.test.ts"
NAMING_FIXES=0

# Pattern 1: slug.agentX.test.ts
while IFS= read -r wrong; do
  [ -z "$wrong" ] && continue
  slug=$(echo "$wrong" | sed 's/\.agent[A-Z]\.test\.ts//')
  agent_id=$(echo "$wrong" | grep -oE 'agent[A-Z]')
  correct="${agent_id}_${slug}.test.ts"
  sed -i '' "s|${wrong}|${correct}|g" "$TMP"
  NAMING_FIXES=$((NAMING_FIXES + 1))
done < <(grep -oE '[a-z][a-z0-9-]+\.agent[A-Z]\.test\.ts' "$TMP" 2>/dev/null || true)

# Pattern 2: slug-agentX.test.ts
while IFS= read -r wrong; do
  [ -z "$wrong" ] && continue
  slug=$(echo "$wrong" | sed 's/-agent[A-Z]\.test\.ts//')
  agent_id=$(echo "$wrong" | grep -oE 'agent[A-Z]')
  correct="${agent_id}_${slug}.test.ts"
  sed -i '' "s|${wrong}|${correct}|g" "$TMP"
  NAMING_FIXES=$((NAMING_FIXES + 1))
done < <(grep -oE '[a-z][a-z0-9-]+-agent[A-Z]\.test\.ts' "$TMP" 2>/dev/null || true)

if [ "$NAMING_FIXES" -gt 0 ]; then
  fix "Fixed ${NAMING_FIXES} test file name(s) to agentX_slug.test.ts convention"
fi

# ---------------------------------------------------------------------------
# 9. Fix migration numbers: deduplicate and ensure they start after existing
# ---------------------------------------------------------------------------
MIGRATION_DIR="${ROOT}/services/api-gateway/migration"
if [ -d "$MIGRATION_DIR" ]; then
  HIGHEST=$(ls -1 "$MIGRATION_DIR"/*.sql 2>/dev/null | xargs -I{} basename {} | grep -oE '^[0-9]+' | sort -n | tail -1 || true)
  HIGHEST=${HIGHEST:-0}
  HIGHEST=$((10#$HIGHEST))
  NEXT=$((HIGHEST + 1))

  # Collect existing migration numbers on disk (to skip references to them)
  EXISTING_NUMS=$(ls -1 "$MIGRATION_DIR"/*.sql 2>/dev/null | xargs -I{} basename {} | grep -oE '^[0-9]+' | sort -nu || true)

  # Find "Create ..." lines with migration paths — these are NEW migrations.
  # Lines with "Reference" or "Inspect" or "existing" are references to existing tables, skip them.
  NEW_MIGRATION_LINES=$(grep -nE '^\- Create .*migration/[0-9]{3}_' "$TMP" | grep -v -iE 'reference|inspect|existing' || true)

  if [ -n "$NEW_MIGRATION_LINES" ]; then
    # Extract the migration numbers from new-migration lines (with duplicates preserved)
    NEW_NUMS_ALL=$(echo "$NEW_MIGRATION_LINES" | grep -oE '[0-9]{3}_' | sed 's/_$//' || true)
    NEW_NUMS_UNIQUE=$(echo "$NEW_NUMS_ALL" | sort -nu || true)
    NEW_COUNT_ALL=$(echo "$NEW_NUMS_ALL" | wc -l | tr -d ' ')
    NEW_COUNT_UNIQUE=$(echo "$NEW_NUMS_UNIQUE" | wc -l | tr -d ' ')

    # Case 1: All new migrations share the same number (GPT assigned one number to all)
    # Assign sequential numbers starting from NEXT
    if [ "$NEW_COUNT_UNIQUE" -eq 1 ] && [ "$NEW_COUNT_ALL" -gt 1 ]; then
      DUP_NUM=$(echo "$NEW_NUMS_UNIQUE" | head -1)
      ASSIGN=$NEXT
      # Process each "Create" line with this migration number, replacing sequentially
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        LINE_NO=$(echo "$line" | cut -d: -f1)
        NEW_NUM=$(printf '%03d' "$ASSIGN")
        # Replace the migration number only on this specific line
        sed -i '' "${LINE_NO}s/${DUP_NUM}_/${NEW_NUM}_/" "$TMP"
        ASSIGN=$((ASSIGN + 1))
      done <<< "$(echo "$NEW_MIGRATION_LINES")"
      fix "Deduplicated migration ${DUP_NUM}: assigned ${NEXT}–$(printf '%03d' $((ASSIGN - 1))) to ${NEW_COUNT_ALL} agents"

    # Case 2: Numbers are unique but some overlap with existing disk migrations
    else
      NEEDS_RENUM=false
      for num in $NEW_NUMS_UNIQUE; do
        num_int=$((10#$num))
        if [ "$num_int" -le "$HIGHEST" ]; then
          # Check it's not an existing migration being referenced
          if ! echo "$EXISTING_NUMS" | grep -q "^${num}$"; then
            NEEDS_RENUM=true
            break
          fi
        fi
      done

      if $NEEDS_RENUM; then
        LOWEST_BRIEF=$(echo "$NEW_NUMS_UNIQUE" | head -1)
        LOWEST_BRIEF=$((10#$LOWEST_BRIEF))
        OFFSET=$((NEXT - LOWEST_BRIEF))
        for old_num in $NEW_NUMS_UNIQUE; do
          old_num_int=$((10#$old_num))
          new_num_int=$((old_num_int + OFFSET))
          new_num=$(printf '%03d' "$new_num_int")
          # Only replace in "Create" lines, not in "Reference/existing" lines
          sed -i '' "/[Rr]eference.*existing\|[Ii]nspect.*table\|existing migration/!s/${old_num}_/${new_num}_/g" "$TMP"
        done
        fix "Renumbered migrations: offset +${OFFSET} (${LOWEST_BRIEF}→${NEXT}, existing highest: ${HIGHEST})"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 10. Ensure Phase: line format consistency
# ---------------------------------------------------------------------------
if grep -qE 'Phase:[^ ]|Phase :[0-9]' "$TMP" 2>/dev/null; then
  sed -i '' 's/Phase:[[:space:]]*/Phase: /g; s/Phase :/Phase:/g' "$TMP"
  fix "Normalized Phase: line formatting"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

if [ $FIXES -eq 0 ]; then
  $QUIET || echo "=== No fixes needed — SPRINT_BRIEF.md looks clean ==="
  rm -f "$TMP" "$ORIG"
  exit 0
fi

# Show diff
if ! $QUIET; then
  echo ""
  echo "=== ${FIXES} fix(es) applied ==="
  echo ""
  diff -u "$ORIG" "$TMP" | head -120 || true
  echo ""
fi

if $DRY_RUN; then
  $QUIET || echo "[dry-run] No changes written. Run without --dry-run to apply."
  rm -f "$TMP" "$ORIG"
  exit 0
fi

# Apply
cp "$TMP" "$BRIEF"
rm -f "$TMP" "$ORIG"
$QUIET || echo "=== SPRINT_BRIEF.md updated (${FIXES} fixes) ==="
