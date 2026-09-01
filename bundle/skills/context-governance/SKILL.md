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
2. Read ONLY `CONTEXT-MANIFEST.md` in full — but read it as a **routing table, not a report.**
   - **Trust it for WHERE things are.** Paths, which file fills which canonical role, which directory holds
     the archive, which row is `ACTIVE` vs `ARCHIVED`. Routing is the manifest's job and the one thing it is
     reliably good at; following a path costs nothing, and that is what keeps Lite cheap.
   - **Never trust it for WHAT they contain.** Line counts, file sizes, item/tool/problem counts, versions,
     "which handoff is active", "not yet created" — these are snapshots of a moment that has already passed,
     and they rot **silently**: nothing in the manifest turns red when the file it describes changes
     underneath it. Measured on one project, a canonical file the manifest sized at "~409 lines" was 2,858; a
     "65 tools" figure executed to 86; and rows still carried the scaffolding phrase "not yet created" about
     files that had existed for months. Lite reported CLEAN through all of it — **because it had been told
     not to look.** That instruction is how a wrong index propagates unchallenged, session after session.
   - **The operative rule: any number this session is about to ACT on must be MEASURED, not read.** One
     command beats any figure in an index — `wc -l`, `grep -c`, `stat`, `git log -1`, or executing the source
     of truth (`node -e '…length'`) for a count the code owns. If you are merely *mentioning* a figure in a
     report, attribute it (`manifest says N — unverified`); never restate it as fact.
   - **Cost discipline — this must not turn Lite into Full.** Do NOT open the described files to verify them.
     Measure with cheap shell probes only: a `wc`/`stat`/`grep -c` costs ~10 tokens, while opening one
     2,858-line file costs ~40K — the Full-audit budget Lite exists to avoid. Budget **at most ~5 probes per
     run**, spent only on facts this session will actually use. A manifest claim nobody is acting on needs no
     probe at all; leave it alone rather than paying to disprove it.
3. Verify: each canonical file in the manifest's "Canonical Files" table actually exists at the listed path — **for rows whose Status is `ACTIVE` only.** A row marked `ARCHIVED` means "this path is intentionally absent"; the convention is to set the status and keep the row, never to delete it (`/init-governance`, `/live-state-orchestrator` Step 7). Checking archived rows for existence turns every correctly closed project into a red flag — for example a project that finished its goal and therefore deleted `docs/context/NEXT-SESSION-PROMPT.md`.
4. **Verify: exactly ONE active handoff — counting FILES, not markers.** Search `HANDOFF*.md` under
   `docs/context/`, the project's handoff directory (e.g. `MDs/`), and any archive directories listed in the
   manifest; collect every file declaring itself active.
   - **A pointer does NOT count toward the total.** The governed layout is deliberately two files: a
     fixed-path pointer (`docs/context/HANDOFF.md`) and the versioned handoff it names. **Both are marked
     `status: active`, and that is the CORRECT state** — the pointer is active *as a pointer*, not as a second
     source of truth. Counting it turns the healthy steady state into a permanent red flag that escalates
     every single session start into a ~150K-token Full Audit, which trains the operator to ignore the alarm.
   - **Identifying a pointer — verify, do not assume.** A file is a pointer when its frontmatter carries
     `type: pointer` **or** `points_to: <path>`. Check which marker the project actually uses before excluding
     anything (in the layout this rule was written against, `docs/context/HANDOFF.md` carries **both**, plus
     the body line "This file is a pointer, not the source."). A file marked active with **neither** marker is
     a real handoff and it counts.
   - **Count = (files declaring active) − (those that are pointers). Expected: exactly 1.** Then confirm the
     pointer's `points_to` target IS that one file. A pointer still aimed at a superseded handoff is its own
     red flag — `pointer/target mismatch` — and in practice a far more common failure than a true dual handoff.
   - **A REAL violation keeps its teeth:** two independent handoff FILES, neither a pointer, both claiming
     active — typically two versioned handoffs where the older was never stamped `superseded_by`. That is the
     dual-source-of-truth this check exists to catch, and it still escalates to Full.
   - **Prose statuses are IN scope — a frontmatter-only grep reads half the evidence.** Handoffs are not all
     YAML: a file can declare `**Status:** active` in blockquote prose with **no frontmatter at all** (six such
     files sat in one project's `MDs/`, every one of them long superseded, and all six were invisible to the
     frontmatter check while it reported CLEAN). A rule that silently ignores half the evidence is the exact
     failure mode this audit exists to end. Scan both forms in one call:
     ```bash
     grep -rliE '^[[:space:]]*(>[[:space:]]*)?(status:|\*\*status:\*\*)[[:space:]]*active' <handoff-dirs>/HANDOFF*.md
     ```
   - **Prose hits are REPORTED, not escalated.** A prose `Status: active` on a handoff that a newer one
     supersedes is a MEDIUM finding — `unstamped superseded handoff (prose status): <file>` — not a dual
     handoff; escalating six historical files to Full every session would just recreate the false alarm above.
     The remedy (edit that line to `superseded`) is a WRITE, therefore a PROPOSED action requiring operator
     approval (Behavior Contract + Stop-Report Protocol) — Lite never performs it. Only a prose-active file
     that is **not** superseded by a newer handoff counts toward the active total and escalates.
5. Verify: the version in `version.json` (or project-equivalent version source) matches references in `CLAUDE.md` (one regex check).
6. **Canonical working-copy invariant.** If `CONTEXT-MANIFEST.md` declares `canonical_working_copy` (frontmatter) or a "Canonical Working Copy" section, compare it to the current project root (`pwd`). If they differ — OR a `_STALE_DO_NOT_USE.md` tombstone exists at the project root — **STOP**: you may be on a stale/duplicate copy (e.g., a cloud-sync mount such as OneDrive/Google Drive). This is the check that catches a zombie copy which otherwise looks valid (all canonical files present, exactly one active handoff). See `GOTCHAS.md` #11. A SessionStart guard (`canonical-cwd-check.sh`) enforces the same invariant independently.
7. **Stale next-session prompt.** If `docs/context/NEXT-SESSION-PROMPT.md` exists, compare its
   mtime to `docs/context/HANDOFF.md`. If the prompt is OLDER, report
   `stale next-session prompt (<N> days behind HANDOFF)`. It is a paste-ready brief with no
   `status` field and nothing marking it out of date, so a session reads it as current — which is
   exactly how one project's prompt went 16 days stale while still describing infrastructure that
   had moved. One `stat` call; do not open the file. The rule it enforces: the prompt is rewritten
   from scratch at every close, or deleted (`GOVERNANCE-AGENT-GUIDE.md` §18).
7b. **Misplaced or duplicate next-session prompt.** Check 7 only `stat`s the canonical path, so a
   prompt at any OTHER path is invisible to it — it silently rots and a later session can read a stale
   or duplicate brief. Search ALL project paths (`MDs/`, `Plans/`, the project root, **and
   `docs/context/` itself**) for `NEXT-SESSION-PROMPT.md` and the legacy variants
   (`NEXT-SESSION-KICKOFF.md`, `NEXT-SESSION-PROMPT-*.md`). The ONLY allowed file is the exact path
   `docs/context/NEXT-SESSION-PROMPT.md` (one per project — `~/.claude/docs/NEXT-SESSION-HANDOVER.md`
   §0); flag every other match — **including a variant that lives inside `docs/context/`** (e.g.
   `docs/context/NEXT-SESSION-KICKOFF.md`), which the step-3 manifest-existence check would otherwise
   pass whenever that variant happens to be registered. Any match → red flag `misplaced next-session
   prompt at <path> (canonical: docs/context/NEXT-SESSION-PROMPT.md)`. This is the naming-drift the
   fixed-name convention exists to end: before it, "every project invented its own name" (the spec
   lists four variants across four projects). **Report and escalate only — Lite never writes, and MUST
   NOT relocate or delete anything here** (Behavior Contract + Stop-Report Protocol): a drifted file
   may be the newer or the only copy, so the remedy — relocate to the canonical path and register the
   manifest row, or delete a confirmed duplicate — is a PROPOSED action requiring the operator's
   explicit approval. One `find`/glob call; do not open the files.
8. Skip steps D, E, F, G of the full audit.
9. **Parallel-session check** (GOVERNANCE-AGENT-GUIDE §16). Cheap signals: `.claude/scheduled_tasks.lock` PID alive; another
   transcript in `~/.claude/projects/<project-key>/` modified < 10 min ago; staged files you did not stage. If ANY fires:
   report `parallel session: LIKELY (<evidence>)` and switch to coordination rules — commit only your own paths
   (`git commit -- <paths>`), no `-A/-u/stash/checkout --/reset --hard`, re-read before edit, `/parallel-session-merge`
   before any HANDOFF write. A "[GOVERNANCE CRASH RECOVERY]" banner is NOT proof of a crash when this check fires.

**Red-flag escalation:** If Lite detects ANY of these, it auto-escalates to Full Audit:
- More than one active handoff **FILE** after excluding pointers (check 4) — i.e. two independent handoffs,
  neither carrying `type: pointer` / `points_to:`, both claiming active. A pointer plus its target both marked
  active is the CORRECT governed state and is **not** a red flag. A prose-only `Status: active` on a handoff
  that a newer one supersedes is reported MEDIUM, not escalated; a pointer whose `points_to` names a
  superseded handoff (`pointer/target mismatch`) IS a red flag
- A canonical file listed in the manifest with Status `ACTIVE` is missing on disk (an `ARCHIVED` row pointing at an absent path is correct, not a red flag)
- `version.json` and `CLAUDE.md` disagree on the version string
- A new file at `docs/context/*.md` exists that is NOT in the manifest
- A `NEXT-SESSION-PROMPT.md` (or `NEXT-SESSION-KICKOFF.md` / `NEXT-SESSION-PROMPT-*.md`) exists at any path other than the exact `docs/context/NEXT-SESSION-PROMPT.md` — a misplaced/duplicate next-session prompt (INCLUDING a variant inside `docs/context/` that step-3's manifest-existence check passes because it is registered), invisible to check 7's canonical-path staleness `stat`, so a session can read the wrong brief (check 7b)
- The current project root does NOT match `canonical_working_copy` declared in `CONTEXT-MANIFEST.md` (you may be on a stale/duplicate copy), or a `_STALE_DO_NOT_USE.md` tombstone is present at the project root
- The `canonical_working_copy` in `CONTEXT-MANIFEST.md` does NOT match the path in the `CLAUDE.md` "Canonical Working Copy" banner — a canonical fact was updated in one always-read file but not propagated to the other (the H:\ stale-copy incident's root cause); reconcile CLAUDE.md / CONTEXT-MANIFEST / MEMORY before proceeding

**Output:** ~300 tokens. Format:
```
[context-governance lite]
- canonical files: X/Y present
- active handoffs: 1 (expected; pointer excluded) [+ <n> unstamped-superseded (prose) — MEDIUM]
- version sync: ok
- red flags: none | <list>
- parallel session: none | LIKELY (<evidence>)
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
- **Self-contradicting entries** (added 2026-08-24 after four were found at once). An entry that carries a `✅ RESOLVED` paragraph *above* a `Status: OPEN` line is worse than either state alone, because whichever line a session reads first becomes the truth. One found this way had been resolved for four days while a session opened it intending to fix it again.

  ```bash
  awk '/^### [0-9]+[a-z]?\./{h=$0; res=0}
       /✅ \*\*RESOLVED|^- \*\*✅ RESOLVED/{if(h!="")res=1}
       /^- \*\*Status:\*\* OPEN/{if(res==1 && h!="") print "CONTRADICTS: " substr(h,1,90)}' <open-problems-file>
  ```

  Expect false positives where a flag or constant contains the word (`RESOLVED_CONFIG_STANCE` is a flag name, not a resolution) — **read each hit before reporting it.** The remedy is always to EDIT the `Status:` line, never to prepend another paragraph above it.
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
