#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# sprint-validate.sh — Pre-flight validation of SPRINT_BRIEF.md
#
# Catches common GPT formatting issues and agent conflicts before launch.
# Run this before sprint-run.sh or sprint-init.sh.
#
# Checks:
#   1. Parser loads without errors (agent names, phases, merge order)
#   2. No duplicate file paths across agent task sections
#   3. All agents in merge order exist as ## headings
#   4. Phase 1 agents don't reference barrel/server.ts/api-types modifications
#   5. Migration numbers are unique
#   6. Agent naming follows convention (agent<LETTER>-<slug>)
#   7. API route files include auth enforcement (requireAuth/withAuth)
#
# Usage:
#   ./.sprint/scripts/sprint-validate.sh           # Validate and report
#   ./.sprint/scripts/sprint-validate.sh --strict  # Exit 1 on warnings (not just errors)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

STRICT=false
[ "${1:-}" = "--strict" ] && STRICT=true

ERRORS=0
WARNINGS=0

error() { echo "  ERROR: $*"; ERRORS=$((ERRORS + 1)); }
warn()  { echo "  WARN:  $*"; WARNINGS=$((WARNINGS + 1)); }
ok()    { echo "  OK:    $*"; }

# Temp files for tracking ownership (bash 3 compatible — no associative arrays)
FILE_OWNERS_TMP=$(mktemp)
MIGRATION_OWNERS_TMP=$(mktemp)
trap 'rm -f "$FILE_OWNERS_TMP" "$MIGRATION_OWNERS_TMP"' EXIT

echo "=== Sprint Brief Validation ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Parser loads successfully
# ---------------------------------------------------------------------------
echo "--- Parsing SPRINT_BRIEF.md ---"

# shellcheck source=./sprint-parse.sh
if ! source "${SCRIPT_DIR}/sprint-parse.sh" 2>/dev/null; then
  error "sprint-parse.sh failed to load. Fix SPRINT_BRIEF.md syntax."
  echo ""
  echo "=== VALIDATION FAILED ($ERRORS errors) ==="
  exit 1
fi

ok "Sprint ${SPRINT_NUM} parsed: ${#AGENTS[@]} agents (${#PHASE1_AGENTS[@]} P1, ${#PHASE2_AGENTS[@]} P2)"

# ---------------------------------------------------------------------------
# 2. Agent naming convention
# ---------------------------------------------------------------------------
echo ""
echo "--- Agent Naming ---"
NAMING_ERRORS=0
for agent in "${AGENTS[@]}"; do
  if ! echo "$agent" | grep -qE '^agent[A-Z]-'; then
    error "'${agent}' doesn't match agent<LETTER>-<slug> pattern"
    NAMING_ERRORS=$((NAMING_ERRORS + 1))
  fi
done
if [ $NAMING_ERRORS -eq 0 ]; then
  ok "All agent names follow convention"
fi

# ---------------------------------------------------------------------------
# 3. Merge order matches agent headings
# ---------------------------------------------------------------------------
echo ""
echo "--- Merge Order Consistency ---"
ORDER_OK=true
for agent in "${MERGE_ORDER[@]}"; do
  found=false
  for a in "${AGENTS[@]}"; do
    if [ "$a" = "$agent" ]; then
      found=true
      break
    fi
  done
  if ! $found; then
    error "Merge order lists '${agent}' but no ## heading found"
    ORDER_OK=false
  fi
done
for agent in "${AGENTS[@]}"; do
  found=false
  for m in "${MERGE_ORDER[@]}"; do
    if [ "$m" = "$agent" ]; then
      found=true
      break
    fi
  done
  if ! $found; then
    warn "'${agent}' has a ## heading but is not in merge order"
    ORDER_OK=false
  fi
done
if $ORDER_OK; then
  ok "Merge order matches agent headings"
fi

# ---------------------------------------------------------------------------
# 4. File path collision detection
# ---------------------------------------------------------------------------
echo ""
echo "--- File Ownership ---"

COLLISION_COUNT=0
FILE_COUNT=0

for agent in "${AGENTS[@]}"; do
  brief=$(get_agent_brief "$agent")
  while IFS= read -r filepath; do
    [ -z "$filepath" ] && continue
    FILE_COUNT=$((FILE_COUNT + 1))
    # Check if this file was already claimed by another agent
    existing=$(grep "^${filepath}	" "$FILE_OWNERS_TMP" 2>/dev/null | head -1 | cut -f2 || true)
    if [ -n "$existing" ]; then
      error "File collision: '${filepath}' claimed by ${existing} AND ${agent}"
      COLLISION_COUNT=$((COLLISION_COUNT + 1))
    else
      printf '%s\t%s\n' "$filepath" "$agent" >> "$FILE_OWNERS_TMP"
    fi
  done < <(echo "$brief" | grep -E '^- (Create|Modify|Update)' | grep -oE '`[a-zA-Z][a-zA-Z0-9/_.-]+\.(ts|sql|swift|json)`' | tr -d '`' | sort -u)
done

if [ $COLLISION_COUNT -eq 0 ]; then
  ok "No file path collisions detected (${FILE_COUNT} unique paths)"
else
  warn "${COLLISION_COUNT} file collision(s) — these will cause merge conflicts"
fi

# ---------------------------------------------------------------------------
# 5. Phase 1 agents don't touch forbidden files
# ---------------------------------------------------------------------------
echo ""
echo "--- Phase 1 Constraints ---"
CONSTRAINT_VIOLATIONS=0

for agent in "${PHASE1_AGENTS[@]}"; do
  brief=$(get_agent_brief "$agent")

  # Check for barrel/index.ts modifications
  if echo "$brief" | grep -qiE '(modify|update|edit|add to|wire|register).*index\.ts'; then
    warn "P1 agent '${agent}' may modify an index.ts barrel file"
    CONSTRAINT_VIOLATIONS=$((CONSTRAINT_VIOLATIONS + 1))
  fi

  # Check for server.ts modifications
  if echo "$brief" | grep -qiE '(modify|update|edit|register.*route).*server\.ts'; then
    warn "P1 agent '${agent}' may modify server.ts"
    CONSTRAINT_VIOLATIONS=$((CONSTRAINT_VIOLATIONS + 1))
  fi

  # Check for api-types modifications (not creation)
  if echo "$brief" | grep -qiE 'modify.*packages/api-types'; then
    warn "P1 agent '${agent}' may modify packages/api-types/"
    CONSTRAINT_VIOLATIONS=$((CONSTRAINT_VIOLATIONS + 1))
  fi
done

if [ $CONSTRAINT_VIOLATIONS -eq 0 ]; then
  ok "Phase 1 agents appear to respect barrel/server.ts constraints"
fi

# ---------------------------------------------------------------------------
# 6. Migration number uniqueness
# ---------------------------------------------------------------------------
echo ""
echo "--- Migration Numbers ---"
MIGRATION_COLLISIONS=0
MIGRATION_COUNT=0

for agent in "${AGENTS[@]}"; do
  brief=$(get_agent_brief "$agent")
  while IFS= read -r mignum; do
    [ -z "$mignum" ] && continue
    MIGRATION_COUNT=$((MIGRATION_COUNT + 1))
    existing=$(grep "^${mignum}	" "$MIGRATION_OWNERS_TMP" 2>/dev/null | head -1 | cut -f2 || true)
    if [ -n "$existing" ]; then
      error "Migration ${mignum} claimed by ${existing} AND ${agent}"
      MIGRATION_COLLISIONS=$((MIGRATION_COLLISIONS + 1))
    else
      printf '%s\t%s\n' "$mignum" "$agent" >> "$MIGRATION_OWNERS_TMP"
    fi
  done < <(echo "$brief" | grep -oE '[0-9]{3}_' | sed 's/_$//' | sort -u)
done

if [ $MIGRATION_COLLISIONS -eq 0 ]; then
  ok "Migration numbers are unique (${MIGRATION_COUNT} migrations)"
fi

# ---------------------------------------------------------------------------
# 7. Auth enforcement in existing route files
# ---------------------------------------------------------------------------
echo ""
echo "--- Auth Enforcement (existing routes) ---"
AUTH_MISSING=0
ROUTES_CHECKED=0

# Check all route files under api-gateway/src/routes/ for requireAuth or withAuth
ROUTES_DIR="${SCRIPT_DIR}/../services/api-gateway/src/routes"
if [ -d "$ROUTES_DIR" ]; then
  while IFS= read -r route_file; do
    [ -z "$route_file" ] && continue
    ROUTES_CHECKED=$((ROUTES_CHECKED + 1))
    basename_file=$(basename "$route_file")
    if ! grep -qE '(requireAuth|withAuth|requireBearerAuth|requireBearerToken)' "$route_file"; then
      warn "Route file '${basename_file}' has no auth enforcement (missing requireAuth/withAuth)"
      AUTH_MISSING=$((AUTH_MISSING + 1))
    fi
  done < <(find "$ROUTES_DIR" -name '*.ts' -not -name '*.test.ts' -not -name '*.d.ts' 2>/dev/null)
fi

if [ $ROUTES_CHECKED -eq 0 ]; then
  ok "No route files found (skipped)"
elif [ $AUTH_MISSING -eq 0 ]; then
  ok "All ${ROUTES_CHECKED} route files enforce auth"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================="
if [ $ERRORS -gt 0 ]; then
  echo "  VALIDATION FAILED: ${ERRORS} error(s), ${WARNINGS} warning(s)"
  echo "  Fix errors before launching the sprint."
  echo "========================================="
  exit 1
elif [ $WARNINGS -gt 0 ] && $STRICT; then
  echo "  VALIDATION FAILED (strict): ${WARNINGS} warning(s)"
  echo "  Fix warnings or re-run without --strict."
  echo "========================================="
  exit 1
elif [ $WARNINGS -gt 0 ]; then
  echo "  VALIDATION PASSED with ${WARNINGS} warning(s)"
  echo "  Review warnings above — they may cause merge conflicts."
  echo "========================================="
  exit 0
else
  echo "  VALIDATION PASSED — no issues found"
  echo "========================================="
  exit 0
fi
