---
name: full-finish
description: Universal post-task pipeline — multi-agent orchestrated audit, session handoff, docs, commit, build, release, deploy
user-invocable: true
---

# /full-finish — Multi-Agent Release Pipeline

You are the **Team Lead Orchestrator**. Your job is to execute a complete release pipeline by coordinating specialized agents that work in parallel. You analyze, dispatch, coordinate, and synthesize — agents do the deep work.

This skill includes **session handoff** — producing a self-contained handoff document so a new session can pick up with zero context loss.

**Language**: Communicate with the user in their preferred language (detect from CLAUDE.md or conversation). All code, comments, and technical artifacts in **English**.

**Execute ALL phases in order. Do NOT skip any phase. Adapt to the ACTUAL changes made.**

---

## Phase 0 — Dynamic Project Discovery (Orchestrator)

Before any work, discover the project context:

1. **Read project CLAUDE.md** — understand architecture, conventions, deployment topology, gotchas
2. **Read `docs/context/CONTEXT-MANIFEST.md`** — if governed, get the full context map
3. **Detect project type**: Docker-based? Node.js? Python? Monorepo? Determine build/deploy commands
4. **Detect source/client topology**: Does the project have separate source/client directories? Read from CLAUDE.md
5. **Detect deployment targets**: Local? Remote servers? CI/CD? Cloud? Read from CLAUDE.md

Store this discovery as `PROJECT_CONTEXT` — pass it to every agent prompt.

---

## Phase 1 — Analyze Changes (Orchestrator)

Quick analysis — no agents needed:

1. `git status` (never `-uall`) — modified, staged, untracked files
2. `git diff --stat` — change summary
3. `git diff` + `git diff --cached` — understand what changed
4. Categorize: **Backend**, **Frontend**, **Infrastructure**, **Config**, **Docs-only**
5. Build the **file list** and **change summary** for agent prompts
6. Determine **agent team composition**:

| Change Scope | Team |
|---|---|
| Docs only (no code) | Skip Phase 2 → jump to Phase 3 |
| 1-3 backend files | 3 agents: QA + Security + Integration |
| Backend + Frontend | 4 agents: QA + Security + Integration + PM |
| Major feature (5+ files) | 4 agents: QA + Security + Integration + PM |

---

## Phase 2 — QA & Security Audit (Parallel Agents)

**If only docs changed, state "No code changes — QA&SEC skipped" and jump to Phase 3.**

Dispatch agents **in parallel** using the `/qa-sec` skill methodology:

- **QA Engineer** (`model: opus`) — Code audit, server/client testing, performance, Docker
- **Security Engineer** (`model: opus`) — LLM threats, OWASP, infrastructure
- **Integration Tester** (`model: sonnet`) — Health checks, API smoke tests, container status
- **PM** (`model: sonnet`, only for complex changes) — Merge reports, prioritize, validate

**Each agent prompt MUST include:**
1. The exact file list from Phase 1
2. The `PROJECT_CONTEXT` from Phase 0
3. Pre-flight: "Read the project's CLAUDE.md FIRST"

After agents complete:
1. Merge reports, deduplicate (keep higher severity)
2. Verify CRITICAL/HIGH issues were fixed by agents
3. If unfixed blockers remain: inform user, wait before proceeding

---

## Phase 3 — Documentation & Session Handoff (Parallel Agents)

Dispatch **2 agents in parallel**:

### 3.1 Documentation & Handoff Agent (`model: sonnet`)

This agent is the **sole owner** of ALL documentation tasks:

```
You are the Documentation & Handoff Agent. You own ALL documentation across the pipeline.

## Pre-Flight (MANDATORY)
1. Run `date` to capture timestamp for all entries.
2. Read the project's CLAUDE.md for documentation structure.

## PART A — Session Forensics
- git status, git diff --stat, git stash list, git log --oneline -10, git branch
- docker ps (if applicable)
- Flag uncommitted changes as CRITICAL open items

## PART B — Update Project Documentation
Read each file BEFORE editing. Surgical edits only.
- CLAUDE.md — version, new features/files/gotchas
- Open-Problems or issue tracker — mark resolved, add new
- README.md — user-facing changes
- Memory files — save project/feedback/reference memories to ~/.claude/projects/<project>/memory/

## PART C — Session Handoff Document
Generate a self-contained handoff:

  # Session Handoff — [DATE]
  ## TL;DR (2-3 sentences)
  ## Completed Work (bulleted, with file references)
  ## Open Issues (P0 Blocking / P1 High / P2 Low)
  ## Key Decisions
  ## Warnings for Next Session
  ## Files Changed
  ## Git State (branch, uncommitted, last commit)
  ## Suggested First Action for Next Session

## Constraints
- Read BEFORE edit. Never guess file contents.
- User's language for prose, English for code/paths.
```

### 3.2 DevOps Agent (`model: sonnet`)

```
You are the DevOps Agent. Verify infrastructure is in sync with code changes.

## Pre-Flight
Read the project's CLAUDE.md (deployment, infrastructure, installer sections).

## Tasks (adapt to what exists in this project)
- Installer files: verify new files are included
- Cross-platform parity: Windows + Linux (if applicable)
- Docker Compose: new volumes, ports, env vars, entrypoint changes
- CI/CD: pipeline config changes (if applicable)
- Version file sync: all version references match

## Deliverables
- Infrastructure status: in-sync / gaps identified
- Platform parity: confirmed or gaps
- Installer: files verified / unchanged

## Constraints
- Check CLAUDE.md for project-specific infrastructure patterns
- If no installers exist: "No installers — skipped"
```

### 3.5 Verify Documentation Output (Orchestrator — MANDATORY)

1. Verify Open-Problems/issues were updated
2. Verify memory files were saved
3. Verify handoff document was generated
4. If anything missing: instruct Documentation Agent to complete

---

## Phase 4 — Version Bump + Git Commit + Push (Orchestrator)

### 4.1 Version Bump

**Detect version file** — common patterns: `version.json`, `package.json`, `pyproject.toml`, `Cargo.toml`, `VERSION`

1. Read version file — increment patch (or as appropriate)
2. Update any secondary version references (installers, CLAUDE.md, etc.)
3. Verify all version references are in sync

### 4.2 Git Commit + Push

1. `git status` — confirm changes ready
2. `git log --oneline -5` — match commit message style
3. Stage relevant files (NOT secrets: `.env`, `*.enc`, `*.key`)
4. Commit with descriptive message + Co-Authored-By
5. Push. If rejected (remote has new commits), ask user before force-push

---

## Phase 5 — Build & Release (Orchestrator)

**Adapt to project type** (read from CLAUDE.md / package.json / Makefile):

- **Node.js**: `npm run build` or equivalent
- **Docker**: `docker compose build`
- **Compiled**: run build tool (Inno Setup, cargo build, go build, etc.)
- **GitHub Release**: `gh release create v<VERSION>` with artifacts
- **No build needed**: skip and state "No build step configured"

**CRITICAL:** Release tags MUST be clean semver (`v1.2.3`). No suffixes.

---

## Phase 6 — Deploy to Clients (Orchestrator)

**Read deployment targets from CLAUDE.md.** Common patterns:

- Local client → remind user to update
- Remote servers → SSH deploy or push-update mechanism
- CI/CD → trigger pipeline
- Frozen/locked deployments → explicitly skip with warning

**Never deploy to frozen/locked targets.** Check CLAUDE.md for deployment restrictions.

---

## Phase 7 — Final Report + Session Handoff (Orchestrator)

### 7.1 Release Report (in user's language)

```
## Full-Finish Report — v[VERSION]

### Summary
- Files audited: X
- Agents dispatched: Y
- Issues found: Z (W fixed)
- Status: ✓ Clean / ⚠ Warnings / ✗ Blocked

### QA — [PASS/FAIL/WARN summary per layer]
### Security — [severity summary per layer]
### Integration — [PASS/FAIL/SKIP per test]
### Documentation — files updated, handoff generated
### DevOps — infrastructure status

### Version & Release
- Version: v[VERSION]
- Commit: [HASH]
- Release: [URL or N/A]

### Open Issues
- [anything unfixed]
```

### 7.2 Display Handoff Document (MANDATORY)

Read the handoff from the Documentation Agent and **display it in full** to the user.

---

## Phase 8 — Memory & Knowledge Maintenance (MANDATORY — Final Phase)

1. **MEMORY.md index** — verify under 200 lines, remove stale entries
2. **Memory files** — no duplicates with existing memories or CLAUDE.md
3. **Completed projects** — archive finished work
4. **Open-Problems** — mark resolved, add new
5. **Plans/** — archive fully-implemented plans
6. **Stale references** — verify paths in documentation still exist

---

## Orchestration Summary

```
Phase 0: Discover project context                            [sequential]
Phase 1: Analyze changes                                     [sequential]
Phase 2: QA + Security + Integration + PM agents             [parallel]
  → Merge results, fix CRITICAL/HIGH                         [sequential]
Phase 3: Documentation + DevOps agents                       [parallel]
  → Verify docs completeness                                 [sequential]
Phase 4: Version bump, commit, push                          [sequential]
Phase 5: Build artifacts, create release                     [sequential]
Phase 6: Deploy to clients                                   [sequential]
Phase 7: Final report + display handoff                      [sequential]
Phase 8: Memory & knowledge maintenance                      [sequential]
```

---

## Important Notes

- **NEVER skip phases.** If nothing to do, state that and move on.
- **NEVER create empty commits.**
- **NEVER force-push without user approval.**
- **Read files before editing.** Do NOT guess contents.
- **Dynamic discovery**: All paths, ports, containers, servers come from reading CLAUDE.md — nothing hardcoded.
- **Phase 2 agents are MANDATORY** on every non-trivial code change.
- **Agents fix issues**: CRITICAL/HIGH fixed in source, not just reported.
- **Decision gate**: If blockers found, stop and inform user.
