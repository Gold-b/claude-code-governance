#!/usr/bin/env bash
# verify.sh — Quick health check for governance installation
# Run after Claude Code updates to confirm everything survived.
# Usage: bash ~/.claude/governance-installer/verify.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0

check() {
  if eval "$2" &>/dev/null; then
    printf "${GREEN}✓${NC} %s\n" "$1"
    PASS=$((PASS + 1))
  else
    printf "${RED}✗${NC} %s\n" "$1"
    FAIL=$((FAIL + 1))
  fi
}

warn_check() {
  if eval "$2" &>/dev/null; then
    printf "${GREEN}✓${NC} %s\n" "$1"
    PASS=$((PASS + 1))
  else
    printf "${YELLOW}⚠${NC} %s (optional)\n" "$1"
    WARN=$((WARN + 1))
  fi
}

echo "Context Governance Health Check"
echo "================================"
echo ""

# Hooks
echo "Hooks:"
check "  _common.sh"              "[ -f ~/.claude/hooks/governance/_common.sh ]"
check "  pre-session.sh"          "[ -f ~/.claude/hooks/governance/pre-session.sh ]"
check "  pre-task.sh"             "[ -f ~/.claude/hooks/governance/pre-task.sh ]"
check "  governance-guard.sh"     "[ -f ~/.claude/hooks/governance/governance-guard.sh ]"
check "  pre-write.sh"            "[ -f ~/.claude/hooks/governance/pre-write.sh ]"
check "  post-milestone.sh"       "[ -f ~/.claude/hooks/governance/post-milestone.sh ]"
check "  end-session.sh"          "[ -f ~/.claude/hooks/governance/end-session.sh ]"
check "  commit-task-success.sh"  "[ -f ~/.claude/hooks/governance/commit-task-success.sh ]"
check "  check-full-finish.sh"    "[ -f ~/.claude/hooks/check-full-finish.sh ]"
echo ""

# Skills (core)
echo "Core Skills:"
for skill in bootstrapper context-governance evidence-debugger impact-safe-executor \
             init-governance live-state-orchestrator parallel-session-merge; do
  check "  $skill" "[ -f ~/.claude/skills/$skill/SKILL.md ]"
done
echo ""

# Skills (extended)
echo "Extended Skills:"
for skill in plan-and-execute qa-sec multi-agents full-finish enable-remote-code; do
  warn_check "  $skill" "[ -f ~/.claude/skills/$skill/SKILL.md ]"
done
echo ""

# Docs
echo "Docs:"
check "  GOVERNANCE-AGENT-GUIDE.md"  "[ -f ~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md ]"
check "  GOVERNANCE-HUMAN-GUIDE.md"  "[ -f ~/.claude/docs/GOVERNANCE-HUMAN-GUIDE.md ]"
echo ""

# CLAUDE.md
echo "Configuration:"
check "  CLAUDE.md exists"        "[ -f ~/.claude/CLAUDE.md ]"
check "  settings.json exists"    "[ -f ~/.claude/settings.json ]"

# Verify hooks are registered in settings.json
if command -v node &>/dev/null; then
  check "  SessionStart hook registered" \
    "node -e \"const s=JSON.parse(require('fs').readFileSync(process.env.HOME+'/.claude/settings.json','utf8')); process.exit(s.hooks?.SessionStart ? 0 : 1)\""
  check "  UserPromptSubmit hook registered" \
    "node -e \"const s=JSON.parse(require('fs').readFileSync(process.env.HOME+'/.claude/settings.json','utf8')); process.exit(s.hooks?.UserPromptSubmit ? 0 : 1)\""
  check "  PreToolUse hook registered" \
    "node -e \"const s=JSON.parse(require('fs').readFileSync(process.env.HOME+'/.claude/settings.json','utf8')); process.exit(s.hooks?.PreToolUse ? 0 : 1)\""
  check "  Stop hook registered" \
    "node -e \"const s=JSON.parse(require('fs').readFileSync(process.env.HOME+'/.claude/settings.json','utf8')); process.exit(s.hooks?.Stop ? 0 : 1)\""
fi
echo ""

# Log directory
echo "Runtime:"
check "  logs directory exists"   "[ -d ~/.claude/logs ]"
warn_check "  governance.log exists"   "[ -f ~/.claude/logs/governance.log ]"
echo ""

# Summary
echo "================================"
printf "Results: ${GREEN}%d passed${NC}" "$PASS"
[ "$WARN" -gt 0 ] && printf ", ${YELLOW}%d warnings${NC}" "$WARN"
[ "$FAIL" -gt 0 ] && printf ", ${RED}%d FAILED${NC}" "$FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo ""
  printf "${RED}Some checks failed.${NC} Run: bash ~/.claude/governance-installer/install.sh\n"
  exit 1
fi

if [ "$WARN" -gt 0 ]; then
  echo ""
  printf "${YELLOW}Optional components missing.${NC} Run: bash ~/.claude/governance-installer/install.sh (without --core-only)\n"
fi

exit 0
