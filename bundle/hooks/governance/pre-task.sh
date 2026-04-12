#!/usr/bin/env bash
# pre-task.sh — Context Governance hook
# Master Plan §8.2 — fires at UserPromptSubmit (each new user message)
# Purpose: run governance lite + selective context loading scoped to the task
#
# Phase 4 state (current): plumbing live, skills deferred to Phase 5
# Phase 5+ behavior:       invokes context-governance (lite) + scoped load

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0
gov_log "pre-task" "fired (state=$(gov_phase_state))"

if ! gov_skill_exists "context-governance"; then
  gov_log "pre-task" "skill 'context-governance' not installed — Phase 5 deferred, exiting fail-soft"
  exit 0
fi

gov_log "pre-task" "skill present — Phase 5 invocation TBD"
exit 0
