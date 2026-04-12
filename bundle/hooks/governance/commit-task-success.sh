#!/usr/bin/env bash
# commit-task-success.sh — Explicit success-confirmation gate for governance doc updates
# Created: 2026-04-12 (in response to user feedback: "enforcement via hook, not LLM instruction")
#
# This script is called EXPLICITLY by the LLM AFTER the user has confirmed
# that a task completed successfully. It creates a short-lived "success token"
# that the pre-write governance-guard hook reads to authorize edits to
# protected governance documents (Open-Problems.md, GOTCHAS.md, HANDOFF-*.md).
#
# Without this token, governance-guard.sh will BLOCK any write to protected
# docs — the LLM cannot bypass this by "forgetting the rule", because the
# hook runs at infrastructure level before the tool call is executed.
#
# Usage:
#   bash .claude/hooks/governance/commit-task-success.sh "<task-description>"
#
# The task description is free-form text describing what succeeded.
# It is saved with the token for audit purposes.
#
# Token lifetime: 5 minutes from creation.
# Token location: ~/.claude/logs/governance-success-token.json

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "ERROR: commit-task-success.sh requires a task description argument." >&2
  echo "Usage: bash commit-task-success.sh \"<task description>\"" >&2
  exit 2
fi

TASK_DESC="$1"
TOKEN_DIR="$HOME/.claude/logs"
TOKEN_FILE="$TOKEN_DIR/governance-success-token.json"
HISTORY_DIR="$TOKEN_DIR/governance-success-history"

mkdir -p "$TOKEN_DIR" "$HISTORY_DIR"

NOW_EPOCH=$(date +%s)
NOW_ISO=$(date '+%Y-%m-%dT%H:%M:%S%z')
EXPIRES_EPOCH=$((NOW_EPOCH + 300))  # 5 minutes

# Security: refuse to write if token file is a symlink (symlink attack prevention)
if [ -L "$TOKEN_FILE" ]; then
  echo "ERROR: $TOKEN_FILE is a symlink — refusing to write (possible symlink attack)" >&2
  exit 2
fi

# Security: rotate old history files (keep last 30 days)
find "$HISTORY_DIR" -name "*.json" -mtime +30 -delete 2>/dev/null || true

cat > "$TOKEN_FILE" <<JSON
{
  "created_at": "$NOW_ISO",
  "created_at_epoch": $NOW_EPOCH,
  "expires_at_epoch": $EXPIRES_EPOCH,
  "task_description": $(printf '%s' "$TASK_DESC" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
  "protected_files_allowed": [
    "MDs/Open-Problems.md",
    "MDs/HANDOFF-",
    "docs/context/GOTCHAS.md",
    "docs/context/OPEN-PROBLEMS.md",
    "docs/context/HANDOFF.md",
    "docs/context/MEMORY.md",
    "memory/MEMORY.md",
    "Plans/PLAN.md"
  ]
}
JSON

# Audit log — append to history (never deleted)
HIST_COPY="$HISTORY_DIR/$(date '+%Y%m%d-%H%M%S').json"
cp "$TOKEN_FILE" "$HIST_COPY"

echo "[commit-task-success] Token created"
echo "  task: $TASK_DESC"
echo "  expires: $(date -r $EXPIRES_EPOCH '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d @$EXPIRES_EPOCH '+%Y-%m-%d %H:%M:%S')"
echo "  token:   $TOKEN_FILE"
echo "  audit:   $HIST_COPY"
echo ""
echo "Governance doc edits are now unblocked for the next 5 minutes."
exit 0
