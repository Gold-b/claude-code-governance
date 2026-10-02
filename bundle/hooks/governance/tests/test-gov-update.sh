#!/usr/bin/env bash
# test-gov-update.sh — the signed MANUAL updater (2.0.0), end to end, in a SANDBOX.
#
# Never touches the real ~/.claude: every case runs under a throwaway HOME, against fixture
# releases built from THIS checkout by the real release-manifest.sh and signed by throwaway keys
# generated per run. A fixture "remote" is a directory of GitHub-shaped tarballs
# (claude-code-governance-<ver>/ top directory) served over file://.
#
# Cases (plan §8): T1-T11, T13-T18, mutants M1-M4, plus the release-manifest determinism check
# (step 4), install-map parity (step 5) and the pre-push VERSION/tag rule (step 9). 2026-09-30:
# 2.0.0 has NO automatic update (owner decision 2026-09-29/30). The SessionEnd trigger and its
# cases ([SESSIONEND], M5-M9) are gone; [NOAUTO] proves no variable, record or flag enables an
# unattended apply and that the human path (--fetch, --apply) works; mutant M8 (the predicate
# forced true) and M10 (a --fetch spawn put back into pre-session.sh) prove that suite can fail.
# Every apply below is the human `--apply`; `--apply-if-ready` is only the recovery child's entry.
# [T11] (2026-09-30, HELD-TERMS): a release whose terms changed is fetched with the deep verify ON
# and a marker planted in the one script that verify executes: the marker must stay absent until
# --accept-terms, and appear right after it.
# [CONSENT] (2026-09-30, P4: C3, C5, S4): install.sh and gov-update.sh --accept-terms refuse inside an
# AI-agent session without the sandbox nonce, before any write; with it, terms-accepted carries
# notice_sha256 / shown_sha256 equal to sha256sum of the NOTICE and of the sed-extracted summary.
# [CLOSEPUSH] (2026-09-30, P6: C4, T3, S4; F2: D2, D3, D7; y/N design per the owner decision of
# 2026-10-01): install.sh records push at session close OFF unless a person answers y / yes (any case,
# blanks and CR ignored) to the y/N question at a real terminal; Enter, anything else and the
# withdrawn typed phrase are No. No flag turns it ON: the old --enable-close-push is an unknown option
# (exit 1, nothing written), with or without the nonce. T3 / round-2 finding 13: both writers print
# the question with gov_close_push_ask, and the recorded shown_sha256 is the hash of exactly the bytes
# printed (real NOTICE path, [y/N] prompt included) - asserted through each real writer with a
# terminal test double in a sandbox copy of consent-lib.sh (Windows has no util-linux script(1); the
# pty case runs where it exists). An ON record PLANTED with that hash is what the push end-to-end case
# and the re-install/uninstall cases start from. A re-install keeps the choice, a terms bump turns it OFF,
# --uninstall keeps it (and refuses, removing nothing, when its backup cannot be made), the ON record
# makes close-push.sh push (end to end) while an OFF record makes it skip, and the installer's own
# output no longer claims an automatic update exists.
# [CONSENT] (d) is INVERTED (D3): the source-machine marker, as a file or a directory, exempts nothing.
# [RELEASE] (2026-09-30, TG1: T7, S3, C6, C11): gov-release.sh refuses under each agent marker
# without the nonce, with SSH_ASKPASS(_REQUIRE), without a terminal, with the sandbox-only variables
# outside the sandbox, and (under the nonce) with anything outside the sandbox HOME; a C6 "yes"
# without --terms-bump fails and with it passes; the C11 listing fails on an unmapped network file
# and a missing NOTICE bullet; the real test-terms-text.sh runs once; the real release signs with
# stderr visible and SSH_AUTH_SOCK unset (witness ssh-keygen) and puts the answers in the notes.
# T12 (apply under load) is a measurement, run by hand: GOV_TEST_T12=1 (GOV_TEST_T12_NICE=1 runs it
# under nice -n 19).
# GOV_TEST_SLOW=1 adds one fetch with the real deep verify (~80 s).
# GOV_TEST_ONLY="T1 T2 ..." runs a subset (case names as printed).
#
# Every "nothing changed" claim is a hash of the sandbox tree before and after, and every refusal
# is paired with a case that proceeds — a suite whose guards never let anything through proves as
# little as one whose guards never stop anything. The mutants (M1-M4, M8, M10) prove the suite can fail.
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got [$2] want [$3])"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing [$3] in: $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-300))" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1 (unexpected [$3])" ;; *) ok "$1" ;; esac; }
want() { [ -z "${GOV_TEST_ONLY:-}" ] && return 0; case " $GOV_TEST_ONLY " in *" $1 "*) return 0 ;; esac; return 1; }
# one_line <label> <output> <expected text>: a --fetch exit path printed EXACTLY one non-empty line,
# it is a [GOVERNANCE UPDATE] line, and it carries the expected text (r2 findings 1, 12, 15).
one_line() {
  local n first
  n=$(printf '%s\n' "$2" | grep -c .)
  first=$(printf '%s\n' "$2" | grep . | head -1)
  is "$1: exactly one line printed" "$n" "1"
  case "$first" in "[GOVERNANCE UPDATE] "*) ok "$1: it is a [GOVERNANCE UPDATE] line" ;; *) bad "$1: not a [GOVERNANCE UPDATE] line: [$first]" ;; esac
  has "$1: it says what happened" "$2" "$3"
}

# The environment of the person running this must not leak in: a source-machine signal would turn
# every case into a silent "source machine" skip, an opt-out into a silent "off".
unset GOV_REPO_PATH GOV_RELEASE_KEY GOV_AUTO_UPDATE GOV_ACCEPT_TERMS GOV_UPDATE_OVERWRITE_LOCAL \
      GOV_UPDATE_ARCHIVE_URL GOV_SESSION_ID GOV_SESSION_SOURCE GOVERNANCE_UPDATE_CHECK
export GOVERNANCE_HOOKS=1 GOV_NO_STDIN=1

# Only a person accepts (C3, 2026-09-30): install.sh and gov-update.sh --accept-terms refuse inside an
# AI-agent session. The suite never unsets the markers (T4); every sandbox HOME that must accept gets
# the selftest nonce instead (nonce_home), which consent-lib.sh honours only in a non-real HOME (S2).
# [CONSENT] forces CLAUDECODE=1 on its own cases, so its refusals fire outside an agent session too.
NONCE="st-$$-$RANDOM"
export GOV_CONSENT_SELFTEST="$NONCE"
nonce_home() { mkdir -p "$1" && printf '%s\n' "$NONCE" > "$1/.governance-consent-selftest"; }
if [ -n "${CLAUDECODE:-}" ] || [ -n "${AI_AGENT:-}" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]; then
  echo "test-gov-update: AI-agent markers present in the suite env (the nonce is what lets installs accept)"
else
  echo "NOTE: not an agent session; refusal cases exercise the code path only ([CONSENT] sets CLAUDECODE=1 itself)"
fi

for _t in ssh-keygen tar git node curl sha256sum; do
  command -v "$_t" >/dev/null 2>&1 || { echo "test-gov-update: $_t is required and missing - this is a FAILURE, not a skip"; exit 1; }
done

# ── where the code under test lives ─────────────────────────────────────────────────────────
REPO=""
for _cand in "$SCRIPT_DIR/../../../.." "$HOME/.claude/governance-installer"; do
  if [ -f "$_cand/install.sh" ] && [ -d "$_cand/bundle/hooks/governance" ]; then REPO="$(cd "$_cand" && pwd)"; break; fi
done
[ -n "$REPO" ] || { echo "test-gov-update: cannot find the installer tree (install.sh + bundle/) - FAILURE"; exit 1; }
# shellcheck source=/dev/null
. "$GOV_DIR/release-manifest.sh" || { echo "test-gov-update: cannot load release-manifest.sh"; exit 1; }
# shellcheck source=/dev/null
. "$GOV_DIR/_common.sh" 2>/dev/null

SB=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/gov-upd-test.$$")
REAL_MV="$(command -v mv)"
cleanup() {
  [ -f "$SB/stub-sleeper.pid" ] && kill "$(cat "$SB/stub-sleeper.pid")" 2>/dev/null
  [ -n "${LIVE_PID:-}" ] && kill "$LIVE_PID" 2>/dev/null
  if [ "${GOV_TEST_KEEP:-0}" = "1" ]; then echo "test-gov-update: sandbox KEPT at $SB (GOV_TEST_KEEP=1)"; else rm -rf "$SB"; fi
}
trap cleanup EXIT
echo "test-gov-update: code under test = $REPO"
echo "test-gov-update: sandbox        = $SB"

url_of() {  # file:// URL template for a remote directory (native curl on Windows wants C:/...)
  if command -v cygpath >/dev/null 2>&1; then printf 'file:///%s/v%%s.tar.gz' "$(cygpath -m "$1")"
  else printf 'file://%s/v%%s.tar.gz' "$1"; fi
}

# ── keys ────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$SB/keys"
for k in k1 k2; do ssh-keygen -q -t ed25519 -N '' -f "$SB/keys/$k" -C t </dev/null >/dev/null 2>&1; done
signer_line() { printf '%s namespaces="%s",valid-after="20200101",valid-before="20991231" %s\n' "$RELMAN_PRINCIPAL" "$RELMAN_NS" "$(cut -d' ' -f1,2 "$SB/keys/$1.pub")"; }

# ── the fixture source tree: this checkout's shippable files ─────────────────────────────────
SRC="$SB/src"; mkdir -p "$SRC"
if [ -d "$REPO/.git" ]; then
  _list=$(git -C "$REPO" ls-files --cached --others --exclude-standard 2>/dev/null)
else
  _list=$(cd "$REPO" && find . -type f | sed 's|^\./||')
fi
printf '%s\n' "$_list" | grep -Ev '(^|/)desktop\.ini$|\.bak($|-)|^RELEASE-MANIFEST' | while IFS= read -r f; do
  [ -f "$REPO/$f" ] || continue
  mkdir -p "$SRC/$(dirname "$f")"; cp "$REPO/$f" "$SRC/$f"
done
mkdir -p "$SRC/bundle/release"
signer_line k1 > "$SRC/bundle/release/allowed_signers"
[ -f "$SRC/install.sh" ] && [ -f "$SRC/bundle/hooks/governance/gov-update.sh" ] \
  || { echo "test-gov-update: fixture source incomplete (no install.sh or gov-update.sh) - FAILURE"; exit 1; }

# mkrel <name> <ver> <key> [<pre-sign mutation fn>] [<post-sign mutation fn>]
#   builds $SB/rel/<name>/claude-code-governance-<ver> and $SB/remote-<name>/v<ver>.tar.gz
mkrel() {
  local name="$1" ver="$2" key="$3" pre="${4:-}" post="${5:-}" d t terms
  d="$SB/rel/$name"; t="$d/claude-code-governance-$ver"
  rm -rf "$d"; mkdir -p "$d" "$SB/remote-$name"
  cp -r "$SRC" "$t"
  printf '%s\n' "$ver" > "$t/bundle/VERSION"
  [ -n "$pre" ] && "$pre" "$t"
  terms=$(tr -d '[:space:]' < "$t/bundle/TERMS-VERSION" 2>/dev/null); [ -n "$terms" ] || terms=1
  bash "$t/install.sh" --print-install-map > "$d/map" 2>/dev/null </dev/null
  [ -n "${MAP_EXTRA:-}" ] && printf '%s\n' "$MAP_EXTRA" >> "$d/map"
  relman_build "$t" "$ver" "$terms" "$d/map" 2026-01-01T00:00:00Z > "$t/RELEASE-MANIFEST" || { echo "mkrel $name: build failed"; return 1; }
  ssh-keygen -Y sign -f "$SB/keys/$key" -n "$RELMAN_NS" "$t/RELEASE-MANIFEST" </dev/null >/dev/null 2>&1 || { echo "mkrel $name: sign failed"; return 1; }
  [ -n "$post" ] && "$post" "$t"
  (cd "$d" && tar -czf "$SB/remote-$name/v$ver.tar.gz" "claude-code-governance-$ver")
}

# ── sandbox HOMEs ───────────────────────────────────────────────────────────────────────────
H="$SB/h"
# treehash: every installed file's content, every DIRECTORY (a rollback must remove what the apply
# created), and the update state a rollback must restore (the baseline, the manifest, the pinned key,
# the merge memory, the mode, the terms record). Logs, backups and transient state are excluded.
treehash() {
  (cd "$H/.claude" && {
     find . -type d ! -path './logs*' ! -path './backups*' ! -path './.governance-update*' | LC_ALL=C sort
     find . -type f ! -path './logs/*' ! -path './backups/*' ! -path './.governance-update/*' \
       | LC_ALL=C sort | tr '\n' '\0' | xargs -0 sha256sum 2>/dev/null
     for f in installed.hashes installed.manifest allowed_signers settings-hooks.installed.json install-mode terms-accepted close-push; do
       [ -f ".governance-update/$f" ] && sha256sum ".governance-update/$f"
     done
   }) | sha256sum | cut -c1-16
}
use_home() { rm -rf "$H"; cp -r "$1" "$H"; }
upd() {  # upd <args...> — the INSTALLED gov-update.sh (or $UPD_SCRIPT) under the sandbox HOME
  HOME="$H" GOV_UPDATE_ALLOW_FILE=1 GOV_UPDATE_SKIP_DEEP_VERIFY="${DEEP_SKIP-1}" \
  GOV_UPDATE_ATTEMPT_SPACING="${SPACING:-0}" GOV_UPDATE_ARCHIVE_URL="$URL" \
  GOV_SESSION_SOURCE="${SRCKIND-startup}" GOV_SESSION_ID="${SID:-test-self}" \
  bash "${UPD_SCRIPT:-$H/.claude/hooks/governance/gov-update.sh}" "$@" </dev/null 2>/dev/null
}
halt_reason() { sed -n 's/^reason=\([^ ]*\).*/\1/p' "$H/.claude/.governance-update/HALT-$1" 2>/dev/null; }
marker() { tr -d '[:space:]' < "$H/.claude/.governance-version" 2>/dev/null; }
# wait_until <seconds> <condition>: polls every 0.5 s; rc 0 once the condition holds (detached children).
wait_until() { local n=0 lim=$(( $1 * 2 )); while ! eval "$2" && [ "$n" -lt "$lim" ]; do sleep 0.5; n=$((n + 1)); done; eval "$2"; }

# File mode helpers (S4: records are 0600). Some Windows filesystems ignore chmod: probe once, and
# report a skip there instead of a false pass or a false fail.
_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
: > "$SB/modeprobe"; chmod 600 "$SB/modeprobe" 2>/dev/null
_MODES=0; [ "$(_mode "$SB/modeprobe")" = "600" ] && _MODES=1
_mode_is_600() {  # _mode_is_600 <label> <file>
  if [ "$_MODES" = "1" ]; then is "$1" "$(_mode "$2")" "600"
  else echo "  skip $1 (this filesystem ignores chmod: a 600 probe reads $(_mode "$SB/modeprobe"))"; fi
}
_hash_file() { tr -d '\r' < "$1" | sha256sum | cut -d' ' -f1; }
EMPTY_SHA=$(printf '' | sha256sum | cut -d' ' -f1)
CP_OFF_NOTTY='Push at session close: OFF (the default without a terminal). To turn it on, run this yourself in your own terminal: bash ~/.claude/hooks/governance/close-push.sh --enable'
CP_SUM_OFF='  Push at session close:  OFF - turn on: bash ~/.claude/hooks/governance/close-push.sh --enable'
CP_SUM_UPD='  Automatic updates:      not in this version (you update by hand)'

echo "building fixture releases ..."
mkrel base 1.9.0 k1 || exit 1
# The 1.9.0 baseline, installed exactly as a user would: tagged tree, terms accepted by flag.
BASE="$SB/base-home"; mkdir -p "$BASE"; nonce_home "$BASE"   # use_home copies carry the nonce
_inst=$(HOME="$BASE" bash "$SB/rel/base/claude-code-governance-1.9.0/install.sh" --accept-terms --no-verify 2>&1 </dev/null); _irc=$?
is "baseline: install.sh 1.9.0 exits 0" "$_irc" "0"
[ "$_irc" = "0" ] || printf '%s\n' "$_inst" | tail -15
has "baseline: signed release recognised" "$_inst" "Installing signed release v1.9.0"
has "baseline: release key pinned on first install" "$_inst" "PINNED (trust on first install)"
is "baseline: marker 1.9.0" "$(tr -d '[:space:]' < "$BASE/.claude/.governance-version" 2>/dev/null)" "1.9.0"
for f in allowed_signers installed.hashes installed.manifest install-mode terms-accepted settings-hooks.installed.json close-push; do
  is "baseline: .governance-update/$f written" "$([ -s "$BASE/.claude/.governance-update/$f" ] && echo yes || echo no)" "yes"
done
# C4: no terminal, no flag -> push at session close is recorded OFF, and the output says so.
_bcp="$BASE/.claude/.governance-update/close-push"
is "baseline: close-push = enabled=0 terms_version=1 method=default-non-interactive" \
   "$(gov_record_field "$_bcp" enabled) $(gov_record_field "$_bcp" terms_version) $(gov_record_field "$_bcp" method)" "0 1 default-non-interactive"
is "baseline: close-push field order, one line" \
   "$(sed -n 's/^enabled=0 terms_version=1 decided_at=[0-9TZ:-]* framework_version=1\.9\.0 method=default-non-interactive notice_sha256=[0-9a-f]\{64\} shown_sha256=[0-9a-f]\{64\}$/shape-ok/p' "$_bcp")/$(wc -l < "$_bcp" | tr -d ' ')" "shape-ok/1"
is "baseline: close-push notice_sha256 = the installed NOTICE, CR-stripped" \
   "$(gov_record_field "$_bcp" notice_sha256)" "$(_hash_file "$SB/rel/base/claude-code-governance-1.9.0/NOTICE-AUTO-UPDATE.md")"
is "baseline: close-push shown_sha256 = the empty-string hash (no question was shown)" "$(gov_record_field "$_bcp" shown_sha256)" "$EMPTY_SHA"
_mode_is_600 "baseline: close-push is mode 600" "$_bcp"
has "baseline: the A.7 no-terminal line" "$_inst" "$CP_OFF_NOTTY"
has "baseline: the A.8 push line (OFF)" "$_inst" "$CP_SUM_OFF"
has "baseline: the A.8 updates line (not in this version)" "$_inst" "$CP_SUM_UPD"
hasnt "baseline: no question was shown without a terminal" "$_inst" "Turn push at session close ON now?"
cp -r "$SB/rel/base/claude-code-governance-1.9.0" "$BASE/.claude/governance-installer"

# 2.0.0 drops a doc 1.9.0 had and adds an extended skill.
pre_t1() {
  rm -f "$1/bundle/docs/ROTATE-CONNECTOR-TOKEN.md"
  mkdir -p "$1/bundle/skills/test-new-skill"
  printf -- '---\nname: test-new-skill\ndescription: fixture\n---\nfixture\n' > "$1/bundle/skills/test-new-skill/SKILL.md"
  printf '\n[extended]\ntest-new-skill\n' >> "$1/bundle/DISTRIBUTED"
}
mkrel good 2.0.0 k1 pre_t1 || exit 1
URL=$(url_of "$SB/remote-good")

# ════════════════════════════════════════════════════════════════════════════════════════════
if want T1; then
echo "(${SECONDS}s) [T1] valid update 1.9.0 -> 2.0.0 (one doc dropped, one skill added)"
use_home "$BASE"; _before=$(treehash); _cpb=$(sha256sum < "$H/.claude/.governance-update/close-push")
upd --fetch 2.0.0
is "fetch wrote READY" "$([ -f "$H/.claude/.governance-update/READY" ] && echo yes || echo no)" "yes"
is "the staged tree exists" "$([ -f "$H/.claude/.governance-update/staged/v2.0.0/RELEASE-MANIFEST" ] && echo yes || echo no)" "yes"
is "fetch alone changed nothing installed" "$(treehash)" "$_before"
_o=$(upd --apply)
has "notice printed" "$_o" "Applied v2.0.0 (was v1.9.0"
hasnt "  it does not claim it applied automatically (2.0.0 has no automatic update)" "$_o" "automatically"
hasnt "  it names no automatic-update switch" "$_o" "GOV_AUTO_UPDATE"
has "  it ends with the rollback command and the restart note (A16)" "$_o" "Roll back: bash ~/.claude/hooks/governance/gov-update.sh --rollback. Restart Claude Code if a hook or agent was added."
is "marker stamped 2.0.0" "$(marker)" "2.0.0"
is "the apply left the close-push record byte for byte (an update never changes the user's choice)" \
   "$(sha256sum < "$H/.claude/.governance-update/close-push" 2>/dev/null)" "$_cpb"
is "installed.manifest is 2.0.0's" "$(relman_get "$H/.claude/.governance-update/installed.manifest" version)" "2.0.0"
# Verify round 4 #2 (2026-10-02): the installed terms copy is part of the install map, so the apply
# writes it with installed.manifest and the two terms sources still agree (consent-lib.sh fails
# closed when they do not).
is "the install map carries the terms copy (TERMS-VERSION and the NOTICE)" \
   "$(relman_section "$H/.claude/.governance-update/installed.manifest" install-map | grep -cE '^(bundle/TERMS-VERSION|NOTICE-AUTO-UPDATE\.md) -> hooks/governance-terms/')" "2"
is "after the apply: the copy's TERMS-VERSION = installed.manifest's terms_version" \
   "$(tr -d '[:space:]' < "$H/.claude/hooks/governance-terms/TERMS-VERSION" 2>/dev/null)/$(relman_get "$H/.claude/.governance-update/installed.manifest" terms_version)" "1/1"
is "  ... and the NOTICE copy is the release's, byte for byte" \
   "$(cmp -s "$H/.claude/hooks/governance-terms/NOTICE-AUTO-UPDATE.md" "$SB/rel/good/claude-code-governance-2.0.0/NOTICE-AUTO-UPDATE.md" && echo same || echo differs)" "same"
is "installed.hashes lists the new skill" "$(grep -c ' skills/test-new-skill/SKILL.md$' "$H/.claude/.governance-update/installed.hashes")" "1"
is "the new skill is installed" "$([ -f "$H/.claude/skills/test-new-skill/SKILL.md" ] && echo yes || echo no)" "yes"
is "the dropped doc is gone" "$([ -f "$H/.claude/docs/ROTATE-CONNECTOR-TOKEN.md" ] && echo present || echo gone)" "gone"
_bk=$(ls -1d "$H/.claude/backups"/governance-update-* 2>/dev/null | tail -1)
is "the backup holds the dropped doc" "$([ -f "$_bk/docs/ROTATE-CONNECTOR-TOKEN.md" ] && echo yes || echo no)" "yes"
is "the backup holds a replaced hook" "$([ -f "$_bk/hooks/governance/_common.sh" ] && echo yes || echo no)" "yes"
is "the backup holds settings.json" "$([ -f "$_bk/settings.json" ] && echo yes || echo no)" "yes"
is "log has APPLIED" "$(grep -c 'APPLIED v1.9.0 -> v2.0.0' "$H/.claude/logs/governance-update.log")" "1"
printf '  (timing: %s)\n' "$(grep -o 'mv retries [0-9]*, [0-9]*s' "$H/.claude/logs/governance-update.log" | tail -1)"
is "READY removed" "$([ -f "$H/.claude/.governance-update/READY" ] && echo present || echo gone)" "gone"
is "governance-installer refreshed (VERSION)" "$(tr -d '[:space:]' < "$H/.claude/governance-installer/bundle/VERSION")" "2.0.0"
is "governance-installer: dropped doc removed there too" "$([ -f "$H/.claude/governance-installer/bundle/docs/ROTATE-CONNECTOR-TOKEN.md" ] && echo present || echo gone)" "gone"
is "governance-installer carries the signed manifest" "$(relman_get "$H/.claude/governance-installer/RELEASE-MANIFEST" version)" "2.0.0"
_o2=$(upd --apply)
has "a second --apply finds nothing staged (the notice is printed once)" "$_o2" "nothing is staged"
_o2=$(upd --apply-if-ready)
is "  and the recovery entry point is silent with nothing to recover" "$_o2" ""
is "installed.hashes match the disk (fresh baseline)" \
   "$(cd "$H/.claude" && sed 's/^[0-9a-f]*  //' .governance-update/installed.hashes | tr '\n' '\0' | xargs -0 sha256sum | sed 's/ \*/  /' | cmp -s - .governance-update/installed.hashes && echo yes || echo no)" "yes"
T1_HOME="$SB/t1-home"; rm -rf "$T1_HOME"; cp -r "$H" "$T1_HOME"
fi

# ── staged snapshot for the Phase-B cases ─────────────────────────────────────────────────────
use_home "$BASE"; upd --fetch 2.0.0
STAGED="$SB/staged-home"; rm -rf "$STAGED"; cp -r "$H" "$STAGED"
[ -f "$STAGED/.claude/.governance-update/READY" ] || bad "precondition: a staged home could not be built (every Phase-B case below is void)"

# ════════════════════════════════════════════════════════════════════════════════════════════
if want T2; then
echo "(${SECONDS}s) [T2] bad signature (manifest signed by a second key)"
mkrel badsig 2.0.0 k2 pre_t1 >/dev/null
use_home "$BASE"; _before=$(treehash); URL=$(url_of "$SB/remote-badsig")
upd --fetch 2.0.0
is "HALT reason=signature" "$(halt_reason 2.0.0)" "signature"
is "READY never written" "$([ -f "$H/.claude/.governance-update/READY" ] && echo yes || echo no)" "no"
is "tree unchanged" "$(treehash)" "$_before"
_att=$(cat "$H/.claude/.governance-update/fetch-attempts-2.0.0" 2>/dev/null)
upd --fetch 2.0.0
is "no second fetch for a halted version" "$(cat "$H/.claude/.governance-update/fetch-attempts-2.0.0" 2>/dev/null)" "$_att"
printf '2.0.0\n' > "$H/.claude/logs/.governance-latest"
_o=$(HOME="$H" bash "$H/.claude/hooks/governance/pre-session.sh" <<< '{"cwd":"/tmp","source":"startup"}' 2>&1)
has "the next session start says it was halted" "$_o" "v2.0.0 was NOT installed (halted: signature)"
URL=$(url_of "$SB/remote-good")
fi

if want T3; then
echo "(${SECONDS}s) [T3] one byte changed in a hook after signing"
post_tamper() { printf '# x\n' >> "$1/bundle/hooks/governance/pre-task.sh"; }
mkrel tamper 2.0.0 k1 pre_t1 post_tamper >/dev/null
use_home "$BASE"; _before=$(treehash); URL=$(url_of "$SB/remote-tamper")
upd --fetch 2.0.0
is "HALT reason=checksum" "$(halt_reason 2.0.0)" "checksum"
is "tree unchanged" "$(treehash)" "$_before"
URL=$(url_of "$SB/remote-good")
fi

if want T3b; then
echo "(${SECONDS}s) [T3b] an extra file the manifest does not list"
post_extra_root() { printf 'x\n' > "$1/EXTRA.txt"; }
post_extra_bundle() { printf 'x\n' > "$1/bundle/hooks/governance/extra.sh"; }
for v in root bundle; do
  mkrel "extra$v" 2.0.0 k1 pre_t1 "post_extra_$v" >/dev/null
  use_home "$BASE"; URL=$(url_of "$SB/remote-extra$v")
  upd --fetch 2.0.0
  is "extra file in $v -> HALT checksum" "$(halt_reason 2.0.0)" "checksum"
done
URL=$(url_of "$SB/remote-good")
fi

if want T3c; then
echo "(${SECONDS}s) [T3c] hostile archive shapes"
_A="$SB/arch"; rm -rf "$_A"; mkdir -p "$_A/remote-abs" "$_A/remote-dotdot" "$_A/remote-twotop"
cp "$SB/remote-good/v2.0.0.tar.gz" "$_A/base.tgz"; gzip -dc "$_A/base.tgz" > "$_A/base.tar"
printf 'evil\n' > "$_A/evil"
cp "$_A/base.tar" "$_A/abs.tar";    (cd "$_A" && tar -rPf abs.tar --transform 's|^evil|/tmp/gov-evil|' evil 2>/dev/null)
cp "$_A/base.tar" "$_A/dotdot.tar"; (cd "$_A" && tar -rPf dotdot.tar --transform 's|^evil|claude-code-governance-2.0.0/../evil|' evil 2>/dev/null)
cp "$_A/base.tar" "$_A/twotop.tar"; (cd "$_A" && tar -rf twotop.tar --transform 's|^evil|other-top/evil|' evil 2>/dev/null)
for v in abs dotdot twotop; do
  gzip -c "$_A/$v.tar" > "$_A/remote-$v/v2.0.0.tar.gz"
  _members=$(tar -tzf "$_A/remote-$v/v2.0.0.tar.gz" 2>/dev/null | grep -c 'evil')
  is "precondition: the $v archive really carries the hostile member" "$([ "$_members" -ge 1 ] && echo yes || echo no)" "yes"
  use_home "$BASE"; _before=$(treehash); URL=$(url_of "$_A/remote-$v")
  upd --fetch 2.0.0
  is "$v member -> HALT archive" "$(halt_reason 2.0.0)" "archive"
  is "$v: tree unchanged" "$(treehash)" "$_before"
done
[ -e /tmp/gov-evil ] && bad "an absolute member was EXTRACTED to /tmp/gov-evil" && rm -f /tmp/gov-evil
URL=$(url_of "$SB/remote-good")
fi

if want T4; then
echo "(${SECONDS}s) [T4] downgrade"
mkrel down 1.8.0 k1 >/dev/null
use_home "$BASE"; _before=$(treehash); URL=$(url_of "$SB/remote-down")
upd --fetch 1.8.0
is "an older published version is never fetched" "$([ -f "$H/.claude/.governance-update/READY" ] && echo yes || echo no)" "no"
printf 'version=1.8.0 manifest_sha256=x staged_at=x\n' > "$H/.claude/.governance-update/READY"
_o=$(upd --apply)
has "a planted READY for 1.8.0 is refused" "$_o" "downgrade"
is "HALT reason=downgrade" "$(halt_reason 1.8.0)" "downgrade"
is "tree unchanged" "$(treehash)" "$_before"
URL=$(url_of "$SB/remote-good")
fi

if want T5; then
echo "(${SECONDS}s) [T5] network down, spacing, the attempt cap, tag 404"
use_home "$BASE"; URL=$(url_of "$SB/remote-missing")
_o=$(SPACING=3600 upd --fetch 2.0.0)
# r2 findings 1, 12, 15 (2026-10-01): this line was `is "network failure is silent" "$_o" ""`.
# A --fetch is a human's own act, so every exit path now says what happened in the terminal.
one_line "network failure" "$_o" "[GOVERNANCE UPDATE] v2.0.0 could not be downloaded (network: curl rc="
has "  it names the attempt and the cap" "$_o" "; attempt 1 of 10) - nothing staged. Details: ~/.claude/logs/governance-update.log"
hasnt "  it does not claim it staged" "$_o" "is downloaded and verified"
is "one attempt recorded" "$(cat "$H/.claude/.governance-update/fetch-attempts-2.0.0" 2>/dev/null)" "1"
is "one log line says network" "$(grep -c 'reason=network v2.0.0' "$H/.claude/logs/governance-update.log")" "1"
_o=$(SPACING=3600 upd --fetch 2.0.0)
is "a second call inside the spacing window does nothing" "$(cat "$H/.claude/.governance-update/fetch-attempts-2.0.0" 2>/dev/null)" "1"
one_line "inside the spacing window" "$_o" "[GOVERNANCE UPDATE] v2.0.0: the last download attempt was "
has "  it names the spacing" "$_o" " s ago; attempts are at least 3600 s apart - nothing downloaded. Try again in "
# The minutes depend on how long the first attempt took on a loaded machine (MEASURED 9 s): 59 or 60.
has "  and the way out" "$_o" " min, or reset the counters (this also clears every halt): bash ~/.claude/hooks/governance/gov-update.sh --clear-halt"
has "  and the log says so too" "$(cat "$H/.claude/logs/governance-update.log")" "skipped v2.0.0: inside the attempt spacing (3600 s; the last attempt was "
_o=$(SPACING=0 upd --fetch 2.0.0)
is "outside the window it tries again" "$(cat "$H/.claude/.governance-update/fetch-attempts-2.0.0" 2>/dev/null)" "2"
hasnt "  control: outside the window no spacing line" "$_o" "attempts are at least"
has "  control: it reports the new attempt instead" "$_o" "attempt 2 of 10)"
printf '10\n' > "$H/.claude/.governance-update/fetch-attempts-2.0.0"
_o=$(SPACING=0 upd --fetch 2.0.0)
is "at the cap a --fetch does not try again" "$(cat "$H/.claude/.governance-update/fetch-attempts-2.0.0" 2>/dev/null)" "10"
one_line "at the attempt cap" "$_o" "[GOVERNANCE UPDATE] v2.0.0: the download was already tried 10 times (the limit is 10) - nothing downloaded. To reset the counters (this also clears every halt): bash ~/.claude/hooks/governance/gov-update.sh --clear-halt"
printf '9\n' > "$H/.claude/.governance-update/fetch-attempts-2.0.0"
_o=$(SPACING=0 upd --fetch 2.0.0)
hasnt "  control: one below the cap there is no cap line" "$_o" "the download was already tried"
is "  control: and it tries (counter 10)" "$(cat "$H/.claude/.governance-update/fetch-attempts-2.0.0" 2>/dev/null)" "10"
printf '2.0.0\n' > "$H/.claude/logs/.governance-latest"
# 2.0.0 (P1, 2026-09-30): a session start never fetches, so it has no retry count to report - the
# old "could not be downloaded after 10 tries" give-up line went with the automatic fetch. At the
# cap the session start prints the same manual line as at any other time (P11 found this case still
# asserting the removed line: it is outside the selftest subset, so only the full run reaches it).
_o=$(HOME="$H" bash "$H/.claude/hooks/governance/pre-session.sh" <<< '{"cwd":"/tmp"}' 2>&1)
has "after the cap: the manual-path line" "$_o" "Update deliberately: git pull in your clone of Gold-b/claude-code-governance"
hasnt "  and no give-up line (it belonged to the removed automatic fetch)" "$_o" "could not be downloaded"
is "  and the session start did not advance the counter" "$(cat "$H/.claude/.governance-update/fetch-attempts-2.0.0" 2>/dev/null)" "10"
use_home "$BASE"
mkdir -p "$SB/stub404"
printf '#!/bin/sh\nprintf 404\nexit 0\n' > "$SB/stub404/curl"; chmod +x "$SB/stub404/curl"
for i in 1 2 3; do
  _o=$(PATH="$SB/stub404:$PATH" upd --fetch 2.0.0)
  if [ "$i" -lt 3 ]; then
    one_line "404 number $i" "$_o" "[GOVERNANCE UPDATE] v2.0.0: the release tag was not found (HTTP 404, $i of 3; the third makes it a halt) - nothing downloaded."
  else
    one_line "404 number 3 (the halt line only, not a 404 line as well)" "$_o" "[GOVERNANCE UPDATE] v2.0.0 is halted (reason: no-tag) - nothing was prepared or installed."
    hasnt "  no separate 404 line on the third" "$_o" "the release tag was not found"
  fi
done
is "three 404s -> HALT no-tag" "$(halt_reason 2.0.0)" "no-tag"
printf '2.0.0\n' > "$H/.claude/logs/.governance-latest"
_o=$(HOME="$H" bash "$H/.claude/hooks/governance/pre-session.sh" <<< '{"cwd":"/tmp"}' 2>&1)
has "the maintainer line" "$_o" "has no release tag"
URL=$(url_of "$SB/remote-good")
fi

if want T6; then
echo "(${SECONDS}s) [T6] verify.sh fails after the swap -> byte-identical rollback"
pre_v_fail()  { pre_t1 "$1"; printf '#!/usr/bin/env bash\nexit 1\n' > "$1/verify.sh"; }
pre_v_skill() { pre_t1 "$1"; rm -rf "$1/bundle/skills/bootstrapper"; }
pre_v_sleep() { pre_t1 "$1"; printf '#!/usr/bin/env bash\nsleep 20\n' > "$1/verify.sh"; }
for v in fail:verify-failed skill:verify-failed sleep:verify-timeout; do
  n="${v%%:*}"; want_r="${v#*:}"
  mkrel "v$n" 2.0.0 k1 "pre_v_$n" >/dev/null
  use_home "$BASE"; URL=$(url_of "$SB/remote-v$n")
  upd --fetch 2.0.0
  is "$n: staged" "$([ -f "$H/.claude/.governance-update/READY" ] && echo yes || echo no)" "yes"
  _before=$(treehash); cp "$H/.claude/settings.json" "$SB/settings.before"
  _o=$(GOV_UPDATE_VERIFY_TIMEOUT=3 upd --apply)
  has "$n: the notice names the backup it restored from" "$_o" "restored from ~/.claude/backups/governance-update-"
  is "$n: tree byte-identical to before" "$(treehash)" "$_before"
  is "$n: settings.json identical" "$(cmp -s "$SB/settings.before" "$H/.claude/settings.json" && echo same || echo differs)" "same"
  is "$n: marker unchanged" "$(marker)" "1.9.0"
  if [ "$want_r" = "verify-timeout" ]; then
    # Out of time is retried (a loaded machine at nice 19), halted only on the third failure.
    is "$n: first time out -> NOT halted, retried" "$(halt_reason 2.0.0)" ""
    has "$n:   and it names the retry BY HAND (nothing retries on its own, A16)" "$_o" "retry it by hand: bash ~/.claude/hooks/governance/gov-update.sh --apply (failed attempt 1 of 3)"
    printf '2\n' > "$H/.claude/.governance-update/retry-2.0.0"
    _o=$(GOV_UPDATE_VERIFY_TIMEOUT=3 upd --apply)
    is "$n: third time out -> HALT reason=$want_r" "$(halt_reason 2.0.0)" "$want_r"
  else
    is "$n: HALT reason=$want_r" "$(halt_reason 2.0.0)" "$want_r"
  fi
  has "$n: the notice names the backup" "$_o" "could NOT be applied ($want_r)"
done
URL=$(url_of "$SB/remote-good")
fi

if want T7; then
echo "(${SECONDS}s) [T7] the release source machine never updates itself"
use_home "$BASE"; touch "$H/.claude/.governance-source"
upd --fetch 2.0.0
is "marker file alone refuses" "$([ -f "$H/.claude/.governance-update/fetch-attempts-2.0.0" ] && echo fetched || echo refused)" "refused"
use_home "$BASE"
printf 'GOV_REPO_PATH=x; touch "%s/sourced"\n' "$SB" > "$H/.claude/.governance-local.env"
upd --fetch 2.0.0
is "GOV_REPO_PATH in the local env file alone refuses" "$([ -f "$H/.claude/.governance-update/fetch-attempts-2.0.0" ] && echo fetched || echo refused)" "refused"
is "the local env file was NOT sourced" "$([ -f "$SB/sourced" ] && echo sourced || echo grepped)" "grepped"
use_home "$BASE"
GOV_RELEASE_KEY=/nonexistent upd --fetch 2.0.0
is "GOV_RELEASE_KEY alone refuses" "$([ -f "$H/.claude/.governance-update/fetch-attempts-2.0.0" ] && echo fetched || echo refused)" "refused"
use_home "$STAGED"; touch "$H/.claude/.governance-source"; _before=$(treehash)
upd --apply
is "apply refuses on the source machine too" "$(treehash)" "$_before"
has "  and logs why" "$(cat "$H/.claude/logs/governance-update.log" 2>/dev/null)" "reason=source-machine (marker ~/.claude/.governance-source)"
use_home "$BASE"
upd --fetch 2.0.0
is "no signal -> it proceeds" "$([ -f "$H/.claude/.governance-update/READY" ] && echo staged || echo refused)" "staged"
fi

if want T8; then
echo "(${SECONDS}s) [T8] cross-session lock"
use_home "$BASE"; mkdir -p "$H/.claude/.governance-update/lock.d"
printf 'pid=%s since=x mode=apply\n' "$$" > "$H/.claude/.governance-update/lock.d/info"
_o=$(upd --fetch 2.0.0)
is "a live lock -> the second run does nothing" "$([ -f "$H/.claude/.governance-update/fetch-attempts-2.0.0" ] && echo ran || echo skipped)" "skipped"
is "and says so in the log" "$(grep -c 'locked by pid=' "$H/.claude/logs/governance-update.log")" "1"
one_line "a live lock" "$_o" "[GOVERNANCE UPDATE] another update process holds the lock - nothing downloaded; run this again in a minute."
printf 'pid=999999 since=x mode=apply\n' > "$H/.claude/.governance-update/lock.d/info"
touch -d '2 hours ago' "$H/.claude/.governance-update/lock.d/info" 2>/dev/null
_o=$(upd --fetch 2.0.0)
hasnt "  control: a stale lock prints no lock line" "$_o" "holds the lock"
one_line "  control: the run that broke the stale lock" "$_o" "[GOVERNANCE UPDATE] v2.0.0 is downloaded and verified ("
is "a stale lock (dead pid) is broken" "$(grep -c 'stale lock broken' "$H/.claude/logs/governance-update.log")" "1"
is "and the run proceeds" "$([ -f "$H/.claude/.governance-update/READY" ] && echo yes || echo no)" "yes"
is "the lock is released afterwards" "$([ -d "$H/.claude/.governance-update/lock.d" ] && echo held || echo free)" "free"
fi

# [FETCHMSG] (2026-10-01, r2 findings 1, 12, 15): every --fetch exit path prints exactly one
# [GOVERNANCE UPDATE] line saying what happened - staged, refused and why, or skipped and why - and
# keeps its log line. Every refusal is paired with a control that proceeds. T5 covers the network
# failure, the spacing, the cap and the 404s; T8 the lock; NOAUTO (f) the halts, the source machine,
# a non-version and an older version.
if want FETCHMSG; then
echo "(${SECONDS}s) [FETCHMSG] every --fetch exit path says what happened in the terminal"
U_="$H/.claude/.governance-update"
_INSTALL_TAIL="To install: close every Claude Code session, then in your own terminal run  bash ~/.claude/hooks/governance/gov-update.sh --apply --force-live"
echo "  (a) success: the staged line (it was in the log only)"
use_home "$BASE"; URL=$(url_of "$SB/remote-good")
_o=$(upd --fetch 2.0.0)
is "  precondition: READY written" "$([ -f "$U_/READY" ] && echo staged || echo none)" "staged"
_nf=$(relman_get "$U_/staged/v2.0.0/RELEASE-MANIFEST" files)
one_line "success" "$_o" "[GOVERNANCE UPDATE] v2.0.0 is downloaded and verified ($_nf files) and staged; nothing is installed. $_INSTALL_TAIL"
has "  the log line is kept" "$(cat "$H/.claude/logs/governance-update.log")" "STAGED v2.0.0 ($_nf files verified)"
echo "  (b) the same version again: already staged (it was silent)"
_o=$(upd --fetch 2.0.0)
one_line "already staged" "$_o" "[GOVERNANCE UPDATE] v2.0.0 is already downloaded and verified (staged) - nothing downloaded again. $_INSTALL_TAIL"
is "  nothing downloaded again (still one attempt)" "$(cat "$U_/fetch-attempts-2.0.0" 2>/dev/null)" "1"
hasnt "  it does not claim a fresh download" "$_o" "is downloaded and verified ("
echo "  (c) a file:// URL without GOV_UPDATE_ALLOW_FILE=1: refused, and says why (it was silent)"
use_home "$BASE"
_o=$(env -u GOV_UPDATE_ALLOW_FILE HOME="$H" GOV_UPDATE_ARCHIVE_URL="$URL" GOV_UPDATE_SKIP_DEEP_VERIFY=1 \
       bash "$H/.claude/hooks/governance/gov-update.sh" --fetch 2.0.0 </dev/null 2>/dev/null)
one_line "file:// without the test switch" "$_o" "[GOVERNANCE UPDATE] refused the archive URL: file:// is accepted only with GOV_UPDATE_ALLOW_FILE=1 (tests only) - nothing downloaded."
is "  no attempt counted (the URL is checked before the counter)" "$([ -f "$U_/fetch-attempts-2.0.0" ] && echo counted || echo none)" "none"
has "  the log line is kept" "$(cat "$H/.claude/logs/governance-update.log")" "refused file:// URL without GOV_UPDATE_ALLOW_FILE=1"
_o=$(upd --fetch 2.0.0)
hasnt "  control: the same URL with the switch is not refused" "$_o" "refused the archive URL"
has "  control: and it stages, on the first try" "$_o" "[GOVERNANCE UPDATE] v2.0.0 is downloaded and verified ("
echo "  (d) an http:// URL: refused, and says why (it was silent)"
use_home "$BASE"
_o=$(URL="http://127.0.0.1:9/v%s.tar.gz" upd --fetch 2.0.0)
one_line "http://" "$_o" "[GOVERNANCE UPDATE] refused the archive URL: only https:// is accepted (check GOV_UPDATE_ARCHIVE_URL) - nothing downloaded."
is "  no attempt counted" "$([ -f "$U_/fetch-attempts-2.0.0" ] && echo counted || echo none)" "none"
has "  the log line is kept" "$(cat "$H/.claude/logs/governance-update.log")" "refused a non-https archive URL"
_o=$(URL="https://127.0.0.1:9/v%s.tar.gz" upd --fetch 2.0.0)
hasnt "  control: an https:// URL is not refused" "$_o" "refused the archive URL"
one_line "  control: an unreachable https:// URL" "$_o" "[GOVERNANCE UPDATE] v2.0.0 could not be downloaded (network: curl rc="
echo "  (e) GOVERNANCE_HOOKS=0 with the bypass notice muted: still one line (it was silent)"
use_home "$BASE"; URL=$(url_of "$SB/remote-good")
_o=$(GOVERNANCE_HOOKS=0 GOV_BYPASS_QUIET=1 upd --fetch 2.0.0)
one_line "GOVERNANCE_HOOKS=0" "$_o" "[GOVERNANCE UPDATE] GOVERNANCE_HOOKS=0 is set (governance is off) - nothing downloaded."
is "  nothing fetched" "$([ -f "$U_/fetch-attempts-2.0.0" ] || [ -f "$U_/READY" ] && echo fetched || echo off)" "off"
_o=$(GOVERNANCE_HOOKS=1 upd --fetch 2.0.0)
hasnt "  control: GOVERNANCE_HOOKS=1 prints no off line" "$_o" "governance is off"
echo "  (f) no version given: says how to call it (it printed \"'' is not a version\")"
use_home "$BASE"
_o=$(upd --fetch)
one_line "no version" "$_o" "[GOVERNANCE UPDATE] no version given - nothing downloaded. Usage: bash ~/.claude/hooks/governance/gov-update.sh --fetch <version>"
hasnt "  not the empty-name line" "$_o" "'' is not a version"
_o=$(upd --fetch banana)
hasnt "  control: a non-empty non-version keeps its own line" "$_o" "no version given"
echo "  (g) the verified tree cannot be moved into place: says so (it was in the log only)"
use_home "$BASE"
mkdir -p "$SB/stubmvstage"
cat > "$SB/stubmvstage/mv" <<EOF
#!/bin/sh
for a in "\$@"; do last="\$a"; done
case "\$last" in */staged/v[0-9]*) exit 1 ;; esac
exec "$REAL_MV" "\$@"
EOF
chmod +x "$SB/stubmvstage/mv"
_o=$(PATH="$SB/stubmvstage:$PATH" upd --fetch 2.0.0)
one_line "stage failure" "$_o" "[GOVERNANCE UPDATE] v2.0.0 verified, but it could not be moved into ~/.claude/.governance-update/staged - nothing staged. Details: ~/.claude/logs/governance-update.log"
is "  no READY" "$([ -f "$U_/READY" ] && echo staged || echo none)" "none"
hasnt "  it does not claim it staged" "$_o" "is downloaded and verified ("
has "  the log line is kept" "$(cat "$H/.claude/logs/governance-update.log")" "could not move the staged tree into place"
echo "  (g2) READY cannot be written: says so (it would have been logged as STAGED, and printed nothing)"
use_home "$BASE"
mkdir -p "$SB/stubmvready"
cat > "$SB/stubmvready/mv" <<EOF
#!/bin/sh
for a in "\$@"; do last="\$a"; done
case "\$last" in */.governance-update/READY) exit 1 ;; esac
exec "$REAL_MV" "\$@"
EOF
chmod +x "$SB/stubmvready/mv"
_o=$(PATH="$SB/stubmvready:$PATH" upd --fetch 2.0.0)
one_line "READY write failure" "$_o" "[GOVERNANCE UPDATE] v2.0.0 verified, but ~/.claude/.governance-update/READY could not be written - nothing staged. Details: ~/.claude/logs/governance-update.log"
is "  no READY" "$([ -f "$U_/READY" ] && echo staged || echo none)" "none"
hasnt "  no STAGED log line" "$(cat "$H/.claude/logs/governance-update.log")" "STAGED v2.0.0"
_o=$(upd --fetch 2.0.0)
hasnt "  control: without the stub the next --fetch has no failure line" "$_o" "could not be written"
has "  control: and stages" "$_o" "[GOVERNANCE UPDATE] v2.0.0 is downloaded and verified ("
echo "  (g3) the state folder cannot be created: says so, not \"another process holds the lock\""
use_home "$BASE"; rm -rf "$U_"; printf 'not a folder\n' > "$U_"
_o=$(upd --fetch 2.0.0)
one_line "state folder blocked by a file" "$_o" "[GOVERNANCE UPDATE] cannot create ~/.claude/.governance-update - nothing downloaded."
hasnt "  it does not blame a lock" "$_o" "holds the lock"
has "  the log says why" "$(cat "$H/.claude/logs/governance-update.log")" "fetch skipped"
use_home "$BASE"
_o=$(upd --fetch 2.0.0)
hasnt "  control: with the folder creatable there is no such line" "$_o" "cannot create"
echo "  (h) the documents state the messaging"
has "NOTICE item 2 documents the --fetch line" "$(tr '\n' ' ' < "$SRC/NOTICE-AUTO-UPDATE.md" | tr -s ' ')" "Every \`--fetch\` ends with one \`[GOVERNANCE UPDATE]\` line in your terminal"
has "README documents the --fetch line" "$(tr '\n' ' ' < "$SRC/README.md" | tr -s ' ')" "Every \`--fetch\` ends with one \`[GOVERNANCE UPDATE]\` line in your terminal"
fi

# [NOAUTO] (2026-09-30, replaces the old [T9] opt-out): 2.0.0 has NO automatic update and no way to
# turn one on. Every switch the old designs had is planted at once, and nothing applies; the human
# path is the control that proves the staged release COULD have been applied.
if want NOAUTO; then
echo "(${SECONDS}s) [NOAUTO] no variable, record or flag enables an unattended apply; the human path works"
U_="$H/.claude/.governance-update"
echo "  (a) every old switch ON at once, a verified release staged: --apply-if-ready applies nothing"
use_home "$STAGED"
printf 'enabled=1 terms_version=1 accepted_at=2026-01-01T00:00:00Z method=interactive\n' > "$U_/auto-update"
printf 'GOV_AUTO_UPDATE=1\nGOV_ENABLE_AUTO_UPDATE=1\n' > "$H/.claude/.governance-local.env"
is "  precondition: terms accepted (v1) and a READY staged" "$(grep -c 'terms_version=1' "$U_/terms-accepted" 2>/dev/null)/$([ -f "$U_/READY" ] && echo staged || echo none)" "1/staged"
_before=$(treehash)
for s in session-end startup resume ""; do
  _o=$(GOV_AUTO_UPDATE=1 GOV_ENABLE_AUTO_UPDATE=1 SRCKIND="$s" upd --apply-if-ready)
  is "source=${s:-<absent>}: silent" "$_o" ""
done
NOAUTO_TREE_OK=$([ "$(treehash)" = "$_before" ] && echo same || echo changed)
is "  tree unchanged" "$NOAUTO_TREE_OK" "same"
is "  marker still 1.9.0" "$(marker)" "1.9.0"
is "  READY kept (the release stays staged for the human)" "$([ -f "$U_/READY" ] && echo kept || echo gone)" "kept"
has "  the log says why" "$(cat "$H/.claude/logs/governance-update.log" 2>/dev/null)" "automatic apply is not available in this version; a staged release is applied only by hand: --apply --force-live"
_o=$(upd --status)
has "  --status says so, with the hand commands (A16)" "$_o" "automatic update: not available in this version (update by hand: --fetch <ver>, then --apply --force-live)"
hasnt "  --status offers no switch" "$_o" "GOV_AUTO_UPDATE"
_o=$(upd --apply)
has "  control: the human --apply on the same machine applies it" "$_o" "Applied v2.0.0"
echo "  (b) --fetch is a human mode: no pause variable gates it"
use_home "$BASE"; printf 'GOV_AUTO_UPDATE=0\n' > "$H/.claude/.governance-local.env"
GOV_AUTO_UPDATE=0 upd --fetch 2.0.0
is "GOV_AUTO_UPDATE=0 (env and local file): a hand --fetch still STAGES" "$([ -f "$U_/READY" ] && [ -f "$U_/staged/v2.0.0/RELEASE-MANIFEST" ] && echo staged || echo off)" "staged"
use_home "$BASE"
_o=$(GOVERNANCE_UPDATE_CHECK=0 upd --fetch 2.0.0)
is "GOVERNANCE_UPDATE_CHECK=0 (no network): nothing downloaded" "$([ -f "$U_/fetch-attempts-2.0.0" ] || [ -f "$U_/READY" ] && echo fetched || echo off)" "off"
has "  and it says so" "$_o" "GOVERNANCE_UPDATE_CHECK=0 is set (no network) - nothing downloaded."
echo "  (c) the removed modes and the never-shipped flags are refused"
use_home "$BASE"; _before=$(treehash)
_o=$(upd --apply-at-session-end); _rc=$?
is "gov-update.sh --apply-at-session-end -> rc 2 (removed)" "$_rc" "2"
has "  it prints the usage" "$_o" "--apply [--force-live]"
hasnt "  the usage no longer lists it" "$_o" "--apply-at-session-end"
_o=$(upd --enable-auto-update); _rc=$?
is "gov-update.sh --enable-auto-update -> rc 2 (never existed)" "$_rc" "2"
is "  nothing changed" "$(treehash)" "$_before"
_NH="$SB/noauto-home"; rm -rf "$_NH"; mkdir -p "$_NH"
_o=$(HOME="$_NH" bash "$SRC/install.sh" --enable-auto-update </dev/null 2>&1); _rc=$?
is "install.sh --enable-auto-update -> rc 1" "$_rc" "1"
has "  Unknown option" "$_o" "Unknown option: --enable-auto-update"
is "  HOME untouched (nothing written)" "$(find "$_NH" -mindepth 1 2>/dev/null | grep -c .)" "0"
echo "  (d) nothing registers the updater"
is "the template has no SessionEnd key" "$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log("SessionEnd" in (s.hooks||{}) ? "present" : "absent")' "$SRC/bundle/settings-hooks.json")" "absent"
is "  and no event runs gov-update.sh" "$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));let n=0;for(const g of Object.values(s.hooks||{}))for(const x of g)for(const h of (x.hooks||[]))if(/gov-update\.sh/.test(h.command||""))n++;console.log(n)' "$SRC/bundle/settings-hooks.json")" "0"
use_home "$BASE"
_o=$(HOME="$H" bash "$H/.claude/governance-installer/verify.sh" </dev/null 2>&1); _rc=$?
_o=$(printf '%s' "$_o" | sed 's/\x1b\[[0-9;]*m//g')
is "verify.sh on the installed HOME passes" "$_rc" "0"
[ "$_rc" = "0" ] || printf '%s\n' "$_o" | grep '✗' | head -5
has "  including the inverted check" "$_o" "✓   no SessionEnd auto-update hook registered"
node -e 'const f=process.argv[1],fs=require("fs"),s=JSON.parse(fs.readFileSync(f,"utf8"));s.hooks=s.hooks||{};s.hooks.SessionEnd=[{hooks:[{type:"command",command:"~/.claude/hooks/governance/gov-update.sh --apply-at-session-end",timeout:10}]}];fs.writeFileSync(f,JSON.stringify(s))' "$H/.claude/settings.json"
_o2=$(HOME="$H" bash "$H/.claude/governance-installer/verify.sh" </dev/null 2>&1); _rc=$?
_o2=$(printf '%s' "$_o2" | sed 's/\x1b\[[0-9;]*m//g')
is "  control: an old SessionEnd registration fails verify.sh" "$([ "$_rc" != "0" ] && echo failed || echo passed)" "failed"
has "  on exactly that check" "$_o2" "✗   no SessionEnd auto-update hook registered"
echo "  (e) the deep verify's helpers check accepts the predicate's library (it runs on every real --fetch)"
# The suite skips the deep verify (GOV_UPDATE_SKIP_DEEP_VERIFY=1), so this step is run by hand here:
# gov-update.sh calls gov_auto_update_on / gov_local_env_get from consent-lib.sh, sourced by _common.sh.
_o=$(bash "$SRC/bundle/hooks/governance/governance-helpers-check.sh" "$SRC/bundle/hooks/governance" </dev/null 2>&1); _rc=$?
is "helpers-check on the release tree -> rc 0" "$_rc" "0"
has "  OK" "$_o" "helpers-check: OK"
_HC="$SB/hc-nolib"; rm -rf "$_HC"; cp -r "$SRC/bundle/hooks/governance" "$_HC"; rm -f "$_HC/consent-lib.sh"
_o=$(bash "$_HC/governance-helpers-check.sh" "$_HC" </dev/null 2>&1); _rc=$?
is "  control: without consent-lib.sh the same check fails" "$_rc" "1"
has "  naming the predicate" "$_o" "MISSING  gov-update.sh calls gov_auto_update_on"
echo "  (f) F3 (findings 7, 8): every --fetch / --apply refusal says why in the terminal, not only in the log"
mkdir -p "$SB/rel/nomani/claude-code-governance-9.9.9" "$SB/remote-nomani"
echo x > "$SB/rel/nomani/claude-code-governance-9.9.9/README.md"
(cd "$SB/rel/nomani" && tar -czf "$SB/remote-nomani/v9.9.9.tar.gz" claude-code-governance-9.9.9)
use_home "$BASE"
_o=$(URL=$(url_of "$SB/remote-nomani") upd --fetch 9.9.9); _rc=$?
is "--fetch 9.9.9 of an archive without RELEASE-MANIFEST -> rc 0 and HALT reason=manifest" "$_rc/$(halt_reason 9.9.9)" "0/manifest"
has "  it prints the halt (was silent: finding 7)" "$_o" "[GOVERNANCE UPDATE] v9.9.9 is halted (reason: manifest) - nothing was prepared or installed. Details: ~/.claude/logs/governance-update.log. To retry after the cause is fixed: bash ~/.claude/hooks/governance/gov-update.sh --clear-halt"
_o=$(URL=$(url_of "$SB/remote-nomani") upd --fetch 9.9.9)
has "  a --fetch of the halted version says so (not silent)" "$_o" "v9.9.9 is halted (manifest) - nothing downloaded. To retry after the cause is fixed"
_o=$(upd --fetch 2.0.0)
hasnt "  control: a good --fetch prints no halt" "$_o" "is halted"
is "  control: and stages" "$([ -f "$U_/READY" ] && echo staged || echo none)" "staged"
use_home "$BASE"; printf 'reason=signature at=x detail=y\n' > "$U_/HALT-2.0.0"
_o=$(upd --fetch 2.0.0)
has "  a signature halt names the re-pin, not --clear-halt alone" "$_o" "v2.0.0 is halted (signature) - nothing downloaded. The release is not signed by the key pinned on this machine: if the maintainer rotated the key, re-pin from a FRESH clone (README, \"Release signing key\"); --clear-halt alone will fail the same way."
hasnt "  and does not offer --clear-halt as the retry" "$_o" "To retry after the cause is fixed"
use_home "$BASE"
_o=$(upd --fetch banana)
has "--fetch banana: says it is not a version" "$_o" "'banana' is not a version - nothing downloaded."
_o=$(upd --fetch 1.0.0)
has "--fetch of an older version: says so" "$_o" "v1.0.0 is not newer than the installed v1.9.0 - nothing to do."
touch "$H/.claude/.governance-source"
_o=$(upd --fetch 2.0.0)
has "--fetch on the source machine: says so" "$_o" "this is the release source machine (marker ~/.claude/.governance-source) - it never installs releases; nothing downloaded."
use_home "$STAGED"; touch "$H/.claude/.governance-source"
_o=$(upd --apply --force-live)
has "--apply on the source machine: says so (was silent: finding 8)" "$_o" "this is the release source machine (marker ~/.claude/.governance-source) - it never installs releases; nothing applied."
use_home "$STAGED"
sleep 60 >/dev/null 2>&1 </dev/null & LIVE_PID=$!
mkdir -p "$U_/lock.d"; printf 'pid=%s since=x mode=fetch\n' "$LIVE_PID" > "$U_/lock.d/info"
_o=$(upd --apply --force-live)
kill "$LIVE_PID" 2>/dev/null; LIVE_PID=""
has "--apply with the lock held by a live pid: says so (was silent: finding 8)" "$_o" "[GOVERNANCE UPDATE] another update process holds the lock - nothing done; run this again in a minute."
is "  and applied nothing" "$(marker)" "1.9.0"
rm -rf "$U_/lock.d"
_o=$(upd --apply --force-live)
hasnt "  control: with the lock free the same --apply does not report a lock" "$_o" "holds the lock"
has "  control: and applies" "$_o" "Applied v2.0.0"
use_home "$STAGED"; printf 'reason=checksum at=x detail=y\n' > "$U_/HALT-2.0.0"
_o=$(upd --apply --force-live)
has "--apply of a halted version: says so and that READY was removed (finding 8)" "$_o" "v2.0.0 is halted (checksum) - its staged copy is not applied and READY was removed. To retry after the cause is fixed: bash ~/.claude/hooks/governance/gov-update.sh --clear-halt"
is "  READY removed, nothing applied" "$([ -f "$U_/READY" ] && echo kept || echo removed)/$(marker)" "removed/1.9.0"
use_home "$STAGED"; printf '2.0.0\n' > "$H/.claude/.governance-version"
_o=$(upd --apply --force-live)
has "--apply of the installed version: says the staged copy was removed" "$_o" "v2.0.0 is already installed - the staged copy was removed."
is "  and it was" "$([ -e "$U_/staged/v2.0.0" ] || [ -f "$U_/READY" ] && echo kept || echo removed)" "removed"
echo "  (g) F3 (finding 6, D.2): --status says a failed check FAILED, and shows push at session close"
use_home "$BASE"; printf '2.0.0\n' > "$H/.claude/logs/.governance-latest"; rm -f "$H/.claude/logs/.governance-version-status"
_o=$(upd --status)
has "--status after a good check: the plain line" "$_o" "  last check:       0 h ago (published: 2.0.0)"
hasnt "  and no FAILED" "$_o" "FAILED (HTTP"
printf '404\n' > "$H/.claude/logs/.governance-version-status"; touch "$H/.claude/logs/.governance-latest"
_o=$(upd --status)
has "--status after a failed check (404): says FAILED, with the last known version" "$_o" "  last check:       0 h ago - FAILED (HTTP 404); last known published: v2.0.0"
hasnt "  and not the plain line (finding 6)" "$_o" "h ago (published: 2.0.0)"
: > "$H/.claude/logs/.governance-latest"
has "  a failed check with no version ever seen: 'unknown', not 'vunknown'" "$(upd --status)" "FAILED (HTTP 404); last known published: unknown"
printf '2.0.0\n' > "$H/.claude/logs/.governance-latest"
has "--status on the baseline (installer default OFF): not called the user's choice" "$_o" "  push at close:    OFF (the default - you were not asked, recorded "
rm -f "$U_/close-push"
_o=$(upd --status)
has "--status with no close-push record: OFF (no choice recorded)" "$_o" "  push at close:    OFF (no choice recorded)"
printf 'enabled=1 terms_version=1 decided_at=2026-09-30T10:00:00Z framework_version=1.9.0 method=close-push-enable\n' > "$U_/close-push"
_o=$(upd --status)
has "--status with an ON record + accepted terms: ON (your choice, recorded <date>)" "$_o" "  push at close:    ON (your choice, recorded 2026-09-30)"
printf 'enabled=1 terms_version=0 decided_at=2026-09-30T10:00:00Z framework_version=1.9.0 method=close-push-enable\n' > "$U_/close-push"
_o=$(upd --status)
has "  an ON record made under older terms: OFF with the predicate's reason" "$_o" "  push at close:    OFF (terms changed to v1; accept them, then turn it on again in your own terminal: bash ~/.claude/hooks/governance/close-push.sh --enable)"
hasnt "  and never ON" "$_o" "push at close:    ON"
printf 'enabled=0 terms_version=1 decided_at=2026-09-29T10:00:00Z framework_version=1.9.0 method=declined\n' > "$U_/close-push"
_o=$(upd --status)
has "  a declined record: OFF (your choice, recorded <date>)" "$_o" "  push at close:    OFF (your choice, recorded 2026-09-29)"
echo "  (g2) round 3 B2: --status on the maintainer's machine (marker ~/.claude/.governance-source)"
CP_MAINT_ON='  push at close:    ON (maintainer machine: ~/.claude/.governance-source)'
touch "$H/.claude/.governance-source"
_o=$(upd --status)
has "marker + a declined record: ON (maintainer machine), the predicate's reason" "$_o" "$CP_MAINT_ON"
hasnt "  never 'your choice' there" "$_o" "your choice"
hasnt "  and not OFF" "$_o" "push at close:    OFF"
_o=$(HOME="$H" bash "$H/.claude/hooks/governance/close-push.sh" --disable </dev/null 2>&1)
has "  close-push.sh --disable on the maintainer's machine says push stays on" "$_o" "push at session close stays ON here"
is "  and it wrote the enabled=0 record" "$(gov_record_field "$U_/close-push" enabled)/$(gov_record_field "$U_/close-push" method)" "0/close-push-disable"
_o=$(upd --status)
has "marker, after close-push.sh --disable: still ON (maintainer machine)" "$_o" "$CP_MAINT_ON"
hasnt "  not 'your choice'" "$_o" "your choice"
rm -f "$U_/close-push"
_o=$(upd --status)
has "marker + no record: ON (maintainer machine)" "$_o" "$CP_MAINT_ON"
hasnt "  not 'no choice recorded'" "$_o" "no choice recorded"
_o=$(GOV_CLOSE_PUSH=0 upd --status)
has "marker + GOV_CLOSE_PUSH=0 + no record: OFF (paused by GOV_CLOSE_PUSH=0)" "$_o" "  push at close:    OFF (paused by GOV_CLOSE_PUSH=0)"
hasnt "  not 'no choice recorded'" "$_o" "no choice recorded"
printf 'GOV_CLOSE_PUSH=0\n' > "$H/.claude/.governance-local.env"
printf 'enabled=0 terms_version=1 decided_at=2026-09-29T10:00:00Z framework_version=1.9.0 method=declined\n' > "$U_/close-push"
_o=$(upd --status)
has "marker + GOV_CLOSE_PUSH=0 in .governance-local.env + a declined record: paused" "$_o" "  push at close:    OFF (paused by GOV_CLOSE_PUSH=0)"
hasnt "  not 'your choice'" "$_o" "your choice"
rm -f "$H/.claude/.governance-local.env" "$H/.claude/.governance-source"
_o=$(upd --status)
has "control: marker removed, the same declined record: OFF (your choice, recorded <date>)" "$_o" "  push at close:    OFF (your choice, recorded 2026-09-29)"
hasnt "  control: no maintainer line without the marker" "$_o" "maintainer machine"
mkdir -p "$H/.claude/.governance-source"
_o=$(upd --status)
hasnt "control: a DIRECTORY named like the marker is not the maintainer's machine" "$_o" "maintainer machine"
rmdir "$H/.claude/.governance-source"
printf 'enabled=0 terms_version=1 decided_at=2026-09-28T10:00:00Z framework_version=1.9.0 method=something-else\n' > "$U_/close-push"
_o=$(upd --status)
has "an OFF record with an unknown method: 'recorded off', as consent-lib.sh words it" "$_o" "  push at close:    OFF (recorded off on 2026-09-28)"
hasnt "  never 'your choice'" "$_o" "your choice"
printf 'enabled=1 terms_version=1 decided_at=2026-09-30T10:00:00Z framework_version=1.9.0 method=close-push-enable\n' > "$U_/close-push"
_o=$(GOV_CLOSE_PUSH=0 upd --status)
has "control: a client ON record + GOV_CLOSE_PUSH=0: OFF (paused by GOV_CLOSE_PUSH=0)" "$_o" "  push at close:    OFF (paused by GOV_CLOSE_PUSH=0)"
_o=$(upd --status)
has "control: the same client ON record, no pause: ON (your choice, recorded <date>)" "$_o" "  push at close:    ON (your choice, recorded 2026-09-30)"
hasnt "  control: no maintainer line on a client" "$_o" "maintainer machine"
echo "  (h) F3 (MINOR): the no-terminal --accept-terms line is addressed to the human"
use_home "$BASE"
_o=$(upd --accept-terms); _rc=$?
is "--accept-terms without a terminal -> rc 1" "$_rc" "1"
has "  it tells the human to run it in their own terminal" "$_o" "then run this yourself, in your own terminal: bash ~/.claude/hooks/governance/gov-update.sh --accept-terms  (or, for an installation without a terminal, GOV_ACCEPT_TERMS=1 set by you for that one command). Nothing was recorded."
hasnt "  the old agent-addressed line is gone" "$_o" "then re-run with GOV_ACCEPT_TERMS=1."
echo "  (i) F3 (finding 7): the session-start halted line names the re-pin for a signature halt, --clear-halt otherwise"
for _hr in signature checksum; do
  use_home "$BASE"; printf '2.0.0\n' > "$H/.claude/logs/.governance-latest"
  printf 'reason=%s at=x detail=y\n' "$_hr" > "$U_/HALT-2.0.0"
  _o=$(HOME="$H" GOV_NO_STDIN=0 bash "$H/.claude/hooks/governance/pre-session.sh" <<< '{"cwd":"/tmp","source":"startup"}' 2>&1)
  has "pre-session, halted ($_hr): the halted line" "$_o" "v2.0.0 was NOT installed (halted: $_hr)"
  if [ "$_hr" = "signature" ]; then
    has "  re-pin advice" "$_o" "if the maintainer rotated the key, re-pin from a FRESH clone (README, \"Release signing key\"); --clear-halt alone will fail the same way."
    hasnt "  no bare --clear-halt retry" "$_o" "To retry after the cause is fixed"
  else
    has "  --clear-halt advice" "$_o" "To retry after the cause is fixed: bash ~/.claude/hooks/governance/gov-update.sh --clear-halt"
    hasnt "  no re-pin advice" "$_o" "re-pin from a FRESH clone"
  fi
done
fi

if want T10; then
echo "(${SECONDS}s) [T10] locally modified installed file"
use_home "$STAGED"
printf '# my local patch\n' >> "$H/.claude/hooks/governance/pre-task.sh"
_before=$(treehash)
_o=$(upd --apply)
has "refused, naming the file" "$_o" "modified locally (hooks/governance/pre-task.sh)"
is "tree unchanged" "$(treehash)" "$_before"
_o=$(GOV_UPDATE_OVERWRITE_LOCAL=1 upd --apply)
has "GOV_UPDATE_OVERWRITE_LOCAL=1 applies" "$_o" "Applied v2.0.0"
_bk=$(ls -1d "$H/.claude/backups"/governance-update-* 2>/dev/null | tail -1)
is "the local patch is in the backup" "$(grep -c 'my local patch' "$_bk/hooks/governance/pre-task.sh" 2>/dev/null)" "1"
echo "  (CRLF: a baseline written from a CRLF checkout must not read as local edits)"
_crlf="$SB/crlf-tree"; rm -rf "$_crlf"; cp -r "$SB/rel/base/claude-code-governance-1.9.0" "$_crlf"
find "$_crlf/bundle" -name '*.md' | while read -r f; do sed -i 's/$/\r/' "$f"; done
is "precondition: the CRLF tree really has CRLF" "$(grep -rl $'\r' "$_crlf/bundle/docs" | grep -c .)" "$(ls "$_crlf/bundle/docs"/*.md | grep -c .)"
rm -rf "$H"; mkdir -p "$H"; nonce_home "$H"
HOME="$H" bash "$_crlf/install.sh" --accept-terms --no-verify >/dev/null 2>&1 </dev/null
upd --fetch 2.0.0
_o=$(upd --apply)
has "CRLF-installed machine updates without a false local-edit refusal" "$_o" "Applied v2.0.0"
fi

if want T11; then
echo "(${SECONDS}s) [T11] terms bump: HELD-TERMS - none of the release's code runs before --accept-terms"
# The marker: the first line of the one release script the deep verify EXECUTES (check-no-pii.sh
# --selftest, gov-update.sh upd_deep_verify) writes a file, then short-circuits the (slow) selftest
# with the given rc. `bash -n` / `node --check` at fetch parse it but never run it.
plant_code() {  # plant_code <tree> <marker name> <selftest rc>
  local f="$1/bundle/hooks/governance/check-no-pii.sh"
  { head -1 "$f"; printf 'touch "%s/%s"; [ "${1:-}" = "--selftest" ] && exit %s\n' "$SB" "$2" "$3"; tail -n +2 "$f"; } > "$f.new" \
    && mv -f "$f.new" "$f" && chmod +x "$f"
}
pre_terms() { pre_t1 "$1"; printf '2\n' > "$1/bundle/TERMS-VERSION"; sed -i 's/^Terms version: 1$/Terms version: 2/' "$1/NOTICE-AUTO-UPDATE.md"; plant_code "$1" ran-2.0.0-code 0; }
pre_terms_bad() { pre_terms "$1"; plant_code "$1" ran-bad-code 1; }
pre_code_v1() { pre_t1 "$1"; plant_code "$1" ran-v1-code 0; }
mkrel terms 2.0.0 k1 pre_terms >/dev/null
mkrel termsbad 2.0.0 k1 pre_terms_bad >/dev/null
mkrel codev1 2.0.0 k1 pre_code_v1 >/dev/null
is "precondition: the fixture's scanner carries the marker line" "$(grep -c 'ran-2.0.0-code' "$SB/rel/terms/claude-code-governance-2.0.0/bundle/hooks/governance/check-no-pii.sh")" "1"
U_="$H/.claude/.governance-update"
# insthash: treehash without the terms record - accepting the terms legitimately changes that one
# file, and "nothing installed" is a claim about everything else.
insthash() {
  (cd "$H/.claude" && {
     find . -type d ! -path './logs*' ! -path './backups*' ! -path './.governance-update*' | LC_ALL=C sort
     find . -type f ! -path './logs/*' ! -path './backups/*' ! -path './.governance-update/*' \
       | LC_ALL=C sort | tr '\n' '\0' | xargs -0 sha256sum 2>/dev/null
     for f in installed.hashes installed.manifest allowed_signers settings-hooks.installed.json install-mode; do
       [ -f ".governance-update/$f" ] && sha256sum ".governance-update/$f"
     done
   }) | sha256sum | cut -c1-16
}
HELD_LINE="[GOVERNANCE UPDATE] v2.0.0 is waiting: its terms changed (v2) and none of its code has run. For the human: read ~/.claude/.governance-update/staged/v2.0.0/NOTICE-AUTO-UPDATE.md, then run in your own terminal: bash ~/.claude/hooks/governance/gov-update.sh --accept-terms   (it refuses when it detects an AI-agent session - a safeguard, not a guarantee)"
echo "  (a) --fetch with the REAL deep verify switched on: held, nothing of v2.0.0 ran"
use_home "$BASE"; URL=$(url_of "$SB/remote-terms"); rm -f "$SB/ran-2.0.0-code"
_before=$(treehash); _ibefore=$(insthash)
_o=$(DEEP_SKIP=0 upd --fetch 2.0.0)
is "  the D.2 terms-held line, word for word" "$(printf '%s\n' "$_o" | grep -cxF "$HELD_LINE")" "1"
is "  HELD-TERMS-2.0.0 written" "$(gov_record_field "$U_/HELD-TERMS-2.0.0" terms_version)/$([ -n "$(gov_record_field "$U_/HELD-TERMS-2.0.0" staged_at)" ] && echo dated || echo undated)" "2/dated"
is "  READY absent" "$([ -f "$U_/READY" ] && echo present || echo absent)" "absent"
is "  staged/v2.0.0 present (for the human to read)" "$([ -f "$U_/staged/v2.0.0/NOTICE-AUTO-UPDATE.md" ] && [ -f "$U_/staged/v2.0.0/RELEASE-MANIFEST" ] && echo present || echo absent)" "present"
is "  the release's code did NOT run (marker absent)" "$([ -e "$SB/ran-2.0.0-code" ] && echo ran || echo absent)" "absent"
is "  tree unchanged" "$(treehash)" "$_before"
has "  the log says so" "$(cat "$H/.claude/logs/governance-update.log" 2>/dev/null)" "held: terms v2 not accepted; nothing of v2.0.0 ran"
_o=$(upd --status)
has "  --status names it" "$_o" "held (terms):     v2.0.0 - terms v2 not accepted"
_o=$(upd --apply)
has "  --apply: held with the terms line" "$_o" "its terms changed (v2)"
hasnt "  --apply: nothing applied" "$_o" "Applied"
_o=$(upd --apply --force-live)
hasnt "  --apply --force-live: nothing applied either (READY is the only trigger)" "$_o" "Applied"
upd --apply-if-ready >/dev/null
is "  tree unchanged, marker 1.9.0, still no code run" "$([ "$(treehash)" = "$_before" ] && echo same || echo changed)/$(marker)/$([ -e "$SB/ran-2.0.0-code" ] && echo ran || echo absent)" "same/1.9.0/absent"
upd --clear-halt >/dev/null
is "  --clear-halt leaves HELD alone" "$([ -f "$U_/HELD-TERMS-2.0.0" ] && echo kept || echo gone)" "kept"
_o=$(DEEP_SKIP=0 upd --fetch 2.0.0)
is "  a second --fetch re-prints the line and runs nothing" "$(printf '%s\n' "$_o" | grep -cxF "$HELD_LINE")/$([ -e "$SB/ran-2.0.0-code" ] && echo ran || echo absent)" "1/absent"
echo "  (b) --accept-terms without a terminal and without GOV_ACCEPT_TERMS: nothing"
_o=$(HOME="$H" GOV_UPDATE_SKIP_DEEP_VERIFY=0 bash "$H/.claude/hooks/governance/gov-update.sh" --accept-terms </dev/null 2>&1); _rc=$?
is "  rc 1" "$_rc" "1"
has "  it names the staged release's NOTICE" "$_o" "staged/v2.0.0/NOTICE-AUTO-UPDATE.md"
hasnt "  terms v2 NOT recorded" "$(cat "$U_/terms-accepted")" "terms_version=2"
is "  still held, no READY, no code run" "$([ -f "$U_/HELD-TERMS-2.0.0" ] && echo held || echo gone)/$([ -f "$U_/READY" ] && echo ready || echo none)/$([ -e "$SB/ran-2.0.0-code" ] && echo ran || echo absent)" "held/none/absent"
echo "  (b2) --accept-terms with GOV_ACCEPT_TERMS=1 inside an agent session, no nonce: refused (C3)"
mv "$H/.governance-consent-selftest" "$SB/t11-nonce"
_o=$(HOME="$H" CLAUDECODE=1 GOV_ACCEPT_TERMS=1 GOV_UPDATE_SKIP_DEEP_VERIFY=0 bash "$H/.claude/hooks/governance/gov-update.sh" --accept-terms </dev/null 2>&1); _rc=$?
mv "$SB/t11-nonce" "$H/.governance-consent-selftest"
is "  rc 1" "$_rc" "1"
has "  the A.2 refusal line (refused on detection, D1/L1)" "$_o" "[GOVERNANCE] Refused: this needs your own decision, typed in your own terminal, and an AI-agent"
hasnt "  the refusal claims no guarantee: no 'cannot accept' (L1)" "$_o" "cannot accept"
hasnt "  terms v2 NOT recorded" "$(cat "$U_/terms-accepted")" "terms_version=2"
is "  still held, no READY, no code run" "$([ -f "$U_/HELD-TERMS-2.0.0" ] && echo held || echo gone)/$([ -f "$U_/READY" ] && echo ready || echo none)/$([ -e "$SB/ran-2.0.0-code" ] && echo ran || echo absent)" "held/none/absent"
echo "  (c) --accept-terms with GOV_ACCEPT_TERMS=1 (+ nonce): recorded, THEN the deep verify runs, THEN READY"
_o=$(HOME="$H" GOV_ACCEPT_TERMS=1 GOV_UPDATE_SKIP_DEEP_VERIFY=0 bash "$H/.claude/hooks/governance/gov-update.sh" --accept-terms </dev/null 2>&1); _rc=$?
is "  rc 0" "$_rc" "0"
has "  --accept-terms prints the summary (2026-09-30 text, item 4)" "$_o" "AUTOMATIC UPDATES are not part of this version"
hasnt "  --accept-terms prints no retired summary line" "$_o" "updates ITSELF"
has "terms v2 recorded" "$(cat "$U_/terms-accepted")" "terms_version=2"
_sn="$U_/staged/v2.0.0/NOTICE-AUTO-UPDATE.md"
is "  notice_sha256 = the STAGED release's NOTICE (the one whose summary was printed), CR-stripped" \
   "$(gov_record_field "$U_/terms-accepted" notice_sha256)" "$(tr -d '\r' < "$_sn" | sha256sum | cut -d' ' -f1)"
is "  shown_sha256 = the summary block extracted with the same sed" \
   "$(gov_record_field "$U_/terms-accepted" shown_sha256)" \
   "$(sed -n '/<!-- terms-summary:begin -->/,/<!-- terms-summary:end -->/{/<!--/d;p;}' "$_sn" | tr -d '\r' | sha256sum | cut -d' ' -f1)"
is "  control: the staged NOTICE differs from the installer copy's, so the hash above names the right file" \
   "$([ "$(tr -d '\r' < "$_sn" | sha256sum | cut -d' ' -f1)" != "$(tr -d '\r' < "$H/.claude/governance-installer/NOTICE-AUTO-UPDATE.md" | sha256sum | cut -d' ' -f1)" ] && echo differ || echo same)" "differ"
is "  the deep verify ran now (marker present)" "$([ -e "$SB/ran-2.0.0-code" ] && echo ran || echo absent)" "ran"
has "  it says v2.0.0 is prepared" "$_o" "[GOVERNANCE UPDATE] v2.0.0 is now prepared; to install: close every session, then --apply --force-live"
is "  READY present, HELD gone" "$([ -f "$U_/READY" ] && echo ready || echo none)/$([ -f "$U_/HELD-TERMS-2.0.0" ] && echo held || echo gone)" "ready/gone"
is "  still nothing installed" "$(insthash)/$(marker)" "$_ibefore/1.9.0"
upd --apply-if-ready >/dev/null
is "  --apply-if-ready still does not apply (no automatic update)" "$(marker)" "1.9.0"
_o=$(upd --apply --force-live)
has "after acceptance, --apply --force-live applies" "$_o" "Applied v2.0.0"
is "  marker 2.0.0" "$(marker)" "2.0.0"
# Verify round 4 #2: a TERMS BUMP applied by hand moves both terms sources together, so the predicate
# reads one clear version (v2) - not "unclear", which would keep push off on every client for ever.
is "  the terms copy moved with the manifest: TERMS-VERSION 2 / installed.manifest terms_version 2" \
   "$(tr -d '[:space:]' < "$H/.claude/hooks/governance-terms/TERMS-VERSION" 2>/dev/null)/$(relman_get "$U_/installed.manifest" terms_version)" "2/2"
is "  ... the NOTICE copy is v2.0.0's (Terms version: 2)" "$(grep -cx 'Terms version: 2' "$H/.claude/hooks/governance-terms/NOTICE-AUTO-UPDATE.md" 2>/dev/null)" "1"
is "  ... and gov_installed_terms_version says 2" "$(HOME="$H" bash -c '. "$1" && gov_installed_terms_version' _ "$H/.claude/hooks/governance/consent-lib.sh")" "2"
echo "  (d) the terms accepted some other way: the next --fetch prepares the held release (the retry path)"
use_home "$BASE"; rm -f "$SB/ran-2.0.0-code"
DEEP_SKIP=0 upd --fetch 2.0.0 >/dev/null
printf 'terms_version=2 accepted_at=2026-01-01T00:00:00Z framework_version=1.9.0 method=env\n' > "$U_/terms-accepted"
_o=$(DEEP_SKIP=0 upd --fetch 2.0.0)
has "  prepared" "$_o" "v2.0.0 is now prepared"
is "  READY, HELD gone, the code ran only now" "$([ -f "$U_/READY" ] && echo ready || echo none)/$([ -f "$U_/HELD-TERMS-2.0.0" ] && echo held || echo gone)/$([ -e "$SB/ran-2.0.0-code" ] && echo ran || echo absent)" "ready/gone/ran"
echo "  (e) the deep verify fails after acceptance: halted as deep-verify, nothing prepared"
use_home "$BASE"; URL=$(url_of "$SB/remote-termsbad"); rm -f "$SB/ran-bad-code"
DEEP_SKIP=0 upd --fetch 2.0.0 >/dev/null
is "  precondition: held, its code not run" "$([ -f "$U_/HELD-TERMS-2.0.0" ] && echo held || echo gone)/$([ -e "$SB/ran-bad-code" ] && echo ran || echo absent)" "held/absent"
_before=$(insthash)
_o=$(HOME="$H" GOV_ACCEPT_TERMS=1 GOV_UPDATE_SKIP_DEEP_VERIFY=0 bash "$H/.claude/hooks/governance/gov-update.sh" --accept-terms </dev/null 2>&1); _rc=$?
is "  rc 1" "$_rc" "1"
has "  it says so" "$_o" "v2.0.0 was NOT prepared: its self-check failed (deep-verify)"
is "  HALT-2.0.0 reason deep-verify" "$(halt_reason 2.0.0)" "deep-verify"
is "  no READY, no HELD, no staged tree, tree unchanged" "$([ -f "$U_/READY" ] && echo ready || echo none)/$([ -f "$U_/HELD-TERMS-2.0.0" ] && echo held || echo gone)/$([ -d "$U_/staged/v2.0.0" ] && echo staged || echo gone)/$([ "$(insthash)" = "$_before" ] && echo same || echo changed)" "none/gone/gone/same"
echo "  (f) control: terms unchanged (v1) - the same marker runs AT FETCH (the deep verify is not skipped by the hold logic)"
use_home "$BASE"; URL=$(url_of "$SB/remote-codev1"); rm -f "$SB/ran-v1-code"
_o=$(DEEP_SKIP=0 upd --fetch 2.0.0)
is "  READY, no HELD, the code ran" "$([ -f "$U_/READY" ] && echo ready || echo none)/$(ls "$U_"/HELD-TERMS-* 2>/dev/null | grep -c .)/$([ -e "$SB/ran-v1-code" ] && echo ran || echo absent)" "ready/0/ran"
hasnt "  no terms-held line" "$_o" "is waiting: its terms changed"
echo "  (g) a manual install.sh --force supersedes a HELD release (no stale HELD-TERMS left behind)"
use_home "$BASE"; URL=$(url_of "$SB/remote-terms")
upd --fetch 2.0.0 >/dev/null
is "  precondition: held" "$([ -f "$U_/HELD-TERMS-2.0.0" ] && echo held || echo gone)" "held"
_o=$(HOME="$H" bash "$SB/rel/base/claude-code-governance-1.9.0/install.sh" --accept-terms --no-verify --force </dev/null 2>&1); _rc=$?
is "  install.sh --force exits 0" "$_rc" "0"
has "  it says it cleared the staged update" "$_o" "Cleared a staged or interrupted update (a release you fetched, or an --apply that was cut off): this manual install supersedes it."
hasnt "  ... not calling it automatic (there is none)" "$_o" "staged automatic update"
is "  HELD-TERMS and the staged tree are gone" "$([ -f "$U_/HELD-TERMS-2.0.0" ] && echo held || echo gone)/$([ -d "$U_/staged/v2.0.0" ] && echo staged || echo gone)" "gone/gone"
use_home "$BASE"; _cpb=$(sha256sum < "$U_/close-push")
_o=$(HOME="$H" bash "$SB/rel/base/claude-code-governance-1.9.0/install.sh" --accept-terms --no-verify --force </dev/null 2>&1)
hasnt "  control: nothing staged or held -> no 'Cleared' line" "$_o" "Cleared a staged or interrupted"
has "  a --force re-install keeps the push choice and says so (never re-asked)" "$_o" "Push at session close: OFF (the default - you were not asked, recorded "
hasnt "  ... and does not call the installer's default (BASE: no terminal) the user's choice" "$_o" "Push at session close: OFF (your choice"
is "  the close-push record is byte for byte unchanged" "$(sha256sum < "$U_/close-push")" "$_cpb"
hasnt "  and does not re-record it" "$_o" "Push at session close: OFF recorded"
URL=$(url_of "$SB/remote-good")
fi

if want T13; then
echo "(${SECONDS}s) [T13] killed mid-apply"
mkdir -p "$SB/stubmv"
cat > "$SB/stubmv/mv" <<STUBMV
#!/usr/bin/env bash
case "\$*" in
  *"/.governance-update/prep."*)
    n=\$(cat "$SB/mvcount" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$SB/mvcount"
    if [ "\$n" -ge 6 ]; then echo \$\$ > "$SB/stub-sleeper.pid"; exec sleep 600; fi ;;
esac
exec "$REAL_MV" "\$@"
STUBMV
chmod +x "$SB/stubmv/mv"
use_home "$STAGED"; _before=$(treehash); rm -f "$SB/mvcount"
HOME="$H" GOV_UPDATE_SKIP_DEEP_VERIFY=1 GOV_SESSION_SOURCE=startup GOV_SESSION_ID=test-self PATH="$SB/stubmv:$PATH" \
  bash "$H/.claude/hooks/governance/gov-update.sh" --apply </dev/null >/dev/null 2>&1 &
_ap=$!
_w=0
# NOT `grep -c ... || echo 0`: grep -c prints 0 AND exits 1, so that yields "0 0" and the test
# errored out of the loop at once, killing the apply before its first swap (MEASURED).
_nswap() { local n; n=$(grep -c '^swapped ' "$H/.claude/.governance-update/APPLYING" 2>/dev/null); echo "${n:-0}"; }
while [ "$(_nswap)" -lt 5 ] && [ "$_w" -lt 240 ]; do sleep 0.5; _w=$((_w + 1)); done
is "precondition: the apply reached 5 swapped files" "$(grep -c '^swapped ' "$H/.claude/.governance-update/APPLYING" 2>/dev/null)" "5"
kill -9 "$_ap" 2>/dev/null; wait "$_ap" 2>/dev/null
sleep 1
is "precondition: the apply process is dead" "$(kill -0 "$_ap" 2>/dev/null && echo alive || echo dead)" "dead"
# Recovered through --apply-if-ready, the entry point of pre-session's detached recovery child:
# restoring a half-applied tree is not an update, so the absence of any automatic update must not
# leave it in place (review round 2).
_o=$(upd --apply-if-ready)
has "the recovery child rolls back and says so" "$_o" "could NOT be applied (interrupted)"
is "tree byte-identical to before the apply" "$(treehash)" "$_before"
# An interruption says nothing about the release (the machine was shut down, the process killed):
# kept for a retry by hand, not halted, until the third time.
is "first interruption: NOT halted" "$(halt_reason 2.0.0)" ""
is "  READY kept for a retry by hand" "$([ -f "$H/.claude/.governance-update/READY" ] && echo kept || echo gone)" "kept"
# Nothing retries on its own in this version, so the line names the hand command (A16).
has "  and it says so - with the hand command" "$_o" "retry it by hand: bash ~/.claude/hooks/governance/gov-update.sh --apply (failed attempt 1 of 3)"
hasnt "  no automatic retry promised" "$_o" "tried again when a Claude Code session next ends"
hasnt "  the recovery child did not go on to apply" "$_o" "Applied v2.0.0"
is "  marker still 1.9.0" "$(marker)" "1.9.0"
is "the journal is gone" "$([ -f "$H/.claude/.governance-update/APPLYING" ] && echo present || echo gone)" "gone"
_o=$(upd --apply-if-ready)
is "  a second pass of the recovery entry point does NOT retry it (no automatic apply)" "$(marker)" "1.9.0"
_o=$(upd --apply)
has "  the retry BY HAND applies it" "$_o" "Applied v2.0.0"
is "  the retry counter is cleared on success" "$(ls "$H/.claude/.governance-update"/retry-* 2>/dev/null | wc -l | tr -d ' ')" "0"
[ -f "$SB/stub-sleeper.pid" ] && kill "$(cat "$SB/stub-sleeper.pid")" 2>/dev/null
echo "  (the THIRD interruption halts the version)"
use_home "$STAGED"; rm -f "$SB/mvcount"; printf '2\n' > "$H/.claude/.governance-update/retry-2.0.0"
HOME="$H" GOV_UPDATE_SKIP_DEEP_VERIFY=1 GOV_SESSION_SOURCE=startup GOV_SESSION_ID=test-self PATH="$SB/stubmv:$PATH" \
  bash "$H/.claude/hooks/governance/gov-update.sh" --apply </dev/null >/dev/null 2>&1 &
_ap=$!; _w=0
while [ "$(_nswap)" -lt 5 ] && [ "$_w" -lt 240 ]; do sleep 0.5; _w=$((_w + 1)); done
kill -9 "$_ap" 2>/dev/null; wait "$_ap" 2>/dev/null; sleep 1
[ -f "$SB/stub-sleeper.pid" ] && kill "$(cat "$SB/stub-sleeper.pid")" 2>/dev/null
_o=$(upd --apply-if-ready)
is "third interruption: HALT reason=interrupted" "$(halt_reason 2.0.0)" "interrupted"
has "  and it says it will not be retried" "$_o" "will not be retried"
is "  READY removed" "$([ -f "$H/.claude/.governance-update/READY" ] && echo kept || echo gone)" "gone"
echo "  (the apply process is still ALIVE: nothing may be touched)"
t13_alive() {  # the alive scenario with $1 = the gov-update.sh to use; output -> $SB/t13.out
  # NOT called inside $( ): the tree hash taken here must reach the caller, and a backgrounded
  # sleep holding the substitution's pipe would make $( ) wait for it.
  use_home "$STAGED"
  sleep 60 >/dev/null 2>&1 </dev/null & LIVE_PID=$!
  printf 'version=2.0.0\nfrom=1.9.0\nstarted=x\nbackup=%s/none\npid=%s\nbackup-complete files=0\n' "$SB" "$LIVE_PID" > "$H/.claude/.governance-update/APPLYING"
  mkdir -p "$H/.claude/.governance-update/lock.d"
  printf 'pid=%s since=x mode=apply\n' "$LIVE_PID" > "$H/.claude/.governance-update/lock.d/info"
  T13_BEFORE=$(treehash)
  UPD_SCRIPT="$1" upd --apply-if-ready > "$SB/t13.out"
  kill "$LIVE_PID" 2>/dev/null; LIVE_PID=""
}
t13_alive "$H/.claude/hooks/governance/gov-update.sh"; _o=$(cat "$SB/t13.out")
has "a live apply is reported, not rolled back" "$_o" "an apply is still running (pid"
is "tree unchanged" "$(treehash)" "$T13_BEFORE"
is "the journal is kept for the live process" "$([ -f "$H/.claude/.governance-update/APPLYING" ] && echo kept || echo removed)" "kept"
fi

if want T14; then
echo "(${SECONDS}s) [T14] another live session defers the apply"
mk_session() { mkdir -p "$H/.claude/logs/sessions/$1"; touch -d "$2 seconds ago" "$H/.claude/logs/sessions/$1/f" "$H/.claude/logs/sessions/$1"; }
use_home "$STAGED"; mk_session other 60; _before=$(treehash)
_o=$(upd --apply)
has "deferred while another session is live" "$_o" "deferred 1 time(s)"
is "deferrals=1" "$(cat "$H/.claude/.governance-update/deferrals")" "1"
is "tree unchanged" "$(treehash)" "$_before"
upd --apply >/dev/null; _o=$(upd --apply)
has "from the 3rd deferral the sessions are named" "$_o" "Live: other"
_o=$(upd --apply --force-live)
has "--apply --force-live applies" "$_o" "Applied v2.0.0"
use_home "$STAGED"; mk_session idle 700
_o=$(upd --apply)
has "a session idle for 700 s does not count" "$_o" "Applied v2.0.0"
use_home "$STAGED"; mk_session test-self 5
_o=$(SID=test-self upd --apply)
has "the CURRENT session's own dir does not count" "$_o" "Applied v2.0.0"
use_home "$STAGED"; mk_session other 60; touch "$H/.claude/logs/sessions/other/.gov-session-closed"
_o=$(upd --apply)
has "a closed session does not count" "$_o" "Applied v2.0.0"
fi

if want T14b; then
echo "(${SECONDS}s) [T14b] --apply-if-ready (the recovery child's entry) never applies, whatever the session source (2026-09-30)"
for s in compact clear recovery session-end startup resume ""; do
  use_home "$STAGED"; _before=$(treehash)
  SRCKIND="$s" upd --apply-if-ready >/dev/null
  is "source=${s:-<absent>}: not applied" "$(treehash)" "$_before"
  is "source=${s:-<absent>}: READY kept" "$([ -f "$H/.claude/.governance-update/READY" ] && echo kept || echo gone)" "kept"
done
use_home "$STAGED"
_o=$(SRCKIND=compact upd --apply)
has "control: the human --apply ignores the session source and applies" "$_o" "Applied v2.0.0"
fi

if want T15; then
echo "(${SECONDS}s) [T15] no ssh-keygen -Y on this machine"
mkdir -p "$SB/stubssh"
printf '#!/bin/sh\necho "ssh-keygen: illegal option -- Y" >&2\nexit 1\n' > "$SB/stubssh/ssh-keygen"; chmod +x "$SB/stubssh/ssh-keygen"
use_home "$BASE"; _before=$(treehash)
PATH="$SB/stubssh:$PATH" upd --fetch 2.0.0
is "HALT reason=no-ssh-keygen-Y" "$(halt_reason 2.0.0)" "no-ssh-keygen-Y"
is "never falls back to unverified (no READY)" "$([ -f "$H/.claude/.governance-update/READY" ] && echo staged || echo refused)" "refused"
is "tree unchanged" "$(treehash)" "$_before"
fi

if want T16; then
echo "(${SECONDS}s) [T16] path traversal in a SIGNED install map"
MAP_EXTRA="bundle/hooks/governance/_common.sh -> ../evil.sh  core" mkrel trav 2.0.0 k1 pre_t1 >/dev/null
use_home "$BASE"; URL=$(url_of "$SB/remote-trav")
upd --fetch 2.0.0
is "HALT reason=install-map" "$(halt_reason 2.0.0)" "install-map"
is "nothing written outside ~/.claude" "$([ -e "$H/evil.sh" ] && echo written || echo clean)" "clean"
URL=$(url_of "$SB/remote-good")
fi

if want T17; then
echo "(${SECONDS}s) [T17] key rotation"
pre_rot1() { pre_t1 "$1"; { signer_line k1; signer_line k2; } > "$1/bundle/release/allowed_signers"; }
pre_rot2() { pre_rot1 "$1"; }
mkrel rot1 2.0.0 k1 pre_rot1 >/dev/null
mkrel rot2 2.0.1 k2 pre_rot2 >/dev/null
use_home "$BASE"; URL=$(url_of "$SB/remote-rot1")
upd --fetch 2.0.0; _o=$(upd --apply)
has "release N (old+new signers, signed by old) applies" "$_o" "Applied v2.0.0"
is "the pinned file now carries the new key" "$(grep -c "$(cut -d' ' -f2 "$SB/keys/k2.pub")" "$H/.claude/.governance-update/allowed_signers")" "1"
URL=$(url_of "$SB/remote-rot2")
upd --fetch 2.0.1; _o=$(upd --apply)
has "release N+1 signed by the NEW key applies" "$_o" "Applied v2.0.1"
mkrel rot0 2.0.0 k2 pre_t1 >/dev/null
use_home "$BASE"; URL=$(url_of "$SB/remote-rot0")
upd --fetch 2.0.0
is "a release signed by the new key BEFORE rotation is refused" "$(halt_reason 2.0.0)" "signature"
URL=$(url_of "$SB/remote-good")
fi

if want T18; then
echo "(${SECONDS}s) [T18] settings-merge.js"
M="$GOV_DIR/settings-merge.js"; T="$SB/t18"; rm -rf "$T"; mkdir -p "$T"
cat > "$T/old.json" <<'J'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/.claude/hooks/governance/end-session.sh"},{"type":"command","command":"echo '[MEMORY MAINTENANCE] old text'"},{"type":"command","command":"~/.claude/hooks/governance/retired-hook.sh"}]}]}}
J
cat > "$T/new.json" <<'J'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/.claude/hooks/governance/end-session.sh","timeout":30},{"type":"command","command":"echo '[MEMORY MAINTENANCE] new text'"}]}],"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/governance/pre-session.sh","timeout":120}]}]},"effortLevel":"max"}
J
cat > "$T/settings.json" <<'J'
{"permissions":{"allow":["Bash(ls:*)"]},"env":{"X":"1"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/.claude/hooks/governance/end-session.sh"},{"type":"command","command":"echo '[MEMORY MAINTENANCE] old text'"},{"type":"command","command":"~/.claude/hooks/governance/retired-hook.sh"},{"type":"command","command":"~/my-own-stop-hook.sh"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/mine.sh"}]}]}}
J
_o=$(node "$M" --template "$T/new.json" --settings "$T/settings.json" --installed "$T/old.json" 2>&1)
is "merge reports merged" "$_o" "merged"
_cmds=$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));for(const[e,g]of Object.entries(s.hooks))for(const x of g)for(const h of x.hooks)console.log(e+"|"+h.command)' "$T/settings.json")
has "a user Stop hook survives" "$_cmds" "Stop|~/my-own-stop-hook.sh"
has "a user PreToolUse group survives" "$_cmds" "PreToolUse|~/mine.sh"
is "the MEMORY MAINTENANCE entry is replaced, not duplicated" "$(printf '%s\n' "$_cmds" | grep -c 'MEMORY MAINTENANCE')" "1"
has "  ... by the new text" "$_cmds" "new text"
hasnt "a governance entry the new template dropped disappears" "$_cmds" "retired-hook.sh"
has "a new governance event is added" "$_cmds" "SessionStart|~/.claude/hooks/governance/pre-session.sh"
is "permissions untouched" "$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify(s.permissions)+JSON.stringify(s.env))' "$T/settings.json")" '{"allow":["Bash(ls:*)"]}{"X":"1"}'
# pre-session.sh is capped at 10 s by the merge itself (2026-09-26): the template above says 120.
_pst() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));for(const g of s.hooks.SessionStart||[])for(const h of g.hooks)if(/pre-session\.sh/.test(h.command))console.log(h.timeout)' "$1"; }
is "a template's pre-session timeout 120 is clamped to 10" "$(_pst "$T/settings.json")" "10"
sed 's/"timeout":120/"timeout":7/' "$T/new.json" > "$T/new7.json"
node "$M" --template "$T/new7.json" --settings "$T/settings.json" --installed "$T/new.json" >/dev/null 2>&1
is "  control: a timeout already under the cap (7) is kept" "$(_pst "$T/settings.json")" "7"
node "$M" --template "$T/new.json" --settings "$T/settings.json" --installed "$T/new7.json" >/dev/null 2>&1
# SessionEnd (2026-09-30): a machine that installed the 2.0.0-dev template (SessionEnd trigger
# registered, pre-session at 120) re-installs the real template, which has NO SessionEnd: the
# governance trigger is removed, a user's own SessionEnd hook survives byte for byte.
cat > "$T/tpl-end.json" <<'J'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/governance/pre-session.sh","timeout":120}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"~/.claude/hooks/governance/gov-update.sh --apply-at-session-end","timeout":10}]}]}}
J
_s_end='{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"~/.claude/hooks/governance/gov-update.sh --apply-at-session-end","timeout":10},{"type":"command","command":"~/my-end.sh","timeout":3,"x":"keep me"}]}],"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/governance/pre-session.sh","timeout":120}]}]}}'
_se_of() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const e=((s.hooks||{}).SessionEnd||[]).flatMap(g=>g.hooks);console.log(e.map(h=>JSON.stringify(h)).join("\n"))' "$1"; }
printf '%s\n' "$_s_end" > "$T/s-end.json"
is "  precondition: the old registration is there" "$(_se_of "$T/s-end.json" | grep -c 'gov-update.sh --apply-at-session-end')" "1"
node "$M" --template "$SRC/bundle/settings-hooks.json" --settings "$T/s-end.json" --installed "$T/tpl-end.json" >/dev/null 2>&1
_se=$(_se_of "$T/s-end.json")
hasnt "SessionEnd: the old governance trigger is removed (--installed names it)" "$_se" "gov-update.sh"
has "  the user's own SessionEnd hook survives byte for byte" "$_se" '{"type":"command","command":"~/my-end.sh","timeout":3,"x":"keep me"}'
is "  and pre-session drops from 120 to 10 in the same merge" "$(_pst "$T/s-end.json")" "10"
printf '%s\n' "$_s_end" > "$T/s-end2.json"
node "$M" --template "$SRC/bundle/settings-hooks.json" --settings "$T/s-end2.json" >/dev/null 2>&1
_se=$(_se_of "$T/s-end2.json")
hasnt "  also without --installed (a hooks/governance/ command is always the framework's)" "$_se" "gov-update.sh"
has "  and the user's hook still survives" "$_se" '"command":"~/my-end.sh"'
printf '%s\n' "$_s_end" > "$T/s-end3.json"
node "$M" --template "$T/tpl-end.json" --settings "$T/s-end3.json" >/dev/null 2>&1
is "  control: a template that still HAS the trigger keeps exactly one (so the removal above is the template's doing)" "$(_se_of "$T/s-end3.json" | grep -c 'gov-update.sh --apply-at-session-end')" "1"
touch -d '1 hour ago' "$T/settings.json"; _m1=$(stat -c %Y "$T/settings.json" 2>/dev/null || stat -f %m "$T/settings.json")
_o=$(node "$M" --template "$T/new.json" --settings "$T/settings.json" --installed "$T/new.json" 2>&1)
_m2=$(stat -c %Y "$T/settings.json" 2>/dev/null || stat -f %m "$T/settings.json")
is "identical result -> reported unchanged" "$_o" "unchanged"
is "identical result -> file not rewritten (mtime kept)" "$_m2" "$_m1"
printf '{ broken' > "$T/bad.json"
node "$M" --template "$T/new.json" --settings "$T/bad.json" >/dev/null 2>&1; _rc=$?
is "an unparseable settings.json is refused (exit 1), not replaced" "$_rc" "1"
is "  and left exactly as it was" "$(cat "$T/bad.json")" "{ broken"
fi

# ── step 4: the manifest is deterministic and blind to CRLF checkouts ────────────────────────
if want MANIFEST; then
echo "(${SECONDS}s) [MANIFEST] determinism and line endings"
_G="$SB/gitrepo"; rm -rf "$_G"; cp -r "$SRC" "$_G"
( cd "$_G" && git init -q && git -c core.autocrlf=false add -A && git -c user.name=t -c user.email=nobody -c core.autocrlf=false commit -qm fixture ) >/dev/null 2>&1
relman_archive_tree "$_G" HEAD "$SB/arch1" && bash "$SB/arch1/install.sh" --print-install-map > "$SB/map1" 2>/dev/null
relman_build "$SB/arch1" 3.0.0 1 "$SB/map1" 2026-01-01T00:00:00Z > "$SB/m1"
relman_build "$SB/arch1" 3.0.0 1 "$SB/map1" 2026-01-01T00:00:00Z > "$SB/m2"
is "built twice from the same tree: byte-identical" "$(cmp -s "$SB/m1" "$SB/m2" && echo same || echo differs)" "same"
git -c core.autocrlf=true clone -q "$_G" "$SB/crlfclone" 2>/dev/null
is "precondition: the autocrlf clone has CRLF files in its worktree" "$([ -n "$(grep -rl $'\r' "$SB/crlfclone/bundle" 2>/dev/null | head -1)" ] && echo yes || echo no)" "yes"
relman_archive_tree "$SB/crlfclone" HEAD "$SB/arch2" && bash "$SB/arch2/install.sh" --print-install-map > "$SB/map2" 2>/dev/null
relman_build "$SB/arch2" 3.0.0 1 "$SB/map2" 2026-01-01T00:00:00Z > "$SB/m3"
is "a CRLF checkout yields the same manifest" "$(cmp -s "$SB/m1" "$SB/m3" && echo same || echo differs)" "same"
relman_build "$SB/crlfclone" 3.0.0 1 "$SB/map2" 2026-01-01T00:00:00Z 2>/dev/null | grep -v '^[^0-9a-f]' > "$SB/m4"
is "control: hashing the CRLF WORKTREE directly would differ" "$(relman_section "$SB/m1" files | cmp -s - <(relman_section "$SB/m4" files 2>/dev/null) && echo same || echo differs)" "differs"
relman_validate_header "$SB/m1" 3.0.0 2>/dev/null; is "the built manifest validates" "$?" "0"
sed 's/^files=.*/files=1/' "$SB/m1" > "$SB/m5"; relman_validate_header "$SB/m5" 2>/dev/null; is "a wrong files= count is rejected" "$?" "1"
fi

# ── step 5: what install.sh copies == its install map ─────────────────────────────────────────
if want MAP; then
echo "(${SECONDS}s) [MAP] install-map parity"
_P="$SB/parity"; rm -rf "$_P"; mkdir -p "$_P"; nonce_home "$_P"
_tree="$SB/rel/base/claude-code-governance-1.9.0"
_nmap=$(bash "$_tree/install.sh" --print-install-map 2>/dev/null | grep -c .)
_ninst=$(cd "$BASE/.claude" && find hooks skills docs agents -type f 2>/dev/null | grep -c .)
is "full install: files copied == map lines" "$_ninst" "$_nmap"
HOME="$_P" bash "$_tree/install.sh" --core-only --accept-terms --no-verify >/dev/null 2>&1 </dev/null
_ncore=$(bash "$_tree/install.sh" --print-install-map 2>/dev/null | awk '$4 == "core"' | grep -c .)
_ninst=$(cd "$_P/.claude" && find hooks skills docs agents -type f 2>/dev/null | grep -c .)
is "core-only install: files copied == core map lines" "$_ninst" "$_ncore"
is "core-only records its mode" "$(cat "$_P/.claude/.governance-update/install-mode")" "core-only"
is "  and push at session close OFF (no terminal, no flag)" \
   "$(gov_record_field "$_P/.claude/.governance-update/close-push" enabled)/$(gov_record_field "$_P/.claude/.governance-update/close-push" method)" "0/default-non-interactive"
_d=$(HOME="$SB/dry" bash "$_tree/install.sh" --dry-run </dev/null 2>&1); _rc=$?
is "dry run without accepted terms and no terminal exits 1" "$_rc" "1"
has "  and says why" "$_d" "Terms v1 are not accepted"
is "  and writes nothing" "$(find "$SB/dry" -type f 2>/dev/null | grep -c .)" "0"
_d=$(HOME="$SB/refuse" bash "$_tree/install.sh" </dev/null 2>&1); _rc=$?
is "a real install without acceptance refuses (exit 1)" "$_rc" "1"
is "  before writing anything" "$(find "$SB/refuse" -type f 2>/dev/null | grep -c .)" "0"
nonce_home "$SB/dry2"
_d=$(HOME="$SB/dry2" bash "$_tree/install.sh" --dry-run --accept-terms </dev/null 2>&1); _rc=$?
is "dry run with --accept-terms exits 0" "$_rc" "0"
has "  it previews the push-at-close record" "$_d" "[DRY] would record push at session close: OFF (default-non-interactive)"
is "  and writes nothing (only the nonce is in HOME)" "$(find "$SB/dry2" -mindepth 1 ! -name .governance-consent-selftest | wc -l | tr -d ' ')" "0"
echo "  (pinned key vs a clone signed by another key)"
mkrel foreign 2.0.0 k2 >/dev/null
cp -r "$BASE" "$SB/pinhome"
_d=$(HOME="$SB/pinhome" bash "$SB/rel/foreign/claude-code-governance-2.0.0/install.sh" --accept-terms --no-verify </dev/null 2>&1); _rc=$?
is "a clone whose manifest does not verify under its OWN key is refused" "$_rc" "1"
has "  with the reason" "$_d" "does not verify under its OWN"
pre_foreignkey() { signer_line k2 > "$1/bundle/release/allowed_signers"; }
mkrel foreign2 2.0.0 k2 pre_foreignkey >/dev/null
_d=$(HOME="$SB/pinhome" bash "$SB/rel/foreign2/claude-code-governance-2.0.0/install.sh" --accept-terms --no-verify </dev/null 2>&1); _rc=$?
is "a self-consistent clone with a DIFFERENT key is refused against the pin" "$_rc" "1"
has "  naming --trust-new-key" "$_d" "--trust-new-key"
_d=$(HOME="$SB/pinhome" bash "$SB/rel/foreign2/claude-code-governance-2.0.0/install.sh" --accept-terms --no-verify --trust-new-key </dev/null 2>&1); _rc=$?
is "--trust-new-key replaces the pin" "$_rc" "0"
is "  (pinned file now equals the clone's)" "$(cmp -s "$SB/pinhome/.claude/.governance-update/allowed_signers" "$SB/rel/foreign2/claude-code-governance-2.0.0/bundle/release/allowed_signers" && echo same || echo differs)" "same"
fi

# ── only a person accepts; the record says which text (P4: C3, C5, S4) ────────────────────────
if want CONSENT; then
echo "(${SECONDS}s) [CONSENT] install.sh / gov-update.sh --accept-terms refuse an AI agent; records carry the hashes"
_tree="$SB/rel/base/claude-code-governance-1.9.0"; _N="$_tree/NOTICE-AUTO-UPDATE.md"
_hash_summary() { sed -n '/<!-- terms-summary:begin -->/,/<!-- terms-summary:end -->/{/<!--/d;p;}' "$1" | tr -d '\r' | sha256sum | cut -d' ' -f1; }
# _hash_file, _mode, _mode_is_600: defined once, before the baseline install.
_REF1='[GOVERNANCE] Refused: this needs your own decision, typed in your own terminal, and an AI-agent'
_REF2='session was detected (a safeguard, not a guarantee). Nothing was recorded or changed.'
_S1=$(sed -n '/<!-- terms-summary:begin -->/,/<!-- terms-summary:end -->/{/<!--/d;p;}' "$_N" | grep -m1 .)
is "precondition: the fixture NOTICE has a non-empty summary block" "$([ -n "$_S1" ] && echo yes || echo no)" "yes"

echo "  (a) install.sh --accept-terms inside an agent session, NO nonce: refused before any write"
_ca="$SB/c-a"; rm -rf "$_ca"; mkdir -p "$_ca"
_o=$(HOME="$_ca" CLAUDECODE=1 bash "$_tree/install.sh" --accept-terms --no-verify </dev/null 2>&1); _rc=$?
is "  rc 1" "$_rc" "1"
is "  the A.2 refusal, both lines verbatim" "$(printf '%s\n' "$_o" | grep -cxF "$_REF1")/$(printf '%s\n' "$_o" | grep -cxF "$_REF2")" "1/1"
is "  no .governance-version, no .governance-update/, nothing left in HOME" \
   "$([ -e "$_ca/.claude/.governance-version" ] && echo marker || echo none)/$([ -e "$_ca/.claude/.governance-update" ] && echo upd || echo none)/$(find "$_ca" -mindepth 1 | wc -l | tr -d ' ')" "none/none/0"
hasnt "  it printed no summary (it refused before showing terms it will not record)" "$_o" "$_S1"
_o=$(HOME="$_ca" CLAUDECODE=1 GOV_ACCEPT_TERMS=1 bash "$_tree/install.sh" --no-verify </dev/null 2>&1); _rc=$?
is "  GOV_ACCEPT_TERMS=1 in the process env, no nonce: refused the same way" "$_rc/$(printf '%s\n' "$_o" | grep -cxF "$_REF1")/$(find "$_ca" -mindepth 1 | wc -l | tr -d ' ')" "1/1/0"

echo "  (b) the same with the nonce: accepted, and the record proves which text (C5)"
_cb="$SB/c-b"; rm -rf "$_cb"; nonce_home "$_cb"
_o=$(HOME="$_cb" CLAUDECODE=1 bash "$_tree/install.sh" --accept-terms --no-verify </dev/null 2>&1); _rc=$?
is "  rc 0" "$_rc" "0"
[ "$_rc" = "0" ] || printf '%s\n' "$_o" | tail -8
hasnt "  no refusal line" "$_o" "$_REF1"
has "  the summary is printed on the non-interactive path too (C2(c))" "$_o" "$_S1"
has "  the A.1 non-interactive outcome line" "$_o" "Terms v1 accepted non-interactively (--accept-terms). Full text: $_N"
_R="$_cb/.claude/.governance-update/terms-accepted"
is "  notice_sha256 = tr -d '\\r' < NOTICE | sha256sum" "$(gov_record_field "$_R" notice_sha256)" "$(_hash_file "$_N")"
is "  shown_sha256 = the summary block, same sed" "$(gov_record_field "$_R" shown_sha256)" "$(_hash_summary "$_N")"
is "  terms_version first (the grep/sed readers), then the other fields" \
   "$(sed -n 's/^\(terms_version=[0-9]*\) accepted_at=[0-9TZ:-]* framework_version=[^ ]* method=\([^ ]*\) notice_sha256=[0-9a-f]\{64\} shown_sha256=[0-9a-f]\{64\}$/\1 \2/p' "$_R")" "terms_version=1 --accept-terms"
is "  one line, no path in it (S4)" "$(wc -l < "$_R" | tr -d ' ')/$(grep -c / "$_R")" "1/0"
is "  no tmp file left beside it" "$(ls "$_cb/.claude/.governance-update" | grep -c '\.tmp\.')" "0"
_mode_is_600 "  terms-accepted is mode 600" "$_R"

echo "  (c) GOV_ACCEPT_TERMS=1 only in the sandbox local env file: not read (S4)"
_cc="$SB/c-c"; rm -rf "$_cc"; nonce_home "$_cc"; mkdir -p "$_cc/.claude"
printf 'GOV_ACCEPT_TERMS=1\nexport GOV_ACCEPT_TERMS=1\n' > "$_cc/.claude/.governance-local.env"
_o=$(HOME="$_cc" CLAUDECODE=1 bash "$_tree/install.sh" --no-verify </dev/null 2>&1); _rc=$?
is "  rc 1" "$_rc" "1"
has "  refused: not accepted, no terminal" "$_o" "Terms v1 not accepted, and there is no terminal to ask on."
is "  no record, no .governance-update/" "$([ -e "$_cc/.claude/.governance-update" ] && echo upd || echo none)" "none"
_o=$(HOME="$_cc" CLAUDECODE=1 GOV_ACCEPT_TERMS=1 bash "$_tree/install.sh" --no-verify </dev/null 2>&1); _rc=$?
is "  control: the same variable in the PROCESS env is an acceptance (method=env)" "$_rc/$(gov_record_field "$_cc/.claude/.governance-update/terms-accepted" method)" "0/env"

echo "  (d) the source-machine marker is NOT an exemption for consent (D3)"
_cd="$SB/c-d"; rm -rf "$_cd"; mkdir -p "$_cd/.claude"; : > "$_cd/.claude/.governance-source"
_o=$(HOME="$_cd" CLAUDECODE=1 bash "$_tree/install.sh" --accept-terms --no-verify </dev/null 2>&1); _rc=$?
is "  marker FILE, no nonce: rc 1, the A.2 refusal, no record" \
   "$_rc/$(printf '%s\n' "$_o" | grep -cxF "$_REF1")/$([ -e "$_cd/.claude/.governance-update/terms-accepted" ] && echo record || echo none)" "1/1/none"
rm -f "$_cd/.claude/.governance-source"; mkdir -p "$_cd/.claude/.governance-source"
_o=$(HOME="$_cd" CLAUDECODE=1 bash "$_tree/install.sh" --accept-terms --no-verify </dev/null 2>&1); _rc=$?
is "  marker DIRECTORY (a plain mkdir), no nonce: rc 1, the A.2 refusal, no record" \
   "$_rc/$(printf '%s\n' "$_o" | grep -cxF "$_REF1")/$([ -e "$_cd/.claude/.governance-update/terms-accepted" ] && echo record || echo none)" "1/1/none"
nonce_home "$_cd"
_o=$(HOME="$_cd" CLAUDECODE=1 bash "$_tree/install.sh" --accept-terms --no-verify </dev/null 2>&1); _rc=$?
is "  control: the same HOME with the sandbox nonce accepts (rc 0, recorded)" \
   "$_rc/$(gov_record_field "$_cd/.claude/.governance-update/terms-accepted" terms_version)" "0/1"
rm -rf "$_cd/.claude/.governance-source"

echo "  (e) gov-update.sh --accept-terms, GOV_ACCEPT_TERMS=1: refused without the nonce, recorded with it"
use_home "$BASE"; rm -f "$H/.governance-consent-selftest"
_R="$H/.claude/.governance-update/terms-accepted"; _rb=$(sha256sum < "$_R")
_o=$(HOME="$H" CLAUDECODE=1 GOV_ACCEPT_TERMS=1 bash "$H/.claude/hooks/governance/gov-update.sh" --accept-terms </dev/null 2>&1); _rc=$?
is "  no nonce: rc 1" "$_rc" "1"
is "  the A.2 refusal, both lines verbatim" "$(printf '%s\n' "$_o" | grep -cxF "$_REF1")/$(printf '%s\n' "$_o" | grep -cxF "$_REF2")" "1/1"
is "  the record is unchanged" "$(sha256sum < "$_R")" "$_rb"
nonce_home "$H"
_GN="$H/.claude/governance-installer/NOTICE-AUTO-UPDATE.md"
_o=$(HOME="$H" CLAUDECODE=1 GOV_ACCEPT_TERMS=1 bash "$H/.claude/hooks/governance/gov-update.sh" --accept-terms </dev/null 2>&1); _rc=$?
is "  with the nonce: rc 0, method env" "$_rc/$(gov_record_field "$_R" method)/$(gov_record_field "$_R" terms_version)" "0/env/1"
is "  notice_sha256 = the installer copy's NOTICE (nothing staged)" "$(gov_record_field "$_R" notice_sha256)" "$(_hash_file "$_GN")"
is "  shown_sha256 = its summary block" "$(gov_record_field "$_R" shown_sha256)" "$(_hash_summary "$_GN")"
has "  the final line: nothing installs on its own" "$_o" "[GOVERNANCE UPDATE] terms v1 accepted (env). Nothing was installed, and nothing installs on its own."
hasnt "  no 'installs itself' (there is no automatic update)" "$_o" "installs itself"
_mode_is_600 "  the rewritten record is mode 600" "$_R"
use_home "$STAGED"; printf '\nlocal edit\n' >> "$H/.claude/governance-installer/NOTICE-AUTO-UPDATE.md"
_SN="$H/.claude/.governance-update/staged/v2.0.0/NOTICE-AUTO-UPDATE.md"
_o=$(HOME="$H" CLAUDECODE=1 GOV_ACCEPT_TERMS=1 bash "$H/.claude/hooks/governance/gov-update.sh" --accept-terms </dev/null 2>&1); _rc=$?
is "  a staged release: rc 0, and the hash is the STAGED NOTICE's, not the installer copy's" \
   "$_rc/$([ "$(gov_record_field "$_R" notice_sha256)" = "$(_hash_file "$_SN")" ] && echo staged || echo other)/$([ "$(_hash_file "$_SN")" != "$(_hash_file "$H/.claude/governance-installer/NOTICE-AUTO-UPDATE.md")" ] && echo distinct || echo same)" "0/staged/distinct"
has "  the final line names the manual install" "$_o" "Nothing installs on its own: to install v2.0.0, close every Claude Code session, then in your own terminal run  bash ~/.claude/hooks/governance/gov-update.sh --apply --force-live"
is "  and nothing was installed" "$(marker)" "1.9.0"

echo "  (f) --dry-run --accept-terms: the nonce'd run previews the record and writes nothing"
_cf="$SB/c-f"; rm -rf "$_cf"; nonce_home "$_cf"
_o=$(HOME="$_cf" CLAUDECODE=1 bash "$_tree/install.sh" --dry-run --accept-terms </dev/null 2>&1); _rc=$?
is "  rc 0" "$_rc" "0"
has "  it says what it would record" "$_o" "[DRY] would record terms v1 (--accept-terms)"
has "  and the push-at-close record it would write (OFF: no terminal, no flag)" "$_o" "[DRY] would record push at session close: OFF (default-non-interactive)"
has "  the OFF-without-terminal line names close-push.sh --enable (D2)" "$_o" "$CP_OFF_NOTTY"
is "  no preview of push ON anywhere" "$(printf '%s\n' "$_o" | grep -c 'would record push at session close: ON')" "0"
hasnt "  it does not claim it recorded the push choice" "$_o" "Push at session close: OFF recorded"
is "  nothing written (only the nonce is in HOME)" "$(find "$_cf" -mindepth 1 ! -name .governance-consent-selftest | wc -l | tr -d ' ')" "0"
rm -f "$_cf/.governance-consent-selftest"
_o=$(HOME="$_cf" CLAUDECODE=1 bash "$_tree/install.sh" --dry-run --accept-terms </dev/null 2>&1); _rc=$?
is "  without the nonce: the preview mirrors the refusal (rc 1, the A.2 line, no 'would record')" \
   "$_rc/$(printf '%s\n' "$_o" | grep -cxF "$_REF1")/$(printf '%s\n' "$_o" | grep -c 'would record terms')" "1/1/0"
is "  and still writes nothing" "$(find "$_cf" -mindepth 1 | wc -l | tr -d ' ')" "0"

echo "  (g) --uninstall keeps terms-accepted and close-push (the records of the user's choices)"
_R="$_cb/.claude/.governance-update/terms-accepted"; _rb=$(sha256sum < "$_R" 2>/dev/null)
_RC="$_cb/.claude/.governance-update/close-push"; _rcb=$(sha256sum < "$_RC" 2>/dev/null)
is "  precondition: the install wrote a close-push record" "$([ -s "$_RC" ] && echo yes || echo no)" "yes"
_o=$(HOME="$_cb" CLAUDECODE=1 bash "$_tree/install.sh" --uninstall </dev/null 2>&1); _rc=$?
is "  rc 0, and the hooks are gone (it did uninstall)" "$_rc/$([ -e "$_cb/.claude/hooks/governance/pre-session.sh" ] && echo present || echo gone)" "0/gone"
is "  terms-accepted kept, byte for byte" "$(sha256sum < "$_R" 2>/dev/null)" "$_rb"
is "  close-push kept, byte for byte" "$(sha256sum < "$_RC" 2>/dev/null)" "$_rcb"
has "  the success line names both" "$_o" "kept terms-accepted and close-push"
is "  control: the rest of the update state is gone (install-mode)" "$([ -e "$_cb/.claude/.governance-update/install-mode" ] && echo present || echo gone)" "gone"
_mode_is_600 "  still mode 600" "$_R"
fi

# ── push at session close is the user's recorded choice (P6: C4, T3, S4) ──────────────────────
if want CLOSEPUSH; then
echo "(${SECONDS}s) [CLOSEPUSH] install.sh: push at session close is OFF unless a person turns it on"
_tree="$SB/rel/base/claude-code-governance-1.9.0"; _N="$_tree/NOTICE-AUTO-UPDATE.md"
_U="$H/.claude/.governance-update"; _CPR="$_U/close-push"
_today=$(date -u +%Y-%m-%d)
_CPREF1='[GOVERNANCE] Refused: this needs your own decision, typed in your own terminal, and an AI-agent'
_CPREF2='session was detected (a safeguard, not a guarantee). Nothing was recorded or changed.'
_QRISK='  Main risks: a push cannot be taken back once someone has fetched it; everyone with access to'
_qhash() { ( . "$1" && gov_close_push_question "$2" | gov_sha256_lf_stdin ); }  # <consent-lib.sh> <NOTICE>
_cpf() { printf '%s/%s/%s' "$(gov_record_field "$_CPR" enabled)" "$(gov_record_field "$_CPR" method)" "$(gov_record_field "$_CPR" terms_version)"; }
_inst_cp() { HOME="$H" CLAUDECODE=1 bash "${CP_TREE:-$_tree}/install.sh" "$@" </dev/null 2>&1; }
# A private governed repo one commit ahead of a LOCAL bare origin (close-push.sh's selftest _mk shape).
git config --file "$SB/cp-gitconfig" user.email you@example.com
git config --file "$SB/cp-gitconfig" user.name selftest
git config --file "$SB/cp-gitconfig" init.defaultBranch main
git config --file "$SB/cp-gitconfig" protocol.file.allow always
_cpgit() { GIT_CONFIG_GLOBAL="$SB/cp-gitconfig" GIT_CONFIG_NOSYSTEM=1 git "$@"; }
_cpmk() {
  local r="$SB/cp-$1"; rm -rf "$r" "$r.git"
  _cpgit init --quiet --bare "$r.git"; _cpgit clone --quiet "$r.git" "$r" 2>/dev/null
  mkdir -p "$r/docs/context"; printf -- '---\ntype: manifest\n---\n' > "$r/docs/context/CONTEXT-MANIFEST.md"
  printf 'a\n' > "$r/a.txt"; _cpgit -C "$r" add -A; _cpgit -C "$r" commit --quiet -m base
  _cpgit -C "$r" push --quiet -u origin main 2>/dev/null
  printf 'b\n' >> "$r/a.txt"; _cpgit -C "$r" commit --quiet -am ahead
}
_cprun() { HOME="$H" GIT_CONFIG_GLOBAL="$SB/cp-gitconfig" GIT_CONFIG_NOSYSTEM=1 bash "$H/.claude/hooks/governance/close-push.sh" -C "$SB/cp-$1" </dev/null 2>&1 | tail -1; }
_cporigin() { [ "$(_cpgit -C "$SB/cp-$1" rev-parse HEAD)" = "$(_cpgit --git-dir="$SB/cp-$1.git" rev-parse main 2>/dev/null)" ] && echo holds-head || echo behind; }

echo "  (a) --enable-close-push is gone (D2): an unknown option, exit 1, HOME untouched - even with the nonce"
use_home "$BASE"; _before=$(treehash); _cpb=$(sha256sum < "$_CPR"); _tb=$(sha256sum < "$_U/terms-accepted")
_o=$(_inst_cp --enable-close-push --force --no-verify); _rc=$?
is "  rc 1" "$_rc" "1"
has "  the installer's unknown-option line" "$_o" "Unknown option: --enable-close-push"
hasnt "  the question was not shown" "$_o" "$_QRISK"
hasnt "  no ON line" "$_o" "Push at session close: ON"
is "  tree, close-push, terms-accepted unchanged; lock free" \
   "$([ "$(treehash)" = "$_before" ] && echo same || echo changed)/$([ "$(sha256sum < "$_CPR")" = "$_cpb" ] && echo same || echo changed)/$([ "$(sha256sum < "$_U/terms-accepted")" = "$_tb" ] && echo same || echo changed)/$([ -d "$_U/lock.d" ] && echo held || echo free)" "same/same/same/free"
is "  the usage text names no ON flag (--help)" "$(bash "$_tree/install.sh" --help </dev/null 2>&1 | grep -c -- '--enable-close-push')" "0"

echo "  (a2) T3 / round-2 finding 13: both writers print the question with gov_close_push_ask and record the hash of the printed bytes"
_QEND='Turn push at session close ON now? [y/N]: '
# _askcap <consent-lib.sh> <notice path> <outfile>: the bytes gov_close_push_ask printed -> <outfile>,
# the hash it set -> stdout. Hashed independently below (_hash_file), never by the code under test.
_askcap() { ( . "$1" && GOV_SHOWN_SHA256="" && gov_close_push_ask "$2" > "$3" && printf '%s' "$GOV_SHOWN_SHA256" ); }
for _cl in "$_tree/bundle/hooks/governance/consent-lib.sh" "$H/.claude/hooks/governance/consent-lib.sh"; do
  _lbl=installer; [ "$_cl" = "$H/.claude/hooks/governance/consent-lib.sh" ] && _lbl=installed
  _set=$(_askcap "$_cl" "$_N" "$SB/cp-ask-$_lbl")
  is "  $_lbl consent-lib.sh: GOV_SHOWN_SHA256 = sha256 of exactly the bytes printed (real NOTICE path)" "$_set" "$(_hash_file "$SB/cp-ask-$_lbl")"
  is "  $_lbl: the hash is real (64 hex, not the empty-string hash)" "$(printf '%s' "$_set" | grep -cxE '[0-9a-f]{64}')/$([ "$_set" != "$EMPTY_SHA" ] && echo real || echo empty)" "1/real"
  is "  $_lbl: the printed block names the real NOTICE path" "$(grep -cF "Full text: $_N, sections 2a and 10.3" "$SB/cp-ask-$_lbl")" "1"
  is "  $_lbl: the printed block ends with the y/N prompt, no newline" "$(tail -c ${#_QEND} "$SB/cp-ask-$_lbl")" "$_QEND"
done
is "  the installer's and the installed copy print the same bytes (one literal)" "$(cmp -s "$SB/cp-ask-installer" "$SB/cp-ask-installed" && echo same || echo differs)" "same"
_sh=$(_hash_file "$SB/cp-ask-installed")
is "  control: the canonical-name hash differs from the printed one (the round-2 finding-13 mismatch is detectable)" \
   "$([ "$(_qhash "$H/.claude/hooks/governance/consent-lib.sh" NOTICE-AUTO-UPDATE.md)" != "$_sh" ] && echo differs || echo same)" "differs"
is "  both writers call gov_close_push_ask once and take its hash (install.sh, close-push.sh --enable)" \
   "$(grep -cxF '    GOV_SHOWN_SHA256=""; gov_close_push_ask "$NOTICE_FILE"; PUSH_SHOWN_SHA="$GOV_SHOWN_SHA256"' "$_tree/install.sh")/$(grep -cxF '  GOV_SHOWN_SHA256=""; gov_close_push_ask "$notice"; ssha="$GOV_SHOWN_SHA256"' "$H/.claude/hooks/governance/close-push.sh")" "1/1"
# The recorded hash, end to end, through each REAL writer. Neither reaches the question without a
# terminal, so a sandbox copy gets a test double: consent-lib.sh with gov_interactive_terminal -> 0
# appended (the copy only; the code under test is otherwise byte-identical). The answer is piped.
_SEAM="$SB/cp-seam"; rm -rf "$_SEAM"; mkdir -p "$_SEAM"
cp "$H/.claude/hooks/governance/close-push.sh" "$H/.claude/hooks/governance/consent-lib.sh" "$_SEAM/"
printf '\ngov_interactive_terminal() { return 0; }   # TEST DOUBLE (test-gov-update.sh CLOSEPUSH a2)\n' >> "$_SEAM/consent-lib.sh"
_NH="$H/.claude/hooks/governance-terms/NOTICE-AUTO-UPDATE.md"   # the installed copy of the terms (round 3b G2: gov_terms_copy_dir)
_enable_seam() { printf '%b' "$1" | HOME="$H" bash "$_SEAM/close-push.sh" --enable > "$SB/cp-seam.out" 2>/dev/null; }
use_home "$BASE"; rm -f "$_CPR"
_enable_seam 'y\n'; _rc=$?
is "  close-push.sh --enable (seam) + y: rc 0, enabled=1 method=close-push-enable" "$_rc/$(gov_record_field "$_CPR" enabled)/$(gov_record_field "$_CPR" method)" "0/1/close-push-enable"
_out=$(cat "$SB/cp-seam.out"); _pre="${_out%%"$_QEND"*}"
is "  precondition: the --enable output contains the y/N prompt" "$([ "$_pre" != "$_out" ] && echo yes || echo no)" "yes"
is "  close-push.sh --enable: recorded shown_sha256 = sha256 of the bytes it printed" \
   "$(gov_record_field "$_CPR" shown_sha256)" "$(printf '%s%s' "$_pre" "$_QEND" | tr -d '\r' | sha256sum | cut -d' ' -f1)"
has "  ... and those bytes carry the real NOTICE path" "$_pre" "Full text: $_NH, sections 2a and 10.3"
for _a in 'YES\n' ' y \r\n' 'Yes\r\n'; do
  rm -f "$_CPR"; _enable_seam "$_a"
  is "  close-push.sh --enable (seam) answer [$(printf '%s' "$_a" | sed 's/\\r/<CR>/;s/\\n//')]: ON" "$(gov_record_field "$_CPR" enabled)/$(gov_record_field "$_CPR" method)" "1/close-push-enable"
done
for _a in '\n' '\r\n' 'n\n' 'no\n' 'yy\n' 'I ENABLE PUSH AT SESSION CLOSE\n' ''; do
  rm -f "$_CPR"; _enable_seam "$_a"
  is "  close-push.sh --enable (seam) answer [$(printf '%s' "$_a" | sed 's/\\r/<CR>/;s/\\n//')]: OFF, declined" "$(gov_record_field "$_CPR" enabled)/$(gov_record_field "$_CPR" method)" "0/declined"
done
# install.sh: a COPY of the installer tree whose bundled consent-lib.sh carries the same double (the
# copy installs as an unsigned snapshot; only the close-push record is under test here).
_ST="$SB/cp-seam-tree"; rm -rf "$_ST"; cp -r "$_tree" "$_ST"
printf '\ngov_interactive_terminal() { return 0; }   # TEST DOUBLE (test-gov-update.sh CLOSEPUSH a2)\n' >> "$_ST/bundle/hooks/governance/consent-lib.sh"
_inst_seam() {  # _inst_seam <answer>: a fresh copy of the baseline HOME without a record, install.sh answering
  rm -rf "$SB/cp-seam-home"; cp -r "$BASE" "$SB/cp-seam-home"; rm -f "$SB/cp-seam-home/.claude/.governance-update/close-push"
  printf '%b' "$1" | HOME="$SB/cp-seam-home" CLAUDECODE=1 bash "$_ST/install.sh" --force --no-verify > "$SB/cp-seam-inst.out" 2>/dev/null
}
_SR="$SB/cp-seam-home/.claude/.governance-update/close-push"
_inst_seam 'y\n'; _rc=$?
is "  install.sh (seam) + y: rc 0, enabled=1 method=interactive" "$_rc/$(gov_record_field "$_SR" enabled)/$(gov_record_field "$_SR" method)" "0/1/interactive"
_out=$(cat "$SB/cp-seam-inst.out"); _pre="${_out%%"$_QEND"*}"
_qb=$( ( . "$_ST/bundle/hooks/governance/consent-lib.sh" && gov_close_push_question "$_ST/NOTICE-AUTO-UPDATE.md"; printf '.' ) ); _qb="${_qb%.}"
is "  install.sh: the question block is in what it printed, verbatim (real NOTICE path)" "$(case "$_out" in *"$_qb"*) echo printed ;; *) echo absent ;; esac)" "printed"
is "  install.sh: recorded shown_sha256 = sha256 of the block it printed" \
   "$(gov_record_field "$_SR" shown_sha256)" "$(printf '%s' "$_qb" | tr -d '\r' | sha256sum | cut -d' ' -f1)"
# One No through the real installer (each install is slow on a loaded machine); the whole No set
# runs through close-push.sh above and through the shared rule in (a3).
for _a in 'I ENABLE PUSH AT SESSION CLOSE\n'; do
  _inst_seam "$_a"
  is "  install.sh (seam) answer [$(printf '%s' "$_a" | sed 's/\\n//')]: OFF, declined" "$(gov_record_field "$_SR" enabled)/$(gov_record_field "$_SR" method)" "0/declined"
done
use_home "$BASE"
# The ON record the rest of this section starts from is PLANTED, with the hash a writer records for
# this NOTICE path (no flag and no non-terminal path writes an ON record).
printf 'enabled=1 terms_version=1 decided_at=%s framework_version=1.9.0 method=interactive notice_sha256=%s shown_sha256=%s\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(_hash_file "$_N")" "$_sh" > "$_CPR"
is "  planted ON record: gov_close_push_on agrees: ON" "$(HOME="$H" bash -c '. "$1" && gov_close_push_on && echo on || echo "off: $GOV_CONSENT_REASON"' _ "$H/.claude/hooks/governance/consent-lib.sh")" "on"

echo "  (a3) the answer rule of the y/N question (one rule, consent-lib.sh gov_close_push_answer_yes)"
_ansfn=$(sed -n '/^  _inst_answer_enables() {$/,/^  }$/p' "$_tree/install.sh")
is "  precondition: _inst_answer_enables extracted from install.sh" "$(printf '%s\n' "$_ansfn" | grep -c '_inst_answer_enables() {')" "1"
_ans() { ( . "$_tree/bundle/hooks/governance/consent-lib.sh" && eval "$_ansfn" && _inst_answer_enables "$1" && echo ON || echo OFF ); }
# A CR variable, not $'y\r' inline: bash fails to parse $'...' after a '...' argument inside one
# "$(...)/$(...)" string (measured: "unexpected EOF while looking for matching `)'").
_CR=$'\r'
is "  y / yes / Y / YES / padded / with CR -> ON" \
   "$(_ans y)/$(_ans yes)/$(_ans Y)/$(_ans YES)/$(_ans '  yes ')/$(_ans "y$_CR")" "ON/ON/ON/ON/ON/ON"
is "  Enter / n / no / ye / yess / the withdrawn phrase -> OFF" \
   "$(_ans '')/$(_ans n)/$(_ans no)/$(_ans ye)/$(_ans yess)/$(_ans 'I ENABLE PUSH AT SESSION CLOSE')" "OFF/OFF/OFF/OFF/OFF/OFF"
is "  the interactive branch uses it" "$(grep -c 'if _inst_answer_enables "\$_cp_ans"; then' "$_tree/install.sh")" "1"
if command -v script >/dev/null 2>&1 && script --version 2>/dev/null | grep -qi util-linux; then
  _pty() {  # _pty <answer> -> install.sh on a pty (stdin AND stdout a terminal), answer fed to the question
    printf '%s\n' "$1" | HOME="$SB/cp-pty" CLAUDECODE=1 script -qec "bash '$_tree/install.sh' --force --no-verify" /dev/null 2>&1
  }
  rm -rf "$SB/cp-pty"; cp -r "$BASE" "$SB/cp-pty"; rm -f "$SB/cp-pty/.claude/.governance-update/close-push"
  _o=$(_pty 'y')
  _qtree=$( ( . "$_tree/bundle/hooks/governance/consent-lib.sh" && gov_close_push_question "$_N" ) | tr -d '\r' | sha256sum | cut -d' ' -f1)
  is "  pty: y -> enabled=1 method=interactive, shown_sha256 = the hash of the block printed (real path)" \
     "$(gov_record_field "$SB/cp-pty/.claude/.governance-update/close-push" enabled)/$(gov_record_field "$SB/cp-pty/.claude/.governance-update/close-push" method)/$([ "$(gov_record_field "$SB/cp-pty/.claude/.governance-update/close-push" shown_sha256)" = "$_qtree" ] && echo printed || echo other)" "1/interactive/printed"
  rm -f "$SB/cp-pty/.claude/.governance-update/close-push"
  _o=$(_pty '')
  is "  pty: Enter (the default No) -> enabled=0 method=declined" \
     "$(gov_record_field "$SB/cp-pty/.claude/.governance-update/close-push" enabled)/$(gov_record_field "$SB/cp-pty/.claude/.governance-update/close-push" method)" "0/declined"
else
  echo "  skip pty run of the interactive question (no util-linux script(1) here - Git for Windows / macOS; the answer rule is (a3), the printed-bytes hash through both real writers is (a2) via the terminal test double)"
fi

echo "  (b) end to end: the installer's ON record makes close-push.sh push a private repo"
_cpmk on1
_o=$(_cprun on1)
has "  close-push.sh: PUSHED" "$_o" "[close-push] PUSHED"
is "  the bare origin really holds HEAD" "$(_cporigin on1)" "holds-head"
CP_ON_HOME="$SB/cp-on-home"; rm -rf "$CP_ON_HOME"; cp -r "$H" "$CP_ON_HOME"

echo "  (c) --no-close-push: OFF, recorded by flag; close-push.sh then skips (the other direction)"
_o=$(_inst_cp --no-close-push --force --no-verify); _rc=$?
is "  rc 0, record 0/--no-close-push/1" "$_rc/$(_cpf)" "0/0/--no-close-push/1"
has "  the A.7 'no' line" "$_o" "Push at session close: OFF. Sessions still commit their own work locally; nothing is pushed."
has "  the A.8 push line: OFF" "$_o" "$CP_SUM_OFF"
is "  shown_sha256 = the empty-string hash (no question)" "$(gov_record_field "$_CPR" shown_sha256)" "$EMPTY_SHA"
_cpmk off1
_o=$(_cprun off1)
has "  close-push.sh: SKIP, off on this machine" "$_o" "[close-push] SKIP (push at session close is off on this machine - off (your choice)"
is "  the origin does not hold HEAD" "$(_cporigin off1)" "behind"
_cpb=$(sha256sum < "$_CPR")
_o=$(_inst_cp --force --no-verify); _rc=$?
is "  a re-install without a flag keeps it: rc 0, bytes unchanged" "$_rc/$([ "$(sha256sum < "$_CPR")" = "$_cpb" ] && echo same || echo changed)" "0/same"
has "  ... and says so" "$_o" "Push at session close: OFF (your choice, recorded $_today). Change it at any time: close-push.sh --enable / --disable"

echo "  (c2) a kept record is described by its method= (findings 2/17): only a person's choice is 'your choice'"
_CPK_DEF='Push at session close: OFF (the default - you were not asked, recorded 2026-01-01). To turn it on, run this yourself in your own terminal: bash ~/.claude/hooks/governance/close-push.sh --enable'
_CPK_TC='Push at session close: OFF (turned off when the terms changed, recorded 2026-01-01). To turn it on, run this yourself in your own terminal: bash ~/.claude/hooks/governance/close-push.sh --enable'
_CPK_OFF='Push at session close: OFF (your choice, recorded 2026-01-01). Change it at any time: close-push.sh --enable / --disable'
_CPK_ON='Push at session close: ON (your choice, recorded 2026-01-01). Change it at any time: close-push.sh --enable / --disable'
# Round 4 minor (2026-10-02): an OFF with an unknown method is "recorded off" here too, as consent-lib.sh
# gov_close_push_off_kind and gov-update.sh --status word it - never "your choice".
_CPK_REC='Push at session close: OFF (recorded off on 2026-01-01). Change it at any time: close-push.sh --enable / --disable'
for _m in 0/default-non-interactive 0/default-agent-session 0/terms-changed 0/declined 0/close-push-disable 0/something-else 1/close-push-enable; do
  printf 'enabled=%s terms_version=1 decided_at=2026-01-01T00:00:00Z framework_version=2.0.0 method=%s\n' "${_m%%/*}" "${_m#*/}" > "$_CPR"
  _cpb=$(sha256sum < "$_CPR")
  _o=$(_inst_cp --force --no-verify); _rc=$?
  is "  $_m: kept (rc 0, bytes unchanged)" "$_rc/$([ "$(sha256sum < "$_CPR")" = "$_cpb" ] && echo same || echo changed)" "0/same"
  case "$_m" in
    0/default-*)     has "  $_m: 'the default - you were not asked'" "$_o" "$_CPK_DEF"
                     hasnt "  $_m: ... never 'your choice'" "$_o" "Push at session close: OFF (your choice" ;;
    0/terms-changed) has "  $_m: 'turned off when the terms changed'" "$_o" "$_CPK_TC"
                     hasnt "  $_m: ... never 'your choice'" "$_o" "Push at session close: OFF (your choice" ;;
    0/something-else) has "  $_m: 'recorded off', the same words as --status" "$_o" "$_CPK_REC"
                     hasnt "  $_m: ... never 'your choice'" "$_o" "Push at session close: OFF (your choice" ;;
    0/*)             has "  $_m: the user's no is 'your choice'" "$_o" "$_CPK_OFF"
                     hasnt "  $_m: ... never 'you were not asked'" "$_o" "you were not asked"
                     hasnt "  $_m: ... never 'when the terms changed'" "$_o" "turned off when the terms changed" ;;
    1/*)             has "  $_m: the user's yes is 'your choice'" "$_o" "$_CPK_ON"
                     hasnt "  $_m: ... never 'you were not asked'" "$_o" "you were not asked" ;;
  esac
done
_o=$(_inst_cp --dry-run --no-verify); _rc=$?
is "  --dry-run over the close-push-enable record: rc 0, the same kept line" "$_rc/$(printf '%s\n' "$_o" | grep -cF "$_CPK_ON")" "0/1"
printf 'enabled=0 terms_version=1 decided_at=2026-01-01T00:00:00Z framework_version=2.0.0 method=default-non-interactive\n' > "$_CPR"
_o=$(_inst_cp --dry-run --no-verify); _rc=$?
is "  --dry-run over a default OFF (the finding's own repro): rc 0, the default line, no 'your choice'" \
   "$_rc/$(printf '%s\n' "$_o" | grep -cF "$_CPK_DEF")/$(printf '%s\n' "$_o" | grep -cF 'Push at session close: OFF (your choice')" "0/1/0"

echo "  (d)--enable-close-push with or without the nonce: an unknown option, nothing written; no path previews ON"
rm -rf "$H"; cp -r "$CP_ON_HOME" "$H"
_o=$(_inst_cp --no-close-push --force --no-verify)   # start from OFF, so a wrongful ON would show
rm -f "$H/.governance-consent-selftest"; _before=$(treehash); _cpb=$(sha256sum < "$_CPR")
_o=$(_inst_cp --enable-close-push --force --no-verify); _rc=$?
is "  no nonce: rc 1, Unknown option" "$_rc/$(printf '%s\n' "$_o" | grep -c 'Unknown option: --enable-close-push')" "1/1"
hasnt "  the question was not shown" "$_o" "$_QRISK"
is "  record and tree unchanged, lock released" "$([ "$(sha256sum < "$_CPR")" = "$_cpb" ] && echo same || echo changed)/$([ "$(treehash)" = "$_before" ] && echo same || echo changed)/$([ -d "$_U/lock.d" ] && echo held || echo free)" "same/same/free"
_o=$(_inst_cp --enable-close-push --dry-run); _rc=$?
is "  no nonce, --dry-run: rc 1, Unknown option, no 'would record push'" \
   "$_rc/$(printf '%s\n' "$_o" | grep -c 'Unknown option: --enable-close-push')/$(printf '%s\n' "$_o" | grep -c 'would record push')" "1/1/0"
is "  ... and writes nothing" "$([ "$(sha256sum < "$_CPR")" = "$_cpb" ] && echo same || echo changed)/$([ "$(treehash)" = "$_before" ] && echo same || echo changed)" "same/same"
_o=$(_inst_cp --no-close-push --force --no-verify); _rc=$?
is "  control: turning it OFF needs no nonce (an agent may turn it off)" "$_rc/$(_cpf)" "0/0/--no-close-push/1"
nonce_home "$H"; _before=$(treehash); _cpb=$(sha256sum < "$_CPR")
_o=$(_inst_cp --enable-close-push --force --no-verify); _rc=$?
is "  with the nonce: rc 1, Unknown option, nothing written" \
   "$_rc/$(printf '%s\n' "$_o" | grep -c 'Unknown option: --enable-close-push')/$([ "$(sha256sum < "$_CPR")" = "$_cpb" ] && echo same || echo changed)/$([ "$(treehash)" = "$_before" ] && echo same || echo changed)" "1/1/same/same"
_o=$(_inst_cp --enable-close-push --dry-run); _rc=$?
is "  with the nonce, --dry-run: rc 1, Unknown option, no preview of ON" \
   "$_rc/$(printf '%s\n' "$_o" | grep -c 'Unknown option: --enable-close-push')/$(printf '%s\n' "$_o" | grep -c 'would record push at session close: ON')" "1/1/0"
_o=$(_inst_cp --dry-run --force); _rc=$?
is "  control: a nonce'd --dry-run without the flag runs (rc 0) and previews no ON" \
   "$_rc/$(printf '%s\n' "$_o" | grep -c 'would record push at session close: ON')/$(_cpf)" "0/0/0/--no-close-push/1"

echo "  (e) --enable-close-push --no-close-push: an unknown option (the contradiction check is gone), nothing written"
_cb2="$SB/cp-both"; rm -rf "$_cb2"; nonce_home "$_cb2"
_o=$(HOME="$_cb2" bash "$_tree/install.sh" --accept-terms --enable-close-push --no-close-push </dev/null 2>&1); _rc=$?
is "  rc 1" "$_rc" "1"
has "  it says why" "$_o" "Unknown option: --enable-close-push"
hasnt "  no contradiction text any more" "$_o" "contradict each other"
is "  nothing written (only the nonce is in HOME)" "$(find "$_cb2" -mindepth 1 ! -name .governance-consent-selftest | wc -l | tr -d ' ')" "0"
_o=$(HOME="$_cb2" bash "$_tree/install.sh" --accept-terms --no-close-push --no-verify </dev/null 2>&1); _rc=$?
is "  control: one of them alone installs (rc 0, 0/--no-close-push)" "$_rc/$(gov_record_field "$_cb2/.claude/.governance-update/close-push" enabled)/$(gov_record_field "$_cb2/.claude/.governance-update/close-push" method)" "0/0/--no-close-push"

echo "  (f) the terms changed (TERMS-VERSION 2): an ON record from terms v1 is turned OFF without a terminal"
CP_T2="$SB/cp-terms2"; rm -rf "$CP_T2"; cp -r "$_tree" "$CP_T2"; printf '2\n' > "$CP_T2/bundle/TERMS-VERSION"
use_home "$BASE"
printf 'enabled=1 terms_version=1 decided_at=2026-01-01T00:00:00Z framework_version=1.9.0 method=interactive\n' > "$_CPR"
_o=$(CP_TREE="$CP_T2" _inst_cp --force --accept-terms --no-verify); _rc=$?
is "  rc 0, terms v2 accepted" "$_rc/$(gov_record_field "$_U/terms-accepted" terms_version)" "0/2"
[ "$_rc" = "0" ] || printf '%s\n' "$_o" | tail -8
is "  record: 0/terms-changed/2" "$(_cpf)" "0/terms-changed/2"
has "  the line says it was ON and why it is OFF now" "$_o" "Push at session close was ON under terms v1; the terms changed (v2), so it is OFF until you turn it on again yourself, in your own terminal: bash ~/.claude/hooks/governance/close-push.sh --enable"
has "  the A.8 push line: OFF" "$_o" "$CP_SUM_OFF"
use_home "$BASE"
printf 'enabled=0 terms_version=1 decided_at=2026-01-01T00:00:00Z framework_version=1.9.0 method=declined\n' > "$_CPR"
_o=$(CP_TREE="$CP_T2" _inst_cp --force --accept-terms --no-verify)
is "  an OFF record from terms v1: also re-recorded 0/terms-changed/2" "$(_cpf)" "0/terms-changed/2"
hasnt "  ... without claiming it was ON" "$_o" "was ON under terms"
use_home "$BASE"
printf 'enabled=1 terms_version=1 decided_at=2026-01-01T00:00:00Z framework_version=1.9.0 method=interactive\n' > "$_CPR"
_cpb=$(sha256sum < "$_CPR")
_o=$(_inst_cp --force --no-verify); _rc=$?
is "  control: the SAME ON record under unchanged terms (v1) is kept: rc 0, bytes unchanged" "$_rc/$([ "$(sha256sum < "$_CPR")" = "$_cpb" ] && echo same || echo changed)" "0/same"
has "  ... and reported as the user's choice" "$_o" "Push at session close: ON (your choice, recorded 2026-01-01)."
has "  ... with the A.8 line ON since that date" "$_o" "  Push at session close:  ON (since 2026-01-01)"
hasnt "  ... no terms-changed line" "$_o" "the terms changed"

echo "  (g) --uninstall keeps both records, and says truthfully what it removed"
rm -rf "$H"; cp -r "$CP_ON_HOME" "$H"
printf '#!/bin/sh\n# the user own hook\n' > "$H/.claude/hooks/my-own-hook.sh"
node -e 'const f=process.argv[1],fs=require("fs"),s=JSON.parse(fs.readFileSync(f,"utf8"));s.hooks=s.hooks||{};(s.hooks.Notification=s.hooks.Notification||[]).push({hooks:[{type:"command",command:"echo mine"}]});fs.writeFileSync(f,JSON.stringify(s,null,2)+"\n")' "$H/.claude/settings.json"
_tb=$(sha256sum < "$_U/terms-accepted"); _cpb=$(sha256sum < "$_CPR")
_o=$(_inst_cp --uninstall); _rc=$?
is "  rc 0, hooks gone" "$_rc/$([ -e "$H/.claude/hooks/governance/close-push.sh" ] && echo present || echo gone)" "0/gone"
is "  terms-accepted and close-push kept byte for byte" "$([ "$(sha256sum < "$_U/terms-accepted")" = "$_tb" ] && echo same || echo changed)/$([ "$(sha256sum < "$_CPR")" = "$_cpb" ] && echo same || echo changed)" "same/same"
has "  the hooks line says the WHOLE directory, the user's own hooks included" "$_o" "Removed ~/.claude/hooks/ - the whole directory, including any hook of your own (backed up at "
has "  the settings line says the ENTIRE hooks section, the user's entries included" "$_o" "Hooks section removed from settings.json - every entry under \"hooks\", including ones you added (backed up at "
_ubd=$(printf '%s\n' "$_o" | sed -n 's/.*Backup directory: \(.*\)$/\1/p' | head -1)
is "  ... and both are TRUE: the user's hook is gone and in the backup; the user's entry is gone and in the backup" \
   "$([ -e "$H/.claude/hooks/my-own-hook.sh" ] && echo present || echo gone)/$([ -f "$_ubd/hooks/my-own-hook.sh" ] && echo backed || echo lost)/$(node -e 'const s=require(process.argv[1]);console.log(s.hooks?"hooks-key":"no-hooks-key")' "$H/.claude/settings.json")/$(grep -c 'echo mine' "$_ubd/settings.json" 2>/dev/null)" \
   "gone/backed/no-hooks-key/1"
_o=$(_inst_cp --accept-terms --no-verify); _rc=$?
is "  a re-install after --uninstall keeps the ON choice (never re-asked)" "$_rc/$(_cpf)" "0/1/interactive/1"
has "  ... and says so" "$_o" "Push at session close: ON (your choice, recorded $_today)."

echo "  (h) verify.sh checks the record, both directions"
rm -rf "$H"; cp -r "$CP_ON_HOME" "$H"
_v=$(HOME="$H" bash "$_tree/verify.sh" </dev/null 2>&1)
is "  record present: the check passes" "$(printf '%s\n' "$_v" | grep 'push-at-close choice recorded' | grep -c '✓')" "1"
rm -f "$_CPR"
_v=$(HOME="$H" bash "$_tree/verify.sh" </dev/null 2>&1); _rc=$?
is "  record missing: the check fails and verify.sh exits 1" "$(printf '%s\n' "$_v" | grep 'push-at-close choice recorded' | grep -c '✗')/$_rc" "1/1"

echo "  (i) --uninstall when the backup cannot be made: exit 1, nothing removed (finding 12)"
rm -rf "$H"; cp -r "$CP_ON_HOME" "$H"
# BACKUP_DIR is backups/governance-<local time to the second>: plant a FILE named hooks in every
# such directory for the next 3 minutes, so `cp -r hooks $BACKUP_DIR/hooks` cannot succeed.
_t0=$(date +%s); _i=0
while [ "$_i" -le 180 ]; do
  _bd="$H/.claude/backups/governance-$(date -d "@$((_t0 + _i))" '+%Y%m%d-%H%M%S' 2>/dev/null || date -r "$((_t0 + _i))" '+%Y%m%d-%H%M%S')"
  mkdir -p "$_bd"; : > "$_bd/hooks"; _i=$((_i + 1))
done
_before=$(treehash); _sb=$(sha256sum < "$H/.claude/settings.json")
_o=$(_inst_cp --uninstall); _rc=$?
is "  rc 1" "$_rc" "1"
has "  it says the backup failed and nothing was removed" "$_o" "Could not back up ~/.claude/hooks/ to "
has "  ... in those words" "$_o" "- nothing was removed."
hasnt "  no removal line" "$_o" "Removed ~/.claude/hooks/"
is "  hooks, docs, settings.json, version marker, update state all still there; lock free" \
   "$([ -e "$H/.claude/hooks/governance/close-push.sh" ] && echo hooks || echo GONE)/$([ -d "$H/.claude/docs" ] && echo docs || echo GONE)/$([ "$(sha256sum < "$H/.claude/settings.json")" = "$_sb" ] && echo settings || echo CHANGED)/$([ -f "$H/.claude/.governance-version" ] && echo marker || echo GONE)/$([ -f "$_U/install-mode" ] && echo state || echo GONE)/$([ -d "$_U/lock.d" ] && echo held || echo free)" \
   "hooks/docs/settings/marker/state/free"
is "  the whole tree is unchanged" "$([ "$(treehash)" = "$_before" ] && echo same || echo changed)" "same"
rm -rf "$H/.claude/backups"
_o=$(_inst_cp --uninstall); _rc=$?
is "  control: the same HOME with a writable backup path uninstalls (rc 0, hooks gone)" \
   "$_rc/$([ -e "$H/.claude/hooks/governance/close-push.sh" ] && echo present || echo gone)" "0/gone"

echo "  (j) the installer's own output claims no automatic update (D7, finding 4)"
is "  every 'automatic update' mention in install.sh says it is not in this version" \
   "$(grep -ci 'automatic update' "$_tree/install.sh")" "$(grep -c 'not in this version' "$_tree/install.sh")"
is "  control: the count is not vacuous (the A.8 line is there)" "$(grep -c "Automatic updates:      not in this version" "$_tree/install.sh")" "1"
hasnt "  the snapshot line names the manual path" "$(grep 'normal between releases' "$_tree/install.sh")" "Automatic updates will replace"
has "  ... in these words" "$(grep 'normal between releases' "$_tree/install.sh")" "The next release you install by hand (gov-update.sh --fetch/--apply, or git pull + install.sh --force) replaces it."
CLOSEPUSH_REACHED_END=1
fi
# Round 3 (2026-10-02, measured): an expansion-time parse error inside this section abandoned the
# rest of the `if want CLOSEPUSH` block silently, and the suite still ended pass=N fail=0. The end
# of the block must be reached, or that is a failure.
if want CLOSEPUSH; then
  is "[CLOSEPUSH] ran to its last assertion (nothing abandoned mid-section)" "${CLOSEPUSH_REACHED_END:-0}" "1"
fi

# ── step 9: the pre-push VERSION/tag rule ─────────────────────────────────────────────────────
if want PREPUSH; then
echo "(${SECONDS}s) [PREPUSH] a VERSION bump without its tag cannot be pushed"
if [ -f "$REPO/.githooks/pre-push" ]; then
  _R="$SB/pp"; rm -rf "$_R"; mkdir -p "$_R"
  git init -q --bare "$_R/remote.git"
  git init -q "$_R/w"; cp -r "$REPO/.githooks" "$_R/w/.githooks"
  gw() { git -C "$_R/w" -c user.name=t -c user.email=nobody "$@"; }
  gw config core.hooksPath .githooks
  gw remote add origin "$_R/remote.git"
  mkdir -p "$_R/w/bundle"; printf '1.0.0\n' > "$_R/w/bundle/VERSION"; printf 'a\n' > "$_R/w/notes.txt"
  gw add -A; gw commit -qm one; gw branch -M master; gw tag v1.0.0
  gw push -q origin master v1.0.0 >/dev/null 2>&1; is "setup: first push with its tag passes" "$?" "0"
  printf 'b\n' >> "$_R/w/notes.txt"; gw commit -qam two
  gw push -q origin master >/dev/null 2>&1; is "a push that does not touch VERSION passes" "$?" "0"
  printf '1.1.0\n' > "$_R/w/bundle/VERSION"; gw commit -qam three
  _o=$(gw push origin master 2>&1); _rc=$?
  is "VERSION 1.1.0 without tag v1.1.0 is refused" "$([ "$_rc" -ne 0 ] && echo refused || echo pushed)" "refused"
  has "  with the reason" "$_o" "no local tag v1.1.0"
  gw tag v1.1.0
  _o=$(gw push origin master 2>&1); _rc=$?
  is "the tag exists LOCALLY but is not pushed -> refused" "$([ "$_rc" -ne 0 ] && echo refused || echo pushed)" "refused"
  has "  saying it must reach the remote" "$_o" "neither in this push nor on the remote"
  _o=$(GOV_GIT_PII_GATE=0 gw push origin master 2>&1); _rc=$?
  is "the PII kill switch does NOT switch this gate off" "$([ "$_rc" -ne 0 ] && echo refused || echo pushed)" "refused"
  gw push -q origin master v1.1.0 >/dev/null 2>&1; is "with the tag in the same push it passes" "$?" "0"
  printf '1.2.0\n' > "$_R/w/bundle/VERSION"; gw commit -qam four; gw tag v1.2.0
  gw push -q origin v1.2.0 >/dev/null 2>&1
  gw push -q origin master >/dev/null 2>&1; is "a tag pushed EARLIER (already on the remote) passes" "$?" "0"
  # The remote tip is a commit this clone has never seen (someone else pushed; no fetch here). The
  # range cannot be computed, so the gate must assume VERSION changed — fail CLOSED.
  # Branch named explicitly: with init.defaultBranch=main the bare remote's HEAD points nowhere,
  # the clone has no branch, and this case would silently fall back to the ordinary diff check.
  git -C "$_R/remote.git" symbolic-ref HEAD refs/heads/master
  git clone -q -b master "$_R/remote.git" "$_R/w2" 2>/dev/null
  printf 'c\n' >> "$_R/w2/notes.txt"
  git -C "$_R/w2" -c user.name=t -c user.email=nobody commit -qam elsewhere
  git -C "$_R/w2" push -q origin master 2>/dev/null
  _tip=$(git -C "$_R/remote.git" rev-parse master 2>/dev/null)
  is "precondition: the remote tip moved to a commit made elsewhere" "$_tip" "$(git -C "$_R/w2" rev-parse HEAD 2>/dev/null)"
  is "precondition: this clone has never seen that commit" "$(git -C "$_R/w" cat-file -e "$_tip^{commit}" 2>/dev/null && echo seen || echo unseen)" "unseen"
  printf '1.3.0\n' > "$_R/w/bundle/VERSION"; gw commit -qam five
  _o=$(gw push --force origin master 2>&1); _rc=$?
  is "unknown remote tip + VERSION 1.3.0 without its tag -> refused (fail closed)" "$([ "$_rc" -ne 0 ] && echo refused || echo pushed)" "refused"
  has "  with the reason" "$_o" "no local tag v1.3.0"
else
  bad "no .githooks/pre-push in $REPO - the rule cannot be tested"
fi
fi

# ── review round 1 (2026-09-25): cases for every finding that was a real defect ───────────────
if want PRESESSION; then
echo "(${SECONDS}s) [PRESESSION] pre-session.sh REPORTS a staged release and never applies or downloads one (2026-09-26/30)"
# SessionStart blocks Claude Code's start-up and the VS Code extension fails it at 60 s, so the hook
# only prints a line; 2.0.0 has no automatic update, so the apply runs only by hand.
# GOV_NO_STDIN=0: the suite exports 1 for the tools it runs, but a HOOK must read its payload.
ps_run() { HOME="$H" GOV_NO_STDIN=0 GOV_UPDATE_SKIP_DEEP_VERIFY=1 bash "$H/.claude/hooks/governance/pre-session.sh" <<< "$1" 2>&1; }
use_home "$STAGED"; printf '2.0.0\n' > "$H/.claude/logs/.governance-latest"
mkdir -p "$H/.claude/logs/sessions/sess-a"; touch "$H/.claude/logs/sessions/sess-a/f"
_t0=$SECONDS
_o=$(ps_run '{"cwd":"/tmp","session_id":"sess-a","source":"startup"}')
hasnt "source=startup, READY staged: NOT applied by the hook" "$_o" "Applied v2.0.0"
is "  marker unchanged" "$(marker)" "1.9.0"
has "  the hook names the staged version, your --fetch, and that nothing installs on its own" "$_o" "[GOVERNANCE UPDATE] v2.0.0 is downloaded and verified (your --fetch); nothing installs on its own. To install: close every Claude Code session, then in your own terminal run  bash ~/.claude/hooks/governance/gov-update.sh --apply --force-live"
has "  ... and the command that installs it" "$_o" "gov-update.sh --apply --force-live"
hasnt "  ... and no automatic-install promise (2.0.0 has none)" "$_o" "installs itself"
is "  it returned inside the 10 s SessionStart budget" "$([ $((SECONDS - _t0)) -lt 10 ] && echo yes || echo "no ($((SECONDS - _t0)) s)")" "yes"
_o=$(ps_run '{"cwd":"/tmp","session_id":"sess-a","source":"compact"}')
hasnt "source=compact: not applied either" "$_o" "Applied v2.0.0"
_o=$(HOME="$H" GOVERNANCE_UPDATE_CHECK=0 GOV_NO_STDIN=0 bash "$H/.claude/hooks/governance/pre-session.sh" <<< '{"cwd":"/tmp","session_id":"sess-a","source":"startup"}' 2>&1)
hasnt "  update check OFF: the READY line is silent" "$_o" "is downloaded and verified (your --fetch)"
# A human runs the command from a terminal: no session id, and the session that printed the line
# is still fresh on disk. That is why the line names --force-live.
touch "$H/.claude/logs/sessions/sess-a/f"
_o=$(SID=terminal upd --apply)
hasnt "a plain --apply beside the fresh session dir defers (why the line says --force-live)" "$_o" "Applied v2.0.0"
_o=$(SID=terminal upd --apply --force-live)
has "control: the command the line names applies it" "$_o" "Applied v2.0.0"
is "  marker 2.0.0" "$(marker)" "2.0.0"
fi

# ps_behind [VAR=value ...]: a machine BEHIND the published version (1.9.0 installed, 2.0.0 cached
# as published and fresh, so the hook itself needs no network) starts a session with a stub curl
# that records every call; the hook's output -> PSB_OUT. psb_fetched: a fetch was attempted
# (fetch-attempts-* written, or curl called) - the only way a download can begin. [M10] reuses it.
mkdir -p "$SB/stubcurl"
printf '#!/bin/sh\necho "$@" >> "%s/curl-called"\nprintf 000\nexit 7\n' "$SB" > "$SB/stubcurl/curl"; chmod +x "$SB/stubcurl/curl"
ps_behind() {
  use_home "$BASE"; printf '2.0.0\n' > "$H/.claude/logs/.governance-latest"; rm -f "$SB/curl-called"
  if [ -n "${PSB_SED:-}" ]; then   # [M10]: the installed pre-session.sh, mutated in place
    sed "$PSB_SED" "$H/.claude/hooks/governance/pre-session.sh" > "$SB/psb.tmp" && cat "$SB/psb.tmp" > "$H/.claude/hooks/governance/pre-session.sh"
  fi
  PSB_OUT=$(env HOME="$H" GOV_NO_STDIN=0 PATH="$SB/stubcurl:$PATH" "$@" bash "$H/.claude/hooks/governance/pre-session.sh" \
              <<< '{"cwd":"/tmp","session_id":"sess-n","source":"startup"}' 2>&1 | cat)
}
psb_fetched() { ls "$H/.claude/.governance-update"/fetch-attempts-* >/dev/null 2>&1 || [ -f "$SB/curl-called" ]; }
if want PRESESSION; then
echo "  (a machine behind the published version: the hook tells, and spawns no --fetch)"
for _pe in "" GOV_AUTO_UPDATE=1; do
  ps_behind ${_pe:+"$_pe"}
  has "${_pe:-no switch}: the legacy manual line" "$PSB_OUT" "Context Governance v2.0.0 is published; this machine has v1.9.0."
  has "  and the signed manual path, run by hand" "$PSB_OUT" "Signed manual update: bash ~/.claude/hooks/governance/gov-update.sh --fetch 2.0.0"
  # A detached child starts within ~1 s idle; 6 s leaves room for a loaded machine ([M10] measures it).
  wait_until 6 'psb_fetched'
  is "  pre-session spawned no fetch (fetch-attempts-* absent, stub curl not called)" "$(psb_fetched && echo spawned || echo none)" "none"
done
fi

if want PRESESSION && [ -f "$SB/stubmv/mv" ]; then
echo "  (an interrupted apply: pre-session starts the ROLLBACK detached and returns - even with GOVERNANCE_UPDATE_CHECK=0)"
# kill_mid_apply: an apply killed after 5 swapped files -> a half-applied tree with its journal.
kill_mid_apply() {
  use_home "$STAGED"; KMA_BEFORE=$(treehash); rm -f "$SB/mvcount"
  HOME="$H" GOV_UPDATE_SKIP_DEEP_VERIFY=1 GOV_SESSION_SOURCE=startup GOV_SESSION_ID=test-self PATH="$SB/stubmv:$PATH" \
    bash "$H/.claude/hooks/governance/gov-update.sh" --apply </dev/null >/dev/null 2>&1 &
  local ap=$! w=0
  while [ "$(_nswap)" -lt 5 ] && [ "$w" -lt 240 ]; do sleep 0.5; w=$((w + 1)); done
  kill -9 "$ap" 2>/dev/null; wait "$ap" 2>/dev/null; sleep 1
  [ -f "$SB/stub-sleeper.pid" ] && kill "$(cat "$SB/stub-sleeper.pid")" 2>/dev/null
}
kill_mid_apply
# (Not "the tree differs": the first files swapped can be byte-identical between the two versions.)
is "precondition: an apply died mid-swap and left its journal" "$([ -f "$H/.claude/.governance-update/APPLYING" ] && [ "$(_nswap)" -ge 5 ] && echo yes || echo no)" "yes"
_t0=$(date +%s%3N)
_o=$(HOME="$H" GOV_NO_STDIN=0 GOVERNANCE_UPDATE_CHECK=0 GOV_UPDATE_SKIP_DEEP_VERIFY=1 bash "$H/.claude/hooks/governance/pre-session.sh" <<< '{"cwd":"/tmp","session_id":"sess-a","source":"startup"}' 2>&1 | cat)
_dt=$(( $(date +%s%3N) - _t0 ))
has "interrupted apply: rollback started in the background, with the update check OFF" "$_o" "it is being rolled back to its backup in the background now"
is "  the hook returned inside the 10 s budget (stdout closed; the restore alone is ~17 s)" "$([ "$_dt" -lt 10000 ] && echo yes || echo "no (${_dt} ms)")" "yes"
wait_until 120 '[ ! -f "$H/.claude/.governance-update/APPLYING" ] && [ "$(treehash)" = "$KMA_BEFORE" ]'
is "  within 120 s the tree is byte-identical to before" "$(treehash)" "$KMA_BEFORE"
wait_until 20 'grep -q "could NOT be applied (interrupted)" "$H/.claude/.governance-update/REPORT" 2>/dev/null'
has "  REPORT says so" "$(cat "$H/.claude/.governance-update/REPORT" 2>/dev/null)" "could NOT be applied (interrupted)"
wait_until 10 '[ ! -d "$H/.claude/.governance-update/lock.d" ]'
is "  the recovery child restored and stopped: marker 1.9.0, READY kept for the human" "$(marker)/$([ -f "$H/.claude/.governance-update/READY" ] && echo kept || echo gone)" "1.9.0/kept"
hasnt "  and it applied nothing" "$(cat "$H/.claude/.governance-update/REPORT" 2>/dev/null)" "Applied v"
_o=$(ps_run '{"cwd":"/tmp","session_id":"sess-b","source":"startup"}')
has "the next start prints the REPORT line" "$_o" "could NOT be applied (interrupted)"
is "  and consumes it (emptied in place)" "$([ -s "$H/.claude/.governance-update/REPORT" ] && echo kept || echo gone)" "gone"
_o=$(ps_run '{"cwd":"/tmp","session_id":"sess-b","source":"startup"}')
hasnt "  a second start prints it no more" "$_o" "could NOT be applied (interrupted)"
fi

if want PRESESSION; then
echo "  (the recovery spawn: REPORT bounded, never written through a symlink)"
# A journal from a process that died BEFORE its backup completed: the recovery child only clears it
# (nothing was swapped), fast. Its disappearance is the proof that a child ran.
_dead_journal() { printf 'version=2.0.0\nfrom=1.9.0\nstarted=x\nbackup=x\npid=999999\n' > "$H/.claude/.governance-update/APPLYING"; }
use_home "$STAGED"; _dead_journal
for _i in $(seq 1 80); do echo "[GOVERNANCE UPDATE] old line $_i"; done > "$H/.claude/.governance-update/REPORT"
HOME="$H" bash "$H/.claude/hooks/governance/gov-update.sh" --recover-detached </dev/null >/dev/null 2>&1
wait_until 60 '[ ! -f "$H/.claude/.governance-update/APPLYING" ] && [ ! -d "$H/.claude/.governance-update/lock.d" ]'
is "the recovery child ran (the dead journal is cleared)" "$([ -f "$H/.claude/.governance-update/APPLYING" ] && echo kept || echo cleared)" "cleared"
is "  REPORT bounded to its last 50 lines before the child appends" "$(grep -c 'old line' "$H/.claude/.governance-update/REPORT")" "50"
is "  the newest line is kept" "$(grep -c 'old line 80$' "$H/.claude/.governance-update/REPORT")" "1"
is "  and it applied nothing (marker 1.9.0, READY kept)" "$(marker)/$([ -f "$H/.claude/.governance-update/READY" ] && echo kept || echo gone)" "1.9.0/kept"
use_home "$STAGED"; _dead_journal; rm -f "$SB/elsewhere"
ln -s "$SB/elsewhere" "$H/.claude/.governance-update/REPORT" 2>/dev/null
if [ -L "$H/.claude/.governance-update/REPORT" ]; then
  HOME="$H" bash "$H/.claude/hooks/governance/gov-update.sh" --recover-detached </dev/null >/dev/null 2>&1
  sleep 5
  is "REPORT as a symlink: refused, nothing started, nothing written through it" "$([ -e "$SB/elsewhere" ] && echo written || echo clean)/$([ -f "$H/.claude/.governance-update/APPLYING" ] && echo not-started || echo started)" "clean/not-started"
  has "  logged" "$(cat "$H/.claude/logs/governance-update.log" 2>/dev/null)" "REPORT is a symlink - refusing to write through it"
else
  echo "  (no real symlinks on this filesystem - symlink case skipped)"
fi
fi

if want BUDGET; then
echo "(${SECONDS}s) [BUDGET] an apply that cannot finish in time aborts before changing anything"
use_home "$STAGED"; _before=$(treehash)
_o=$(GOV_UPDATE_APPLY_BUDGET=1 upd --apply)
has "too busy -> not applied" "$_o" "too busy"
is "  tree unchanged" "$(treehash)" "$_before"
is "  READY kept for the next start" "$([ -f "$H/.claude/.governance-update/READY" ] && echo kept || echo gone)" "kept"
GOV_UPDATE_APPLY_BUDGET=1 upd --apply >/dev/null; _o=$(GOV_UPDATE_APPLY_BUDGET=1 upd --apply)
has "after 3 in a row it names the manual command" "$_o" "gov-update.sh --apply"
_o=$(upd --apply)
has "with a normal budget it then applies" "$_o" "Applied v2.0.0"
fi

if want EXTRA; then
echo "(${SECONDS}s) [EXTRA] a signed manifest beside an EXTRA hook is not labelled a signed release"
_X="$SB/extra-tree"; rm -rf "$_X" "$SB/extra-home"; cp -r "$SB/rel/base/claude-code-governance-1.9.0" "$_X"
printf '#!/usr/bin/env bash\necho extra\n' > "$_X/bundle/hooks/governance/zz-extra.sh"
mkdir -p "$SB/extra-home"; nonce_home "$SB/extra-home"
_o=$(HOME="$SB/extra-home" bash "$_X/install.sh" --accept-terms --no-verify </dev/null 2>&1)
has "labelled an unreleased snapshot" "$_o" "UNRELEASED master snapshot"
hasnt "  not a signed release" "$_o" "Installing signed release"
is "  the recorded manifest is synthesized (unsigned=1)" "$(grep -c '^unsigned=1' "$SB/extra-home/.claude/.governance-update/installed.manifest")" "1"
# P4: the synthesized header states the terms version, so gov_installed_terms_version always has one.
is "  the synthesized manifest carries terms_version=1 in its header" \
   "$(awk '/^\[files\]$/ { exit } /^terms_version=/' "$SB/extra-home/.claude/.governance-update/installed.manifest")" "terms_version=1"
# Control: a pre-2.0 tree (no TERMS-VERSION) synthesizes no terms_version line.
_X0="$SB/extra-tree0"; rm -rf "$_X0" "$SB/extra-home0"; cp -r "$_X" "$_X0"; rm -f "$_X0/bundle/TERMS-VERSION"
mkdir -p "$SB/extra-home0"
HOME="$SB/extra-home0" bash "$_X0/install.sh" --no-verify </dev/null >/dev/null 2>&1
is "  control: a bundle without TERMS-VERSION writes no terms_version= header line" \
   "$(grep -c '^unsigned=1' "$SB/extra-home0/.claude/.governance-update/installed.manifest" 2>/dev/null)/$(grep -c '^terms_version=' "$SB/extra-home0/.claude/.governance-update/installed.manifest" 2>/dev/null)" "1/0"
fi

if want RACE; then
echo "(${SECONDS}s) [RACE] install.sh refuses while an update is running"
use_home "$STAGED"
sleep 60 >/dev/null 2>&1 </dev/null & LIVE_PID=$!
printf 'version=2.0.0\nfrom=1.9.0\nstarted=x\nbackup=x\npid=%s\n' "$LIVE_PID" > "$H/.claude/.governance-update/APPLYING"
_before=$(treehash)
_o=$(HOME="$H" bash "$SB/rel/base/claude-code-governance-1.9.0/install.sh" --accept-terms --no-verify --force </dev/null 2>&1); _rc=$?
is "refused (exit 1)" "$_rc" "1"
has "  naming the running update" "$_o" "An update is running right now (gov-update.sh --fetch/--apply/--rollback, or the restore of an interrupted apply; pid $LIVE_PID,"
hasnt "  not calling it automatic (there is none)" "$_o" "automatic update"
is "  nothing changed" "$(treehash)" "$_before"
_o=$(HOME="$H" bash "$SB/rel/base/claude-code-governance-1.9.0/install.sh" --uninstall </dev/null 2>&1); _rc=$?
kill "$LIVE_PID" 2>/dev/null; LIVE_PID=""
is "--uninstall is refused too while it runs" "$_rc" "1"
is "  nothing removed" "$(treehash)" "$_before"
is "  the apply's journal is still there" "$([ -f "$H/.claude/.governance-update/APPLYING" ] && echo kept || echo removed)" "kept"
# A lock directory whose info is not written YET is an update being taken, not a dead one.
use_home "$STAGED"; mkdir -p "$H/.claude/.governance-update/lock.d"; _before=$(treehash)
_o=$(HOME="$H" bash "$SB/rel/base/claude-code-governance-1.9.0/install.sh" --accept-terms --no-verify --force </dev/null 2>&1); _rc=$?
is "a lock being taken (no pid yet) -> the install refuses" "$_rc" "1"
has "  saying so" "$_o" "being written"
is "  nothing changed" "$(treehash)" "$_before"
touch -d '2 hours ago' "$H/.claude/.governance-update/lock.d"
_o=$(HOME="$H" bash "$SB/rel/base/claude-code-governance-1.9.0/install.sh" --accept-terms --no-verify --force </dev/null 2>&1); _rc=$?
is "the same lock 2 h old (never completed) is stale -> the install proceeds" "$_rc" "0"
is "  and releases the lock when done" "$([ -d "$H/.claude/.governance-update/lock.d" ] && echo held || echo free)" "free"
is "  and leaves the OFF push-at-close record (kept from the baseline)" \
   "$(gov_record_field "$H/.claude/.governance-update/close-push" enabled)/$(gov_record_field "$H/.claude/.governance-update/close-push" method)" "0/default-non-interactive"
fi

if want ROLLBACK; then
echo "(${SECONDS}s) [ROLLBACK] manual --rollback: exact, undoable, and refuses a stale backup"
use_home "$BASE"; _base_hash=$(treehash)
use_home "$STAGED"; upd --apply >/dev/null
is "precondition: 2.0.0 applied" "$(marker)" "2.0.0"
_o=$(HOME="$H" bash "$H/.claude/hooks/governance/gov-update.sh" --rollback </dev/null 2>&1)
has "rolled back" "$_o" "Rolled back to v1.9.0"
is "tree equals the 1.9.0 install exactly" "$(treehash)" "$_base_hash"
is "HALT reason=manual-rollback (it will not re-apply)" "$(halt_reason 2.0.0)" "manual-rollback"
is "the state before the rollback was saved" "$(ls -1d "$H/.claude/backups"/*pre-rollback 2>/dev/null | grep -c .)" "1"
_o=$(HOME="$H" bash "$H/.claude/hooks/governance/gov-update.sh" --rollback </dev/null 2>&1); _rc=$?
is "a second --rollback (backup of 2.0.0, 1.9.0 installed) is refused" "$_rc" "1"
has "  saying why" "$_o" "Restoring it would discard everything since"
is "  and changes nothing" "$(treehash)" "$_base_hash"
fi

if want BOMB; then
echo "(${SECONDS}s) [BOMB] an archive that unpacks past the cap is refused before extraction"
_B="$SB/bomb"; rm -rf "$_B"; mkdir -p "$_B/claude-code-governance-2.0.0" "$SB/remote-bomb"
head -c 120000000 /dev/zero > "$_B/claude-code-governance-2.0.0/big" 2>/dev/null
(cd "$_B" && tar -czf "$SB/remote-bomb/v2.0.0.tar.gz" claude-code-governance-2.0.0); rm -rf "$_B"
is "precondition: the bomb is small compressed" "$([ "$(wc -c < "$SB/remote-bomb/v2.0.0.tar.gz")" -lt 2000000 ] && echo yes || echo no)" "yes"
use_home "$BASE"; URL=$(url_of "$SB/remote-bomb")
upd --fetch 2.0.0
is "HALT reason=archive" "$(halt_reason 2.0.0)" "archive"
has "  because of the unpacked size" "$(cat "$H/.claude/.governance-update/HALT-2.0.0")" "unpacks to more than"
is "  nothing was extracted" "$(find "$H/.claude/.governance-update/staged" -name big 2>/dev/null | grep -c .)" "0"
echo "  (a SPARSE member: tiny stream, huge declared size)"
_B="$SB/sparse"; rm -rf "$_B"; mkdir -p "$_B/claude-code-governance-2.0.0" "$SB/remote-sparse"
if (cd "$_B" && truncate -s 209715201 claude-code-governance-2.0.0/big 2>/dev/null && tar -S -czf "$SB/remote-sparse/v2.0.0.tar.gz" claude-code-governance-2.0.0 2>/dev/null); then
  rm -rf "$_B"
  use_home "$BASE"; URL=$(url_of "$SB/remote-sparse")
  upd --fetch 2.0.0
  has "a sparse member declaring 200 MB is refused" "$(cat "$H/.claude/.governance-update/HALT-2.0.0" 2>/dev/null)" "members declare"
  # The same member under an owner NAME containing a space, which once shifted the size column.
  _B="$SB/sparse2"; rm -rf "$_B"; mkdir -p "$_B/claude-code-governance-2.0.0" "$SB/remote-sparse2"
  (cd "$_B" && truncate -s 209715201 claude-code-governance-2.0.0/big && tar -S --owner='a b:0' -czf "$SB/remote-sparse2/v2.0.0.tar.gz" claude-code-governance-2.0.0 2>/dev/null); rm -rf "$_B"
  use_home "$BASE"; URL=$(url_of "$SB/remote-sparse2")
  upd --fetch 2.0.0
  has "  ... also under an owner name with a space" "$(cat "$H/.claude/.governance-update/HALT-2.0.0" 2>/dev/null)" "members declare"
else
  bad "could not build a sparse archive here (truncate/tar -S) - the sparse cap is untested"
fi
URL=$(url_of "$SB/remote-good")
fi

if want NOBASE; then
echo "(${SECONDS}s) [NOBASE] a machine with no installed.hashes still applies (baseline written before verify.sh)"
use_home "$STAGED"; rm -f "$H/.claude/.governance-update/installed.hashes"
_o=$(upd --apply)
has "the no-baseline note" "$_o" "no local-modification baseline"
has "applied" "$_o" "Applied v2.0.0"
is "a baseline exists afterwards" "$([ -s "$H/.claude/.governance-update/installed.hashes" ] && echo yes || echo no)" "yes"
fi

if want COLLIDE; then
echo "(${SECONDS}s) [COLLIDE] a user's own file at a path the release claims for the first time"
use_home "$STAGED"; mkdir -p "$H/.claude/skills/test-new-skill"
printf 'my own skill\n' > "$H/.claude/skills/test-new-skill/SKILL.md"; _before=$(treehash)
_o=$(upd --apply)
has "refused, naming it" "$_o" "skills/test-new-skill/SKILL.md"
is "tree unchanged" "$(treehash)" "$_before"
cp "$SB/rel/good/claude-code-governance-2.0.0/bundle/skills/test-new-skill/SKILL.md" "$H/.claude/skills/test-new-skill/SKILL.md"
_o=$(upd --apply)
has "an IDENTICAL file at that path is not a collision" "$_o" "Applied v2.0.0"
fi

if want EBUSY; then
echo "(${SECONDS}s) [EBUSY] settings-merge.js refuses a settings.json it cannot read (not ENOENT)"
_E="$SB/ebusy"; rm -rf "$_E"; mkdir -p "$_E/settings.json"
node "$GOV_DIR/settings-merge.js" --template "$SRC/bundle/settings-hooks.json" --settings "$_E/settings.json" >/dev/null 2>&1; _rc=$?
is "an unreadable settings.json (EISDIR) -> exit 1" "$_rc" "1"
is "  and nothing was written in its place" "$([ -d "$_E/settings.json" ] && echo untouched || echo replaced)" "untouched"
node "$GOV_DIR/settings-merge.js" --template "$SRC/bundle/settings-hooks.json" --settings "$_E/absent.json" >/dev/null 2>&1; _rc=$?
is "a MISSING settings.json is created (ENOENT is the only 'empty')" "$_rc/$([ -s "$_E/absent.json" ] && echo created || echo none)" "0/created"
fi

if want RELEASE; then
echo "(${SECONDS}s) [RELEASE] gov-release.sh end to end against a local remote (stub gh)"
# 2026-09-30 (TG1: legal T7, S3, C6, C11): the repo, the keys, the remote and every stand-in live
# INSIDE the sandbox HOME, because under the suite's nonce override gov-release.sh refuses anything
# outside it. The signer's C6 answers come from a file (no pty here: `script` is absent on Git for
# Windows), which gov-release.sh honours only under that override.
RH="$SB/relhome"; RR="$RH/relrepo"; RREM="$RH/relremote.git"; rm -rf "$RH"
cp -r "$BASE" "$RH"; nonce_home "$RH"
mkdir -p "$RH/keys" "$RH/stubs"; cp "$SB/keys/k1" "$SB/keys/k1.pub" "$SB/keys/k2" "$SB/keys/k2.pub" "$RH/keys/"
git init -q --bare "$RREM"
cp -r "$SRC" "$RR"; printf '1.9.0\n' > "$RR/bundle/VERSION"
_fp1=$(ssh-keygen -lf "$SB/keys/k1.pub" | awk '{print $2}')
_fpreal=$(grep -o 'SHA256:[A-Za-z0-9+/]\{43\}' "$RR/README.md" | head -1)
[ -n "$_fpreal" ] && sed -i "s|$_fpreal|$_fp1|g" "$RR/README.md"
rg() { git -C "$RR" -c user.name=t -c user.email=nobody -c core.autocrlf=false "$@"; }
rg init -q; rg config user.name t; rg config user.email nobody; rg config core.autocrlf false
rg add -A; rg commit -qm base; rg branch -M master; rg tag v1.9.0
rg remote add origin "$RREM"; rg push -q origin master v1.9.0 2>/dev/null
rm -rf "$RH/.claude/governance-installer"; mkdir -p "$RH/.claude/governance-installer"
cp -r "$RR/bundle" "$RR/install.sh" "$RR/verify.sh" "$RR/README.md" "$RH/.claude/governance-installer/"
printf 'GOV_REPO_PATH=%s\nGOV_RELEASE_KEY=%s\n' "$RR" "$RH/keys/k1" > "$RH/.claude/.governance-local.env"
mkdir -p "$SB/stubgh" "$SB/stubsk"
cat > "$SB/stubgh/gh" <<EOF_GH
#!/bin/sh
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "release create") echo "\$@" > "$SB/gh-called"
    while [ \$# -gt 0 ]; do [ "\$1" = "--notes-file" ] && cat "\$2" > "$SB/gh-notes"; shift; done; exit 0 ;;
esac
exit 0
EOF_GH
chmod +x "$SB/stubgh/gh"
# S3 witness: an ssh-keygen in front of the real one records whether SSH_AUTH_SOCK reached each
# signing call (${SSH_AUTH_SOCK-unset} tells "unset" from "empty").
_real_sk=$(command -v ssh-keygen)
cat > "$SB/stubsk/ssh-keygen" <<EOF_SK
#!/bin/sh
case " \$* " in *" -Y sign "*) printf 'sign sock=[%s] %s\n' "\${SSH_AUTH_SOCK-unset}" "\$*" >> "$SB/sign.log" ;; esac
exec "$_real_sk" "\$@"
EOF_SK
chmod +x "$SB/stubsk/ssh-keygen"
# Stand-ins for tests/test-terms-text.sh (the real one takes ~2 min; it runs once, below). The OK
# one records the root it was given and that root's TERMS-VERSION.
printf '#!/bin/sh\necho "root=$1 terms=$(tr -d "[:space:]" < "$1/bundle/TERMS-VERSION")" >> "%s"\necho "terms-text selftest: pass=1 fail=0"\nexit 0\n' "$RH/stubs/tt-called" > "$RH/stubs/tt-ok.sh"
printf '#!/bin/sh\necho "terms-text selftest: pass=0 fail=1"\nexit 1\n' > "$RH/stubs/tt-bad.sh"
printf 'a=no\nb=no\nc=no\nd=no\n' > "$RH/stubs/answers-no"
printf 'a=no\nb=no\nc=no\nd=yes\n' > "$RH/stubs/answers-d-yes"
printf 'a=no\nb=no\nc=no\n' > "$RH/stubs/answers-short"
# grel [args] - GRA (answers file), GRT (terms-test stand-in; empty = the real one), GRENV (extra
# `env` arguments, word-split on purpose) override the defaults. SSH_ASKPASS is removed because Git
# for Windows exports it in every login shell; [RELEASE] sets it back where it tests the refusal.
grel() { HOME="$RH" PATH="$SB/stubgh:$PATH" GOV_UPDATE_SKIP_DEEP_VERIFY=1 GOV_RELEASE_LOCAL_REHEARSAL=1 \
         GOV_RELEASE_ANSWERS="${GRA-$RH/stubs/answers-no}" GOV_RELEASE_TERMS_TEST="${GRT-$RH/stubs/tt-ok.sh}" \
         env -u SSH_ASKPASS -u SSH_ASKPASS_REQUIRE ${GRENV:-} bash "$RH/.claude/hooks/governance/gov-release.sh" "$@" </dev/null 2>&1; }
_NOMARK="-u CLAUDECODE -u AI_AGENT -u CLAUDE_CODE_ENTRYPOINT"
_relstate() { printf '%s|%s|%s' "$(git -C "$RR" rev-parse HEAD)" "$(git -C "$RR" status --porcelain | wc -l | tr -d ' ')" "$(git -C "$RREM" tag -l | tr '\n' ' ')"; }
_rs0=$(_relstate)

echo "  (T7: only a person releases - each refusal fires before a single check or write)"
_o=$(GOV_CONSENT_SELFTEST= GRENV="CLAUDECODE=1" grel 2.0.0 --dry-run); _rc=$?
is "markers, no sandbox nonce (CLAUDECODE=1) -> exit 1" "$_rc" "1"
has "  it names the AI-agent session" "$_o" "REFUSED - this is an AI-agent session"
hasnt "  and stops before the preconditions" "$_o" "Preconditions:"
_o=$(GOV_CONSENT_SELFTEST= GRENV="$_NOMARK AI_AGENT=claude-code_x_agent" grel 2.0.0 --dry-run)
has "AI_AGENT alone refuses" "$_o" "REFUSED - this is an AI-agent session"
_o=$(GOV_CONSENT_SELFTEST= GRENV="$_NOMARK CLAUDE_CODE_ENTRYPOINT=cli" grel 2.0.0 --dry-run)
has "CLAUDE_CODE_ENTRYPOINT alone refuses" "$_o" "REFUSED - this is an AI-agent session"
_o=$(GOV_CONSENT_SELFTEST= GRA= GRT= GRENV="$_NOMARK" grel 2.0.0 --dry-run); _rc=$?
is "no markers, no nonce, no terminal -> exit 1" "$_rc" "1"
hasnt "  the agent refusal does NOT fire without markers" "$_o" "AI-agent session"
has "  the terminal refusal does" "$_o" "REFUSED - stdin is not a terminal"
_o=$(GOV_CONSENT_SELFTEST= GRENV="$_NOMARK" grel 2.0.0 --dry-run)
has "GOV_RELEASE_ANSWERS without the sandbox nonce refuses" "$_o" "REFUSED - GOV_RELEASE_ANSWERS / GOV_RELEASE_TERMS_TEST are for the test sandbox only"
_o=$(GRA= grel 2.0.0 --dry-run)
has "the sandbox nonce alone does not waive the terminal (no answers file)" "$_o" "REFUSED - stdin is not a terminal"
_o=$(GRENV="SSH_ASKPASS=/x/askpass" grel 2.0.0 --dry-run); _rc=$?
is "SSH_ASKPASS set -> exit 1 (even under the nonce)" "$_rc" "1"
has "  it names SSH_ASKPASS and the fix" "$_o" "unset SSH_ASKPASS SSH_ASKPASS_REQUIRE"
_o=$(GRENV="SSH_ASKPASS_REQUIRE=force" grel 2.0.0 --dry-run)
has "SSH_ASKPASS_REQUIRE alone refuses" "$_o" "SSH_ASKPASS / SSH_ASKPASS_REQUIRE is set"
mkdir -p "$SB/outside-repo"
_o=$(GRENV="GOV_REPO_PATH=$SB/outside-repo" grel 2.0.0 --dry-run)
has "under the nonce, a repository outside the sandbox HOME refuses" "$_o" "'$SB/outside-repo' is not inside the sandbox HOME"
_o=$(GRENV="GOV_RELEASE_KEY=$SB/keys/k1" grel 2.0.0 --dry-run)
has "under the nonce, a key outside the sandbox HOME refuses" "$_o" "'$SB/keys/k1' is not inside the sandbox HOME"
_o=$(GRA="$RH/stubs/answers-short" grel 2.0.0 --dry-run)
has "an unanswered C6 question refuses" "$_o" "REFUSED - question d was not answered yes or no"
is "  none of the refusals changed the repo or the remote" "$(_relstate)" "$_rs0"

# A full precondition pass costs minutes under load (check-no-pii.sh over every bundle file), so
# each full dry run below asserts several checks at once: this one is must-FIRE for the selftest
# verdict, C6 (d=yes, no --terms-bump) and a red terms test; the next is must-NOT-fire for all three.
_o=$(GRA="$RH/stubs/answers-d-yes" GRT="$RH/stubs/tt-bad.sh" grel 2.0.0 --dry-run); _rc=$?
hasnt "under the nonce with an answers file, the markers do not refuse" "$_o" "REFUSED"
has "  nothing outside the sandbox: the confinement passes" "$_o" "Preconditions:"
is "dry run without a GREEN selftest -> exit 1" "$_rc" "1"
has "  it names the failing precondition" "$_o" "FAIL  selftest verdict=GREEN"
has "  and prints the passing ones too" "$_o" "PASS  clean working tree"
has "  C6: d=yes without --terms-bump fails, naming the fix" "$_o" "FAIL  C6 material-change answers (a=no b=no c=no d=yes) are consistent with the terms version - a 'yes' is a material change: re-run with --terms-bump"
has "  a red test-terms-text.sh fails, with its result line" "$_o" "FAIL  tests/test-terms-text.sh green on the tree to be tagged (terms-text selftest: pass=0 fail=1)"
has "  and says nothing was written" "$_o" "precondition(s) failed - nothing was written"
is "  nothing was tagged" "$(git -C "$RR" tag -l v2.0.0)" ""
_fpnow=$(find "$RH/.claude/hooks/governance" -type f \( -name '*.sh' -o -name '*.js' -o -name '*.py' -o -name '*.ps1' \) | LC_ALL=C sort | xargs cat | sha256sum | cut -c1-12)
printf 'verdict=GREEN\nhooks_fingerprint=%s\n' "$_fpnow" > "$RH/.claude/logs/governance-selftest.result"
# The one run with the REAL tests/test-terms-text.sh (GRT empty), on the archived tree to be tagged.
_o=$(GRT= grel 2.0.0 --dry-run); _rc=$?
is "dry run with every precondition met -> exit 0" "$_rc" "0"
[ "$_rc" = "0" ] || printf '%s\n' "$_o" | grep FAIL | head -5
has "  the real test-terms-text.sh ran green on the tree to be tagged" "$_o" "PASS  tests/test-terms-text.sh green on the tree to be tagged (terms-text selftest: pass="
has "  C6: all four answers 'no' pass without --terms-bump" "$_o" "PASS  C6 material-change answers (a=no b=no c=no d=no) are consistent with the terms version"
has "  C11: the listing passes" "$_o" "PASS  C11: every network-shaped line is listed against the NOTICE"
has "  C11: pre-session.sh is listed against NOTICE 3's version-check bullet" "$(printf '%s\n' "$_o" | grep -F 'bundle/hooks/governance/pre-session.sh')" "NOTICE 3 'The version check'"
has "  C11: wa-send.js is listed against NOTICE 3's notifications bullet" "$(printf '%s\n' "$_o" | grep -F 'bundle/hooks/governance/wa-send.js')" "NOTICE 3 'Notifications'"
has "  the dry run reports the answers" "$_o" "every precondition passes (C6 answers: a=no b=no c=no d=no)"
is "  and wrote nothing" "$(_relstate)" "$_rs0"

echo "  (C11 must-fire, and C6 with --terms-bump must-not-fire, in one run)"
mkdir -p "$RR/tools"; printf '#!/bin/sh\ncurl -s https://collector.example.invalid/ping\n' > "$RR/tools/net.sh"
sed -i 's/^- \*\*Notifications/- **Messages/' "$RR/NOTICE-AUTO-UPDATE.md"
rg add -A; rg commit -qm c11-fixture
: > "$RH/stubs/tt-called"
_o=$(GRA="$RH/stubs/answers-d-yes" grel 2.0.0 --dry-run --terms-bump); _rc=$?
has "d=yes WITH --terms-bump passes the C6 check" "$_o" "PASS  C6 material-change answers (a=no b=no c=no d=yes) are consistent with the terms version (--terms-bump)"
has "  (the NOTICE footer precondition is what also stops this fixture)" "$_o" "FAIL  NOTICE says 'Terms version: 2'"
has "  the terms test was given the tree with the terms version the release will carry" "$(cat "$RH/stubs/tt-called")" "terms=2"
is "an unlisted network file -> exit 1" "$_rc" "1"
has "  the file is listed as UNLISTED" "$(printf '%s\n' "$_o" | grep -F 'tools/net.sh')" "UNLISTED - name it in gov-release.sh c11_label and in NOTICE section 3"
has "  a mapped bullet missing from NOTICE 3 is named" "$_o" "MISSING: NOTICE 3 has no bullet 'Notifications'"
has "  the C11 check fails naming both files" "$_o" "FAIL  C11: every network-shaped line is listed against the NOTICE - not listed: bundle/hooks/governance/wa-send.js tools/net.sh"
rg reset -q --hard HEAD~1; rm -rf "$RR/tools"
is "  (fixture commit removed)" "$(_relstate)" "$_rs0"
# A publish queue whose content is already in the clone does not block the release, and is
# archived once the release has pushed it.
printf '2026-01-01T00:00:00+00:00 %s\n' "$RH/.claude/hooks/governance/gov-update.sh" > "$RH/.claude/logs/.governance-push-pending"
: > "$SB/sign.log"
_o=$(PATH="$SB/stubsk:$PATH" GRENV="SSH_AUTH_SOCK=$SB/bogus-agent.sock" grel 2.0.0); _rc=$?
is "the real run exits 0" "$_rc" "0"
has "  S3: ssh-keygen's own stderr is visible (not sent to /dev/null)" "$_o" "Write signature to"
has "  S3: the signer is told where to answer a prompt" "$_o" "answer any passphrase or touch prompt here"
_slog=$(cat "$SB/sign.log" 2>/dev/null)
has "  S3: the manifest signature ran with SSH_AUTH_SOCK unset" "$(printf '%s\n' "$_slog" | grep -F "$RH/keys/k1" | grep -F RELEASE-MANIFEST)" "sign sock=[unset]"
has "  S3: the tag signature (git -> ssh-keygen) ran with SSH_AUTH_SOCK unset" "$(printf '%s\n' "$_slog" | grep -F -- '-n git')" "sign sock=[unset]"
has "  (control: the throwaway signature DID see the variable, so the witness can tell)" "$(printf '%s\n' "$_slog" | grep -F throwaway)" "sign sock=[$SB/bogus-agent.sock]"
has "  C6: the release notes carry the review heading" "$(cat "$SB/gh-notes" 2>/dev/null)" "### Material-change review (legal C6)"
has "  C6: and the signer's answer to (d)" "$(cat "$SB/gh-notes" 2>/dev/null)" "(d) Does it send any information about the user or the user's projects to anyone, the maintainer included? **no**"
has "  C6: and the terms version" "$(cat "$SB/gh-notes" 2>/dev/null)" "Terms version: 1 (unchanged)."
has "  C6: the signed tag message records the answers" "$(git -C "$RR" cat-file tag v2.0.0)" "Material-change review (legal C6), answered by the signer: a=no b=no c=no d=no"
has "  the queued publish counts as fulfilled" "$_o" "publish queue fulfilled by this release"
is "  and is archived after the push" "$([ -f "$RH/.claude/logs/.governance-push-pending" ] && echo pending || echo archived)/$([ -f "$RH/.claude/logs/.governance-push-pending.released-v2.0.0" ] && echo kept || echo lost)" "archived/kept"
[ "$_rc" = "0" ] || printf '%s\n' "$_o" | tail -8
has "  the client-side rehearsal verified the tag" "$_o" "Rehearsal: verify-archive: OK v2.0.0"
is "  tag v2.0.0 is on the remote" "$(git -C "$RREM" tag -l v2.0.0)" "v2.0.0"
is "  the tag is signed (ssh)" "$(git -C "$RR" cat-file tag v2.0.0 | grep -c 'BEGIN SSH SIGNATURE')" "1"
is "  the remote master carries the manifest" "$(git -C "$RREM" show master:RELEASE-MANIFEST | sed -n 's/^version=//p')" "2.0.0"
has "  a GitHub Release was created with both files" "$(cat "$SB/gh-called" 2>/dev/null)" "RELEASE-MANIFEST.sig"
is "  staging VERSION written" "$(tr -d '[:space:]' < "$RH/.claude/governance-installer/bundle/VERSION")" "2.0.0"
is "  the source machine is marked" "$([ -f "$RH/.claude/.governance-source" ] && echo yes || echo no)" "yes"
is "  and its own marker stamped" "$(tr -d '[:space:]' < "$RH/.claude/.governance-version")" "2.0.0"
echo "  (a release signed by a key clients of v2.0.0 do not have is refused)"
signer_line k2 > "$RR/bundle/release/allowed_signers"; cp "$RR/bundle/release/allowed_signers" "$RH/.claude/governance-installer/bundle/release/allowed_signers"
sed -i "s|$_fp1|$(ssh-keygen -lf "$SB/keys/k2.pub" | awk '{print $2}')|g" "$RR/README.md"
sed -i 's/(v2\.0\.0)/(v2.0.1)/' "$RR/README.md"; cp "$RR/README.md" "$RH/.claude/governance-installer/README.md"
rg add -A; rg commit -qm rotate-wrong; rg push -q origin master 2>/dev/null
printf 'GOV_REPO_PATH=%s\nGOV_RELEASE_KEY=%s\n' "$RR" "$RH/keys/k2" > "$RH/.claude/.governance-local.env"
_o=$(grel 2.0.1); _rc=$?
is "a new-key-only release without --new-key-only -> exit 1" "$_rc" "1"
has "  naming the reason" "$_o" "FAIL  the release key is pinned by clients of v2.0.0"
is "  no tag v2.0.1" "$(git -C "$RREM" tag -l v2.0.1)" ""
fi

# ── mutants: the suite must be able to FAIL ─────────────────────────────────────────────────
# mutant <name> <sed expression> -> path of a mutated gov-update.sh beside copies of its libraries
mutant() {
  local d="$SB/mut-$1"; rm -rf "$d"; mkdir -p "$d"
  cp "$GOV_DIR/_common.sh" "$GOV_DIR/release-manifest.sh" "$GOV_DIR/consent-lib.sh" "$d/"
  sed "$2" "$GOV_DIR/gov-update.sh" > "$d/gov-update.sh"
  if cmp -s "$GOV_DIR/gov-update.sh" "$d/gov-update.sh"; then echo ""; return; fi
  printf '%s' "$d/gov-update.sh"
}
# mutant_lib <name> <sed expression> -> path of an UNCHANGED gov-update.sh beside a mutated
# consent-lib.sh (the predicate lives there; _common.sh sources it from its own directory).
mutant_lib() {
  local d="$SB/mut-$1"; rm -rf "$d"; mkdir -p "$d"
  cp "$GOV_DIR/_common.sh" "$GOV_DIR/release-manifest.sh" "$GOV_DIR/gov-update.sh" "$d/"
  sed "$2" "$GOV_DIR/consent-lib.sh" > "$d/consent-lib.sh"
  if cmp -s "$GOV_DIR/consent-lib.sh" "$d/consent-lib.sh"; then echo ""; return; fi
  printf '%s' "$d/gov-update.sh"
}
if want M1; then
echo "(${SECONDS}s) [M1] mutant: no signature check"
m=$(mutant M1 's/relman_verify_sig "\$m" "\$t\/RELEASE-MANIFEST.sig" "\$signers"/true/')
if [ -z "$m" ]; then bad "M1: the sed did not change gov-update.sh - the mutant is void"
else
  use_home "$BASE"; URL=$(url_of "$SB/remote-badsig")
  UPD_SCRIPT="$m" upd --fetch 2.0.0
  is "M1: the mutant lets T2's bad signature through (so T2 can fail)" "$(halt_reason 2.0.0)" ""
fi
URL=$(url_of "$SB/remote-good")
fi
if want M2; then
echo "(${SECONDS}s) [M2] mutant: no checksum"
m=$(mutant M2 's/VERIFY_DETAIL=\$(relman_verify_tree "\$m" "\$t" 2>&1) || { VERIFY_REASON="checksum"; return 1; }/:/')
if [ -z "$m" ]; then bad "M2: the sed did not change gov-update.sh - the mutant is void"
elif [ ! -f "$SB/remote-tamper/v2.0.0.tar.gz" ]; then bad "M2 needs T3's tampered release - run it with T3"
else
  use_home "$BASE"; URL=$(url_of "$SB/remote-tamper")
  UPD_SCRIPT="$m" upd --fetch 2.0.0
  is "M2: the mutant stages T3's tampered tree (so T3 can fail)" "$([ -f "$H/.claude/.governance-update/READY" ] && echo staged || echo refused)" "staged"
fi
URL=$(url_of "$SB/remote-good")
fi
if want M3; then
echo "(${SECONDS}s) [M3] mutant: no backup"
m=$(mutant M3 's/^upd_backup_copy() {$/upd_backup_copy() { return 0/; s/^upd_backup_verify() {$/upd_backup_verify() { return 0/')
if [ -z "$m" ]; then bad "M3: the sed did not change gov-update.sh - the mutant is void"
else
  use_home "$BASE"; URL=$(url_of "$SB/remote-vfail"); _before=$(treehash)
  upd --fetch 2.0.0
  UPD_SCRIPT="$m" upd --apply >/dev/null
  _after=$(treehash)
  is "M3: without the backup T6's rollback cannot restore the tree (so T6 can fail)" "$([ "$_after" = "$_before" ] && echo restored || echo corrupted)" "corrupted"
fi
URL=$(url_of "$SB/remote-good")
fi
if want M4; then
echo "(${SECONDS}s) [M4] mutant: no liveness check"
m=$(mutant M4 's/kill -0 "\$[a-z0-9]*"/false/g')
if [ -z "$m" ]; then bad "M4: the sed did not change gov-update.sh - the mutant is void"
else
  if ! command -v t13_alive >/dev/null 2>&1; then bad "M4 needs T13's scenario - run it with T13"
  else
    t13_alive "$m"; _o=$(cat "$SB/t13.out")
    hasnt "M4: the mutant rolls back under a LIVE apply (so T13-alive can fail)" "$_o" "an apply is still running"
  fi
fi
fi
# ── mutants of "no automatic update" (2026-09-30): each must turn a [NOAUTO]/[PRESESSION] assertion red ──
if want M8; then
echo "(${SECONDS}s) [M8] mutant: gov_auto_update_on forced true"
m=$(mutant_lib M8 's/^gov_auto_update_on() {$/gov_auto_update_on() { return 0/')
if [ -z "$m" ]; then bad "M8: the sed did not change consent-lib.sh - the mutant is void"
else
  use_home "$STAGED"
  printf 'enabled=1 terms_version=1 accepted_at=2026-01-01T00:00:00Z method=interactive\n' > "$H/.claude/.governance-update/auto-update"
  # A generous budget: a "too busy" abort would leave 1.9.0 and pass this mutant off as harmless.
  GOV_AUTO_UPDATE=1 GOV_UPDATE_APPLY_BUDGET=600 SRCKIND=session-end UPD_SCRIPT="$m" upd --apply-if-ready >/dev/null
  is "M8: with the predicate true, --apply-if-ready applies unattended (so [NOAUTO] (a) can fail)" "$(marker)" "2.0.0"
fi
fi
if want M10; then
echo "(${SECONDS}s) [M10] mutant: a --fetch spawn put back into pre-session.sh (after the legacy line)"
PSB_M10='/Context Governance v\$_REMOTE_V is published;/a\            bash "$SCRIPT_DIR/gov-update.sh" --fetch "$_REMOTE_V" </dev/null >/dev/null 2>&1 &'
use_home "$BASE"; _psf="$H/.claude/hooks/governance/pre-session.sh"
sed "$PSB_M10" "$_psf" > "$SB/m10-pre-session.sh"
if cmp -s "$_psf" "$SB/m10-pre-session.sh" || ! bash -n "$SB/m10-pre-session.sh" 2>/dev/null; then
  bad "M10: the sed did not change pre-session.sh (or broke its syntax) - the mutant is void"
else
  PSB_SED="$PSB_M10" ps_behind; PSB_SED=""
  _t0=$SECONDS; wait_until 30 'psb_fetched'
  is "M10: the re-inserted spawn is caught by [PRESESSION]'s 'no fetch spawned' (so it can fail)" "$(psb_fetched && echo spawned || echo none)" "spawned"
  echo "  (the spawned fetch showed after ~$((SECONDS - _t0)) s; [PRESESSION] waits 6 s)"
  wait_until 30 '[ ! -d "$H/.claude/.governance-update/lock.d" ]'
fi
fi
if [ "${GOV_TEST_SLOW:-0}" = "1" ] && want SLOW; then
echo "(${SECONDS}s) [SLOW] one fetch with the REAL deep verify (scanner selftest on the staged tree)"
use_home "$BASE"; URL=$(url_of "$SB/remote-good")
DEEP_SKIP=0 upd --fetch 2.0.0
is "deep-verified fetch staged" "$([ -f "$H/.claude/.governance-update/READY" ] && echo yes || echo no)" "yes"
fi

if [ "${GOV_TEST_T12:-0}" = "1" ]; then
echo "(${SECONDS}s) [T12] apply wall time (run on the owner's box, under load, by hand)"
for i in $(seq 1 "${GOV_TEST_T12_RUNS:-10}"); do
  use_home "$STAGED"
  if [ "${GOV_TEST_T12_NICE:-0}" = "1" ]; then
    _s=$(date +%s%N); _o=$(UPD_SCRIPT= nice -n 19 bash -c "$(declare -f upd); $(declare -p H URL 2>/dev/null); upd --apply"); _e=$(date +%s%N)
  else
    _s=$(date +%s%N); _o=$(upd --apply); _e=$(date +%s%N)
  fi
  _r=$(grep -o 'mv retries [0-9]*' "$H/.claude/logs/governance-update.log" | tail -1)
  printf '  T12 run %s: %s ms, %s, %s\n' "$i" "$(( (_e - _s) / 1000000 ))" "$_r" "$(case "$_o" in *Applied*) echo applied ;; *) echo "NOT APPLIED: $_o" ;; esac)"
done
fi

echo ""
echo "test-gov-update: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
