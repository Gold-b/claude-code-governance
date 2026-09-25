#!/usr/bin/env bash
# gov-release.sh — cut a SIGNED release of this framework. Source machine only.
#
# TOOL: run by hand by the maintainer; covered by case_gov_update (tests/test-gov-update.sh builds
# its fixtures with the same release-manifest.sh library and rehearses this tool's dry run).
#
# Usage:
#   bash ~/.claude/hooks/governance/gov-release.sh <version> [--terms-bump] [--dry-run] [--new-key-only]
#
#   --new-key-only  EMERGENCY key rotation only (old key suspected stolen): sign with a key the
#                   previous release's signers file does not contain. Every client then halts that
#                   version with reason `signature` until its owner re-pins by hand (README).
#   GOV_RELEASE_LOCAL_REHEARSAL=1  rehearse against `git archive` of the pushed tag instead of the
#                   GitHub download (tests only; a real release rehearses the real download)
#
# What a release IS (2.0.0). A commit on master carrying RELEASE-MANIFEST (the SHA-256 of every file
# of the tagged tree plus the install map) and RELEASE-MANIFEST.sig (an SSH signature by the release
# key), tagged v<version> with a signed tag, pushed, and published as a GitHub Release with both
# files attached. Clients install ONLY such a tree, verified against the key pinned at install.
#
# Order of work, each step refusing with a named reason:
#   1. preconditions — every one printed PASS/FAIL; any FAIL stops the run before a single write
#   2. bundle/VERSION (and TERMS-VERSION with --terms-bump) written to STAGING first, then the
#      clone, same bytes — otherwise the next publish aborts TARGET-AHEAD
#   3. RELEASE-MANIFEST built from `git archive` of the exact tree to be tagged (never the working
#      tree: core.autocrlf), signed, then proven both ways: the bundle's key verifies it AND a
#      throwaway key's signature does NOT
#   4. commit (the tracked PII pre-commit gate runs), signed tag, push master + tag in one push,
#      GitHub Release with both files attached
#   5. client-side rehearsal: download the tag archive exactly as a client does and verify it under
#      a sandbox HOME whose pinned key is the bundle's. Red = the release is unusable: the exact
#      delete commands are printed, NOT run.
#
# Reads GOV_REPO_PATH and GOV_RELEASE_KEY from the environment or from ~/.claude/.governance-local.env
# (with grep — that file can carry a real token; it is never sourced). The first successful run
# creates ~/.claude/.governance-source, the marker that stops this machine from auto-updating itself.
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { echo "gov-release: cannot load _common.sh" >&2; exit 1; }
# shellcheck source=/dev/null
. "$SCRIPT_DIR/release-manifest.sh" 2>/dev/null || { echo "gov-release: cannot load release-manifest.sh" >&2; exit 1; }

VER=""; TERMS_BUMP=0; DRY=0; NEW_KEY_ONLY=0
for a in "$@"; do
  case "$a" in
    --terms-bump) TERMS_BUMP=1 ;;
    --dry-run)    DRY=1 ;;
    --new-key-only) NEW_KEY_ONLY=1 ;;
    --help|-h)    sed -n '2,/^set +e/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           echo "gov-release: unknown option $a" >&2; exit 2 ;;
    *)            VER="$a" ;;
  esac
done
gov_is_semver "$VER" || { echo "gov-release: usage: gov-release.sh <x.y.z> [--terms-bump] [--dry-run]" >&2; exit 2; }

CH="$HOME/.claude"
LOCAL_ENV="$CH/.governance-local.env"
STAGING="${GOV_RELEASE_STAGING:-$CH/governance-installer}"
env_get() {
  local k="$1" v=""
  eval "v=\${$k:-}"
  if [ -z "$v" ] && [ -f "$LOCAL_ENV" ]; then
    v=$(grep -E "^[[:space:]]*(export[[:space:]]+)?$k=" "$LOCAL_ENV" 2>/dev/null | tail -1 \
        | sed -e 's/^[^=]*=//' -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
              -e 's/^["'\'']//' -e 's/["'\'']$//')
  fi
  printf '%s' "$v"
}
REPO=$(env_get GOV_REPO_PATH)
KEY=$(env_get GOV_RELEASE_KEY)
[ -n "$REPO" ] || { echo "gov-release: GOV_REPO_PATH is not set - this runs only on the release source machine." >&2; exit 1; }
[ -n "$KEY" ]  || { echo "gov-release: GOV_RELEASE_KEY is not set - put the path of the private release key in $LOCAL_ENV." >&2; exit 1; }
REPO=$(cd "$REPO" 2>/dev/null && pwd) || { echo "gov-release: GOV_REPO_PATH does not resolve" >&2; exit 1; }
case "$KEY" in "~/"*) KEY="$HOME/${KEY#\~/}" ;; esac
[ -f "$KEY" ] || { echo "gov-release: GOV_RELEASE_KEY does not resolve to a file" >&2; exit 1; }
TAG="v$VER"
URL_TMPL="${GOV_UPDATE_ARCHIVE_URL:-https://github.com/Gold-b/claude-code-governance/archive/refs/tags/v%s.tar.gz}"

FAILS=0
chk() {  # chk <label> <0 = ok> [detail]
  if [ "$2" = "0" ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s%s\n' "$1" "${3:+ - $3}"; FAILS=$((FAILS + 1)); fi
}

echo "gov-release $VER$([ "$DRY" = "1" ] && echo ' (dry run)')  repo=$REPO"
echo "Preconditions:"

command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; chk "gh present and authenticated" $?
relman_have_sshsig; chk "ssh-keygen -Y available" $?
[ -z "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; chk "clean working tree" $? "commit or stash first"
[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "master" ]; chk "on master" $?
git -C "$REPO" fetch -q origin 2>/dev/null
git -C "$REPO" merge-base --is-ancestor origin/master HEAD 2>/dev/null; chk "HEAD contains origin/master (nothing to pull)" $? "pull first"
[ ! -f "$CH/logs/.governance-push-pending" ]; chk "publish queue empty" $? "a held GOV_PUBLISH queue exists - publish or clear it first"
bash "$SCRIPT_DIR/end-session.sh" --publish-preview </dev/null >/dev/null 2>&1; chk "end-session.sh --publish-preview clean (no TARGET-AHEAD)" $?
_d=$(diff -rq --exclude=desktop.ini "$STAGING/bundle" "$REPO/bundle" 2>&1 | head -3)
[ -z "$_d" ]; chk "staging bundle/ == clone bundle/" $? "$_d"
_res="$CH/logs/governance-selftest.result"
_fp_now=$(find "$CH/hooks" -type f \( -name '*.sh' -o -name '*.js' -o -name '*.py' -o -name '*.ps1' \) 2>/dev/null \
          | LC_ALL=C sort | xargs cat 2>/dev/null | sha256sum 2>/dev/null | cut -c1-12)
grep -q '^verdict=GREEN' "$_res" 2>/dev/null; chk "selftest verdict=GREEN (Stop-hook certified)" $? "$(grep -E '^(verdict|reason)=' "$_res" 2>/dev/null | tr '\n' ' ')"
[ "$(sed -n 's/^hooks_fingerprint=//p' "$_res" 2>/dev/null)" = "$_fp_now" ]; chk "the selftest verdict is about the live hooks tree now" $? "result $(sed -n 's/^hooks_fingerprint=//p' "$_res" 2>/dev/null) != live $_fp_now - re-run the selftest"
bash "$SCRIPT_DIR/check-no-pii.sh" --tree "$REPO/bundle" </dev/null >/dev/null 2>&1; chk "check-no-pii.sh --tree bundle" $?
grep -qF "(v$VER)" "$REPO/README.md"; chk "README.md changelog has a (v$VER) entry" $?
[ -f "$REPO/LICENSE" ] && [ -f "$REPO/NOTICE-AUTO-UPDATE.md" ]; chk "LICENSE and NOTICE-AUTO-UPDATE.md present" $?
_tv=$(tr -d '[:space:]' < "$REPO/bundle/TERMS-VERSION" 2>/dev/null); case "$_tv" in ''|*[!0-9]*) _tv=0 ;; esac
[ "$TERMS_BUMP" = "1" ] && _tv=$((_tv + 1))
grep -qx "Terms version: $_tv" "$REPO/NOTICE-AUTO-UPDATE.md"; chk "NOTICE says 'Terms version: $_tv'" $?
_newest=$(git -C "$REPO" tag -l 'v*' 2>/dev/null | sed 's/^v//' | while read -r t; do gov_is_semver "$t" && echo "$t"; done \
          | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
_cmp=gt; [ -n "$_newest" ] && gov_semver_cmp_var _cmp "$VER" "$_newest"
[ "$_cmp" = "gt" ]; chk "$VER is newer than the newest tag (${_newest:-none})" $?
_cur=$(tr -d '[:space:]' < "$REPO/bundle/VERSION" 2>/dev/null); _cmp2=gt; gov_is_semver "$_cur" && gov_semver_cmp_var _cmp2 "$VER" "$_cur"
[ "$_cmp2" = "gt" ] || [ "$_cmp2" = "eq" ]; chk "$VER is not older than bundle/VERSION (${_cur:-none})" $?
git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; [ $? -ne 0 ]; chk "tag $TAG does not exist yet" $?
_signers="$REPO/bundle/release/allowed_signers"
# What CLIENTS have pinned is the signers file of the PREVIOUS release, not this one: a release
# signed only by a key that is new in this tree verifies against its own file and against nothing
# any client holds. The controls below use the previous file (the first release has none).
_prev_signers="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/gov-prev-signers.$$")"
if [ -n "$_newest" ] && git -C "$REPO" show "v$_newest:bundle/release/allowed_signers" > "$_prev_signers" 2>/dev/null && [ -s "$_prev_signers" ]; then
  _prev_label="v$_newest"
else
  cp "$_signers" "$_prev_signers" 2>/dev/null; _prev_label="this tree (first signed release)"
fi
_pubk=$(ssh-keygen -y -f "$KEY" </dev/null 2>/dev/null | cut -d' ' -f1,2)
if [ -n "$_pubk" ] && grep -qF "$_pubk" "$_prev_signers" 2>/dev/null; then _in_prev=0; else _in_prev=1; fi
if [ "$NEW_KEY_ONLY" = "1" ]; then
  chk "--new-key-only: EMERGENCY rotation acknowledged (clients pinned to $_prev_label will halt)" 0
else
  chk "the release key is pinned by clients of $_prev_label (else every client halts)" $_in_prev "rotate in two releases (old+new signers signed by old), or --new-key-only for an emergency"
fi
_pub=$(ssh-keygen -y -f "$KEY" </dev/null 2>/dev/null | cut -d' ' -f1,2)
[ -n "$_pub" ] && grep -qF "$_pub" "$_signers" 2>/dev/null; chk "the release key's public half is in bundle/release/allowed_signers" $?
_line=$(grep -F "${_pub:-no-key}" "$_signers" 2>/dev/null | head -1)
_vb=$(printf '%s' "$_line" | sed -n 's/.*valid-before="\{0,1\}\([0-9]\{8\}\).*/\1/p')
_days=-1
if [ -n "$_vb" ]; then _days=$(( ( $(date -d "$_vb" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 )); fi
_nkeys=$(grep -c "^$RELMAN_PRINCIPAL " "$_signers" 2>/dev/null)
{ [ "$_days" -ge 90 ] || [ "${_nkeys:-0}" -ge 2 ]; }; chk "key valid for >= 90 more days, or a successor key already pinned ($_days days left, ${_nkeys:-0} key(s))" $?
_fp=$(ssh-keygen -lf "$KEY.pub" 2>/dev/null | awk '{print $2}')
[ -n "$_fp" ] && grep -qF "$_fp" "$REPO/README.md"; chk "README.md carries the key fingerprint ${_fp:-?}" $?

if [ "$FAILS" -gt 0 ]; then
  rm -f "$_prev_signers"; echo "gov-release: $FAILS precondition(s) failed - nothing was written."
  exit 1
fi
if [ "$DRY" = "1" ]; then
  rm -f "$_prev_signers"; echo "gov-release: dry run - every precondition passes. Nothing was written."
  exit 0
fi

die() { echo "gov-release: $*" >&2; exit 1; }

git -C "$REPO" pull -q --ff-only origin master || die "git pull --ff-only origin master failed"

# 2. VERSION — staging first, then the clone, same bytes.
printf '%s\n' "$VER" > "$STAGING/bundle/VERSION" || die "cannot write staging VERSION"
cp "$STAGING/bundle/VERSION" "$REPO/bundle/VERSION" || die "cannot write clone VERSION"
_add="bundle/VERSION"
if [ "$TERMS_BUMP" = "1" ]; then
  { printf '%s\n' "$_tv" > "$STAGING/bundle/TERMS-VERSION" && cp "$STAGING/bundle/TERMS-VERSION" "$REPO/bundle/TERMS-VERSION"; } || die "cannot write TERMS-VERSION"
  _add="$_add bundle/TERMS-VERSION"
fi

# 3. Manifest from the exact tree to be tagged (the index, VERSION included, manifest excluded).
# shellcheck disable=SC2086
git -C "$REPO" add -- $_add || die "git add failed"
_tree=$(git -C "$REPO" write-tree) || die "git write-tree failed"
_work=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$_work" "$_prev_signers"' EXIT
relman_archive_tree "$REPO" "$_tree" "$_work/t" || die "git archive failed"
bash "$_work/t/install.sh" --print-install-map > "$_work/map" 2>"$_work/map.err" </dev/null || die "install.sh --print-install-map failed: $(head -3 "$_work/map.err")"
relman_build "$_work/t" "$VER" "$_tv" "$_work/map" > "$REPO/RELEASE-MANIFEST" || die "manifest build failed"
rm -f "$REPO/RELEASE-MANIFEST.sig"
ssh-keygen -Y sign -f "$KEY" -n "$RELMAN_NS" "$REPO/RELEASE-MANIFEST" </dev/null >/dev/null 2>&1 || die "signing failed"
relman_verify_sig "$REPO/RELEASE-MANIFEST" "$REPO/RELEASE-MANIFEST.sig" "$_signers" || die "POSITIVE CONTROL FAILED: the new signature does not verify under bundle/release/allowed_signers"
if [ "$NEW_KEY_ONLY" != "1" ]; then
  relman_verify_sig "$REPO/RELEASE-MANIFEST" "$REPO/RELEASE-MANIFEST.sig" "$_prev_signers" \
    || die "POSITIVE CONTROL FAILED: the signature does not verify under the signers clients have pinned ($_prev_label)"
fi
ssh-keygen -q -t ed25519 -N '' -f "$_work/throwaway" -C t </dev/null >/dev/null 2>&1
cp "$REPO/RELEASE-MANIFEST" "$_work/m"
ssh-keygen -Y sign -f "$_work/throwaway" -n "$RELMAN_NS" "$_work/m" </dev/null >/dev/null 2>&1
if relman_verify_sig "$_work/m" "$_work/m.sig" "$_signers"; then die "NEGATIVE CONTROL FAILED: a throwaway key's signature verified - the signers file trusts too much"; fi
relman_verify_tree "$REPO/RELEASE-MANIFEST" "$_work/t" || die "the manifest does not describe the archived tree"
relman_check_map "$REPO/RELEASE-MANIFEST" "$_work/t" || die "install map failed its safety check"

# 4. Commit, tag, push, Release.
_subject=$(grep -m1 -F "(v$VER)" "$REPO/README.md" | sed -e 's/.*(v[0-9.]*)[^A-Za-z0-9]*//' -e 's/\*\*//g' -e 's/[[:space:]]*$//' | cut -c1-72)
git -C "$REPO" add -- RELEASE-MANIFEST RELEASE-MANIFEST.sig || die "git add of the manifest failed"
git -C "$REPO" commit -q -m "Release $VER: ${_subject:-signed release}" -m "Signed release manifest (RELEASE-MANIFEST + .sig) for $TAG." || die "commit failed (the PII pre-commit gate may have refused it)"
git -C "$REPO" show --stat --oneline HEAD | head -8
relman_archive_tree "$REPO" HEAD "$_work/c" || die "archive of the release commit failed"
relman_verify_tree "$REPO/RELEASE-MANIFEST" "$_work/c" || die "the COMMITTED tree does not match the manifest - not tagging"
git -C "$REPO" -c gpg.format=ssh -c user.signingkey="$KEY" tag -s "$TAG" -m "Release $VER" || die "signed tag failed"
git -C "$REPO" push -q origin master "$TAG" || die "push failed (the pre-push gate may have refused it)"
awk -v v="(v$VER)" 'index($0, v) { on = 1 } on && /^- \*\*/ && !index($0, v) { exit } on { print }' "$REPO/README.md" > "$_work/notes"
gh release create "$TAG" --repo "$(git -C "$REPO" remote get-url origin | sed 's|.*github.com[:/]||; s|\.git$||')" \
   --title "$TAG" --notes-file "$_work/notes" "$REPO/RELEASE-MANIFEST" "$REPO/RELEASE-MANIFEST.sig" >/dev/null \
   || echo "gov-release: WARNING - gh release create failed; the tag is pushed and is what clients use."
touch "$CH/.governance-source" 2>/dev/null
# The source machine's live tree IS this release: stamp it, or its own advisory would report the
# release it just made as an update it does not have.
printf '%s\n' "$VER" > "$CH/.governance-version" 2>/dev/null

# 5. Client-side rehearsal against the real download.
_url="${URL_TMPL//%s/$VER}"
_ok=0
for _try in 1 2 3 4 5 6; do
  if [ "${GOV_RELEASE_LOCAL_REHEARSAL:-0}" = "1" ]; then
    git -C "$REPO" -c core.autocrlf=false -c core.eol=lf archive --format=tar --prefix="claude-code-governance-$VER/" "$TAG" 2>/dev/null \
      | gzip -c > "$_work/rel.tgz" && [ -s "$_work/rel.tgz" ] && { _ok=1; break; }
  elif curl -sSL --proto '=https' --proto-redir '=https' -m 120 -o "$_work/rel.tgz" "$_url" 2>/dev/null && [ -s "$_work/rel.tgz" ]; then _ok=1; break; fi
  sleep 10
done
_sbx="$_work/sandbox-user"
mkdir -p "$_sbx/.claude/.governance-update"
cp "$_prev_signers" "$_sbx/.claude/.governance-update/allowed_signers"
_rh=""
# stdout carries the verdict line; stderr (e.g. a "deep verify SKIPPED" notice) is shown on failure.
if [ "$_ok" = "1" ] && _rh=$(HOME="$_sbx" GOVERNANCE_HOOKS=1 bash "$SCRIPT_DIR/gov-update.sh" --verify-archive "$_work/rel.tgz" 2>"$_work/rh.err" </dev/null); then
  echo "Rehearsal: $_rh"
  [ -s "$_work/rh.err" ] && sed 's/^/  (rehearsal note) /' "$_work/rh.err"
else
  echo "gov-release: REHEARSAL FAILED - clients cannot install $TAG: ${_rh:-download failed} $(cat "$_work/rh.err" 2>/dev/null)"
  echo "  Remove the release by hand after reading why:"
  echo "    git -C \"$REPO\" push --delete origin $TAG && git -C \"$REPO\" tag -d $TAG"
  echo "    gh release delete $TAG --yes"
  exit 1
fi

echo "Released $VER"
echo "  tag:              $TAG $(git -C "$REPO" rev-parse --short "$TAG^{commit}")"
echo "  manifest sha256:  $(relman_sha256 "$REPO/RELEASE-MANIFEST")"
echo "  files:            $(relman_get "$REPO/RELEASE-MANIFEST" files)"
echo "  key fingerprint:  $_fp"
echo "  key days left:    $_days"
