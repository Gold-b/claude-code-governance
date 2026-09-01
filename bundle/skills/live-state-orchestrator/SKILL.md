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

## Pre-Close Reality Check (MANDATORY before any HANDOFF write)

**BEFORE writing a new HANDOFF.md or transitioning a handoff to `consumed`/`archived`, you MUST invoke `/pre-close-check`.**

Rationale: this skill is the bookkeeper for canonical state. If a parallel session has already produced a newer handoff or released a new version, writing over it here would destroy that work. The 2026-04-17 v1.2.3-b/v1.2.4 incident happened exactly because the bookkeeper trusted in-session state over filesystem reality.

Flow:
1. Call `/pre-close-check` skill
2. If verdict is NOT `clean` → STOP, report to user, ask how to resolve (merge first? abort? override?)
3. Only proceed with handoff/state writes after verdict is `clean`

This applies to: new HANDOFF creation, handoff lifecycle transitions, PLAN.md milestone additions that claim release state.

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

### Step 6.1 — Render the continuation prompt (only if the session goal is still open)

Applies only when **all three** conditions hold (`~/.claude/docs/NEXT-SESSION-HANDOVER.md` §1):

1. The session was scoped by a goal — `/goal`, or a sub-plan in `Plans/PLAN.md` still `IN_PROGRESS`; **and**
2. That goal's Definition of Done is not fully satisfied; **and**
3. **The session is ENDING** — context threshold reached, the user stopped, or an unresolvable
   blocker was hit.

Condition 3 is not optional. This skill also runs after ordinary milestones, where conditions 1
and 2 are true by definition — rendering there would emit a copy-ready "hand this to the next
session" prompt in the middle of a session that is not ending. That is the mid-session status
stop `/loop` exists to suppress. **Mid-session invocation: skip this step entirely** and report
`skipped — session not ending` in Step 9.

- Spec + templates: `~/.claude/docs/NEXT-SESSION-HANDOVER.md`. Read it; do not improvise the format.
- **Target file: `docs/context/NEXT-SESSION-PROMPT.md`** — fixed name, fixed location, one per
  project. **Rewrite it from scratch every time; never append.** It is not a state record: it
  carries the goal, the Definition of Done, pointers, blockers and the next action, and points at
  `HANDOFF.md` / `Plans/PLAN.md` / `OPEN-PROBLEMS.md` rather than copying them.
- Update its `CONTEXT-MANIFEST.md` row in Step 7 (add the row if the project predates it).
- **Deleting is a CLOSE action only.** At an actual session close where no prompt is due (goal
  complete and verified, or no goal was scoped): delete the file if it exists and mark its
  manifest row `ARCHIVED`. A leftover prompt from the previous goal is read by the next session as
  its brief.
- **Mid-session — including `/full-finish` PART D — do NOTHING to this file.** Not write, not
  delete. Condition 3 above already skips the whole step; deleting there would mutate tracked
  state in the middle of a pipeline, and the prompt it removed may still be the correct handover
  if the session ends unexpectedly two phases later.

**Two modes.** The default is `persist` — render, write the file, emit to the user. The caller may
instead request **`render-only`**: produce the identical text, emit it to the user, and perform
**no write and no delete at all**. `render-only` exists for callers that must not dirty a tracked
file at that moment — `/full-finish` Phase 9.1 on the PASS-but-goal-open path, where touching a
tracked file after the release tag would turn a hermetic close that just passed into a dirty tree.
Without this mode that branch has no compliant path: the only renderer would always write, and
hand-writing the prompt is forbidden. Report which mode ran in Step 9.
- The prompt carries goal + Definition of Done + **pointers** + blockers + the precise next
  action. It must NOT restate the handoff body above it.
- Emit the same prompt to the user in chat.
- Every "done" claim inside it needs the evidence recorded in Step 3 (Verification Gate, §8).

Skip this step — and say so in the Step 9 summary — when the session is not ending, when the goal
is complete and verified, when no goal was scoped, or when the user said no continuation prompt
is needed.

### Step 7 — Update CONTEXT-MANIFEST.md
After updating the canonical files above, sync the manifest to match:
- Update the `verified_on` column for every file that was read or written in Steps 1-6
- If the HANDOFF pointer changed → update the HANDOFF row (`Points to` column + `verified_on`)
- If a new file was created (new handoff, new gotcha file) → add a row
- If a file was archived → update its status to `ARCHIVED` (do NOT delete the row)

### Step 8 — Update active rollout/plan headers
If any sub-plan in PLAN.md transitioned to RESOLVED → check its plan file header status line and update it.
Example: if SP-1 was marked RESOLVED in PLAN.md but `CONTEXT-GOVERNANCE-ROLLOUT-PLAN.md` header still says "Phase 2 AWAITING" → fix it.

### Step 9 — Output summary
```
[live-state-orchestrator]
Updated:
- PLAN.md: <what changed>
- MEMORY.md: <added entries or "no change">
- OPEN-PROBLEMS.md: <added/resolved entries>
- HANDOFF.md: <lifecycle change or "no change">
- Continuation prompt: <NEXT-SESSION-PROMPT.md rewritten (persist) | chat only (render-only) | deleted — goal complete | skipped — session not ending | skipped — no goal scoped>
- CONTEXT-MANIFEST.md: <rows updated or "no change">

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
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §18 (Goal-Scoped Autonomous Continuation)
- `~/.claude/docs/NEXT-SESSION-HANDOVER.md` (continuation-prompt renderer spec — Step 6.1)
