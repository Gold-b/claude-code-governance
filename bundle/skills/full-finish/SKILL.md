---
name: full-finish
description: Universal post-task pipeline — multi-agent orchestrated audit, session handoff, docs, commit, build, release, deploy
---

# Full-Finish — Multi-Agent Release Pipeline

You are the **Team Lead Orchestrator**. Your job is to execute a complete release pipeline by coordinating specialized agents that work in parallel. You analyze, dispatch, coordinate, and synthesize — agents do the deep work.

This skill includes **session handoff** (formerly `/end-session`) — producing a self-contained handoff document so a new session can pick up with zero context loss.

**Language**: Communicate with the user in **Hebrew**. All code, comments, and technical artifacts in **English**.

**Execute ALL phases in order. Do NOT skip any phase. Adapt to the ACTUAL changes made.**

---

## Phase 0 — Pre-Close Reality Check (MANDATORY, FIRST)

**BEFORE Phase 1, you MUST invoke `/pre-close-check`.** This catches parallel session activity that would cause you to commit stale/partial state.

Trigger: Call the `pre-close-check` skill. Read its output.

**Stop conditions:**
- If verdict is `PARALLEL_SESSION_DETECTED` → STOP, report to user, ask whether to run `/parallel-session-merge` first.
- If verdict is `DRIFT_DETECTED` → STOP, show the drift (version mismatch / multiple active handoffs / stale manifest), ask user how to resolve.
- If verdict is `clean` → proceed to Phase 1.

**Do NOT skip this phase.** The 2026-04-17 v1.4.112-b/v1.4.113 incident happened because the prior session trusted in-memory state over filesystem reality.

**Documentation Agent ownership**: A single **Documentation & Handoff Agent** (`model: sonnet`) is responsible for ALL documentation tasks across the entire pipeline — session forensics, handoff document, MD updates, memory extraction, and public docs. This agent is dispatched in Phase 3 and handles everything that was previously split between end-session and the docs agent.

---

## Phase 1 — Analyze Changes (Orchestrator)

You perform this phase directly (no agents needed — quick analysis):

1. Run `git status` (never use `-uall`) to see all modified, staged, and untracked files.
2. Run `git diff --stat` to see a summary of changes.
3. Run `git diff` (unstaged) and `git diff --cached` (staged) to understand what was changed.
4. Categorize the changes:
   - **Backend** (admin/server.js, admin/lib/*.js, admin/routes/*.js)
   - **Frontend** (admin/public/*.html, admin/public/*.js, admin/public/*.css, flow-builder/*.js)
   - **Gateway patches** (patches/*.js)
   - **Infrastructure** (docker-compose.yml, Dockerfile, installer/*, *.bat, *.ps1, *.sh)
   - **Watchdog** (watchdog/*.js, watchdog-remote/*.js)
   - **Documentation** (CLAUDE.md, MDs/*.md, README.md)
5. Build the **file list** and **change summary** for agent prompts.
6. Determine the **agent team composition** for Phase 2:

| Change Scope | Team |
|---|---|
| Docs only (no code) | Skip Phase 2 → jump to Phase 4 |
| 1-3 backend files | 3 agents: QA + Security + Integration |
| Backend + Frontend | 4 agents: QA + Security + Integration + PM |
| Backend + Infra + Patches | 4 agents: QA + Security + Integration + PM |
| Major feature (5+ files) | 4 agents: QA + Security + Integration + PM |

---

## Phase 2 — QA & Security Audit (Parallel Agents)

**If only docs changed, state "No code changes — QA&SEC skipped" and jump to Phase 4.**

### 2.1 Dispatch Agents

Launch agents **in parallel** (single message, multiple Agent tool calls):

- **QA Engineer** (`model: opus`) — Code audit + server/client testing + performance + Docker
- **Security Engineer** (`model: opus`) — LLM threats + OWASP + infrastructure
- **Live Integration Tester** (`model: sonnet`) — Health checks + API smoke + remote verification
- **Project Manager** (`model: sonnet`, only if 4+ agents or complex changes) — Coordinates results, prioritizes, validates

**Each agent prompt MUST include:**
1. The exact file list from Phase 1
2. Pre-flight: "Read `C:\openclaw-docker\CLAUDE.md` FIRST"
3. Source repo: `C:\openclaw-docker\`
4. Clear deliverables format

### 2.2 QA Engineer Agent

```
You are the QA Engineer. Audit ALL changed files for correctness, integration, and performance.

## Pre-Flight (MANDATORY)
Read C:\openclaw-docker\CLAUDE.md first. Then read EVERY changed file in full.

## Changed Files
[EXACT FILE LIST FROM PHASE 1]

## Layer A — Code Audit (every changed file)
- Correctness: logic errors, off-by-one, null/undefined checks, async/await (missing await, unhandled rejections), memory leaks (listeners without cleanup, growing Maps/Sets), incorrect return values
- Encoding: UTF-8 BOM (PS Set-Content writes BOM — use [System.IO.File]::WriteAllText), CRLF/LF consistency, JSON validity
- Shell/PS: ERRORLEVEL reset, expansion timing, PS 5.1 compat (Join-Path 2 args, ASCII-only in ISS)
- Cross-File: shared schemas match, shared paths resolve, env var naming matches, execution order valid, error propagation handled, platform parity (Windows + Linux)
- Conventions: thinkingBudget: 0 on ALL LLM calls, ...result.usage spread, _autoSync() on every CRUD, _syncAgentSettingsToV5() before save(), sanitizeErrorMessage(), credential masking (••••••••), Hebrew ~4 tokens/char

## Layer B — Server-Side Tests
- API endpoints: valid inputs → expected response, invalid → 400 (not 500), missing auth → 401/503
- Zod schema validation, _autoSync() propagation, error sanitization (no stack traces/secrets)
- Rate limiting, Admin↔Gateway integration, edge cases (empty, Unicode, Hebrew, max-length, concurrent)
- JID format (@s.whatsapp.net / @g.us)

## Layer C — Client-Side Tests (if frontend changed)
- RTL layout, form validation, modal/tab lifecycle, Hebrew text, event handlers, error states, console errors

## Layer D — Performance
- N+1 patterns, sync I/O in async paths, unbounded data structures, token cost, Hebrew token ratio, WhatsApp rate limits (3 msg/60s), timeout handling

## Layer E — Docker Build (if backend/infra changed)
- docker compose build goldb-admin, verify starts + healthy, check logs

## Layer F — Direct Tests (unit + integration)
- Look for test files: `tests/`, `__tests__/`, `*.test.js`, `*.spec.js`
- If test runner exists (`npm test`, `node tests/run.js`, etc.) — run it and report pass/fail/error counts
- If no automated suite — state "No test suite found" (not a failure), then manually verify each changed function/endpoint with direct `node -e` or `curl` calls
- Any test failure = FAIL with full stack trace

## Layer G — E2E Tests (end-to-end flows)
- Test the full user-facing pipeline for every feature touched in this session:
  - Lead ingestion → rule match → WhatsApp delivery → delivery confirmed in logs
  - KB query (via POST /api/knowledgebase/query or God Mode) → chunk retrieval → coherent LLM response
  - Admin CRUD (add/edit/delete) → _autoSync() fires → openclaw.json + rules.json updated
  - Multi-channel message → channel adapter → correct routing
- Verify no "500 Internal Server Error" or unhandled promise rejections appear in docker logs during tests
- Use Bearer token from ~/.openclaw/openclaw.json gateway.auth.password

## Layer H — Flow Tests (Flow Builder)
- For any flow-related code changes (flow-executor.js, workflow-engine.js, routes/flows.js, automation-utils.js):
  - Trigger a real flow via POST /api/flows/:id/trigger → verify each node executes in correct order (check logs)
  - Test _resolveVariable with dot-path on both triggerData AND context.variables
  - Test condition evaluation (equals, contains, regex)
  - Test notification dedup (context._notifSentKeys prevents double-send in loop_list)
  - Test error node: verify flow halts gracefully on invalid input, no crash
- If no flows exist in system: create a minimal test flow (condition + send_message nodes), run, delete
- Report: nodes executed, any failures, any unhandled exceptions

## Deliverables
PASS / FAIL (severity + fix) / WARN / FIXED (before→after) report.
Fix CRITICAL/HIGH immediately in source files.

## Constraints
- Source: C:\openclaw-docker\. Client (docker): C:\GoldB-Agent\
- Do NOT skip files. Thoroughness over speed.
```

### 2.3 Security Engineer Agent

```
You are the Security Engineer. Perform mandatory security review on ALL changed files.

## Pre-Flight (MANDATORY)
Read C:\openclaw-docker\CLAUDE.md (Security section) + admin/lib/security-utils.js + every changed file.

## Changed Files
[EXACT FILE LIST FROM PHASE 1]

## Layer 1 — Prompt Injection & LLM Threats
- Direct injection: user→system prompt override
- Indirect injection: documents/webhooks/emails/KB chunks embedding instructions
- Prompt leaking: L0/L3 sandwich defense intact?
- Tool abuse: LLM tricked into send email/message/read secrets. All tool args validated?
- Context poisoning: conversation memory/history manipulation
- Output weaponization: XSS/command injection via LLM output
- Token exhaustion: MAX_TOOL_ROUNDS enforced, thinkingBudget: 0
- [NO_REPLY] bypass

## Layer 2 — OWASP Top 10
- A01 Broken Access Control: missing auth, path traversal (../ ..\\  %2e%2e), CORS
- A02 Cryptographic Failures: weak algos, rejectUnauthorized:false without cert pinning (Gotcha #29)
- A03 Injection: SQL/command/template/header/shell
- A05 Security Misconfiguration: defaults, debug, containers as root, 0.0.0.0
- A06 Vulnerable Components: CVEs, latest tags, prototype pollution (_.merge + user input)
- A07 Auth Failures: hardcoded secrets, === vs timingSafeEqual
- XSS: innerHTML, eval(), Function(), setTimeout(string)
- Sensitive Data Exposure: secrets in logs/git/Docker layers
- Webhook/API: HMAC validation, rate limiting, Content-Type, SSRF private IP blocking

## Layer 3 — Infrastructure
- Container: cap_drop:ALL (admin only, NOT gateway — breaks DNS), USER directive, resource limits
- SSRF defense, path traversal defense
- Secrets: DPAPI/AES at rest, .gitignore covers .env* *.enc *.key *.pem
- Network: 127.0.0.1 binding, unnecessary ports

## Deliverables
CRITICAL / HIGH / MEDIUM / LOW / CLEAN report with exact attack vectors.
Fix CRITICAL/HIGH immediately in source files.

## Constraints
- Source: C:\openclaw-docker\
- Check KB 4-layer prompt (L0-L3) for new injection surfaces
- Verify security-utils.js covers new code paths
```

### 2.4 Live Integration Tester Agent

```
You are the Live Integration Tester. Verify the deployed system works end-to-end.

## Pre-Flight
Read C:\openclaw-docker\CLAUDE.md. Read docker-compose.yml.

## T1 Local Health
- docker compose ps → both "running" + "(healthy)"
- curl http://localhost:18790/health → {"status":"ok"}
- curl http://localhost:18789/health → HTTP 200
- docker compose logs goldb-admin --tail=20 — no errors
- docker compose logs goldb-gateway --tail=20 — no errors

## T2 Admin API Smoke
- Auth token: read from ~/.openclaw/openclaw.json → gateway.auth.password
- GET /api/status, /api/config, /api/groups, /api/knowledgebase/status, /api/version → valid JSON
- Unauthenticated GET /api/status → 401 or 503

## T3 Gateway Communication
- Admin→Gateway health via Docker network
- SSE /api/events → SSE headers
- WebSocket in admin logs

## T4 Container Resources
- docker stats --no-stream — admin ≤1GB, gateway ≤2GB

## T5 Remote Health (Hetzner)
- ssh root@178.104.17.170 "systemctl is-active goldb-watchdog-remote"
- OA Amuta health check via SSH
- **NOTE: OA Amuta is frozen at v1.4.37. Do NOT push updates or trigger any update mechanism on this server.**

## T6 Post-Update Guardian
- SKIP for OA Amuta (no updates pushed)
- For other clients: verify post-update health

## T7 Error Paths
- /api/internal/godmode-process empty body → 400
- /api/config no auth → 401/503
- No stack traces in error responses

## T8 WhatsApp Safety Verification
- Verify WHATSAPP-SAFETY.md exists in admin/ and is loaded into AGENTS.md (search for "Anti-Loop Protection" in workspace/AGENTS.md)
- Verify wake-up notification code exists in server.js (_sendWakeUpNotification function)
- Check gwEvents status handler uses { connected: true/false } format (NOT st.status string)

## Deliverables
PASS / FAIL / SKIP per test. WhatsApp not connected → SKIP.

## Constraints
- READ-ONLY — do NOT modify files
- Client dir (docker): C:\GoldB-Agent\
```

### 2.5 Project Manager Agent (when 4+ agents or complex changes)

```
You are the Project Manager coordinating the QA & Security audit phase.

## Your Role
You receive the results from QA, Security, and Integration agents. Your job:

1. **Merge & Deduplicate** — Same issue found by QA + Security → report once at higher severity
2. **Prioritize** — CRITICAL > HIGH > MEDIUM > LOW. List fix order.
3. **Validate Fixes** — If agents fixed issues, verify fixes don't conflict or introduce new bugs
4. **Identify Gaps** — Any area NOT covered by the agents? Any cross-cutting concerns missed?
5. **Risk Assessment** — Based on all reports, is the release safe? Flag blockers.

## Deliverables
Return:
- RELEASE_STATUS: GO / BLOCKED (with blocker list)
- MERGED_ISSUES: deduplicated issue list with severity + fix status
- GAPS: uncovered areas or concerns
- FIX_ORDER: if issues remain, recommended fix sequence

## Constraints
- Do NOT implement code — you coordinate only
- Communicate in Hebrew with the user
- Be concise — focus on decisions and blockers
```

### 2.6 Collect & Resolve

After all agents complete:

1. **If PM was dispatched**: use PM's merged report as the source of truth
2. **If no PM**: merge reports yourself — deduplicate, prioritize
3. **CRITICAL/HIGH issues**: verify they were fixed by agents. If not, fix them now.
4. **Re-verify**: if fixes were applied, run quick syntax check (`node -c`) on modified files
5. **Decision gate**: if RELEASE_STATUS = BLOCKED, inform user and wait for instructions before Phase 4

---

## Phase 3 — Documentation & Session Handoff (Parallel Agents)

Dispatch **2 agents in parallel**:

### 3.1 Documentation & Handoff Agent (SINGLE OWNER — all docs across pipeline)

This agent is the **sole owner** of ALL documentation tasks in the entire pipeline. No other agent writes docs.

```
You are the Documentation & Handoff Agent. You own ALL documentation across the full-finish pipeline:
session forensics, handoff document, MD updates, memory extraction, and public docs.

## TIMESTAMP RULE (MANDATORY)
Every documentation entry you write — in ANY file (MDs/, Plans/, MEMORY.md, memory files, Open-Problems.md, handoff document) — MUST include the current date and time (YYYY-MM-DD HH:MM) next to the heading or entry. Use `date` command to get the exact timestamp before writing. Never write a doc entry without a timestamp.

## Pre-Flight (MANDATORY)
1. Run `date '+%Y-%m-%d %H:%M'` to capture current timestamp for all entries.
2. Read C:\openclaw-docker\CLAUDE.md for project context.

---

## PART A — Session Forensics (from end-session)

Run these checks to capture session state:

### A.1 Git State Snapshot
git status                          # Uncommitted/untracked files
git diff --stat                     # Unstaged change summary
git diff --cached --stat            # Staged change summary
git stash list                      # Any stashed work
git log --oneline -10               # Recent commits
git branch --show-current           # Current branch

Flag uncommitted changes as CRITICAL open items.

### A.2 Container State
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "Docker not accessible"

### A.3 Active Tasks & Recent Errors
- Check TodoWrite state: completed, in-progress, not-started tasks
- Scan for errors: failed builds/tests, Docker errors, API errors, git conflicts

---

## PART B — Update Project Documentation

### B.1 Ensure mandatory MD files exist
Check root, docs/, MDs/ for: PRD.md, Knowledge.md, MEMORY.md
If MISSING, create in MDs/ with real content from codebase analysis.

### B.2 Update existing docs (ONLY if changes require it)
Read each file BEFORE editing. Surgical edits only. Keep existing style.
- CLAUDE.md — version line, new features/files/gotchas, directory structure
- MDs/MEMORY.md — new patterns, bug fixes, decisions, lessons
- MDs/Knowledge.md — architecture, patterns, config changes
- MDs/PRD.md — features, requirements, user flows
- README.md — user-facing setup, features, troubleshooting

### B.3 MANDATORY — Update MDs/Open-Problems.md
1. Mark resolved issues as ~~resolved~~ with version + fix description
2. Add new problems/bugs discovered during this session
3. Add new entries to Resolution History table
4. Update version + session count in header
This file is the SSOT for what's broken, fixed, and pending. Skipping = critical failure.

### B.4 Public docs (docs.bituah.net)
IF messaging channels, integrations, AI providers, security, or user-facing features changed:
1. Read admin/public/home.html, privacy-policy.html, terms.html
2. Edit source files, update "Last updated" dates
3. Clone, copy, commit, push to Gold-b/goldb-agent-docs
IF no relevant changes: state "Public docs unchanged" and skip.

---

## PART C — Memory & Learning Extraction

### C.1 Save Memory Files
Write/update memory files in ~/.claude/projects/<project>/memory/ for:
- **Project memories**: features, bugs with root cause, architecture decisions + WHY
- **Feedback memories**: user corrections, approaches that worked/failed
- **Reference memories**: external resources, API endpoints, tool locations
Each file: frontmatter + root cause + how-to-apply section.

### C.2 Update MEMORY.md Index
Add one-line entries to MEMORY.md for each new/updated memory file.

### C.3 Update Plans
- Plans/*.md — update plan status (completed/in-progress/blocked)
- CLAUDE.md — new gotchas, architecture changes, version references

---

## PART D — Session Handoff Document

Generate a self-contained handoff document in this format:

# Session Handoff — [DATE]
## TL;DR
[2-3 sentences]
## Completed Work
[bulleted list with file references]
## Open Issues
### P0 — Blocking
### P1 — High Priority (each with What/Where/Why/Approach)
### P2 — Low Priority
## Key Decisions
## Warnings for Next Session
## Files Changed
## Git State (branch, uncommitted, last commit)
## Suggested First Action for Next Session

---

## PART E — WhatsApp Notification (Optional)
If /whatsapp skill was used this session, send summary via WhatsApp.
Follow BiDi rules. run_in_background: true.

---

## Deliverables
1. Updated MD files list with change summary
2. Public docs status
3. Memory files saved/updated
4. Session handoff document (output to user)
5. Open-Problems.md updated

## Constraints
- Source: C:\openclaw-docker\
- Read BEFORE edit. Never guess file contents.
- Hebrew for prose, English for code/paths.
```

### 3.2 DevOps Agent

```
You are the DevOps Agent. Verify installers and infrastructure are in sync with code changes.

## Pre-Flight
Read C:\openclaw-docker\CLAUDE.md (directory structure, installer sections).

## Task A — Windows Installer (Inno Setup)
1. Read installer/goldb-setup.iss
2. Verify ALL new files from this session are in [Files] section
3. If new .bat/.ps1/.sh created → add Source line
4. If new post-install tasks → verify in installer/post-install.ps1
5. post-install.ps1 MUST be ASCII only (PS 5.1 encoding gotcha)

## Task B — Linux Installer
1. Read installer/install-ubuntu.sh
2. Verify new cron jobs, chmod +x, dependencies
3. auto-update.sh deploys via zipball (files auto-included), but cron/tasks need explicit setup

## Task C — Cross-Platform Parity
- Every new feature: Windows AND Linux implementation (or documented why platform-specific)
- version.json and goldb-setup.iss AppVersion in sync

## Task D — Docker Compose Verification
- Any new volumes, ports, env vars, entrypoint changes in docker-compose.yml
- Gateway wrapper: never change pinned SHA256 digest without approval
- cap_drop: ALL on admin (NOT gateway — breaks DNS)

## Deliverables
- Installer status: files added/verified/unchanged
- Platform parity: confirmed or gaps identified
- Docker: changes validated or issues found

## Constraints
- Source: C:\openclaw-docker\
- If no new distributable files: "Installers unchanged"
```

---

## Phase 3.5 — Verify Documentation Agent Output (MANDATORY)

The Documentation & Handoff Agent (Phase 3.1) handles ALL documentation and session knowledge extraction. The orchestrator's role here is **verification only**:

1. **Verify** the Documentation Agent updated `MDs/Open-Problems.md` (MANDATORY every session)
2. **Verify** memory files were saved/updated in `~/.claude/projects/<project>/memory/`
3. **Verify** the session handoff document was generated
4. **If any are missing**: instruct the Documentation Agent via SendMessage to complete them
5. **Add** any findings from Phase 2 (QA/Security) that the Documentation Agent may have missed

**This verification is NON-NEGOTIABLE.** The Documentation Agent owns the work; the orchestrator owns the quality gate.

---

## Phase 4 — Version Bump + Git Commit + Push (Orchestrator)

You perform this phase directly (sequential operations):

### 4.1 Version Bump

**MANDATORY — bump version BEFORE commit:**

1. Read `version.json` — increment patch (e.g., `1.4.7` → `1.4.8`).
2. Update `installer/goldb-setup.iss` `#define MyAppVersion` to match.
3. Update `CLAUDE.md` version line (`Current version:`) AND project overview version.
4. Verify all three are in sync.

**CRITICAL:** Never commit under the same version as a previous release. Auto-update compares versions — same = "already up to date" = client skips.

### 4.2 Git Commit + Push

1. Run `git status` to confirm all changes are ready.
2. Run `git log --oneline -5` for commit message style.
3. Stage all relevant files (NOT secrets: `.env`, `*.enc`, `*.key`; NOT build output: `dist/`, `output/`).
4. Commit:
   ```bash
   git commit -m "$(cat <<'EOF'
   <concise summary of what changed and why>

   Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
   EOF
   )"
   ```
5. Push: `git push`
6. If push fails (remote has new commits), ask user before force-push. NEVER force-push without approval.

---

## Phase 5 — GitHub Release + Installer Build (Orchestrator)

**Immediately after push succeeds:**

1. Read `version.json` for current version.
2. Verify `goldb-setup.iss` `AppVersion` matches.
3. Build Windows EXE:
   ```bash
   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" "C:\openclaw-docker\installer\goldb-setup.iss"
   ```
4. Verify output EXE in `installer/output/`.
5. Stage, commit, push EXE:
   ```bash
   git add installer/output/*.exe version.json installer/goldb-setup.iss
   git commit -m "$(cat <<'EOF'
   Build EXE for v<VERSION>

   Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
   EOF
   )"
   git push
   ```
6. Create GitHub release:
   ```bash
   gh release create v<VERSION> installer/output/GoldBAgent-Setup.exe installer/install-ubuntu.sh \
     --title "v<VERSION>" \
     --notes "Release v<VERSION>"
   ```
7. Confirm release URL.

**CRITICAL:** Tags MUST be clean semver (`v1.4.8`). No suffixes. `auto-update.ps1` uses `[System.Version]::Parse()` — suffixes break it.

---

## Phase 6 — Push Update to Clients (Orchestrator)

**MANDATORY — immediately after GitHub Release.**

> **⛔ OA Amuta (Hetzner 178.104.17.170) — DO NOT UPDATE.**
> This server is frozen at v1.4.37. Auto-update was removed (cron + files deleted on 2026-03-25).
> Do NOT push updates, do NOT SSH to trigger push-update, do NOT run any update commands on this server.
> The server runs independently and must NOT receive new versions.

1. Local Windows client (`C:\GoldB-Agent\`) → remind user to run `UPDATE.bat`.
2. Any future clients → update via their configured mechanism.
3. Failed clients → log, do NOT block pipeline.

---

## Phase 7 — Final Report + Session Handoff (Orchestrator)

**This phase has TWO mandatory outputs.** Both must be displayed directly to the user (not just saved to files).

### 7.1 Release Report

Compile a **Hebrew** summary from all agent outputs:

```
## דוח Full-Finish — v[VERSION]

### סיכום כללי
- קבצים שנבדקו: X
- סוכנים שפעלו: Y (QA, Security, Integration, PM, Docs, DevOps)
- בעיות שנמצאו: Z (W תוקנו)
- סטטוס: ✓ תקין / ⚠ נדרש תיקון / ✗ חסימה

### QA (סוכן 1)
- שכבות שנבדקו: A-H
- Direct Tests (F): [PASS/FAIL/SKIP — test count]
- E2E Tests (G): [PASS/FAIL — flows tested]
- Flow Tests (H): [PASS/FAIL/SKIP — nodes tested]
- [PASS/FAIL/WARN/FIXED summary]

### אבטחה (סוכן 2)
- שכבות שנבדקו: 1-3
- [CRITICAL/HIGH/MEDIUM/LOW/CLEAN summary]

### אינטגרציה (סוכן 3)
- בדיקות שרצו: T1-T7
- [PASS/FAIL/SKIP counts]

### מנהל פרויקט (אם פעל)
- סטטוס שחרור: GO / BLOCKED
- בעיות ממוזגות + סדר עדיפויות

### תיעוד + Handoff (סוכן 4)
- קבצים שעודכנו/נוצרו
- Public docs: עודכנו / ללא שינוי
- Memory files: saved / updated / none

### DevOps (סוכן 5)
- מתקינים: תקינים / עודכנו / ללא שינוי
- פלטפורמות: Windows + Linux

### גרסה ושחרור
- גרסה: v[VERSION]
- Commit: [HASH]
- Release: [URL]

### עדכון לקוחות
- [per-client status: updated / failed / skipped]

### בעיות פתוחות
- [anything unfixed needing user attention]
```

### 7.2 Session Handoff Document (MANDATORY)

**Read** the handoff document generated by the Docs+Handoff Agent (saved as a memory file) and **display it in full** to the user. This document is the session's legacy — a new Claude Code session will read it as the first message to have full context.

If the Docs+Handoff Agent saved it to a memory file, read it with the Read tool and output it verbatim. If not saved to a file, reconstruct it from the agent's output using this template:

```markdown
# Session Handoff — [DATE]
**Branch**: [branch] | **Version**: [version] | **Duration**: [estimate]

## TL;DR
[2-3 sentences]

## Completed Work
[per-release bulleted list with file references]

## Open Issues
### P0 — Blocking
### P1 — High Priority
### P2 — Low Priority

## Key Decisions
## Warnings for Next Session
## Git State
- Branch: [name], Uncommitted: [yes/no], Last commit: [hash]

## Container State
[table of containers + status]

## Suggested First Action for Next Session
[specific, actionable instruction]
```

**CRITICAL:** The handoff document MUST be displayed directly in the Phase 7 output. Saving it to a file is NOT sufficient — the user must see it.

---

## Orchestration Summary

```
Phase 1: Orchestrator analyzes changes                          [sequential]
    ↓
Phase 2: QA + Security + Integration + PM agents               [parallel]
    ↓
  2.6: Orchestrator merges results, fixes CRITICAL/HIGH         [sequential]
    ↓
Phase 3: Documentation + DevOps agents                          [parallel]
    ↓
Phase 3.5: Orchestrator extracts session knowledge, updates MDs  [sequential]
    ↓
Phase 4: Orchestrator bumps version, commits, pushes            [sequential]
    ↓
Phase 5: Orchestrator builds EXE, creates GitHub release        [sequential]
    ↓
Phase 6: Orchestrator pushes update to all clients              [sequential]
    ↓
Phase 7: Orchestrator compiles final Hebrew report              [sequential]
```

**Total agents per run: 4-6** (depending on change scope)
**Parallel waves: 2** (Phase 2 audit wave + Phase 3 docs wave)

---

## Important Notes

- **NEVER skip phases.** If nothing to do, state that and move on.
- **NEVER create empty commits.** Skip Phase 4 if no changes.
- **NEVER force-push without user approval.**
- **Read files before editing.** Do NOT guess contents.
- **Phase 2 agents are MANDATORY** on every non-trivial code change. All must run in parallel (single message, multiple Agent tool calls). Use `model: opus` for QA + Security, `model: sonnet` for Integration + PM + Docs + DevOps.
- **PM agent**: Include when 4+ agents or complex changes. PM merges reports and validates fix integrity.
- **Deduplication**: Same issue found by QA + Security → report once at higher severity.
- **Fix immediately**: Agents fix CRITICAL/HIGH in source files, not just report.
- **Decision gate**: If PM returns BLOCKED, stop and inform user before releasing.
- **Mandatory MD files**: PRD.md, Knowledge.md, MEMORY.md must exist after Phase 3.
- **Gold-B specifics**: Source `C:\openclaw-docker\`, client `C:\GoldB-Agent\`. `thinkingBudget: 0`, `...result.usage` spread, `_autoSync()`, Hebrew UI + English code.
- **Release tags**: Clean semver only (`v1.4.8`). No suffixes — breaks `[System.Version]::Parse()`.
- **WhatsApp Safety**: Verify `admin/WHATSAPP-SAFETY.md` is loaded into both AGENTS.md (sync-keywords.js) and KB synthesis prompt (ai-processor.js). Verify wake-up notification sends to personalNumbers on gateway reconnect.

---

## Phase 8 — Memory & Knowledge Maintenance (MANDATORY — Final Phase)

**This phase runs AFTER Phase 7, before returning control to the user.** It prevents knowledge drift across sessions.

1. **MEMORY.md index** — verify under 200 lines. Remove stale entries, merge duplicates.
2. **Memory files** — new files this session must not duplicate existing ones or CLAUDE.md gotchas. Merge or replace.
3. **Completed projects** — move memory files for completed work to `archive/`, remove from MEMORY.md index.
4. **MDs/Open-Problems.md** — mark resolved items, add new issues.
5. **MDs/HANDOFF-*.md** — archive previous handoff if a new one was generated.
6. **Plans/** — move fully-implemented plans to `Plans/archive/`.
7. **Stale references** — verify all paths in MEMORY.md and CLAUDE.md Documentation Map still exist.
8. **CLAUDE.md gotchas** — add new gotchas for any non-obvious technical rules discovered this session.

**Target:** minimal file count, zero duplication, all references valid, MEMORY.md under 200 lines.
