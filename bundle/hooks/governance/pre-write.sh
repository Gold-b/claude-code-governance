#!/usr/bin/env bash
# pre-write.sh — Context Governance hook
# Master Plan §8.3 — fires at PreToolUse for Edit/Write/MultiEdit/NotebookEdit tools
# Purpose: run impact-safe-executor's impact map check before any file write
#
# Phase 4 state (current): plumbing live, skills deferred to Phase 5
# Phase 5+ behavior:       invokes impact-safe-executor impact map; may pause for approval

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0
gov_log "pre-write" "fired (state=$(gov_phase_state))"

if ! gov_skill_exists "impact-safe-executor"; then
  gov_log "pre-write" "skill 'impact-safe-executor' not installed — Phase 5 deferred, exiting fail-soft"
  exit 0
fi

# Phase 5+ would invoke impact-safe-executor here. Note: this hook MUST stay
# fail-soft. Even when Phase 5 wires the real check, an internal failure must
# never block the user's edit — the check warns, it does not block.
gov_log "pre-write" "skill present — Phase 5 invocation TBD"
exit 0
