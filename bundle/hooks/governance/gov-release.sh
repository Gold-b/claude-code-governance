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
# (gov_local_env_get: grep, never sourced - that file can carry a real token). The first successful
# run - and every later run that reaches the signed-tag push, even if the client check after it fails -
# creates ~/.claude/.governance-source: the marker that stops this machine from updating itself AND
# turns push at session close ON there (see consent-lib.sh).
#
# ONLY A PERSON RELEASES (2026-09-30, legal T7, S3, C6, C11). Before anything else it refuses:
#   - inside an AI-agent session (CLAUDECODE / AI_AGENT / CLAUDE_CODE_ENTRYPOINT set);
#   - with SSH_ASKPASS or SSH_ASKPASS_REQUIRE set (a passphrase could then be answered by a program;
#     Git for Windows sets SSH_ASKPASS in every login shell - `unset SSH_ASKPASS SSH_ASKPASS_REQUIRE`);
#   - when stdin is not a terminal.
# Every signature with the release key (the manifest and the tag) runs with stdin and stderr on
# that terminal, and with SSH_AUTH_SOCK unset, so a passphrase or touch prompt is visible and
# ssh-agent is never used. The signer then answers the four material-change questions (legal C6
# (a)-(d)); any "yes" without --terms-bump is refused, and the answers go into the release notes.
# Two more preconditions: the C11 network listing of the tree to be tagged (every file with a
# network-shaped line is mapped to the NOTICE section that discloses it; an unmapped file fails),
# and tests/test-terms-text.sh green on that tree.
#
# The test sandbox ONLY (tests/test-gov-update.sh [RELEASE]): when gov_consent_override_ok holds
# (the suite's nonce in a HOME that is not the real one), the markers do not refuse and the answers
# may come from the file GOV_RELEASE_ANSWERS (lines a=yes|no .. d=yes|no) instead of the terminal,
# and GOV_RELEASE_TERMS_TEST may name a stand-in for test-terms-text.sh. Under that override the
# repository, the key, the staging tree and origin (fetch AND push URL) must all resolve inside that
# HOME, so the override can reach nothing outside the sandbox. Without the override, setting
# GOV_RELEASE_ANSWERS or GOV_RELEASE_TERMS_TEST is itself a refusal.
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
command -v gov_local_env_get >/dev/null 2>&1 && command -v gov_agent_session >/dev/null 2>&1 \
  && command -v gov_consent_override_ok >/dev/null 2>&1 \
  || { echo "gov-release: consent-lib.sh did not load (gov_local_env_get / gov_agent_session missing) - refusing." >&2; exit 1; }

# ── Only a person releases (T7, S3). Nothing below this block runs, and nothing is written, unless
# a human at a terminal started it. Refusals go to stderr and exit 1.
refuse() { printf 'gov-release: REFUSED - %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '  %s\n' "$2" >&2; printf '  Nothing was written.\n' >&2; exit 1; }
_SANDBOX=1; gov_consent_override_ok && _SANDBOX=0
if gov_agent_session && [ "$_SANDBOX" != 0 ]; then
  refuse "this is an AI-agent session (CLAUDECODE / AI_AGENT / CLAUDE_CODE_ENTRYPOINT is set)." \
         "A release is signed by a person: run gov-release.sh yourself, in your own terminal, outside Claude Code."
fi
if [ -n "${SSH_ASKPASS:-}" ] || [ -n "${SSH_ASKPASS_REQUIRE:-}" ]; then
  refuse "SSH_ASKPASS${SSH_ASKPASS_REQUIRE:+ / SSH_ASKPASS_REQUIRE} is set: a program could answer the key's passphrase prompt instead of you." \
         "Run  unset SSH_ASKPASS SSH_ASKPASS_REQUIRE  in this terminal (Git for Windows sets SSH_ASKPASS in every login shell), then run this again."
fi
_ANSWERS="${GOV_RELEASE_ANSWERS:-}"
if [ -n "$_ANSWERS" ] || [ -n "${GOV_RELEASE_TERMS_TEST:-}" ]; then
  [ "$_SANDBOX" = 0 ] || refuse "GOV_RELEASE_ANSWERS / GOV_RELEASE_TERMS_TEST are for the test sandbox only." \
                                "The signer answers on the terminal, and test-terms-text.sh is the one this tree ships. Unset them."
fi
if [ -z "$_ANSWERS" ] && [ ! -t 0 ]; then
  refuse "stdin is not a terminal." \
         "The signer answers the release questions and any passphrase prompt on a terminal: run it in your own terminal, with no pipe or redirect into it."
fi

REPO=$(gov_local_env_get GOV_REPO_PATH)
KEY=$(gov_local_env_get GOV_RELEASE_KEY)
[ -n "$REPO" ] || { echo "gov-release: GOV_REPO_PATH is not set - this runs only on the release source machine." >&2; exit 1; }
[ -n "$KEY" ]  || { echo "gov-release: GOV_RELEASE_KEY is not set - put the path of the private release key in $LOCAL_ENV." >&2; exit 1; }
REPO=$(cd "$REPO" 2>/dev/null && pwd) || { echo "gov-release: GOV_REPO_PATH does not resolve" >&2; exit 1; }
case "$KEY" in "~/"*) KEY="$HOME/${KEY#\~/}" ;; esac
[ -f "$KEY" ] || { echo "gov-release: GOV_RELEASE_KEY does not resolve to a file" >&2; exit 1; }
TAG="v$VER"

# Under the sandbox override, everything the run could write to or sign with must be inside the
# sandbox HOME: the override then cannot cut a release of a real repository with a real key.
_in_home() {  # <path> -> 0 when it resolves (a file by its directory) inside $HOME
  local p="$1" d h
  [ -n "$p" ] || return 1
  if [ -d "$p" ]; then d=$(cd "$p" 2>/dev/null && pwd -P) || return 1
  else d=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || return 1; fi
  h=$(cd "$HOME" 2>/dev/null && pwd -P) || return 1
  case "$d/" in "$h"/*) return 0 ;; esac
  return 1
}
if [ "$_SANDBOX" = 0 ] && { gov_agent_session || [ -n "$_ANSWERS" ] || [ -n "${GOV_RELEASE_TERMS_TEST:-}" ]; }; then
  _ou=$(git -C "$REPO" remote get-url origin 2>/dev/null); _opu=$(git -C "$REPO" remote get-url --push origin 2>/dev/null)
  for _p in "$REPO" "$KEY" "$STAGING" "$_ou" "$_opu" ${GOV_RELEASE_TERMS_TEST:+"$GOV_RELEASE_TERMS_TEST"} ${_ANSWERS:+"$_ANSWERS"}; do
    { [ -e "$_p" ] && [ ! -L "$_p" ] && _in_home "$_p"; } \
      || refuse "the test-sandbox override is in use, but '$_p' is not inside the sandbox HOME." \
                "Under the override the repository, key, staging tree and origin (fetch and push URL) must all be local paths inside \$HOME."
  done
fi

# ── C6: the signer's four answers. Asked here, before the preconditions, so a "yes" without
# --terms-bump is one of the FAILs listed below and stops the run before any write.
C6_Q_a="(a) Does this release change NOTICE-AUTO-UPDATE.md section 10, the terms summary or the install questions?"
C6_Q_b="(b) Does it add or widen any action outside ~/.claude or outside the machine - a new network destination, a push, a posted or sent message, or deleting or rewriting user files outside the framework's own?"
C6_Q_c="(c) Does it turn any feature ON by default?"
C6_Q_d="(d) Does it send any information about the user or the user's projects to anyone, the maintainer included?"
C6_a=""; C6_b=""; C6_c=""; C6_d=""
echo "gov-release $VER$([ "$DRY" = "1" ] && echo ' (dry run)')  repo=$REPO"
_c6_norm() { case "$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '[:space:]')" in y|yes) echo yes ;; n|no) echo no ;; *) echo "" ;; esac; }
_prev_tag_for_hint=$(git -C "$REPO" tag -l 'v*' 2>/dev/null | sed 's/^v//' | while read -r t; do gov_is_semver "$t" && echo "$t"; done \
                     | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
echo "Material-change questions (legal C6) - answer each yes or no:"
if [ -n "$_prev_tag_for_hint" ]; then
  if git -C "$REPO" diff --quiet "v$_prev_tag_for_hint" HEAD -- NOTICE-AUTO-UPDATE.md 2>/dev/null; then
    echo "  (hint: NOTICE-AUTO-UPDATE.md is unchanged since v$_prev_tag_for_hint)"
  else
    echo "  (hint: NOTICE-AUTO-UPDATE.md CHANGED since v$_prev_tag_for_hint - read the diff before answering (a))"
  fi
fi
for _q in a b c d; do
  _qn="C6_Q_$_q"; _text="${!_qn}"
  _v=""
  if [ -n "$_ANSWERS" ]; then
    _v=$(_c6_norm "$(sed -n "s/^$_q=//p" "$_ANSWERS" 2>/dev/null | tail -1)")
    printf '  %s %s\n' "$_text" "${_v:-<no answer>}"
  else
    for _try in 1 2 3; do
      printf '  %s [yes/no] ' "$_text"
      IFS= read -r _raw || _raw=""
      _v=$(_c6_norm "$_raw"); [ -n "$_v" ] && break
      echo "  please type yes or no"
    done
  fi
  [ -n "$_v" ] || refuse "question $_q was not answered yes or no." "Every release needs all four answers (legal C6)."
  printf -v "C6_$_q" '%s' "$_v"
done
C6_LINE="a=$C6_a b=$C6_b c=$C6_c d=$C6_d"
C6_ANY_YES=0; case " $C6_LINE" in *=yes*) C6_ANY_YES=1 ;; esac
URL_TMPL="${GOV_UPDATE_ARCHIVE_URL:-https://github.com/Gold-b/claude-code-governance/archive/refs/tags/v%s.tar.gz}"

FAILS=0
chk() {  # chk <label> <0 = ok> [detail]
  if [ "$2" = "0" ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s%s\n' "$1" "${3:+ - $3}"; FAILS=$((FAILS + 1)); fi
}

echo "Preconditions:"

command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; chk "gh present and authenticated" $?
relman_have_sshsig; chk "ssh-keygen -Y available" $?
[ -z "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; chk "clean working tree" $? "commit or stash first"
[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "master" ]; chk "on master" $?
git -C "$REPO" fetch -q origin 2>/dev/null
git -C "$REPO" merge-base --is-ancestor origin/master HEAD 2>/dev/null; chk "HEAD contains origin/master (nothing to pull)" $? "pull first"
bash "$SCRIPT_DIR/end-session.sh" --publish-preview </dev/null >/dev/null 2>&1; chk "end-session.sh --publish-preview clean (no TARGET-AHEAD)" $?
_d=$(diff -rq --exclude=desktop.ini "$STAGING/bundle" "$REPO/bundle" 2>&1 | head -3)
[ -z "$_d" ]; chk "staging bundle/ == clone bundle/" $? "$_d"
# The publish queue records hook edits that reached STAGING. Every hook edit adds to it, so it is
# never empty on the machine where the release was just built. What matters is that nothing in it
# is missing from what this release commits: with staging == clone (checked above) every queued
# change is already in the clone, and this release publishes it. The queue is archived after the push.
_PQ="$CH/logs/.governance-push-pending"
if [ ! -f "$_PQ" ]; then
  chk "publish queue empty" 0
else
  [ -z "$_d" ]; chk "publish queue fulfilled by this release ($(sed 's|^[^ ]* ||' "$_PQ" 2>/dev/null | sort -u | grep -c .) queued file(s), all already in the clone)" $? "staging and clone differ - reconcile before releasing"
fi
_res="$CH/logs/governance-selftest.result"
# Computed EXACTLY as the verdict's writer computes it (selftest-advisory-stop.sh: the directory
# the suite lives in, hooks/governance). governance-selftest.sh's own _gov_tree_id hashes all of
# hooks/ — a different number for the same question; comparing against the wrong one refused a
# GREEN, current verdict (MEASURED 2026-09-25).
_fp_now=$(find "$SCRIPT_DIR" -type f \( -name '*.sh' -o -name '*.js' -o -name '*.py' -o -name '*.ps1' \) 2>/dev/null \
          | LC_ALL=C sort | xargs cat 2>/dev/null | sha256sum 2>/dev/null | cut -c1-12)
grep -q '^verdict=GREEN' "$_res" 2>/dev/null; chk "selftest verdict=GREEN (Stop-hook certified)" $? "$(grep -E '^(verdict|reason)=' "$_res" 2>/dev/null | tr '\n' ' ')"
[ "$(sed -n 's/^hooks_fingerprint=//p' "$_res" 2>/dev/null)" = "$_fp_now" ]; chk "the selftest verdict is about the live hooks tree now" $? "result $(sed -n 's/^hooks_fingerprint=//p' "$_res" 2>/dev/null) != live $_fp_now - re-run the selftest"
# The files a release SHIPS are the tracked ones: scanning the directory would also read untracked
# Windows desktop.ini files (never released, and they carry a version string the IPV4 rule flags).
(cd "$REPO" && git ls-files -z -- bundle | xargs -0 bash "$SCRIPT_DIR/check-no-pii.sh") </dev/null >/dev/null 2>&1; chk "check-no-pii.sh over every tracked bundle/ file" $?
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

# C6: a "yes" is a material change - it needs --terms-bump (the NOTICE footer, TERMS_PINNED in
# tests/test-terms-text.sh and bundle/TERMS-VERSION all go up), so every user re-accepts.
if [ "$C6_ANY_YES" = "1" ] && [ "$TERMS_BUMP" != "1" ]; then
  chk "C6 material-change answers ($C6_LINE) are consistent with the terms version" 1 \
      "a 'yes' is a material change: re-run with --terms-bump after raising the NOTICE footer and TERMS_PINNED"
else
  chk "C6 material-change answers ($C6_LINE) are consistent with the terms version$([ "$TERMS_BUMP" = "1" ] && echo ' (--terms-bump)')" 0
fi

# C11: every file of the tree to be tagged with a network-shaped line, listed against the NOTICE
# section that discloses it. A file this map does not know FAILS: a new network call ships only
# after it is named here AND in NOTICE section 3 (or 2a). Kinds: s3/s2a = the traffic, disclosed by
# the bullet named; tool = source machine only; local = the user's own local services; none/text =
# the words occur, no request is made.
C11_RE='curl|wget|https?://|gh api|fetch|http\.request'
c11_label() {  # <path in the tree> -> "<kind>|<text>", or nothing when the file is not mapped
  case "$1" in
    bundle/hooks/governance/pre-session.sh) echo "s3|The version check" ;;
    bundle/hooks/governance/gov-update.sh)  echo "s3|The release" ;;
    bundle/hooks/governance/close-push.sh|bundle/skills/live-state-orchestrator/SKILL.md)
                                            echo "s3|Push at session close" ;;
    bundle/hooks/governance/pr-watch.sh|bundle/skills/pr-follow-through/SKILL.md|bundle/skills/pr-to-git/SKILL.md)
                                            echo "s3|Pull-request checks" ;;
    bundle/hooks/governance/wa-send.js)     echo "s3|Notifications" ;;
    bundle/hooks/governance/end-session.sh) echo "s2a|(f) Publishing framework edits" ;;
    bundle/hooks/governance/gov-release.sh) echo "tool|the maintainer's release tool; runs on the release source machine only" ;;
    bundle/skills/full-finish/SKILL.md)     echo "local|curl to the user's own services (localhost health checks, the user's own endpoints) when the user runs /full-finish" ;;
    bundle/hooks/governance/check-no-pii.sh) echo "none|URL-shaped scanner patterns and fixture strings" ;;
    bundle/hooks/governance/governance-selftest.sh) echo "none|comments and a git-subcommand deny list (the tests it runs are listed on their own)" ;;
    bundle/hooks/governance/bootstrap-gate.sh|bundle/hooks/governance/canonical-cwd-check.sh|bundle/hooks/governance/close-report.sh|bundle/hooks/governance/consent-guard.sh|bundle/hooks/governance/deny-git-bypass.sh)
                                            echo "none|the words occur in comments, messages or command patterns" ;;
    bundle/hooks/governance/tests/*)        echo "none|test fixtures: file:// remotes, 127.0.0.1 stubs, stubbed curl and gh" ;;
    bundle/.governance-local.env.example|.githooks/*|install.sh) echo "none|comments and messages" ;;
    bundle/hooks/governance/consent-lib.sh) echo "none|the close-push question text ('fetched')" ;;
    README.md|NOTICE-AUTO-UPDATE.md|bundle/docs/*.md|PARALLEL-SESSION-NOTES/*.md)
                                            echo "text|documentation: links and descriptions, not a request" ;;
  esac
}
_notice_sec() {  # <heading prefix, e.g. "## 3."> -> that section of the tree's NOTICE
  git -C "$REPO" show "HEAD:NOTICE-AUTO-UPDATE.md" 2>/dev/null | tr -d '\r' \
    | awk -v h="$1" 'index($0, h) == 1 { on = 1; next } on && /^## / { exit } on { print }'
}
_n3=$(_notice_sec "## 3."); _n2a=$(_notice_sec "## 2a.")
_c11_bad=""
echo "  C11 network listing of the tree to be tagged (HEAD $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)):"
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  _n=$(git -C "$REPO" grep -c -I -E "$C11_RE" HEAD -- "$_f" 2>/dev/null | sed 's/.*://')
  _lab=$(c11_label "$_f"); _k="${_lab%%|*}"; _t="${_lab#*|}"
  case "$_k" in
    s3)  if printf '%s\n' "$_n3" | grep -qF "**$_t"; then _st="NOTICE 3 '$_t'"; else _st="MISSING: NOTICE 3 has no bullet '$_t'"; _c11_bad="$_c11_bad $_f"; fi ;;
    s2a) if printf '%s\n' "$_n2a" | grep -qF "**$_t"; then _st="NOTICE 2a '$_t'"; else _st="MISSING: NOTICE 2a has no item '$_t'"; _c11_bad="$_c11_bad $_f"; fi ;;
    tool|local|none|text) _st="$_k: $_t" ;;
    *)   _st="UNLISTED - name it in gov-release.sh c11_label and in NOTICE section 3"; _c11_bad="$_c11_bad $_f" ;;
  esac
  printf '    %-52s %3s line(s)  %s\n' "$_f" "${_n:-?}" "$_st"
done <<EOF_C11
$(git -C "$REPO" grep -l -I -E "$C11_RE" HEAD -- . 2>/dev/null | sed 's/^HEAD://')
EOF_C11
[ -z "$_c11_bad" ]; chk "C11: every network-shaped line is listed against the NOTICE" $? "not listed:$_c11_bad"

# The accepted texts say what this tree does (legal C1, C8, C9, C11): tests/test-terms-text.sh on
# the tree to be tagged, with the terms version this release will carry (takes ~2 minutes).
_tt_dir=$(mktemp -d 2>/dev/null) || _tt_dir=""
_tt_rc=1; _tt_last=""
if [ -n "$_tt_dir" ] && relman_archive_tree "$REPO" HEAD "$_tt_dir" 2>/dev/null; then
  printf '%s\n' "$_tv" > "$_tt_dir/bundle/TERMS-VERSION"
  _tt="${GOV_RELEASE_TERMS_TEST:-$_tt_dir/bundle/hooks/governance/tests/test-terms-text.sh}"
  _tt_out=$(bash "$_tt" "$_tt_dir" </dev/null 2>&1); _tt_rc=$?
  _tt_last=$(printf '%s\n' "$_tt_out" | tail -1)
fi
[ -n "$_tt_dir" ] && rm -rf "$_tt_dir"
[ "$_tt_rc" = "0" ]; chk "tests/test-terms-text.sh green on the tree to be tagged (${_tt_last:-did not run})" $?

if [ "$FAILS" -gt 0 ]; then
  rm -f "$_prev_signers"; echo "gov-release: $FAILS precondition(s) failed - nothing was written."
  exit 1
fi
if [ "$DRY" = "1" ]; then
  rm -f "$_prev_signers"; echo "gov-release: dry run - every precondition passes (C6 answers: $C6_LINE). Nothing was written."
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
# S3: stdin and stderr stay on the signer's terminal (a passphrase or touch prompt is visible and
# answerable only there), and SSH_AUTH_SOCK is unset so the key never comes from an ssh-agent.
echo "Signing RELEASE-MANIFEST with $KEY (answer any passphrase or touch prompt here):"
env -u SSH_AUTH_SOCK ssh-keygen -Y sign -f "$KEY" -n "$RELMAN_NS" "$REPO/RELEASE-MANIFEST" || die "signing failed"
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
echo "Signing tag $TAG with the same key:"
env -u SSH_AUTH_SOCK git -C "$REPO" -c gpg.format=ssh -c user.signingkey="$KEY" tag -s "$TAG" -m "Release $VER" \
    -m "Material-change review (legal C6), answered by the signer: $C6_LINE" || die "signed tag failed"
git -C "$REPO" push -q origin master "$TAG" || die "push failed (the pre-push gate may have refused it)"
# The queued publish is now on the remote with this release; keep the list as a record.
[ -f "$_PQ" ] && mv -f "$_PQ" "$_PQ.released-v$VER" 2>/dev/null
awk -v v="(v$VER)" 'index($0, v) { on = 1 } on && /^- \*\*/ && !index($0, v) { exit } on { print }' "$REPO/README.md" > "$_work/notes"
# C6: the signer's four answers travel with the release (and are in the signed tag message).
{
  printf '\n### Material-change review (legal C6)\n\n'
  printf 'Answered by the person who signed this release. Terms version: %s (%s).\n\n' "$_tv" "$([ "$TERMS_BUMP" = "1" ] && echo raised || echo unchanged)"
  for _q in a b c d; do _qn="C6_Q_$_q"; _an="C6_$_q"; printf -- '- %s **%s**\n' "${!_qn}" "${!_an}"; done
} >> "$_work/notes"
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
