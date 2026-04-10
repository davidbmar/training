#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# sprint-video.sh — Generate a sprint demo video after merge
# ─────────────────────────────────────────────────────────────
#
# Reads the PROJECT_STATUS doc and SPRINT_BRIEF to understand
# what changed, then uses Claude to orchestrate video production
# via MCP tools (video-annotator).
#
# Can be run standalone or as a POST_MERGE_HOOK:
#   POST_MERGE_HOOKS+=(".sprint/scripts/sprint-video.sh")
#
# Environment (set by sprint-run.sh when used as hook):
#   SPRINT_NUM    — sprint number
#   ROOT          — project root directory
#   STATUS_FILE   — path to the PROJECT_STATUS doc
#   SPRINT_BASE   — worktree base directory
#
# Usage:
#   .sprint/scripts/sprint-video.sh                    # auto-detect
#   .sprint/scripts/sprint-video.sh --sprint 7         # specific sprint
#   .sprint/scripts/sprint-video.sh --dry-run          # show plan only
#   .sprint/scripts/sprint-video.sh --output demo.mp4  # custom output
#
# Prerequisites:
#   - ffmpeg (brew install ffmpeg)
#   - video-annotator with MCP tools (pip install video-annotator)
#   - macOS (for TTS via 'say' command)
#
# ─────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# ── Resolve project root ─────────────────────────────────────
if [ -n "$ROOT" ]; then
  PROJECT_ROOT="$ROOT"
else
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
fi

# ── Parse arguments ──────────────────────────────────────────
DRY_RUN=false
OUTPUT_PATH=""
SPRINT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --output)     OUTPUT_PATH="$2"; shift 2 ;;
    --sprint)     SPRINT_OVERRIDE="$2"; shift 2 ;;
    *)            echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Resolve sprint number ────────────────────────────────────
if [ -n "$SPRINT_OVERRIDE" ]; then
  SPRINT_NUM="$SPRINT_OVERRIDE"
elif [ -z "$SPRINT_NUM" ]; then
  # Auto-detect from latest PROJECT_STATUS file
  LATEST_STATUS=$(ls -1 "${PROJECT_ROOT}/docs/PROJECT_STATUS_"*.md 2>/dev/null | sort | tail -1)
  if [ -n "$LATEST_STATUS" ]; then
    SPRINT_NUM=$(echo "$LATEST_STATUS" | grep -o 'sprint[0-9]*' | grep -o '[0-9]*')
  else
    echo "  Error: Cannot determine sprint number."
    echo "  Use --sprint N or set SPRINT_NUM environment variable."
    exit 1
  fi
fi

# ── Resolve status file ──────────────────────────────────────
if [ -z "$STATUS_FILE" ] || [ ! -f "$STATUS_FILE" ]; then
  STATUS_FILE=$(ls -1 "${PROJECT_ROOT}/docs/PROJECT_STATUS_"*"-sprint${SPRINT_NUM}.md" 2>/dev/null | sort | tail -1)
fi

# ── Resolve output path ──────────────────────────────────────
if [ -z "$OUTPUT_PATH" ]; then
  OUTPUT_PATH="${PROJECT_ROOT}/docs/sprint-${SPRINT_NUM}-demo.mp4"
fi

# ── Banner ────────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │  Sprint Video — Demo Generator              │"
echo "  └─────────────────────────────────────────────┘"
echo ""
echo "  Project:  $PROJECT_ROOT"
echo "  Sprint:   $SPRINT_NUM"
echo "  Status:   ${STATUS_FILE:-'(not found)'}"
echo "  Output:   $OUTPUT_PATH"
echo "  Mode:     $($DRY_RUN && echo 'DRY RUN' || echo 'LIVE')"
echo ""

# ── Check prerequisites ──────────────────────────────────────
MISSING=""

if ! command -v ffmpeg &>/dev/null; then
  MISSING+="  - ffmpeg (brew install ffmpeg)\n"
fi

if ! command -v say &>/dev/null; then
  MISSING+="  - say (macOS TTS — required for narration)\n"
fi

if ! python3 -c "import video_annotator" &>/dev/null; then
  MISSING+="  - video-annotator (pip install video-annotator)\n"
fi

if [ -n "$MISSING" ]; then
  echo "  Missing prerequisites:"
  echo -e "$MISSING"
  if ! $DRY_RUN; then
    echo "  Install missing tools and retry."
    exit 1
  else
    echo "  (Continuing in dry-run mode)"
  fi
fi

# ── Gather context ────────────────────────────────────────────
SPRINT_BRIEF="${PROJECT_ROOT}/SPRINT_BRIEF.md"
SPRINT_BRIEF_ARCHIVED="${PROJECT_ROOT}/.sprint/history/sprint-${SPRINT_NUM}-brief.md"

# Prefer archived brief (matches completed sprint)
if [ -f "$SPRINT_BRIEF_ARCHIVED" ]; then
  BRIEF_FILE="$SPRINT_BRIEF_ARCHIVED"
elif [ -f "$SPRINT_BRIEF" ]; then
  BRIEF_FILE="$SPRINT_BRIEF"
else
  BRIEF_FILE=""
fi

# Git diff summary for the sprint
GIT_SUMMARY=$(git log --oneline --no-merges -20 2>/dev/null | head -15)

echo "  ── Context ──"
echo "  Brief:    ${BRIEF_FILE:-'(not found)'}"
echo "  Status:   ${STATUS_FILE:-'(not found)'}"
echo "  Commits:  $(echo "$GIT_SUMMARY" | wc -l | tr -d ' ') recent"
echo ""

if $DRY_RUN; then
  echo "  ── Dry Run Complete ──"
  echo "  Would generate sprint demo video at: $OUTPUT_PATH"
  echo ""
  echo "  Context files that would be read:"
  [ -n "$BRIEF_FILE" ] && echo "    - $BRIEF_FILE"
  [ -n "$STATUS_FILE" ] && echo "    - $STATUS_FILE"
  echo ""
  echo "  Claude would:"
  echo "    1. Read sprint context (brief + status + git log)"
  echo "    2. Generate a narration script"
  echo "    3. Capture screenshots of key features"
  echo "    4. Generate TTS narration for each scene"
  echo "    5. Render scenes into MP4 with crossfade transitions"
  echo ""
  exit 0
fi

# ── Build prompt for Claude ───────────────────────────────────
CONTEXT=""
if [ -f "$STATUS_FILE" ]; then
  CONTEXT+="## PROJECT_STATUS (Sprint ${SPRINT_NUM})"$'\n'
  CONTEXT+=$(cat "$STATUS_FILE")
  CONTEXT+=$'\n\n'
fi

if [ -n "$BRIEF_FILE" ] && [ -f "$BRIEF_FILE" ]; then
  CONTEXT+="## Sprint Brief"$'\n'
  CONTEXT+=$(cat "$BRIEF_FILE")
  CONTEXT+=$'\n\n'
fi

CONTEXT+="## Recent Commits"$'\n'
CONTEXT+="$GIT_SUMMARY"
CONTEXT+=$'\n'

PROMPT=$(cat <<'PROMPT_EOF'
You are generating a sprint demo video. You have access to MCP video tools.

Based on the sprint context below, create a 1-3 minute narrated demo video:

1. Call start_video_project with the sprint title
2. Add a title card introducing the sprint
3. For each major feature/change:
   - If there's a web UI to show, capture_scene with the URL and an annotation
   - Add narration explaining what was built and why it matters
4. Add a summary title card
5. Call render_video to produce the final MP4

Keep narration concise and professional. Focus on what's new and why it matters.
If the app has a web UI, capture it (default: http://localhost:7070).
If there's no web UI to show, use title cards with narration only.

PROMPT_EOF
)

FULL_PROMPT="${PROMPT}"$'\n\n'"${CONTEXT}"

echo "  ── Generating Video ──"
echo "  Invoking Claude to orchestrate video production..."
echo ""

# ── Invoke Claude with MCP tools ──────────────────────────────
# Claude will use the video-annotator MCP tools to:
# 1. start_video_project
# 2. capture_scene / add_title_card for each feature
# 3. add_narration for each scene
# 4. render_video to produce MP4
#
# The MCP server must be configured in the user's Claude settings.
# Fallback: use the CLI directly if MCP is not available.

if command -v claude &>/dev/null; then
  echo "$FULL_PROMPT" | claude --print --output-format text 2>&1 | tail -20

  if [ -f "$OUTPUT_PATH" ]; then
    echo ""
    echo "  ✓ Video generated: $OUTPUT_PATH"
    echo "  Size: $(du -h "$OUTPUT_PATH" | awk '{print $1}')"
  else
    echo ""
    echo "  [warn] Video file not found at $OUTPUT_PATH"
    echo "  Claude may have used a different output path — check annotator-reports/"
  fi
else
  echo "  [warn] Claude CLI not found. Cannot generate video automatically."
  echo ""
  echo "  Manual alternative:"
  echo "    1. Start the MCP server: python -m video_annotator.mcp_server"
  echo "    2. Use Claude to call the video MCP tools with this context:"
  echo "    3. Save the prompt context: echo '...' > /tmp/sprint-video-context.md"
  echo ""
fi

echo ""
