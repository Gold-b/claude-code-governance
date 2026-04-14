#!/usr/bin/env bash
# check-docs-updated.sh — Enforce documentation on every task that changes code
# Fires on: TaskCompleted
# Purpose: If code files were modified but NO documentation was updated,
#          emit a WARNING reminding the agent to document gotchas/memory/handoff.
#
# This hook enforces the rule: "Document at moment of discovery, not after."
# Created: 2026-04-12 (user feedback: documentation must be automatic, not reminded)

set -euo pipefail

# Source _common.sh for gov_notify (best-effort — don't fail if missing)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || true

# --- Config ---
SOURCE_REPO="/c/openclaw-docker"
GOTCHAS="docs/context/GOTCHAS.md"
OPEN_PROBLEMS="MDs/Open-Problems.md"
MEMORY_DIR="$HOME/.claude/projects/c--GoldB-Agent/memory"

# --- Check if we're in a governed project ---
if [[ ! -d "$SOURCE_REPO/.git" ]]; then
  exit 0
fi

cd "$SOURCE_REPO"

# --- Detect uncommitted code changes ---
CODE_CHANGES=$(git diff --name-only -- '*.js' '*.ts' '*.json' '*.ps1' '*.sh' '*.bat' 'patches/' 'admin/' 'enrichment/' 'watchdog/' 'watchdog-remote/' 2>/dev/null | head -20)

if [[ -z "$CODE_CHANGES" ]]; then
  # No code changes — nothing to document
  exit 0
fi

# --- Detect if documentation was also updated ---
DOC_CHANGES=$(git diff --name-only -- "$GOTCHAS" "$OPEN_PROBLEMS" 'MDs/HANDOFF-*.md' 'docs/context/MEMORY.md' 2>/dev/null | head -10)

# Also check if any memory files were created/modified recently (last 5 min)
RECENT_MEMORY=0
if [[ -d "$MEMORY_DIR" ]]; then
  RECENT_MEMORY=$(find "$MEMORY_DIR" -maxdepth 1 -name '*.md' -newer "$MEMORY_DIR/MEMORY.md" -mmin -5 2>/dev/null | wc -l)
fi

if [[ -n "$DOC_CHANGES" ]] || [[ "$RECENT_MEMORY" -gt 0 ]]; then
  # Documentation was updated — all good
  exit 0
fi

# --- Code changed but no docs updated — BLOCK ---
NUM_FILES=$(echo "$CODE_CHANGES" | wc -l)

# Show popup notification for missing docs
gov_notify \
  "תיעוד חסר" \
  "${NUM_FILES} קבצי קוד שונו ללא עדכון תיעוד. יש לתעד ממצאים." \
  "Documentation" 2>/dev/null || true

cat >&2 <<ERRMSG
[doc-check] BLOCKED: $NUM_FILES code file(s) modified but NO documentation updated.
Changed files: $(echo "$CODE_CHANGES" | tr '\n' ', ' | sed 's/,$//')

Before this task can complete, you MUST update at least ONE of:
  1. docs/context/GOTCHAS.md (if bugs/pitfalls discovered)
  2. Memory files (for decisions/lessons learned)
  3. MDs/Open-Problems.md (if issues resolved or discovered)

Rule: 'Document at moment of discovery, not after.'

If this is a truly trivial change (typo, formatting), override with GOVERNANCE_HOOKS=0.
ERRMSG
exit 2
