#!/usr/bin/env bash
# post-milestone.sh — Context Governance hook (PostToolUse: Edit/Write)
# Fires after every successful file write. Outputs a periodic reminder to
# update project state via /live-state-orchestrator.
#
# Throttled: outputs the reminder at most once per 5 minutes to avoid noise.
# The reminder goes to stdout, which Claude Code injects into LLM context.

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0

# Throttle: only remind once per 5 minutes (300 seconds)
THROTTLE_FILE="$HOME/.claude/logs/.post-milestone-last"
NOW_EPOCH=$(date +%s 2>/dev/null || echo 0)

if [ -f "$THROTTLE_FILE" ]; then
  LAST_EPOCH=$(cat "$THROTTLE_FILE" 2>/dev/null || echo 0)
  ELAPSED=$((NOW_EPOCH - LAST_EPOCH))
  if [ "$ELAPSED" -lt 300 ]; then
    # Too soon — stay quiet
    exit 0
  fi
fi

# Enough time passed — output reminder and update throttle
echo "$NOW_EPOCH" > "$THROTTLE_FILE" 2>/dev/null

gov_log "post-milestone" "fired — outputting state-update reminder"
echo "[GOVERNANCE] Multiple file writes detected. Consider running /live-state-orchestrator to keep PLAN.md, MEMORY.md, and OPEN-PROBLEMS.md in sync with your progress. Save new memories for important decisions, fixes, and lessons learned."
exit 0
