# Claude Instructions — training

## Project Overview

TODO: Describe your project here

### Tech Stack
TODO: List your tech stack

### Key Commands
```bash
TODO: Add your key commands
```

---

## Afterburner Framework

This project uses the **Afterburner** framework (traceable-searchable-adr-memory-index) for sprint orchestration, project memory, and dashboard tracking.

- **Framework location:** Check `.sprint/.framework-root` for the path
- **Dashboard:** `http://127.0.0.1:1201` — switch to this project in Settings

### Dashboard Data Pipeline

After each sprint merge, rebuild dashboard data:
```bash
# From the framework repo:
PROJECT_ROOT=/Users/davidmar/src/training OUTPUT_DIR=<framework>/dist/projects/training/data ./scripts/build-sprint-data.sh
```

Or use the dashboard's Settings → "Rebuild Data" button.

**Critical flow:** `sprint-merge.sh` auto-generates `docs/PROJECT_STATUS_*.md` → `build-sprint-data.sh` parses those into JSON → dashboard displays sprints/sessions/ADRs.

---

## Project Memory System

This repo uses a **Traceable Project Memory** system. Every coding session, commit, and decision must be documented and searchable.

### You MUST Follow These Rules

#### 1. Session ID Format

Every coding session gets a unique Session ID:
```
S-YYYY-MM-DD-HHMM-<slug>
```

**HHMM is UTC** — always use `date -u +%Y-%m-%d-%H%M` to generate the timestamp.

Example: `S-2026-03-10-0616-sprint1-evidence-engine`

#### 2. Commit Message Format

Write a **human-readable subject line**. Put the Session ID in the commit body:
```
Subject line describing the change

Session: S-YYYY-MM-DD-HHMM-slug
```

#### 3. Session Documentation

When starting work:

1. **Check if a session exists** for this work:
   ```bash
   ls docs/project-memory/sessions/
   ```

2. **If no session exists, create one:**
   - Copy `docs/project-memory/sessions/_template.md`
   - Name it with the Session ID: `S-YYYY-MM-DD-HHMM-slug.md`
   - Fill in Title, Goal, Context, Plan

3. **After making changes, update the session doc:**
   - Add what changed to "Changes Made"
   - Document decisions in "Decisions Made"
   - Link commits after you create them

#### 4. When to Create an ADR

Create an ADR in `docs/project-memory/adr/` when:
- Making significant architectural decisions
- Choosing between technical approaches
- Establishing patterns that will be followed
- Making decisions with long-term consequences

Use the ADR template: `docs/project-memory/adr/_template.md`

#### 5. Backlog (Bugs & Features)

Track work items in `docs/project-memory/backlog/`:
- **Bugs** use a `B-NNN` prefix (e.g., `B-001-login-crash.md`)
- **Features** use an `F-NNN` prefix (e.g., `F-001-dark-mode.md`)
- Each item gets its own markdown file with Summary, Status, Priority
- Update `docs/project-memory/backlog/README.md` table when adding/changing items
- Link backlog items from code comments when relevant (e.g., `# TODO: see F-001`)

#### 6. Searching Project Memory

To find context for code:

**Search commits by Session ID:**
```bash
git log --all --grep="S-2026-03-10-0616-sprint1-evidence-engine"
```

**Search session docs:**
```bash
grep -r "keyword" docs/project-memory/sessions/
```

**Search ADRs:**
```bash
grep -r "decision topic" docs/project-memory/adr/
```

**Search backlog:**
```bash
grep -r "keyword" docs/project-memory/backlog/
```

#### 7. Semantic Search (AI-Powered)

When users ask questions using **concepts** rather than exact keywords:
1. Read ALL session docs and ADRs
2. Match related concepts (synonyms, related terms)
3. Explain WHY results match
4. Cross-reference between sessions, ADRs, and commits

#### 8. Multi-Agent Sprint Orchestration

This repo uses the Afterburner multi-agent sprint system for parallelizing work.

**Fully Automated (recommended):**
```bash
.sprint/scripts/sprint-run.sh                    # init → poll → merge → report → cleanup
.sprint/scripts/sprint-run.sh --push             # also push when done
```

**Manual Workflow:**
1. Write a `SPRINT_BRIEF.md` in the repo root (use template in `docs/project-memory/tools/`)
2. Run `.sprint/scripts/sprint-init.sh` — creates git worktrees and per-agent briefs
3. Run `.sprint/scripts/sprint-tmux.sh` — launches tmux with one tab per agent
4. Agents run autonomously: implement brief, run tests, auto-commit
5. Run `.sprint/scripts/sprint-merge.sh` — merges branches in order, auto-generates `PROJECT_STATUS` doc

**Planning Next Sprint:**
```bash
.sprint/scripts/sprint-plan.sh                   # reads last PROJECT_STATUS + backlog
```

**Configuration:** `.sprint/config.sh` (project-specific settings)

**Agent Rules:**
- Agents run non-interactively — they MUST NOT ask for confirmation
- Each agent works in its own worktree — no shared file modifications
- Agents auto-commit when tests pass
- Check for zero-commit branches after a sprint (indicates stuck agents)

### Your Workflow

1. **Start of work:** Create or identify Session ID (HHMM is UTC)
2. **Create session doc:** Use template, fill in Title/Goal/Context/Plan
3. **Make changes:** Write code
4. **Commit:** Human-readable subject, `Session: S-...` in body
5. **Update session doc:** Add Changes Made, Decisions, Links
6. **Create ADR if needed:** For significant decisions
7. **Create PR:** Reference Session ID, link to session doc

### Quick Reference

- **Session template:** `docs/project-memory/sessions/_template.md`
- **ADR template:** `docs/project-memory/adr/_template.md`
- **Sprint brief spec:** `docs/project-memory/tools/SPRINT_BRIEF_SPEC.md`
- **Sprint brief template:** `docs/project-memory/tools/SPRINT_BRIEF_TEMPLATE.md`
- **Sprint scripts:** `.sprint/scripts/`
- **Agent prompt:** `.sprint/scripts/CLAUDE_RUN_PROMPT.txt`

## Always Enforce

- ✅ Session ID times are UTC (`date -u`)
- ✅ Every commit has `Session: S-...` in the body
- ✅ Every session has a markdown doc with a Title field
- ✅ Significant decisions get ADRs
- ✅ PRs reference Session IDs
- ✅ Session docs link to commits, PRs, ADRs
- ✅ Sprint briefs follow the spec in `docs/project-memory/tools/SPRINT_BRIEF_SPEC.md`
- ✅ `sprint-merge.sh` generates `PROJECT_STATUS` docs — do not create them manually
- ✅ After sprint merge, rebuild dashboard data so sprints appear in the dashboard
