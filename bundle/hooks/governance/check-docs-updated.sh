#!/usr/bin/env bash
# check-docs-updated.sh — Enforce documentation on tasks that change code (project-relative).
# Fires on: TaskCompleted.
#
# Purpose: if code files were written this session but NO governance doc was updated, emit an
# ADVISORY reminding the agent to document gotchas/memory/handoff. Generic across ALL governed
# projects: detects the project root by walking up to CLAUDE.md and reads the per-session write
# log (~/.claude/logs/.gov-session-changes). The HARD block stays at session end (end-session.sh
# Check 0); this per-task hook only reminds. Escalation: post-milestone reminds -> end-session blocks.
#
# Rewritten 2026-06-18: removed the machine-specific hardcoding (one project name, one checkout
# path and one session-log slug) that made it inert (or made it audit the wrong repo) on every
# other project.
#
# Kill switch: GOVERNANCE_HOOKS=0
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || true
command -v gov_disabled >/dev/null 2>&1 && gov_disabled && exit 0
if [ "${GOVERNANCE_HOOKS:-1}" = "0" ]; then [ "${GOV_BYPASS_QUIET:-0}" = "1" ] || echo "[governance] GOVERNANCE_HOOKS=0 — bypassing check-docs-updated. (GOV_BYPASS_QUIET=1 to mute)" >&2; exit 0; fi

# --- Detect project root (walk up to CLAUDE.md) ---
PROJECT_ROOT="$PWD"
if [ ! -f "$PROJECT_ROOT/CLAUDE.md" ]; then
  d="$PROJECT_ROOT"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ -f "$d/CLAUDE.md" ]; then PROJECT_ROOT="$d"; break; fi
    d="$(dirname "$d")"
  done
fi

# --- Only governed projects ---
[ -f "$PROJECT_ROOT/docs/context/CONTEXT-MANIFEST.md" ] || exit 0

# --- Signal: the per-session write log (same source post-milestone.sh / end-session.sh use) ---
CHANGES_LOG="$(gov_state_file .gov-session-changes)"
[ -f "$CHANGES_LOG" ] || exit 0

HAS_CODE=0
HAS_DOC=0
grep -qiE '\.(js|ts|tsx|jsx|mjs|cjs|json|sh|ps1|bat|py|go|rs|java|rb|php|c|cpp|h|hpp|css|sql)$' "$CHANGES_LOG" 2>/dev/null && HAS_CODE=1
grep -qiE 'GOTCHAS\.md|MEMORY\.md|HANDOFF\.md|OPEN-PROBLEMS\.md|CONVENTIONS\.md|/memory/' "$CHANGES_LOG" 2>/dev/null && HAS_DOC=1

# --- Code changed but no docs updated -> ADVISORY (never hard-blocks at the task level) ---
if [ "$HAS_CODE" -eq 1 ] && [ "$HAS_DOC" -eq 0 ]; then
  command -v gov_notify >/dev/null 2>&1 && gov_notify \
    "תיעוד חסר" \
    "קוד שונה בסשן ללא עדכון תיעוד. תעד ממצאים." \
    "documentation" 2>/dev/null || true
  cat >&2 <<ERRMSG
[doc-check] Code files were modified this session but NO governance doc was updated.
Update at least ONE of (under docs/context/): GOTCHAS.md · MEMORY.md (or a memory file) · OPEN-PROBLEMS.md · HANDOFF.md.
Rule: "Document at moment of discovery, not after." (Advisory — the hard gate is at session end. Override with GOVERNANCE_HOOKS=0.)
ERRMSG
fi
exit 0
