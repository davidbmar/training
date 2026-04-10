#!/usr/bin/env bash
# Sprint orchestration — centralized configuration.
# Source this file (via sprint-parse.sh) — do not execute directly.
#
# Override any variable before sourcing, or edit defaults here.
# All variables use ${VAR:-default} so they work without modification.

# Project slug — used to name the sibling worktree directory.
# Default: derived from the repo directory name.
SCRIPT_DIR_CFG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_CFG="$(cd "${SCRIPT_DIR_CFG}/.." && pwd -P)"
PROJECT_SLUG="${PROJECT_SLUG:-$(basename "$ROOT_CFG")}"

# Test command — run after agent work and after each merge.
# IMPORTANT: Set this to your project's actual test runner. sprint-run.sh
# uses this command to verify each agent's work and each merge.
# The default is a safe no-op — you MUST change it for real sprints.
#
# Examples:
#   Playwright (recommended for dashboard projects):
#     DEFAULT_TEST_CMD="npx playwright test tests/test-unit.spec.js tests/test-integration.spec.js"
#   Python/pytest:
#     DEFAULT_TEST_CMD="python3 -m pytest tests/ -v"
#   Go:
#     DEFAULT_TEST_CMD="go test ./..."
#   Multiple commands:
#     DEFAULT_TEST_CMD="python3 -m pytest tests/ -v && npm run lint"
#
# NOTE: Use python3 (not python) on macOS — there is no 'python' binary.
# NOTE: Avoid 'npm test' — it often wraps the real runner with extra output
#       that can confuse sprint-run.sh exit-code detection.
DEFAULT_TEST_CMD="${DEFAULT_TEST_CMD:-echo 'No test command configured — set DEFAULT_TEST_CMD in sprint-config.sh'}"

# Sprint notes file — agent summaries are appended here.
SPRINT_NOTES_FILE="${SPRINT_NOTES_FILE:-${ROOT_CFG}/Sprint-Notes.md}"

# Ephemeral files — auto-resolved with --theirs during merge conflicts.
# Override by setting EPHEMERAL_FILES before sourcing, or edit this list.
if [ -z "${EPHEMERAL_FILES+x}" ]; then
  EPHEMERAL_FILES=(
    "AGENT_BRIEF.md"
    ".claude-output.txt"
    "docs/project-memory/.index/last-updated.txt"
  )
fi

# Sprint report output paths.
STATUS_DIR="${STATUS_DIR:-${ROOT_CFG}/docs}"
STATUS_PREFIX="${STATUS_PREFIX:-PROJECT_STATUS}"

# Sprint demo video — auto-generate a narrated MP4 after each sprint.
# Requires: ffmpeg, video-annotator (pip install video-annotator), macOS (for TTS).
# Set to true to enable as a post-merge hook.
GENERATE_SPRINT_VIDEO="${GENERATE_SPRINT_VIDEO:-false}"

# Post-merge hooks — commands run after a successful merge + report.
# Each hook runs with these environment variables available:
#   SPRINT_NUM, ROOT, STATUS_FILE, SPRINT_BASE
# Hooks are non-fatal: a failing hook logs a warning but does not block the pipeline.
# Override by setting POST_MERGE_HOOKS before sourcing, or edit this list.
if [ -z "${POST_MERGE_HOOKS+x}" ]; then
  POST_MERGE_HOOKS=()
fi

# Auto-register sprint video hook if enabled
if [ "$GENERATE_SPRINT_VIDEO" = "true" ]; then
  POST_MERGE_HOOKS+=("${ROOT:-${ROOT_CFG}}/.sprint/scripts/sprint-video.sh")
fi

# Messaging notifications (tool-telegram-whatsapp)
# Set WHATSUP_ENABLED=true in your project's .sprint/config.sh to enable.
# Requires: whatsup CLI installed (pip install tool-telegram-whatsapp)
WHATSUP_ENABLED="${WHATSUP_ENABLED:-false}"
WHATSUP_CMD="${WHATSUP_CMD:-$HOME/src/tool-telegram-whatsapp/.venv/bin/whatsup}"

if [ "$WHATSUP_ENABLED" = "true" ] && [ -x "$WHATSUP_CMD" ]; then
  POST_MERGE_HOOKS+=("$WHATSUP_CMD notify ${PROJECT_SLUG} sprint-merged --sprint \${SPRINT_NUM} --status passed --summary \"Sprint \${SPRINT_NUM} merged\"")
fi

# Auto-rebuild dashboard data after sprint completion.
# Set to true to POST to the dashboard API, rebuilding sessions/ADRs/sprints JSON.
AUTO_DASHBOARD_REBUILD="${AUTO_DASHBOARD_REBUILD:-true}"

# Auto-deploy after sprint completion.
# Set to a command (e.g. "npm run deploy") to run after push.
# Set to "true" to run the deploy API endpoint (dashboard-driven deploy).
# Default: empty (no auto-deploy).
AUTO_DEPLOY="${AUTO_DEPLOY:-}"
