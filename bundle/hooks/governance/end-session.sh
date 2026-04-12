#!/usr/bin/env bash
# end-session.sh — Context Governance hook (Stop event)
# Outputs a reminder to stdout for LLM to write handoff.
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }
gov_disabled && exit 0
gov_log "end-session" "fired (state=$(gov_phase_state))"

# stdout → injected into LLM context by Claude Code harness
echo "[GOVERNANCE] Session ending. Execute end-session protocol: run /live-state-orchestrator to update PLAN.md + MEMORY.md + write HANDOFF.md. See ~/.claude/CLAUDE.md §Mandatory Session Start Protocol Step 5."
exit 0
