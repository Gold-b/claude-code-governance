#!/usr/bin/env bash
# parallel-import.sh — Context Governance hook
# Master Plan §8.7 — detects when output from a parallel session is pasted.
# Wired to UserPromptSubmit — checks if the user's message contains
# session-like markers (handoff headers, session dump markers, agent output).
#
# If detected, outputs instruction to run /parallel-session-merge.
# If not detected, exits silently.

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0

# Not a governed project — skip
if [ ! -f "docs/context/CONTEXT-MANIFEST.md" ]; then
  exit 0
fi

# Read user prompt from stdin (JSON: {"prompt":"...","session_id":"...","cwd":"...",...})
if [ -t 0 ]; then
  exit 0
fi

RAW_INPUT=$(cat 2>/dev/null || echo "")
if [ -z "$RAW_INPUT" ]; then
  exit 0
fi

# Extract only the user's typed message from the JSON payload.
# Use exit code to distinguish "extraction failed" from "prompt is empty".
INPUT=$(echo "$RAW_INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('prompt', ''))
except Exception:
    sys.exit(1)
" 2>/dev/null)
PY_RC=$?
# Fallback only if python3 genuinely failed (non-zero exit), not on empty prompt
if [ "$PY_RC" -ne 0 ]; then
  INPUT="$RAW_INPUT"
fi
# Empty prompt = nothing to analyze, skip
[ -z "$INPUT" ] && exit 0

# Heuristic: detect session-like content in the user's message
# Look for markers that suggest pasted output from another AI session
MARKERS=0
echo "$INPUT" | grep -qi "handoff\|session.*dump\|GPT.*said\|claude.*output\|from.*another.*session\|merge.*this\|HANDOFF-v" && MARKERS=$((MARKERS + 1))
echo "$INPUT" | grep -qi "status:.*active\|consumed_at\|remaining_items\|superseded_by" && MARKERS=$((MARKERS + 1))

# Also detect large pastes (>2000 chars) with code-like content
INPUT_LEN=${#INPUT}
if [ "$INPUT_LEN" -gt 2000 ]; then
  echo "$INPUT" | grep -qiE 'def |function |class |import |const |module\.' && MARKERS=$((MARKERS + 1))
fi

if [ "$MARKERS" -ge 2 ]; then
  gov_log "parallel-import" "WARNING: parallel session content detected ($MARKERS markers, $INPUT_LEN chars)"

  # Show popup notification
  gov_notify \
    "סשן מקביל" \
    "זוהה תוכן מסשן מקביל. מומלץ לרוץ merge לפני עבודה." \
    "/parallel-session-merge"

  # NEVER exit 2 on UserPromptSubmit — causes deadlock (user gets no response).
  echo "[GOVERNANCE WARNING] Detected content that may be from another AI session ($MARKERS indicators). Consider running /parallel-session-merge to reconcile with current project state before applying changes blindly."
  exit 0
fi

exit 0
