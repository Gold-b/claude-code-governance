---
name: bootstrapper
description: Project Context Bootstrapper. Loads ONLY the relevant context for the current task using Selective Context Loading. Returns a focused briefing — current objective, current state, allowed scope, no-go zones, next safe action. Master Plan §7.1.
user-invocable: true
---

# /bootstrapper — Project Context Bootstrapper

**Language:** Communicate in **Hebrew**. All code, paths, identifiers in **English**.

**Authority:** Context Governance framework (see `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §5). This is the FIRST skill that runs at session start (after `context-governance lite`). It produces the briefing that Claude reads before doing any work.

**Core principle:** Load relevant context, NOT all context. Selective loading is mandatory.

> This skill works on ANY project that has been initialized with `/init-governance`.

---

## When to invoke

- **Auto:** `pre-session.sh` hook
- **Manual:** `/bootstrapper` at session start
- **After:** importing a session from another agent (alongside `parallel-session-merge`)
- **When in doubt** about what the current state is

---

## Inputs

The skill reads these from the user's first message or from the calling hook:

- `goal` — what is the user trying to do? (free text, optional)
- `candidate_scope` — directory/file hints from the user (optional)
- `last_handoff` — path to the active handoff if known (auto-detected from `docs/context/HANDOFF.md`)

If `goal` is empty, the skill assumes "general awareness" mode and produces a baseline briefing without scope-specific context.

---

## Execution steps

### Step 1 — Read the orchestration tier (mandatory)

1. `CLAUDE.md` (project orchestration — should be <500 lines)
2. `docs/context/CONTEXT-MANIFEST.md` — meta-index of all context files
3. `Plans/PLAN.md` — active sub-plan router
4. `docs/context/OPEN-PROBLEMS.md` first 80 lines (P1 + start of P2)
5. `docs/context/HANDOFF.md` (pointer check; if it points to another file, read that target ONLY if `status: active`)

**Ungoverned project fallback:** If `docs/context/CONTEXT-MANIFEST.md` does NOT exist:
- The project is NOT governed. Suggest `/init-governance` to the user.
- Produce a minimal briefing from `CLAUDE.md` alone (skip Steps 2-3).
- Note the missing governance structure in the briefing output.

**Token budget for Step 1:** ~25,000 tokens. This is the mandatory baseline.

### Step 2 — Selective Context Loading (scoped to goal)

Uses the algorithm from `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §5:

1. **Read the CONTEXT-MANIFEST.md "Canonical Files" table** — this lists ALL available context files with their `path`, `role`, and `description` fields.
2. **Extract keywords from the user's goal** — tokenize into meaningful terms.
3. **Match keywords against manifest entries:**
   - Compare goal keywords against each file's `role` and `description` fields
   - Score by keyword overlap (exact match > partial match > stem match)
   - Select the top 3-5 matching files
4. **Load matched files:**
   - For large files (GOTCHAS, CONVENTIONS): grep by goal keywords, do NOT read in full
   - For focused files (SCHEMAS-INDEX sections, architecture sections): read only the relevant section
   - For small files (<5KB): read in full
5. **If no manifest entries match the goal keywords:**
   - Load `docs/context/CONVENTIONS.md` (general code writing context)
   - Grep `docs/context/GOTCHAS.md` for any terms from the user's goal
   - Note limited context in the briefing output

**Token budget for Step 2:** ~30,000 tokens additional.

### Step 3 — Stale signal detection

Quickly verify:
- Active handoff is `status: active` and `consumed_at: pending` (NOT consumed)
- `Plans/PLAN.md` has at least one `status: IN_PROGRESS` sub-plan, or note that none is active
- `docs/context/MEMORY.md` Active Summary is current (mentions the current version from `version.json` or equivalent)
- If any sub-plan is `BLOCKED`, surface the blocker

### Step 4 — Compose briefing

Output a structured briefing:

```
[bootstrapper]
Project: <project name> (v<version> per version.json or equivalent)
Current rollout phase: <from PLAN.md active sub-plan status>

## Current Objective
<one sentence from PLAN.md or from user goal>

## Current State
- Active sub-plans: <list with status>
- Active handoff: <name + status + age>
- Recent milestones: <last 3 from PLAN.md milestone log>

## Allowed Scope (for this task)
<list of files/directories the user goal touches>

## No-Go Zones
<project-specific constraints extracted from CLAUDE.md — e.g., frozen deployments, read-only dirs, release gates>

## Stale Signals
<list, or "none">

## Next Safe Action
<one specific next step, with file paths>

## Read-These-First (if user wants to dive deep)
<top 3-5 file paths most relevant to the goal, sourced from CONTEXT-MANIFEST.md matches>
```

Total briefing output: ~400-800 tokens visible to user.

---

## Behavior contract

- **Read-only.** Never writes any file.
- **Token-bounded.** Step 1 <= 25K tokens, Step 2 <= 30K tokens, total <= 60K tokens.
- **Hebrew briefing.** All user-facing output in Hebrew. File paths and code in English.
- **Honest about gaps.** If a referenced file is missing or unreadable, surface it explicitly — do not silently skip.
- **No assumptions about intent.** If `goal` is ambiguous, ask one clarifying question before loading scoped context.
- **Idempotent.** Safe to invoke multiple times in a session — produces the same briefing for the same goal.
- **Project-agnostic.** Works with ANY governed project. All paths are discovered dynamically from CONTEXT-MANIFEST.md.

---

## Stop conditions

The skill stops and asks the user when:
1. `Plans/PLAN.md` has multiple sub-plans `IN_PROGRESS` (ambiguous current focus)
2. The active handoff is `consumed` but `Plans/PLAN.md` has not absorbed it
3. The user goal cannot be matched to any file in CONTEXT-MANIFEST.md AND no reasonable fallback exists
4. A canonical file referenced by the manifest is missing from disk
5. The project is not governed (no CONTEXT-MANIFEST.md) and `CLAUDE.md` is also absent

---

## Reference

- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §5 (Selective Context Loading algorithm)
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §2 (Canonical File Layout)
- `docs/context/CONTEXT-MANIFEST.md` (project-specific canonical files list)
- `Plans/PLAN.md` (current sub-plans)
