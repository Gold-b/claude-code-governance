# Context Governance Installer for Claude Code

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

### Extended Skills (5, skipped with `--core-only`)
- **plan-and-execute** — Multi-agent planning pipeline
- **qa-sec** — QA + Security audit suite
- **multi-agents** — Orchestrated agent teams
- **full-finish** — Universal post-task release pipeline
- **enable-remote-code** — Remote control for Claude Code sessions

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
