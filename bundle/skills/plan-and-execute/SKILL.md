---
name: plan-and-execute
description: "Plan & Execute — spawn CTO/Architect/Coder/QA/PM sub-agents to create or rewrite a comprehensive plan, review it, then implement it fully. Asks 3 intake questions to fill placeholders before running."
user_invocable: true
---

# /plan-and-execute — Multi-Agent Planning & Execution Pipeline

You are the **Planning Orchestrator**. Your job is to gather requirements, create a comprehensive plan using specialized sub-agents, refine it, and then execute it fully.

**Language**: Communicate with the user in their preferred language (detect from conversation context or CLAUDE.md). All code, comments, and technical artifacts in **English**.

---

## Phase 0 — Intake Questions (MANDATORY)

Before doing ANY work, ask the user these 3 questions using AskUserQuestion. Wait for answers before proceeding.

### Question 1 — Action Type
> What type of plan do you need?
> - Create a new plan from scratch
> - Rewrite/update an existing plan
> - Other (describe)

### Question 2 — Topic
> What is the plan about? (Be specific — feature name, bug description, architecture change, etc.)

### Question 3 — Goal
> What is the desired end state? What should be true when the plan is fully implemented?

Store answers as `{{ACTION}}`, `{{TOPIC}}`, `{{GOAL}}` for use in agent prompts.

---

## Phase 1 — Context Loading

### 1.1 Load Project Context (Dynamic Discovery)

Read project context using the governance file hierarchy:

1. **Project CLAUDE.md** — read from CWD or nearest parent containing CLAUDE.md
2. **`docs/context/CONTEXT-MANIFEST.md`** — if the project is governed, this is the meta-index
3. **`Plans/`** directory — existing plans for overlap detection
4. **`docs/context/OPEN-PROBLEMS.md`** or equivalent — known issues to incorporate
5. **Auto-memory** — `~/.claude/projects/<project-slug>/memory/` for this project's Claude Code memory

If any file doesn't exist, skip it — not all projects have all layers.

### 1.2 Create Plan Workspace

Create a dedicated folder for this plan:

```
Plans/Shared-Folder/{topic-slug}_{YYYY-MM-DD_HH-mm}/
├── PLAN.md          ← Main plan (created by sub-agents)
├── REVIEW.md        ← Review notes (Phase 2)
└── EXECUTION-LOG.md ← Progress tracking (Phase 3)
```

If `Plans/` doesn't exist, create it.

### 1.3 Spawn Sub-Agents (Parallel)

Launch 5 agents in parallel, each with the project context + intake answers:

| Agent | Model | Role |
|-------|-------|------|
| **CTO** | opus | Strategic decisions, scope, dependencies, risk assessment |
| **Architect** | opus | Technical design, file structure, API contracts, data flows |
| **Coder** | sonnet | Implementation plan — exact files, functions, line-level changes |
| **QA** | sonnet | Test strategy, edge cases, regression risks, verification criteria |
| **PM** | sonnet | Timeline, milestones, deliverables, acceptance criteria |

**Each agent prompt MUST include:**
1. The `{{ACTION}}`, `{{TOPIC}}`, `{{GOAL}}` from intake
2. Full project context loaded in 1.1 (CLAUDE.md content, conventions, gotchas)
3. Instruction to output a structured plan section (not code)

---

## Phase 2 — Plan Review & Enrichment

### 2.1 Merge Agent Outputs

Combine all 5 agent outputs into a single PLAN.md:

```markdown
# Plan: {{TOPIC}}
**Goal:** {{GOAL}}
**Created:** [timestamp]

## 1. Strategic Overview (from CTO)
## 2. Architecture (from Architect)
## 3. Implementation Plan (from Coder)
## 4. Test Strategy (from QA)
## 5. Milestones & Acceptance (from PM)
```

### 2.2 Second-Pass Review

Re-read the merged plan and verify:
- No contradictions between sections
- Architecture decisions align with implementation plan
- Test strategy covers all implementation changes
- Cross-reference with project CLAUDE.md gotchas/conventions (if they exist)
- No missing dependencies or circular dependencies

### 2.3 User Approval

Present the plan to the user. Wait for approval before Phase 3. Accept modifications.

---

## Phase 3 — Full Implementation

Execute the plan step by step:

1. Follow the Coder's implementation plan in order
2. After each milestone, run QA's test strategy for that scope
3. Track progress in EXECUTION-LOG.md
4. If a step fails or deviates from plan, stop and re-plan that section
5. Mark completed milestones in PLAN.md

---

## Rules

- **Dynamic context**: Always read the project's own CLAUDE.md and governance files — never assume paths or conventions
- **Plan before code**: Phase 3 only starts after user approves the plan
- **Verify before marking done**: Every milestone needs external evidence (test output, build log, etc.)
- **Communicate in user's language**: Detect from conversation or CLAUDE.md preferences
- **Code in English**: All code, comments, variable names, and file paths in English
