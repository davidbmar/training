#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# check-upstream.sh — Sync sprint scripts from the framework
# ─────────────────────────────────────────────────────────────
#
# Compares md5 checksums for each tracked script against the
# framework's toolkit/ directory, copies changed files, and
# updates the local checksum cache.
#
# Framework location is resolved in this order:
#   1. FRAMEWORK_ROOT environment variable
#   2. .sprint/.framework-root file (written by setup.sh)
#   3. Default: ~/src/traceable-searchable-adr-memory-index
#
# Usage (from your project root):
#   ./.sprint/scripts/check-upstream.sh              # sync changes
#   ./.sprint/scripts/check-upstream.sh --dry-run    # preview only
#
# ─────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

# ── Resolve framework location ────────────────────────────────
if [ -n "$FRAMEWORK_ROOT" ]; then
  FW_ROOT="$FRAMEWORK_ROOT"
  FW_SOURCE="env FRAMEWORK_ROOT"
elif [ -f "$PROJECT_ROOT/.sprint/.framework-root" ]; then
  FW_ROOT="$(cat "$PROJECT_ROOT/.sprint/.framework-root")"
  FW_SOURCE=".sprint/.framework-root"
else
  FW_ROOT="$HOME/src/traceable-searchable-adr-memory-index"
  FW_SOURCE="default (~/.../traceable-searchable-adr-memory-index)"
fi

UPSTREAM="$FW_ROOT/toolkit"

if [ ! -d "$UPSTREAM" ]; then
  echo ""
  echo "  Error: Framework not found at $FW_ROOT"
  echo "  Set FRAMEWORK_ROOT or update .sprint/.framework-root"
  exit 1
fi

FILES=(
  sprint-parse.sh sprint-fix.sh sprint-validate.sh sprint-init.sh
  sprint-launch.sh sprint-run.sh sprint-merge.sh sprint-tmux.sh
  sprint-checkpoint.sh sprint-video.sh check-zero-commit-agents.sh
  CLAUDE_RUN_PROMPT.txt check-upstream.sh
)

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

DEST="$PROJECT_ROOT/.sprint/scripts"
CHECKSUM_FILE="$PROJECT_ROOT/.sprint/.checksums"

# ── Banner ───────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │  Sprint Toolkit — Upstream Sync             │"
echo "  └─────────────────────────────────────────────┘"
echo ""
echo "  Framework: $FW_ROOT"
echo "  Source:    $FW_SOURCE"
echo "  Target:    $DEST"
echo "  Mode:      $($DRY_RUN && echo 'DRY RUN (no changes)' || echo 'LIVE')"
echo ""

# ── Compare checksums ───────────────────────────────────────
changed=0
skipped=0
up_to_date=0
new_checksums=""

printf "  %-35s  %s\n" "FILE" "STATUS"
printf "  %-35s  %s\n" "───────────────────────────────────" "──────────"

for f in "${FILES[@]}"; do
  if [ ! -f "$UPSTREAM/$f" ]; then
    printf "  %-35s  %s\n" "$f" "SKIP (not in framework)"
    skipped=$((skipped + 1))
    continue
  fi

  upstream_md5=$(md5 -q "$UPSTREAM/$f" 2>/dev/null || md5sum "$UPSTREAM/$f" | awk '{print $1}')
  stored_md5=$(grep "^$f " "$CHECKSUM_FILE" 2>/dev/null | awk '{print $2}')

  if [ "$upstream_md5" != "$stored_md5" ]; then
    printf "  %-35s  %s\n" "$f" "CHANGED"
    changed=$((changed + 1))
    if ! $DRY_RUN; then
      cp "$UPSTREAM/$f" "$DEST/$f"
    fi
  else
    printf "  %-35s  %s\n" "$f" "up to date"
    up_to_date=$((up_to_date + 1))
  fi
  new_checksums+="$f $upstream_md5"$'\n'
done

# ── Summary ──────────────────────────────────────────────────
echo ""
echo "  ── Summary ──"
echo "  Up to date: $up_to_date   Changed: $changed   Skipped: $skipped"

if [ $changed -eq 0 ]; then
  echo ""
  echo "  All toolkit files are current. Nothing to do."
  exit 0
fi

# ── Seed templates (install if missing, never overwrite) ───────
SEED_TEMPLATES="$UPSTREAM/templates/seed"
SEED_DIR="$PROJECT_ROOT/docs/seed"

if [ -d "$SEED_TEMPLATES" ] && [ -d "$SEED_DIR" ]; then
  echo "  ── Seed templates ──"
  if [ ! -f "$SEED_DIR/current-state.md" ]; then
    if ! $DRY_RUN; then
      cp "$SEED_TEMPLATES/current-state.md" "$SEED_DIR/current-state.md"
      echo "    docs/seed/current-state.md       installed"
    else
      echo "    docs/seed/current-state.md       WOULD install"
    fi
  else
    echo "    docs/seed/current-state.md       exists (not overwritten)"
  fi
  echo ""
fi

# ── Sync global Claude.md ──────────────────────────────────────
GLOBAL_CLAUDE_DIR="$HOME/.claude"
GLOBAL_CLAUDE_FILE="$GLOBAL_CLAUDE_DIR/CLAUDE.md"
GLOBAL_TEMPLATE="$UPSTREAM/templates/global-claude.md"

if [ -f "$GLOBAL_TEMPLATE" ]; then
  if [ -f "$GLOBAL_CLAUDE_FILE" ] && grep -q "Afterburner" "$GLOBAL_CLAUDE_FILE" 2>/dev/null; then
    echo "  ~/.claude/CLAUDE.md                 Afterburner config present"
  elif ! $DRY_RUN; then
    mkdir -p "$GLOBAL_CLAUDE_DIR"
    if [ -f "$GLOBAL_CLAUDE_FILE" ]; then
      echo "" >> "$GLOBAL_CLAUDE_FILE"
      cat "$GLOBAL_TEMPLATE" >> "$GLOBAL_CLAUDE_FILE"
      echo "  ~/.claude/CLAUDE.md                 Afterburner config appended"
    else
      cp "$GLOBAL_TEMPLATE" "$GLOBAL_CLAUDE_FILE"
      echo "  ~/.claude/CLAUDE.md                 created with Afterburner config"
    fi
  else
    echo "  ~/.claude/CLAUDE.md                 WOULD install Afterburner config"
  fi
fi
echo ""

# ── Sync Claude skills ────────────────────────────────────────
SKILLS_SRC="$FW_ROOT/claude_skill/skills"
SKILLS_DST="$HOME/.claude/skills"

if [ -d "$SKILLS_SRC" ]; then
  echo "  ── Claude Skills ──"
  skills_updated=0
  for skill_dir in "$SKILLS_SRC"/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")
    if [ -f "$skill_dir/SKILL.md" ]; then
      if ! $DRY_RUN; then
        mkdir -p "$SKILLS_DST/$skill_name"
        cp "$skill_dir/SKILL.md" "$SKILLS_DST/$skill_name/SKILL.md"
        echo "    $skill_name   updated"
        skills_updated=$((skills_updated + 1))
      else
        echo "    $skill_name   WOULD update"
      fi
    fi
  done
  if ! $DRY_RUN && [ $skills_updated -eq 0 ]; then
    echo "    (no skills found)"
  fi
  echo ""
fi

# ── Write checksums ──────────────────────────────────────────
if ! $DRY_RUN; then
  echo -n "$new_checksums" > "$CHECKSUM_FILE"
  chmod +x "$DEST"/sprint-*.sh "$DEST"/check-*.sh 2>/dev/null
  echo ""
  echo "  Done. $changed file(s) updated."
else
  echo ""
  echo "  (Dry run — no files were changed)"
fi
