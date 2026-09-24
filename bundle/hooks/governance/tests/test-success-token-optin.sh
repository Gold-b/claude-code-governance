#!/usr/bin/env bash
# test-success-token-optin.sh - the success-token gate is OPT-IN (v1.7.1) and nothing deadlocks a close.
#
# WHY (2026-09-24). With the gate on by default, end-session.sh / close-completeness.sh demanded
# HANDOFF/MEMORY/OPEN-PROBLEMS before a stop while governance-guard.sh refused those writes until the
# owner approved a token. Section 6 replays that exact sequence end to end. The other sections pin
# the flag parsing (1/true/yes/on enable, everything else is off), prove the controls that must stay
# on regardless (DEPLOYMENT/FROZEN role gate, bundle/ publish-target gate, GOVERNANCE_HOOKS=0), and
# that opting in restores the old behaviour exactly.
#
# Sandboxed: a temporary HOME and fixture projects; your real ~/.claude is never read or written.
# Usage: bash tests/test-success-token-optin.sh      (HOOKS=<dir> to point it at another copy)
HOOKS="${HOOKS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Every hook call below gets its payload through an explicit pipe. Close the suite's OWN stdin:
# sourcing/running hook code with an open, silent stdin blocks in gov_hook_input forever - that is
# what made two runs of this suite hit a 20-minute timeout when launched from a backgrounded shell.
exec </dev/null
REAL_GIT="$(command -v git)"
SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT
SBX_HOME="$SBX/home"; mkdir -p "$SBX_HOME/.claude/logs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s  -- %s\n' "$1" "$2"; }

# run <script> <cwd> <payload> [VAR=val ...]  -> RC, BOTH
run() {
  local script="$1" cwd="$2" payload="$3"; shift 3
  BOTH=$( cd "$cwd" && printf '%s' "$payload" | env -u GOV_REQUIRE_SUCCESS_TOKEN \
      HOME="$SBX_HOME" USERPROFILE="$SBX_HOME" GOV_NOTIFY=0 GOV_WHATSAPP=0 \
      GOVERNANCE_HOOKS=1 GOV_ROLE_FRAMEWORK=1 GOV_SESSION_ID="${SID:-sid-x}" "$@" \
      timeout 60 bash "$HOOKS/$script" 2>&1 )
  RC=$?
}
expect() { # $1 want-rc, $2 label
  if [ "$RC" = "$1" ]; then ok "$2 (rc=$RC)"; else bad "$2" "rc=$RC want $1: $(printf '%s' "$BOTH" | tr '\n' '|' | head -c 240)"; fi
}
has() { case "$BOTH" in *"$1"*) ok "$2" ;; *) bad "$2" "missing [$1]" ;; esac; }
hasnt() { case "$BOTH" in *"$1"*) bad "$2" "unexpected [$1]" ;; *) ok "$2" ;; esac; }
token() { local t="$SBX_HOME/.claude/logs/governance-success-token.json"
  if [ -z "$1" ]; then rm -f "$t"; else printf '{"expires_at_epoch":%s}\n' "$(( $(date +%s) + $1 ))" > "$t"; fi; }

mkproj() { # $1 dir $2 role
  mkdir -p "$1/docs/context" "$1/Plans" "$1/admin/lib"
  printf '# P\n' > "$1/CLAUDE.md"; printf '%s\n' "$2" > "$1/.governance-role"
  printf -- '---\ntype: manifest\n---\n' > "$1/docs/context/CONTEXT-MANIFEST.md"
  printf '# PLAN\n' > "$1/Plans/PLAN.md"; printf '# HANDOFF\n' > "$1/docs/context/HANDOFF.md"
  printf '# MEMORY\n' > "$1/docs/context/MEMORY.md"
}
pl() { # tool file cwd
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s","content":"x"}}' "${SID:-sid-x}" "$3" "$1" "$2"; }

SRC="$SBX/src"; mkproj "$SRC" SOURCE
DEP="$SBX/dep"; mkproj "$DEP" DEPLOYMENT
FRZ="$SBX/frz"; mkproj "$FRZ" FROZEN

. "$HOOKS/_common.sh"
PATTERNS=$(gov_protected_patterns)
echo "== 1. guard, DEFAULT (flag unset): every protected pattern, every write tool, is ALLOWED"
token
while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  f="$SRC/$pat"; mkdir -p "$(dirname "$f")"
  run governance-guard.sh "$SRC" "$(pl Edit "$f" "$SRC")"; expect 0 "default: Edit $pat"
done <<EOF
$PATTERNS
EOF
# The guard never branches on tool_name (the matcher lives in settings.json), so one pattern is
# enough to prove Write/MultiEdit take the same path. Each hook call costs 2-9s under load; the
# full 3x matrix pushed this suite past 20 minutes on a busy machine.
for tool in Write MultiEdit; do
  run governance-guard.sh "$SRC" "$(pl "$tool" "$SRC/docs/context/HANDOFF.md" "$SRC")"; expect 0 "default: $tool docs/context/HANDOFF.md"
done
# Windows-style path with backslashes (as Claude Code sends it on Windows)
WIN=$(cygpath -w "$SRC/docs/context/HANDOFF.md" 2>/dev/null | sed 's/\\/\\\\/g')
if [ -n "$WIN" ]; then
  run governance-guard.sh "$SRC" "$(pl Edit "$WIN" "$SRC")"; expect 0 "default: Windows backslash path to HANDOFF.md"
fi
run governance-guard.sh "$SRC" "$(pl Edit "$SRC/docs/context/HANDOFF.md" "$SRC")"
hasnt "success token" "default: output never mentions a token"
grep -q "ALLOW: success-token gate off" "$SBX_HOME/.claude/logs/governance.log" && ok "default: decision is LOGGED (live invariant stays balanced)" || bad "default: decision logged" "no ALLOW line"

echo "== 2. flag values"
for v in "" 0 false no off FALSE garbage 2; do
  run governance-guard.sh "$SRC" "$(pl Edit "$SRC/docs/context/HANDOFF.md" "$SRC")" GOV_REQUIRE_SUCCESS_TOKEN="$v"
  expect 0 "flag='$v' -> gate OFF"
done
for v in 1 true TRUE yes Yes on ON; do
  token
  run governance-guard.sh "$SRC" "$(pl Edit "$SRC/docs/context/HANDOFF.md" "$SRC")" GOV_REQUIRE_SUCCESS_TOKEN="$v"
  expect 2 "flag='$v', no token -> gate ON, BLOCKED"
done
token 300
run governance-guard.sh "$SRC" "$(pl Edit "$SRC/docs/context/HANDOFF.md" "$SRC")" GOV_REQUIRE_SUCCESS_TOKEN=1
expect 0 "flag on + fresh token -> ALLOWED"
token -60
run governance-guard.sh "$SRC" "$(pl Edit "$SRC/docs/context/HANDOFF.md" "$SRC")" GOV_REQUIRE_SUCCESS_TOKEN=1
expect 2 "flag on + expired token -> BLOCKED"; has "expired" "expired: says so"
printf 'not json' > "$SBX_HOME/.claude/logs/governance-success-token.json"
run governance-guard.sh "$SRC" "$(pl Edit "$SRC/docs/context/HANDOFF.md" "$SRC")" GOV_REQUIRE_SUCCESS_TOKEN=1
expect 2 "flag on + malformed token -> BLOCKED"
token

echo "== 3. controls that must stay ON regardless of the flag"
run governance-guard.sh "$DEP" "$(pl Edit "$DEP/docs/context/HANDOFF.md" "$DEP")"; expect 2 "default: DEPLOYMENT node still BLOCKED"
run governance-guard.sh "$FRZ" "$(pl Edit "$FRZ/docs/context/HANDOFF.md" "$FRZ")"; expect 2 "default: FROZEN node still BLOCKED"
REPO="$SBX/pubrepo"; mkdir -p "$REPO/bundle/hooks"
printf 'GOV_REPO_PATH=%s\n' "$REPO" > "$SBX_HOME/.claude/.governance-local.env"
run governance-guard.sh "$SRC" "$(pl Edit "$REPO/bundle/hooks/x.sh" "$SRC")"; expect 2 "default: direct bundle/ edit still BLOCKED"
run governance-guard.sh "$SRC" "$(pl Edit "$REPO/bundle/hooks/x.sh" "$SRC")" GOV_BUNDLE_EDIT=1; expect 0 "bundle/ with GOV_BUNDLE_EDIT=1 -> allowed (kill switch intact)"
rm -f "$SBX_HOME/.claude/.governance-local.env"

echo "== 4. unrelated paths and malformed input"
run governance-guard.sh "$SRC" "$(pl Edit "$SRC/admin/lib/a.js" "$SRC")" GOV_REQUIRE_SUCCESS_TOKEN=1; expect 0 "ordinary file, flag on -> allowed"
run governance-guard.sh "$SRC" "$(pl Edit "$SBX_HOME/.claude/projects/c--x/memory/MEMORY.md" "$SRC")" GOV_REQUIRE_SUCCESS_TOKEN=1; expect 0 "user auto-memory, flag on -> allowed"
run governance-guard.sh "$SRC" ""; expect 0 "empty payload -> allowed (fail-open, unchanged)"
run governance-guard.sh "$SRC" "{bad json"; expect 0 "malformed payload -> allowed (fail-open, unchanged)"
run governance-guard.sh "$SRC" "$(pl Edit "$SRC/docs/context/HANDOFF.md" "$SRC")" GOVERNANCE_HOOKS=0 GOV_REQUIRE_SUCCESS_TOKEN=1; expect 0 "GOVERNANCE_HOOKS=0 still bypasses"

echo "== 5. pre-done.sh (TaskCompleted)"
SID=sid-pd; d="$SBX_HOME/.claude/logs/sessions/$SID"; mkdir -p "$d"; printf '%s\n' "$SRC/admin/lib/a.js" > "$d/.gov-session-changes"
PD='{"session_id":"sid-pd","cwd":"'"$SRC"'","hook_event_name":"TaskCompleted"}'
token
run pre-done.sh "$SRC" "$PD"; expect 0 "default: changes, no token -> task completion ALLOWED"
hasnt "VERIFICATION GATE" "default: no gate text"
run pre-done.sh "$SRC" "$PD" GOV_REQUIRE_SUCCESS_TOKEN=1; expect 2 "flag on, no token -> BLOCKED"
token 300
run pre-done.sh "$SRC" "$PD" GOV_REQUIRE_SUCCESS_TOKEN=1; expect 0 "flag on, fresh token -> allowed"
token; unset SID

echo "== 6. THE REPORTED DEADLOCK, end to end: close demands HANDOFF -> guard lets it be written -> close passes"
CC="$SBX/cc"; mkproj "$CC" SOURCE
printf 'docs/context/HANDOFF.md\n' > "$CC/docs/context/.close-required"
g() { "$REAL_GIT" -C "$CC" "$@" >/dev/null 2>&1; }
g init; g config user.email a@example.com; g config user.name Op; g add -A; g commit -m base
BASE=$("$REAL_GIT" -C "$CC" rev-parse HEAD)
stamp() { local d="$SBX_HOME/.claude/logs/sessions/$1"; mkdir -p "$d"
  printf '%s %s %s sid=%s\n' "$BASE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CC" "$1" > "$d/.gov-session-start"; }
printf 'module.exports=1;\n' > "$CC/admin/lib/f.js"; g add -A; g commit -m code
for mode in default optin; do
  sid="sid-cc-$mode"; stamp "$sid"
  extra=(); [ "$mode" = optin ] && extra=(GOV_REQUIRE_SUCCESS_TOKEN=1)
  SID=$sid run close-completeness.sh "$CC" '{"session_id":"'"$sid"'","cwd":"'"$CC"'","hook_event_name":"Stop"}' "${extra[@]}"
  expect 2 "$mode: code changed, HANDOFF not written -> stop BLOCKED"
  if [ "$mode" = default ]; then
    has "No approval is needed" "default: close message says write WITHOUT asking"
    hasnt "commit-task-success" "default: close message does NOT ask for a token"
    SID=$sid run governance-guard.sh "$CC" "$(pl Edit "$CC/docs/context/HANDOFF.md" "$CC")"
    expect 0 "default: the HANDOFF write the close demands is ALLOWED - no deadlock"
  else
    has "commit-task-success" "opt-in: close message explains the token"
    SID=$sid run governance-guard.sh "$CC" "$(pl Edit "$CC/docs/context/HANDOFF.md" "$CC")" GOV_REQUIRE_SUCCESS_TOKEN=1
    expect 2 "opt-in: HANDOFF write without a token is BLOCKED (old behaviour preserved)"
  fi
done
printf '\n## 2026-09-24 session\nreal entry\n' >> "$CC/docs/context/HANDOFF.md"; g add -A; g commit -m handoff
stamp sid-cc-after
SID=sid-cc-after run close-completeness.sh "$CC" '{"session_id":"sid-cc-after","cwd":"'"$CC"'","hook_event_name":"Stop"}'
expect 0 "after the HANDOFF is written, the stop is ALLOWED"

echo "== 7. end-session.sh message branch renders correctly in both modes"
snip=$(awk '/if gov_success_token_required; then/{f=1} f{print} /^  fi$/{if(f){exit}}' "$HOOKS/end-session.sh")
for mode in off on; do
  v=0; [ "$mode" = on ] && v=1
  BOTH=$(GOV_REQUIRE_SUCCESS_TOKEN=$v bash -c ". '$HOOKS/_common.sh'; $snip
printf '%s' \"\$_es_token_note\"")
  if [ "$mode" = off ]; then has "No approval is needed" "end-session off: no-approval note"; hasnt "commit-task-success" "end-session off: no token instruction"
  else has "commit-task-success" "end-session on: token instruction"; fi
done

echo
echo "$PASS passed, $FAIL failed  (${SECONDS}s)"
[ "$FAIL" -eq 0 ]
