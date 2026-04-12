#!/usr/bin/env bash
# _common.sh — Context Governance hook shared utilities
# Created: 2026-04-11 (Phase 4 of Context Governance rollout)
# Master Plan §8 — sourced by all governance hook scripts in this directory.
#
# Behavior contract:
#   * Always fail-soft. Any error → log + return 0. Hooks must NEVER block work.
#   * Idempotent. Running the same hook twice in a row produces the same result.
#   * Skill-aware. If the corresponding skill is not yet installed (Phase 5
#     deferred), the hook logs the skip and exits 0.
#
# Environment variables:
#   GOVERNANCE_HOOKS         (default: 1)   set to "0" to disable all governance hooks globally
#   GOVERNANCE_LOG           (default: ~/.claude/logs/governance.log) path of the rolling hook log
#   GOVERNANCE_SKILLS_DIR    (default: ~/.claude/skills) where to look for skill definitions

GOVERNANCE_LOG="${GOVERNANCE_LOG:-$HOME/.claude/logs/governance.log}"
GOVERNANCE_HOOKS="${GOVERNANCE_HOOKS:-1}"
GOVERNANCE_SKILLS_DIR="${GOVERNANCE_SKILLS_DIR:-$HOME/.claude/skills}"

# Ensure log dir exists. Failure here is non-fatal — we still try to run.
mkdir -p "$(dirname "$GOVERNANCE_LOG")" 2>/dev/null || true

# gov_log <hook_name> <message>
# Appends a timestamped line to the governance log. Never throws.
gov_log() {
  local hook="$1"
  local msg="$2"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown-time")
  echo "[$ts] [$hook] $msg" >> "$GOVERNANCE_LOG" 2>/dev/null || true
}

# gov_disabled
# Returns 0 (success) if governance hooks are globally disabled (GOVERNANCE_HOOKS=0).
# Use as: `gov_disabled && exit 0`
gov_disabled() {
  if [ "$GOVERNANCE_HOOKS" = "0" ]; then
    return 0
  fi
  return 1
}

# gov_skill_exists <skill_name>
# Returns 0 (success) if the named skill is installed at $GOVERNANCE_SKILLS_DIR/<skill_name>/SKILL.md
gov_skill_exists() {
  local skill="$1"
  if [ -d "$GOVERNANCE_SKILLS_DIR/$skill" ] && [ -f "$GOVERNANCE_SKILLS_DIR/$skill/SKILL.md" ]; then
    return 0
  fi
  return 1
}

# gov_phase_state
# Echoes a one-word state describing what Phase 4 vs Phase 5 should expect.
# Used for diagnostic logging.
gov_phase_state() {
  if gov_skill_exists "context-governance"; then
    echo "phase5+"
  else
    echo "phase4-plumbing"
  fi
}
