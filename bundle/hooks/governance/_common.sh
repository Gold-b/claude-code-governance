#!/usr/bin/env bash
# _common.sh — Context Governance hook shared utilities
# Created: 2026-04-11 (Phase 4 of Context Governance rollout)
# Master Plan §8 — sourced by all governance hook scripts in this directory.
#
# Behavior contract:
#   * Exit code rules (HARD RULE — 2026-04-13 deadlock incident):
#     - UserPromptSubmit hooks: NEVER exit 2. Exit 2 blocks ALL responses,
#       creating an unrecoverable deadlock. Use exit 0 + warning instead.
#     - PreToolUse hooks: exit 2 is OK (blocks one tool, LLM can adapt).
#       BUT prefer exit 0 + warning unless the action is truly destructive.
#     - Stop hooks: exit 2 is OK (prevents premature session end).
#     - Infrastructure errors (log write, path parse) → fail-soft (exit 0).
#   * Idempotent. Running the same hook twice in a row produces the same result.
#   * Skill-aware. If the corresponding skill is not yet installed (Phase 5
#     deferred), the hook logs the skip and exits 0.
#   * Kill switch: GOVERNANCE_HOOKS=0 disables ALL hooks globally.
#
# Environment variables:
#   GOVERNANCE_HOOKS         (default: 1)   set to "0" to disable all governance hooks globally
#   GOVERNANCE_LOG           (default: ~/.claude/logs/governance.log) path of the rolling hook log
#   GOVERNANCE_SKILLS_DIR    (default: ~/.claude/skills) where to look for skill definitions

GOVERNANCE_LOG="${GOVERNANCE_LOG:-$HOME/.claude/logs/governance.log}"
GOVERNANCE_HOOKS="${GOVERNANCE_HOOKS:-1}"
GOVERNANCE_SKILLS_DIR="${GOVERNANCE_SKILLS_DIR:-$HOME/.claude/skills}"

# Security: validate log path stays under ~/.claude/ to prevent path injection via env var
case "$GOVERNANCE_LOG" in
  "$HOME/.claude/"*) ;; # OK
  *) GOVERNANCE_LOG="$HOME/.claude/logs/governance.log" ;;
esac

# Ensure log dir exists. Failure here is non-fatal — we still try to run.
mkdir -p "$(dirname "$GOVERNANCE_LOG")" 2>/dev/null || true

# gov_log <hook_name> <message>
# Appends a timestamped line to the governance log. Never throws.
# Sanitizes message to prevent log injection (strips newlines/control chars).
gov_log() {
  local hook="$1"
  local msg
  msg=$(printf '%s' "$2" | tr -d '\n\r' | tr -cd '[:print:]')
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown-time")
  # Refuse to write if log is a symlink
  [ -L "$GOVERNANCE_LOG" ] && return 0
  echo "[$ts] [$hook] $msg" >> "$GOVERNANCE_LOG" 2>/dev/null || true
}

# gov_disabled
# Returns 0 (success) if governance hooks are globally disabled (GOVERNANCE_HOOKS=0).
# Use as: `gov_disabled && exit 0`
gov_disabled() {
  if [ "$GOVERNANCE_HOOKS" = "0" ]; then
    return 0
  fi
  return 1
}

# gov_skill_exists <skill_name>
# Returns 0 (success) if the named skill is installed at $GOVERNANCE_SKILLS_DIR/<skill_name>/SKILL.md
gov_skill_exists() {
  local skill="$1"
  if [ -d "$GOVERNANCE_SKILLS_DIR/$skill" ] && [ -f "$GOVERNANCE_SKILLS_DIR/$skill/SKILL.md" ]; then
    return 0
  fi
  return 1
}

# gov_phase_state
# Echoes a one-word state describing what Phase 4 vs Phase 5 should expect.
# Used for diagnostic logging.
gov_phase_state() {
  if gov_skill_exists "context-governance"; then
    echo "phase5+"
  else
    echo "phase4-plumbing"
  fi
}

# gov_notify <title> <message> [skill_name]
# Shows a topmost popup notification on Windows via PowerShell WPF dialog.
# The popup stays on screen until the user clicks the dismiss button.
# Runs ASYNC — returns immediately, does NOT block the hook.
# Fails silently on non-Windows or if PowerShell unavailable.
# Automatically detects project name from CWD.
# Arguments are sanitized to prevent command injection.
gov_notify() {
  local title="$1"
  local message="$2"
  local skill="${3:-}"
  local script_path
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/gov-notify.ps1"

  # Popup kill switch (separate from GOVERNANCE_HOOKS — allows silent smoke tests)
  [ "${GOV_NOTIFY:-1}" = "0" ] && return 0

  # Only on Windows, only if script exists
  [ ! -f "$script_path" ] && return 0
  command -v powershell.exe >/dev/null 2>&1 || return 0

  # Detect project name from CWD or CLAUDE.md
  local project=""
  project=$(basename "$(pwd)" 2>/dev/null || echo "")

  # Sanitize inputs — strip quotes and special chars to prevent injection
  title=$(printf '%s' "$title" | tr -d "'\"\`\$" | head -c 200)
  message=$(printf '%s' "$message" | tr -d "'\"\`\$" | head -c 500)
  skill=$(printf '%s' "$skill" | tr -d "'\"\`\$" | head -c 100)
  project=$(printf '%s' "$project" | tr -d "'\"\`\$" | head -c 100)

  # Build args array
  local args=(-ExecutionPolicy Bypass -WindowStyle Hidden -File "$script_path")
  args+=(-Title "$title" -Message "$message")
  [ -n "$skill" ] && args+=(-Skill "$skill")
  [ -n "$project" ] && args+=(-Project "$project")

  # Run async — fire and forget (do NOT block the hook).
  # MSYS_NO_PATHCONV=1 prevents Git Bash from converting arguments that start
  # with "/" (e.g., "/full-finish") to Windows paths ("C:/Program Files/Git/full-finish").
  MSYS_NO_PATHCONV=1 powershell.exe "${args[@]}" </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}
