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

# Resolve the project from the PAYLOAD before anything gates on it. Both gates below used to fall
# back to a $PWD walk, which from inside `~/.claude/**` resolves to the user-level CLAUDE.md and
# reports DEPLOYMENT - silently discarding every write a session made while its shell was there.
GOV_INPUT="$(gov_hook_input)"
GOV_ROOT="$(gov_payload_root "$GOV_INPUT")"
export GOV_PROJECT_ROOT="$GOV_ROOT"

# Node-role gate (Framework v2): edits on DEPLOYMENT/FROZEN nodes are anomalies.
# Don't track — they're either mirror-copies or should have been blocked earlier.
gov_role_guard SOURCE

# Not a governed project — skip.
# Asks about the project the EDIT belongs to (payload `cwd`/`file_path`), not about wherever this
# hook process happens to be standing. The old relative test silently dropped every write made
# while the session's shell sat outside the project root - see gov_payload_root() for the full
# account and why a $PWD walk is not a safe substitute.
if ! gov_is_governed "$GOV_ROOT"; then
  exit 0
fi

# --- Track changed files (append-only log) ---
# PostToolUse stdin: {"tool_input":{"file_path":"..."}, "tool_name":"Edit", "cwd":"..."}
# Older versions had file_path at top-level. Handle both.
CHANGES_LOG="$(gov_state_file .gov-session-changes)"
FILE_CHANGED=""
if [ ! -t 0 ]; then
  INPUT="$GOV_INPUT"; [ -z "$INPUT" ] && INPUT="{}"
  # Prefer python3 JSON parsing (handles nesting correctly)
  if command -v python3 &>/dev/null; then
    FILE_CHANGED=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    p = d.get('tool_input', {}).get('file_path', '') or d.get('file_path', '') or d.get('tool_response', {}).get('filePath', '')
    print(p)
except: pass
" 2>/dev/null)
  fi
  # Fallback: regex — matches file_path at any nesting depth
  if [ -z "$FILE_CHANGED" ]; then
    FILE_CHANGED=$(echo "$INPUT" | grep -oP '"file_path"\s*:\s*"([^"]+)"' | head -1 | sed 's/.*"file_path"\s*:\s*"\([^"]*\)".*/\1/' 2>/dev/null)
  fi
fi
if [ -n "$FILE_CHANGED" ]; then
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

STATE_FILE="$(gov_state_file .gov-milestone-state)"
cat > "$STATE_FILE" 2>/dev/null <<EOF
change_count=$CHANGE_COUNT
has_doc_change=$HAS_DOC_CHANGE
has_code_change=$HAS_CODE_CHANGE
last_update=$(date +%s)
EOF

gov_log "post-milestone" "tracked change #$CHANGE_COUNT: $FILE_CHANGED (code=$HAS_CODE_CHANGE doc=$HAS_DOC_CHANGE)"

# --- Throttled reminder (every 5 minutes) ---
THROTTLE_FILE="$(gov_state_file .post-milestone-last)"
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
QA_NOTIFIED_FLAG="$(gov_state_file .gov-qa-notified)"
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
