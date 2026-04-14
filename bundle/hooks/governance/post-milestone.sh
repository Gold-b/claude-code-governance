#!/usr/bin/env bash
# post-milestone.sh — Context Governance STATE TRACKING hook (PostToolUse: Edit/Write)
# Cannot block (PostToolUse — edit already happened, exit 2 can't undo).
# Instead: tracks ALL file changes for downstream enforcement (pre-done.sh,
# check-docs-updated.sh, end-session.sh use this data to BLOCK).
#
# This hook is the "instrumentation layer" — it records what happened.
# Enforcement happens downstream at TaskCompleted and Stop events.
#
# State files written:
#   ~/.claude/logs/.gov-session-changes — append-only log of changed file paths
#   ~/.claude/logs/.gov-milestone-state — JSON-like state for downstream hooks
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

# --- Track changed files (append-only log) ---
CHANGES_LOG="$HOME/.claude/logs/.gov-session-changes"
FILE_CHANGED="unknown"
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || echo "{}")
  FILE_CHANGED=$(echo "$INPUT" | grep -oP '"file_path"\s*:\s*"([^"]+)"' | head -1 | sed 's/.*"file_path"\s*:\s*"\([^"]*\)".*/\1/' 2>/dev/null || echo "unknown")
fi
if [ "$FILE_CHANGED" != "unknown" ] && [ -n "$FILE_CHANGED" ]; then
  echo "$FILE_CHANGED" >> "$CHANGES_LOG" 2>/dev/null
fi

# --- Update milestone state for downstream hooks ---
CHANGE_COUNT=0
if [ -f "$CHANGES_LOG" ]; then
  CHANGE_COUNT=$(wc -l < "$CHANGES_LOG" 2>/dev/null | tr -d ' ')
fi

# Track whether governance-relevant files were changed
HAS_DOC_CHANGE=0
HAS_CODE_CHANGE=0
if [ -f "$CHANGES_LOG" ]; then
  grep -qiE 'GOTCHAS|HANDOFF|Open-Problems|MEMORY|CONVENTIONS' "$CHANGES_LOG" 2>/dev/null && HAS_DOC_CHANGE=1
  grep -qiE '\.js$|\.ts$|\.json$|\.ps1$|\.sh$' "$CHANGES_LOG" 2>/dev/null && HAS_CODE_CHANGE=1
fi

STATE_FILE="$HOME/.claude/logs/.gov-milestone-state"
cat > "$STATE_FILE" 2>/dev/null <<EOF
change_count=$CHANGE_COUNT
has_doc_change=$HAS_DOC_CHANGE
has_code_change=$HAS_CODE_CHANGE
last_update=$(date +%s)
EOF

gov_log "post-milestone" "tracked change #$CHANGE_COUNT: $FILE_CHANGED (code=$HAS_CODE_CHANGE doc=$HAS_DOC_CHANGE)"

# --- Throttled reminder (every 5 minutes) ---
THROTTLE_FILE="$HOME/.claude/logs/.post-milestone-last"
NOW_EPOCH=$(date +%s 2>/dev/null || echo 0)

if [ -f "$THROTTLE_FILE" ]; then
  LAST_EPOCH=$(cat "$THROTTLE_FILE" 2>/dev/null || echo 0)
  ELAPSED=$((NOW_EPOCH - LAST_EPOCH))
  if [ "$ELAPSED" -lt 300 ]; then
    exit 0
  fi
fi

echo "$NOW_EPOCH" > "$THROTTLE_FILE" 2>/dev/null

# Recommend /qa-sec after significant code changes (once per session)
QA_NOTIFIED_FLAG="$HOME/.claude/logs/.gov-qa-notified"
if [ "$CHANGE_COUNT" -ge 10 ] && [ "$HAS_CODE_CHANGE" -eq 1 ] && [ ! -f "$QA_NOTIFIED_FLAG" ]; then
  gov_notify \
    "QA מומלץ" \
    "${CHANGE_COUNT} שינויי קוד בסשן הנוכחי. מומלץ להריץ בדיקות." \
    "/qa-sec"
  echo "$NOW_EPOCH" > "$QA_NOTIFIED_FLAG" 2>/dev/null
  gov_log "post-milestone" "qa-sec recommendation popup shown ($CHANGE_COUNT code changes)"
fi

echo "[GOVERNANCE] $CHANGE_COUNT file writes this session (code=$HAS_CODE_CHANGE doc=$HAS_DOC_CHANGE). Downstream hooks WILL BLOCK task completion if documentation is missing. Run /live-state-orchestrator at each milestone."
exit 0
