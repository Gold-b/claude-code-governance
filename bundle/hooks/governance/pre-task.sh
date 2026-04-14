#!/usr/bin/env bash
# pre-task.sh — Context Governance ENFORCEMENT hook (UserPromptSubmit)
# Deterministic blocking: allows first prompt (so LLM can run bootstrapper),
# blocks all subsequent prompts if bootstrapper hasn't executed.
#
# Enforcement logic:
#   1st prompt  → exit 0 + MANDATORY instruction (LLM must run bootstrapper)
#   2nd+ prompt → exit 2 (BLOCK) if session marker still missing
#
# Session marker: ~/.claude/logs/.gov-session-bootstrapped
#   Created by: /bootstrapper skill or manual `touch`
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

SESSION_MARKER="$HOME/.claude/logs/.gov-session-bootstrapped"
PROMPT_COUNTER="$HOME/.claude/logs/.gov-session-prompt-count"

# Not a governed project — skip enforcement
if [ ! -f "docs/context/CONTEXT-MANIFEST.md" ] && [ ! -f "CLAUDE.md" ]; then
  exit 0
fi

# Already bootstrapped — lightweight staleness check only
if [ -f "$SESSION_MARKER" ]; then
  if [ -f "docs/context/CONTEXT-MANIFEST.md" ]; then
    exit 0
  else
    gov_log "pre-task" "WARNING: CONTEXT-MANIFEST.md disappeared mid-session"
    echo "[GOVERNANCE WARNING] docs/context/CONTEXT-MANIFEST.md was deleted or moved during this session. Run /context-governance lite to diagnose." >&2
    exit 2
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
  # First prompt — allow through so LLM can execute bootstrapper
  gov_log "pre-task" "first prompt — allowing through with MANDATORY instruction"
  echo "[GOVERNANCE ENFORCEMENT] The /bootstrapper skill has NOT been executed yet in this session. You MUST run /context-governance lite followed by /bootstrapper BEFORE answering the user's question. This is mandatory per the Session Start Protocol. After running bootstrapper, create the session marker: touch ~/.claude/logs/.gov-session-bootstrapped"
  exit 0
fi

# 2nd+ prompt — BLOCK. Bootstrapper should have run by now.
gov_log "pre-task" "BLOCKED: prompt #$COUNT without bootstrapper (session marker missing)"
echo "[GOVERNANCE ENFORCEMENT] BLOCKED — prompt #$COUNT received but /bootstrapper has NOT been executed. The first prompt was allowed through with a MANDATORY instruction to run bootstrapper. That instruction was not followed. Run /context-governance lite + /bootstrapper NOW. Then: touch ~/.claude/logs/.gov-session-bootstrapped" >&2
exit 2
