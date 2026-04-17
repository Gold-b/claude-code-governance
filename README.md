# Context Governance Installer for Claude Code by Gold-B.

Portable installer that sets up the full Context Governance architecture at the user level (`~/.claude/`).

## Quick Install

```bash
bash ~/.claude/governance-installer/install.sh
```

## Options

| Flag | Effect |
|---|---|
| `--core-only` | Install only 7 core governance skills (skip 5 extended toolkit skills) |
| `--force` | Overwrite existing files without prompting |
| `--dry-run` | Preview what would be installed (no changes) |
| `--no-claude-md` | Skip CLAUDE.md — keep your existing user instructions |
| `--uninstall` | Remove all governance files (backs up before removal) |

## What Gets Installed

### Hooks (11 scripts in `~/.claude/hooks/`)
| Event | Script | Purpose |
|---|---|---|
| SessionStart | `pre-session.sh` | Detects governance, triggers briefing |
| UserPromptSubmit | `pre-task.sh` | Governance lite check per message |
| PreToolUse (Edit/Write) | `governance-guard.sh` | Blocks protected-doc edits without success token |
| PreToolUse (Edit/Write) | `pre-write.sh` | Impact map before file changes |
| PostToolUse (Edit/Write) | `post-milestone.sh` | State update after milestones |
| TaskCompleted | `check-full-finish.sh` | Warns about uncommitted changes |
| Stop | `end-session.sh` | Session-end handoff |

### Core Skills (7)
- **bootstrapper** — Loads relevant project context for session briefing
- **context-governance** — Audits context file hygiene (lite + full modes)
- **evidence-debugger** — Root-cause analysis with confidence grading
- **impact-safe-executor** — Pre-write impact map, scope enforcement
- **init-governance** — One-time project scaffold for governance structure
- **live-state-orchestrator** — Keeps PLAN/MEMORY/HANDOFF in sync
- **parallel-session-merge** — Reconciles multi-agent parallel work

### Extended Skills (6, skipped with `--core-only`)
- **plan-and-execute** — Multi-agent planning pipeline
- **qa-sec** — QA + Security audit suite
- **multi-agents** — Orchestrated agent teams
- **full-finish** — Universal post-task release pipeline
- **pre-close-check** — Parallel-session drift protection before any close/handoff/release (NEW 2026-04-17)
- **enable-remote-code** — Remote control for Claude Code sessions

### Pre-Close Reality Check (2026-04-17)

The `pre-close-check` skill protects against **parallel-session drift** — the scenario where two Claude sessions run concurrently on the same project and one closes with stale state that overwrites the other's work.

**Triggered automatically before:**
- `/full-finish` Phase 0 (before any release)
- `/live-state-orchestrator` HANDOFF writes
- `/plan-and-execute` Phase 3.3 (governance state update)

**5 checks performed:**
1. `git log --since="60 minutes ago"` — commits from parallel sessions
2. Handoff file mtimes vs session start
3. `version.json` ↔ `CLAUDE.md` ↔ `HANDOFF` pointer consistency
4. Active handoff count = 1 (dual handoffs = drift)
5. `CONTEXT-MANIFEST.md` in sync with actual handoff state

If `PARALLEL_SESSION_DETECTED` or `DRIFT_DETECTED` → calling skill halts, asks user how to resolve. Prevents the 2026-04-17 `v1.4.112-b/v1.4.113` incident class of errors.

### Docs (2 guides in `~/.claude/docs/`)
- **GOVERNANCE-AGENT-GUIDE.md** — Structured guide for LLM implementation
- **GOVERNANCE-HUMAN-GUIDE.md** — Human-readable governance reference

### Configuration
- **CLAUDE.md** — User-level instructions (session protocol, security, governance rules)
- **settings.json** — Hook registrations merged into existing settings

## Portability

To install on another machine:
1. Copy the entire `~/.claude/governance-installer/` directory
2. Run `bash ~/.claude/governance-installer/install.sh`

All paths use `~/` notation — works on Windows (Git Bash/MSYS2), macOS, and Linux.

## Kill Switch

Disable all governance hooks without uninstalling:
```bash
export GOVERNANCE_HOOKS=0
```

## Uninstall

```bash
bash ~/.claude/governance-installer/install.sh --uninstall
```
Backs up all files before removal. CLAUDE.md is NOT removed (manual decision).
