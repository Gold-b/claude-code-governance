# Active Task Plan

> Turn-scoped checklist. SUBORDINATE to `Plans/PLAN.md` (rank 3 in the source-of-truth hierarchy,
> `docs/context/CONTEXT-MANIFEST.md`). This file holds checkable items for the task in flight and
> carries no facts of its own - like `docs/context/NEXT-SESSION-PROMPT.md`, it can never win a
> disagreement with PLAN / HANDOFF / OPEN-PROBLEMS. Reset it when a task starts. At close, the
> milestone goes to `Plans/PLAN.md` and any lesson to `tasks/lessons.md` (then promoted).
>
> Created 2026-09-15 by the Boris Cherny harness audit (`docs/context/BORIS-HARNESS-PROPOSAL.md`).
> NOT gitignored yet (proposal change C) - until that lands this file is tracked in a PUBLIC repo:
> placeholders only, no client names, no machine paths (CLAUDE.md rule 1).

## Objective
<one sentence: what this task changes and what "done" means>

## Plan trigger
- [ ] 3+ moving parts, a structural change, or an architecture decision -> plan BEFORE touching code
- [ ] Drift from the plan detected mid-task -> STOP, re-plan here, then continue

## Verification Criteria (define BEFORE editing)
- [ ] `bash ~/.claude/hooks/governance/governance-selftest.sh` -> `fail=0 uncovered=0`
      (hook / skill / installer changes; NOT while a sandbox run is alive under `~/.gov-selftest/`
      - a second run clobbers the verdict file, and a script with a live instance is read-only, GOTCHAS #14)
- [ ] `bash verify.sh` -> 0 FAILED (installer changes)
- [ ] Positive AND negative control in the same run for every new check (CONVENTIONS "Verification")
- [ ] Isolated review: Agent `zero-context-verifier` -> `Status: APPROVED`, objections cite `path:line`
- [ ] Elegance check: is there a simpler shape that keeps the same fail-loud, fail-closed guarantees?

## Execution Steps
- [ ] Step 1: research / enumeration - delegated to a subagent; only the conclusion enters this context
- [ ] Step 2: implementation - minimal edit inside the declared scope
- [ ] Step 3: local verification - the criteria above, with the evidence pasted below
- [ ] Step 4: isolated review - hand `zero-context-verifier` the diff + touched files + raw test output ONLY
- [ ] Step 5: record - milestone to `Plans/PLAN.md`, lessons to `tasks/lessons.md`, handoff at close

## Evidence log
<paste the actual command output here - a description of it is not evidence>
