---
name: evidence-debugger
description: Evidence Root-Cause Debugger. Takes evidence (logs, errors, symptoms) and finds the root cause with explicit confidence level. Builds a minimal fix path. Maintains separation between proven and unproven claims. Master Plan §7.4.
user-invocable: true
---

# /evidence-debugger — Evidence Root-Cause Debugger

**Language:** Communicate in **Hebrew**. Code, paths, errors in **English**.

**Authority:** Context Governance framework (see `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §8). This is the DIAGNOSIS skill — produces a root cause hypothesis grounded in evidence, with explicit confidence and a minimal fix path. Does NOT execute the fix.

> This skill works on ANY governed project (has `docs/context/CONTEXT-MANIFEST.md`).

---

## Path Resolution (Dynamic)

Before any operation:
1. Read `docs/context/CONTEXT-MANIFEST.md` at the project root
2. Resolve paths for: GOTCHAS file, OPEN-PROBLEMS file, MEMORY file
3. If any file doesn't exist, note it and continue with available data
4. If CONTEXT-MANIFEST.md is missing → work with `CLAUDE.md` only (degraded mode)

---

## When to invoke

- **Manual:** `/evidence-debugger` when investigating a bug, error, regression, or surprising behavior
- **NOT for:** writing code (use `/impact-safe-executor`)
- **NOT for:** checking context state (use `/context-governance`)

---

## Inputs

- `evidence_sources` — list of logs/errors/screenshots/test outputs (paths or pasted content)
- `expected_behavior` — what the user thought should happen
- `actual_behavior` — what actually happened
- `suspected_scope` — files/modules the user already suspects (optional, often wrong)

If `evidence_sources` is empty, the skill REFUSES to proceed and asks for evidence.

---

## Execution steps

### Step 1 — Symptom statement
Write a one-sentence symptom statement that any person could understand without context.

If the symptom cannot be stated in one sentence, the report is too vague — ask the user to narrow it.

### Step 2 — Evidence inventory
List every piece of evidence with labels: `direct` (the bug itself) or `indirect` (correlated, may or may not be related).

### Step 3 — Filter to direct evidence only
Build the hypothesis from `direct` evidence ONLY. `indirect` evidence is held in reserve.

### Step 4 — Search for hypotheses
For each piece of direct evidence:
1. Grep the project's GOTCHAS file (path from manifest, if exists) for keywords from the evidence
2. Read MEMORY "Repeated Pitfalls" — does this match a known pitfall?
3. Read the relevant code paths — does any match the evidence pattern?
4. Run `git log --oneline -20 -- <suspected file>` — was this recently changed?
5. Check OPEN-PROBLEMS file (path from manifest) — is this already a known bug?

Generate 1-3 root cause hypotheses, each with:
- **Hypothesis statement** (one sentence)
- **Supporting evidence** (which direct evidence backs it)
- **Disconfirming evidence** (anything that argues against)
- **Confidence:** LOW (<=30%) | MEDIUM (30-70%) | HIGH (>=70%)

### Step 5 — Pick the leading hypothesis
- HIGH → present as the answer
- MEDIUM → present + suggest one minimal test to confirm
- LOW → do NOT recommend a fix; ask for more evidence

### Step 6 — Determine impact scope
What components are affected? Blast radius? Isolated or system-wide? Silent symptoms?

### Step 7 — Minimal fix path
Propose the smallest possible fix:
- One file, one function, one line if possible
- NO refactoring, NO unrelated improvements
- Include suggested gotcha entry to add after the fix

### Step 8 — Regression checklist
- Direct: does the bug stop reproducing?
- Indirect: are correlated symptoms also resolved?
- Side effect: any new symptoms in adjacent components?
- Long-term: what monitoring should detect recurrence?

### Step 9 — Output report
```
[evidence-debugger]
## Symptom
<one sentence>

## Evidence
- direct: <count>
- indirect: <count>

## Root cause (leading hypothesis)
<one sentence>
**Confidence:** HIGH | MEDIUM | LOW
**Supporting:** <evidence list>
**Disconfirming:** <list, or "none">

## Impact scope
<components affected>

## Minimal fix path
1. <file>:<line> — <change>
(usually 1-3 steps)

## Regression checklist
- [ ] Direct: <test>
- [ ] Indirect: <test>
- [ ] Side effect: <test>

## Proven vs unproven
- PROVEN: <list>
- UNPROVEN: <list>

## Gotcha to add (after fix)
<one-line gotcha entry>
```

---

## Behavior contract

- **NEVER guess.** LOW confidence = ask for more evidence, not propose a fix.
- **NEVER conflate symptoms with causes.**
- **NEVER fix more than one cause per invocation.**
- **PROVEN vs UNPROVEN section is mandatory.**
- **Read-only.** Does not edit code. Fix is done by `/impact-safe-executor`.
- **Project-agnostic.** All paths resolved from manifest.
- **Hebrew output** to user. English paths and code.
- **Token budget:** ~20K tokens per invocation.

---

## Stop conditions

1. Evidence insufficient for any hypothesis
2. Multiple hypotheses tie at same confidence
3. Leading hypothesis contradicts a Repeated Pitfall in MEMORY (prior pattern wins until disproved)
4. Fix path requires >5 lines across >2 files (bug is bigger than one root cause)

---

## Reference

- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §8 (Verification Gate)
- `docs/context/GOTCHAS.md` (project-specific, if exists)
- `docs/context/MEMORY.md` "Lessons Learned" + "Repeated Pitfalls"
- `docs/context/OPEN-PROBLEMS.md` (known bug list)
