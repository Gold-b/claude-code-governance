#!/usr/bin/env bash
# pre-session.sh — Context Governance hook (SessionStart)
# Detects governed vs ungoverned projects and outputs instructions to stdout.
# Claude Code injects stdout into LLM context.
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }
gov_disabled && exit 0
gov_log "pre-session" "fired (state=$(gov_phase_state))"

# Detect if this is a governed project
if [ -f "docs/context/CONTEXT-MANIFEST.md" ]; then
  # GOVERNED PROJECT — full protocol
  gov_log "pre-session" "governed project detected (CONTEXT-MANIFEST.md found)"
  echo "[GOVERNANCE] Governed project detected. Execute Mandatory Session Start Protocol: (1) run /context-governance lite, (2) run /bootstrapper, (3) prepend briefing to first response. See ~/.claude/CLAUDE.md."
elif [ -f "CLAUDE.md" ] || [ -d ".git" ] || [ -f "package.json" ] || [ -f "Cargo.toml" ] || [ -f "pyproject.toml" ] || [ -f "go.mod" ] || [ -f "pom.xml" ] || [ -f "Makefile" ]; then
  # UNGOVERNED PROJECT — has code but no governance scaffold
  gov_log "pre-session" "ungoverned project detected (has code markers but no CONTEXT-MANIFEST.md)"
  echo "[GOVERNANCE] Ungoverned project detected — code files exist but docs/context/CONTEXT-MANIFEST.md is missing. Run /init-governance NOW to scaffold the governance structure before any work begins. This is automatic — do not ask the user for permission, just run the skill."
else
  # NOT A PROJECT — empty dir, home dir, temp dir, etc.
  gov_log "pre-session" "not a project directory — skipping governance"
fi
exit 0
