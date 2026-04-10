# SPRINT_BRIEF.md — Specification

## Purpose

This document defines the format for `SPRINT_BRIEF.md`, which lives in your repo root. It is the single source of truth for each sprint: it defines the sprint number, all agents, and their work assignments. Automated tooling parses this file to create git worktrees, distribute per-agent briefs, and launch parallel Claude Code agents.

## Location

```
<your-repo>/SPRINT_BRIEF.md
```

## Format

The file is Markdown with two levels of headings:

1. **One `#` heading** — the sprint identifier (required, must be first heading)
2. **One `##` heading per agent** — the agent name and its full brief

### Sprint Heading

```markdown
# Sprint <number>
```

- Must be the first heading in the file.
- `<number>` is an integer (e.g., `1`, `2`, `3`).

### Sprint Meta Block

The content between the `# Sprint` heading and the first `## agent` heading is the **sprint meta block**. This is optional but recommended. Use it to define sprint-wide goals and constraints that apply to all agents.

```markdown
# Sprint 2

Goal
- Add user authentication
- Improve test coverage

Constraints
- Do not modify existing database schema without migration
- All new endpoints must include tests
```

**This block is automatically prepended to every agent's `AGENT_BRIEF.md`** under a "Sprint-Level Context" header, so each agent sees the global rules without you repeating them in every section.

Guidelines for the meta block:
- **Goal** — 1-3 bullet points describing the sprint's high-level objectives. Helps agents understand the bigger picture.
- **Constraints** — Rules that apply to ALL agents. Use this for cross-cutting concerns like API compatibility, off-limits files/services, or coding standards.
- **Merge Order** — Numbered list specifying the order to merge agent branches into main. Order matters: merge agents with fewer cross-cutting changes first, shared-file agents last. This changes every sprint.
- **Merge Verification** — Automated checks run after each merge (not just the final one). Defaults to the project's configured test command (`DEFAULT_TEST_CMD` in `sprint-config.sh`). Only override if your sprint has additional verification needs.
- **Previous Sprint** (optional) — Summary of what the previous sprint accomplished. If omitted, `sprint-init.sh` auto-detects the most recent `docs/PROJECT_STATUS_*.md` file and injects it into each agent's brief. Use this field to manually override or supplement the auto-detected summary — for example, to highlight specific context agents need or to reference a status doc from a non-standard location.
- Keep it concise — agents receive Goal, Constraints, and Previous Sprint Summary on top of their own brief (Merge Order and Merge Verification are not distributed to agents).

### Agent Sections

Each `## <agent-name>` heading defines one agent. Everything between one `##` heading and the next (or end of file) is that agent's complete brief.

```markdown
## <agent-name>

Objective
- <one-line goal>

Tasks
- <task 1>
- <task 2>
- <task 3>

Acceptance Criteria
- <criterion 1>
- <criterion 2>
```

### Agent Naming Rules

Agent names become git branch names and directory names, so they must:

- Follow the pattern: `agent<CAPITAL-LETTER>-<descriptive-slug>` — the letter MUST be uppercase (A-Z)
- The slug after the letter must be lowercase with hyphens only
- Be descriptive of the work (not the agent letter alone)
- Contain no spaces, underscores, or other special characters

Examples: `agentA-add-auth`, `agentB-refactor-db`, `agentC-improve-tests`

**Important:** The capital letter is required. `agenta-foo` is invalid — use `agentA-foo`.

### Brief Content Rules

Each agent section MUST include:

| Section | Required | Purpose |
|---------|----------|---------|
| **Objective** | Yes | One or two bullet points stating the goal |
| **Tasks** | Yes | Concrete, actionable items the agent will implement |
| **Acceptance Criteria** | Yes | How to verify the work is complete |

Each agent section MAY include:

| Section | Purpose |
|---------|---------|
| **Context** | Background info, links to relevant files or docs |
| **Constraints** | Limitations, things to avoid, dependencies |
| **Files** | Specific files or directories the agent should focus on |
| **Notes** | Anything else relevant |

### Scope Rules

- Each agent's work must be **independent** — no two agents should modify the same files.
- Keep tasks scoped so a single agent can complete them in one session.
- If work has dependencies, note them in Constraints (e.g., "Depends on agentA's output schema") but design the tasks so the agent can stub or mock the dependency.
- Prefer 3-8 agents per sprint. Fewer than 3 isn't worth parallelizing; more than 8 creates merge complexity.

### Autonomous Execution Rules

Agents run **non-interactively** via `claude --dangerously-skip-permissions -p "$PROMPT"`. They cannot receive user input after launch. Therefore:

- **Agents MUST NOT ask for confirmation, approval, or clarification.** Any prompt like "Shall I proceed?" or "Does this look right?" will hang forever and produce zero output.
- **Agents MUST NOT use skills or workflows that require user interaction** (e.g., brainstorming's design-approval gate). If a skill blocks on user input, the agent must skip it and proceed directly to implementation.
- **Agents must be self-sufficient.** The `AGENT_BRIEF.md` contains everything needed. If something is ambiguous, make a reasonable decision, document it in a commit message, and move on.

**Post-Sprint Validation:** After all agents complete, check for **zero-commit branches** — branches where the agent produced no commits. This indicates the agent got stuck (usually on a confirmation prompt). Re-run the failed agent's work manually or with an updated prompt.

### Agent Commit Policy

Agents MUST commit their work if all files they created/modified are correct, even if pre-existing tests unrelated to their work fail intermittently. The rule is:

- Run the project's test command.
- If all tests **in the packages/services you modified** pass, commit.
- If a test you did NOT write and that does NOT test your code fails, that is a **pre-existing flaky test** — commit anyway and note the flaky test in your commit message.
- Never abandon completed work because of unrelated test failures.

## Complete Example

```markdown
# Sprint 2

Goal
- Add user authentication
- Improve API documentation

Constraints
- Do not modify existing database schema without migration
- All new endpoints must include tests
- No two agents may modify the same files

Merge Order
1. agentC-add-docs
2. agentB-user-model
3. agentA-auth-endpoints

Merge Verification
- npm test

## agentA-auth-endpoints

Objective
- Build JWT authentication endpoints for login, register, and token refresh.

Tasks
- Create `src/routes/auth.ts` with login, register, and refresh endpoints
- Add JWT token generation and validation utilities in `src/utils/jwt.ts`
- Write integration tests for all auth endpoints
- Add auth middleware for protected routes

Acceptance Criteria
- Login returns a valid JWT token
- Register creates a user and returns a token
- Token refresh works with valid refresh tokens
- All tests pass

## agentB-user-model

Objective
- Create the user database model and migration.

Tasks
- Create migration for users table in `migrations/002-users.sql`
- Add `src/models/user.ts` with CRUD operations
- Write unit tests for user model
- Add password hashing with bcrypt

Acceptance Criteria
- Migration creates users table with email, password_hash, created_at
- Model supports create, findByEmail, findById
- Passwords are hashed, never stored in plaintext
- All tests pass

## agentC-add-docs

Objective
- Add OpenAPI documentation for existing and new endpoints.

Tasks
- Create `docs/openapi.yaml` with schema definitions
- Document all existing endpoints
- Add Swagger UI middleware at `/api/docs`

Acceptance Criteria
- OpenAPI spec validates without errors
- Swagger UI loads and shows all endpoints
- All tests pass
```

## How Tooling Uses This File

The automated scripts parse `SPRINT_BRIEF.md` as follows:

1. **Sprint number**: extracted from the `# Sprint <N>` heading
2. **Sprint meta block**: everything between `# Sprint N` and the first `##` heading (Goal + Constraints + Merge Order + Merge Verification)
3. **Agent list**: every `## <name>` heading becomes an agent
4. **Per-agent brief**: Previous Sprint Summary (auto-detected or from meta block) + Goal and Constraints from the meta block are prepended, then the agent's own section content — written to `AGENT_BRIEF.md` in each worktree (Merge Order and Merge Verification are NOT distributed to agents)
5. **Merge order**: parsed by `sprint-merge.sh` to merge branches in the specified sequence
6. **Merge verification**: commands run after each merge to catch conflicts early
7. **Worktree path**: `../<project-slug>-agents-sprint<N>/<agent-name>/`
8. **Branch name**: `<agent-name>`

### Workflow

```
Edit SPRINT_BRIEF.md
       |
       v
./scripts/sprint-init.sh       # creates worktrees + AGENT_BRIEF.md per agent
       |
       v
./scripts/sprint-tmux.sh       # launches tmux with N tabs, one per agent
       |
       v
Each agent runs autonomously:
  1. Claude reads AGENT_BRIEF.md
  2. Implements tasks
  3. Summary appended to Sprint-Notes.md
  4. Tests run
  5. Auto-commits if tests pass
       |
       v
./scripts/sprint-merge.sh      # merges branches in order, verifies after each
       |
       v
Review Sprint-Notes.md + push main
```

## GPT Prompt Template

When asking GPT to generate a `SPRINT_BRIEF.md`, provide this context:

```
I need you to write a SPRINT_BRIEF.md file for my next sprint.

Format rules:
- First heading must be: # Sprint <number>
- Between the # heading and the first ## agent heading, include a sprint meta block with:
  - Goal: 1-3 bullet points for the sprint's high-level objectives
  - Constraints: rules that apply to ALL agents
  - Merge Order: numbered list of agent names in the order they should be merged into main. Merge agents with fewer cross-cutting changes (isolated work) first; agents that touch shared files last.
  - Merge Verification: list of commands run after each merge (default: your project's test command). Only override if the sprint has additional verification needs.
  - Goal and Constraints are automatically prepended to every agent's brief. Merge Order and Verification are NOT — they're used by merge tooling only.
- Each agent gets a ## heading with the name pattern: agent<CAPITAL-LETTER>-<descriptive-slug>
- The letter after "agent" MUST be uppercase (agentA-, agentB-, etc.) — the rest is lowercase with hyphens only
- Agent names become git branches, so no spaces or special characters
- Each agent section must have: Objective, Tasks, and Acceptance Criteria
- In each agent's Tasks, be specific about which files are created or modified
- Each agent's work must be independent — no two agents should touch the same file
- Aim for 3-8 agents
- Tasks should be completable by an AI coding agent in a single session
- Include the Autonomous Execution Rules: agents run non-interactively and MUST NOT ask for confirmation, approval, or clarification. They must proceed directly to implementation without waiting for user input.

Here is the previous sprint's status (PROJECT_STATUS doc):
<paste previous sprint's PROJECT_STATUS_*.md>

Here is the current project status:
<paste relevant context>

Here is what I want to accomplish this sprint:
<describe goals>
```
