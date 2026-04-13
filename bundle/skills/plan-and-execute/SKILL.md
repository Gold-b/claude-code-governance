---
name: plan-and-execute
description: Plan & Execute — spawn CTO/Architect/Coder/QA/PM sub-agents to create or rewrite a comprehensive plan, review it, then implement it fully. Asks 3 intake questions to fill placeholders before running.
user-invocable: true
---

# /plan-and-execute — Multi-Agent Plan & Execute Pipeline

**Language**: Communicate with the user in **Hebrew**. All code, comments, and technical artifacts in **English**.

---

## Phase 0 — Intake Questions (MANDATORY FIRST STEP)

Before doing ANYTHING else, you MUST ask the user 3 questions to fill the placeholders in this skill. Use the `AskUserQuestion` tool with the following 3 questions in a SINGLE call:

**Question 1 — Action Type:**
- Header: "Action"
- Question: "ליצור תכנית חדשה או לשכתב תכנית קיימת?"
- Options: "ליצור" (תכנית חדשה מאפס) / "לשכתב" (עדכון/שכתוב של תכנית קיימת)

**Question 2 — Topic:**
- Header: "Topic"
- Question: "מהו הנושא המרכזי של התכנית?"
- Options: Let the user type freely (use 2 example options relevant to the project like "Feature חדש", "ארכיטקטורה", "Bug Fix", "שדרוג מודול" — the user will likely pick "Other" and type their own)

**Question 3 — Goal:**
- Header: "Goal"
- Question: "מהי מטרת התכנית? (מה אנחנו רוצים להשיג?)"
- Options: Same approach — provide 2 generic examples like "שיפור ביצועים", "הוספת יכולת חדשה", "תיקון בעיה קריטית" — expecting the user to type their own via "Other"

Once you receive the 3 answers, substitute them into the placeholders below and proceed to Phase 1.

---

## Phase 1 — Context Loading & Sub-Agent Orchestration

Execute the following steps IN ORDER:

### 1.1 Load ALL Relevant Context FIRST (before spawning any agent)

Read the following files/directories to load full project context into YOUR context window:

- `MDs/Updated-Important-Facts.md`
- `CLAUDE.md` (project root)
- `Plans/` directory — all existing plan files
- `MDs/` directory — all knowledge files
- Memory files from `~/.claude/projects/c--GoldB-Agent/memory/`
- Any schema files, config files, or architecture docs referenced in the above

**You MUST have this context loaded BEFORE spawning sub-agents**, so that when agents arrive, the orchestrator (you) already has full knowledge.

### 1.2 Create Shared Folder

Create a dedicated shared folder for inter-agent communication:

```
Plans/Shared-Folder/{plan-topic-slug}_{YYYY-MM-DD_HH-mm}/
```

Create the main plan file inside it: `PLAN.md`

### 1.3 Spawn Sub-Agents

Using the Agent tool, spawn the following specialized sub-agents. Each agent receives the full context you loaded in 1.1 plus a clear role description:

| Role | Responsibility |
|------|---------------|
| **CTO** | High-level architecture decisions, technology choices, risk assessment |
| **Software Architect** | Detailed system design, module boundaries, data flow, API contracts |
| **Expert Coder** | Implementation feasibility, code structure, patterns, edge cases |
| **QA Expert** | Test strategy, test cases, E2E scenarios, regression risks |
| **PM** | Task breakdown, dependencies, milestones, acceptance criteria |

**Each agent must contribute to the plan file** with their domain-specific section.

### 1.4 Build the Plan

The plan document (`PLAN.md`) must include:

1. **Executive Summary** — what we're doing and why
2. **Architecture & Design** (Architect + CTO)
3. **Implementation Steps** — numbered, ordered, with file paths (Coder + Architect)
4. **QA Strategy** — tests, E2E, validation steps embedded IN EVERY implementation step (QA)
5. **Risk Assessment** — what could go wrong and mitigations (CTO + PM)
6. **Task Breakdown & Dependencies** (PM)
7. **Acceptance Criteria** — how we know we're done (PM + QA)

The ACTION is: **{{ACTION}}** (ליצור / לשכתב)
The TOPIC is: **{{TOPIC}}**
The GOAL is: **{{GOAL}}**

---

## Phase 2 — Plan Review & Enrichment

### 2.1 Second Pass Context Reload

Re-read all MD, Plans, Schemas, and Memory files. Look specifically for:
- Facts that CONTRADICT anything in the plan
- Existing implementations that the plan overlaps with
- Gotchas from CLAUDE.md that apply to the plan's scope
- Security considerations from the hardening guidelines

### 2.2 Update the Plan

For every update, addition, or correction — add a timestamp:

```
[2026-XX-XX HH:MM] Updated: <description of change>
```

Improvements to apply:
- Cross-reference with gotchas list (170+ items in CLAUDE.md)
- Verify no architectural violations
- Ensure QA + Tests + E2E are embedded in EVERY step
- Add missing edge cases
- Strengthen security considerations
- Validate all file paths and module references exist

### 2.3 Final Review

Run one final review pass with the QA agent to verify:
- Every step has a verification method
- No circular dependencies
- All acceptance criteria are testable
- The plan is implementable in sequence

---

## Phase 3 — Full Implementation

### 3.1 Execute the Plan

Implement ALL steps in the plan, continuously, until completion:

1. Follow the exact order defined in the plan
2. **Before each code-changing step**, run the `/impact-safe-executor` skill mentally:
   - Identify files that will be modified and their dependents (impact map)
   - Verify the step stays within the approved plan scope
   - If the step would touch files outside the plan's scope → STOP and ask the user
   - Prefer minimal edits — don't refactor surrounding code
   - Note: this is a lightweight check, not a full skill invocation. Apply the principles (impact awareness, scope enforcement, minimal edit) inline as you work.
3. After each step, run the QA checks defined for that step
4. If a step fails QA — fix before proceeding
5. Update the plan file with completion timestamps:
   ```
   [2026-XX-XX HH:MM] COMPLETED: Step X — <description>
   ```
6. Use sub-agents for parallel implementation where steps are independent

### 3.2 Post-Implementation Verification

After ALL steps are complete:
- Run full QA suite (server-side + client-side)
- Verify no regressions introduced
- Confirm all acceptance criteria are met
- Update plan status to COMPLETED

### 3.3 Mandatory Finish

After successful implementation and verification, invoke `/full-finish` to run the full release pipeline.

---

## Rules

- **Source repo is `C:\openclaw-docker\`** — ALL edits there. NEVER edit `C:\GoldB-Agent\` directly.
- **Every implementation step MUST have QA embedded** — no exceptions.
- **Timestamps on everything** — plan changes, completions, issues found.
- **Shared folder is the single source of truth** for inter-agent communication.
- **thinkingBudget: 0** on ALL LLM calls.
- **Hebrew for communication, English for code.**
