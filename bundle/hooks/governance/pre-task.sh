#!/usr/bin/env bash
# pre-task.sh — Context Governance enforcement hook (UserPromptSubmit)
# Ensures bootstrapper runs at session start. Never blocks (exit 2) to avoid
# deadlocks — previous design relied on LLM to `touch` a marker file, but LLM
# was unreliable, causing exit 2 on 2nd+ prompts → silent response drop.
#
# Enforcement logic:
#   1st prompt  → auto-create marker + exit 0 + MANDATORY bootstrapper instruction
#   2nd+ prompt → exit 0 (marker already exists)
#   Edge case   → marker missing on 2nd+ prompt: auto-create + warn + exit 0
#
# Session marker: ~/.claude/logs/.gov-session-bootstrapped
#   Created by: this hook (auto-created on 1st prompt)
#   Deleted by: pre-session.sh on every new session
#
# Prompt counter: ~/.claude/logs/.gov-session-prompt-count
#   Incremented on every UserPromptSubmit. Reset by pre-session.sh.
#
# Kill switch: GOVERNANCE_HOOKS=0
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0

# Read the payload once and resolve the project it is ABOUT, before anything branches on it.
# Sets GOV_PROJECT_ROOT. Without this, `gov_state_file` drains stdin inside a subshell and
# every governed-project test below silently falls back to $PWD - which resolves to the
# USER-LEVEL ~/.claude/CLAUDE.md whenever the session's shell is standing there.
gov_prime_payload

# Node-role gate (Framework v2): only enforce on SOURCE.
gov_role_guard SOURCE

SESSION_MARKER="$(gov_state_file .gov-session-bootstrapped)"
PROMPT_COUNTER="$(gov_state_file .gov-session-prompt-count)"

# Not a governed project — skip enforcement
if ! gov_is_governed "$GOV_PROJECT_ROOT" && [ ! -f "$GOV_PROJECT_ROOT/CLAUDE.md" ]; then
  exit 0
fi

# Already bootstrapped — lightweight staleness check only
if [ -f "$SESSION_MARKER" ]; then
  if gov_is_governed "$GOV_PROJECT_ROOT"; then
    exit 0
  else
    gov_log "pre-task" "WARNING: CONTEXT-MANIFEST.md disappeared mid-session"
    echo "[GOVERNANCE WARNING] docs/context/CONTEXT-MANIFEST.md was deleted or moved during this session. Run /context-governance lite to diagnose."
    exit 0
  fi
fi

# --- Bootstrapper has NOT run yet — count prompts ---
COUNT=1
if [ -f "$PROMPT_COUNTER" ]; then
  COUNT=$(cat "$PROMPT_COUNTER" 2>/dev/null | tr -dc '0-9')
  COUNT=$((COUNT + 1))
fi
echo "$COUNT" > "$PROMPT_COUNTER" 2>/dev/null

if [ "$COUNT" -le 1 ]; then
  # First prompt — allow through and CREATE the marker to prevent deadlock.
  # Previous design relied on LLM to `touch` the marker, but LLM is unreliable
  # at following through — caused deadlock where exit 2 blocked all future prompts.
  touch "$SESSION_MARKER" 2>/dev/null
  gov_log "pre-task" "first prompt — allowing through with MANDATORY instruction (marker auto-created)"
  echo "[GOVERNANCE ENFORCEMENT] The /bootstrapper skill has NOT been executed yet in this session. You MUST run /context-governance lite followed by /bootstrapper BEFORE answering the user's question. This is mandatory per the Session Start Protocol."
  exit 0
fi

# 2nd+ prompt without marker — should not happen now (marker auto-created on 1st prompt).
# If it does, allow through with a warning instead of blocking (exit 2 caused deadlocks).
gov_log "pre-task" "WARNING: prompt #$COUNT without marker (unexpected — auto-creating)"
touch "$SESSION_MARKER" 2>/dev/null
echo "[GOVERNANCE WARNING] Session marker was missing on prompt #$COUNT. This is unexpected. Ensure /bootstrapper was run. Marker has been auto-created to prevent deadlock."
exit 0
