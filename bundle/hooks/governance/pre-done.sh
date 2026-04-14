#!/usr/bin/env bash
# pre-done.sh — Context Governance ENFORCEMENT hook (TaskCompleted)
# Master Plan §8.5 — fires when a task is marked complete.
# Deterministic blocking: blocks task completion if governance evidence is missing.
#
# Enforcement logic:
#   Session has tracked changes AND no success token → exit 2 (BLOCK)
#   No changes tracked this session → exit 0 (nothing to verify)
#   Success token exists and valid → exit 0 (evidence present)
#
# Kill switch: GOVERNANCE_HOOKS=0
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0

# Not a governed project — skip
if [ ! -f "docs/context/CONTEXT-MANIFEST.md" ]; then
  exit 0
fi

gov_log "pre-done" "fired — checking verification gate"

# Check if session has any tracked changes
CHANGES_LOG="$HOME/.claude/logs/.gov-session-changes"
CHANGE_COUNT=0
if [ -f "$CHANGES_LOG" ]; then
  CHANGE_COUNT=$(wc -l < "$CHANGES_LOG" 2>/dev/null | tr -d ' ')
fi

if [ "$CHANGE_COUNT" -eq 0 ]; then
  # No file changes this session — no evidence needed for read-only work
  gov_log "pre-done" "no changes tracked — allowing task completion"
  exit 0
fi

# Changes exist — check for governance success token
TOKEN_FILE="$HOME/.claude/logs/governance-success-token.json"

if [ ! -f "$TOKEN_FILE" ]; then
  gov_log "pre-done" "BLOCKED: $CHANGE_COUNT changes but no success token"

  # Show popup notification for verification gate
  gov_notify \
    "שער אימות" \
    "נמצאו ${CHANGE_COUNT} שינויים ללא אסמכתא. יש לספק ראיות לפני השלמת המשימה." \
    "Verification Gate"

  cat >&2 <<ERRMSG
[GOVERNANCE VERIFICATION GATE] BLOCKED — task marked complete but no evidence token found.

This session has $CHANGE_COUNT tracked file writes. Before completing:

1. EXTERNAL EVIDENCE: Provide test output, build log, docker logs, or API response.
   Saying 'it should work' is NOT evidence.
2. BOTH REPOS: If you edited source (C:\\openclaw-docker), also update client (C:\\GoldB-Agent).
3. DOCUMENTATION: Update CLAUDE.md, GOTCHAS.md, or OPEN-PROBLEMS.md for findings.
4. NO REGRESSIONS: Verify related systems still work.
5. GOVERNANCE: Run /live-state-orchestrator if not done this milestone.

After verification, issue the token:
  bash ~/.claude/hooks/governance/commit-task-success.sh "<task description>"

Override for non-code tasks: GOVERNANCE_HOOKS=0
ERRMSG
  exit 2
fi

# Token exists — verify TTL
NOW_EPOCH=$(date +%s)
EXPIRES_EPOCH=$(cat "$TOKEN_FILE" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(int(d.get("expires_at_epoch", 0)))
except Exception:
    print(0)
' 2>/dev/null)

if [ -z "$EXPIRES_EPOCH" ] || [ "$EXPIRES_EPOCH" = "0" ]; then
  gov_log "pre-done" "BLOCKED: token malformed"
  echo "[GOVERNANCE VERIFICATION GATE] BLOCKED — success token is malformed. Re-issue: bash ~/.claude/hooks/governance/commit-task-success.sh \"<desc>\"" >&2
  exit 2
fi

if [ "$NOW_EPOCH" -gt "$EXPIRES_EPOCH" ]; then
  EXPIRED_AGO=$(($NOW_EPOCH - $EXPIRES_EPOCH))
  gov_log "pre-done" "BLOCKED: token expired ${EXPIRED_AGO}s ago"
  echo "[GOVERNANCE VERIFICATION GATE] BLOCKED — success token expired ${EXPIRED_AGO}s ago. Re-verify and re-issue: bash ~/.claude/hooks/governance/commit-task-success.sh \"<desc>\"" >&2
  exit 2
fi

# Token valid — allow task completion
REMAINING=$(($EXPIRES_EPOCH - $NOW_EPOCH))
gov_log "pre-done" "ALLOWED: token valid (${REMAINING}s remaining), $CHANGE_COUNT changes verified"
exit 0
