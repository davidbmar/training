#!/usr/bin/env bash
# Module 03: Phase 2 Agents — Inject static agent templates if configured
# These are project-specific integration/validation agents that don't change per sprint
set -euo pipefail

if [ ! -f "${PHASE2_AGENTS_FILE:-}" ]; then
  # No phase 2 agents configured — skip silently
  exit 0
fi

# Check if file has content (not just comments/whitespace)
CONTENT=$(grep -v '^#' "$PHASE2_AGENTS_FILE" | grep -v '^<!--' | grep -v '^$' | head -1 || echo "")
if [ -z "$CONTENT" ]; then
  exit 0
fi

cat "$PHASE2_AGENTS_FILE"
echo ""
