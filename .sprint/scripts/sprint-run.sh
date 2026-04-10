#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# sprint-run.sh — Fully automated two-phase sprint execution
#
# Runs an entire sprint hands-free:
#   Phase 1: Init worktrees → launch agents → poll for completion → merge → test
#   Phase 2: Init worktrees → launch agents → poll for completion → merge → test
#   Final:   Collect metrics → generate project status report → commit → push
#
# Usage:
#   ./scripts/sprint-run.sh              # Run full sprint (both phases)
#   ./scripts/sprint-run.sh --phase 1    # Run Phase 1 only
#   ./scripts/sprint-run.sh --phase 2    # Run Phase 2 only (after Phase 1 is done)
#   ./scripts/sprint-run.sh --skip-report # Skip report generation at the end
#   ./scripts/sprint-run.sh --continue   # Resume: skip completed steps
#   ./scripts/sprint-run.sh --skip-validate # Skip pre-flight validation
#   ./scripts/sprint-run.sh --push       # Auto-push to origin after completion
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Defaults for optional features (must be set before set -u bites)
WHATSUP_ENABLED="${WHATSUP_ENABLED:-false}"
WHATSUP_CMD="${WHATSUP_CMD:-}"

# shellcheck source=./sprint-parse.sh
source "${SCRIPT_DIR}/sprint-parse.sh"

LAUNCH_CMD="${SCRIPT_DIR}/sprint-launch.sh"
SPRINT_NOTES="${ROOT}/Sprint-Notes.md"
POLL_INTERVAL=60  # seconds between completion checks
SKIP_REPORT=false
VERIFICATION_FAILED=false
CONTINUE_MODE=false
SKIP_VALIDATE=false
AUTO_PUSH=false
RUN_PHASE=""

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --phase) shift; RUN_PHASE="${1:-}"; shift ;;
    --skip-report) SKIP_REPORT=true; shift ;;
    --skip-validate) SKIP_VALIDATE=true; shift ;;
    --continue) CONTINUE_MODE=true; shift ;;
    --push) AUTO_PUSH=true; shift ;;
    --poll-interval) shift; POLL_INTERVAL="${1:-60}"; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Timing helpers (bash 3 compatible — no associative arrays)
# ---------------------------------------------------------------------------

TIMING_FILE="${ROOT}/.sprint-timing.txt"

# Get current epoch seconds
now_s() { date +%s; }

# Format seconds as human-readable duration
format_duration() {
  local secs="$1"
  local hours=$((secs / 3600))
  local mins=$(( (secs % 3600) / 60 ))
  local s=$((secs % 60))
  if [ $hours -gt 0 ]; then
    printf '%dh %dm %ds' "$hours" "$mins" "$s"
  elif [ $mins -gt 0 ]; then
    printf '%dm %ds' "$mins" "$s"
  else
    printf '%ds' "$s"
  fi
}

# Record a timing entry: timer_record <label> <start_epoch> [end_epoch]
# If end_epoch is omitted, uses current time
timer_record() {
  local label="$1"
  local start="$2"
  local end="${3:-$(now_s)}"
  local elapsed=$((end - start))
  printf '%s\t%s\t%s\n' "$label" "$elapsed" "$(format_duration $elapsed)" >> "$TIMING_FILE"
  log "${label}: $(format_duration $elapsed)"
}

# Read a timing value by label (returns seconds)
timer_get() {
  local label="$1"
  grep "^${label}	" "$TIMING_FILE" 2>/dev/null | tail -1 | cut -f2 || echo "0"
}

# Print the full timing summary
print_timing_summary() {
  echo ""
  echo "============================================================"
  echo "  Sprint ${SPRINT_NUM} — Timing Summary"
  echo "============================================================"
  if [ -f "$TIMING_FILE" ]; then
    while IFS=$'\t' read -r label secs human; do
      printf '  %-35s %s\n' "$label" "$human"
    done < "$TIMING_FILE"
  fi
  echo "============================================================"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[$(date -u '+%H:%M:%S')] $*"; }

# Check if an agent branch has already been merged into main.
# Returns 0 (true) if the branch tip is reachable from main — meaning a merge
# would produce "Already up to date." This covers both merge commits and
# fast-forward merges regardless of commit message content.
agent_already_merged() {
  local agent="$1"
  # Branch exists and its tip is an ancestor of (or equal to) main?
  if git rev-parse --verify "$agent" >/dev/null 2>&1; then
    git merge-base --is-ancestor "$agent" main 2>/dev/null && return 0
  fi
  # Branch doesn't exist locally — check merge log as fallback
  local log_output
  log_output=$(git log --oneline --first-parent main -100 2>/dev/null || true)
  echo "$log_output" | grep -q "Merge branch '${agent}'" 2>/dev/null
}

# Check if ALL agents in a list are already merged into main
all_agents_merged() {
  local agents=("$@")
  for agent in "${agents[@]}"; do
    if ! agent_already_merged "$agent"; then
      return 1
    fi
  done
  return 0
}

# Check if all agents in a list have completed their work.
# Used to decide whether to LAUNCH agents — distinct from wait_for_agents
# which decides when to MERGE.
#
# An agent is complete if:
#   - its done-marker file exists (written by sprint-launch.sh at the very end), OR
#   - it has commits ahead of main (work done — may still be running, but
#     don't re-launch; wait_for_agents handles the "truly done" gate)
#
# An agent that exists but has 0 commits ahead and no done-marker was just
# created by sprint-init.sh and hasn't started work yet — NOT complete.
all_agents_complete() {
  local agents=("$@")
  for agent in "${agents[@]}"; do
    # Done-marker from sprint-launch.sh? Complete.
    if [ -f "${ROOT}/.agent-done-${agent}" ]; then
      continue
    fi
    # Branch doesn't exist yet? Not complete.
    if ! git rev-parse --verify "$agent" >/dev/null 2>&1; then
      return 1
    fi
    # Has commits ahead of main? Agent has started work — don't re-launch.
    local count
    count=$(git log "main..${agent}" --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 0 ]; then
      continue
    fi
    # Branch exists but no commits ahead and no done-marker = just created
    return 1
  done
  return 0
}

# Poll until all agents have finished their full launch pipeline.
# Checks for done-marker files written by sprint-launch.sh at the very end
# (after Claude exits, tests run, and final commit is made).
# Falls back to commit-count check for agents launched outside this script.
wait_for_agents() {
  local phase_name="$1"
  shift
  local agents=("$@")

  log "Waiting for ${#agents[@]} ${phase_name} agents to complete..."
  log "Polling every ${POLL_INTERVAL}s. Agents:"
  for a in "${agents[@]}"; do
    echo "    - $a"
  done
  echo ""

  # Track which agents we've already sent notifications for (bash 3 compatible)
  local notified_agents=""

  while true; do
    local done_count=0
    local total=${#agents[@]}
    local pending=()

    for agent in "${agents[@]}"; do
      # Primary check: done-marker file (written at end of sprint-launch.sh)
      if [ -f "${ROOT}/.agent-done-${agent}" ]; then
        done_count=$((done_count + 1))
        # Send whatsup notification once per agent completion
        if ! echo "$notified_agents" | grep -qF "|${agent}|"; then
          notified_agents="${notified_agents}|${agent}|"
          if [ "$WHATSUP_ENABLED" = "true" ] && [ -x "$WHATSUP_CMD" ]; then
            "$WHATSUP_CMD" notify "${PROJECT_SLUG}" agent-completed --sprint "${SPRINT_NUM}" --agent "${agent}" 2>/dev/null || true
          fi
        fi
        continue
      fi
      pending+=("$agent")
    done

    if [ $done_count -eq $total ]; then
      log "All ${total} ${phase_name} agents complete!"
      echo ""
      return 0
    fi

    log "${done_count}/${total} complete. Waiting: ${pending[*]}"
    sleep "$POLL_INTERVAL"
  done
}

# Launch agents in background tmux session (non-blocking)
launch_agents_tmux() {
  local session_name="$1"
  shift
  local agents=("$@")

  # Clean stale done-markers from prior runs
  for agent in "${agents[@]}"; do
    rm -f "${ROOT}/.agent-done-${agent}"
  done

  # Kill existing session if present
  tmux kill-session -t "$session_name" 2>/dev/null || true

  # Create tmux session with first agent
  local first_agent="${agents[0]}"
  tmux new-session -d -s "$session_name" -n "$first_agent" \
    "unset CLAUDECODE; bash -lc '${LAUNCH_CMD} ${first_agent}; exec bash'"

  # Create a tab for each remaining agent
  for agent in "${agents[@]:1}"; do
    tmux new-window -t "$session_name" -n "$agent" \
      "unset CLAUDECODE; bash -lc '${LAUNCH_CMD} ${agent}; exec bash'"
  done

  log "Launched ${#agents[@]} agents in tmux session: ${session_name}"
  echo "  Attach: tmux attach -t ${session_name}"
  echo ""
}

# Merge a list of agents, optionally skipping per-merge tests
merge_agents() {
  local phase_name="$1"
  local skip_per_merge="$2"
  shift 2
  local agents=("$@")

  local ephemeral_files=("AGENT_BRIEF.md" ".claude-output.txt" "docs/project-memory/.index/last-updated.txt")
  local merged=0
  local total=${#agents[@]}

  log "Merging ${total} ${phase_name} branches..."
  echo ""

  for agent in "${agents[@]}"; do
    merged=$((merged + 1))

    # Clean ephemeral/generated files before EACH merge — prevents
    # "local changes would be overwritten" errors from:
    #   - .index/ files rebuilt by pre-commit hooks
    #   - public/api/*.json regenerated by npm run prebuild
    #   - sprint metric/timing files updated by this script
    git checkout -- docs/project-memory/.index/ 2>/dev/null || true
    git clean -f docs/project-memory/.index/ 2>/dev/null || true
    git checkout -- public/api/ 2>/dev/null || true
    for ef in "${ephemeral_files[@]}"; do
      git checkout -- "$ef" 2>/dev/null || true
    done
    # Commit any remaining dirty tracked files to unblock merge
    if ! git diff --quiet 2>/dev/null; then
      git add -A 2>/dev/null || true
      git commit -m "chore: auto-commit dirty files before merge (sprint ${SPRINT_NUM})" --no-verify 2>/dev/null || true
    fi

    # In continue mode, skip agents already merged into main
    if $CONTINUE_MODE && agent_already_merged "$agent"; then
      echo "=== [$merged/$total] ${agent} — already merged, skipping ==="
      echo ""
      continue
    fi

    echo "=== [$merged/$total] Merging ${agent} ==="

    if ! git rev-parse --verify "$agent" >/dev/null 2>&1; then
      echo "Error: Branch '${agent}' does not exist"
      exit 1
    fi

    if git merge "$agent" --no-edit 2>&1; then
      echo "[clean]   ${agent}"
    else
      # Auto-resolve conflicts
      local has_real=false
      local real_files=()
      for file in $(git diff --name-only --diff-filter=U); do
        local is_eph=false
        for eph in "${ephemeral_files[@]}"; do
          if [[ "$file" == "$eph" ]] || [[ "$file" == docs/project-memory/.index/* ]]; then
            is_eph=true
            break
          fi
        done

        if $is_eph; then
          git checkout --theirs "$file" 2>/dev/null && git add "$file"
          echo "  [auto]  ${file} — ephemeral, accepted theirs"
        else
          # For Phase 1 file conflicts: if this file was created by an
          # earlier agent in merge order, keep ours (the earlier agent's
          # version is already on main). This handles the case where two
          # agents both create the same file.
          if [ "$skip_per_merge" = "true" ]; then
            # Check if this is a new file conflict (both sides added)
            local conflict_type
            conflict_type=$(git status --porcelain "$file" 2>/dev/null | head -c2)
            if [ "$conflict_type" = "AA" ] || [ "$conflict_type" = "UU" ]; then
              # In Phase 1, earlier agent in merge order owns the file
              git checkout --ours "$file" 2>/dev/null && git add "$file"
              echo "  [auto]  ${file} — file ownership conflict, kept ours (earlier agent)"
            else
              has_real=true
              real_files+=("$file")
              echo "  [MANUAL] ${file} — requires manual resolution"
            fi
          else
            has_real=true
            real_files+=("$file")
            echo "  [MANUAL] ${file} — requires manual resolution"
          fi
        fi
      done

      if $has_real; then
        echo ""
        echo "=== MERGE PAUSED — manual resolution required ==="
        echo "Conflicting files: ${real_files[*]}"
        echo "Resolve conflicts, then: git add <files> && git commit --no-edit"
        echo "Then re-run: $0 --continue"
        exit 1
      fi

      git add docs/project-memory/.index/ 2>/dev/null || true
      git commit --no-edit
      echo "[resolved] ${agent} (auto-resolved)"
    fi

    # Per-merge test (Phase 2 only)
    if [ "$skip_per_merge" = "false" ]; then
      echo "--- Verification ---"
      for cmd in "${MERGE_VERIFY[@]}"; do
        if ! eval "$cmd" 2>&1; then
          echo "=== VERIFICATION FAILED after ${agent} ==="
          exit 1
        fi
      done
    fi

    echo ""
  done

  log "All ${total} ${phase_name} branches merged."
}

# Collect project metrics (LOC, test counts, git stats)
collect_metrics() {
  local metrics_file="${ROOT}/.sprint-metrics.txt"

  log "Collecting project metrics..."

  # TypeScript LOC
  local ts_loc
  local ts_dirs=()
  for d in "${ROOT}/packages" "${ROOT}/services" "${ROOT}/src"; do
    [ -d "$d" ] && ts_dirs+=("$d")
  done
  if [ ${#ts_dirs[@]} -gt 0 ]; then
    ts_loc=$(find "${ts_dirs[@]}" -name '*.ts' -not -path '*/node_modules/*' -not -path '*/dist/*' 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
  else
    ts_loc=0
  fi

  # Swift LOC
  local swift_loc=0
  local swift_files=0
  if [ -d "${ROOT}/client" ]; then
    swift_loc=$(find "${ROOT}/client" -name '*.swift' -not -path '*/build/*' 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
    swift_files=$(find "${ROOT}/client" -name '*.swift' -not -path '*/build/*' 2>/dev/null | wc -l | tr -d ' ')
  fi

  # Test count (reuse saved test output from final verification — no re-run needed)
  # Handles two output formats:
  #   Jest/Vitest: "357 passed"
  #   node:test:  "ℹ pass 357"  (grep exits 1 on no-match → pipefail would kill script)
  local test_count
  local test_output_file="${ROOT}/.sprint-test-output.txt"
  if [ -s "$test_output_file" ]; then
    local jest_count node_count
    jest_count=$(grep -oE '[0-9]+ passed' "$test_output_file" 2>/dev/null | awk '{sum += $1} END {print sum+0}' || echo "0")
    node_count=$(grep -oE 'pass [0-9]+' "$test_output_file" 2>/dev/null | grep -oE '[0-9]+$' | awk '{sum += $1} END {print sum+0}' || echo "0")
    test_count=$(( ${jest_count:-0} + ${node_count:-0} ))
  else
    # Fallback: run tests if no saved output (e.g., manual invocation)
    local test_output
    test_output=$(npm test --prefix "${ROOT}" 2>&1 || true)
    local jest_count node_count
    jest_count=$(echo "$test_output" | grep -oE '[0-9]+ passed' 2>/dev/null | awk '{sum += $1} END {print sum+0}' || echo "0")
    node_count=$(echo "$test_output" | grep -oE 'pass [0-9]+' 2>/dev/null | grep -oE '[0-9]+$' | awk '{sum += $1} END {print sum+0}' || echo "0")
    test_count=$(( ${jest_count:-0} + ${node_count:-0} ))
  fi

  # Git stats for this sprint
  local sprint_commits sprint_insertions sprint_deletions sprint_files_changed
  # Find the previous sprint's status commit as the base for diffstat.
  # This is the most reliable anchor — it's always the last commit before
  # the current sprint's agent work began.
  local base_sha=""
  local prev_sprint=$((SPRINT_NUM - 1))
  local full_log
  full_log=$(git log --oneline --first-parent main -200 2>/dev/null || true)
  # Look for "Sprint NN project status" or "sprint NN" status commit
  base_sha=$(echo "$full_log" | grep -i -m1 "sprint.*${prev_sprint}.*status\|Sprint ${prev_sprint} project" | awk '{print $1}' || true)
  # Fallback: find the first commit that isn't a merge or agent commit
  if [ -z "$base_sha" ]; then
    base_sha=$(echo "$full_log" | grep -v -E "Merge branch|Wire Sprint|Add E2E|^[0-9a-f]+ agent" | head -1 | awk '{print $1}' || true)
  fi
  if [ -n "$base_sha" ]; then
    local diffstat
    diffstat=$(git diff --shortstat "${base_sha}..HEAD" 2>/dev/null || echo "")
    sprint_files_changed=$(echo "$diffstat" | grep -oE '[0-9]+ file' | awk '{print $1}' || echo "0")
    sprint_insertions=$(echo "$diffstat" | grep -oE '[0-9]+ insertion' | awk '{print $1}' || echo "0")
    sprint_deletions=$(echo "$diffstat" | grep -oE '[0-9]+ deletion' | awk '{print $1}' || echo "0")
  fi

  # API route count
  local route_count
  route_count=$(grep -c 'router\.add' "${ROOT}/services/api-gateway/src/server.ts" 2>/dev/null || echo "0")

  {
    echo "ts_loc=${ts_loc:-0}"
    echo "swift_loc=${swift_loc:-0}"
    echo "swift_files=${swift_files:-0}"
    echo "test_count=${test_count:-0}"
    echo "sprint_files_changed=${sprint_files_changed:-0}"
    echo "sprint_insertions=${sprint_insertions:-0}"
    echo "sprint_deletions=${sprint_deletions:-0}"
    echo "route_count=${route_count:-0}"
  } > "$metrics_file"

  log "Metrics collected:"
  while IFS= read -r line; do
    echo "  $line"
  done < "$metrics_file"
}

# Generate planning context for next sprint (appended to status doc)
generate_planning_context() {
  local context_file="${ROOT}/.sprint-planning-context.txt"

  log "Generating planning context..."

  # Disable errexit — all paths below are best-effort inventory
  set +e
  {
    echo "## Planning Context for Next Sprint"
    echo ""
    echo "This section provides the codebase inventory needed to plan the next sprint."
    echo ""

    # Migration inventory
    echo "### Database Migrations"
    echo ""
    local migration_dir="${ROOT}/services/api-gateway/migration"
    local migration_count
    migration_count=$(ls -1 "$migration_dir"/*.sql 2>/dev/null | wc -l | tr -d ' ')
    local last_migration
    last_migration=$(ls -1 "$migration_dir" 2>/dev/null | sort | tail -1 | grep -oE '^[0-9]+' || echo "000")
    local next_migration=$((10#$last_migration + 1))

    # Check for duplicate prefixes (would crash migration-runner at runtime)
    local dup_prefixes
    dup_prefixes=$(ls -1 "$migration_dir" 2>/dev/null | grep -oE '^\d{3}' | sort | uniq -d || true)
    if [ -n "$dup_prefixes" ]; then
      log "WARNING: Duplicate migration prefixes detected: $dup_prefixes"
      echo "**WARNING: Duplicate migration prefixes detected: $dup_prefixes** — must be resolved before next sprint!"
      echo ""
    fi

    printf "**Total migration files: %d | Highest number: %s | Next available: %03d**\n" "$migration_count" "$last_migration" "$next_migration"
    echo ""
    echo "Existing migrations:"
    echo '```'
    ls -1 "$migration_dir" 2>/dev/null | sed 's/\.sql$//'
    echo '```'
    echo ""

    # API route inventory
    echo "### API Routes"
    echo ""
    echo "**Registered routes in server.ts:**"
    echo '```'
    grep -E 'router\.add\(' "${ROOT}/services/api-gateway/src/server.ts" 2>/dev/null | sed 's/^[[:space:]]*router\.add("//' | sed 's/", "/  /' | sed 's/",.*//' | sort || echo "(none found)"
    echo '```'
    echo ""
    echo "**Route files:** $(ls -1 "${ROOT}/services/api-gateway/src/routes/" 2>/dev/null | grep -v '^intelligence/$' | tr '\n' ', ' | sed 's/,$//')"
    echo ""

    # Intelligence engine module map
    echo "### Intelligence Engine Modules"
    echo ""
    echo '```'
    find "${ROOT}/services/intelligence-engine/src" -type d -maxdepth 2 2>/dev/null | sed "s|${ROOT}/services/intelligence-engine/src||" | sort | grep -v '^$' | sed 's|^/|  |'
    echo '```'
    echo ""

    # Barrel exports summary
    echo "### Barrel Exports (intelligence-engine)"
    echo ""
    local export_count
    export_count=$(grep -c '^export' "${ROOT}/services/intelligence-engine/src/index.ts" 2>/dev/null || echo "0")
    echo "**${export_count} export lines** in \`services/intelligence-engine/src/index.ts\`"
    echo ""
    echo "Export categories:"
    echo '```'
    grep '^// ' "${ROOT}/services/intelligence-engine/src/index.ts" 2>/dev/null | head -30 || echo "(no section comments)"
    echo '```'
    echo ""

    # Packages and services
    echo "### Packages ($(ls -1 "${ROOT}/packages/" 2>/dev/null | wc -l | tr -d ' '))"
    echo ""
    echo '```'
    ls -1 "${ROOT}/packages/" 2>/dev/null
    echo '```'
    echo ""

    echo "### Services ($(ls -1 "${ROOT}/services/" 2>/dev/null | wc -l | tr -d ' '))"
    echo ""
    echo '```'
    ls -1 "${ROOT}/services/" 2>/dev/null
    echo '```'
    echo ""

    # iOS structure
    echo "### iOS Directory Structure"
    echo ""
    echo '```'
    find "${ROOT}/client/ios/Rosa/Rosa" -type d -maxdepth 2 2>/dev/null | sed "s|${ROOT}/client/ios/Rosa/Rosa||" | sort | grep -v '^$' | sed 's|^/|  |'
    echo '```'
    echo ""
    local swift_count
    swift_count=$(find "${ROOT}/client" -name '*.swift' 2>/dev/null | wc -l | tr -d ' ')
    echo "**${swift_count} Swift files**"
    echo ""

    # Sprint brief rules reminder
    echo "### Sprint Brief Rules"
    echo ""
    echo "- **Two-phase model**: Phase 1 = new files only (no index.ts, server.ts, api-types). Phase 2 = barrel exports, route wiring, OpenAPI types."
    echo "- **Test naming**: \`agentX_slug.test.ts\` (uppercase letter, underscore, slug)"
    echo "- **Test imports**: Phase 1 imports directly from source, not barrels"
    echo "- **No file collisions**: No two agents may create or modify the same file"
    echo "- **Migration numbers**: Pre-assign unique numbers per agent"
    echo "- **Agent naming**: \`agent<LETTER>-<slug>\` (uppercase A-Z)"
    echo "- **iOS rules**: Use canonical components, RosaDesignSystem colors, don't modify five-tab nav"
    echo "- **Barrel + route wiring can be combined** into a single Phase 2 agent"
    echo ""

  } > "$context_file"
  set -e

  log "Planning context generated: ${context_file}"
}

# ---------------------------------------------------------------------------
# Cleanup trap — always rebuild dashboard data on exit (F-012)
# ---------------------------------------------------------------------------

cleanup_and_rebuild() {
  local exit_code=$?
  # (1) Kill any remaining agent tmux sessions
  tmux kill-session -t "sprint${SPRINT_NUM}p1" 2>/dev/null || true
  tmux kill-session -t "sprint${SPRINT_NUM}p2" 2>/dev/null || true

  # (2) Rebuild dashboard data if the build script exists
  local build_script="${SCRIPT_DIR}/../scripts/build-sprint-data.sh"
  if [ ! -f "$build_script" ]; then
    build_script="${ROOT}/.sprint/scripts/build-sprint-data.sh"
  fi
  if [ -f "$build_script" ]; then
    bash "$build_script" 2>/dev/null || true
    echo "[$(date -u '+%H:%M:%S')] Dashboard data rebuilt"
  fi

  return $exit_code
}

trap cleanup_and_rebuild EXIT

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------

SPRINT_START=$(now_s)

# Initialize timing file (fresh unless continuing)
if ! $CONTINUE_MODE; then
  > "$TIMING_FILE"
fi

echo "============================================================"
echo "  Sprint ${SPRINT_NUM} — Automated Run"
echo "  Phase 1 agents: ${#PHASE1_AGENTS[@]}"
echo "  Phase 2 agents: ${#PHASE2_AGENTS[@]}"
echo "  Total agents:   ${#AGENTS[@]}"
$CONTINUE_MODE && echo "  Mode: CONTINUE (skipping completed steps)"
$AUTO_PUSH && echo "  Auto-push: ON"
echo "============================================================"
echo ""

# Confirm we're on main
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "Error: Must be on main branch (currently on '${CURRENT_BRANCH}')"
  exit 1
fi

# Ensure file descriptor limit is high enough for concurrent agent sessions
MIN_FD=10240
CURRENT_FD=$(ulimit -n)
if [ "$CURRENT_FD" -lt "$MIN_FD" ]; then
  ulimit -n "$MIN_FD" 2>/dev/null || true
  NEW_FD=$(ulimit -n)
  if [ "$NEW_FD" -lt "$MIN_FD" ]; then
    echo "Warning: File descriptor limit is ${NEW_FD} (need ${MIN_FD} for ${#AGENTS[@]} agents)."
    echo "Run 'ulimit -n ${MIN_FD}' before launching, or add it to ~/.zshrc."
    exit 1
  fi
  log "Raised file descriptor limit: ${CURRENT_FD} → ${NEW_FD}"
fi

# ===== AUTO-FIX SPRINT BRIEF =====
if ! $CONTINUE_MODE && [ -f "${SCRIPT_DIR}/sprint-fix.sh" ]; then
  log "Auto-correcting SPRINT_BRIEF.md formatting..."
  "${SCRIPT_DIR}/sprint-fix.sh" --quiet || true
fi

# ===== PRE-FLIGHT VALIDATION =====
if ! $SKIP_VALIDATE && ! $CONTINUE_MODE; then
  VALIDATE_START=$(now_s)
  log "Running pre-flight validation..."
  if ! "${SCRIPT_DIR}/sprint-validate.sh"; then
    echo ""
    echo "Fix validation errors before launching."
    echo "Or run with --skip-validate to bypass."
    exit 1
  fi
  timer_record "Validation" "$VALIDATE_START"
  echo ""
fi

# ===== VERIFICATION COMMAND PRE-CHECK (F-011) =====
# Before launching agents, ensure every binary referenced in Merge Verification
# commands actually exists on PATH. Fail fast with a clear error.
if ! $SKIP_VALIDATE && ! $CONTINUE_MODE; then
  MISSING_CMDS=()
  for vcmd in "${MERGE_VERIFY[@]}"; do
    # Extract the first word (the binary) from the command
    binary=$(echo "$vcmd" | awk '{print $1}')
    if ! command -v "$binary" >/dev/null 2>&1; then
      MISSING_CMDS+=("$binary (from: $vcmd)")
    fi
  done
  if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
    echo ""
    echo "=== VERIFICATION COMMAND PRE-CHECK FAILED ==="
    echo "The following binaries are not on PATH:"
    for mc in "${MISSING_CMDS[@]}"; do
      echo "  - $mc"
    done
    echo ""
    echo "Install the missing commands or update Merge Verification in SPRINT_BRIEF.md."
    exit 1
  fi
  log "Verification command pre-check passed (${#MERGE_VERIFY[@]} commands)."
  echo ""
fi

# ===== PHASE 1 =====
if [ -z "$RUN_PHASE" ] || [ "$RUN_PHASE" = "1" ]; then
  if [ ${#PHASE1_AGENTS[@]} -gt 0 ]; then

    # Continue mode: skip Phase 1 entirely if all agents are already merged
    if $CONTINUE_MODE && all_agents_merged "${PHASE1_AGENTS[@]}"; then
      log "Phase 1: All ${#PHASE1_AGENTS[@]} agents already merged — skipping."
      echo ""
    else
      P1_START=$(now_s)
      log "===== PHASE 1: Feature Agents (${#PHASE1_AGENTS[@]}) ====="
      echo ""

      # Notify sprint started (non-fatal — silently skips if whatsup not installed)
      if [ "$WHATSUP_ENABLED" = "true" ] && [ -x "$WHATSUP_CMD" ]; then
        "$WHATSUP_CMD" notify "${PROJECT_SLUG}" sprint-started --sprint "${SPRINT_NUM}" 2>/dev/null || true
      fi

      # Init worktrees (idempotent — sprint-init.sh handles [exists])
      log "Initializing Phase 1 worktrees..."
      "${SCRIPT_DIR}/sprint-init.sh" 1
      echo ""

      # Initialize Sprint-Notes.md (only if not resuming)
      if ! $CONTINUE_MODE || [ ! -f "$SPRINT_NOTES" ]; then
        cat > "$SPRINT_NOTES" <<EOF
# Sprint ${SPRINT_NUM} — Agent Notes

*Started: $(date -u '+%Y-%m-%d %H:%M UTC')*

Phase 1 Agents: ${#PHASE1_AGENTS[@]}
$(printf -- '- %s\n' "${PHASE1_AGENTS[@]}")

Phase 2 Agents: ${#PHASE2_AGENTS[@]}
$([ ${#PHASE2_AGENTS[@]} -gt 0 ] && printf -- '- %s\n' "${PHASE2_AGENTS[@]}" || echo "(none)")

Automated summaries from each agent are appended below as they complete.
EOF
      fi

      # Launch agents (skip if all already have commits — they've finished)
      if all_agents_complete "${PHASE1_AGENTS[@]}"; then
        log "All Phase 1 agents already have commits — skipping launch."
      else
        P1_AGENTS_START=$(now_s)
        launch_agents_tmux "sprint${SPRINT_NUM}p1" "${PHASE1_AGENTS[@]}"

        # Poll for completion
        wait_for_agents "Phase 1" "${PHASE1_AGENTS[@]}"
        timer_record "Phase 1 agents (execution)" "$P1_AGENTS_START"
      fi

      # Merge Phase 1 (skip per-merge tests — new files only)
      # In continue mode, already-merged agents are skipped inside merge_agents
      P1_MERGE_START=$(now_s)
      merge_agents "Phase 1" "true" "${PHASE1_MERGE_ORDER[@]}"
      timer_record "Phase 1 merge" "$P1_MERGE_START"

      # Install any new dependencies introduced by merged agents.
      # Agents may add packages to service-level package.json that aren't
      # installed on main yet. Without this, tests fail on missing modules.
      log "Installing dependencies after Phase 1 merges..."
      for svc_pkg in "${ROOT}"/packages/*/package.json "${ROOT}"/services/*/package.json; do
        svc_dir="$(dirname "$svc_pkg")"
        [ -f "$svc_pkg" ] || continue
        (cd "$svc_dir" && npm install --ignore-scripts 2>&1 | tail -1) || true
      done
      log "Dependencies installed."
      echo ""

      # Run tests once after all Phase 1 merges
      P1_VERIFY_START=$(now_s)
      log "Running post-Phase-1 verification..."
      for cmd in "${MERGE_VERIFY[@]}"; do
        log "Running: ${cmd}"
        if ! eval "$cmd" 2>&1; then
          echo ""
          echo "=== PHASE 1 VERIFICATION FAILED ==="
          echo "Continuing to report generation — fix issues afterward."
          VERIFICATION_FAILED=true
          break
        fi
      done
      timer_record "Phase 1 verification" "$P1_VERIFY_START"
      timer_record "Phase 1 total" "$P1_START"
      if $VERIFICATION_FAILED; then
        log "[warn] Phase 1 verification failed — report will still be generated."
      else
        log "Phase 1 verification passed."
      fi
      echo ""
    fi
  fi
fi

# ===== PHASE 2 =====
if [ -z "$RUN_PHASE" ] || [ "$RUN_PHASE" = "2" ]; then
  if [ ${#PHASE2_AGENTS[@]} -gt 0 ]; then

    # Continue mode: skip Phase 2 entirely if all agents are already merged
    if $CONTINUE_MODE && all_agents_merged "${PHASE2_AGENTS[@]}"; then
      log "Phase 2: All ${#PHASE2_AGENTS[@]} agents already merged — skipping."
      echo ""
    else
      P2_START=$(now_s)
      log "===== PHASE 2: Integration Agents (${#PHASE2_AGENTS[@]}) ====="
      echo ""

      # Init worktrees (from updated main, after Phase 1 merges)
      log "Initializing Phase 2 worktrees..."
      "${SCRIPT_DIR}/sprint-init.sh" 2
      echo ""

      # Launch agents (skip if all already have commits)
      if all_agents_complete "${PHASE2_AGENTS[@]}"; then
        log "All Phase 2 agents already have commits — skipping launch."
      else
        P2_AGENTS_START=$(now_s)
        launch_agents_tmux "sprint${SPRINT_NUM}p2" "${PHASE2_AGENTS[@]}"

        # Poll for completion
        wait_for_agents "Phase 2" "${PHASE2_AGENTS[@]}"
        timer_record "Phase 2 agents (execution)" "$P2_AGENTS_START"
      fi

      # Merge Phase 2 (with per-merge tests — touching shared files)
      P2_MERGE_START=$(now_s)
      merge_agents "Phase 2" "false" "${PHASE2_MERGE_ORDER[@]}"
      timer_record "Phase 2 merge + verify" "$P2_MERGE_START"
      timer_record "Phase 2 total" "$P2_START"

      log "Phase 2 complete."
      echo ""
    fi
  else
    log "No Phase 2 agents — skipping."
    echo ""
  fi
fi

# ===== POST-MERGE DEPENDENCY INSTALL =====
log "Installing dependencies after all merges..."
for svc_pkg in "${ROOT}"/packages/*/package.json "${ROOT}"/services/*/package.json; do
  svc_dir="$(dirname "$svc_pkg")"
  [ -f "$svc_pkg" ] || continue
  (cd "$svc_dir" && npm install --ignore-scripts 2>&1 | tail -1) || true
done
log "Dependencies installed."
echo ""

# ===== FINAL VERIFICATION =====
FINAL_VERIFY_START=$(now_s)
FINAL_TEST_OUTPUT_FILE="${ROOT}/.sprint-test-output.txt"
: > "$FINAL_TEST_OUTPUT_FILE"
log "Running final verification..."
for cmd in "${MERGE_VERIFY[@]}"; do
  log "Running: ${cmd}"
  if eval "$cmd" 2>&1 | tee -a "$FINAL_TEST_OUTPUT_FILE"; then
    true
  else
    echo "=== FINAL VERIFICATION FAILED ==="
    echo "Continuing to report generation — fix issues afterward."
    VERIFICATION_FAILED=true
    break
  fi
done
timer_record "Final verification" "$FINAL_VERIFY_START"
if $VERIFICATION_FAILED; then
  log "[warn] Final verification failed — report will still be generated."
else
  log "All tests pass."
fi
echo ""

# ===== XCODE PROJECT SYNC =====
if [ -f "${SCRIPT_DIR}/xcode-sync.sh" ]; then
  XCODE_START=$(now_s)
  log "Syncing new Swift files to Xcode project..."
  "${SCRIPT_DIR}/xcode-sync.sh" || true
  timer_record "Xcode sync" "$XCODE_START"
  echo ""
fi

# ===== METRICS COLLECTION =====
METRICS_START=$(now_s)
collect_metrics
timer_record "Metrics collection" "$METRICS_START"
echo ""

# ===== PLANNING CONTEXT =====
CONTEXT_START=$(now_s)
generate_planning_context
timer_record "Planning context" "$CONTEXT_START"
echo ""

# ===== REPORT GENERATION =====
# Always define STATUS_FILE so post-merge hooks can reference it
STATUS_FILE="${ROOT}/docs/PROJECT_STATUS_$(date -u +%-m-%-d)-sprint${SPRINT_NUM}.md"

if ! $SKIP_REPORT; then
  REPORT_START=$(now_s)
  PREV_STATUS=$(ls -1 "${ROOT}/docs/PROJECT_STATUS_"*.md 2>/dev/null | sort | tail -1)
  METRICS_FILE="${ROOT}/.sprint-metrics.txt"

  log "Generating project status report..."
  echo "  Previous: ${PREV_STATUS}"
  echo "  Output:   ${STATUS_FILE}"
  echo ""

  # Build timing summary for the report prompt
  TIMING_SUMMARY=""
  if [ -f "$TIMING_FILE" ]; then
    TIMING_SUMMARY="Sprint Timing Data (include in a 'Sprint Timing' section in the report):
"
    while IFS=$'\t' read -r label secs human; do
      TIMING_SUMMARY="${TIMING_SUMMARY}  ${label}: ${human}
"
    done < "$TIMING_FILE"
  fi

  # Build metrics summary for the report prompt
  METRICS_SUMMARY=""
  if [ -f "$METRICS_FILE" ]; then
    METRICS_SUMMARY="Project Metrics (use these exact numbers in the report):
$(cat "$METRICS_FILE")"
  fi

  # Build planning context for the report prompt
  PLANNING_CONTEXT=""
  PLANNING_CONTEXT_FILE="${ROOT}/.sprint-planning-context.txt"
  if [ -f "$PLANNING_CONTEXT_FILE" ]; then
    PLANNING_CONTEXT="$(cat "$PLANNING_CONTEXT_FILE")"
  fi

  REPORT_PROMPT="Generate the Sprint ${SPRINT_NUM} project status document.

You MUST follow the exact format and sections used in the previous status doc.
Read the previous status document, Sprint-Notes.md, and the SPRINT_BRIEF.md to understand what was done.
Then produce a comprehensive PROJECT_STATUS document covering:

- Sprint merge summary table (branch, what it delivered, key stats)
- Updated module inventory (packages + services + iOS)
- Updated capabilities matrix
- Updated API endpoint inventory (include any new endpoints)
- Updated key metrics — USE the metrics provided below, do NOT re-run npm test or wc -l
- Sprint timing section (from timing data below)
- Velocity section with two tables:
  1. Sprint-over-sprint velocity table (carry forward ALL rows from the previous status doc and append this sprint's column)
  2. Sprint efficiency table (agents launched/succeeded, LOC/agent, merge conflicts, test failures)
  3. Velocity trends & observations (what's improving, where to improve)
- Agent notes from Sprint-Notes.md
- Security assessment
- Recommended next steps (prioritized)
- Planning Context section: APPEND the planning context below verbatim as the LAST section before the Document Status footer. This section provides codebase inventory for next-sprint planning. Update the migration number, route count, Swift file count, and any other numbers to reflect THIS sprint's final state.

${METRICS_SUMMARY}

${TIMING_SUMMARY}

Planning Context (append to end of report, update numbers to reflect current state):
${PLANNING_CONTEXT}

Previous status doc: ${PREV_STATUS}
Sprint notes: ${SPRINT_NOTES}
Sprint brief: ${ROOT}/SPRINT_BRIEF.md

Save the report to: ${STATUS_FILE}
Do NOT commit or push — the automation script handles that."

  unset CLAUDECODE
  if claude --dangerously-skip-permissions -p "$REPORT_PROMPT" 2>&1; then
    timer_record "Report generation" "$REPORT_START"
    log "Report generated: ${STATUS_FILE}"

    # Auto-commit the report
    if [ -f "$STATUS_FILE" ]; then
      git add "$STATUS_FILE"
      git commit -m "$(cat <<EOF
Add Sprint ${SPRINT_NUM} project status document

Session: S-$(date -u +%Y-%m-%d-%H%M)-sprint${SPRINT_NUM}-status
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
      log "Report committed."
    else
      log "[warn] Report file not found at ${STATUS_FILE} — skipping commit."
    fi
  else
    timer_record "Report generation (failed)" "$REPORT_START"
    log "[warn] Report generation failed. Generate manually."
  fi
fi

# ===== POST-MERGE HOOKS =====
# Run hooks after report generation (so they see the final PROJECT_STATUS).
# Hooks are non-fatal — a failing hook logs a warning but does not block.
if [ ${#POST_MERGE_HOOKS[@]} -gt 0 ]; then
  log "Running ${#POST_MERGE_HOOKS[@]} post-merge hook(s)..."
  HOOKS_START=$(now_s)
  for hook in "${POST_MERGE_HOOKS[@]}"; do
    log "  Hook: ${hook}"
    if (
      export SPRINT_NUM ROOT STATUS_FILE SPRINT_BASE
      eval "$hook"
    ) 2>&1; then
      log "  [ok] ${hook}"
    else
      log "  [warn] Hook failed: ${hook} — continuing"
    fi
  done
  timer_record "Post-merge hooks" "$HOOKS_START"
fi

# ===== CLEANUP DONE-MARKERS =====
for agent in "${AGENTS[@]}"; do
  rm -f "${ROOT}/.agent-done-${agent}"
done

# ===== CLEANUP WORKTREES =====
# Worktrees are ~20-30GB per sprint and serve no purpose after merge+report.
# Remove them automatically to prevent unbounded disk growth.
if [ -d "${SPRINT_BASE}" ]; then
  log "Cleaning up worktrees in ${SPRINT_BASE}..."
  for agent in "${AGENTS[@]}"; do
    WT="${SPRINT_BASE}/${agent}"
    if [ -d "$WT" ]; then
      git worktree remove --force "$WT" 2>/dev/null || true
    fi
  done
  git worktree prune 2>/dev/null || true
  rmdir "${SPRINT_BASE}" 2>/dev/null || true
  if [ -d "${SPRINT_BASE}" ]; then
    log "[warn] Could not fully remove ${SPRINT_BASE} — clean up manually."
  else
    log "Worktrees cleaned up."
  fi
  # Delete merged agent branches (they clutter git branch and can cause name collisions)
  for agent in "${AGENTS[@]}"; do
    if git branch --list "$agent" | grep -q "$agent"; then
      local_count=$(git log "main..${agent}" --oneline 2>/dev/null | wc -l | tr -d ' ')
      if [ "$local_count" -eq 0 ]; then
        git branch -D "$agent" 2>/dev/null || true
      fi
    fi
  done
fi

# ===== RECORD TOTAL TIME =====
timer_record "TOTAL SPRINT" "$SPRINT_START"

# ===== AUTO-PUSH =====
if $AUTO_PUSH; then
  if $VERIFICATION_FAILED; then
    log "[warn] Skipping auto-push — verification failed. Fix issues, then push manually."
  else
    log "Pushing to origin/main..."
    if git push origin main 2>&1; then
      log "Push complete."
    else
      log "[warn] Push failed. Push manually: git push origin main"
    fi
  fi
fi

# ===== AUTO-REBUILD DASHBOARD =====
# Rebuild dashboard data (sessions/ADRs/sprints JSON) so the dashboard
# reflects this sprint immediately without manual intervention.
if [ "${AUTO_DASHBOARD_REBUILD:-true}" = "true" ]; then
  log "Rebuilding dashboard data..."
  # Resolve slug from sprint config (already set by sprint-parse.sh)
  REBUILD_SLUG="${PROJECT_SLUG:-}"
  REBUILD_BODY="{\"projectRoot\":\"${ROOT}\",\"slug\":\"${REBUILD_SLUG}\"}"
  if curl -sf -X POST http://localhost:1201/api/rebuild-data \
       -H 'Content-Type: application/json' \
       -d "$REBUILD_BODY" >/dev/null 2>&1; then
    log "Dashboard data rebuilt for '${REBUILD_SLUG}'."
  else
    log "[warn] Dashboard rebuild failed (is the dashboard running on :1201?)."
  fi
fi

# ===== AUTO-DEPLOY =====
if [ -n "${AUTO_DEPLOY:-}" ]; then
  log "Running auto-deploy..."
  if [ "$AUTO_DEPLOY" = "true" ]; then
    # Dashboard-driven deploy via API
    DEPLOY_BODY="{\"projectRoot\":\"${ROOT}\",\"slug\":\"${PROJECT_SLUG:-}\"}"
    if curl -sf -X POST http://localhost:1201/api/deploy/trigger \
         -H 'Content-Type: application/json' \
         -d "$DEPLOY_BODY" >/dev/null 2>&1; then
      log "Deploy triggered via dashboard API."
    else
      log "[warn] Deploy API call failed."
    fi
  else
    # Custom deploy command
    if (cd "$ROOT" && eval "$AUTO_DEPLOY") 2>&1; then
      log "Deploy complete."
    else
      log "[warn] Deploy failed: ${AUTO_DEPLOY}"
    fi
  fi
fi

# ===== SUMMARY =====
print_timing_summary
echo ""
echo "============================================================"
echo "  Sprint ${SPRINT_NUM} — Complete"
echo "============================================================"
echo ""
if $VERIFICATION_FAILED; then
  echo "  ⚠  VERIFICATION FAILED — report was generated but push was skipped."
  echo "  Fix the failing commands, then push manually: git push origin main"
fi
if ! $AUTO_PUSH; then
  echo "Next steps:"
  if ! $SKIP_REPORT; then
    echo "  1. Review docs/PROJECT_STATUS_*-sprint${SPRINT_NUM}.md"
  fi
  echo "  2. git push origin main"
fi

# Exit with error if verification failed (after all cleanup/reporting is done)
if $VERIFICATION_FAILED; then
  exit 1
fi
