#!/usr/bin/env bash
# pre-done.sh — Context Governance hook
# Master Plan §8.5 — fires before a task is marked DONE
# Purpose: run the Verification Gate; require external evidence before DONE
#
# Phase 4 state (current): plumbing live, no auto-trigger wired in settings.json
# Phase 5+ behavior:       invokes context-governance verification gate
#
# Note: this hook has no native Claude Code event mapping. It is intentionally
# NOT registered in settings.json under any event type. It is meant to be
# invoked manually by other scripts or by Phase 5 skills that detect a "task
# completion" signal. Until Phase 5 wires it, it can also be called from a
# user's terminal as a sanity check.

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0
gov_log "pre-done" "fired (state=$(gov_phase_state))"

if ! gov_skill_exists "context-governance"; then
  gov_log "pre-done" "skill 'context-governance' not installed — Phase 5 deferred, exiting fail-soft"
  exit 0
fi

gov_log "pre-done" "skill present — Phase 5 verification gate invocation TBD"
exit 0
