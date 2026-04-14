#!/usr/bin/env bash
# pre-write.sh — Context Governance ENFORCEMENT hook (PreToolUse: Edit/Write)
# Deterministic blocking: blocks writes to high-impact files when bootstrapper
# hasn't run (no context = dangerous to edit critical files).
#
# governance-guard.sh handles protected DOCS (GOTCHAS, HANDOFF, etc.).
# This hook handles protected CODE (server.js, config.js, Dockerfile, etc.).
#
# Enforcement logic:
#   Session bootstrapped (marker exists) → exit 0 (warn only)
#   Session NOT bootstrapped → exit 2 (BLOCK writes to high-impact files)
#
# Kill switch: GOVERNANCE_HOOKS=0
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0

# Read the tool input to get target file path
# Security: cap stdin to 64KB to prevent memory exhaustion
PAYLOAD=""
if [ ! -t 0 ]; then
  PAYLOAD=$(head -c 65536 2>/dev/null || true)
fi

if [ -z "$PAYLOAD" ]; then
  exit 0
fi

# Extract file path
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

# High-impact file patterns
HIGH_IMPACT_PATTERNS=(
  "server.js"
  "config.js"
  "docker-compose"
  "Dockerfile"
  ".env"
  "auto-update.ps1"
  "watchdog.js"
)

IS_HIGH_IMPACT=0
MATCHED_PAT=""
for pat in "${HIGH_IMPACT_PATTERNS[@]}"; do
  case "$NORMALIZED" in
    *"$pat"*)
      IS_HIGH_IMPACT=1
      MATCHED_PAT="$pat"
      break
      ;;
  esac
done

if [ "$IS_HIGH_IMPACT" = "0" ]; then
  exit 0
fi

# Check if bootstrapper has run
SESSION_MARKER="$HOME/.claude/logs/.gov-session-bootstrapped"

if [ -f "$SESSION_MARKER" ]; then
  # Bootstrapped — soft warning only (LLM has context)
  gov_log "pre-write" "high-impact file: $FILE_PATH (pattern: $MATCHED_PAT) — bootstrapped, allowing"
  echo "[GOVERNANCE] Writing to high-impact file: $(basename "$FILE_PATH"). Verify assumptions by reading the file first. Check CLAUDE.md for known gotchas related to this file."
  exit 0
fi

# NOT bootstrapped — BLOCK. Cannot safely edit critical files without context.
gov_log "pre-write" "BLOCKED: high-impact file $FILE_PATH without bootstrapper"
echo "[GOVERNANCE ENFORCEMENT] BLOCKED — writing to high-impact file '$(basename "$FILE_PATH")' (matched pattern: $MATCHED_PAT) without bootstrapper context. Run /bootstrapper first, then retry. Editing critical files without project context has caused 5+ silent regressions in the past." >&2
exit 2
