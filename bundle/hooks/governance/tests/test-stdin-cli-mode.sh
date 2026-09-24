#!/usr/bin/env bash
# test-stdin-cli-mode.sh - hand-run tools never block on an open stdin; hooks still read their payload.
#
# WHY (2026-09-24). _common.sh primes the hook payload by reading stdin to EOF the moment it is
# sourced. Right for a hook (Claude Code writes the payload and closes the pipe); fatal for a tool
# run by hand from a shell whose stdin stays open - it waited forever. Measured: rc=124 for
# end-session.sh --publish-preview, close-report.sh --help, sync-governance-copies.sh --sync-all.
# The fix skips priming when the sourcing script's first argument is a `--flag`, except the flag a
# REGISTERED hook uses (--sync-if-drifted). Both directions are asserted: a skip that also ate real
# payloads would silently fail every guard open.
#
# Sandboxed HOME. Usage: bash tests/test-stdin-cli-mode.sh   (HOOKS=<dir> to test another copy)
HOOKS="${HOOKS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
exec </dev/null
SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT
H="$SBX/home"; mkdir -p "$H/.claude/logs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s  -- %s\n' "$1" "$2"; }

[ -f "$HOOKS/_common.sh" ] || { bad "hooks dir" "no _common.sh under $HOOKS"; echo "$PASS passed, $FAIL failed"; exit 1; }

# sid <mode-arg> : source _common.sh the way a script invoked with <mode-arg> would, payload on stdin
sid() { printf '{"session_id":"sid-%s"}' "${1:-none}" \
  | HOME="$H" bash -c ". '$HOOKS/_common.sh'; gov_session_id" _ ${1:+"$1"} 2>/dev/null; }

echo "== 1. payload is still read where a payload exists"
[ "$(sid)" = "sid-none" ] && ok "plain hook (no args): payload read" || bad "plain hook: payload read" "got '$(sid)'"
[ "$(sid --sync-if-drifted)" = "sid---sync-if-drifted" ] && ok "registered flag --sync-if-drifted: payload read" \
  || bad "--sync-if-drifted: payload read" "got '$(sid --sync-if-drifted)'"

echo "== 2. a hand-run --flag does not wait for stdin"
[ -z "$(sid --sync-all)" ] && ok "--sync-all: priming skipped" || bad "--sync-all: priming skipped" "got '$(sid --sync-all)'"
v=$(printf '{"session_id":"sid-forced"}' | HOME="$H" GOV_NO_STDIN=1 bash -c ". '$HOOKS/_common.sh'; gov_session_id" 2>/dev/null)
[ -z "$v" ] && ok "GOV_NO_STDIN=1 forces the skip" || bad "GOV_NO_STDIN=1" "got '$v'"

echo "== 3. with stdin held OPEN, sourcing returns (the actual hang)"
timeout 20 tail -f /dev/null | timeout 10 env HOME="$H" bash -c ". '$HOOKS/_common.sh'" _ --publish-preview >/dev/null 2>&1
rc=${PIPESTATUS[1]}; [ "$rc" = "0" ] && ok "--publish-preview with open stdin returns (rc=0)" || bad "--publish-preview open stdin" "rc=$rc (124 = blocked)"
# Negative control: a plain source DOES wait on an open stdin - proves this harness can see a hang.
timeout 8 tail -f /dev/null | timeout 3 env HOME="$H" bash -c ". '$HOOKS/_common.sh'" >/dev/null 2>&1
rc=${PIPESTATUS[1]}; [ "$rc" = "124" ] && ok "negative control: hook-mode source on an open stdin still waits (rc=124)" \
  || bad "negative control" "rc=$rc - the harness cannot detect a hang, so section 3 proves nothing"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
