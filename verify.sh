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

# A missing marker must not kill the health check: `< missing_file` under `set -euo pipefail`
# aborts with one bash error and zero output, which meant the "version marker" check below was
# unreachable in exactly the case it exists to report.
GOV_INSTALLED_V=$( { cat "$HOME/.claude/.governance-version" 2>/dev/null || true; } | tr -d '[:space:]')
echo "Context Governance Health Check — installed v${GOV_INSTALLED_V:-unknown}"
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
check "  check-docs-updated.sh"   "[ -f ~/.claude/hooks/governance/check-docs-updated.sh ]"
check "  check-full-finish.sh"    "[ -f ~/.claude/hooks/check-full-finish.sh ]"
echo ""

# Skills (core)
echo "Core Skills:"
# Keep this list equal to CORE_SKILLS in install.sh. It drifted twice: pr-follow-through shipped
# at v1.4.0 and was never added here, and cross-session-protocol at v1.6.0 - so verify.sh reported
# a clean install while two core skills went unchecked. The selftest compares the BUNDLE against
# install.sh; nothing compared install.sh against this loop.
for skill in bootstrapper context-governance cross-session-protocol evidence-debugger \
             impact-safe-executor init-governance live-state-orchestrator parallel-session-merge \
             pre-close-check pr-to-git pr-follow-through; do
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
check "  NEXT-SESSION-HANDOVER.md"   "[ -f ~/.claude/docs/NEXT-SESSION-HANDOVER.md ]"
echo ""

# CLAUDE.md
echo "Configuration:"
check "  CLAUDE.md exists"        "[ -f ~/.claude/CLAUDE.md ]"
check "  version marker"          "[ -s ~/.claude/.governance-version ]"
check "  settings.json exists"    "[ -f ~/.claude/settings.json ]"

# Verify hooks are registered in settings.json
if command -v node &>/dev/null; then
  check "  SessionStart hook registered" \
    "node -e \"const s=JSON.parse(require('fs').readFileSync(process.env.HOME+'/.claude/settings.json','utf8')); process.exit(s.hooks?.SessionStart ? 0 : 1)\""
  check "  UserPromptSubmit hook registered" \
    "node -e \"const s=JSON.parse(require('fs').readFileSync(process.env.HOME+'/.claude/settings.json','utf8')); process.exit(s.hooks?.UserPromptSubmit ? 0 : 1)\""
  check "  PreToolUse hook registered" \
    "node -e \"const s=JSON.parse(require('fs').readFileSync(process.env.HOME+'/.claude/settings.json','utf8')); process.exit(s.hooks?.PreToolUse ? 0 : 1)\""
  check "  TaskCompleted hook registered" \
    "node -e \"const s=JSON.parse(require('fs').readFileSync(process.env.HOME+'/.claude/settings.json','utf8')); process.exit(s.hooks?.TaskCompleted ? 0 : 1)\""
  check "  Stop hook registered" \
    "node -e \"const s=JSON.parse(require('fs').readFileSync(process.env.HOME+'/.claude/settings.json','utf8')); process.exit(s.hooks?.Stop ? 0 : 1)\""
  # 2026-09-27: SessionStart hooks block Claude Code's start-up (the VS Code extension fails at 60 s),
  # so pre-session.sh is registered at 10 s or less. 2026-09-30: 2.0.0 has NO automatic update, so a
  # SessionEnd entry that runs gov-update.sh is a FAIL (a machine that still has the old 2.0.0-dev
  # registration clears it by re-running install.sh: settings-merge.js --installed drops it).
  check "  pre-session.sh timeout <= 10 s" \
    "node -e \"const s=JSON.parse(require('fs').readFileSync(process.env.HOME+'/.claude/settings.json','utf8')); const h=(s.hooks?.SessionStart||[]).flatMap(g=>g.hooks||[]).filter(h=>/pre-session\\\\.sh/.test(h.command||'')); process.exit(h.length && h.every(x=>typeof x.timeout==='number' && x.timeout>0 && x.timeout<=10) ? 0 : 1)\""
  check "  no SessionEnd auto-update hook registered" \
    "node -e \"const s=JSON.parse(require('fs').readFileSync(process.env.HOME+'/.claude/settings.json','utf8')); process.exit(!(s.hooks?.SessionEnd||[]).flatMap(g=>g.hooks||[]).some(h=>/gov-update\\\\.sh/.test(h.command||'')) ? 0 : 1)\""
fi
echo ""

# The manual updater and the consent records (2.0.0). Existence checks, like the rest of this file:
# they catch an install that never recorded its trust root or its baseline. The updater itself proves
# far more than this (signature, checksums, file set) before it ever runs verify.sh.
# Heading changed 2026-10-01 (legal review r2, finding 8): 2.0.0 has no automatic update, and the old
# heading named this section after one - a claim printed after every install.
echo "Manual updates and consent records:"
check "  gov-update.sh present"               "[ -f ~/.claude/hooks/governance/gov-update.sh ]"
check "  release key pinned"                  "[ -s ~/.claude/.governance-update/allowed_signers ]"
check "  terms accepted"                      "[ -s ~/.claude/.governance-update/terms-accepted ]"
# 2026-09-30 (C4): install.sh records the push-at-session-close choice (OFF unless the user turned it
# on). Missing = an install that predates the record or never completed: re-run install.sh.
# 2026-10-02 (round 3, B7): on the MAINTAINER's machine install.sh records nothing (push is always on
# there), so the record is not expected and its absence is not a failure - a re-run of install.sh
# could never clear it. The machine is told apart by consent-lib.sh gov_maintainer_machine, the one
# test install.sh uses, sourced from the INSTALLED hooks in a subshell (no second copy of the test).
# 2026-10-02 (verify round 4 #4): the maintainer line says what consent-lib.sh gov_close_push_on says -
# ON, or paused by GOV_CLOSE_PUSH=0 (process env or ~/.claude/.governance-local.env) - never "ON" while
# the predicate that close-push.sh obeys says paused. A pause is not a failure: both count as passed.
VERIFY_MAINTAINER=0; VERIFY_PUSH=""
_vlib="$HOME/.claude/hooks/governance/consent-lib.sh"
if [ -f "$_vlib" ]; then
  VERIFY_PUSH=$( set +eu; . "$_vlib" >/dev/null 2>&1 || exit 0
                 type gov_maintainer_machine >/dev/null 2>&1 && gov_maintainer_machine || exit 0
                 if gov_close_push_on; then printf 'on'; else printf 'paused|%s' "${GOV_CONSENT_REASON:-}"; fi ) || VERIFY_PUSH=""
  [ -n "$VERIFY_PUSH" ] && VERIFY_MAINTAINER=1
fi
if [ "$VERIFY_MAINTAINER" = 1 ] && [ "$VERIFY_PUSH" = "on" ]; then
  printf "${GREEN}✓${NC} %s\n" "  push at close: ON - always, on the maintainer's machine (no record expected)"
  PASS=$((PASS + 1))
elif [ "$VERIFY_MAINTAINER" = 1 ]; then
  _vr="${VERIFY_PUSH#paused|}"
  printf "${GREEN}✓${NC} %s\n" "  push at close: OFF - ${_vr:-paused} (on the maintainer's machine it is otherwise always ON; no record expected)"
  PASS=$((PASS + 1))
else
  check "  push-at-close choice recorded"     "[ -s ~/.claude/.governance-update/close-push ]"
fi
check "  local-modification baseline"         "[ -s ~/.claude/.governance-update/installed.hashes ]"
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
