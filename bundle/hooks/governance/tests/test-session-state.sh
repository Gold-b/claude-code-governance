#!/usr/bin/env bash
# test-session-state.sh — sandbox tests for session-scoped governance state (§17)
#
# Runs the hooks against an ISOLATED HOME (never your real ~/.claude), with fake
# Claude Code stdin JSON, and asserts:
#   1. per-session state dirs (~/.claude/logs/sessions/<sid>/)
#   2. a second live session is reported as PARALLEL, not as a crash
#   3. a session silent > 6 h with a change log is archived as CRASHED
#   4. GOV_DRY_RUN=1 makes no state changes
#   5. legacy path (no session id) still works
#   6. sync-governance-copies mirrors ~/.claude/docs/*.md into the installer bundle
#   7. pre-task counts prompts inside the session dir
#   8. end-session honours dry-run and keeps the push flag
# Usage: bash bundle/hooks/governance/tests/test-session-state.sh   (from the repo root or anywhere)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_contains() { printf '%s' "$2" | grep -q -- "$3" && ok "$1" || { fail "$1 (expected to contain: $3)"; printf '%s\n' "$2" | head -5 | sed 's/^/       | /'; }; }
assert_not_contains() { printf '%s' "$2" | grep -q -- "$3" && { fail "$1 (must NOT contain: $3)"; } || ok "$1"; }
assert_file() { [ -f "$2" ] && ok "$1" || fail "$1 (missing $2)"; }
assert_no_file() { [ -e "$2" ] && fail "$1 (exists $2)" || ok "$1"; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/gov-test-XXXXXX")"
export HOME="$SANDBOX/home"
mkdir -p "$HOME/.claude/logs" "$HOME/.claude/hooks/governance" "$HOME/.claude/governance-installer/bundle/docs" "$HOME/.claude/docs"
cp "$HOOKS_SRC"/*.sh "$HOME/.claude/hooks/governance/"
H="$HOME/.claude/hooks/governance"
export GOVERNANCE_HOOKS=1 GOV_NOTIFY=0 GOVERNANCE_LOG="$HOME/.claude/logs/governance.log"
unset GOV_SESSION_ID GOV_DRY_RUN 2>/dev/null || true

# fake governed project with a git repo (pre-session stamps HEAD; end-session looks for canonical files)
PROJ="$SANDBOX/proj"; mkdir -p "$PROJ/docs/context" "$PROJ/Plans"
( cd "$PROJ" && git init -q . && git config user.email t@t && git config user.name t \
  && printf '# m\ncanonical_working_copy: %s\n' "$PROJ" > docs/context/CONTEXT-MANIFEST.md \
  && printf '# plan\n' > Plans/PLAN.md && printf -- '---\nstatus: active\n---\n# h\n' > docs/context/HANDOFF.md \
  && printf '# mem\n' > docs/context/MEMORY.md && git add -A && git commit -q -m init )
cd "$PROJ"

echo "[1] session-scoped dirs"
OUT=$(printf '{"session_id":"A-1111"}' | bash "$H/pre-session.sh" 2>&1)
assert_contains "governed project detected for sid A" "$OUT" "Governed project detected"
assert_not_contains "no crash on first session" "$OUT" "CRASH RECOVERY"
assert_not_contains "no parallel on first session" "$OUT" "PARALLEL SESSION"
[ -d "$HOME/.claude/logs/sessions/A-1111" ] && ok "sessions/A-1111 created" || fail "sessions/A-1111 missing"
assert_file "start stamp in session dir" "$HOME/.claude/logs/sessions/A-1111/.gov-session-start"
grep -q "sid=A-1111" "$HOME/.claude/logs/sessions/A-1111/.gov-session-start" 2>/dev/null && ok "start stamp carries sid" || fail "start stamp lacks sid"

echo "[2] post-milestone writes into the session dir"
printf '{"session_id":"A-1111","tool_name":"Edit","tool_input":{"file_path":"%s/src/x.py"}}' "$PROJ" | bash "$H/post-milestone.sh" >/dev/null 2>&1
assert_file "change log in sessions/A" "$HOME/.claude/logs/sessions/A-1111/.gov-session-changes"
assert_no_file "legacy shared change log untouched" "$HOME/.claude/logs/.gov-session-changes"

echo "[3] second live session = PARALLEL (not crash), A's log intact"
OUT=$(printf '{"session_id":"B-2222"}' | bash "$H/pre-session.sh" 2>&1)
assert_contains "parallel detected" "$OUT" "PARALLEL SESSION?"
assert_not_contains "not reported as crash" "$OUT" "CRASH RECOVERY"
[ "$(grep -c . "$HOME/.claude/logs/sessions/A-1111/.gov-session-changes")" = "1" ] && ok "A's change log intact" || fail "A's change log was touched"

echo "[4] silent > 6h with changes = CRASH archived"
find "$HOME/.claude/logs/sessions/A-1111" -type f -exec touch -d '8 hours ago' {} \; 2>/dev/null || find "$HOME/.claude/logs/sessions/A-1111" -type f -exec touch -t "$(date -d '8 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-8H +%Y%m%d%H%M)" {} \;
touch -d '8 hours ago' "$HOME/.claude/logs/sessions/A-1111" 2>/dev/null || true
# B is also "old" now? no - B has fresh files, so B counts as parallel; make B old too so only A qualifies for crash
find "$HOME/.claude/logs/sessions/B-2222" -type f -exec touch -d '20 minutes ago' {} \; 2>/dev/null || true
OUT=$(printf '{"session_id":"C-3333"}' | bash "$H/pre-session.sh" 2>&1)
assert_contains "crash reported" "$OUT" "CRASH RECOVERY"
ls "$HOME/.claude/logs/.gov-crashed-session-A-1111-"*.log >/dev/null 2>&1 && ok "A archived" || fail "A archive missing"
assert_file "A marked closed" "$HOME/.claude/logs/sessions/A-1111/.gov-session-closed"
[ ! -s "$HOME/.claude/logs/sessions/A-1111/.gov-session-changes" ] && ok "A change log emptied" || fail "A change log not emptied"

echo "[5] dry-run makes no state changes"
OUT=$(GOV_DRY_RUN=1 bash -c 'printf "{\"session_id\":\"D-4444\"}" | bash "'"$H"'/pre-session.sh"' 2>&1)
assert_contains "dry-run announced" "$OUT" "DRY-RUN"
[ -z "$(ls -A "$HOME/.claude/logs/sessions/D-4444" 2>/dev/null)" ] && ok "no files written for D" || fail "dry-run wrote files: $(ls -A "$HOME/.claude/logs/sessions/D-4444")"

echo "[6] legacy path (no session id) still works"
OUT=$(bash "$H/pre-session.sh" </dev/null 2>&1)
assert_contains "legacy governed detection" "$OUT" "Governed project detected"
[ ! -d "$HOME/.claude/logs/sessions/" ] || [ -z "$(ls -A "$HOME/.claude/logs/sessions/" | grep -v -E '^(A-1111|B-2222|C-3333|D-4444)$')" ] && ok "no anonymous session dir" || fail "unexpected session dir created"

echo "[7] pre-task counts inside the session dir"
printf '{"session_id":"C-3333","prompt":"hi"}' | bash "$H/pre-task.sh" >/dev/null 2>&1
assert_file "prompt counter in sessions/C" "$HOME/.claude/logs/sessions/C-3333/.gov-session-prompt-count"

echo "[8] sync-governance-copies mirrors docs into the installer bundle"
printf '# guide\n' > "$HOME/.claude/docs/GOVERNANCE-AGENT-GUIDE.md"
OUT=$(printf '{"session_id":"C-3333","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$HOME/.claude/docs/GOVERNANCE-AGENT-GUIDE.md" | bash "$H/sync-governance-copies.sh" 2>&1)
assert_file "doc copied to bundle" "$HOME/.claude/governance-installer/bundle/docs/GOVERNANCE-AGENT-GUIDE.md"
grep -q "GOVERNANCE-AGENT-GUIDE.md" "$HOME/.claude/logs/.governance-push-pending" 2>/dev/null && ok "push flag queued" || fail "push flag missing"

echo "[9] end-session dry-run keeps the push flag"
OUT=$(GOV_DRY_RUN=1 bash -c 'printf "{\"session_id\":\"C-3333\"}" | bash "'"$H"'/end-session.sh"' 2>&1)
assert_file "push flag kept in dry-run" "$HOME/.claude/logs/.governance-push-pending"

echo
echo "passed=$PASS failed=$FAIL  (sandbox: $SANDBOX)"
[ "$FAIL" -eq 0 ] && rm -rf "$SANDBOX"
[ "$FAIL" -eq 0 ]
