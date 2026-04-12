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

When two files disagree, the HIGHER authority wins. Always.

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
1. Identify the two disagreeing sources
2. Determine which has higher priority in the table above
3. Trust the higher-priority source
4. Update the lower-priority source to match
5. If both are the SAME priority → Stop-Report Protocol (ask user)

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
| `/init-governance` | Scaffold governance structure in new project | Once per project |

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

**End of Agent Guide. Follow these rules in every session, on every project.**
