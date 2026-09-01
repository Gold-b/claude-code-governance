# Context Governance — Agent Operational Guide

> **Audience:** LLM agents (Claude Code, sub-agents, orchestrators). This document is structured for machine consumption — explicit instructions, decision trees, exact paths, I/O contracts.
> **Human companion doc:** `~/.claude/docs/GOVERNANCE-HUMAN-GUIDE.md`
> **Version:** 1.0 (2026-04-12)
> **Scope:** Universal — applies to ALL projects, not just one specific project.

---

## 1. What is Context Governance

Context Governance is a mandatory framework that ensures every Claude Code session:
- Knows what it is working on (objective + state)
- Knows what files to trust (source-of-truth hierarchy)
- Never overwrites or contradicts work done by other sessions
- Produces verifiable evidence before marking work as done
- Writes a handoff so the next session can resume without asking "where were we?"

**If you are reading this, you MUST follow these rules in every session.**

---

## 2. Canonical File Layout

Every governed project MUST have this structure. If a file is missing, run `/init-governance` to scaffold it.

```
<project-root>/
├── CLAUDE.md                              # Project orchestration (slim, <500 lines)
├── docs/
│   └── context/
│       ├── CONTEXT-MANIFEST.md            # Meta-index of all context files
│       ├── HANDOFF.md                     # Active session bridge (lifecycle: active/consumed/archived)
│       ├── NEXT-SESSION-PROMPT.md         # Paste-ready next-session prompt — pointers only, rewritten or deleted every close (§18)
│       ├── OPEN-PROBLEMS.md               # Unresolved work tracker (or pointer to existing file)
│       ├── MEMORY.md                      # Durable decisions + lessons + pitfalls (NOT bugs)
│       ├── CONVENTIONS.md                 # Code style + security + patterns
│       ├── SCHEMAS-INDEX.md               # Index of contracts, data models, API specs
│       └── GOTCHAS.md                     # Bug-driven rules (append-only, numbered)
└── Plans/
    └── PLAN.md                            # Active sub-plan router
```

**Detection algorithm:** To check if a project is governed:
```
IF file_exists("<project-root>/docs/context/CONTEXT-MANIFEST.md")
  → project IS governed. Read the manifest.
ELSE
  → project is NOT governed. Suggest /init-governance to the user.
```

---

## 3. Source-of-Truth Hierarchy

Rank is the **last** tiebreaker, not the first. Evidence beats rank; recency beats rank. Reach for the
table below only after both of those have failed to decide.

> **Why this order, and not "higher rank always wins" (2026-09-01).** On one governed project
> `Plans/PLAN.md` (rank 3) said an enforcement flip was "IN PROGRESS", while `MDs/Open-Problems.md`
> (rank 4) said `✅ RESOLVED 2026-08-28 — both flips LIVE + owner-verified`, with the date, the node,
> the override file and the owner's own live E2E. Rank-first gives the FALSE answer, and the old step 4
> ("update the lower-priority source to match") would then have overwritten the correct, dated,
> owner-witnessed record with the stale one — destroying the only accurate copy. PLAN.md was simply
> never updated after the flip. A stale file does not announce itself; it just keeps its old rank.

| Priority | Source | What it owns |
|---|---|---|
| 1 (highest) | Runtime code + tests | Implementation behavior |
| 2 | `version.json` (or equivalent) | Version number |
| 3 | `Plans/PLAN.md` | Active execution state |
| 4 | `docs/context/OPEN-PROBLEMS.md` | Unresolved work |
| 5 | `docs/context/HANDOFF.md` | Latest session bridge |
| 6 | `docs/context/MEMORY.md` | Durable decisions + lessons |
| 7 | `docs/context/CONVENTIONS.md` | Code style + patterns |
| 8 | `CLAUDE.md` | Orchestration rules |

**Contradiction resolution procedure:**
1. Identify the two disagreeing sources, and **read both in full at the source** — never resolve a
   contradiction from a summary, an index row, or another agent's report.
2. **Evidence first.** A claim carrying a date **and** a checkable artifact — commit SHA, tag, test
   output, a named config file, a live check the owner witnessed — beats a claim carrying none,
   **whatever the ranks are**. Go check the artifact; that is what makes it evidence.
3. **Recency second.** If both carry dates, the newer wins unless the older carries strictly stronger
   evidence. An undated status line sitting in a file whose neighbours all carry recent dates is the
   prime suspect for "nobody updated this", not the winner.
4. **Rank last.** Only when evidence and recency both fail to separate them does the priority table
   decide.
5. **Verify before you rewrite.** Confirm the winner against a primary artifact *before* editing the
   loser. Do not propagate a fact you have not checked — that is how one stale line becomes two.
6. **Stop-Report only when 2, 3 and 4 have all failed.** Escalating a question the files already
   answer wastes the owner's time and teaches the session to ask instead of read. If you are about to
   ask the owner to adjudicate between two files, you owe them one sentence saying which artifact you
   checked and why it did not settle it.

**Where rank is blind — an authority can be silent rather than wrong.** Priority 1 is "runtime code",
but a fact can live outside the repo entirely: a deployment-local `docker-compose.override.yml`, an
env var set on the node, a value in a secret store. The repo then reads as "OFF"/"absent" and rank-1
appears to speak with maximum authority while actually knowing nothing. **Absence in the repo is not
evidence of absence in production.** Before concluding a flag/feature is off, name the file that would
hold the live value and say whether you read it.

---

## 4. Session Lifecycle

Every Claude Code session follows this flow:

```
SESSION START
  │
  ├─► [Hook: pre-session] Context Governance Lite + Bootstrapper
  │     → Read CONTEXT-MANIFEST.md
  │     → Read PLAN.md
  │     → Read active HANDOFF.md
  │     → Produce briefing
  │
  ├─► USER MESSAGE
  │     ├─► [Hook: pre-task] Context Governance Lite
  │     │     → Verify no red flags
  │     │     → Load scope-specific files (Selective Context Loading)
  │     │
  │     ├─► WORK
  │     │     ├─► [Hook: pre-write] Impact-Safe Executor
  │     │     │     → Build impact map
  │     │     │     → Check scope boundaries
  │     │     │     → If HIGH risk → ask user approval
  │     │     │
  │     │     └─► [Hook: post-milestone] Live State Orchestrator
  │     │           → Update PLAN.md
  │     │           → Update MEMORY.md (if durable findings)
  │     │           → Update OPEN-PROBLEMS.md (if bug resolved/found)
  │     │
  │     └─► REPEAT for each user message
  │
  └─► SESSION END
        └─► [Hook: end-session] Live State Orchestrator
              → Write HANDOFF.md (new or update)
              → Mark previous handoff as consumed
              → Final PLAN.md milestone entry
```

---

## 5. Selective Context Loading

**Core principle:** Load relevant context, NOT all context. Token budget matters.

**Algorithm:**
1. ALWAYS read (mandatory, every session):
   - `CLAUDE.md` (project orchestration)
   - `docs/context/CONTEXT-MANIFEST.md` (meta-index)
   - `Plans/PLAN.md` (current state)
   - `docs/context/HANDOFF.md` (session bridge)
   - `docs/context/NEXT-SESSION-PROMPT.md` **if present** (the previous session's `/goal` + `/loop` prompt — it carries the goal and its Definition of Done; starting without it means not knowing what "done" means). Absent is the healthy default. Compare its mtime to `HANDOFF.md` first: older → treat as STALE, report it, do not adopt its goal. It holds pointers, not state, and loses to PLAN/HANDOFF/OPEN-PROBLEMS on any disagreement.

2. Read ONLY IF the user's goal matches (selective):
   - `docs/context/CONVENTIONS.md` → when writing/reviewing code
   - `docs/context/SCHEMAS-INDEX.md` → when touching APIs, data models, config
   - `docs/context/GOTCHAS.md` → grep by keyword, NEVER read the full file
   - `docs/context/MEMORY.md` → when making architectural decisions or debugging repeated failures
   - `docs/context/OPEN-PROBLEMS.md` → when the task relates to an existing bug

3. NEVER read blindly:
   - Do NOT read every file in `docs/context/` at session start
   - Do NOT read `GOTCHAS.md` in full (it can be >80KB)
   - Do NOT read archived files unless explicitly investigating history

---

## 6. HANDOFF Lifecycle

Every handoff file has a `status` field in its frontmatter:

| Status | Meaning | Allowed transitions |
|---|---|---|
| `active` | This is the current session bridge. Read it. | → `consumed`, → `superseded` |
| `consumed` | Content absorbed into PLAN.md / MEMORY.md | → `archived` |
| `superseded` | Replaced by a newer handoff | → `archived` |
| `archived` | Historical. Load only for context recovery | (terminal) |

**Rules:**
- Only ONE handoff may be `active` at any time
- When transitioning to `consumed`, MUST set `consumed_at` + `imported_into_plan_section`
- `docs/context/HANDOFF.md` can be either the actual content OR a pointer to a file elsewhere. Check `type: pointer` in frontmatter.
- At session end, the `end-session` hook writes a new handoff or updates the existing one.
- The paste-ready continuation prompt is a **separate file**, `docs/context/NEXT-SESSION-PROMPT.md` (§18) — not a section of the handoff, and not a second state record: it holds pointers only, carries no `status` frontmatter, and takes no part in this lifecycle. It is rewritten or deleted at every close.

---

## 7. Stop-Report Protocol

When you detect a contradiction you cannot safely resolve:

1. **STOP** — do not auto-fix, do not write code, do not update files
2. **REPORT** — describe the contradiction, the two sources, and the evidence
3. **PROPOSE** — list 2+ resolution options with risk levels
4. **WAIT** — do not proceed until the user chooses

**Triggers:**
- Two sources at the same hierarchy level disagree
- A file referenced by the manifest is missing on disk
- A `RESOLVED` marker would be claimed without external evidence
- A write would exceed the declared scope
- Multiple sub-plans are `IN_PROGRESS` simultaneously (ambiguous focus)

---

## 8. Verification Gate

Before marking ANY task as DONE or RESOLVED:

1. **Evidence is mandatory.** Acceptable forms:
   - Test runner output with PASS
   - Build/lint output (exit 0)
   - `docker logs` showing new behavior
   - HTTP probe with expected response
   - File mtime + content sample after save
   - Screenshot of working UI

2. **NOT acceptable:**
   - "Looked correct to me"
   - "Should work"
   - "Code compiles in my head"

3. **Record the evidence** in `Plans/PLAN.md` milestone log entry.

---

## 9. Skills Reference (Quick Lookup)

| Skill | Purpose | When |
|---|---|---|
| `/context-governance` | Audit context file hygiene (Lite / Full) | Session start, before task, weekly cron |
| `/context-governance full` | Deep audit (all 7 steps A-G) | On demand, weekly, red-flag escalation |
| `/bootstrapper` | Load context + produce briefing | Session start |
| `/live-state-orchestrator` | Update PLAN/MEMORY/HANDOFF after work | After milestones, at session end |
| `/impact-safe-executor` | Pre-write safety gate with impact map | Before every code edit |
| `/evidence-debugger` | Root-cause diagnosis with confidence | When investigating bugs |
| `/parallel-session-merge` | Reconcile multiple session outputs | When importing external session work |
| `/pre-close-check` | Verify no parallel session drift before close/handoff/release | MANDATORY before `/full-finish`, `/live-state-orchestrator` HANDOFF writes, `/plan-and-execute` Phase 3.3 |
| `/init-governance` | Scaffold governance structure in new project | Once per project |

Not a skill, but read alongside them: **`~/.claude/docs/NEXT-SESSION-HANDOVER.md`** — the renderer spec for a goal-scoped continuation prompt (`/goal` + `/loop` + context-limit exception). See §18.

### 9.1 Pre-Close Reality Check (2026-04-17)

Added after a two-release incident (a patch build and the release that followed it) where a session closed with a stale handoff while a parallel session had already released a new version. The root cause was trusting in-session state over filesystem reality. The `/pre-close-check` skill now runs BEFORE any canonical-state write, and verifies: (1) git activity in last 60 min, (2) handoff file mtimes, (3) version.json vs CLAUDE.md vs HANDOFF pointer agreement, (4) active handoff count = 1, (5) CONTEXT-MANIFEST sync.

Integration points:
- `/full-finish` → Phase 0 (before analyze-changes)
- `/live-state-orchestrator` → before any HANDOFF.md write
- `/plan-and-execute` → before Phase 3.3 governance state update

If the check returns `PARALLEL_SESSION_DETECTED` or `DRIFT_DETECTED`, the calling skill MUST stop and ask the user how to resolve before proceeding.

---

## 10. File Mutation Rules

| File | Who writes | When | Append-only? |
|---|---|---|---|
| `CONTEXT-MANIFEST.md` | `context-governance` Full Audit, `live-state-orchestrator` | On file add/remove, on audit | No (full rewrite OK) |
| `PLAN.md` | `live-state-orchestrator`, manual | After milestones | Milestone log: yes. Status fields: updatable. |
| `HANDOFF.md` | `end-session` hook, manual | Session end | No (replaced per session) |
| `OPEN-PROBLEMS.md` | `live-state-orchestrator`, manual | Bug found/resolved | Entries: append-only. Status: updatable. |
| `MEMORY.md` | `live-state-orchestrator`, manual | After durable decisions | Append-only. Prune to archive when >300 lines. |
| `CONVENTIONS.md` | Manual (deliberate) | When coding standards change | Append new rules. Existing rules: edit carefully. |
| `SCHEMAS-INDEX.md` | Manual, `init-governance` | When schemas change | Append new schemas. Remove deleted schemas. |
| `GOTCHAS.md` | Manual, `evidence-debugger` | After bug-driven learning | **Strictly append-only.** Never renumber. Never delete. |
| `CLAUDE.md` | Manual (deliberate) | Architecture changes | Edit carefully. Keep <500 lines. |

---

## 11. Governance Modes

### Lite Mode (~6.5K tokens, ~5s)
- Verify canonical files exist
- Check single active HANDOFF
- Version consistency check
- Red-flag scan (escalates to Full if found)

### Full Mode (~135K-165K tokens, ~60-180s)
- 7 steps A through G
- Cross-reference all links
- Content-level contradiction detection
- Risk classification (H/M/L)
- Remediation plan
- Manifest rewrite

**When to use which:**
- Lite: every session start, every task start (automatic via hooks)
- Full: weekly cron, explicit user request, Lite detected red flag

---

## 12. Dynamic Path Detection

Skills MUST NOT hardcode project paths. Instead:

```
# Step 1: Find project root
project_root = CWD (or the directory containing CLAUDE.md)

# Step 2: Check if governed
manifest = project_root + "/docs/context/CONTEXT-MANIFEST.md"
IF file_exists(manifest):
  governed = true
  Read manifest → discover all canonical file paths
ELSE:
  governed = false
  Suggest /init-governance

# Step 3: Discover files from manifest
For each canonical role (PLAN, HANDOFF, MEMORY, etc.):
  path = manifest.canonical_files[role].path
  IF path starts with "../../" → resolve relative to manifest location
  IF file_exists(resolved_path) → use it
  ELSE → log warning, continue without it
```

**The manifest is the map. The map tells you where everything is. Never assume.**

---

## 13. Inter-Skill Communication

Skills communicate through files, not through in-memory state:

| Producer | File | Consumer |
|---|---|---|
| `bootstrapper` | stdout briefing (not persisted) | Main session context |
| `impact-safe-executor` | `.executor-evidence-<ts>.log` | `live-state-orchestrator` reads it for PLAN update |
| `evidence-debugger` | stdout report (not persisted) | User + `impact-safe-executor` uses the fix path |
| `live-state-orchestrator` | `PLAN.md`, `MEMORY.md`, `HANDOFF.md` | All other skills (next invocation reads updated files) |
| `context-governance` Full | `CONTEXT-MANIFEST.md` (updated) | All skills (next invocation reads updated manifest) |
| `parallel-session-merge` | `PLAN.md`, `MEMORY.md`, new `HANDOFF.md` | Next session reads merged state |

---

## 14. Error Handling

All governance operations MUST be fail-soft:

- Hook script crashes → exit 0, log error, DO NOT block user work
- Skill cannot find a file → log warning, continue with available data
- Contradiction detected → Stop-Report (do not auto-resolve)
- Evidence collection fails → do NOT mark as DONE, ask user

**Global kill-switch:** `export GOVERNANCE_HOOKS=0` disables all governance hooks instantly without editing any file. Use in emergencies.

---

## 15. New Project Onboarding

When entering a project for the first time:

```
1. Check: does docs/context/CONTEXT-MANIFEST.md exist?
   YES → Project is governed. Read manifest. Follow lifecycle.
   NO  → Project is NOT governed.
         Ask user: "Should I initialize Context Governance? (/init-governance)"
         IF yes → run /init-governance
         IF no  → work without governance (respect project-level CLAUDE.md only)
```

---

## 16. Parallel Sessions on ONE Working Tree (2026-08-15)

The user may run two Claude Code sessions on the same project folder at once
(e.g. terminal + VS Code). They share ONE git index, ONE working tree and — today —
ONE set of governance state files (`~/.claude/logs/.gov-session-*`). Incident
2026-08-15 (Project A): session A ran `git add -u` and committed session B's
half-finished file; session B's SessionStart wiped session A's change log and
reported a false "CRASH RECOVERY".

**Detect (cheap, at session start and before any close):**
1. `.claude/scheduled_tasks.lock` in the project → is its `pid` alive?
   (`tasklist //FI "PID eq N"` on Windows, `kill -0 N` elsewhere) — also count
   running `claude` processes.
2. Newest transcript in `~/.claude/projects/<project-key>/*.jsonl` that is NOT this
   session and was modified in the last 10 minutes.
3. `git status --short`: staged (`M `/`A `) files you did not stage, or index mtime
   newer than your last git command.

**Rules when a parallel session is (or may be) alive:**
- Commit only your own paths: `git add <files>` + `git commit -- <paths>`.
  NEVER `git add -A`, `git add -u`, `git stash`, `git checkout -- .`, `git reset --hard`
  in the shared tree — they destroy or hijack the other session's uncommitted work.
- Re-read a file immediately before editing it; prefer Edit (anchored) over Write.
- Do not write HANDOFF.md / mark handoffs consumed until `/pre-close-check` says
  `clean`; if the other session is alive, run `/parallel-session-merge` first.
- Tell the user (WhatsApp/terminal) which files each session owns.
- Treat "[GOVERNANCE CRASH RECOVERY]" as *possibly* a parallel session, not a crash,
  until the PID/transcript check says otherwise.

**Framework limitation — RESOLVED 2026-08-16 (§17):** session-state files are now keyed by
session id (`~/.claude/logs/sessions/<sid>/`); a parallel session is detected from another
session dir that was active in the last 10 minutes, a crash from a dir silent for > 6 h that
still holds a change log.

---

## 17. Session-Scoped State, Dry-Run, Drift & Push Discipline (2026-08-16)

Every Claude Code hook receives JSON on stdin that includes `session_id`. The framework now
uses it (bundle v2026-08-16; `_common.sh` helpers `gov_hook_input`, `gov_session_id`,
`gov_state_dir`, `gov_state_file`, `gov_dry`, `gov_other_sessions`, `gov_prune_sessions`).

**Per-session state.** Files that describe ONE session live in
`~/.claude/logs/sessions/<session_id>/`: `.gov-session-bootstrapped`, `.gov-session-prompt-count`,
`.gov-session-changes`, `.gov-milestone-state`, `.post-milestone-last`, `.gov-qa-notified`,
`.gov-session-start`, `.gov-session-dirty`, `.gov-session-closed`. Global (shared) stay:
`governance.log`, `governance-success-token.json` (created by the model via Bash, which has no
session id), `.governance-push-pending`, `.gov-wa-*` notification markers, `.gov-crashed-session-*`
archives. When no session id is available (manual run, old Claude Code) every path falls back to
the legacy `~/.claude/logs/…` — behaviour unchanged there. `GOV_SESSION_ID=<sid>` overrides the id
(tests, manual runs). Session dirs untouched for 14 days are pruned at SessionStart.

**Crash vs parallel (pre-session.sh).** Another session dir touched in the last 10 minutes ⇒
`[GOVERNANCE PARALLEL SESSION?]` (coordination rules of §16). A dir silent for > 6 h that still
holds a change log ⇒ `[GOVERNANCE CRASH RECOVERY]`; its log is archived to
`~/.claude/logs/.gov-crashed-session-<sid>-<ts>.log` and the dir is marked closed. Secondary hints:
`.claude/scheduled_tasks.lock` naming a *different* session id whose pid is alive; the count of
running `claude` processes. Advisory only, fail-soft.

**Rules for hook authors.**
1. Read stdin ONLY through `gov_hook_input` — `_common.sh` primes the cache when sourced; a raw
   `cat`/`head -c` afterwards sees EOF (and would silently break the session id).
2. Build per-session paths with `gov_state_file NAME`; never hard-code `~/.claude/logs/.gov-*`.
3. Wrap every mutation in `gov_dry || …`. `GOV_DRY_RUN=1 bash hook.sh` must print what it would
   do and change nothing — this is how hooks are tested by hand (never run a live hook without it:
   GOTCHA "manual dry-run wiped the session log", 2026-08-15).
4. Test in a sandbox — both suites use an isolated `HOME` and fake stdin, and run it before every
   install / push:
   - `bash bundle/hooks/governance/tests/test-session-state.sh` — per-session dirs, parallel vs
     crash, dry-run, legacy path, docs sync, push flag.
   - `bash bundle/hooks/governance/tests/test-update-advisory.sh` — the §20 advisory: version
     validation and the injection payload, the advisory decisions, the unversioned path, the
     non-blocking fetch (via a sleeping `curl` stub), FROZEN silence, hook-lineage skew, the
     installer's refusal-to-stamp paths, and the temp sweep.
   Assertion counts are deliberately not quoted here — a number in prose goes stale silently and
   the suites print their own totals.

**Drift advisory.** pre-session.sh compares the live `~/.claude/hooks/governance/*.sh` with the
installer bundle (`~/.claude/governance-installer/bundle/hooks/governance/`) and prints
`[GOVERNANCE DRIFT] …` when they differ. The bundle mirrors the GitHub repo
(`Gold-b/claude-code-governance`), so a drift line means "someone edited live hooks (or an old
copy was restored) without going through the sync". Reconcile before editing hooks.

**Sync & push discipline.** `sync-governance-copies.sh` (PostToolUse) mirrors an edited live hook
or skill to the two project mirrors and the installer bundle, and now also mirrors
`~/.claude/docs/*.md` into the bundle; it queues the path in `.governance-push-pending`.
`end-session.sh` (Stop) syncs bundle → repo working tree, runs `git pull --rebase --autostash`
first (aborts and keeps the flag on conflict), stages ONLY the files named in the flag (mapped
into `bundle/…`) plus `install.sh`/`verify.sh` if changed, commits, pushes; the flag survives a
failed push. Never `git add bundle/` wholesale.

**The Stop hook can empty your index between `git add` and `git commit`.** Its
`git pull --rebase --autostash` stashes uncommitted work — staged included — and the pop restores
it to the WORKING TREE only, silently un-staging it. A commit issued after that quietly contains
fewer files than you staged, and `git status` afterwards looks like an ordinary dirty tree, so
nothing announces the loss. It happened on PR #4: six files staged, three committed, and only the
reviewer's "this is still unresolved" caught it. **`git add` and `git commit` in ONE shell
invocation, then confirm with `git show --stat <sha>` that every intended file is listed.** Never
treat "I staged it" as evidence it shipped.

**Edit `install.sh` / `verify.sh` in the installer, never in the repo checkout.** The same
bundle→repo sync also does `cp $HOME/.claude/governance-installer/install.sh $GH_REPO/install.sh`
(and the same for `verify.sh`). The repo copies are DERIVED: an edit made directly in
the repo checkout (`$GOV_REPO_PATH`) is silently reverted the next time the Stop hook runs, while
`README.md` — which is not copied — survives, so the loss looks selective and is easy to miss.
Primary location for those two files is `~/.claude/governance-installer/`.

**Rolling out to clients (other machines / projects).** Pull the repo, run
`bash install.sh --force` (backs up first), then `bash bundle/hooks/governance/tests/test-session-state.sh` and `bash bundle/hooks/governance/tests/test-update-advisory.sh`
and `bash verify.sh`. Existing sessions keep working: their state simply starts a new per-session
dir on the next hook call.

---

## 18. Goal-Scoped Autonomous Continuation (2026-08-25)

Some sessions are scoped by a **goal** rather than a task: the user declares an outcome plus a
Definition of Done, and expects the agent to keep working through implement → test → review →
merge → deploy → verify without returning for status reports. Two directives express this:

- `/goal` — the outcome, the scope list, and the Definition of Done.
- `/loop` — do not return control until that Definition of Done is satisfied.

**The full renderer spec, all three templates, and the placeholder table live in
`~/.claude/docs/NEXT-SESSION-HANDOVER.md`.** Do not restate them here or inside any skill; read
that file when you need to produce or interpret a continuation prompt.

### 18.1 What the guide adds on top of the spec

1. **`/loop` never overrides a governance stop.** §7 (Stop-Report), §8 (Verification Gate),
   Human-in-the-Loop confirmation, the node-role guard, the file-collision guard, the
   `/full-finish` permission requirement and the one-active-HANDOFF invariant all still fire
   inside a loop. Most of them are **waits, not exits**: Stop-Report waits for the user's choice,
   Human-in-the-Loop waits for a yes. Answer arrives and work can continue → resume the loop and
   render nothing. Only when the answer cannot be had in this session does the stop become a
   **legitimate loop exit** — record it under *Blockers* and close. Collapsing "the gate refused"
   into "the session is over" hands over a handoff describing a state that stopped being true the
   moment the user answered. `NEXT-SESSION-HANDOVER.md` §4 is the full table.
2. **A Definition of Done is a list of Verification Gates.** Every bullet needs external
   evidence per §8. "Deployed" without a probe against the deployed thing is not deployed. Render
   the goal's **recorded** criteria verbatim; the stock list in `NEXT-SESSION-HANDOVER.md` §2 is a
   default for goals that never stated one, never a replacement for one the user did state.
3. **The continuation prompt is a rendering, never a record.** It lives in its own file,
   `docs/context/NEXT-SESSION-PROMPT.md`, but canonical state stays in `HANDOFF.md` / `PLAN.md` /
   `OPEN-PROBLEMS.md`; the prompt carries goal + pointers + next action. Writing state twice is
   the drift this framework exists to prevent — and a separate file makes that easy, so it is
   **rewritten from scratch or deleted at every close, never appended to**. A prompt older than
   the handoff beside it is worse than no prompt, because it reads as current.
4. **Order is fixed:** `/pre-close-check` → `/live-state-orchestrator` (canonical files) →
   render the prompt. Rendering before the files are written produces a prompt that describes a
   state that was never persisted. In a pipeline, "last" means *actually* last: the decision goes
   after the final blocking gate, not after the last interesting phase.
5. **Rendering may be chat-only.** Persisting is the default, but never at the price of breaking a
   close invariant that has already been satisfied — see `NEXT-SESSION-HANDOVER.md` §0 and
   `/full-finish` Phase 9.1.
6. **Not every session ends with one.** A goal that is complete and verified closes with
   `/full-finish` output and the handoff; no continuation prompt is rendered
   (`NEXT-SESSION-HANDOVER.md` §1).

### 18.2 Where it is wired

| Component | Behaviour |
|---|---|
| `/live-state-orchestrator` | Step 6.1 — the ONLY renderer, in two modes: `persist` (rewrite `docs/context/NEXT-SESSION-PROMPT.md`, the default; delete it when no prompt is due) and `render-only` (identical text, no write and no delete). Runs ONLY when the session is actually ending — it also runs after ordinary milestones, where rendering would be exactly the mid-session status stop `/loop` suppresses |
| `/full-finish` | PART D (Phase 3) and Phase 7 both render NOTHING — Phase 3 runs before the release exists, Phase 7 runs before Phase 8 can dirty the tree and before Phase 9 can refuse the close. **Phase 9.1** decides on the Phase 9 verdict: PASS + goal met → nothing; BLOCK while the user is still choosing a recovery → nothing yet (a BLOCK is not automatically a session end); BLOCK + the session actually ends → `persist`; PASS + goal open → `render-only`, chat only, because `NEXT-SESSION-PROMPT.md` is tracked and writing it after the tag would dirty a tree that just passed the hermetic close. After the tag it also never DELETES a stale prompt — same reason — it reports one instead |
| `/plan-and-execute` | Phase 3.3 item 10 — same rule via the orchestrator |
| `/bootstrapper` | Reads the file at session start if present, after checking its mtime against `HANDOFF.md`. Without this the goal and its Definition of Done are invisible to the next session, which is the whole point of writing them down |
| `/context-governance` Lite | Flags the file when its mtime predates `HANDOFF.md`; checks manifest-row existence for `ACTIVE` rows only, so a deleted prompt with an `ARCHIVED` row is not a red flag |
| `end-session.sh` (Stop hook) | Unchanged, and it does NOT enforce the prompt — it only enforces that a handoff exists. The prompt is a separate file with no lifecycle; the orchestrator owns it |

---

## 19. Public-Repository Hygiene (2026-08-18)

**`Gold-b/claude-code-governance` is a PUBLIC repository.** The framework belongs to no project,
which is exactly why notes about it land here — and exactly why a note written *about a session*
instead of *about the framework* leaks the session's project into public view. That happened once:
an incident note carried a private project's name (in the filename and throughout the body),
absolute local paths including the machine's user directory, session UUIDs, and commit hashes from
a private repository. Every technical finding in it was worth keeping; none of the identifying
detail was.

Three earlier references pointed at this section before it existed
(`sync-governance-copies.sh`, `README.md`, and the sanitised note itself). This is it.

### 19.1 The rule

**Write about the FRAMEWORK, never about the SESSION.** If a sentence needs a project name, a
client, a host or a path under `C:\Users\…` to make sense, it is a session note and does not
belong here — or it belongs here rewritten. Use `Project A` / `Project B`, `Session 1` / `Session
2`, and `~/.claude/…` paths. The 2026-08-15 note in `PARALLEL-SESSION-NOTES/` is the worked
example: rewritten generically, every finding intact.

### 19.2 Never commit

- Private project or client names — including in **filenames**
- Absolute local paths (`C:\Users\<name>\…`, `/home/<name>/…`, mapped drives, cloud-sync mounts)
- Session UUIDs, transcript paths, machine names, internal hostnames
- IPs of private infrastructure
- Commit SHAs, PR numbers or branch names from **private** repositories
- Anything that is or ever was a credential — tokens, passwords, keys, webhook secrets

Machine-local configuration that names private checkouts (`~/.claude/.governance-mirrors`) is
never shipped in the bundle. Hardcoding those paths in a hook is the same leak wearing a
config's clothes; that is why mirror roots became configuration (§17).

### 19.3 Leak grep (advisory — review every hit by hand)

**Pick the range that matches when you are running it.** `--cached` is the *staged* diff: it is
empty once you have committed, so running it at pre-push time returns a clean sheet for a leak
that is already in the commit you are about to push. That silent all-clear is worse than not
running it.

```bash
# Choose ONE range:
RANGE_ARGS="--cached"                 # before committing  (staged changes)
RANGE_ARGS="@{upstream}..HEAD"        # before pushing     (commits not yet on the remote)
RANGE_ARGS="origin/master...HEAD"     # reviewing a branch (everything the PR adds)

git diff $RANGE_ARGS --name-only -z | xargs -0 grep -nEI \
  -e '[A-Za-z]:[\\/]+Users[\\/]+[^ "]+' \
  -e '/home/[a-z][a-z0-9_-]*/' \
  -e '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
  -e '([0-9]{1,3}\.){3}[0-9]{1,3}' \
  -e '(ghp_|github_pat_|gho_|sk-|AKIA)[A-Za-z0-9_]{10,}' \
  2>/dev/null

# Your own private project names are in your machine-local mirrors file — grep for them too.
sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' ~/.claude/.governance-mirrors 2>/dev/null \
  | xargs -n1 basename 2>/dev/null \
  | while read -r n; do [ -n "$n" ] && git diff $RANGE_ARGS -G"$n" --name-only; done
```

Sanity-check the check itself before trusting it: plant a known string, confirm the grep prints
it, then remove it. A leak grep you have never seen fire is a leak grep you do not know works.

It is a net, not a proof. It will not catch a client's name you never wrote in a path, and it
flags harmless version-like strings. Read the hits.

### 19.4 A rewrite does not remove history

Sanitising a file changes the tip, not the past, and this repository is **public**. Treat anything
already pushed as **disclosed**: rotate any credential that appeared, and do not assume a
force-push, a rename or a rewrite un-published it. The only reliable move after a leak is
rotation.

---

## 20. Framework Versioning & Update Advisory (2026-08-25)

Until this section existed the framework had **no version number at all**. There was no way for a
machine to learn that a release had happened: every install was "whatever was in the clone the day
someone ran `install.sh`", and a fixed bug could sit unshipped on a machine indefinitely with
nothing anywhere reporting it.

### 20.1 The version

`bundle/VERSION` — one semver line, the single source. `install.sh` reads it (never hardcode a
version in the installer again) and stamps `~/.claude/.governance-version` as its **last** step.
That marker answers "what is installed on THIS machine"; `bundle/VERSION` on `master` answers
"what is published".

**The marker is a claim, so it is only written when the claim is true.** Three outcomes, and the
difference between the last two matters:

| Outcome | What happens to the marker |
|---|---|
| Every step succeeded | Stamped with the bundle's version |
| A step failed | **Untouched.** The failing step may have nothing to do with the files on disk — a `settings.json` merge failure on a machine whose settings are already correct is a no-op — and deleting a valid marker turns a fully working machine into one that reports "no usable version marker" every session, forever. The old value is the honest record: the run did not complete, so the machine is still whatever it was. |
| The bundle carried no `VERSION` | **Removed, after being backed up** to `~/.claude/backups/governance-<timestamp>/`. This is the one destructive path, and it is destructive on purpose: the run *did* overwrite hooks, skills and docs with content of unknown provenance, so a marker from an earlier install now describes files that are gone. Nothing here deletes a record without keeping a copy. |

The literal `unknown` is never written: the reader rejects it as not-a-version and advises
"re-run install.sh", which would write `unknown` again — a loop with no exit but the kill switch.
Any run that did not fully succeed exits non-zero and does not say "ready".

Bump it in the same commit as the change it describes. A version that lags its content is worse
than no version, because the advisory then reports "up to date" while the machine is not.

### 20.2 The advisory

`pre-session.sh` compares the two and prints `[GOVERNANCE UPDATE]` when the published version is
newer, or when the machine has no usable marker at all — that second path exists because gating on
the marker would have excluded exactly the machines the advisory is for: the ones running a copy
old enough to predate versioning. Six properties, each deliberate:

- **It never blocks, and its cost is a measured number, not a claim.** The network call is fully
  detached and only refreshes a cache; what a session prints is the result of a *previous* run.
  **Measured on Windows/MSYS2: +77 ms and +106 ms in two interleaved A/B runs, n=12 each** (medians,
  advisory on vs `GOVERNANCE_UPDATE_CHECK=0`). On Linux/macOS forks are ~3× cheaper, so expect
  under 40 ms.

  It first shipped at **+494 ms** — about ten forks: two role lookups, two command-substitution
  file reads, a `date`, a `gov_mtime`, a `sort -V` probe. Everything that can be a bash builtin is
  now one (`read`, `printf -v`, parameter substitution, a builtin version compare), and the role is
  looked up once via `gov_detect_role_var`. **Do not reintroduce a `$( )` in that block without an
  interleaved A/B first.** The original cost was missed because it was measured as a single
  before/after pair and the 200 ms signal was written off as noise; at this scale only paired,
  interleaved sampling separates the two. A hook that slows every session start is a hook people
  disable, and a disabled hook protects nothing.
- **It never installs.** `install.sh` replaces the very hooks and skills that are executing at
  that moment. Swapping them under a live session is a real hazard, so the update is always a
  deliberate operator action: `git pull` in a clone, then `bash install.sh --force`.
- **It only advises upgrades.** A local version *ahead* of the published one is a dev machine
  mid-release, not a machine that is behind.
- **It validates on read, not only on write.** The cache is shape-checked when it is read back —
  a file can be hand-edited, truncated by a full disk, or hold an error page from a proxy.
  Trusting its contents because *we* wrote it is the same mistake as trusting a config because it
  parsed.

- **It says nothing when it cannot know.** Its two helpers live in `_common.sh`, and hook files are
  mirrored individually — so this file can legitimately sit beside an older `_common.sh` that has
  neither. Bash then reports `command not found`, the call returns 127, and 127 is
  indistinguishable from "rejected": that printed two error lines and a false "no version marker"
  advisory on a machine that was exactly up to date. Both helpers are now checked with
  `command -v` first, and their absence means silence, not a guess.
- **It fails closed on a broken comparison.** No `sort -V` means no way to tell an upgrade from a
  downgrade, so it stays silent rather than advising. A false "update available" trains people to
  ignore the line, which costs more than the missed advisory.

Offline is a first-class case: a failed fetch touches the cache without overwriting it, so the
machine backs off a full TTL (12h) instead of retrying on every session start. The fetch writes to
a per-process temp file and `mv -f`s it into place, so two sessions starting at once cannot let a
reader see a half-written value; temps orphaned by a killed session are swept after an hour.

**Kill switch:** `GOVERNANCE_UPDATE_CHECK=0` silences the advisory and skips the fetch.
`GOVERNANCE_HOOKS=0` still disables everything.

### 20.3 Rolling out to other machines

There is no automatic install, by design (see above). On each machine: `git pull` the clone, run
`bash install.sh --force` (it backs up first), then `bash verify.sh` and
`bash bundle/hooks/governance/tests/test-session-state.sh` and `bash bundle/hooks/governance/tests/test-update-advisory.sh`. Existing sessions keep working.

---

**End of Agent Guide. Follow these rules in every session, on every project.**
