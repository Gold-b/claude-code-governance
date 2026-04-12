---
name: init-governance
description: Initialize Context Governance structure in a new project. Scaffolds all canonical files (CONTEXT-MANIFEST, PLAN, HANDOFF, MEMORY, CONVENTIONS, SCHEMAS-INDEX, GOTCHAS, OPEN-PROBLEMS) + CLAUDE.md governance section. Run once per project.
user-invocable: true
---

# /init-governance — Project Governance Scaffold

**Language:** Communicate in **Hebrew**. All file content in **English**.

**Purpose:** One-time initialization of the Context Governance framework in a new project. Creates the canonical file structure so that all governance skills (bootstrapper, live-state-orchestrator, impact-safe-executor, evidence-debugger, parallel-session-merge, context-governance) can operate.

**Reference:** `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §2 (canonical layout) + §15 (new project onboarding).

---

## When to invoke

- **Manual:** `/init-governance` when starting a new project
- **Suggested by:** `bootstrapper` or `context-governance` when they detect a project without `docs/context/CONTEXT-MANIFEST.md`
- **NOT for:** projects that are already governed (check first!)

---

## Pre-flight check

Before scaffolding, verify:
1. `docs/context/CONTEXT-MANIFEST.md` does NOT already exist (if it does → abort, tell user "project is already governed")
2. The current working directory IS a project root (contains code, has a `.git/` or identifiable project structure)
3. `CLAUDE.md` may or may not exist (if it exists, we AUGMENT it; if not, we CREATE a minimal one)

---

## Phase 0 — Intake Questions (MANDATORY)

Ask the user 3 questions before scaffolding:

**Question 1 — Project Name:**
- "מהו שם הפרויקט?"

**Question 2 — Project Description:**
- "תאר בקצרה מה הפרויקט עושה (משפט אחד עד שלושה)"

**Question 3 — Tech Stack (optional):**
- "מה ה-tech stack? (שפות, frameworks, DB, deployment)" — the user can skip this

---

## Phase 1 — Create directory structure

```bash
mkdir -p docs/context
mkdir -p Plans
```

---

## Phase 2 — Create canonical files

Create each file with the templates below. Replace `{{PROJECT_NAME}}` and `{{PROJECT_DESCRIPTION}}` with intake answers.

### 2.1 — `docs/context/CONTEXT-MANIFEST.md`

```markdown
---
type: manifest
created_at: {{TODAY}}
last_verified: {{TODAY}}
---

# Context Manifest — {{PROJECT_NAME}}

> Meta-index of every context file in this project. Update this file whenever a context file is added, removed, or renamed.

## Hierarchy of Source-of-Truth

1. Runtime code + tests (ultimate authority)
2. Version file (if exists)
3. Plans/PLAN.md (active execution state)
4. docs/context/OPEN-PROBLEMS.md (unresolved work)
5. docs/context/HANDOFF.md (latest session bridge)
6. docs/context/MEMORY.md (durable decisions)
7. docs/context/CONVENTIONS.md (code style)
8. CLAUDE.md (orchestration)

## Canonical Files

| Path | Role | Authority | Status | Verified On |
|---|---|---|---|---|
| CLAUDE.md | Orchestration | high | ACTIVE | {{TODAY}} |
| Plans/PLAN.md | Active execution state | high | ACTIVE | {{TODAY}} |
| docs/context/CONTEXT-MANIFEST.md | This file — meta-index | high | ACTIVE | {{TODAY}} |
| docs/context/HANDOFF.md | Session bridge | high | ACTIVE | {{TODAY}} |
| docs/context/OPEN-PROBLEMS.md | Unresolved work | high | ACTIVE | {{TODAY}} |
| docs/context/MEMORY.md | Durable decisions + lessons | high | ACTIVE | {{TODAY}} |
| docs/context/CONVENTIONS.md | Code style + patterns | medium | ACTIVE | {{TODAY}} |
| docs/context/SCHEMAS-INDEX.md | Schema/API index | medium | ACTIVE | {{TODAY}} |
| docs/context/GOTCHAS.md | Bug-driven rules | high | ACTIVE | {{TODAY}} |

## Change Log

| Date | Change | Author |
|---|---|---|
| {{TODAY}} | Initial scaffold via /init-governance | Claude Code |
```

### 2.2 — `Plans/PLAN.md`

```markdown
# Active Plan — {{PROJECT_NAME}}

## Objective
{{PROJECT_DESCRIPTION}}

## Active Sub-Plans
(none yet — add sub-plans as work begins)

## Milestone Log
| Date | Event | Reference |
|---|---|---|
| {{TODAY}} | Project initialized with Context Governance | /init-governance |
```

### 2.3 — `docs/context/HANDOFF.md`

```markdown
---
status: active
created_at: {{TODAY}}
consumed_at: pending
imported_into_plan_section: pending
---

# Handoff — {{PROJECT_NAME}}

## Session Summary
Project freshly initialized. No work done yet.

## Current State
Context Governance scaffolded. All canonical files created empty.

## Open Work
Everything — project is brand new.

## Exact Next Action
Define the first task or sub-plan in Plans/PLAN.md.

## Read These First
- CLAUDE.md
- Plans/PLAN.md
- docs/context/CONTEXT-MANIFEST.md
```

### 2.4 — `docs/context/OPEN-PROBLEMS.md`

```markdown
# Open Problems — {{PROJECT_NAME}}

## P1 — Critical / Blocking
(none yet)

## P2 — Medium Priority
(none yet)

## P3 — Backlog
(none yet)
```

### 2.5 — `docs/context/MEMORY.md`

```markdown
---
type: project_memory
scope: durable
created_at: {{TODAY}}
---

# Project Memory — {{PROJECT_NAME}}

## Active Summary
- Project initialized {{TODAY}}
- Tech stack: {{TECH_STACK}}
- No work completed yet

## Durable Decisions
| Date | Decision | Rationale | Implications |
|---|---|---|---|
| {{TODAY}} | Adopted Context Governance framework | Prevent context drift, silent regressions, and session-to-session information loss | All sessions follow governance lifecycle |

## Lessons Learned
(none yet)

## Repeated Pitfalls
(none yet)
```

### 2.6 — `docs/context/CONVENTIONS.md`

```markdown
# Code & Operations Conventions — {{PROJECT_NAME}}

## Language
- Code/comments: English
- UI text: (define per project)
- User communication: Hebrew

## Code Style
(define as the project progresses — add rules here, not in CLAUDE.md)

## Forbidden Patterns
(add patterns that have caused bugs — each should reference a GOTCHAS.md entry)

## Security
(add security conventions as they emerge)
```

### 2.7 — `docs/context/SCHEMAS-INDEX.md`

```markdown
# Schemas Index — {{PROJECT_NAME}}

> Index of schemas, contracts, data models, API specs. Points to where they live in code — does NOT contain definitions.

## Configuration Schemas
(add entries as schemas are created)

## API Contracts
(add entries as APIs are defined)

## Data Models
(add entries as models are defined)
```

### 2.8 — `docs/context/GOTCHAS.md`

```markdown
---
type: gotchas
created_at: {{TODAY}}
total_entries: 0
---

# Technical Gotchas — {{PROJECT_NAME}}

> Append-only list of bug-driven rules. Each entry comes from a real failure.
> Never renumber. Never delete. Annotate obsolete entries with ~~strikethrough~~.

(no entries yet — first gotcha will be #1)
```

---

## Phase 3 — Augment or create CLAUDE.md

If `CLAUDE.md` already exists:
- Add a `## Context Governance` section at the end with:
  ```markdown
  ## Context Governance
  
  This project uses the Context Governance framework.
  - Entry point: `docs/context/CONTEXT-MANIFEST.md`
  - Agent guide: `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md`
  - Human guide: `~/.claude/docs/GOVERNANCE-HUMAN-GUIDE.md`
  - Active plan: `Plans/PLAN.md`
  - Handoff: `docs/context/HANDOFF.md`
  ```

If `CLAUDE.md` does NOT exist:
- Create a minimal one:
  ```markdown
  # {{PROJECT_NAME}}
  
  ## Project Overview
  {{PROJECT_DESCRIPTION}}
  
  ## Tech Stack
  {{TECH_STACK}}
  
  ## Context Governance
  
  This project uses the Context Governance framework.
  - Entry point: `docs/context/CONTEXT-MANIFEST.md`
  - Agent guide: `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md`
  - Human guide: `~/.claude/docs/GOVERNANCE-HUMAN-GUIDE.md`
  - Active plan: `Plans/PLAN.md`
  - Handoff: `docs/context/HANDOFF.md`
  ```

---

## Phase 4 — Verification

After all files are created:
1. List all created files with sizes
2. Verify `docs/context/CONTEXT-MANIFEST.md` references all of them
3. Run `/context-governance lite` to verify the scaffold passes the health check
4. Report to user in Hebrew:
   ```
   הפרויקט אותחל בהצלחה עם Context Governance.
   נוצרו X קבצים:
   - docs/context/CONTEXT-MANIFEST.md (meta-index)
   - docs/context/HANDOFF.md (session bridge)
   - docs/context/OPEN-PROBLEMS.md (bug tracker)
   - docs/context/MEMORY.md (durable decisions)
   - docs/context/CONVENTIONS.md (code style)
   - docs/context/SCHEMAS-INDEX.md (schema index)
   - docs/context/GOTCHAS.md (bug-driven rules)
   - Plans/PLAN.md (active plan)
   
   הפעולה הבאה: הגדר את המשימה הראשונה ב-Plans/PLAN.md.
   ```

---

## Behavior contract

- **Idempotent guard:** REFUSES to run if `docs/context/CONTEXT-MANIFEST.md` already exists
- **Non-destructive:** If `CLAUDE.md` exists, ONLY appends a governance section — never overwrites
- **No code edits:** This skill creates documentation files only
- **Templates are minimal:** Empty sections with clear headers. Content grows organically as the project progresses.
- **Hebrew output to user.** English file content.

---

## Reference

- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §2 (canonical layout)
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §15 (new project onboarding)
- `~/.claude/docs/GOVERNANCE-HUMAN-GUIDE.md` (user-facing explanation)
