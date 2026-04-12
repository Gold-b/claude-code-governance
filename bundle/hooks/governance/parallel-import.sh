#!/usr/bin/env bash
# parallel-import.sh — Context Governance hook
# Master Plan §8.7 — fires when output from a parallel session (other Claude/GPT) is imported
# Purpose: invoke parallel-session-merge to detect overlaps + advance canonical state
#
# Phase 4 state (current): plumbing live, no auto-trigger wired in settings.json
# Phase 5+ behavior:       invokes parallel-session-merge skill
#
# Note: there is no native Claude Code event for "user pasted external content".
# This hook is intentionally NOT registered under any event in settings.json.
# It is meant to be invoked manually when the user pastes a session dump from
# another agent (e.g. "here is what GPT told me, merge it"). Phase 5 may add
# heuristic detection in pre-task.sh to auto-trigger this when a paste is large
# and contains session-like markers.

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0
gov_log "parallel-import" "fired (state=$(gov_phase_state))"

if ! gov_skill_exists "parallel-session-merge"; then
  gov_log "parallel-import" "skill 'parallel-session-merge' not installed — Phase 5 deferred, exiting fail-soft"
  exit 0
fi

gov_log "parallel-import" "skill present — Phase 5 merge invocation TBD"
exit 0
