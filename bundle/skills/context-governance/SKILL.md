---
name: context-governance
description: Meta-Skill for auditing context-file hygiene. Two modes — Lite (~6.5K tokens, runs at session/task start) and Full (~150K tokens, runs on demand or weekly cron). Detects dual handoffs, version mismatches, broken cross-references, stale files, and contradictions. Master Plan §6.
user-invocable: true
---

# /context-governance — Context Hygiene Meta-Skill

> This skill works on ANY project that has been initialized with `/init-governance`.

**Language:** Communicate in **Hebrew**. All code, paths, file content in **English**.

**Authority:** Master Plan v1.2 §6 (Context Governance). This is the META skill that all other Super-Skills depend on. It does NOT do any work — it audits the state of the context layer and reports findings.

---

## Project Detection (Dynamic — No Hardcoded Paths)

Before running any audit steps, the skill MUST detect the project context dynamically:

1. **Find project root:** Use CWD, or walk up to the nearest directory containing `CLAUDE.md`.
2. **Check governance status:** Look for `docs/context/CONTEXT-MANIFEST.md` at the project root.
   - **If found:** Read the manifest to discover all canonical file paths, knowledge directories, plan directories, and any project-specific overrides.
   - **If NOT found:** Report that the project is not governed and suggest the user run `/init-governance` to scaffold the canonical layout. Then STOP — do not proceed with audit steps.
3. **Canonical layout reference:** See `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §2 for the expected file structure.

All paths below are expressed RELATIVE to the detected project root. The manifest is the single source of truth for where files live in each specific project.

---

## Modes

This skill has TWO modes. Determine which to run based on the invocation context.

### Mode A — Lite (default for hooks)

**Trigger:** `pre-session.sh`, `pre-task.sh` hooks. Also: explicit invocation `/context-governance lite` or `/context-governance` with no argument.

**Scope:** ~10 files, ~5 seconds wall-clock, ~6,500 tokens total.

**What it does:**
1. Glob the canonical files as listed in the manifest:
   - `CLAUDE.md`
   - `docs/context/CONTEXT-MANIFEST.md`
   - `Plans/PLAN.md`
   - `docs/context/HANDOFF.md`
   - `docs/context/OPEN-PROBLEMS.md`
   - `docs/context/MEMORY.md` (optional read)
2. Read ONLY `CONTEXT-MANIFEST.md` in full. Trust its claims about other files (do NOT open them).
3. Verify: each canonical file in the manifest's "Canonical Files" table actually exists at the listed path.
4. Verify: only ONE handoff has `status: active` in its frontmatter (search for `HANDOFF*.md` in both `docs/context/` and any archive directories listed in the manifest).
5. Verify: the version in `version.json` (or project-equivalent version source) matches references in `CLAUDE.md` (one regex check).
6. Skip steps D, E, F, G of the full audit.

**Red-flag escalation:** If Lite detects ANY of these, it auto-escalates to Full Audit:
- More than one `status: active` handoff
- A canonical file listed in the manifest is missing on disk
- `version.json` and `CLAUDE.md` disagree on the version string
- A new file at `docs/context/*.md` exists that is NOT in the manifest

**Output:** ~300 tokens. Format:
```
[context-governance lite]
- canonical files: X/Y present
- active handoffs: 1 (expected)
- version sync: ok
- red flags: none | <list>
- next: clean | escalate-to-full
```

### Mode B — Full Audit

**Trigger:** Explicit `/context-governance full`, weekly cron from `/schedule`, or auto-escalation from Lite.

**Scope:** 30-40 files, 60-180 seconds wall-clock, ~135K-165K tokens total.

**What it does:** All 7 steps A-G.

#### Step A — Inventory
Glob recursively under all directories listed in the manifest (typically `docs/`, `Plans/`, and any project-specific knowledge directories). Build a list of every `.md` file with size, mtime, and a short header excerpt.

#### Step B — Classification
Open each context file. Read frontmatter + first 10 lines. Classify each as one of: `orchestration`, `plan`, `handoff`, `memory`, `conventions`, `schemas`, `gotchas`, `manifest`, `audit-snapshot`, `archived`, `functional-runtime`, `unknown`.

#### Step C — Architectural validation
For each canonical role from `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §2, verify exactly one file fills it (exception: pointers count toward their target).

#### Step D — Content validation
- Cross-reference: for every markdown link `[...](path)` in the canonical files, verify the target exists.
- Contradiction scan: read pairs of files that should agree (version file ↔ `CLAUDE.md`, `Plans/PLAN.md` ↔ active `HANDOFF.md`, `docs/context/MEMORY.md` ↔ `docs/context/OPEN-PROBLEMS.md`). Flag any disagreement.
- Stale TODO scan: `grep -rn "TODO\|FIXME" docs/ Plans/ CLAUDE.md`. Anything older than 30 days is a candidate for archive or escalation.
- Ownership scan: every file in the manifest should have either `owner` field or be implicitly project-wide.

#### Step E — Risk audit
Group findings into High / Medium / Low:
- HIGH: dual sources of truth, broken canonical files, version mismatch, fail-closed defenses on misconfigured fields
- MEDIUM: stale references, archive items still referenced as active, files not in manifest
- LOW: formatting drift, naming inconsistencies

#### Step F — Remediation plan
For each finding, propose one of: `fix-now`, `archive`, `merge-with`, `mark-stale`, `delete`, `ask-user`. Do NOT execute any destructive action without user approval (Stop-Report Protocol).

#### Step G — Manifest update
Update `docs/context/CONTEXT-MANIFEST.md`:
- `verified_on` field for every file checked
- Add new files found that weren't in the manifest
- Mark deleted files as `STATUS: missing` (do not delete the row — historical evidence)
- Append change log entry

**Output:** ~3,000 tokens. Format:
```
[context-governance full]
## A. Inventory: <count> files
## B. Classification: <breakdown>
## C. Architectural: <pass/fail per canonical role>
## D. Content: <findings count>
  - Cross-references: <broken/total>
  - Contradictions: <list>
  - Stale TODOs: <count>
## E. Risks: H=<n> M=<n> L=<n>
## F. Remediation:
  - <action>: <file> → <reason>
## G. Manifest: <updated/no-change>
```

---

## Stop-Report Protocol (both modes)

If the skill finds a contradiction it cannot resolve safely:
1. STOP — do not auto-fix.
2. Report findings to the main session.
3. List proposed actions with risk level.
4. Wait for user decision.
5. Never proceed with destructive action without explicit approval.

---

## Behavior Contract

- **Read-only by default.** Lite mode never writes. Full mode writes ONLY to `docs/context/CONTEXT-MANIFEST.md` (Step G).
- **Fail-soft.** If any file is missing or unreadable, log and continue. Never throw.
- **Token-bounded.** Lite: max 8K tokens output. Full: max 200K tokens output. Refuse to read individual files larger than 50KB without explicit user approval.
- **No code edits.** This skill never edits source code, configuration code, or runtime modules.
- **Project-agnostic.** All paths are resolved dynamically from the manifest. No hardcoded project paths exist in this skill.
- **Hebrew output to user.** Findings are reported in Hebrew, with English file paths and code snippets.

---

## Reference

- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §2 (canonical file layout)
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §3 (source-of-truth hierarchy)
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §11 (governance modes)
- Master Plan §6.3 (mode definitions)
- Master Plan §6.5 (7 audit steps)
- Master Plan §11.3 (Stop-Report Protocol)
