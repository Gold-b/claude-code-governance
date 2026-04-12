---
name: impact-safe-executor
description: Impact-Safe Executor. Runs BEFORE every code write. Builds an impact map (dependencies, contracts at risk, regression zones), enforces approved scope, performs minimal edit, collects external evidence. Stops for approval if scope exceeded. Master Plan §7.3.
user-invocable: true
---

# /impact-safe-executor — Impact-Safe Executor

**Language:** Communicate in **Hebrew**. Code, paths, identifiers in **English**.

**Authority:** Context Governance framework (see `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §8). This is the WRITE-SAFETY skill — the guard that runs before every code modification to prevent silent regressions.

> This skill works on ANY governed project (has `docs/context/CONTEXT-MANIFEST.md`).

---

## Path Resolution (Dynamic)

Before any operation:
1. Read `docs/context/CONTEXT-MANIFEST.md` at the project root
2. Resolve paths for: GOTCHAS, CONVENTIONS, SCHEMAS-INDEX, PLAN
3. If CONTEXT-MANIFEST.md is missing → suggest `/init-governance` and abort

---

## When to invoke

- **Auto:** `pre-write.sh` hook — fires on PreToolUse for Edit/Write/MultiEdit/NotebookEdit
- **Manual:** `/impact-safe-executor` before any planned code change
- **NOT during:** documentation-only edits to `docs/context/*` (those go through the orchestrator)

---

## Inputs

- `goal` — what is being built/fixed (one sentence)
- `approved_plan` — reference to the PLAN.md sub-plan section
- `allowed_scope` — explicit list of files allowed to edit
- `stop_condition` — what would constitute "scope exceeded"
- `validation_requirements` — what evidence will be required before DONE

If `allowed_scope` is empty, the skill REFUSES to proceed and asks the user to declare scope first.

---

## Execution steps

### Step 1 — Read scope-relevant context
1. Each file in `allowed_scope` (full read)
2. Project file-roles documentation (if referenced in manifest)
3. GOTCHAS file (grep filtered by filename of each scope file, resolved from manifest)
4. SCHEMAS-INDEX (relevant sections, resolved from manifest)
5. CONVENTIONS (code conventions + forbidden patterns, resolved from manifest)

### Step 2 — Build impact map
For each file in `allowed_scope`:

```
File: <path>
- Direct callers: <grep result count>
- Indirect dependencies: <2-hop transitive callers>
- Contracts touched:
  - API endpoints: <list>
  - Config fields: <list>
  - Exported functions: <list>
- Regression zones (gotchas tagged with this file): <gotcha numbers, if GOTCHAS file exists>
- Risk level: LOW | MEDIUM | HIGH
```

**Risk classification (generic):**
- **HIGH** — file with >5 direct callers OR has CRITICAL gotchas OR listed as `authority: HIGH` in manifest OR is a core config/routing/processing file
- **MEDIUM** — file with 2-5 callers OR is referenced from a gotcha
- **LOW** — leaf file with 0-1 callers OR pure utility

### Step 3 — Scope check
- For each planned write, verify the target file is in `allowed_scope`
- If a write would touch a file NOT in scope → STOP, ask user
- If a write would touch a HIGH-risk file → STOP, ask user with the impact map

### Step 4 — Execute the write (minimal edit)
- Make ONE edit at a time
- After each edit, verify the change matches the intent (read the modified region)
- Do NOT batch unrelated changes
- Do NOT add "improvements" that weren't in the goal

### Step 5 — Collect external evidence
After each milestone:
- Run relevant validation: lint, typecheck, focused test, build, or probe
- Capture the OUTPUT (not just "ran successfully")
- Append evidence to a scratch file

**Acceptable evidence:** test output with PASS, build/lint exit 0, docker logs, HTTP probe, file mtime + content. **NOT acceptable:** "looked correct", "should work", "compiles in my head".

### Step 6 — Update PLAN.md (via live-state-orchestrator)
- Append milestone with evidence log
- Mark step COMPLETED only if evidence is non-empty

### Step 7 — Output report
```
[impact-safe-executor]
Goal: <one sentence>
Files touched: <list>
Impact map summary: HIGH=<n> MEDIUM=<n> LOW=<n>
Approvals requested: <list, or "none">
Evidence collected:
- <validation>: <result>
Risks remaining: <list, or "none">
Next: <continue | block | done>
```

---

## Behavior contract

- **MUST stop for approval** when scope exceeded, HIGH-risk file first edit, or evidence fails
- **NEVER claim DONE** without evidence in Step 5
- **NEVER batch** unrelated changes
- **NEVER refactor** code not in the goal
- **NEVER add** dependencies/features beyond the goal
- **Concurrency safe.** Check `.lock` files per governance protocol.
- **Project-agnostic.** All paths resolved from manifest. No hardcoded project paths.
- **Hebrew status updates** to user. English code and paths.

---

## Generic forbidden patterns

- ❌ Writing to directories marked read-only in CLAUDE.md
- ❌ Git push / reset --hard / push --force without explicit user command
- ❌ Adding "improvements" not in the goal
- ❌ Hardcoding values that should be derived from config/version files
- ❌ Skipping evidence collection

(Project-specific forbidden patterns are loaded dynamically from `docs/context/CONVENTIONS.md` §"Forbidden Patterns" if it exists.)

---

## Stop conditions

1. `allowed_scope` is empty or undefined
2. A HIGH-risk file is about to be edited for the first time this session
3. Proposed change touches a file NOT in `allowed_scope`
4. Validation evidence cannot be collected
5. A gotcha attached to the file warns against this exact change

---

## Reference

- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §8 (Verification Gate)
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §10 (File Mutation Rules)
- `docs/context/CONVENTIONS.md` (project-specific forbidden patterns)
- `docs/context/GOTCHAS.md` (project-specific bug-driven rules)
