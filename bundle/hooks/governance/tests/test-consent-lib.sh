#!/usr/bin/env bash
# test-consent-lib.sh - coverage for consent-lib.sh (2026-09-30, legal conditions T2 T3 S2 S4 C3 C5;
# fix round 1: D2 terminal predicate, D3 no source-marker exemption, D5 reason; 2026-10-01 owner
# decision: the maintainer's machine is always on, clients answer a plain y/N; round-2 findings 7
# (NOTICE 10.1 item 6), 11 (installed terms version from two sources, fail closed) and 13
# (shown_sha256 = the bytes printed). Section [14] holds the NOTICE assertions for this group).
# Round 3 (2026-10-02): a terms source that is absent or not an integer fails closed ([1b]); an OFF
# record says "your choice" only for an answer the person gave ([1d]); the NOTICE must DISCLOSE the
# maintainer marker ([14] probe, [16] the shipped text); [15]'s dry runs run one after the other.
# Verify round 4 (2026-10-02): the second terms source is the INSTALLED copy
# ~/.claude/hooks/governance-terms/TERMS-VERSION, not ~/.claude/governance-installer/bundle/ ([1e]);
# one OFF-wording list (gov_close_push_off_kind) and the unwrapped reason (gov_reason_text) ([1f]);
# install.sh reads the marker through gov_maintainer_machine and installs the terms copy ([15]).
#
# Every check runs against a SANDBOX HOME; nothing under the real ~/.claude is read or written.
# Both directions for every rule: the must-fire case AND the must-not-fire control, asserting the
# printed text (the reason string, the value, the bytes), not only a return code.
#
# The suite runs inside AI-agent sessions (CLAUDECODE / AI_AGENT / CLAUDE_CODE_ENTRYPOINT set).
# It never unsets those markers to get past the refusal (T4): the refusal is bypassed only by the
# sandbox nonce under a non-real HOME. The one place all markers are cleared is the "[17c]" check,
# which tests the detection's OWN negative direction ("no markers -> not an agent") in a subshell.
#
# Output ends with:  consent-lib selftest: pass=<n> fail=<n> skip=<n>   (exit 1 on any fail or pass=0)
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$GOV_DIR/consent-lib.sh"
PASS=0; FAIL=0; SKIP=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  skip %s\n' "$1"; SKIP=$((SKIP+1)); }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got [$2] want [$3])"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no [$3] in [$2])" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ([$3] present in [$2])" ;; *) ok "$1" ;; esac; }

[ -f "$LIB" ] || { echo "  FAIL consent-lib.sh missing at $LIB"; echo "consent-lib selftest: pass=0 fail=1 skip=0"; exit 1; }

SBX=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/gov-consent-$$")
mkdir -p "$SBX"
SBX=$(cd "$SBX" && pwd -P)
H="$SBX/home"; D="$H/.claude/.governance-update"
mkdir -p "$D" "$SBX/other"
trap 'rm -rf "$SBX"' EXIT
NONCE="nonce-$$-$RANDOM$RANDOM"
printf '%s\n' "$NONCE" > "$H/.governance-consent-selftest"

# lib <cmd...> -> runs <cmd> in a subshell with HOME=sandbox and the library sourced. The pause
# variable and the old auto-update variable are cleared so the operator's env cannot leak in.
lib() { ( HOME="$H"; export HOME; unset GOV_CLOSE_PUSH GOV_AUTO_UPDATE GOV_ACCEPT_TERMS; . "$LIB"; "$@" ); }
# cps -> "ON|reason" or "OFF|reason" of gov_close_push_on
cps() { lib _cps; }
_cps() { if gov_close_push_on; then printf 'ON|%s' "$GOV_CONSENT_REASON"; else printf 'OFF|%s' "$GOV_CONSENT_REASON"; fi; }
# TC: the INSTALLED terms copy (consent-lib.sh gov_terms_copy_dir; verify round 4 #2, 2026-10-02) -
# the second terms source. The old one, ~/.claude/governance-installer/bundle/TERMS-VERSION, existed
# only for a clone at exactly that path ([1e] proves it is no longer read).
TC="$H/.claude/hooks/governance-terms"
reset_records() { rm -f "$D/close-push" "$D/terms-accepted" "$D/installed.manifest" "$D/auto-update" "$H/.claude/.governance-local.env"; rm -rf "$H/.claude/governance-installer" "$H/.claude/.governance-source" "$TC"; }
tvfile() { mkdir -p "$TC"; printf '%s\n' "$1" > "$TC/TERMS-VERSION"; }
notv() { rm -rf "$TC"; }   # the installed copy absent
manif() { printf '# claude-code-governance release manifest v1\nversion=2.0.1\nterms_version=%s\n[files]\n' "$1" > "$D/installed.manifest"; }
inst() { manif "$1"; tvfile "$1"; }   # both terms sources at v<n>: what install.sh leaves on a client
marker() { mkdir -p "$H/.claude"; : > "$H/.claude/.governance-source"; }
rec()  { printf '%s\n' "$1" > "$D/close-push"; }
acc()  { printf '%s\n' "$1" > "$D/terms-accepted"; }
envf() { printf '%s\n' "$@" > "$H/.claude/.governance-local.env"; }
ON='ON|on (your choice)'
PAUSED='OFF|paused by GOV_CLOSE_PUSH=0'
STALE2='OFF|off (terms changed to v2; accept them, then turn it on again in your own terminal: bash ~/.claude/hooks/governance/close-push.sh --enable)'

echo "[1] gov_close_push_on - the truth table (a client: both terms sources installed, as install.sh leaves them)"
reset_records; inst 1
is "no record -> off, 'no choice recorded (off)'" "$(cps)" 'OFF|no choice recorded (off)'
rec 'enabled=0 terms_version=1 recorded_at=2026-09-30T00:00:00Z method=declined'
acc 'terms_version=1 accepted_at=2026-09-30T00:00:00Z framework_version=2.0.0 method=interactive'
is "enabled=0 (method=declined) -> off, 'off (your choice)'" "$(cps)" 'OFF|off (your choice)'
rec 'enabled=1 terms_version=1 recorded_at=2026-09-30T00:00:00Z method=interactive'
is "enabled=1 under the installed terms, terms accepted -> ON (must-fire)" "$(cps)" "$ON"
rm -f "$D/terms-accepted"
is "enabled=1 but no terms-accepted record -> off (terms changed)" "$(cps)" \
   'OFF|off (terms changed to v1; accept them, then turn it on again in your own terminal: bash ~/.claude/hooks/governance/close-push.sh --enable)'
acc 'terms_version=1 method=interactive'
inst 2
is "stale close-push record (tv1 < installed v2) -> off (terms changed to v2)" "$(cps)" "$STALE2"
acc 'terms_version=2 method=--accept-terms'
is "finding 9: terms re-accepted (v2) but the close-push record still v1 -> still off, same reason" "$(cps)" "$STALE2"
has "  ... and the reason names the step that DOES turn it back on (close-push.sh --enable, a terminal)" "$(cps)" "in your own terminal: bash ~/.claude/hooks/governance/close-push.sh --enable"
hasnt "  ... and no longer claims re-accepting alone is enough" "$(cps)" "re-accept: gov-update.sh --accept-terms"
acc 'terms_version=1 method=interactive'
rec 'enabled=1 terms_version=2'
is "record current, stale terms-accepted (tv1 < v2) -> off (terms changed to v2)" "$(cps)" "$STALE2"
acc 'terms_version=2 method=interactive'
is "record and terms-accepted both at v2 -> ON (control)" "$(cps)" "$ON"
printf 'version=2.0.1\n[files]\nterms_version=9\n' > "$D/installed.manifest"; tvfile 1
rec 'enabled=1 terms_version=1'; acc 'terms_version=1'
is "terms_version below [files] is not the header -> the manifest states nothing -> off, fail closed (round 3)" "$(cps)" \
   'OFF|off (installed terms version unclear: installed.manifest says nothing usable, TERMS-VERSION says v1; re-run install.sh)'
is "  ... and installed stays v1 (the [files] value is not read)" "$(lib gov_installed_terms_version)" "1"

echo "[1b] finding 11 - the installed terms version: two sources, the highest counts, a disagreement fails closed"
UNCLEAR='OFF|off (installed terms version unclear: installed.manifest says v1, TERMS-VERSION says v2; re-run install.sh)'
reset_records; rec 'enabled=1 terms_version=1'; acc 'terms_version=2'; manif 2; tvfile 2
is "reproduction baseline: record v1, manifest v2, TERMS-VERSION 2 -> off (terms changed to v2)" "$(cps)" "$STALE2"
manif 1
is "finding 11: manifest LOWERED to v1 (a session's edit), TERMS-VERSION still 2 -> OFF, the sources disagree" "$(cps)" "$UNCLEAR"
hasnt "  ... and it is not 'on (your choice)' (the old code returned ON here)" "$(cps)" "ON|"
is "  ... gov_installed_terms_version takes the highest (2), not the manifest's 1" "$(lib gov_installed_terms_version)" "2"
manif 2; tvfile 1
is "the other way round: TERMS-VERSION lowered to 1, manifest 2 -> installed stays 2" "$(lib gov_installed_terms_version)" "2"
is "  ... and the predicate is off, naming both values" "$(cps)" \
   'OFF|off (installed terms version unclear: installed.manifest says v2, TERMS-VERSION says v1; re-run install.sh)'
rec 'enabled=1 terms_version=2'; manif 2; tvfile 2
is "both sources agree on v2, record and acceptance v2 -> ON (control)" "$(cps)" "$ON"
manif 1; tvfile 1; rec 'enabled=1 terms_version=1'; acc 'terms_version=1'
is "both sources lowered together to v1 -> ON (stated limit L1: editing both is not detected)" "$(cps)" "$ON"
# Round 3 (consent-security minor, MEASURED before the fix: each of the five cases below returned
# "on (your choice)"): a source that is ABSENT or NOT AN INTEGER fails closed too - with one source
# missing, lowering the other was undetected. The reason names what each source says.
U_NONE_1='OFF|off (installed terms version unclear: installed.manifest says nothing usable, TERMS-VERSION says v1; re-run install.sh)'
U_1_NONE='OFF|off (installed terms version unclear: installed.manifest says v1, TERMS-VERSION says nothing usable; re-run install.sh)'
U_NONE_NONE='OFF|off (installed terms version unclear: installed.manifest says nothing usable, TERMS-VERSION says nothing usable; re-run install.sh)'
reset_records; rec 'enabled=1 terms_version=1'; acc 'terms_version=1'; inst 1
is "round 3 control: both sources v1, record and acceptance v1 -> ON" "$(cps)" "$ON"
rm -f "$D/installed.manifest"
is "round 3: manifest ABSENT, TERMS-VERSION 1 -> OFF, unclear (was: on)" "$(cps)" "$U_NONE_1"
manif 1; notv
is "round 3: TERMS-VERSION ABSENT, manifest 1 -> OFF, unclear (was: on)" "$(cps)" "$U_1_NONE"
rm -f "$D/installed.manifest"
is "round 3: BOTH absent -> OFF, unclear (was: on)" "$(cps)" "$U_NONE_NONE"
hasnt "  ... and never 'on (your choice)'" "$(cps)" "ON|"
inst 1; printf '1x\n' > "$TC/TERMS-VERSION"
is "round 3: TERMS-VERSION '1x' (not an integer), manifest 1 -> OFF, unclear (was: on)" "$(cps)" "$U_1_NONE"
inst 1; manif v1
is "round 3: manifest 'v1' (not an integer), TERMS-VERSION 1 -> OFF, unclear (was: on)" "$(cps)" "$U_NONE_1"
inst 1; rm -f "$D/installed.manifest"; tvfile 2; rec 'enabled=1 terms_version=1'; acc 'terms_version=1'
is "manifest absent, TERMS-VERSION 2 -> OFF, unclear (no longer read as one clear source)" "$(cps)" \
   'OFF|off (installed terms version unclear: installed.manifest says nothing usable, TERMS-VERSION says v2; re-run install.sh)'
manif 2; notv
is "TERMS-VERSION absent, manifest 2 -> OFF, unclear" "$(cps)" \
   'OFF|off (installed terms version unclear: installed.manifest says v2, TERMS-VERSION says nothing usable; re-run install.sh)'
manif 01; tvfile 1; rec 'enabled=1 terms_version=1'
is "manifest '01' and TERMS-VERSION '1' are the same number -> not a disagreement -> ON" "$(cps)" "$ON"
rec 'enabled=0 terms_version=1 method=declined'; manif 1; tvfile 2
is "an enabled=0 record with disagreeing sources -> the reason is the choice" "$(cps)" 'OFF|off (your choice)'
rec 'enabled=0 terms_version=1 method=declined'; rm -f "$D/installed.manifest"; notv
is "  ... and with both sources absent, still the choice (an OFF record is read before the sources)" "$(cps)" 'OFF|off (your choice)'

echo "[1e] verify round 4 #2 - the second terms source is the INSTALLED copy, wherever the clone was"
# What install.sh leaves after an install from a clone in ANY directory: installed.manifest and
# ~/.claude/hooks/governance-terms/TERMS-VERSION - and NO ~/.claude/governance-installer at all.
reset_records; manif 1; tvfile 1; rec 'enabled=1 terms_version=1 decided_at=2026-10-02T00:00:00Z method=interactive'; acc 'terms_version=1'
is "precondition: no ~/.claude/governance-installer in this HOME" "$([ -e "$H/.claude/governance-installer" ] && echo present || echo absent)" "absent"
is "a client that installed from a clone elsewhere and answered y -> ON (was: off, unclear)" "$(cps)" "$ON"
is "  ... gov_terms_copy_dir is under ~/.claude/hooks/ (removed by --uninstall)" "$(lib gov_terms_copy_dir)" "$H/.claude/hooks/governance-terms"
is "  ... _gov_terms_sources reads the copy" "$(lib _gov_terms_sources)" "1 1"
notv; mkdir -p "$H/.claude/governance-installer/bundle"; printf '1\n' > "$H/.claude/governance-installer/bundle/TERMS-VERSION"
is "the OLD location alone (an installer clone at ~/.claude/governance-installer, no installed copy) is not a source -> OFF, unclear" "$(cps)" "$U_1_NONE"
rm -rf "$H/.claude/governance-installer"; tvfile 1
is "  ... the installed copy restored -> ON (control)" "$(cps)" "$ON"
printf '\n' > "$TC/TERMS-VERSION"
is "the installed copy EMPTY -> OFF, unclear" "$(cps)" "$U_1_NONE"
printf 'one\n' > "$TC/TERMS-VERSION"
is "the installed copy GARBLED ('one') -> OFF, unclear" "$(cps)" "$U_1_NONE"
tvfile 1; rm -f "$D/installed.manifest"
is "the manifest deleted, the copy kept -> OFF, unclear" "$(cps)" "$U_NONE_1"
manif 1; tvfile 0
is "the copy LOWERED to 0 (manifest 1) -> OFF, the sources disagree (finding 11 kept)" "$(cps)" \
   'OFF|off (installed terms version unclear: installed.manifest says v1, TERMS-VERSION says v0; re-run install.sh)'
is "  ... and lowering it never lowers the installed version (the highest, 1)" "$(lib gov_installed_terms_version)" "1"
tvfile 1; is "both sources back at v1 -> ON (control)" "$(cps)" "$ON"

echo "[1f] verify round 4 minors - one OFF-wording list, the reason without its wrapper"
for m in declined close-push-disable --no-close-push; do is "gov_close_push_off_kind $m -> choice" "$(lib gov_close_push_off_kind "$m")" "choice"; done
for m in default-non-interactive default-agent-session; do is "gov_close_push_off_kind $m -> default" "$(lib gov_close_push_off_kind "$m")" "default"; done
is "gov_close_push_off_kind terms-changed -> terms" "$(lib gov_close_push_off_kind terms-changed)" "terms"
for m in '' kept selftest declinedx interactive; do is "gov_close_push_off_kind [$m] -> recorded" "$(lib gov_close_push_off_kind "$m")" "recorded"; done
is "gov_close_push_on words its OFF reasons from gov_close_push_off_kind (one list)" \
   "$(tr -d '\r' < "$LIB" | grep -c 'case "$(gov_close_push_off_kind "$(gov_record_field "$rec" method)")" in')" "1"
is "gov_reason_text strips the 'off (...)' wrapper" "$(lib gov_reason_text 'off (your choice)')" "your choice"
is "gov_reason_text keeps a nested parenthesis" "$(lib gov_reason_text 'off (installed terms version unclear: a (b); re-run install.sh)')" "installed terms version unclear: a (b); re-run install.sh"
is "gov_reason_text leaves the pause as it is" "$(lib gov_reason_text 'paused by GOV_CLOSE_PUSH=0')" "paused by GOV_CLOSE_PUSH=0"
is "gov_reason_text leaves 'no choice recorded (off)' as it is" "$(lib gov_reason_text 'no choice recorded (off)')" "no choice recorded (off)"

echo "[1d] OPEN-PROBLEMS #39 item 11 - an OFF record says 'your choice' only when the person answered"
reset_records; inst 1; acc 'terms_version=1'
for m in declined close-push-disable --no-close-push; do
  rec "enabled=0 terms_version=1 decided_at=2026-01-01T00:00:00Z method=$m"
  is "method=$m (an answer the person gave) -> off (your choice)" "$(cps)" 'OFF|off (your choice)'
done
for m in default-non-interactive default-agent-session; do
  rec "enabled=0 terms_version=1 decided_at=2026-01-01T00:00:00Z method=$m"
  is "method=$m (install.sh's default, no question asked) -> off (the default: you were not asked)" "$(cps)" 'OFF|off (the default: you were not asked)'
  hasnt "  ... and never 'your choice'" "$(cps)" "your choice"
done
rec 'enabled=0 terms_version=1 decided_at=2026-01-01T00:00:00Z method=terms-changed'
is "method=terms-changed -> off (turned off when the terms changed)" "$(cps)" 'OFF|off (turned off when the terms changed)'
hasnt "  ... and never 'your choice'" "$(cps)" "your choice"
rec 'enabled=0 terms_version=1'
is "no method= -> off (recorded off): nothing says the person chose" "$(cps)" 'OFF|off (recorded off)'
rec 'enabled=0 terms_version=1 method=selftest'
is "an unknown method -> off (recorded off)" "$(cps)" 'OFF|off (recorded off)'
rec 'enabled=0 terms_version=1 method=declinedx'
is "a method that only starts like an answer (declinedx) -> off (recorded off)" "$(cps)" 'OFF|off (recorded off)'
rec 'enabled=1 terms_version=1 method=interactive'
is "control: an enabled=1 record under the installed terms -> ON (the ON reason is unchanged)" "$(cps)" "$ON"

echo "[1c] the maintainer's machine (owner decision 2026-10-01): always on, no record"
MAINT='ON|on (maintainer machine: ~/.claude/.governance-source)'
reset_records; marker
is "marker file, no record, no terms accepted -> ON, the maintainer reason" "$(cps)" "$MAINT"
is "  ... and nothing was written: no close-push, no terms-accepted record" "$( [ -e "$D/close-push" ] || [ -e "$D/terms-accepted" ] && echo written || echo none)" "none"
rec 'enabled=0 terms_version=1'; acc 'terms_version=1'
is "marker + a recorded enabled=0 -> still ON (always on)" "$(cps)" "$MAINT"
rec 'enabled=1 terms_version=0'; manif 3; tvfile 5
is "marker + a stale record and disagreeing terms sources -> still ON (no terms check here)" "$(cps)" "$MAINT"
envf 'GOV_CLOSE_PUSH=0'
is "marker + GOV_CLOSE_PUSH=0 in the local env file -> paused" "$(cps)" "$PAUSED"
is "marker + GOV_CLOSE_PUSH=0 in the process env -> paused" "$( ( HOME="$H"; export HOME GOV_CLOSE_PUSH=0; rm -f "$H/.claude/.governance-local.env"; . "$LIB"; _cps ) )" "$PAUSED"
reset_records; mkdir -p "$H/.claude/.governance-source"
is "the marker as a DIRECTORY is not the maintainer's machine -> the client rule (no choice recorded)" "$(cps)" 'OFF|no choice recorded (off)'
is "  ... gov_maintainer_machine says no" "$(lib gov_maintainer_machine && echo yes || echo no)" "no"
rmdir "$H/.claude/.governance-source"
if ln -s "$SBX/other" "$H/.claude/.governance-source" 2>/dev/null && [ -L "$H/.claude/.governance-source" ]; then
  : > "$SBX/other/f"; rm -f "$H/.claude/.governance-source"; ln -s "$SBX/other/f" "$H/.claude/.governance-source"
  is "the marker as a SYMLINK to a file -> not the marker" "$(lib gov_maintainer_machine && echo yes || echo no)" "no"
  rm -f "$H/.claude/.governance-source" "$SBX/other/f"
else skip "no symlinks on this filesystem (MSYS copies instead of linking) - the symlink refusal is asserted where links exist"; fi
reset_records
is "no marker, no record (control) -> the client rule, off" "$(cps)" 'OFF|no choice recorded (off)'
marker; is "gov_maintainer_machine with the marker file -> yes (control)" "$(lib gov_maintainer_machine && echo yes || echo no)" "yes"
is "the maintainer's machine does not make gov_human_consent_ok pass in an agent session (D3)" \
   "$( ( HOME="$H"; export HOME CLAUDECODE=1 GOV_CONSENT_SELFTEST=; . "$LIB"; gov_human_consent_ok && echo human-ok || echo refused ) )" "refused"
reset_records

echo "[2] gov_close_push_on - the pause (GOV_CLOSE_PUSH=0: env, file, quoted)"
reset_records; inst 1; rec 'enabled=1 terms_version=1'; acc 'terms_version=1'
is "GOV_CLOSE_PUSH=0 in the process env -> paused" "$( ( HOME="$H"; export HOME GOV_CLOSE_PUSH=0; . "$LIB"; _cps ) )" "$PAUSED"
envf 'GOV_CLOSE_PUSH=0'
is "GOV_CLOSE_PUSH=0 in the local env file -> paused" "$(cps)" "$PAUSED"
envf '# a comment' 'export GOV_CLOSE_PUSH=0   # pause'
is "'export GOV_CLOSE_PUSH=0  # comment' in the file -> paused" "$(cps)" "$PAUSED"
envf 'GOV_CLOSE_PUSH="0"'
is "GOV_CLOSE_PUSH=\"0\" (double-quoted) -> paused" "$(cps)" "$PAUSED"
envf "GOV_CLOSE_PUSH='0'"
is "GOV_CLOSE_PUSH='0' (single-quoted) -> paused" "$(cps)" "$PAUSED"
envf 'GOV_CLOSE_PUSH=0' 'GOV_CLOSE_PUSH=1'
is "the LAST assignment wins (0 then 1) -> ON (control)" "$(cps)" "$ON"
envf 'GOV_CLOSE_PUSH=1'
is "GOV_CLOSE_PUSH=1 in the file -> ON (control)" "$(cps)" "$ON"
envf 'GOV_CLOSE_PUSH=0'
is "env GOV_CLOSE_PUSH=1 beats the file's 0 (env first) -> ON" "$( ( HOME="$H"; export HOME GOV_CLOSE_PUSH=1; . "$LIB"; _cps ) )" "$ON"
envf '#GOV_CLOSE_PUSH=0' 'XGOV_CLOSE_PUSH=0'
is "a commented-out or longer-named assignment is not the pause -> ON" "$(cps)" "$ON"
envf 'GOV_CLOSE_PUSH=0'
rec 'enabled=0 terms_version=1 method=close-push-disable'
is "pause + enabled=0 -> the reason is the choice, not the pause" "$(cps)" 'OFF|off (your choice)'

echo "[3] gov_close_push_on - unreadable records"
reset_records; inst 1; acc 'terms_version=1'
rec 'enabled=yes terms_version=1'; is "enabled=yes -> off (record unreadable)" "$(cps)" 'OFF|off (record unreadable)'
rec 'enabled=1 terms_version=x';   is "terms_version=x -> off (record unreadable)" "$(cps)" 'OFF|off (record unreadable)'
: > "$D/close-push";                 is "empty record -> off (record unreadable)" "$(cps)" 'OFF|off (record unreadable)'
printf 'enabled=1 terms_version=1\r\n' > "$D/close-push"
is "CRLF record enabled=1 -> ON (CR ignored)" "$(cps)" "$ON"
printf 'enabled=1\tterms_version=1\n' > "$D/close-push"
is "tab-separated record -> ON" "$(cps)" "$ON"

echo "[4] gov_installed_terms_version"
reset_records
is "nothing installed -> 1" "$(lib gov_installed_terms_version)" "1"
mkdir -p "$TC"; printf '3\r\n' > "$TC/TERMS-VERSION"
is "no manifest, installed TERMS-VERSION copy=3 (CRLF) -> 3" "$(lib gov_installed_terms_version)" "3"
printf 'version=2.0.0\nterms_version=4\n[files]\n' > "$D/installed.manifest"
is "manifest header terms_version=4, TERMS-VERSION 3 -> the highest, 4" "$(lib gov_installed_terms_version)" "4"
printf 'version=2.0.0\nterms_version=2\n[files]\n' > "$D/installed.manifest"
is "manifest header terms_version=2, TERMS-VERSION 3 -> the highest, 3 (a lower manifest no longer wins)" "$(lib gov_installed_terms_version)" "3"
is "_gov_terms_sources prints both values" "$(lib _gov_terms_sources)" "2 3"
printf 'version=2.0.0\nterms_version=abc\n[files]\n' > "$D/installed.manifest"
is "non-integer manifest value -> falls back to TERMS-VERSION (3)" "$(lib gov_installed_terms_version)" "3"

echo "[5] gov_auto_update_on - always off in this version"
reset_records; acc 'terms_version=1'
printf 'enabled=1 terms_version=1 accepted_at=2026-09-30T00:00:00Z method=interactive\n' > "$D/auto-update"
envf 'GOV_AUTO_UPDATE=1'
o=$( ( HOME="$H"; export HOME GOV_AUTO_UPDATE=1; . "$LIB"; if gov_auto_update_on; then printf 'ON|%s' "$GOV_CONSENT_REASON"; else printf 'OFF|%s' "$GOV_CONSENT_REASON"; fi ) )
is "GOV_AUTO_UPDATE=1 (env + file) + planted auto-update enabled=1 -> OFF, exact reason" "$o" \
   'OFF|automatic updates are not available in this version'
is "control: the planted record IS readable (enabled=1), so the predicate ignores it, not misses it" \
   "$(lib gov_record_field "$D/auto-update" enabled)" "1"
is "control: GOV_AUTO_UPDATE=1 IS readable from the file" "$(lib gov_local_env_get GOV_AUTO_UPDATE)" "1"
is "the library's code names no GOV_AUTO_UPDATE and no auto-update record" \
   "$(grep -v '^[[:space:]]*#' "$LIB" | grep -cE 'GOV_AUTO_UPDATE|/auto-update')" "0"

echo "[6] gov_record_field - the one parser"
reset_records
printf 'enabled=0 terms_version=1\nenabled=1\n' > "$D/x"
is "first line only (a second line's enabled=1 is ignored)" "$(lib gov_record_field "$D/x" enabled)" "0"
printf 'xenabled=1 enabled=0 notice_sha256=abc\n' > "$D/x"
is "exact key, not a suffix match (xenabled=1 is not enabled)" "$(lib gov_record_field "$D/x" enabled)" "0"
is "another key on the same line" "$(lib gov_record_field "$D/x" notice_sha256)" "abc"
is "absent key -> empty" "$(lib gov_record_field "$D/x" method)" ""
printf 'method=* enabled=1\n' > "$D/x"; : > "$SBX/zz-glob-bait"
is "a '*' value is returned literally (no globbing)" "$( cd "$SBX" && lib gov_record_field "$D/x" method )" "*"
o=$( ( HOME="$H"; set -euo pipefail; . "$LIB"; a=$(gov_record_field "$D/missing" enabled); b=$(gov_installed_terms_version)
       c=$(gov_local_env_get GOV_NOT_SET_ANYWHERE); if gov_close_push_on; then :; fi; printf 'survived|%s|%s|%s' "$a" "$b" "$c" ) 2>&1 )
is "set -euo pipefail: missing file / env key / predicate do not kill the caller" "$o" "survived||1|"

echo "[7] gov_local_env_get"
reset_records
envf 'GOV_X=1' 'GOV_X=2 # later' 'GOV_ACCEPT_TERMS=1'
is "last assignment, comment stripped" "$(lib gov_local_env_get GOV_X)" "2"
is "process env first" "$( ( HOME="$H"; export HOME GOV_X=7; . "$LIB"; gov_local_env_get GOV_X ) )" "7"
is "GOV_ACCEPT_TERMS=1 in the FILE is not read (process-env only, S4)" "$(lib gov_local_env_get GOV_ACCEPT_TERMS)" ""
is "GOV_ACCEPT_TERMS=1 in the process env is read (control)" \
   "$( ( HOME="$H"; export HOME GOV_ACCEPT_TERMS=1; . "$LIB"; gov_local_env_get GOV_ACCEPT_TERMS ) )" "1"
o=$( cd "$SBX" && lib gov_local_env_get 'A;touch pwned' ); r=$?
is "an invalid key name is refused (rc 1, empty, nothing executed)" "$r|$o|$( [ -e "$SBX/pwned" ] && echo EXEC )" "1||"
envf 'GOV_Y=$(touch '"$SBX"'/was-executed)'
lib gov_local_env_get GOV_Y >/dev/null
is "the env file is never sourced (a \$(...) value does not run)" "$( [ -e "$SBX/was-executed" ] && echo RAN || echo no)" "no"

echo "[8] gov_sha256_lf - CRLF hashes like LF (C5)"
printf 'line one\nline two\n' > "$SBX/lf.md"; printf 'line one\r\nline two\r\n' > "$SBX/crlf.md"; printf 'line one\nline 2\n' > "$SBX/other.md"
hl=$(lib gov_sha256_lf "$SBX/lf.md"); hc=$(lib gov_sha256_lf "$SBX/crlf.md"); ho=$(lib gov_sha256_lf "$SBX/other.md")
is "CRLF copy == LF copy" "$hc" "$hl"
if [ -n "$hl" ] && [ "$hl" != "$ho" ]; then ok "a different text hashes differently (control)"; else bad "a different text hashes differently (got [$hl] [$ho])"; fi
if command -v sha256sum >/dev/null 2>&1; then ref=$(tr -d '\r' < "$SBX/crlf.md" | sha256sum); else ref=$(tr -d '\r' < "$SBX/crlf.md" | shasum -a 256); fi
is "equals the documented verify command (tr -d CR | sha256sum)" "$hl" "${ref%% *}"
is "stdin variant == file variant" "$(lib gov_sha256_lf_stdin < "$SBX/crlf.md")" "$hl"
case "$hl" in *[!0-9a-f]*|'') bad "hash is 64 lowercase hex (got [$hl])" ;; *) is "hash is 64 lowercase hex" "${#hl}" "64" ;; esac
o=$(lib gov_sha256_lf "$SBX/nope.md"); r=$?
is "missing file -> rc 1, empty" "$r|$o" "1|"

echo "[9] gov_terms_summary - byte-equal to the old sed"
printf '%s\n' '# Notice' 'intro' '<!-- terms-summary:begin -->' '```' ' 1. First term.' '' ' 2. Second <term> & more.' '```' '<!-- terms-summary:end -->' 'after' > "$SBX/NOTICE.md"
sed -n '/<!-- terms-summary:begin -->/,/<!-- terms-summary:end -->/{/<!--/d;p;}' "$SBX/NOTICE.md" > "$SBX/old.out"
lib gov_terms_summary "$SBX/NOTICE.md" > "$SBX/new.out"
if cmp -s "$SBX/old.out" "$SBX/new.out"; then ok "fixture: gov_terms_summary == old sed (cmp)"; else bad "fixture: gov_terms_summary == old sed"; fi
is "fixture: the block, markers dropped" "$(cat "$SBX/new.out")" "$(printf '%s\n' '```' ' 1. First term.' '' ' 2. Second <term> & more.' '```')"
hasnt "text outside the markers is not printed" "$(cat "$SBX/new.out")" "intro"
REAL_NOTICE="$GOV_DIR/../../governance-installer/NOTICE-AUTO-UPDATE.md"   # the live tree
[ -f "$REAL_NOTICE" ] || REAL_NOTICE="$GOV_DIR/../../../NOTICE-AUTO-UPDATE.md"   # a clone: bundle/hooks/governance
if [ -f "$REAL_NOTICE" ] && grep -q 'terms-summary:begin' "$REAL_NOTICE"; then
  sed -n '/<!-- terms-summary:begin -->/,/<!-- terms-summary:end -->/{/<!--/d;p;}' "$REAL_NOTICE" > "$SBX/old2.out"
  lib gov_terms_summary "$REAL_NOTICE" > "$SBX/new2.out"
  if cmp -s "$SBX/old2.out" "$SBX/new2.out" && [ -s "$SBX/new2.out" ]; then ok "installed NOTICE: == old sed, non-empty"; else bad "installed NOTICE: == old sed, non-empty"; fi
else
  skip "installed NOTICE-AUTO-UPDATE.md not beside this tree (sandbox copy) - the fixture covers the sed"
fi
o=$(lib gov_terms_summary "$SBX/none.md"); r=$?
is "missing NOTICE -> rc 1, empty" "$r|$o" "1|"

echo "[10] gov_close_push_question - DRAFTS A.6, one literal"
q=$(lib gov_close_push_question /x/NOTICE-AUTO-UPDATE.md; printf '#END')
is "starts with an empty line" "$(printf '%s' "$q" | sed -n 1p)" ""
is "title line" "$(printf '%s' "$q" | sed -n 2p)" "Push at session close - OFF unless you turn it on"
has "the Full text line carries the given path" "$q" "  Full text: /x/NOTICE-AUTO-UPDATE.md, sections 2a and 10.3"
is "the last line is the DRAFTS A.6 y/N prompt, with NO newline" "$(printf '%s' "${q%#END}" | tail -1)#END" "Turn push at session close ON now? [y/N]: #END"
has "  ... directly after the Full text line" "$q" "sections 2a and 10.3
Turn push at session close ON now? [y/N]: #END"
hasnt "no typed-phrase prompt is left (owner decision 2026-10-01)" "$q" "I ENABLE PUSH"
hasnt "  ... and no 'Type ... to turn it on' line" "$q" "to turn it on (anything else"
is "gov_close_push_phrase no longer exists" "$(lib type gov_close_push_phrase >/dev/null 2>&1 && echo defined || echo gone)" "gone"
is "the library's code names no phrase function" "$(grep -c 'gov_close_push_phrase' "$LIB")" "0"
has "names the risks" "$q" "a push cannot be taken back once someone has fetched it"
has "names the off switch" "$q" "    bash ~/.claude/hooks/governance/close-push.sh --disable"
hasnt "no automatic-update wording" "$q" "utomatic update"
is "18 lines (1 empty + 16 text + the y/N prompt)" "$(printf '%s\n' "${q%#END}" | wc -l | tr -d ' ')" "18"
is "no line wider than 100 columns" "$(printf '%s\n' "${q%#END}" | awk 'length > 100' | wc -l | tr -d ' ')" "0"
# DRAFTS A.6 lives in the machine-local journal of the source repo (GOV_REPO_PATH, process env only:
# this suite reads nothing under the real ~/.claude).
DRAFTS_A6="${GOV_REPO_PATH:-}/Plans/2026-09-29-legal-counsel/DRAFTS.md"
if [ -n "${GOV_REPO_PATH:-}" ] && [ -f "$DRAFTS_A6" ]; then
  a6=$(awk '/^### A\.6 /{on=1; next} on && /^```$/ {n++; if (n==2) exit; next} on && n==1 {print}' "$DRAFTS_A6" | tr -d '\r' | sed 's#<NOTICE path>#/x/NOTICE-AUTO-UPDATE.md#')
  is "the question is DRAFTS A.6 verbatim (path filled in; the prompt's trailing blank is the read position)" "$(printf '%s' "${q%#END}" | sed 's/ $//')" "$a6"
else skip "DRAFTS.md not reachable (set GOV_REPO_PATH to the source repo) - the literal is asserted line by line above"; fi
h1=$(lib gov_close_push_question /x/N.md | lib gov_sha256_lf_stdin); h2=$(lib gov_close_push_question /x/N.md | lib gov_sha256_lf_stdin)
h3=$(lib gov_close_push_question /y/N.md | lib gov_sha256_lf_stdin)
is "the question hash is stable (same path, two calls)" "$h1" "$h2"
if [ -n "$h1" ] && [ "$h1" != "$h3" ]; then ok "a different NOTICE path gives a different hash (control: the path is covered)"; else bad "a different NOTICE path gives a different hash"; fi
# The hash covers the y/N prompt: a copy of the library with the prompt changed hashes differently;
# an unmodified copy hashes the same (control: the copy itself is not the cause).
sed 's/ON now? \[y\/N\]: /ON now? [Y\/n]: /' "$LIB" > "$SBX/lib-mutant.sh"
cp "$LIB" "$SBX/lib-copy.sh"
hm=$( ( . "$SBX/lib-mutant.sh"; gov_close_push_question /x/N.md | gov_sha256_lf_stdin ) )
hc=$( ( . "$SBX/lib-copy.sh"; gov_close_push_question /x/N.md | gov_sha256_lf_stdin ) )
has "control: the mutant really changed the prompt" "$( ( . "$SBX/lib-mutant.sh"; gov_close_push_question /x/N.md ) )" "ON now? [Y/n]: "
if [ -n "$hm" ] && [ "$hm" != "$h1" ]; then ok "a mutated [y/N] prompt gives a different hash (the hash covers the prompt line)"; else bad "mutated prompt: same hash [$hm]"; fi
is "an unmodified copy of the library gives the same hash (control)" "$hc" "$h1"

echo "[10a] gov_close_push_ask - shown_sha256 is the hash of exactly the bytes printed (finding 13)"
P1="/opt/example-project/NOTICE-AUTO-UPDATE.md"
( HOME="$H"; . "$LIB"; GOV_SHOWN_SHA256=""; gov_close_push_ask "$P1" > "$SBX/ask.out"; printf '%s' "$GOV_SHOWN_SHA256" > "$SBX/ask.sha" )
is "it prints exactly what gov_close_push_question prints (cmp)" \
   "$(lib gov_close_push_question "$P1" > "$SBX/q.out"; cmp -s "$SBX/ask.out" "$SBX/q.out" && echo same || echo differs)" "same"
has "  ... the printed block carries the real path and the [y/N] prompt" "$(cat "$SBX/ask.out")" "  Full text: $P1, sections 2a and 10.3"
is "GOV_SHOWN_SHA256 = sha256 of the printed bytes (an independent hash of the captured output)" "$(cat "$SBX/ask.sha")" "$(lib gov_sha256_lf "$SBX/ask.out")"
is "GOV_SHOWN_SHA256 is 64 characters" "$(wc -c < "$SBX/ask.sha" | tr -d ' ')" "64"
hcanon=$(lib gov_close_push_question NOTICE-AUTO-UPDATE.md | lib gov_sha256_lf_stdin)
if [ "$(cat "$SBX/ask.sha")" != "$hcanon" ]; then ok "finding 13 reproduced as a control: the old canonical-name hash is NOT the hash of what was printed"
else bad "the canonical-name hash equals the printed one - the finding-13 check proves nothing"; fi
( HOME="$H"; . "$LIB"; GOV_SHOWN_SHA256=""; gov_close_push_ask /y/NOTICE-AUTO-UPDATE.md > "$SBX/ask2.out"; printf '%s' "$GOV_SHOWN_SHA256" > "$SBX/ask2.sha" )
if [ "$(cat "$SBX/ask2.sha")" != "$(cat "$SBX/ask.sha")" ] && [ "$(cat "$SBX/ask2.sha")" = "$(lib gov_sha256_lf "$SBX/ask2.out")" ]; then
  ok "another path: another hash, again the hash of its own printed bytes"
else bad "another path: hash [$(cat "$SBX/ask2.sha")]"; fi
is "the verify command in the header reproduces the recorded hash" "$(lib gov_close_push_question "$P1" | lib gov_sha256_lf_stdin)" "$(cat "$SBX/ask.sha")"

echo "[10c] gov_close_push_answer_yes - the y/N rule, default No"
ay() { if lib gov_close_push_answer_yes "$1"; then printf 'ON'; else printf 'OFF'; fi; }
for a in y Y yes YES Yes yEs " y" "y " "  yes  " $'y\r' $'yes\r' $'\ty' $'y\t'; do
  printf -v lbl '%q' "$a"; is "answer [$lbl] -> ON (must-fire)" "$(ay "$a")" "ON"
done
for a in "" " " n N no NO No nope "yy" "yess" "y es" "ye" "ok" "sure" "1" "true" "I ENABLE PUSH AT SESSION CLOSE" "y;rm -rf x" $'y\nyes'; do
  printf -v lbl '%q' "$a"; is "answer [$lbl] -> OFF (default No)" "$(ay "$a")" "OFF"
done
is "the empty answer (Enter) is No - the default (control: the rule has a default, not an error)" "$(lib gov_close_push_answer_yes ''; echo "rc=$?")" "rc=1"
o=$( cd "$SBX" && lib gov_close_push_answer_yes '*' ; echo "rc=$?" ); is "a '*' answer is No and does not glob" "$o" "rc=1"

echo "[10b] gov_interactive_terminal - stdin AND stdout (D2)"
o=$(lib gov_interactive_terminal </dev/null 2>&1); r=$?
is "stdin </dev/null -> rc 1, silent" "$r|$o" "1|"
o=$( ( lib gov_interactive_terminal; echo "rc=$?" ) </dev/null | cat 2>&1 )
is "stdout a pipe (| cat), stdin /dev/null -> rc 1, not an error" "$o" "rc=1"
o=$( printf 'y\n' | ( lib gov_interactive_terminal; echo "rc=$?" ) 2>&1 )
is "'y' piped on stdin -> rc 1 (a pipe is not a terminal)" "$o" "rc=1"
if [ -t 0 ] && [ -t 1 ]; then
  is "this run IS on a terminal -> rc 0 (control)" "$(lib gov_interactive_terminal </dev/tty >/dev/tty; echo $?)" "0"
else
  skip "positive direction (rc 0 on a real terminal): this run has no terminal (agent / CI) - close-push.sh --selftest 19f covers it where util-linux script exists"
fi
is "the predicate is exactly [ -t 0 ] && [ -t 1 ] (one definition)" \
   "$(grep -c '^gov_interactive_terminal() { \[ -t 0 \] && \[ -t 1 \]; }$' "$LIB")" "1"

echo "[11] gov_consent_write - atomic, 0600, one line, no identity (S4, T3)"
reset_records
LINE='enabled=1 terms_version=1 recorded_at=2026-09-30T00:00:00Z method=interactive shown_sha256=0123abcd'
um_before=$(umask)
( HOME="$H"; export HOME; . "$LIB"; gov_consent_write "$D/close-push" "$LINE" ); r=$?
is "valid record -> rc 0" "$r" "0"
is "content is exactly the line + LF" "$(cat "$D/close-push")|$(tail -c 1 "$D/close-push" | od -An -c | tr -d ' ')" "$LINE|\\n"
is "content round-trips through the parser" "$(lib gov_record_field "$D/close-push" shown_sha256)" "0123abcd"
is "one line" "$(wc -l < "$D/close-push" | tr -d ' ')" "1"
is "no .tmp. file left behind" "$(ls -a "$D" | grep -c '\.tmp\.')" "0"
is "the caller's umask is unchanged" "$(umask)" "$um_before"
c=$(cat "$D/close-push")
for id in "$H" "$SBX" "${USER:-}" "${USERNAME:-}" "${HOSTNAME:-}" "${COMPUTERNAME:-}"; do
  [ -n "$id" ] || continue
  case "$c" in *"$id"*) bad "record carries no identity/path ([$id] found)" ;; *) ok "record carries no identity/path (one of home/user/host checked)" ;; esac
done
# Mode: measured on a probe first. Git-for-Windows mounts NTFS with noacl, where chmod is a no-op
# and every file reads 644 - there the mode cannot be asserted and the check says so.
: > "$SBX/probe"; chmod 600 "$SBX/probe" 2>/dev/null
pm=$(stat -c %a "$SBX/probe" 2>/dev/null || stat -f %Lp "$SBX/probe" 2>/dev/null)
rmode=$(stat -c %a "$D/close-push" 2>/dev/null || stat -f %Lp "$D/close-push" 2>/dev/null)
if [ "$pm" = "600" ]; then is "record mode is 600" "$rmode" "600"
else skip "record mode 600: this filesystem ignores chmod (probe reads $pm) - asserted where modes exist"; fi
printf 'enabled=0 terms_version=1\n' > "$D/close-push"
( HOME="$H"; export HOME; . "$LIB"; gov_consent_write "$D/close-push" 'enabled=1 terms_version=1' ); r=$?
is "overwrites an existing record (tmp + mv -f)" "$r|$(cat "$D/close-push")" "0|enabled=1 terms_version=1"
refuse() {  # refuse <label> <line>
  printf 'keep=1\n' > "$D/r"
  ( HOME="$H"; export HOME; . "$LIB"; gov_consent_write "$D/r" "$2" ); local rr=$?
  is "refused: $1 (rc 1, record unchanged, no tmp)" "$rr|$(cat "$D/r")|$(ls -a "$D" | grep -c '\.tmp\.')" "1|keep=1|0"
}
refuse "an absolute path"           'enabled=1 path=/opt/example/x'
refuse "a Windows path"             'enabled=1 path=C:\example\x'
refuse "a newline"                  "$(printf 'enabled=1\nevil=1')"
refuse "a glob character"           'enabled=1 method=*'
refuse "an upper-case key"          'Enabled=1'
refuse "a token without ="          'enabled=1 stray'
refuse "an empty line"              ''
if [ -n "${USER:-}${USERNAME:-}" ]; then u="${USER:-$USERNAME}"; refuse "the user name as a value" "enabled=1 by=$u"
else skip "no USER/USERNAME in this environment"; fi
( HOSTNAME=ci-host-example; export HOSTNAME; printf 'keep=1\n' > "$D/r"; HOME="$H"; . "$LIB"; gov_consent_write "$D/r" 'enabled=1 host=CI-HOST-EXAMPLE'; echo "rc=$?|$(cat "$D/r")" ) > "$SBX/h.out"
is "refused: the host name as a value (case-insensitive)" "$(cat "$SBX/h.out")" "rc=1|keep=1"
( HOME="$H"; export HOME; . "$LIB"; gov_consent_write "$D/r" 'enabled=1 method=--accept-terms at=2026-09-30T00:00:00Z' ); r=$?
is "allowed: dashes, colons, dots in values (control)" "$r|$(cat "$D/r")" "0|enabled=1 method=--accept-terms at=2026-09-30T00:00:00Z"

echo "[11b] the terms-accepted line install.sh / gov-update.sh --accept-terms write (P4: C5, S4)"
# The exact shape of the P4 record: terms_version FIRST, because two readers predate the parser -
# install.sh (grep -o 'terms_version=[0-9]*' | head -1) and gov-update.sh upd_apply (sed '^terms_version=').
reset_records
HN=$(printf 'x' | sha256sum | cut -d' ' -f1); HS=$(printf 'y' | sha256sum | cut -d' ' -f1)
TLINE="terms_version=3 accepted_at=2026-09-30T12:00:00Z framework_version=2.0.0 method=--accept-terms notice_sha256=$HN shown_sha256=$HS"
( HOME="$H"; export HOME; . "$LIB"; gov_consent_write "$D/terms-accepted" "$TLINE" ); r=$?
is "the P4 record is accepted by the writer, byte for byte" "$r|$(cat "$D/terms-accepted")" "0|$TLINE"
is "install.sh's reader sees terms_version=3" "$(grep -o 'terms_version=[0-9]*' "$D/terms-accepted" | head -1 | cut -d= -f2)" "3"
is "gov-update.sh upd_apply's reader sees 3" "$(sed -n 's/^terms_version=\([0-9]*\).*/\1/p' "$D/terms-accepted" | head -1)" "3"
is "gov_record_field reads both hashes and the method" \
   "$(lib gov_record_field "$D/terms-accepted" notice_sha256)|$(lib gov_record_field "$D/terms-accepted" shown_sha256)|$(lib gov_record_field "$D/terms-accepted" method)" "$HN|$HS|--accept-terms"
printf '%s\n' "method=env terms_version=3" > "$D/terms-accepted"
is "control: with terms_version NOT first, the upd_apply reader reads nothing (why the order is kept)" \
   "$(sed -n 's/^terms_version=\([0-9]*\).*/\1/p' "$D/terms-accepted" | head -1)" ""
( HOME="$H"; export HOME; . "$LIB"; gov_consent_write "$D/terms-accepted" "terms_version=3 notice=/opt/example/NOTICE-AUTO-UPDATE.md" ); r=$?
is "refused: a record naming the NOTICE by path instead of by hash (rc 1, file untouched)" "$r|$(cat "$D/terms-accepted")" "1|method=env terms_version=3"
reset_records

echo "[12] agent detection and the only overrides (C3, S2)"
# ah <VAR=value...> -> "human-ok" / "refused" from gov_human_consent_ok, in a subshell.
ah() { ( for a in "$@"; do export "$a"; done; HOME="$H"; export HOME; . "$LIB"
         if gov_human_consent_ok; then printf 'human-ok'; else printf 'refused'; fi ) ; }
OTHER="$SBX/other"
is "markers set + no nonce -> refused (must-fire)" "$(ah CLAUDECODE=1 GOV_CONSENT_SELFTEST= USERPROFILE="$OTHER")" "refused"
is "CLAUDECODE alone -> refused" "$( ( unset AI_AGENT CLAUDE_CODE_ENTRYPOINT; ah CLAUDECODE=1 GOV_CONSENT_SELFTEST= ) )" "refused"
is "AI_AGENT alone -> refused" "$( ( unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT; ah AI_AGENT=x GOV_CONSENT_SELFTEST= ) )" "refused"
is "CLAUDE_CODE_ENTRYPOINT alone -> refused" "$( ( unset CLAUDECODE AI_AGENT; ah CLAUDE_CODE_ENTRYPOINT=cli GOV_CONSENT_SELFTEST= ) )" "refused"
is "[17c] no markers at all -> a person, not an agent (the detection's own negative direction)" \
   "$( ( unset CLAUDECODE AI_AGENT CLAUDE_CODE_ENTRYPOINT GOV_CONSENT_SELFTEST; ah ) )" "human-ok"
is "nonce + HOME == USERPROFILE (the sandbox posing as the real home) -> refused" \
   "$(ah CLAUDECODE=1 GOV_CONSENT_SELFTEST="$NONCE" USERPROFILE="$H")" "refused"
is "nonce + USERPROFILE elsewhere (a non-real HOME) -> allowed (the suite's only bypass)" \
   "$(ah CLAUDECODE=1 GOV_CONSENT_SELFTEST="$NONCE" USERPROFILE="$OTHER")" "human-ok"
is "wrong nonce -> refused" "$(ah CLAUDECODE=1 GOV_CONSENT_SELFTEST=not-the-nonce USERPROFILE="$OTHER")" "refused"
is "empty GOV_CONSENT_SELFTEST -> refused" "$(ah CLAUDECODE=1 GOV_CONSENT_SELFTEST= USERPROFILE="$OTHER")" "refused"
mv "$H/.governance-consent-selftest" "$H/.nonce.bak"
is "no nonce file in HOME -> refused" "$(ah CLAUDECODE=1 GOV_CONSENT_SELFTEST="$NONCE" USERPROFILE="$OTHER")" "refused"
mv "$H/.nonce.bak" "$H/.governance-consent-selftest"
UPH=$(printf '%s' "$H" | tr 'a-z' 'A-Z')
if [ -d "$UPH" ] && [ "$UPH" != "$H" ]; then
  is "nonce + USERPROFILE = HOME spelt in another case (case-insensitive FS) -> refused" \
     "$(ah CLAUDECODE=1 GOV_CONSENT_SELFTEST="$NONCE" USERPROFILE="$UPH")" "refused"
else skip "case-sensitive filesystem - the other-case spelling is a different path here"; fi
if ln -s "$H" "$SBX/homelink" 2>/dev/null && [ -L "$SBX/homelink" ]; then
  is "nonce + USERPROFILE = a symlink to HOME -> refused (resolved with pwd -P)" \
     "$(ah CLAUDECODE=1 GOV_CONSENT_SELFTEST="$NONCE" USERPROFILE="$SBX/homelink")" "refused"
else skip "no symlinks on this filesystem (MSYS copies instead of linking)"; fi
is "GOV_REPO_PATH is NOT an exemption" "$(ah CLAUDECODE=1 GOV_CONSENT_SELFTEST= GOV_REPO_PATH=/x USERPROFILE="$OTHER")" "refused"
# D3 (findings 1, 17): the source-machine marker exempts NO consent act, as a file or a directory.
mkdir -p "$H/.claude"; : > "$H/.claude/.governance-source"
is "the source-machine marker as a FILE -> refused (D3: not a consent exemption)" "$(ah CLAUDECODE=1 GOV_CONSENT_SELFTEST= USERPROFILE="$OTHER")" "refused"
is "  control: with the marker file present, the sandbox nonce still passes" "$(ah CLAUDECODE=1 GOV_CONSENT_SELFTEST="$NONCE" USERPROFILE="$OTHER")" "human-ok"
rm -f "$H/.claude/.governance-source"; mkdir "$H/.claude/.governance-source"
is "the source-machine marker as a DIRECTORY (mkdir) -> refused (finding 17)" "$(ah CLAUDECODE=1 GOV_CONSENT_SELFTEST= USERPROFILE="$OTHER")" "refused"
rmdir "$H/.claude/.governance-source"
is "marker gone -> refused (the same answer: the marker never mattered)" "$(ah CLAUDECODE=1 GOV_CONSENT_SELFTEST= USERPROFILE="$OTHER")" "refused"
is "the library's code builds the marker PATH on ONE line, inside gov_maintainer_machine" \
   "$(grep -v '^[[:space:]]*#' "$LIB" | grep -c 'HOME/\.claude/\.governance-source')|$(awk '/^gov_maintainer_machine\(\) \{/{on=1} on && /HOME\/\.claude\/\.governance-source/ && !/^[[:space:]]*#/ {n++} on && /^\}/{on=0} END{print n+0}' "$LIB")" "1|1"
is "  ... the only other code line naming it is the reason string gov_close_push_on prints" \
   "$(grep -v '^[[:space:]]*#' "$LIB" | grep 'governance-source' | grep -vc 'HOME/\.claude/\.governance-source')|$(grep -v '^[[:space:]]*#' "$LIB" | grep -c 'GOV_CONSENT_REASON="on (maintainer machine: ~/\.claude/\.governance-source)"')" "1|1"
is "gov_human_consent_ok and its helpers never call gov_maintainer_machine (D3)" \
   "$(awk '/^(gov_human_consent_ok|gov_consent_override_ok|_gov_is_real_home|gov_agent_session)\(\)/{on=1} on && /gov_maintainer_machine/ {n++} on && /^\}/{on=0} END{print n+0}' "$LIB")" "0"
is "  control: the probe finds the call where it is (gov_close_push_on)" \
   "$(awk '/^gov_close_push_on\(\)/{on=1} on && /gov_maintainer_machine/ {n++} on && /^\}/{on=0} END{print n+0}' "$LIB")" "1"
is "gov_consent_refusal_line = DRAFTS A.2 adapted by D1/L1 (refused on detection)" "$(lib gov_consent_refusal_line)" \
   "$(printf '%s\n' '[GOVERNANCE] Refused: this needs your own decision, typed in your own terminal, and an AI-agent' 'session was detected (a safeguard, not a guarantee). Nothing was recorded or changed.')"
# L1: the printed refusal claims no guarantee - no "cannot" in either line (the DRAFTS A.2 text had
# "an AI agent cannot accept"); the control proves the probe sees the word when it is there.
o=$(lib gov_consent_refusal_line)
hasnt "the refusal line does not say an agent CANNOT act (L1)" "$o" "cannot"
has "the refusal line says it is a safeguard, not a guarantee (L1)" "$o" "a safeguard, not a guarantee"
# Control on the REAL function (round 3: the old control compared two literals and proved nothing):
# a copy of the library whose refusal line carries the DRAFTS A.2 "cannot" wording prints it, and the
# same probe finds it there; the unmodified copy prints the shipped line (the copy is not the cause).
sed "s/'session was detected (a safeguard, not a guarantee). Nothing was recorded or changed.'/'session was detected; an AI agent cannot accept these terms or turn this on for you.'/" "$LIB" > "$SBX/lib-refusal-mutant.sh"
cp "$LIB" "$SBX/lib-refusal-copy.sh"
om=$( ( . "$SBX/lib-refusal-mutant.sh"; gov_consent_refusal_line ) )
oc=$( ( . "$SBX/lib-refusal-copy.sh"; gov_consent_refusal_line ) )
if [ "$om" != "$o" ]; then ok "  control: the mutant library really prints another refusal line"; else bad "  control: the mutant did not change gov_consent_refusal_line (the sed no longer matches the library)"; fi
has "  control: the probe finds 'cannot' in the mutant's gov_consent_refusal_line output" "$om" "cannot"
is "  control: an unmodified copy prints exactly the shipped line" "$oc" "$o"

echo "[13] purity and the _common.sh wiring (A19)"
H2="$SBX/fresh"; mkdir -p "$H2"
o=$( printf 'stdin-data\n' | ( HOME="$H2"; export HOME; . "$LIB"; IFS= read -r x; printf '%s' "$x" ) )
is "sourcing reads no stdin" "$o" "stdin-data"
is "sourcing (and the predicates) create nothing in HOME" \
   "$( ( HOME="$H2"; export HOME; . "$LIB"; gov_close_push_on; gov_auto_update_on; gov_installed_terms_version >/dev/null ); find "$H2" -mindepth 1 | wc -l | tr -d ' ')" "0"
is "nothing on stderr when no record, manifest or TERMS-VERSION exists" \
   "$( ( HOME="$H2"; export HOME; . "$LIB"; gov_close_push_on; gov_installed_terms_version; gov_human_consent_ok; gov_record_field "$H2/none" enabled ) 2>&1 >/dev/null )" ""
o=$( ( HOME="$H"; export HOME; . "$GOV_DIR/_common.sh"; type gov_close_push_on >/dev/null 2>&1 && type gov_auto_update_on >/dev/null 2>&1 && type gov_human_consent_ok >/dev/null 2>&1 && echo defined ) 2>/dev/null )
is "_common.sh provides gov_close_push_on / gov_auto_update_on / gov_human_consent_ok" "$o" "defined"
mkdir -p "$SBX/nolib" "$SBX/cwdbait"; cp "$GOV_DIR/_common.sh" "$SBX/nolib/"
printf 'gov_close_push_on() { return 0; }\n' > "$SBX/cwdbait/consent-lib.sh"
o=$( cd "$SBX/cwdbait" && ( HOME="$H"; export HOME; . "$SBX/nolib/_common.sh"; if gov_close_push_on 2>/dev/null; then echo ON; else echo OFF; fi ) 2>/dev/null )
is "_common.sh without its library: the predicate fails closed, and a cwd consent-lib.sh is not sourced" "$o" "OFF"

echo "[14] NOTICE-AUTO-UPDATE.md - the client wording of the 2026-10-01 decision, findings 7 and 13"
# notice_check FILE -> the names of the checks FILE fails, space-separated; empty = all pass.
notice_check() {
  local f="$1" miss="" s103 s105 i6 s5 pr
  i6=$(awk '/^6\. \*\*Steps taken without asking/{on=1} on && /^7\. /{exit} on' "$f" | tr -d '\r' | tr '\n' ' ' | tr -s ' ')
  s103=$(awk '/^### 10\.3 /{on=1; next} /^### 10\.4 /{on=0} on' "$f" | tr -d '\r' | tr '\n' ' ' | tr -s ' ')
  s105=$(awk '/^### 10\.5 /{on=1; next} /^### /{on=0} on' "$f" | tr -d '\r' | tr '\n' ' ' | tr -s ' ')
  s5=$(awk '/<!-- terms-summary:begin -->/{on=1} /<!-- terms-summary:end -->/{on=0} on && /^ 5\. /{p=1} on && p && /^ 6\. /{exit} on && p' "$f" | tr -d '\r' | tr '\n' ' ' | tr -s ' ')
  pr=$( ( . "$LIB"; gov_close_push_question x ) | tail -1 | sed 's/: $//')
  case "$i6" in *"The commit at session close has no switch of its own"*) ;; *) miss="$miss item6-no-switch" ;; esac
  case "$i6" in *"with how to turn each off)"*) miss="$miss item6-claims-switch" ;; esac
  case "$s103" in *"\`$pr\`"*) ;; *) miss="$miss 10.3-prompt" ;; esac
  case "$s103" in *"the default is No"*) ;; *) miss="$miss 10.3-default-no" ;; esac
  case "$s103" in *"answering \`y\`"*) ;; *) miss="$miss 10.3-answer-y" ;; esac
  case "$s103" in *"no flag and no variable"*) ;; *) miss="$miss 10.3-no-flag" ;; esac
  case "$s105" in *"the question exactly as it was printed, including the file path"*) ;; *) miss="$miss 10.5-printed" ;; esac
  case "$s5" in *"y/N"*"default No"*) ;; *) miss="$miss summary5-yN" ;; esac
  grep -q 'I ENABLE PUSH' "$f" && miss="$miss phrase-left"
  grep -qi 'typed phrase\|a typed$' "$f" && miss="$miss typed-phrase-left"
  printf '%s' "${miss# }"
}
# notice_marker_check FILE -> "" when ONE paragraph (blank-line separated, CR dropped) names both
# the literal `~/.claude/.governance-source` and `gov-release.sh`; else "maintainer-marker-not-disclosed".
# Owner decision 2026-10-01 ("אפשרות ראשונה", Plans/PLAN.md release-gate block): the NOTICE DISCLOSES
# the marker - the file that turns push at session close on with no question - and that
# gov-release.sh creates it. This INVERTS the round-2 check, which failed when the NOTICE named it.
# Kept out of notice_check so the one-statement mutants below stay independent of it.
notice_marker_check() {
  if tr -d '\r' < "$1" | awk 'BEGIN { RS = "" } index($0, "~/.claude/.governance-source") && index($0, "gov-release.sh") { f = 1 } END { exit !f }'; then
    printf ''
  else printf 'maintainer-marker-not-disclosed'; fi
}
if [ -f "$REAL_NOTICE" ]; then
  N="$SBX/N.md"
  is "the shipped NOTICE passes every check" "$(notice_check "$REAL_NOTICE")" ""
  # The mutants start from an LF copy (a CRLF checkout would defeat the line-anchored edits below).
  RN="$SBX/real-lf.md"; tr -d '\r' < "$REAL_NOTICE" > "$RN"
  is "  control: the LF copy passes too" "$(notice_check "$RN")" ""
  REAL_NOTICE="$RN"
  # Must-fire controls: each mutant breaks ONE statement, and exactly that check fires.
  awk '{ if ($0 ~ /^   context files \(section 2a, with how to turn those off\) and commit the files they wrote\. The$/) print "   context files and commit the files they wrote (section 2a, with how to turn each off). The"; else print }' "$REAL_NOTICE" | sed 's/^   commit at session close has no switch of its own: the only way not to commit is not to run the$/   commit at session close - see section 8 - the only way not to commit is not to run the/' > "$N"
  is "finding 7 reproduced: the old item 6 wording -> both item-6 checks fire" "$(notice_check "$N")" "item6-no-switch item6-claims-switch"
  sed 's/ON now? \[y\/N\]`/ON now?`/' "$REAL_NOTICE" > "$N"
  is "10.3 quoting a prompt the code does not print -> 10.3-prompt fires" "$(notice_check "$N")" "10.3-prompt"
  sed 's/the default is No,/the default is Yes,/' "$REAL_NOTICE" > "$N"
  is "10.3 without the default No -> 10.3-default-no fires" "$(notice_check "$N")" "10.3-default-no"
  sed 's/including the file path on its/without the file path on its/' "$REAL_NOTICE" > "$N"
  is "finding 13: 10.5 not saying the printed path is covered -> 10.5-printed fires" "$(notice_check "$N")" "10.5-printed"
  sed 's/(asked next, on a terminal: y\/N,/(asked next, on a terminal; a typed/; s/^    default No)\. A push/    phrase). A push/' "$REAL_NOTICE" > "$N"
  is "the old summary item 5 (a typed phrase) -> summary5-yN and typed-phrase-left fire" "$(notice_check "$N")" "summary5-yN typed-phrase-left"
  { cat "$REAL_NOTICE"; printf '\nType I ENABLE PUSH AT SESSION CLOSE to turn it on.\n'; } > "$N"
  is "the old phrase anywhere in the NOTICE -> phrase-left fires" "$(notice_check "$N")" "phrase-left"
  # The marker disclosure (owner decision 2026-10-01). The shipped NOTICE is checked LAST in this
  # suite (see the end), because the paragraph lands in a separate change; here only the probe's
  # own two directions, on fixtures, so a failure there is about the NOTICE and not the probe.
  printf '%s\n' 'Intro.' '' 'A file named `~/.claude/.governance-source` turns push at session close on with no question;' \
    '`gov-release.sh` creates it after a release.' '' 'Outro.' > "$N"
  is "marker probe: a paragraph naming ~/.claude/.governance-source and gov-release.sh -> passes" "$(notice_marker_check "$N")" ""
  sed 's/$/\r/' "$N" > "$SBX/N-crlf.md"
  is "  ... a CRLF copy of that fixture passes too" "$(notice_marker_check "$SBX/N-crlf.md")" ""
  grep -v 'governance-source' "$RN" > "$N"
  is "marker probe mutant: the NOTICE with every line naming the marker removed -> fires" "$(notice_marker_check "$N")" "maintainer-marker-not-disclosed"
  printf '%s\n' 'A file named `~/.claude/.governance-source` turns push at session close on with no question.' '' \
    '`gov-release.sh` creates it after a release.' > "$N"
  is "marker probe mutant: the marker and gov-release.sh in DIFFERENT paragraphs -> fires" "$(notice_marker_check "$N")" "maintainer-marker-not-disclosed"
  printf '%s\n' 'A file named `.governance-source` is created by `gov-release.sh`.' > "$N"
  is "marker probe mutant: the bare name without ~/.claude/ -> fires (the literal path is required)" "$(notice_marker_check "$N")" "maintainer-marker-not-disclosed"
else
  skip "NOTICE-AUTO-UPDATE.md not beside this tree (sandbox copy) - [14] runs against the installer copy"
fi

echo "[15] install.sh --dry-run: the push-at-session-close decision as printed (maintainer / client)"
# Three sandbox HOMEs with the terms already accepted, run ONE AFTER THE OTHER (round 3: three
# parallel dry runs added to the load of a machine that runs several sessions; each is ~45 s when
# loaded). No terminal here, so the client case is the no-terminal default; the y/N answer itself
# is [10c] and the shared wrapper is checked by name below.
INST=""
for c in "$GOV_DIR/../../governance-installer/install.sh" "$GOV_DIR/../../../install.sh"; do
  [ -f "$c" ] && [ -f "$(dirname "$c")/bundle/hooks/governance/consent-lib.sh" ] && { INST="$c"; break; }
done
if [ -n "$INST" ]; then
  for hn in im imn ic; do
    mkdir -p "$SBX/$hn/.claude/.governance-update"
    printf 'terms_version=1 accepted_at=2026-09-30T00:00:00Z framework_version=2.0.0 method=interactive\n' > "$SBX/$hn/.claude/.governance-update/terms-accepted"
  done
  : > "$SBX/im/.claude/.governance-source"; : > "$SBX/imn/.claude/.governance-source"
  _ito() { if command -v timeout >/dev/null 2>&1; then timeout 600 "$@"; else "$@"; fi; }
  ( HOME="$SBX/im";  export HOME; unset GOV_CLOSE_PUSH; _ito bash "$INST" --dry-run --no-verify </dev/null > "$SBX/im.out" 2>&1 )
  ( HOME="$SBX/imn"; export HOME GOV_CLOSE_PUSH=0; _ito bash "$INST" --dry-run --no-verify --no-close-push </dev/null > "$SBX/imn.out" 2>&1 )
  ( HOME="$SBX/ic";  export HOME; unset GOV_CLOSE_PUSH; _ito bash "$INST" --dry-run --no-verify </dev/null > "$SBX/ic.out" 2>&1 )
  o=$(tr -d '\r' < "$SBX/im.out")
  has "maintainer: the decision line says always ON, nothing asked or recorded" "$o" \
      "Push at session close: ON - always, on the maintainer's machine (~/.claude/.governance-source); nothing is asked or recorded. Pause it with GOV_CLOSE_PUSH=0."
  has "maintainer: the summary says ON (always)" "$o" "  Push at session close:  ON (always, on the maintainer's machine)"
  hasnt "maintainer: no record would be written" "$o" "would record push at session close"
  hasnt "maintainer: no question is printed" "$o" "[y/N]"
  has "maintainer without --force: the RELEASE SOURCE warning" "$o" "This machine is marked as the RELEASE SOURCE (~/.claude/.governance-source)."
  is "install.sh reads the marker only through gov_maintainer_machine (round 4 minor: no direct test of the file)" \
     "$(grep -c '\.governance-source" \]' "$INST")/$(grep -c 'if type gov_maintainer_machine >/dev/null 2>&1 && gov_maintainer_machine && \[ "\$FORCE" = "0" \]; then' "$INST")" "0/1"
  is "install.sh's summary prints a reason through gov_reason_text, never 'OFF (\$GOV_CONSENT_REASON)' (round 4 minor: 'OFF (off (...))')" \
     "$(grep -c 'OFF (\${*GOV_CONSENT_REASON' "$INST")/$(grep -c 'OFF (\$(gov_reason_text "' "$INST")" "0/2"
  o=$(tr -d '\r' < "$SBX/imn.out")
  has "maintainer + --no-close-push: records OFF and says push stays ON here" "$o" \
      "Push at session close: OFF recorded (--no-close-push); this is the maintainer's machine (~/.claude/.governance-source) where push is otherwise always ON, and it is PAUSED now by GOV_CLOSE_PUSH=0 (remove it to resume)."
  has "maintainer + --no-close-push: the OFF record is still written (dry: would record)" "$o" "[DRY] would record push at session close: OFF (--no-close-push)"
  has "maintainer + GOV_CLOSE_PUSH=0: the summary says paused, not ON" "$o" "  Push at session close:  OFF (paused by GOV_CLOSE_PUSH=0)"
  o=$(tr -d '\r' < "$SBX/ic.out")
  has "client, no terminal (control): OFF by default, with the way to turn it on" "$o" \
      "Push at session close: OFF (the default without a terminal). To turn it on, run this yourself in your own terminal: bash ~/.claude/hooks/governance/close-push.sh --enable"
  has "client: the summary says OFF" "$o" "  Push at session close:  OFF - turn on: bash ~/.claude/hooks/governance/close-push.sh --enable"
  hasnt "client: no maintainer wording" "$o" "maintainer's machine"
  hasnt "client: no RELEASE SOURCE warning" "$o" "RELEASE SOURCE"
  has "client --dry-run: the installed terms copy is part of the install (TERMS-VERSION)" "$o" "hooks/governance-terms/TERMS-VERSION"
  has "client --dry-run: ... and the NOTICE copy" "$o" "hooks/governance-terms/NOTICE-AUTO-UPDATE.md"
  is "install.sh's answer wrapper delegates to gov_close_push_answer_yes (one rule)" \
     "$(sed -n '/^  _inst_answer_enables() {$/,/^  }$/p' "$INST" | grep -c 'gov_close_push_answer_yes "\${1:-}"')" "1"
  is "install.sh prints and hashes the question once (gov_close_push_ask), never a canonical-name copy" \
     "$(grep -c 'GOV_SHOWN_SHA256=""; gov_close_push_ask "\$NOTICE_FILE"; PUSH_SHOWN_SHA="\$GOV_SHOWN_SHA256"' "$INST")/$(grep -c 'gov_close_push_question NOTICE-AUTO-UPDATE.md' "$INST")" "1/0"
  is "install.sh names no phrase" "$(grep -c -i 'phrase' "$INST")" "0"
else
  skip "install.sh not beside this tree - [15] runs where the installer copy is present"
fi

echo "[16] the shipped NOTICE discloses the maintainer marker (owner decision 2026-10-01) - checked last"
# Its two directions on fixtures are in [14]. This is the shipped text: a paragraph that names the
# literal ~/.claude/.governance-source and gov-release.sh. It fails until that paragraph is in the
# NOTICE beside this tree (NOTICE section 10.3).
if [ -f "$REAL_NOTICE" ]; then
  is "the shipped NOTICE names ~/.claude/.governance-source and gov-release.sh in one paragraph" "$(notice_marker_check "$REAL_NOTICE")" ""
else
  skip "NOTICE-AUTO-UPDATE.md not beside this tree (sandbox copy) - [16] runs against the installer copy"
fi

echo
printf 'consent-lib selftest: pass=%s fail=%s skip=%s\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ] && [ "$PASS" -gt 0 ]
