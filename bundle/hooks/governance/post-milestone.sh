#!/usr/bin/env bash
# post-milestone.sh — Context Governance hook
# Master Plan §8.4 — fires after a milestone is completed
# Purpose: invoke live-state-orchestrator to update PLAN/MEMORY/OPEN-PROBLEMS
#
# Phase 4 state (current): plumbing live, skills deferred to Phase 5
# Phase 5+ behavior:       invokes live-state-orchestrator
#
# Note: in Claude Code, "milestone" is not a native event. This hook is wired
# to PostToolUse in Phase 4 settings.json with no matcher — i.e. it fires after
# every successful tool use. Phase 5 will refine the trigger logic (e.g. only
# fire after a sequence of edits, not after every single one).

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0
gov_log "post-milestone" "fired (state=$(gov_phase_state))"

if ! gov_skill_exists "live-state-orchestrator"; then
  # Quiet log — this hook fires very frequently in Phase 4, do not spam
  exit 0
fi

gov_log "post-milestone" "skill present — Phase 5 invocation TBD"
exit 0
