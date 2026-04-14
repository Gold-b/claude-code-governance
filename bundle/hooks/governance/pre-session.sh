#!/usr/bin/env bash
# pre-session.sh — Context Governance hook (SessionStart)
# Cannot block (exit 2 would prevent session from starting = deadlock).
# Instead: sets up state, detects crashed previous sessions, outputs instructions.
#
# Responsibilities:
#   1. Reset session marker + prompt counter (clean slate)
#   2. Detect orphan session (previous crash — changes log exists without cleanup)
#   3. Output IMPERATIVE instructions for governed/ungoverned projects
#
# Kill switch: GOVERNANCE_HOOKS=0
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }
gov_disabled && exit 0

SESSION_MARKER="$HOME/.claude/logs/.gov-session-bootstrapped"
PROMPT_COUNTER="$HOME/.claude/logs/.gov-session-prompt-count"
CHANGES_LOG="$HOME/.claude/logs/.gov-session-changes"
CRASH_FLAG=""

# --- Step 1: Detect orphan session (crash recovery) ---
# If .gov-session-changes exists, a previous session tracked file writes but
# never cleaned up (end-session.sh didn't run = crash or force-kill).
if [ -f "$CHANGES_LOG" ]; then
  ORPHAN_COUNT=$(wc -l < "$CHANGES_LOG" 2>/dev/null | tr -d ' ')
  if [ "$ORPHAN_COUNT" -gt 0 ]; then
    CRASH_FLAG="true"
    # Archive the orphan log for forensics
    ARCHIVE="$HOME/.claude/logs/.gov-crashed-session-$(date +%Y%m%d-%H%M%S).log"
    cp "$CHANGES_LOG" "$ARCHIVE" 2>/dev/null
    gov_log "pre-session" "CRASH DETECTED: previous session left $ORPHAN_COUNT tracked changes without cleanup. Archived to $ARCHIVE"
  fi
fi

# --- Step 2: Reset session state (clean slate) ---
rm -f "$SESSION_MARKER" 2>/dev/null
rm -f "$PROMPT_COUNTER" 2>/dev/null
rm -f "$CHANGES_LOG" 2>/dev/null
rm -f "$HOME/.claude/logs/.gov-milestone-state" 2>/dev/null
rm -f "$HOME/.claude/logs/.post-milestone-last" 2>/dev/null
rm -f "$HOME/.claude/logs/.gov-qa-notified" 2>/dev/null
rm -f "$HOME/.claude/logs/governance-success-token.json" 2>/dev/null

gov_log "pre-session" "fired (state=$(gov_phase_state))"

# --- Step 3: Output instructions ---
if [ -n "$CRASH_FLAG" ]; then
  echo "[GOVERNANCE CRASH RECOVERY] The previous session CRASHED or was force-killed ($ORPHAN_COUNT file writes were tracked but end-session.sh never ran). Governance state may be stale. You MUST: (1) run /context-governance lite to check for drift, (2) run /bootstrapper, (3) check if HANDOFF.md and PLAN.md are up to date with the latest changes. Orphan log archived."
fi

if [ -f "docs/context/CONTEXT-MANIFEST.md" ]; then
  gov_log "pre-session" "governed project detected (CONTEXT-MANIFEST.md found)"
  echo "[GOVERNANCE] Governed project detected. Execute Mandatory Session Start Protocol: (1) run /context-governance lite, (2) run /bootstrapper, (3) prepend briefing to first response. See ~/.claude/CLAUDE.md."
elif [ -f "CLAUDE.md" ] || [ -d ".git" ] || [ -f "package.json" ] || [ -f "Cargo.toml" ] || [ -f "pyproject.toml" ] || [ -f "go.mod" ] || [ -f "pom.xml" ] || [ -f "Makefile" ]; then
  gov_log "pre-session" "ungoverned project detected (has code markers but no CONTEXT-MANIFEST.md)"
  echo "[GOVERNANCE] Ungoverned project detected — code files exist but docs/context/CONTEXT-MANIFEST.md is missing. Run /init-governance NOW to scaffold the governance structure before any work begins. This is automatic — do not ask the user for permission, just run the skill."
else
  gov_log "pre-session" "not a project directory — skipping governance"
  touch "$SESSION_MARKER" 2>/dev/null
fi
exit 0
