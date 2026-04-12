#!/usr/bin/env bash
# pre-task.sh — Context Governance hook (UserPromptSubmit)
# Fires on every user message. Outputs a lightweight governance check reminder.
# Throttled to once per session start (not every message).

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0
gov_log "pre-task" "fired (state=$(gov_phase_state))"

# pre-session.sh already handles the heavy lifting (governance detection + briefing).
# pre-task.sh is for per-message checks. Currently: no-op (governance-guard.sh
# handles the critical per-write checks). Future: scoped context reload per task.
exit 0
