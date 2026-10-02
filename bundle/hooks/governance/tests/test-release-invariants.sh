#!/usr/bin/env bash
# test-release-invariants.sh - two push-gate conditions that are properties of the SOURCE, not of a
# run (legal plan 2026-09-30 task P11; board conditions T2 and T6). Created 2026-09-30.
#
# WHAT IT CHECKS, over ONE tree root in the repo/staging layout (install.sh, verify.sh,
# bundle/hooks/governance/*.sh, bundle/hooks/governance/tests/test-gov-update.sh):
#   (T2)  "one parser": no script except consent-lib.sh EXTRACTS a field from a consent record
#         (terms-accepted, close-push, HELD-TERMS-*) with its own sed/grep -o/cut/awk. Such a line
#         is a second parser that can drift from gov_record_field. A whole-line read for display
#         (head -1) and a match test (grep -q) are not extractions; comments are ignored.
#   (T6a) governance-selftest.sh defines GOV_SELFTEST_UPDATE_DEFAULT exactly once;
#   (T6b) case_gov_update runs THAT variable (not a literal list beside it);
#   (T6c) every name in it is a real case of tests/test-gov-update.sh (`if want NAME`) - a typo
#         would silently run nothing for that name;
#   (T6d) it contains every name board T6 requires: T11 NOAUTO CLOSEPUSH CONSENT M8 M10
#         (NOAUTO is the successor of OPTIN; CONSENT carries C3/C5, OPEN-PROBLEMS #35 (b)).
#   (T9a) governance-selftest.sh's expand_cmd resolves `<interpreter> <file>` hook commands to the
#         file and keeps inline commands inline (OPEN-PROBLEMS #33: `python3 ~/.claude/hooks/x.py`
#         was run inline in the sandbox HOME, failed rc=2 and kept the Stop-hook verdict RED -
#         a precondition of T9 "selftest GREEN").
#   (T9b) (round 3) its mutate_and_check reports a mutant it could not write as an ERROR, never as
#         "killed" (under GOV_SELFTEST_HOME a hook outside HOOKS_ROOT got no mutant, the case ran
#         against a missing file, every assertion failed, and that was counted as a kill).
# THEN it proves every check can fail - one mutant per check on a temp copy (must fire) - and that
# a benign edit does not (must not fire). It asserts the printed text of each check.
#
#   [4]   (round 3, B7, 2026-10-02) verify.sh after a REAL install.sh into a private HOME: on the
#         maintainer's machine it passes without a close-push record; on a client it still requires
#         one (both directions; GOV_INVARIANTS_SKIP_INSTALL=1 skips this slow part). Verify round 4 #4
#         (2026-10-02): the maintainer line follows gov_close_push_on - paused by GOV_CLOSE_PUSH=0 (env
#         or .governance-local.env) prints paused, rc 0 - and the maintainer branch reads no terms source.
#   [5]   (verify round 4 #2, 2026-10-02) the terms source on clients: an install from a clone OUTSIDE
#         <HOME>/.claude/governance-installer, answered y, is ON everywhere; one source deleted /
#         garbled / disagreeing is OFF "unclear" and --enable refuses; re-running install.sh restores
#         it; --uninstall removes the copy; the staging layout still works (also skipped by
#         GOV_INVARIANTS_SKIP_INSTALL=1).
# Read-only on the real tree. Sections [1]-[3] use no HOME at all; [4] installs into private HOMEs
# under its own temp dir (HOME and USERPROFILE both set), never the real ~/.claude.
# Usage: bash test-release-invariants.sh [<root>]   (default: found from this file's location;
#        env GOV_INVARIANTS_ROOT overrides). Output ends with:
#        release-invariants selftest: pass=<n> fail=<n>   (exit 1 on any fail or nothing checked)
set +e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOV_DIR="$(cd "$HERE/.." && pwd)"
T6_REQUIRED="T11 NOAUTO CLOSEPUSH CONSENT M8 M10"
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no [$3] in [$(printf '%s' "$2" | head -c 600)])" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ([$3] present in [$(printf '%s' "$2" | head -c 600)])" ;; *) ok "$1" ;; esac; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got [$2] want [$3])"; fi; }

ROOT="${1:-${GOV_INVARIANTS_ROOT:-}}"
if [ -z "$ROOT" ]; then
  # bundle/hooks/governance/tests -> the root three levels up; the live ~/.claude/hooks/governance
  # -> the staging copy ~/.claude/governance-installer.
  for _c in "$GOV_DIR/../../.." "$GOV_DIR/../../governance-installer"; do
    if [ -f "$_c/install.sh" ] && [ -f "$_c/bundle/hooks/governance/governance-selftest.sh" ]; then
      ROOT="$(cd "$_c" && pwd)"; break
    fi
  done
fi
if [ -z "$ROOT" ] || [ ! -f "$ROOT/bundle/hooks/governance/governance-selftest.sh" ]; then
  echo "  FAIL no tree root with install.sh + bundle/hooks/governance found (pass one, or set GOV_INVARIANTS_ROOT)"
  echo "release-invariants selftest: pass=0 fail=1"
  exit 1
fi
echo "release-invariants: tree root $ROOT"

# A line that names a consent record AND extracts from it with a tool of its own.
RECORD_RE='terms-accepted|HELD-TERMS|close-push"|CP_REC'
EXTRACT_RE="sed -n|sed -e|sed 's|grep -[A-Za-z]*o|cut -d|awk "

# run_checks <root> -> one line per check: "PASS (x) ..." or "FAIL (x) ...".
run_checks() {
  local r="$1" g="$1/bundle/hooks/governance" f hits="" n=0 line st suite def cnt names unknown="" missing="" x
  local files=()
  # (T2) one grep over all the files (a process per file costs ~a minute on a loaded Windows box).
  for f in "$r/install.sh" "$r/verify.sh" "$g"/*.sh; do
    [ -f "$f" ] || continue
    case "${f##*/}" in consent-lib.sh) continue ;; esac
    n=$((n+1)); files+=("$f")
  done
  if [ "$n" -gt 0 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      f="${line%%:*}"; line="${line#*:}"
      hits="$hits ${f#"$r"/}:${line%%:*}"
    done <<EOF
$(grep -nHE "$RECORD_RE" "${files[@]}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -E "$EXTRACT_RE")
EOF
  fi
  if [ "$n" -eq 0 ]; then echo "FAIL (T2) no script found under $r - nothing was checked"
  elif [ -n "$hits" ]; then echo "FAIL (T2) a second parser of a consent record (use gov_record_field):$hits"
  else echo "PASS (T2) $n scripts, none but consent-lib.sh extracts a consent-record field"; fi
  # (T6)
  st="$g/governance-selftest.sh"; suite="$g/tests/test-gov-update.sh"
  cnt=$(tr -d '\r' < "$st" | grep -cE '^GOV_SELFTEST_UPDATE_DEFAULT="[^"]*"$')
  if [ "$cnt" = "1" ]; then echo "PASS (T6a) GOV_SELFTEST_UPDATE_DEFAULT defined once"
  else echo "FAIL (T6a) GOV_SELFTEST_UPDATE_DEFAULT defined $cnt times in governance-selftest.sh (want 1)"; fi
  def=$(tr -d '\r' < "$st" | sed -n 's/^GOV_SELFTEST_UPDATE_DEFAULT="\([^"]*\)"$/\1/p' | head -1)
  if tr -d '\r' < "$st" | grep -qF 'GOV_TEST_ONLY="${GOV_SELFTEST_UPDATE_CASES-$GOV_SELFTEST_UPDATE_DEFAULT}"'; then
    echo "PASS (T6b) case_gov_update runs GOV_SELFTEST_UPDATE_DEFAULT"
  else echo "FAIL (T6b) case_gov_update does not run \$GOV_SELFTEST_UPDATE_DEFAULT (a literal list beside it is not checked)"; fi
  names=" $(tr -d '\r' < "$suite" 2>/dev/null | sed -n 's/^if want \([A-Za-z0-9_]*\).*/\1/p' | tr '\n' ' ') "
  if [ "$names" = "  " ] || [ -z "$def" ]; then
    echo "FAIL (T6c) nothing to compare: default=[$def] cases found in test-gov-update.sh=[$(printf '%s' "$names" | wc -w | tr -d ' ')]"
  else
    for x in $def; do case "$names" in *" $x "*) : ;; *) unknown="$unknown $x" ;; esac; done
    if [ -n "$unknown" ]; then echo "FAIL (T6c) not a case of tests/test-gov-update.sh:$unknown"
    else echo "PASS (T6c) all $(printf '%s' "$def" | wc -w | tr -d ' ') default names are real cases"; fi
  fi
  for x in $T6_REQUIRED; do case " $def " in *" $x "*) : ;; *) missing="$missing $x" ;; esac; done
  if [ -n "$missing" ]; then echo "FAIL (T6d) the default subset lacks the T6 name(s):$missing"
  else echo "PASS (T6d) the default subset has every T6 name ($T6_REQUIRED)"; fi
  # (T9a) the selftest's expand_cmd, lifted out of the file and run in a subshell over FIX
  local defs got want wrong="" c
  defs=$(tr -d '\r' < "$st" | awk '/^expand_cmd\(\) \{/{f=1} f{print} f&&/^}/{exit}')
  if [ -z "$defs" ]; then echo "FAIL (T9a) no expand_cmd() in governance-selftest.sh"
  else
    while IFS='|' read -r c want; do
      [ -n "$c" ] || continue
      want="${want//@FIX@/$FIX}"
      got=$( HOME="$FIX"; eval "$defs"; expand_cmd "$c" )
      [ "$got" = "$want" ] || wrong="$wrong [$c -> '$got', want '$want']"
    done <<'EOF'
python3 ~/.claude/hooks/u.py|@FIX@/.claude/hooks/u.py
node ~/.claude/hooks/u.py --x|@FIX@/.claude/hooks/u.py
~/.claude/hooks/governance/g.sh --flag|@FIX@/.claude/hooks/governance/g.sh
python3 ~/.claude/hooks/missing.py|
echo hello|
bash -c "echo hi"|
EOF
    if [ -n "$wrong" ]; then echo "FAIL (T9a) expand_cmd:$wrong"
    else echo "PASS (T9a) expand_cmd resolves <interpreter> <file> and keeps inline commands inline"; fi
  fi
  # (T9b) (round 3, 2026-10-02) mutate_and_check, lifted out of the file and run in a subshell with
  # stub reporters: a hook OUTSIDE HOOKS_ROOT gets no mutant written, and that must be reported as
  # an ERROR - never as "killed" (a case run against a missing file fails every assertion). Control:
  # the same hook inside HOOKS_ROOT is mutated and killed.
  local mdefs mout_in mout_out M9="$TMP/t9b"
  mdefs=$(tr -d '\r' < "$st" | awk '/^mutate_and_check\(\) \{/{f=1} f{print} f&&/^}/{exit}')
  if [ -z "$mdefs" ]; then echo "FAIL (T9b) no mutate_and_check() in governance-selftest.sh"
  else
    rm -rf "$M9"; mkdir -p "$M9/tree/hooks/governance" "$M9/sbx/governance" "$M9/elsewhere/governance"
    printf '#!/usr/bin/env bash\necho hello\n' > "$M9/tree/hooks/governance/h.sh"
    cp "$M9/tree/hooks/governance/h.sh" "$M9/elsewhere/governance/h.sh"
    _t9b() {  # _t9b <hook path> -> the reporter lines mutate_and_check printed
      ( HOOKS_ROOT="$M9/tree/hooks"; SBX_HOOKS="$M9/sbx"; MUT=0; CASE_FAILS=0; CUR_SCRIPT=""
        _ok()  { echo "OK $1"; }
        _bad() { CASE_FAILS=$((CASE_FAILS+1)); echo "BAD $1"; }
        _t9b_case() { [ "$(bash "$CUR_SCRIPT" 2>/dev/null)" = hello ] || CASE_FAILS=$((CASE_FAILS+1)); }
        eval "$mdefs"; mutate_and_check "$1" _t9b_case h.sh ) 2>/dev/null
    }
    mout_out=$(_t9b "$M9/elsewhere/governance/h.sh")
    mout_in=$(_t9b "$M9/tree/hooks/governance/h.sh")
    if printf '%s\n' "$mout_out" | grep -q 'killed'; then
      echo "FAIL (T9b) a mutant that was never written was counted as killed: [$(printf '%s' "$mout_out" | tr '\n' '|')]"
    elif ! printf '%s\n' "$mout_out" | grep -q '^BAD MUTATION\[h.sh/NOOP\] NOT RUN (ERROR'; then
      echo "FAIL (T9b) an unwritten mutant is not reported as an ERROR: [$(printf '%s' "$mout_out" | tr '\n' '|')]"
    elif ! printf '%s\n' "$mout_in" | grep -q '^OK MUTATION\[h.sh/NOOP\] killed'; then
      echo "FAIL (T9b) control: a hook inside HOOKS_ROOT was not mutated and killed: [$(printf '%s' "$mout_in" | tr '\n' '|')]"
    else echo "PASS (T9b) an unwritten mutant is an ERROR, not a kill; a written one is judged (control)"; fi
  fi
}

# A temp dir: FIX is a fake HOME for (T9a); t/ is a copy of exactly the files run_checks reads.
TMP="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/relinv.$$")"; mkdir -p "$TMP"
trap 'rm -rf "$TMP" 2>/dev/null' EXIT
FIX="$TMP/fixhome"; mkdir -p "$FIX/.claude/hooks/governance"
: > "$FIX/.claude/hooks/u.py"; : > "$FIX/.claude/hooks/governance/g.sh"

echo "[1] the real tree"
OUT=$(run_checks "$ROOT")
printf '%s\n' "$OUT" | sed 's/^/    /'
for c in T2 T6a T6b T6c T6d T9a T9b; do has "($c) passes on the real tree" "$OUT" "PASS ($c)"; done
hasnt "no check fails on the real tree" "$OUT" "FAIL ("
fresh() {
  rm -rf "$TMP/t"; mkdir -p "$TMP/t/bundle/hooks/governance/tests"
  cp "$ROOT/install.sh" "$TMP/t/" 2>/dev/null; cp "$ROOT/verify.sh" "$TMP/t/" 2>/dev/null
  cp "$ROOT"/bundle/hooks/governance/*.sh "$TMP/t/bundle/hooks/governance/"
  cp "$ROOT/bundle/hooks/governance/tests/test-gov-update.sh" "$TMP/t/bundle/hooks/governance/tests/"
}
G="$TMP/t/bundle/hooks/governance"
# sub <file> <from> <to>: replace the first line equal to <from> (fixed string, whole line).
sub() { awk -v a="$2" -v b="$3" 'done==0 && $0==a {print b; done=1; next} {print}' "$1" > "$1.x" && mv -f "$1.x" "$1"; }

echo "[2] mutants (must fire)"
fresh
printf '%s\n' "  have=\$(sed -n 's/^terms_version=\\([0-9]*\\).*/\\1/p' \"\$UPD/terms-accepted\" 2>/dev/null | head -1)" >> "$G/gov-update.sh"
O=$(run_checks "$TMP/t"); has "T2: the old sed reader put back into gov-update.sh is caught" "$O" "FAIL (T2) a second parser of a consent record (use gov_record_field): bundle/hooks/governance/gov-update.sh:"
fresh
printf '%s\n' "  ACCEPTED_V=\$( { grep -o 'terms_version=[0-9]*' \"\$UPD_DIR/terms-accepted\" 2>/dev/null || true; } | head -1 | cut -d= -f2)" >> "$TMP/t/install.sh"
O=$(run_checks "$TMP/t"); has "T2: the old grep -o reader put back into install.sh is caught" "$O" "FAIL (T2) a second parser of a consent record (use gov_record_field): install.sh:"
fresh
printf '%s\n' '  v=$(cut -d" " -f1 "$CP_REC")' >> "$G/close-push.sh"
O=$(run_checks "$TMP/t"); has "T2: a cut over the close-push record in close-push.sh is caught" "$O" "bundle/hooks/governance/close-push.sh:"
DEF_LINE=$(tr -d '\r' < "$ROOT/bundle/hooks/governance/governance-selftest.sh" | grep -E '^GOV_SELFTEST_UPDATE_DEFAULT="' | head -1)
fresh
sub "$G/governance-selftest.sh" "$DEF_LINE" "$(printf '%s' "$DEF_LINE" | sed 's/ CLOSEPUSH//')"
O=$(run_checks "$TMP/t"); has "T6d: CLOSEPUSH removed from the default is caught" "$O" "FAIL (T6d) the default subset lacks the T6 name(s): CLOSEPUSH"
fresh
sub "$G/governance-selftest.sh" "$DEF_LINE" "$(printf '%s' "$DEF_LINE" | sed 's/ CONSENT / CONSNET /')"
O=$(run_checks "$TMP/t"); has "T6c: a typo (CONSNET) is caught as not a case" "$O" "FAIL (T6c) not a case of tests/test-gov-update.sh: CONSNET"
has "T6d: ... and the real name is reported missing" "$O" "lacks the T6 name(s): CONSENT"
fresh
printf '%s\n' "$DEF_LINE" >> "$G/governance-selftest.sh"
O=$(run_checks "$TMP/t"); has "T6a: a second definition is caught" "$O" "FAIL (T6a) GOV_SELFTEST_UPDATE_DEFAULT defined 2 times"
fresh
sed -i 's/GOV_TEST_ONLY="${GOV_SELFTEST_UPDATE_CASES-$GOV_SELFTEST_UPDATE_DEFAULT}"/GOV_TEST_ONLY="${GOV_SELFTEST_UPDATE_CASES-T1 T2}"/' "$G/governance-selftest.sh"
O=$(run_checks "$TMP/t"); has "T6b: a literal list run instead of the variable is caught" "$O" "FAIL (T6b) case_gov_update does not run"
fresh
sed -i 's/^if want CLOSEPUSH; then/if want CLOSEPUSHX; then/' "$G/tests/test-gov-update.sh"
O=$(run_checks "$TMP/t"); has "T6c: a case renamed in the suite is caught from the default's side" "$O" "FAIL (T6c) not a case of tests/test-gov-update.sh: CLOSEPUSH"

fresh
sed -i '/^    python3\\ \*|python\\ \*|node\\ \*|bash\\ \*|sh\\ \*|pwsh\\ \*|powershell\\ \*) c="\${c#\* }" ;;$/d' "$G/governance-selftest.sh"
O=$(run_checks "$TMP/t"); has "T9a: expand_cmd without the interpreter arm runs python3 <file> inline again (caught)" "$O" "FAIL (T9a) expand_cmd: [python3 ~/.claude/hooks/u.py -> '', want"
fresh
sed -i 's/^  \[ -f "\$first" \] && printf .%s. "\$first" || printf ..$/  printf "%s" "$first"/' "$G/governance-selftest.sh"
O=$(run_checks "$TMP/t"); has "T9a: an expand_cmd that calls everything a file is caught (inline stays inline)" "$O" "[echo hello -> 'echo', want '']"
fresh
sub "$G/governance-selftest.sh" '  if ! _mutant_written NOOP; then :' '  if false; then :'
O=$(run_checks "$TMP/t"); has "T9b: mutate_and_check without the written-mutant guard counts a missing mutant as killed (caught)" "$O" "FAIL (T9b) a mutant that was never written was counted as killed"

echo "[3] benign edits (must not fire)"
fresh
printf '%s\n' "  # was: have=\$(sed -n 's/^terms_version=...' \"\$UPD/terms-accepted\")" >> "$G/gov-update.sh"
printf '%s\n' "  grep -q '^enabled=0 ' \"\$CD/close-push\" && echo off" >> "$G/close-push.sh"
printf '%s\n' "  echo \"  terms: \$(head -1 \"\$UPD/terms-accepted\")\"" >> "$G/gov-update.sh"
sub "$G/governance-selftest.sh" "$DEF_LINE" 'GOV_SELFTEST_UPDATE_DEFAULT="M10 M8 M4 M2 M1 CLOSEPUSH CONSENT MANIFEST NOAUTO T18 T13 T11 T7 T3 T2 T1"'
O=$(run_checks "$TMP/t")
hasnt "a comment, a grep -q match test, a head -1 display and a reordered default fire nothing" "$O" "FAIL ("
has "  ... and T2 still reports the scan" "$O" "PASS (T2)"
has "  ... and T6d still reports every T6 name" "$O" "PASS (T6d)"

# [4] (round 3, B7) verify.sh after a REAL install into a private HOME: on the maintainer's machine
# (the regular file ~/.claude/.governance-source) install.sh records no close-push choice, and
# verify.sh must not fail on it; on a client the record stays required, with its remedy. Agent
# sessions refuse install.sh, so the agent markers are unset for these commands only (as the other
# suites do); the HOME is private (HOME and USERPROFILE), never the real ~/.claude.
# GOV_INVARIANTS_SKIP_INSTALL=1 skips this section (it is the slow part: two installs).
if [ "${GOV_INVARIANTS_SKIP_INSTALL:-0}" = "1" ]; then
  echo "[4] SKIPPED (GOV_INVARIANTS_SKIP_INSTALL=1): verify.sh against a maintainer / client install"
else
echo "[4] verify.sh after install.sh --accept-terms --force --no-verify (private HOME)"
_inst_v() {  # _inst_v <home>: a real install into <home>, outside the agent markers
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u AI_AGENT -u GOV_REPO_PATH -u GOV_RELEASE_KEY \
      -u GOV_CONSENT_SELFTEST -u GOV_CLOSE_PUSH HOME="$1" USERPROFILE="$1" \
      bash "$ROOT/install.sh" --accept-terms --force --no-verify </dev/null >"$1.install.out" 2>&1
}
_verify_v() {  # _verify_v <home>: verify.sh from the tree under test -> O (colours stripped) and rc
  # The operator's own pause never leaks in; VPAUSE=0 sets it for this one run (round 4 #4).
  env -u GOV_CLOSE_PUSH HOME="$1" USERPROFILE="$1" ${VPAUSE:+GOV_CLOSE_PUSH="$VPAUSE"} bash "$ROOT/verify.sh" </dev/null >"$1.verify.out" 2>&1; rc=$?
  O=$(sed 's/\x1b\[[0-9;]*m//g' "$1.verify.out")
}
_pred() {  # _pred <home> -> "ON|reason" / "OFF|reason" of the INSTALLED gov_close_push_on
  ( HOME="$1"; export HOME; unset GOV_CLOSE_PUSH; . "$1/.claude/hooks/governance/consent-lib.sh" 2>/dev/null || { printf 'NOLIB|'; exit 0; }
    if gov_close_push_on; then printf 'ON|%s' "$GOV_CONSENT_REASON"; else printf 'OFF|%s' "$GOV_CONSENT_REASON"; fi )
}
VM="$TMP/home-maint"; VC="$TMP/home-client"; mkdir -p "$VM/.claude" "$VC"
touch "$VM/.claude/.governance-source"
_inst_v "$VM"; rc=$?
if [ "$rc" != 0 ]; then bad "maintainer HOME: install.sh rc=$rc ($(tail -3 "$VM.install.out" | tr '\n' ' '))"
else
  ok "maintainer HOME: install.sh rc 0"
  [ -e "$VM/.claude/.governance-update/close-push" ] && bad "precondition: the maintainer install wrote a close-push record (the case proves nothing)" \
    || ok "precondition: the maintainer install wrote no close-push record (the reviewers' shape)"
  _verify_v "$VM"
  [ "$rc" = 0 ] && ok "maintainer HOME: verify.sh rc 0" || bad "maintainer HOME: verify.sh rc=$rc ($(printf '%s\n' "$O" | grep -E '✗|Results' | tr '\n' ' '))"
  has "  it prints the passing maintainer line" "$O" "✓   push at close: ON - always, on the maintainer's machine"
  hasnt "  and no failed record check" "$O" "✗   push-at-close choice recorded"
  hasnt "  and no FAILED count" "$O" "FAILED"
  # (verify round 4 #4) the line says what gov_close_push_on says: paused by GOV_CLOSE_PUSH=0 - in the
  # process env or in ~/.claude/.governance-local.env - is printed as paused, never "ON - always", and
  # a pause is not a failure (rc 0). The record check is still not required on this machine.
  _VPL="✓   push at close: OFF - paused by GOV_CLOSE_PUSH=0 (on the maintainer's machine it is otherwise always ON; no record expected)"
  VPAUSE=0 _verify_v "$VM"
  [ "$rc" = 0 ] && ok "maintainer + GOV_CLOSE_PUSH=0 (env): verify.sh rc 0 (a pause is not a failure)" || bad "maintainer + pause (env): verify.sh rc=$rc"
  has "  it prints paused" "$O" "$_VPL"
  hasnt "  and not 'ON - always'" "$O" "ON - always"
  printf 'GOV_CLOSE_PUSH=0\n' > "$VM/.claude/.governance-local.env"
  _verify_v "$VM"
  [ "$rc" = 0 ] && ok "maintainer + GOV_CLOSE_PUSH=0 in .governance-local.env: verify.sh rc 0" || bad "maintainer + pause (file): verify.sh rc=$rc"
  has "  it prints paused" "$O" "$_VPL"
  hasnt "  and not 'ON - always'" "$O" "ON - always"
  is "  ... the same answer as the predicate close-push.sh obeys" "$(_pred "$VM")" "OFF|paused by GOV_CLOSE_PUSH=0"
  printf '# GOV_CLOSE_PUSH=0\n' > "$VM/.claude/.governance-local.env"
  _verify_v "$VM"
  has "control: a commented-out pause -> ON - always again" "$O" "✓   push at close: ON - always, on the maintainer's machine"
  rm -f "$VM/.claude/.governance-local.env"
  # (verify round 4 #2) the maintainer branch is unchanged: it reads no terms source at all, so ON
  # holds with the installed terms copy deleted, and nothing was recorded.
  is "maintainer: the predicate says ON (the maintainer reason)" "$(_pred "$VM")" "ON|on (maintainer machine: ~/.claude/.governance-source)"
  mv "$VM/.claude/hooks/governance-terms" "$VM/.claude/hooks/governance-terms.away" 2>/dev/null
  is "maintainer, the installed terms copy moved away: still ON (no terms check on this machine)" "$(_pred "$VM")" "ON|on (maintainer machine: ~/.claude/.governance-source)"
  mv "$VM/.claude/hooks/governance-terms.away" "$VM/.claude/hooks/governance-terms" 2>/dev/null
  # Control: the same HOME with the marker as a DIRECTORY is not the maintainer's machine (the test
  # is consent-lib.sh's, not "something named .governance-source exists").
  rm -f "$VM/.claude/.governance-source"; mkdir "$VM/.claude/.governance-source"
  _verify_v "$VM"
  [ "$rc" = 1 ] && ok "control: marker as a directory, no record -> verify.sh rc 1" || bad "control: marker directory: verify.sh rc=$rc"
  has "  on exactly the record check" "$O" "✗   push-at-close choice recorded"
  rmdir "$VM/.claude/.governance-source"
fi
_inst_v "$VC"; rc=$?
if [ "$rc" != 0 ]; then bad "client HOME: install.sh rc=$rc ($(tail -3 "$VC.install.out" | tr '\n' ' '))"
else
  ok "client HOME: install.sh rc 0"
  _verify_v "$VC"
  [ "$rc" = 0 ] && ok "client HOME with its record: verify.sh rc 0" || bad "client HOME: verify.sh rc=$rc ($(printf '%s\n' "$O" | grep -E '✗|Results' | tr '\n' ' '))"
  has "  the record check passes" "$O" "✓   push-at-close choice recorded"
  hasnt "  no maintainer line on a client" "$O" "maintainer's machine"
  rm -f "$VC/.claude/.governance-update/close-push"
  _verify_v "$VC"
  [ "$rc" = 1 ] && ok "client HOME, no marker, no record: verify.sh rc 1" || bad "client HOME without a record: verify.sh rc=$rc"
  has "  on exactly the record check" "$O" "✗   push-at-close choice recorded"
  has "  with its remedy" "$O" "Some checks failed. Run: bash ~/.claude/governance-installer/install.sh"
fi
fi

# [5] (verify round 4 #2, 2026-10-02) the terms source on CLIENTS. consent-lib.sh used to read its
# second terms source from ~/.claude/governance-installer/bundle/TERMS-VERSION, which install.sh never
# creates: a client who installed from a clone in any other directory answered y and stayed OFF for
# ever (install.sh said "ON", its own summary "OFF (off (...))", close-push.sh --enable refused, and
# re-running install.sh could not help). Now every install puts the terms copy in
# ~/.claude/hooks/governance-terms/. Both directions, real installs into private HOMEs (HOME and
# USERPROFILE), one after the other:
#   (a) a clone OUTSIDE <HOME>/.claude/governance-installer, the y/N answer y -> ON everywhere
#       (record, predicate, summary, gov-update.sh --status, verify.sh, close-push.sh --enable);
#   (b) one source deleted / garbled / disagreeing -> OFF "unclear", and --enable refuses, nothing
#       recorded; the NOTICE copy deleted -> --enable refuses; re-running install.sh restores ON;
#   (c) --uninstall removes the copy;
#   (d) the maintainer's staging layout (<HOME>/.claude/governance-installer/install.sh) still works.
# The question needs a terminal: a COPY of the tree under test whose bundled consent-lib.sh carries a
# terminal test double (gov_interactive_terminal -> 0, the seam test-gov-update.sh CLOSEPUSH (a2) uses),
# and the answer is piped. install.sh and close-push.sh --enable run outside the agent markers (as
# [4]), for those commands only, with HOME and USERPROFILE both the private HOME.
if [ "${GOV_INVARIANTS_SKIP_INSTALL:-0}" = "1" ]; then
  echo "[5] SKIPPED (GOV_INVARIANTS_SKIP_INSTALL=1): the terms source after an install from a clone elsewhere"
else
echo "[5] the terms source after an install from a clone outside ~/.claude/governance-installer (private HOMEs)"
_seam_tree() {  # _seam_tree <dest>: the shippable files of the tree under test + the terminal double
  local f
  rm -rf "$1"; mkdir -p "$1"
  for f in install.sh verify.sh NOTICE-AUTO-UPDATE.md LICENSE README.md bundle RELEASE-MANIFEST RELEASE-MANIFEST.sig; do
    [ -e "$ROOT/$f" ] && cp -r "$ROOT/$f" "$1/"
  done
  printf '\ngov_interactive_terminal() { return 0; }   # TEST DOUBLE (test-release-invariants.sh [5])\n' >> "$1/bundle/hooks/governance/consent-lib.sh"
}
_inst_seam() {  # _inst_seam <home> <tree> <answer> [args...]: install.sh with the y/N answer piped
  local h="$1" t="$2" a="$3"; shift 3
  printf '%b' "$a" | env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u AI_AGENT -u GOV_REPO_PATH -u GOV_RELEASE_KEY \
      -u GOV_CONSENT_SELFTEST -u GOV_CLOSE_PUSH HOME="$h" USERPROFILE="$h" \
      bash "$t/install.sh" --accept-terms --no-verify "$@" >"$h.install.out" 2>&1
}
_enable5() {  # _enable5 <home> <answer>: the INSTALLED close-push.sh --enable, the answer piped -> rc, $h.enable.out
  # Outside the agent markers, like install.sh above: the sandbox nonce cannot be used here, because
  # with USERPROFILE set to the private HOME consent-lib.sh rightly treats that HOME as the real one.
  printf '%b' "$2" | env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u AI_AGENT -u GOV_CONSENT_SELFTEST -u GOV_CLOSE_PUSH \
      HOME="$1" USERPROFILE="$1" bash "$1/.claude/hooks/governance/close-push.sh" --enable >"$1.enable.out" 2>&1
}
_status5() { env -u GOV_CLOSE_PUSH HOME="$1" USERPROFILE="$1" bash "$1/.claude/hooks/governance/gov-update.sh" --status </dev/null 2>&1 | grep 'push at close:'; }
_rf() { ( . "$GOV_DIR/consent-lib.sh" && gov_record_field "$1/.claude/.governance-update/close-push" "$2" ); }   # the one parser
_QEND5='Turn push at session close ON now? [y/N]: '
_ON5='ON|on (your choice)'

# (a) a clone elsewhere, answer y
TS="$TMP/elsewhere/claude-code-governance"; VE="$TMP/home-elsewhere"; mkdir -p "$VE"
_seam_tree "$TS"
_inst_seam "$VE" "$TS" 'y\n'; rc=$?
if [ "$rc" != 0 ]; then bad "(a) clone elsewhere + y: install.sh rc=$rc ($(tail -3 "$VE.install.out" | tr '\n' ' '))"
else
  ok "(a) clone elsewhere + y: install.sh rc 0"
  _IO=$(sed 's/\x1b\[[0-9;]*m//g' "$VE.install.out")
  is "  precondition: no <HOME>/.claude/governance-installer (the clone is elsewhere)" "$([ -e "$VE/.claude/governance-installer" ] && echo present || echo absent)" "absent"
  is "  the record: enabled=1 method=interactive" "$(_rf "$VE" enabled)/$(_rf "$VE" method)" "1/interactive"
  is "  the installed terms copy: TERMS-VERSION = the bundle's" "$(tr -d '[:space:]' < "$VE/.claude/hooks/governance-terms/TERMS-VERSION" 2>/dev/null)" "$(tr -d '[:space:]' < "$TS/bundle/TERMS-VERSION")"
  is "  the installed terms copy: the NOTICE, byte for byte" "$(cmp -s "$VE/.claude/hooks/governance-terms/NOTICE-AUTO-UPDATE.md" "$TS/NOTICE-AUTO-UPDATE.md" && echo same || echo differs)" "same"
  is "  gov_close_push_on: ON (your choice) - the user's y holds (was: off, unclear)" "$(_pred "$VE")" "$_ON5"
  has "  the decision line says ON" "$_IO" "Push at session close: ON ("
  has "  ... and the summary agrees: ON" "$_IO" "  Push at session close:  ON (since "
  hasnt "  ... never 'OFF (off (' (round 4 minor: the double wrap)" "$_IO" "OFF (off ("
  has "  gov-update.sh --status: ON (your choice)" "$(_status5 "$VE")" "push at close:    ON (your choice, recorded "
  _verify_v "$VE"
  [ "$rc" = 0 ] && ok "  verify.sh rc 0" || bad "  verify.sh rc=$rc ($(printf '%s\n' "$O" | grep -E '✗|Results' | tr '\n' ' '))"
  # close-push.sh --enable works on this machine: --disable, then --enable answering y
  env -u GOV_CLOSE_PUSH HOME="$VE" USERPROFILE="$VE" bash "$VE/.claude/hooks/governance/close-push.sh" --disable </dev/null >/dev/null 2>&1
  is "  --disable: OFF (your choice)" "$(_pred "$VE")" "OFF|off (your choice)"
  _enable5 "$VE" 'y\n'; rc=$?
  _EO=$(cat "$VE.enable.out"); _pre="${_EO%%"$_QEND5"*}"
  is "  close-push.sh --enable + y: rc 0, enabled=1 method=close-push-enable (was: 'no terms text on this machine')" "$rc/$(_rf "$VE" enabled)/$(_rf "$VE" method)" "0/1/close-push-enable"
  has "  ... it showed the question with the INSTALLED NOTICE path" "$_pre" "Full text: $VE/.claude/hooks/governance-terms/NOTICE-AUTO-UPDATE.md, sections 2a and 10.3"
  is "  ... shown_sha256 = the hash of exactly the bytes it printed" "$(_rf "$VE" shown_sha256)" "$(printf '%s%s' "$_pre" "$_QEND5" | tr -d '\r' | sha256sum | cut -d' ' -f1)"
  is "  ... notice_sha256 = the installed NOTICE copy" "$(_rf "$VE" notice_sha256)" "$(tr -d '\r' < "$VE/.claude/hooks/governance-terms/NOTICE-AUTO-UPDATE.md" | sha256sum | cut -d' ' -f1)"
  has "  ... and says ON" "$_EO" "Push at session close: ON ("
  is "  gov_close_push_on after --enable: ON" "$(_pred "$VE")" "$_ON5"

  # (b) the other direction: one source deleted / garbled / disagreeing -> OFF, unclear; --enable refuses
  _TV="$VE/.claude/hooks/governance-terms/TERMS-VERSION"; _TVS=$(cat "$_TV")
  _UNCL5='the installed terms version is unclear on this machine'
  rm -f "$_TV"
  is "(b) the installed TERMS-VERSION copy deleted -> OFF, unclear" "$(_pred "$VE")" "OFF|off (installed terms version unclear: installed.manifest says v$_TVS, TERMS-VERSION says nothing usable; re-run install.sh)"
  has "  gov-update.sh --status says OFF, unclear" "$(_status5 "$VE")" "push at close:    OFF (installed terms version unclear"
  cp "$VE/.claude/.governance-update/close-push" "$TMP/cp5.before"
  _enable5 "$VE" 'y\n'; rc=$?
  is "  close-push.sh --enable + y: refused (rc 1), the record unchanged" "$rc/$(cmp -s "$VE/.claude/.governance-update/close-push" "$TMP/cp5.before" && echo same || echo changed)" "1/same"
  has "  ... saying why, before any question" "$(cat "$VE.enable.out")" "$_UNCL5"
  hasnt "  ... no question was shown" "$(cat "$VE.enable.out")" "[y/N]"
  printf 'one\n' > "$_TV"
  is "  the copy garbled ('one') -> OFF, unclear" "$(_pred "$VE")" "OFF|off (installed terms version unclear: installed.manifest says v$_TVS, TERMS-VERSION says nothing usable; re-run install.sh)"
  printf '%s\n' "$((_TVS + 1))" > "$_TV"
  is "  the copy disagreeing (v$((_TVS + 1)) vs the manifest's v$_TVS) -> OFF, unclear" "$(_pred "$VE")" "OFF|off (installed terms version unclear: installed.manifest says v$_TVS, TERMS-VERSION says v$((_TVS + 1)); re-run install.sh)"
  printf '%s\n' "$_TVS" > "$_TV"
  is "  control: the copy restored -> ON" "$(_pred "$VE")" "$_ON5"
  mv "$VE/.claude/hooks/governance-terms/NOTICE-AUTO-UPDATE.md" "$TMP/notice5.away"
  _enable5 "$VE" 'y\n'; rc=$?
  is "  the NOTICE copy missing: --enable refused (rc 1), the record unchanged" "$rc/$(cmp -s "$VE/.claude/.governance-update/close-push" "$TMP/cp5.before" && echo same || echo changed)" "1/same"
  has "  ... naming the missing copy and the remedy that works" "$(cat "$VE.enable.out")" "no terms text on this machine (~/.claude/hooks/governance-terms/NOTICE-AUTO-UPDATE.md is missing): re-run install.sh"
  # the remedy: both copies gone, install.sh re-run (no answer needed: the current record is kept)
  rm -rf "$VE/.claude/hooks/governance-terms"
  has "  both copies gone -> OFF, unclear" "$(_pred "$VE")" "OFF|off (installed terms version unclear: installed.manifest says v$_TVS, TERMS-VERSION says nothing usable"
  _inst_seam "$VE" "$TS" ''; rc=$?
  is "  the remedy, install.sh re-run: rc 0, the copies back, ON again" "$rc/$([ -s "$_TV" ] && [ -s "$VE/.claude/hooks/governance-terms/NOTICE-AUTO-UPDATE.md" ] && echo copies || echo missing)/$(_pred "$VE")" "0/copies/$_ON5"
  # (c) --uninstall removes the copy (with the rest of ~/.claude/hooks/) and keeps the records
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u AI_AGENT HOME="$VE" USERPROFILE="$VE" bash "$TS/install.sh" --uninstall </dev/null >"$VE.uninstall.out" 2>&1; rc=$?
  is "(c) --uninstall: rc 0, the terms copy gone, the close-push record kept" "$rc/$([ -e "$VE/.claude/hooks/governance-terms" ] && echo present || echo gone)/$(_rf "$VE" enabled)" "0/gone/1"
fi

# (d) the maintainer's staging layout: the clone AT <HOME>/.claude/governance-installer, answer y
VS="$TMP/home-staging"; mkdir -p "$VS/.claude"
_seam_tree "$VS/.claude/governance-installer"
_inst_seam "$VS" "$VS/.claude/governance-installer" 'y\n'; rc=$?
if [ "$rc" != 0 ]; then bad "(d) staging layout + y: install.sh rc=$rc ($(tail -3 "$VS.install.out" | tr '\n' ' '))"
else
  is "(d) staging layout + y: rc 0, the terms copy installed, ON" "$rc/$([ -s "$VS/.claude/hooks/governance-terms/TERMS-VERSION" ] && echo copy || echo nocopy)/$(_pred "$VS")" "0/copy/$_ON5"
  has "  the summary agrees: ON" "$(sed 's/\x1b\[[0-9;]*m//g' "$VS.install.out")" "  Push at session close:  ON (since "
fi
fi

echo "release-invariants selftest: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ] && exit 0
exit 1
