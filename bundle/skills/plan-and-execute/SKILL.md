---
name: plan-and-execute
description: Plan & Execute — spawn CTO/Architect/Coder/QA/PM sub-agents to create or rewrite a comprehensive plan, review it, then implement it fully. Asks 3 intake questions to fill placeholders before running.
user-invocable: true
---

# /plan-and-execute — Multi-Agent Plan & Execute Pipeline

**Language:** Communicate with the user in **Hebrew**. All code, comments, and technical artifacts in **English**.

**Authority:** Context Governance framework (see `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §9, §12). This skill orchestrates multi-agent planning and execution for any governed project. It is the most complex governance skill — errors here cascade into every plan created.

> This skill works on ANY project that has been initialized with `/init-governance`.
> All paths are discovered dynamically from the project's `docs/context/CONTEXT-MANIFEST.md`.

---

## Path Resolution (Dynamic)

Before any operation:
1. Find the project root: use CWD, or walk up to the nearest directory containing `CLAUDE.md`.
2. Check for `docs/context/CONTEXT-MANIFEST.md` at the project root.
   - **If found:** Read the manifest to discover all canonical file paths. Proceed.
   - **If NOT found:** The project is NOT governed. Suggest `/init-governance` to the user. Produce a minimal briefing from `CLAUDE.md` alone (skip Steps 1.2+). Note the missing governance in the briefing.
3. All paths in this skill are expressed RELATIVE to the detected project root. The manifest is the single source of truth for where files live.

---

## When to invoke

- **Manual:** `/plan-and-execute` when a user wants to create or revise a comprehensive plan
- **Manual:** when a complex multi-step task needs architecture + QA + implementation planning
- **After:** receiving user approval to start a large feature or refactor
- **NOT for:** small fixes, single-file changes, or documentation-only edits (use `/impact-safe-executor` instead)

---

## Inputs

- `ACTION` — "create" or "rewrite" (new plan vs. revising an existing one)
- `TOPIC` — the central theme of the plan (feature, module, architecture change, bug fix)
- `GOAL` — what the plan should achieve (the desired outcome)

These inputs are collected via Phase 0 intake questions if not already known from the user's invoking message.

---

## Phase 0 — Intake Questions (MANDATORY FIRST STEP)

**Skip condition:** If the user's invoking message already contains clear answers for all 3 inputs (ACTION, TOPIC, GOAL), extract them directly and skip to Phase 1. For example, if the user writes `/plan-and-execute create a new caching layer to reduce LLM API calls by 50%`, then ACTION=create, TOPIC=caching layer, GOAL=reduce LLM API calls by 50%.

Otherwise, ask the user the 3 questions below in a SINGLE message:

**Question 1 — Action Type:**
- "ליצור תכנית חדשה או לשכתב תכנית קיימת?"
- Options: "ליצור" (new plan from scratch) / "לשכתב" (update/rewrite an existing plan)

**Question 2 — Topic:**
- "מהו הנושא המרכזי של התכנית?"
- Let the user type freely. Provide examples like: "Feature חדש", "ארכיטקטורה", "Bug Fix", "שדרוג מודול"

**Question 3 — Goal:**
- "מהי מטרת התכנית? (מה אנחנו רוצים להשיג?)"
- Let the user type freely. Provide examples like: "שיפור ביצועים", "הוספת יכולת חדשה", "תיקון בעיה קריטית"

Once you receive the 3 answers, substitute them into the placeholders below and proceed to Phase 1.

---

## Phase 1 — Governance-Aware Context Loading

### 1.1 Read Orchestration Tier (mandatory)

Read these files IN ORDER. They form the mandatory baseline (~25K tokens):

| # | File | Role | How to read |
|---|------|------|-------------|
| 1 | `docs/context/CONTEXT-MANIFEST.md` | Meta-index — lists every canonical file with path, role, authority, status | Read in full. This is the entry point for all context discovery. |
| 2 | `CLAUDE.md` | Project orchestration — architecture, deployment topology, key concepts | Read in full (should be <500 lines). |
| 3 | `Plans/PLAN.md` | Active sub-plan router — what is currently being worked on | Read in full. Check which sub-plans are `IN_PROGRESS`. |
| 4 | `docs/context/HANDOFF.md` | Active session bridge (may be a pointer to another file) | Read. If `type: pointer`, follow `points_to` and read the target file. |
| 5 | `docs/context/OPEN-PROBLEMS.md` | Unresolved work tracker (may be a pointer) | Read first 80 lines (P1 + start of P2). Follow pointer if needed. |
| 6 | `version.json` | Version SSOT | Read — version number is authoritative here, not in CLAUDE.md. |

### 1.2 Selective Context Loading (scoped to TOPIC + GOAL)

Use the CONTEXT-MANIFEST's "Canonical Files" table to match the plan's topic against available context. Load ONLY what is relevant:

| File | When to load | How to load |
|------|-------------|-------------|
| `docs/context/CONVENTIONS.md` | Always (code style, security rules, operational patterns) | Read in full (~100-200 lines). |
| `docs/context/GOTCHAS.md` | Always | **NEVER read in full** (can be >80KB). Grep by TOPIC + GOAL keywords only. |
| `docs/context/SCHEMAS-INDEX.md` | When touching APIs, data models, config, DB schemas | Read relevant sections only. |
| `docs/context/MEMORY.md` | When making architectural decisions or debugging repeated failures | Read in full (~100 lines). Contains durable decisions + lessons + pitfalls. |
| User-level memory `~/.claude/projects/<project>/memory/MEMORY.md` | Always (workflow rules, feedback, user preferences) | Read in full. |

**Token budget for Steps 1.1 + 1.2:** ~55K tokens maximum. Do NOT read archived files, full MDs/ directories, or all plan files.

### 1.3 Create Shared Folder

Create a dedicated shared folder for inter-agent communication:

```
Plans/Shared-Folder/{plan-topic-slug}_{YYYY-MM-DD_HH-mm}/
```

Create the main plan file inside it: `PLAN.md`

### 1.4 Spawn Sub-Agents

Using the **Agent tool**, spawn the following specialized sub-agents. Each agent receives a **focused context brief** (NOT the full context dump — summarize what you learned in 1.1-1.2 into a concise brief per agent). Each agent writes its section directly into the shared `PLAN.md` file.

| Role | Responsibility | Key context to include in brief |
|------|---------------|--------------------------------|
| **CTO** | High-level architecture decisions, technology choices, risk assessment | Architecture from CLAUDE.md, deployment topology, active sub-plans from PLAN.md |
| **Software Architect** | Detailed system design, module boundaries, data flow, API contracts | SCHEMAS-INDEX sections, CONVENTIONS, relevant GOTCHAS grep results |
| **Expert Coder** | Implementation feasibility, code structure, patterns, edge cases | CONVENTIONS, relevant GOTCHAS, file roles from CLAUDE.md |
| **QA Expert** | Test strategy, test cases, E2E scenarios, regression risks | OPEN-PROBLEMS (to avoid re-introducing resolved bugs), GOTCHAS |
| **PM** | Task breakdown, dependencies, milestones, acceptance criteria | PLAN.md (current state), HANDOFF (remaining items), OPEN-PROBLEMS |

### 1.5 Build the Plan

The plan document (`PLAN.md`) must include:

1. **Executive Summary** — what we're doing and why
2. **Architecture & Design** (Architect + CTO)
3. **Implementation Steps** — numbered, ordered, with file paths (Coder + Architect)
4. **QA Strategy** — tests, E2E, validation steps embedded IN EVERY implementation step (QA)
5. **Risk Assessment** — what could go wrong and mitigations (CTO + PM)
6. **Task Breakdown & Dependencies** (PM)
7. **Acceptance Criteria** — how we know we're done (PM + QA)
8. **Governance Integration** — which canonical files need updating after implementation (from CONTEXT-MANIFEST)

The ACTION is: **{{ACTION}}** (ליצור / לשכתב)
The TOPIC is: **{{TOPIC}}**
The GOAL is: **{{GOAL}}**

---

## Phase 2 — Plan Review & Enrichment

### 2.1 Contradiction Check

Cross-reference the plan against the **Source-of-Truth Hierarchy** (from `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §3):

| Priority | Source |
|----------|--------|
| 1 (highest) | Runtime code + tests |
| 2 | `version.json` |
| 3 | `Plans/PLAN.md` |
| 4 | `docs/context/OPEN-PROBLEMS.md` |
| 5 | `docs/context/HANDOFF.md` |
| 6 | `docs/context/MEMORY.md` |
| 7 | `docs/context/CONVENTIONS.md` |
| 8 | `CLAUDE.md` |

Look specifically for:
- Facts that CONTRADICT anything in the plan (higher-priority source wins)
- Existing implementations that the plan overlaps with (read actual code, don't trust docs alone)
- Relevant gotchas: grep `docs/context/GOTCHAS.md` for every file path and module name mentioned in the plan
- Security considerations from `docs/context/CONVENTIONS.md` (security section)
- Durable decisions from `docs/context/MEMORY.md` that constrain the plan

### 2.2 Update the Plan

For every update, addition, or correction — add a timestamp:

```
[YYYY-MM-DD HH:MM] Updated: <description of change>
```

Improvements to apply:
- Cross-reference with gotchas (grep by file paths + module names in the plan)
- Verify no architectural violations per CONVENTIONS
- Ensure QA + Tests + E2E are embedded in EVERY step
- Add missing edge cases
- Strengthen security considerations
- Validate all file paths and module references ACTUALLY EXIST on disk (use Glob/Grep)

### 2.3 Final Review

Run one final review pass with the QA agent to verify:
- Every step has a verification method
- No circular dependencies
- All acceptance criteria are testable
- The plan is implementable in sequence
- No conflict with OPEN-PROBLEMS entries

---

## Phase 3 — Full Implementation

### 3.1 Execute the Plan

Implement ALL steps in the plan, continuously, until completion:

1. Follow the exact order defined in the plan
2. **Before each code-changing step**, apply `/impact-safe-executor` principles:
   - Identify files that will be modified and their dependents (impact map)
   - Verify the step stays within the approved plan scope
   - If the step would touch files outside the plan's scope -> STOP and ask the user
   - Prefer minimal edits — don't refactor surrounding code
   - Grep `docs/context/GOTCHAS.md` for the specific files being modified (by filename)
3. After each step, run the QA checks defined for that step
4. If a step fails QA — fix before proceeding
5. Update the plan file with completion timestamps:
   ```
   [YYYY-MM-DD HH:MM] COMPLETED: Step X — <description>
   ```
6. Use the Agent tool for parallel implementation where steps are independent

### 3.2 Post-Implementation Verification

After ALL steps are complete:
- Run full QA suite (server-side + client-side)
- Verify no regressions introduced
- Confirm all acceptance criteria are met
- Update plan status to COMPLETED

### 3.3 Governance State Update

After successful implementation and verification, invoke `/live-state-orchestrator` to update the governance layer. The orchestrator will handle:

1. **`Plans/PLAN.md`** — add milestone log entry with completion date and summary
2. **`docs/context/OPEN-PROBLEMS.md`** — mark any resolved items, add any new issues discovered
3. **`docs/context/MEMORY.md`** — add durable decisions or lessons learned (if any)
4. **`docs/context/GOTCHAS.md`** — append new gotchas discovered during implementation
5. **`docs/context/CONVENTIONS.md`** — update if new patterns were established
6. **`docs/context/SCHEMAS-INDEX.md`** — update if new schemas/APIs were added
7. **`CLAUDE.md`** — update if architecture changed (keep <500 lines)
8. **`docs/context/CONTEXT-MANIFEST.md`** — update `verified_on` dates for modified files

If `/live-state-orchestrator` is not available (ungoverned project), perform these updates manually following the same checklist.

### 3.4 Finish

Ask the user if they want to run `/full-finish` for the full release pipeline. **Do NOT invoke it automatically.**

---

## Behavior contract

- **Discover project paths dynamically** from `docs/context/CONTEXT-MANIFEST.md`. Do NOT hardcode paths.
- **Project-agnostic.** Works with ANY governed project. All paths resolved from manifest.
- **Source-of-Truth Hierarchy.** When files disagree, higher-priority source wins (code > version.json > PLAN > OPEN-PROBLEMS > HANDOFF > MEMORY > CONVENTIONS > CLAUDE.md).
- **Selective Context Loading.** Load ONLY files relevant to the plan's topic. Never read all MDs or all Plans.
- **GOTCHAS.md is grep-only.** Never read the full file (can be >80KB). Always grep by keywords.
- **Every implementation step MUST have QA embedded.** No exceptions.
- **Timestamps on everything.** Plan changes, completions, issues found.
- **Shared folder is the single source of truth** for inter-agent communication during planning.
- **Hebrew for communication, English for code.**
- **Verification Gate.** Never mark work as DONE without external evidence (test output, build log, docker logs, HTTP probe). "Looked correct" is NOT evidence.
- **Concurrency safe.** Check for `.lock` files before writing shared governance files.
- **Token budget.** Phase 1: ~55K tokens. Total skill execution: depends on plan scope.

---

## Stop conditions

The skill stops and asks the user when:

1. `Plans/PLAN.md` has multiple sub-plans `IN_PROGRESS` simultaneously (ambiguous focus)
2. A fact in the plan CONTRADICTS a higher-priority source and auto-resolution is unsafe
3. Two sources at the same hierarchy level disagree (Stop-Report Protocol)
4. A planned write would touch files outside the declared plan scope
5. Evidence collection fails — cannot verify a completed step
6. A gotcha attached to a target file warns against the exact planned change
7. The project is not governed (no CONTEXT-MANIFEST.md) and `CLAUDE.md` is also absent
8. `/full-finish` would be triggered — always ask user first, never auto-invoke

---

## Reference

- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §3 (Source-of-Truth Hierarchy)
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §5 (Selective Context Loading)
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §7 (Stop-Report Protocol)
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §8 (Verification Gate)
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §9 (Skills Reference)
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §10 (File Mutation Rules)
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §12 (Dynamic Path Detection)
