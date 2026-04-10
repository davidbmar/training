# Seed Directory

Drop source materials here to auto-generate lifecycle document drafts.

## Supported Formats

- **Markdown** (`.md`) — best support, headings are parsed as sections
- **Text** (`.txt`) — plain text, parsed by heading patterns
- **Word** (`.docx`) — text extracted from document XML

## What to Put Here

Any documents that describe your product vision, architecture, sprint plans, or technical decisions:

- Product briefs or blueprints
- Architecture decision documents
- Sprint execution guides
- Technical specs or RFCs
- Meeting notes with key decisions

## How It Works

1. Drop files into this `docs/seed/` directory
2. Open the Sprint Dashboard → Lifecycle tab
3. Click **Scan Seed Directory** to see detected files
4. Click **Generate Drafts** to auto-populate Vision, Plan, and Roadmap forms
5. Review and edit the generated drafts — they're starting points, not final versions

## What Gets Extracted

The generator looks for:

- **Vision**: product name, problem statements, target audience, differentiators, solution descriptions
- **Plan**: appetite/timeline, solution sketches, market analysis, rabbit holes, no-gos, sprint candidates
- **Roadmap**: current focus, milestones, system architecture, key decisions, tech stack, constraints
- **Codebase signals**: package.json (name, dependencies), Prisma schema (data models), README (description)

Drafts fill empty fields only — they never overwrite content you've already written.
