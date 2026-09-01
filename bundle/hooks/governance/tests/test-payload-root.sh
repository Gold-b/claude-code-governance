#!/usr/bin/env bash
# test-payload-root.sh — a hook must judge the PROJECT OF THE EDIT, not its own $PWD.
#
# THE BUG (2026-08-17). Every write a session made while its shell stood outside the project root
# was silently dropped from the session change log. Reproduced from a real session that ran its
# test suite out of `~/.claude/skills/<x>`: the edits succeeded, the log never recorded them.
#
# Two independent $PWD dependencies had to be closed, and the second is the nastier one:
#   1. `[ ! -f "docs/context/CONTEXT-MANIFEST.md" ]` - a RELATIVE governed-project test.
#   2. `gov_role_guard SOURCE` -> `gov_detect_role` -> `gov_find_project_root`, which walks UP from
#      $PWD looking for a CLAUDE.md. From inside `~/.claude/**` that walk finds the USER-LEVEL
#      `~/.claude/CLAUDE.md`, calls it "the project", sees no `.git` next to it, and reports
#      DEPLOYMENT - so the guard skipped the hook entirely.
#
# Why it matters more than the false BLOCK it produced at close: the same omission under-counts
# SESSION_WRITES, and end-session.sh only fires its handoff gate at >= 3. A session whose writes
# were mostly dropped can close with NO handoff while the gate stays quiet. A clean close and a
# lost one look identical from outside - which is exactly the failure this framework exists to
# prevent.
set +e
HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }

SANDBOX=$(mktemp -d)
PROJ="$SANDBOX/proj"; OUTSIDE="$SANDBOX/outside"
mkdir -p "$PROJ/docs/context" "$PROJ/.git" "$OUTSIDE"
: > "$PROJ/CLAUDE.md"; : > "$PROJ/docs/context/CONTEXT-MANIFEST.md"
# The outside directory carries its own CLAUDE.md and NO .git — the shape of `~/.claude`, which is
# what made the upward walk report DEPLOYMENT and skip the hook.
: > "$OUTSIDE/CLAUDE.md"

export GOV_SESSION_ID="payload-root-test-$$"
STATE="$HOME/.claude/logs/sessions/$GOV_SESSION_ID"
rm -rf "$STATE"
LOG="$STATE/.gov-session-changes"
count() { grep -c . "$LOG" 2>/dev/null || echo 0; }

# Valid JSON, built by a tool rather than hand-escaped: a payload with a stray `\d` fails strict
# JSON parsing, the hook falls back to its regex path, and the test silently measures a different
# code path than production does. That mistake cost a full diagnostic round.
payload() {
  python3 -c "
import json,sys
json.dump({'session_id':sys.argv[1],'tool_name':'Edit',
           'tool_input':{'file_path':sys.argv[2]},'cwd':sys.argv[3]}, sys.stdout)
" "$GOV_SESSION_ID" "$1" "$2"
}

echo "[1] a governed edit is recorded even when the hook stands OUTSIDE the project"
payload "$PROJ/docs/context/HANDOFF.md" "$PROJ" > "$SANDBOX/p.json"
( cd "$OUTSIDE" && bash "$HOOKS/post-milestone.sh" < "$SANDBOX/p.json" >/dev/null 2>&1 )
[ "$(count)" -eq 1 ] && ok "recorded from outside the project root" \
                     || bad "DROPPED — the \$PWD dependency is back (count=$(count))"

echo "[2] the same edit is still recorded from inside the project"
( cd "$PROJ" && bash "$HOOKS/post-milestone.sh" < "$SANDBOX/p.json" >/dev/null 2>&1 )
[ "$(count)" -eq 2 ] && ok "recorded from the project root" || bad "regression: count=$(count)"

echo "[3] an UNGOVERNED edit is still skipped, even from inside a governed directory"
payload "$OUTSIDE/notes.md" "$OUTSIDE" > "$SANDBOX/q.json"
( cd "$PROJ" && bash "$HOOKS/post-milestone.sh" < "$SANDBOX/q.json" >/dev/null 2>&1 )
[ "$(count)" -eq 2 ] && ok "ungoverned project still skipped" \
                     || bad "the fix over-reached: an ungoverned edit was tracked (count=$(count))"

echo "[4] gov_payload_root resolves the payload, not the shell"
. "$HOOKS/_common.sh" 2>/dev/null
R=$( cd "$OUTSIDE" && . "$HOOKS/_common.sh" && gov_payload_root "$(cat "$SANDBOX/p.json")" )
# Assert BEHAVIOUR, not the spelling of the path. On MSYS one directory has two equally-real
# names (`/tmp/x` and `/c/Users/<u>/AppData/Local/Temp/x`) and neither `pwd -P` nor a string
# compare reconciles them, so a correct answer failed the assertion. What actually matters is that
# it resolved to the GOVERNED project and not to the directory the shell was standing in.
if [ -n "$R" ] && gov_is_governed "$R" && [ ! -f "$R/notes-marker" ]; then
  ok "resolved to the edited project (governed root: $R)"
else
  bad "resolved to '$R' - expected the governed project, not the shell's directory"
fi

echo "[5] a payload with no usable path degrades to the old behaviour instead of throwing"
R=$( cd "$PROJ" && . "$HOOKS/_common.sh" && gov_payload_root '{"tool_name":"Edit"}' )
[ -n "$R" ] && ok "fell back to a root ($R)" || bad "returned nothing"

rm -rf "$SANDBOX" "$STATE"
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
