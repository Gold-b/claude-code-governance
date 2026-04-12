#!/usr/bin/env bash
# pre-write.sh — Context Governance hook (PreToolUse: Edit/Write)
# Fires before every file write. Lightweight — governance-guard.sh does the
# heavy blocking for protected docs. This hook adds a soft reminder for
# high-impact files.
#
# NOTE: This hook must NEVER block (exit 0 always). It warns, not blocks.
# governance-guard.sh is the blocker for protected docs.

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0

# Read the tool input to get target file path
PAYLOAD=""
if [ ! -t 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
fi

if [ -z "$PAYLOAD" ]; then
  exit 0
fi

# Extract file path (same approach as governance-guard.sh)
FILE_PATH=$(printf '%s' "$PAYLOAD" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input", {}) or {}
    fp = ti.get("file_path") or ti.get("path") or ""
    print(fp)
except Exception:
    print("")
' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

NORMALIZED=$(printf '%s' "$FILE_PATH" | tr '\\' '/')

# High-impact file patterns — soft warning (not a block)
HIGH_IMPACT_PATTERNS=(
  "server.js"
  "config.js"
  "docker-compose"
  "Dockerfile"
  ".env"
)

for pat in "${HIGH_IMPACT_PATTERNS[@]}"; do
  case "$NORMALIZED" in
    *"$pat"*)
      gov_log "pre-write" "high-impact file detected: $FILE_PATH (pattern: $pat)"
      # Soft warning — stdout goes to LLM context
      echo "[GOVERNANCE] Writing to high-impact file: $(basename "$FILE_PATH"). Verify assumptions by reading the file first. Check CLAUDE.md for known gotchas related to this file."
      exit 0
      ;;
  esac
done

exit 0
