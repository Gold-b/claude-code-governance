#!/usr/bin/env bash
# test-gov-update.sh — the signed auto-updater (2.0.0), end to end, in a SANDBOX.
#
# Never touches the real ~/.claude: every case runs under a throwaway HOME, against fixture
# releases built from THIS checkout by the real release-manifest.sh and signed by throwaway keys
# generated per run. A fixture "remote" is a directory of GitHub-shaped tarballs
# (claude-code-governance-<ver>/ top directory) served over file://.
#
# Cases (plan §8): T1-T11, T13-T18, mutants M1-M4, plus the release-manifest determinism check
# (step 4), install-map parity (step 5) and the pre-push VERSION/tag rule (step 9).
# T12 (apply under load) is a measurement, run by hand: GOV_TEST_T12=1.
# GOV_TEST_SLOW=1 adds one fetch with the real deep verify (~80 s).
# GOV_TEST_ONLY="T1 T2 ..." runs a subset (case names as printed).
#
# Every "nothing changed" claim is a hash of the sandbox tree before and after, and every refusal
# is paired with a case that proceeds — a suite whose guards never let anything through proves as
# little as one whose guards never stop anything. The mutants (M1-M4) prove the suite can fail.
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

# The environment of the person running this must not leak in: a source-machine signal would turn
# every case into a silent "source machine" skip, an opt-out into a silent "off".
unset GOV_REPO_PATH GOV_RELEASE_KEY GOV_AUTO_UPDATE GOV_ACCEPT_TERMS GOV_UPDATE_OVERWRITE_LOCAL \
      GOV_UPDATE_ARCHIVE_URL GOV_SESSION_ID GOV_SESSION_SOURCE GOVERNANCE_UPDATE_CHECK
export GOVERNANCE_HOOKS=1 GOV_NO_STDIN=1

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
     for f in installed.hashes installed.manifest allowed_signers settings-hooks.installed.json install-mode terms-accepted; do
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

echo "building fixture releases ..."
mkrel base 1.9.0 k1 || exit 1
# The 1.9.0 baseline, installed exactly as a user would: tagged tree, terms accepted by flag.
BASE="$SB/base-home"; mkdir -p "$BASE"
_inst=$(HOME="$BASE" bash "$SB/rel/base/claude-code-governance-1.9.0/install.sh" --accept-terms --no-verify 2>&1 </dev/null); _irc=$?
is "baseline: install.sh 1.9.0 exits 0" "$_irc" "0"
[ "$_irc" = "0" ] || printf '%s\n' "$_inst" | tail -15
has "baseline: signed release recognised" "$_inst" "Installing signed release v1.9.0"
has "baseline: release key pinned on first install" "$_inst" "PINNED (trust on first install)"
is "baseline: marker 1.9.0" "$(tr -d '[:space:]' < "$BASE/.claude/.governance-version" 2>/dev/null)" "1.9.0"
for f in allowed_signers installed.hashes installed.manifest install-mode terms-accepted settings-hooks.installed.json; do
  is "baseline: .governance-update/$f written" "$([ -s "$BASE/.claude/.governance-update/$f" ] && echo yes || echo no)" "yes"
done
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
use_home "$BASE"; _before=$(treehash)
upd --fetch 2.0.0
is "fetch wrote READY" "$([ -f "$H/.claude/.governance-update/READY" ] && echo yes || echo no)" "yes"
is "the staged tree exists" "$([ -f "$H/.claude/.governance-update/staged/v2.0.0/RELEASE-MANIFEST" ] && echo yes || echo no)" "yes"
is "fetch alone changed nothing installed" "$(treehash)" "$_before"
_o=$(upd --apply-if-ready)
has "notice printed" "$_o" "Applied v2.0.0 automatically (was v1.9.0"
is "marker stamped 2.0.0" "$(marker)" "2.0.0"
is "installed.manifest is 2.0.0's" "$(relman_get "$H/.claude/.governance-update/installed.manifest" version)" "2.0.0"
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
_o2=$(upd --apply-if-ready)
is "the notice is printed once (second start is silent)" "$_o2" ""
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
_o=$(upd --apply-if-ready)
has "a planted READY for 1.8.0 is refused" "$_o" "downgrade"
is "HALT reason=downgrade" "$(halt_reason 1.8.0)" "downgrade"
is "tree unchanged" "$(treehash)" "$_before"
URL=$(url_of "$SB/remote-good")
fi

if want T5; then
echo "(${SECONDS}s) [T5] network down, spacing, give-up line, tag 404"
use_home "$BASE"; URL=$(url_of "$SB/remote-missing")
_o=$(SPACING=3600 upd --fetch 2.0.0)
is "network failure is silent" "$_o" ""
is "one attempt recorded" "$(cat "$H/.claude/.governance-update/fetch-attempts-2.0.0" 2>/dev/null)" "1"
is "one log line says network" "$(grep -c 'reason=network v2.0.0' "$H/.claude/logs/governance-update.log")" "1"
SPACING=3600 upd --fetch 2.0.0
is "a second call inside the spacing window does nothing" "$(cat "$H/.claude/.governance-update/fetch-attempts-2.0.0" 2>/dev/null)" "1"
SPACING=0 upd --fetch 2.0.0
is "outside the window it tries again" "$(cat "$H/.claude/.governance-update/fetch-attempts-2.0.0" 2>/dev/null)" "2"
printf '10\n' > "$H/.claude/.governance-update/fetch-attempts-2.0.0"
printf '2.0.0\n' > "$H/.claude/logs/.governance-latest"
_o=$(HOME="$H" bash "$H/.claude/hooks/governance/pre-session.sh" <<< '{"cwd":"/tmp"}' 2>&1)
has "after the cap: the manual-path line" "$_o" "could not be downloaded after 10 tries"
_o=$(HOME="$H" bash "$H/.claude/hooks/governance/pre-session.sh" <<< '{"cwd":"/tmp"}' 2>&1)
hasnt "the give-up line is throttled (12 h)" "$_o" "could not be downloaded"
use_home "$BASE"
mkdir -p "$SB/stub404"
printf '#!/bin/sh\nprintf 404\nexit 0\n' > "$SB/stub404/curl"; chmod +x "$SB/stub404/curl"
for i in 1 2 3; do PATH="$SB/stub404:$PATH" upd --fetch 2.0.0; done
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
for v in fail:verify-failed skill:verify-failed sleep:timeout; do
  n="${v%%:*}"; want_r="${v#*:}"
  mkrel "v$n" 2.0.0 k1 "pre_v_$n" >/dev/null
  use_home "$BASE"; URL=$(url_of "$SB/remote-v$n")
  upd --fetch 2.0.0
  is "$n: staged" "$([ -f "$H/.claude/.governance-update/READY" ] && echo yes || echo no)" "yes"
  _before=$(treehash); cp "$H/.claude/settings.json" "$SB/settings.before"
  _o=$(GOV_UPDATE_VERIFY_TIMEOUT=3 upd --apply-if-ready)
  has "$n: the notice names the backup it restored from" "$_o" "restored from ~/.claude/backups/governance-update-"
  is "$n: tree byte-identical to before" "$(treehash)" "$_before"
  is "$n: settings.json identical" "$(cmp -s "$SB/settings.before" "$H/.claude/settings.json" && echo same || echo differs)" "same"
  is "$n: marker unchanged" "$(marker)" "1.9.0"
  is "$n: HALT reason=$want_r" "$(halt_reason 2.0.0)" "$want_r"
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
upd --apply-if-ready
is "apply refuses on the source machine too" "$(treehash)" "$_before"
use_home "$BASE"
upd --fetch 2.0.0
is "no signal -> it proceeds" "$([ -f "$H/.claude/.governance-update/READY" ] && echo staged || echo refused)" "staged"
fi

if want T8; then
echo "(${SECONDS}s) [T8] cross-session lock"
use_home "$BASE"; mkdir -p "$H/.claude/.governance-update/lock.d"
printf 'pid=%s since=x mode=apply\n' "$$" > "$H/.claude/.governance-update/lock.d/info"
upd --fetch 2.0.0
is "a live lock -> the second run does nothing" "$([ -f "$H/.claude/.governance-update/fetch-attempts-2.0.0" ] && echo ran || echo skipped)" "skipped"
is "and says so in the log" "$(grep -c 'locked by pid=' "$H/.claude/logs/governance-update.log")" "1"
printf 'pid=999999 since=x mode=apply\n' > "$H/.claude/.governance-update/lock.d/info"
touch -d '2 hours ago' "$H/.claude/.governance-update/lock.d/info" 2>/dev/null
upd --fetch 2.0.0
is "a stale lock (dead pid) is broken" "$(grep -c 'stale lock broken' "$H/.claude/logs/governance-update.log")" "1"
is "and the run proceeds" "$([ -f "$H/.claude/.governance-update/READY" ] && echo yes || echo no)" "yes"
is "the lock is released afterwards" "$([ -d "$H/.claude/.governance-update/lock.d" ] && echo held || echo free)" "free"
fi

if want T9; then
echo "(${SECONDS}s) [T9] opt-out"
use_home "$BASE"
GOV_AUTO_UPDATE=0 upd --fetch 2.0.0
is "GOV_AUTO_UPDATE=0 (env): no fetch" "$([ -f "$H/.claude/.governance-update/fetch-attempts-2.0.0" ] && echo fetched || echo off)" "off"
printf 'GOV_AUTO_UPDATE=0\n' > "$H/.claude/.governance-local.env"
upd --fetch 2.0.0
is "GOV_AUTO_UPDATE=0 (local env file): no fetch" "$([ -f "$H/.claude/.governance-update/fetch-attempts-2.0.0" ] && echo fetched || echo off)" "off"
rm -f "$H/.claude/.governance-local.env"
GOVERNANCE_UPDATE_CHECK=0 upd --fetch 2.0.0
is "GOVERNANCE_UPDATE_CHECK=0: nothing" "$([ -f "$H/.claude/.governance-update/fetch-attempts-2.0.0" ] && echo fetched || echo off)" "off"
use_home "$STAGED"; _before=$(treehash)
GOV_AUTO_UPDATE=0 upd --apply-if-ready
is "a staged READY with GOV_AUTO_UPDATE=0 is not applied" "$(treehash)" "$_before"
is "  (marker unchanged)" "$(marker)" "1.9.0"
fi

if want T10; then
echo "(${SECONDS}s) [T10] locally modified installed file"
use_home "$STAGED"
printf '# my local patch\n' >> "$H/.claude/hooks/governance/pre-task.sh"
_before=$(treehash)
_o=$(upd --apply-if-ready)
has "refused, naming the file" "$_o" "modified locally (hooks/governance/pre-task.sh)"
is "tree unchanged" "$(treehash)" "$_before"
_o=$(GOV_UPDATE_OVERWRITE_LOCAL=1 upd --apply-if-ready)
has "GOV_UPDATE_OVERWRITE_LOCAL=1 applies" "$_o" "Applied v2.0.0"
_bk=$(ls -1d "$H/.claude/backups"/governance-update-* 2>/dev/null | tail -1)
is "the local patch is in the backup" "$(grep -c 'my local patch' "$_bk/hooks/governance/pre-task.sh" 2>/dev/null)" "1"
echo "  (CRLF: a baseline written from a CRLF checkout must not read as local edits)"
_crlf="$SB/crlf-tree"; rm -rf "$_crlf"; cp -r "$SB/rel/base/claude-code-governance-1.9.0" "$_crlf"
find "$_crlf/bundle" -name '*.md' | while read -r f; do sed -i 's/$/\r/' "$f"; done
is "precondition: the CRLF tree really has CRLF" "$(grep -rl $'\r' "$_crlf/bundle/docs" | grep -c .)" "$(ls "$_crlf/bundle/docs"/*.md | grep -c .)"
rm -rf "$H"; mkdir -p "$H"
HOME="$H" bash "$_crlf/install.sh" --accept-terms --no-verify >/dev/null 2>&1 </dev/null
upd --fetch 2.0.0
_o=$(upd --apply-if-ready)
has "CRLF-installed machine updates without a false local-edit refusal" "$_o" "Applied v2.0.0"
fi

if want T11; then
echo "(${SECONDS}s) [T11] terms bump"
pre_terms() { pre_t1 "$1"; printf '2\n' > "$1/bundle/TERMS-VERSION"; sed -i 's/^Terms version: 1$/Terms version: 2/' "$1/NOTICE-AUTO-UPDATE.md"; }
mkrel terms 2.0.0 k1 pre_terms >/dev/null
use_home "$BASE"; URL=$(url_of "$SB/remote-terms")
upd --fetch 2.0.0
_before=$(treehash)
_o=$(upd --apply-if-ready)
has "held with the terms line" "$_o" "its terms changed (v2)"
is "tree unchanged while held" "$(treehash)" "$_before"
_o=$(HOME="$H" bash "$H/.claude/hooks/governance/gov-update.sh" --accept-terms </dev/null 2>&1)
hasnt "--accept-terms without a terminal or GOV_ACCEPT_TERMS records nothing" "$(cat "$H/.claude/.governance-update/terms-accepted")" "terms_version=2"
_o=$(HOME="$H" GOV_ACCEPT_TERMS=1 bash "$H/.claude/hooks/governance/gov-update.sh" --accept-terms </dev/null 2>&1)
has "--accept-terms prints the summary" "$_o" "updates ITSELF"
has "terms v2 recorded" "$(cat "$H/.claude/.governance-update/terms-accepted")" "terms_version=2"
_o=$(upd --apply-if-ready)
has "the next start applies" "$_o" "Applied v2.0.0"
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
  bash "$H/.claude/hooks/governance/gov-update.sh" --apply-if-ready </dev/null >/dev/null 2>&1 &
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
# Recovered with automatic updates SWITCHED OFF: restoring a half-applied tree is not an update,
# so an opt-out must not leave it in place (review round 2).
_o=$(GOV_AUTO_UPDATE=0 upd --apply-if-ready)
has "the next start rolls back and says so (even with GOV_AUTO_UPDATE=0)" "$_o" "could NOT be applied (interrupted)"
is "tree byte-identical to before the apply" "$(treehash)" "$_before"
is "HALT reason=interrupted" "$(halt_reason 2.0.0)" "interrupted"
is "the journal is gone" "$([ -f "$H/.claude/.governance-update/APPLYING" ] && echo present || echo gone)" "gone"
[ -f "$SB/stub-sleeper.pid" ] && kill "$(cat "$SB/stub-sleeper.pid")" 2>/dev/null
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
_o=$(upd --apply-if-ready)
has "deferred while another session is live" "$_o" "deferred 1 time(s)"
is "deferrals=1" "$(cat "$H/.claude/.governance-update/deferrals")" "1"
is "tree unchanged" "$(treehash)" "$_before"
upd --apply-if-ready >/dev/null; _o=$(upd --apply-if-ready)
has "from the 3rd deferral the sessions are named" "$_o" "Live: other"
_o=$(upd --apply --force-live)
has "--apply --force-live applies" "$_o" "Applied v2.0.0"
use_home "$STAGED"; mk_session idle 700
_o=$(upd --apply-if-ready)
has "a session idle for 700 s does not count" "$_o" "Applied v2.0.0"
use_home "$STAGED"; mk_session test-self 5
_o=$(SID=test-self upd --apply-if-ready)
has "the CURRENT session's own dir does not count" "$_o" "Applied v2.0.0"
use_home "$STAGED"; mk_session other 60; touch "$H/.claude/logs/sessions/other/.gov-session-closed"
_o=$(upd --apply-if-ready)
has "a closed session does not count" "$_o" "Applied v2.0.0"
fi

if want T14b; then
echo "(${SECONDS}s) [T14b] SessionStart source"
for s in compact clear; do
  use_home "$STAGED"; _before=$(treehash)
  SRCKIND="$s" upd --apply-if-ready >/dev/null
  is "source=$s: not applied" "$(treehash)" "$_before"
  is "source=$s: READY kept" "$([ -f "$H/.claude/.governance-update/READY" ] && echo kept || echo gone)" "kept"
done
for s in startup resume ""; do
  use_home "$STAGED"
  _o=$(SRCKIND="$s" upd --apply-if-ready)
  has "source=${s:-<absent>}: applied" "$_o" "Applied v2.0.0"
done
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
upd --fetch 2.0.0; _o=$(upd --apply-if-ready)
has "release N (old+new signers, signed by old) applies" "$_o" "Applied v2.0.0"
is "the pinned file now carries the new key" "$(grep -c "$(cut -d' ' -f2 "$SB/keys/k2.pub")" "$H/.claude/.governance-update/allowed_signers")" "1"
URL=$(url_of "$SB/remote-rot2")
upd --fetch 2.0.1; _o=$(upd --apply-if-ready)
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
_P="$SB/parity"; rm -rf "$_P"; mkdir -p "$_P"
_tree="$SB/rel/base/claude-code-governance-1.9.0"
_nmap=$(bash "$_tree/install.sh" --print-install-map 2>/dev/null | grep -c .)
_ninst=$(cd "$BASE/.claude" && find hooks skills docs agents -type f 2>/dev/null | grep -c .)
is "full install: files copied == map lines" "$_ninst" "$_nmap"
HOME="$_P" bash "$_tree/install.sh" --core-only --accept-terms --no-verify >/dev/null 2>&1 </dev/null
_ncore=$(bash "$_tree/install.sh" --print-install-map 2>/dev/null | awk '$4 == "core"' | grep -c .)
_ninst=$(cd "$_P/.claude" && find hooks skills docs agents -type f 2>/dev/null | grep -c .)
is "core-only install: files copied == core map lines" "$_ninst" "$_ncore"
is "core-only records its mode" "$(cat "$_P/.claude/.governance-update/install-mode")" "core-only"
_d=$(HOME="$SB/dry" bash "$_tree/install.sh" --dry-run </dev/null 2>&1); _rc=$?
is "dry run without accepted terms and no terminal exits 1" "$_rc" "1"
has "  and says why" "$_d" "Terms v1 are not accepted"
is "  and writes nothing" "$(find "$SB/dry" -type f 2>/dev/null | grep -c .)" "0"
_d=$(HOME="$SB/refuse" bash "$_tree/install.sh" </dev/null 2>&1); _rc=$?
is "a real install without acceptance refuses (exit 1)" "$_rc" "1"
is "  before writing anything" "$(find "$SB/refuse" -type f 2>/dev/null | grep -c .)" "0"
_d=$(HOME="$SB/dry2" bash "$_tree/install.sh" --dry-run --accept-terms </dev/null 2>&1); _rc=$?
is "dry run with --accept-terms exits 0" "$_rc" "0"
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
echo "(${SECONDS}s) [PRESESSION] pre-session.sh drives the apply (READY staged)"
# GOV_NO_STDIN=0: the suite exports 1 for the tools it runs, but a HOOK must read its payload —
# with 1 the "source" in the payload never arrived and compact looked like startup (MEASURED).
ps_run() { HOME="$H" GOV_NO_STDIN=0 GOV_UPDATE_SKIP_DEEP_VERIFY=1 bash "$H/.claude/hooks/governance/pre-session.sh" <<< "$1" 2>&1; }
use_home "$STAGED"; printf '2.0.0\n' > "$H/.claude/logs/.governance-latest"
_o=$(ps_run '{"cwd":"/tmp","session_id":"sess-a","source":"compact"}')
hasnt "source=compact in the payload: not applied" "$_o" "Applied v2.0.0"
is "  marker unchanged" "$(marker)" "1.9.0"
# The CURRENT session's own directory is fresh. Only the GOV_SESSION_ID plumbing tells the updater
# that this is itself: without it, it would count as "another live session" and defer forever.
mkdir -p "$H/.claude/logs/sessions/sess-a"; touch "$H/.claude/logs/sessions/sess-a/f"
_o=$(ps_run '{"cwd":"/tmp","session_id":"sess-a","source":"startup"}')
has "source=startup: applied through pre-session (own session not counted)" "$_o" "Applied v2.0.0"
is "  marker 2.0.0" "$(marker)" "2.0.0"
use_home "$STAGED"; printf '2.0.0\n' > "$H/.claude/logs/.governance-latest"
mkdir -p "$H/.claude/logs/sessions/sess-other"; touch "$H/.claude/logs/sessions/sess-other/f"
_o=$(ps_run '{"cwd":"/tmp","session_id":"sess-a","source":"startup"}')
has "another live session: deferred through pre-session" "$_o" "deferred 1 time(s)"
fi

if want PRESESSION && [ -f "$SB/stubmv/mv" ]; then
echo "  (an interrupted apply is recovered by pre-session even with GOVERNANCE_UPDATE_CHECK=0)"
use_home "$STAGED"; _before=$(treehash); rm -f "$SB/mvcount"
HOME="$H" GOV_UPDATE_SKIP_DEEP_VERIFY=1 GOV_SESSION_SOURCE=startup GOV_SESSION_ID=test-self PATH="$SB/stubmv:$PATH" \
  bash "$H/.claude/hooks/governance/gov-update.sh" --apply-if-ready </dev/null >/dev/null 2>&1 &
_ap=$!; _w=0
while [ "$(_nswap)" -lt 5 ] && [ "$_w" -lt 240 ]; do sleep 0.5; _w=$((_w + 1)); done
kill -9 "$_ap" 2>/dev/null; wait "$_ap" 2>/dev/null; sleep 1
[ -f "$SB/stub-sleeper.pid" ] && kill "$(cat "$SB/stub-sleeper.pid")" 2>/dev/null
_o=$(HOME="$H" GOV_NO_STDIN=0 GOVERNANCE_UPDATE_CHECK=0 GOV_UPDATE_SKIP_DEEP_VERIFY=1 bash "$H/.claude/hooks/governance/pre-session.sh" <<< '{"cwd":"/tmp","session_id":"sess-a","source":"startup"}' 2>&1)
has "recovered through pre-session with the update check OFF" "$_o" "could NOT be applied (interrupted)"
is "  tree byte-identical to before" "$(treehash)" "$_before"
fi

if want BUDGET; then
echo "(${SECONDS}s) [BUDGET] an apply that cannot finish in time aborts before changing anything"
use_home "$STAGED"; _before=$(treehash)
_o=$(GOV_UPDATE_APPLY_BUDGET=1 upd --apply-if-ready)
has "too busy -> not applied" "$_o" "too busy"
is "  tree unchanged" "$(treehash)" "$_before"
is "  READY kept for the next start" "$([ -f "$H/.claude/.governance-update/READY" ] && echo kept || echo gone)" "kept"
GOV_UPDATE_APPLY_BUDGET=1 upd --apply-if-ready >/dev/null; _o=$(GOV_UPDATE_APPLY_BUDGET=1 upd --apply-if-ready)
has "after 3 in a row it names the manual command" "$_o" "gov-update.sh --apply"
_o=$(upd --apply-if-ready)
has "with a normal budget it then applies" "$_o" "Applied v2.0.0"
fi

if want EXTRA; then
echo "(${SECONDS}s) [EXTRA] a signed manifest beside an EXTRA hook is not labelled a signed release"
_X="$SB/extra-tree"; rm -rf "$_X" "$SB/extra-home"; cp -r "$SB/rel/base/claude-code-governance-1.9.0" "$_X"
printf '#!/usr/bin/env bash\necho extra\n' > "$_X/bundle/hooks/governance/zz-extra.sh"
mkdir -p "$SB/extra-home"
_o=$(HOME="$SB/extra-home" bash "$_X/install.sh" --accept-terms --no-verify </dev/null 2>&1)
has "labelled an unreleased snapshot" "$_o" "UNRELEASED master snapshot"
hasnt "  not a signed release" "$_o" "Installing signed release"
is "  the recorded manifest is synthesized (unsigned=1)" "$(grep -c '^unsigned=1' "$SB/extra-home/.claude/.governance-update/installed.manifest")" "1"
fi

if want RACE; then
echo "(${SECONDS}s) [RACE] install.sh refuses while an automatic update is running"
use_home "$STAGED"
sleep 60 >/dev/null 2>&1 </dev/null & LIVE_PID=$!
printf 'version=2.0.0\nfrom=1.9.0\nstarted=x\nbackup=x\npid=%s\n' "$LIVE_PID" > "$H/.claude/.governance-update/APPLYING"
_before=$(treehash)
_o=$(HOME="$H" bash "$SB/rel/base/claude-code-governance-1.9.0/install.sh" --accept-terms --no-verify --force </dev/null 2>&1); _rc=$?
is "refused (exit 1)" "$_rc" "1"
has "  naming the running update" "$_o" "An automatic update is running right now"
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
fi

if want ROLLBACK; then
echo "(${SECONDS}s) [ROLLBACK] manual --rollback: exact, undoable, and refuses a stale backup"
use_home "$BASE"; _base_hash=$(treehash)
use_home "$STAGED"; upd --apply-if-ready >/dev/null
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
_o=$(upd --apply-if-ready)
has "the no-baseline note" "$_o" "no local-modification baseline"
has "applied" "$_o" "Applied v2.0.0"
is "a baseline exists afterwards" "$([ -s "$H/.claude/.governance-update/installed.hashes" ] && echo yes || echo no)" "yes"
fi

if want COLLIDE; then
echo "(${SECONDS}s) [COLLIDE] a user's own file at a path the release claims for the first time"
use_home "$STAGED"; mkdir -p "$H/.claude/skills/test-new-skill"
printf 'my own skill\n' > "$H/.claude/skills/test-new-skill/SKILL.md"; _before=$(treehash)
_o=$(upd --apply-if-ready)
has "refused, naming it" "$_o" "skills/test-new-skill/SKILL.md"
is "tree unchanged" "$(treehash)" "$_before"
cp "$SB/rel/good/claude-code-governance-2.0.0/bundle/skills/test-new-skill/SKILL.md" "$H/.claude/skills/test-new-skill/SKILL.md"
_o=$(upd --apply-if-ready)
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
RR="$SB/relrepo"; RH="$SB/relhome"; rm -rf "$RR" "$RH" "$SB/relremote.git"
git init -q --bare "$SB/relremote.git"
cp -r "$SRC" "$RR"; printf '1.9.0\n' > "$RR/bundle/VERSION"
_fp1=$(ssh-keygen -lf "$SB/keys/k1.pub" | awk '{print $2}')
_fpreal=$(grep -o 'SHA256:[A-Za-z0-9+/]\{43\}' "$RR/README.md" | head -1)
[ -n "$_fpreal" ] && sed -i "s|$_fpreal|$_fp1|g" "$RR/README.md"
rg() { git -C "$RR" -c user.name=t -c user.email=nobody -c core.autocrlf=false "$@"; }
rg init -q; rg config user.name t; rg config user.email nobody; rg config core.autocrlf false
rg add -A; rg commit -qm base; rg branch -M master; rg tag v1.9.0
rg remote add origin "$SB/relremote.git"; rg push -q origin master v1.9.0 2>/dev/null
cp -r "$BASE" "$RH"
rm -rf "$RH/.claude/governance-installer"; mkdir -p "$RH/.claude/governance-installer"
cp -r "$RR/bundle" "$RR/install.sh" "$RR/verify.sh" "$RR/README.md" "$RH/.claude/governance-installer/"
printf 'GOV_REPO_PATH=%s\nGOV_RELEASE_KEY=%s\n' "$RR" "$SB/keys/k1" > "$RH/.claude/.governance-local.env"
mkdir -p "$SB/stubgh"
printf '#!/bin/sh\ncase "$1 $2" in\n  "auth status") exit 0 ;;\n  "release create") echo "$@" > "%s/gh-called"; exit 0 ;;\nesac\nexit 0\n' "$SB" > "$SB/stubgh/gh"; chmod +x "$SB/stubgh/gh"
grel() { HOME="$RH" PATH="$SB/stubgh:$PATH" GOV_UPDATE_SKIP_DEEP_VERIFY=1 GOV_RELEASE_LOCAL_REHEARSAL=1 \
         bash "$RH/.claude/hooks/governance/gov-release.sh" "$@" </dev/null 2>&1; }
_o=$(grel 2.0.0 --dry-run); _rc=$?
is "dry run without a GREEN selftest -> exit 1" "$_rc" "1"
has "  it names the failing precondition" "$_o" "FAIL  selftest verdict=GREEN"
has "  and prints the passing ones too" "$_o" "PASS  clean working tree"
is "  nothing was tagged" "$(git -C "$RR" tag -l v2.0.0)" ""
_fpnow=$(find "$RH/.claude/hooks" -type f \( -name '*.sh' -o -name '*.js' -o -name '*.py' -o -name '*.ps1' \) | LC_ALL=C sort | xargs cat | sha256sum | cut -c1-12)
printf 'verdict=GREEN\nhooks_fingerprint=%s\n' "$_fpnow" > "$RH/.claude/logs/governance-selftest.result"
_o=$(grel 2.0.0 --dry-run); _rc=$?
is "dry run with every precondition met -> exit 0" "$_rc" "0"
[ "$_rc" = "0" ] || printf '%s\n' "$_o" | grep FAIL | head -5
_o=$(grel 2.0.0); _rc=$?
is "the real run exits 0" "$_rc" "0"
[ "$_rc" = "0" ] || printf '%s\n' "$_o" | tail -8
has "  the client-side rehearsal verified the tag" "$_o" "Rehearsal: verify-archive: OK v2.0.0"
is "  tag v2.0.0 is on the remote" "$(git -C "$SB/relremote.git" tag -l v2.0.0)" "v2.0.0"
is "  the tag is signed (ssh)" "$(git -C "$RR" cat-file tag v2.0.0 | grep -c 'BEGIN SSH SIGNATURE')" "1"
is "  the remote master carries the manifest" "$(git -C "$SB/relremote.git" show master:RELEASE-MANIFEST | sed -n 's/^version=//p')" "2.0.0"
has "  a GitHub Release was created with both files" "$(cat "$SB/gh-called" 2>/dev/null)" "RELEASE-MANIFEST.sig"
is "  staging VERSION written" "$(tr -d '[:space:]' < "$RH/.claude/governance-installer/bundle/VERSION")" "2.0.0"
is "  the source machine is marked" "$([ -f "$RH/.claude/.governance-source" ] && echo yes || echo no)" "yes"
is "  and its own marker stamped" "$(tr -d '[:space:]' < "$RH/.claude/.governance-version")" "2.0.0"
echo "  (a release signed by a key clients of v2.0.0 do not have is refused)"
signer_line k2 > "$RR/bundle/release/allowed_signers"; cp "$RR/bundle/release/allowed_signers" "$RH/.claude/governance-installer/bundle/release/allowed_signers"
sed -i "s|$_fp1|$(ssh-keygen -lf "$SB/keys/k2.pub" | awk '{print $2}')|g" "$RR/README.md"
sed -i 's/(v2\.0\.0)/(v2.0.1)/' "$RR/README.md"; cp "$RR/README.md" "$RH/.claude/governance-installer/README.md"
rg add -A; rg commit -qm rotate-wrong; rg push -q origin master 2>/dev/null
printf 'GOV_REPO_PATH=%s\nGOV_RELEASE_KEY=%s\n' "$RR" "$SB/keys/k2" > "$RH/.claude/.governance-local.env"
_o=$(grel 2.0.1); _rc=$?
is "a new-key-only release without --new-key-only -> exit 1" "$_rc" "1"
has "  naming the reason" "$_o" "FAIL  the release key is pinned by clients of v2.0.0"
is "  no tag v2.0.1" "$(git -C "$SB/relremote.git" tag -l v2.0.1)" ""
fi

# ── mutants: the suite must be able to FAIL ─────────────────────────────────────────────────
# mutant <name> <sed expression> -> path of a mutated gov-update.sh beside copies of its libraries
mutant() {
  local d="$SB/mut-$1"; rm -rf "$d"; mkdir -p "$d"
  cp "$GOV_DIR/_common.sh" "$GOV_DIR/release-manifest.sh" "$d/"
  sed "$2" "$GOV_DIR/gov-update.sh" > "$d/gov-update.sh"
  if cmp -s "$GOV_DIR/gov-update.sh" "$d/gov-update.sh"; then echo ""; return; fi
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
  UPD_SCRIPT="$m" upd --apply-if-ready >/dev/null
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
  _s=$(date +%s%N); _o=$(upd --apply-if-ready); _e=$(date +%s%N)
  _r=$(grep -o 'mv retries [0-9]*' "$H/.claude/logs/governance-update.log" | tail -1)
  printf '  T12 run %s: %s ms, %s, %s\n' "$i" "$(( (_e - _s) / 1000000 ))" "$_r" "$(case "$_o" in *Applied*) echo applied ;; *) echo "NOT APPLIED: $_o" ;; esac)"
done
fi

echo ""
echo "test-gov-update: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
