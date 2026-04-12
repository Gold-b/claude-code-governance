#!/usr/bin/env bash
# end-session.sh — Context Governance ENFORCEMENT hook (Stop event)
# BLOCKS session stop if governance files are stale.
#
# Phase 4 (2026-04-11): passive reminder ("please run /live-state-orchestrator")
# Phase 5+ (2026-04-12): blocking enforcement (exit 2 + detailed directives).
#
# Checks:
#   1. PLAN.md version matches version.json
#   2. MEMORY.md version matches version.json
#   3. A handoff exists for the current version (or is pointed to by HANDOFF.md)
#
# On failure: exit 2 (blocks stop) + stderr explains WHY blocked +
#   stdout gives the LLM EXACT instructions on what to fix.
#
# Kill switch: GOVERNANCE_HOOKS=0
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }
gov_disabled && exit 0

# --- Step 0: Run sync-governance.sh to auto-fix version/count drift ---
# This runs BEFORE checks, so mechanical drift is fixed automatically.
# Only handoff (which requires LLM content) can't be auto-fixed.
if [ -f "$SCRIPT_DIR/sync-governance.sh" ]; then
  bash "$SCRIPT_DIR/sync-governance.sh" 2>/dev/null || true
fi

# --- Detect project root (walk up to find CLAUDE.md) ---
PROJECT_ROOT="$PWD"
if [ ! -f "$PROJECT_ROOT/CLAUDE.md" ]; then
  d="$PROJECT_ROOT"
  while [ "$d" != "/" ] && [ "$d" != "" ]; do
    if [ -f "$d/CLAUDE.md" ]; then PROJECT_ROOT="$d"; break; fi
    d="$(dirname "$d")"
  done
fi

# --- Only governed projects ---
if [ ! -f "$PROJECT_ROOT/docs/context/CONTEXT-MANIFEST.md" ]; then
  gov_log "end-session" "not governed — skip"
  exit 0
fi

# --- Need version.json to compare ---
if [ ! -f "$PROJECT_ROOT/version.json" ]; then
  gov_log "end-session" "no version.json — skip version check"
  exit 0
fi

# --- Extract current version from version.json ---
VJ_VER=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PROJECT_ROOT/version.json" 2>/dev/null \
  | grep -o '[0-9][0-9.]*')
if [ -z "$VJ_VER" ]; then
  gov_log "end-session" "could not parse version.json — skip (fail-soft)"
  exit 0
fi

ISSUES=""
DIRECTIVES=""

# --- Check 1: PLAN.md version ---
if [ -f "$PROJECT_ROOT/Plans/PLAN.md" ]; then
  PLAN_VER=$(grep -o 'Project version:.*v[0-9][0-9.]*' "$PROJECT_ROOT/Plans/PLAN.md" 2>/dev/null \
    | grep -o '[0-9][0-9.]*' | head -1)
  if [ -n "$PLAN_VER" ] && [ "$VJ_VER" != "$PLAN_VER" ]; then
    ISSUES="${ISSUES}\n  - Plans/PLAN.md says v${PLAN_VER}, version.json says v${VJ_VER}"
    DIRECTIVES="${DIRECTIVES}\n  (a) Update Plans/PLAN.md: change 'Project version: v${PLAN_VER}' to 'Project version: v${VJ_VER}'. Add milestone log entries for every version between v${PLAN_VER} and v${VJ_VER} (read git log to get details). Update sub-plan statuses if they changed."
  fi
fi

# --- Check 2: MEMORY.md version ---
if [ -f "$PROJECT_ROOT/docs/context/MEMORY.md" ]; then
  MEM_VER=$(grep -o 'Project version:.*v[0-9][0-9.]*' "$PROJECT_ROOT/docs/context/MEMORY.md" 2>/dev/null \
    | grep -o '[0-9][0-9.]*' | head -1)
  if [ -n "$MEM_VER" ] && [ "$VJ_VER" != "$MEM_VER" ]; then
    ISSUES="${ISSUES}\n  - docs/context/MEMORY.md says v${MEM_VER}, version.json says v${VJ_VER}"
    DIRECTIVES="${DIRECTIVES}\n  (b) Update docs/context/MEMORY.md Active Summary: change version to v${VJ_VER}, update phase status, update active handoff reference, add any new durable decisions or lessons learned from this session."
  fi
fi

# --- Check 3: Handoff for current version ---
HANDOFF_EXISTS=0
if [ -f "$PROJECT_ROOT/docs/context/HANDOFF.md" ]; then
  # Check if pointer references current version
  HANDOFF_POINTS=$(grep -o 'HANDOFF-v[0-9][0-9.]*' "$PROJECT_ROOT/docs/context/HANDOFF.md" 2>/dev/null \
    | grep -o '[0-9][0-9.]*' | head -1)
  if [ -n "$HANDOFF_POINTS" ] && [ "$VJ_VER" = "$HANDOFF_POINTS" ]; then
    HANDOFF_EXISTS=1
  fi
fi
# Also check MDs/ directly for a handoff file with current version
if [ $HANDOFF_EXISTS -eq 0 ]; then
  if ls "$PROJECT_ROOT"/MDs/HANDOFF-v${VJ_VER}* 1>/dev/null 2>&1; then
    HANDOFF_EXISTS=1
  fi
fi
if [ $HANDOFF_EXISTS -eq 0 ]; then
  ISSUES="${ISSUES}\n  - No handoff found for v${VJ_VER} (docs/context/HANDOFF.md points to v${HANDOFF_POINTS:-unknown})"
  DIRECTIVES="${DIRECTIVES}\n  (c) Create a new handoff at MDs/HANDOFF-v${VJ_VER}.md with: session summary, current state, open work, exact next action, and read-these-first list. Then update docs/context/HANDOFF.md pointer to reference it. Archive the previous handoff to MDs/archive/ with status: consumed."
fi

# --- Enforce ---
if [ -n "$ISSUES" ]; then
  gov_log "end-session" "BLOCKED: governance stale —$(echo -e "$ISSUES" | tr '\n' ' ')"

  # stderr → shown as hook error (blocks the stop)
  printf "[end-session] BLOCKED — governance files are stale. Fix before stopping.\n" >&2

  # stdout → injected into LLM context as detailed instructions
  cat <<ENDMSG

[GOVERNANCE-ENFORCEMENT] Session stop BLOCKED. Governance files are out of date.

Current version (version.json): v${VJ_VER}

Problems found:
$(printf '%b' "$ISSUES")

Required actions BEFORE you can stop:
$(printf '%b' "$DIRECTIVES")

IMPORTANT:
- Edit files in the SOURCE repo (C:\\openclaw-docker\\) first, then copy to client (C:\\GoldB-Agent\\).
- You need a governance success token to edit protected files:
    bash ~/.claude/hooks/governance/commit-task-success.sh "<description>"
- After fixing all issues, try stopping the session again. This hook will re-check.
- If you believe this is a false positive, the user can override with: GOVERNANCE_HOOKS=0

ENDMSG
  exit 2
fi

# --- All checks passed ---
gov_log "end-session" "passed — PLAN v${PLAN_VER:-?} MEMORY v${MEM_VER:-?} HANDOFF v${HANDOFF_POINTS:-?} == version.json v${VJ_VER}"

# Passed checks — still output a gentle reminder for handoff quality
cat <<ENDMSG
[GOVERNANCE] Session ending cleanly. Version alignment verified (v${VJ_VER}).
Before final stop, ensure your handoff at docs/context/HANDOFF.md covers:
- What was done this session
- What is still open
- Exact next action for the next session
ENDMSG
exit 0
