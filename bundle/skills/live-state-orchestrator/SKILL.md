---
name: live-state-orchestrator
description: Live State Orchestrator. Updates PLAN.md, MEMORY.md, OPEN-PROBLEMS.md, and HANDOFF.md after milestones. Manages handoff lifecycle (active → consumed → archived). Runs after each meaningful step. Master Plan §7.2.
user-invocable: true
---

# /live-state-orchestrator — Live State Orchestrator

**Language:** Communicate in **Hebrew**. All file content in **English**.

**Authority:** Context Governance framework (see `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §10). This skill keeps the project's "current state" files in sync with reality. It is the bookkeeper.

> This skill works on ANY governed project (has `docs/context/CONTEXT-MANIFEST.md`).

---

## Path Resolution (Dynamic)

Before any file operation:
1. Read `docs/context/CONTEXT-MANIFEST.md` at the project root
2. From the "Canonical Files" table, resolve paths for: PLAN, HANDOFF, MEMORY, OPEN-PROBLEMS
3. If any canonical file uses a pointer (frontmatter `type: pointer`), follow it to the real content file
4. If CONTEXT-MANIFEST.md is missing → suggest `/init-governance` and abort

---

## When to invoke

- **Auto:** `post-milestone.sh` hook — after meaningful tool sequences
- **Auto:** `end-session.sh` hook — at session close
- **Manual:** `/live-state-orchestrator` after a logical milestone
- **After:** completing a significant fix, finishing a phase, resolving a bug

---

## Inputs

- `goal` — what was being worked on (free text)
- `current_phase` — which sub-plan / which phase (auto-detected from PLAN.md)
- `completed_changes` — list of files touched since last invocation
- `validation_status` — what evidence was collected
- `decisions` — any new durable decisions made
- `findings` — any new lessons learned or pitfalls discovered

---

## Execution steps

### Step 1 — Read current canonical state
1. `Plans/PLAN.md` (full)
2. `docs/context/HANDOFF.md` (lifecycle frontmatter + summary section)
3. `docs/context/MEMORY.md` (full)
4. `docs/context/OPEN-PROBLEMS.md` (first 100 lines: P1 + P2 start)

All paths resolved dynamically from CONTEXT-MANIFEST.md.

### Step 2 — Determine what changed
- Which sub-plan in PLAN.md does this work belong to?
- Is the work a milestone (phase complete, sub-plan complete, bug resolved)?
- Was new evidence collected?
- Were any contradictions or surprises encountered?

### Step 3 — Update PLAN.md
- Add a milestone log entry (date + what changed + verification + next action)
- If a sub-plan transitioned states (NEW → IN_PROGRESS → BLOCKED → RESOLVED), update its `Status:` field
- If a sub-plan is RESOLVED, add it to the project-wide milestone log table
- NEVER delete completed milestones — append-only

### Step 4 — Update MEMORY.md (only if there are durable findings)
**Add to "Durable Decisions"** when the session made an architectural choice that should outlive this work.
**Add to "Lessons Learned"** when a bug's root cause should change future behavior.
**Add to "Repeated Pitfalls"** when a failure mode happened more than once.
**Update "Active Summary"** with current version, current phase, current sub-plans.

**Do NOT add to MEMORY.md:** Bug lists (they go in OPEN-PROBLEMS), transient session state (it goes in PLAN.md), one-off observations (they go in the next handoff).

### Step 5 — Update OPEN-PROBLEMS.md
- Bug resolved → add resolution, mark with `~~strikethrough~~` and `**Status:** RESOLVED (v<version>, <date>)`
- New bug discovered → append to the right priority section (P1/P2/P3)
- If a pointer file exists → update the Quick Index in the pointer

### Step 6 — Manage HANDOFF lifecycle
Lifecycle transitions per `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §6:
- `active` → `consumed`: when session fully absorbed the handoff into PLAN/MEMORY
- `consumed` → `archived`: at end-session if no further work depends on it

**Rules:**
- Only ONE handoff may be `active` at any time
- When transitioning to `consumed`, MUST set `consumed_at` + `imported_into_plan_section`
- Never mark consumed if work is not actually absorbed
- Never leave two handoffs `active` simultaneously

### Step 7 — Output summary
```
[live-state-orchestrator]
Updated:
- PLAN.md: <what changed>
- MEMORY.md: <added entries or "no change">
- OPEN-PROBLEMS.md: <added/resolved entries>
- HANDOFF.md: <lifecycle change or "no change">

Next action: <from updated PLAN.md>
Context delta: <one-line summary of what is now true that wasn't before>
```

---

## Behavior contract

- **Append-only by default.** Editing existing entries only when correcting an error.
- **Diff before write.** Read current state, compute diff, verify no concurrent changes.
- **Concurrency safe.** Check for `.lock` file before writing.
- **Honest about uncertainty.** If unsure about RESOLVED, use `Status: needs-verification`.
- **Project-agnostic.** All paths resolved from manifest.
- **Hebrew output.** English file paths and code.
- **Token budget:** ~15K tokens per invocation.

---

## Stop conditions

1. A milestone seems to belong to multiple sub-plans
2. Handoff content does not match the work done (parallel session mismatch)
3. RESOLVED would be claimed without external evidence
4. A file was updated without going through the orchestrator (drift detected)

---

## Reference

- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §6 (HANDOFF lifecycle)
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §8 (Verification Gate)
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §10 (File Mutation Rules)
