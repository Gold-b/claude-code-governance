#!/usr/bin/env bash
# close-push.sh — the ONE place a session close pushes the current repository (2026-09-29).
#
# WHY. The owner decided that a session close runs end to end with no human, and that it includes a
# `git push` of the session's commits. Before this, no close path pushed an ordinary project:
# live-state-orchestrator had no git step, end-session.sh pushes only the framework's own public
# repo behind GOV_PUBLISH, and /full-finish pushes only as part of a release. Three prose paths
# that each "push at the end" would drift apart, so every close path calls this script instead
# (HITL-removal board, CTO condition 1 / CEO condition 8).
#
# DESIGN: a fast-forward of the current branch onto its existing, same-name upstream - or nothing.
# Three independent review rounds kept finding edge cases in "push, and if rejected rebase and retry"
# (flattened merges, a mode flipped on the remote mid-close, a deleted branch recreated, a remote
# rewound past a secret re-published). So the script does less: it FETCHES first and decides on the
# remote's real state, and when the branch is behind it does not rebase - it reports and stops.
# Committing is the caller's step (add + commit of the session's own paths in ONE call, then
# `git show --stat`), because only the session knows which paths are its own.
#
# It pushes (`git push --no-follow-tags --recurse-submodules=no <remote> HEAD:<branch>`) only when
# ALL of these hold; otherwise it prints why and the close continues:
#   * current branch, an existing upstream of the SAME name on the fetch remote, the branch still
#     exists on the remote, and the local branch is not behind it;
#   * no separate push URL, no second URL, no pushRemote / pushDefault elsewhere, not a mirror remote;
#   * not the governance framework's own clone (its push is the public release: GOV_PUBLISH only);
#   * `close_push` is not `off` in any manifest from the -C directory up to the root (working tree,
#     pinned commit or upstream - any `off` wins), and under the default `auto` the remote is a
#     known-private GitHub repo or a local path without receive hooks, and the pushed commit carries
#     no file on the CI / deploy-config list below (a LIST, not a guarantee: a repo whose push can
#     deploy needs the owner's `close_push: off`) - the owner's `close_push: on`, already on the
#     REMOTE's manifest, lifts those holds;
#   * no secret shape anywhere in what is published: added lines of every commit (merges included,
#     binaries as text), every commit message and every file name; for anything not known to stay
#     private also the PII scanner. Fail-closed.
#   * no other close holds the lock.
# After the push it fetches again and verifies the pushed commit is on the upstream branch.
#
# OUTPUT: one line, starting with PUSHED / NOTHING / SKIP / HOLD / NOT PUSHED.
# EXIT: always 0 — a close never blocks on a push; the caller records a HOLD / NOT PUSHED line in
# HANDOFF. Exit 1 only for a usage error.
#
# Usage: close-push.sh [-C <dir>] [--dry-run] | --selftest
# Env:   GOV_CLOSE_PUSH=0 (never push), GOVERNANCE_HOOKS=0 (all governance off),
#        GOV_CLOSE_PUSH_TIMEOUT (seconds per network step, default 20)
set -u

_cp_dir="$PWD"; _cp_dry=0; _cp_want_selftest=0
while [ $# -gt 0 ]; do
  case "$1" in
    -C) [ $# -ge 2 ] && [ -n "$2" ] || { echo "close-push: -C needs a directory" >&2; exit 1; }
        _cp_dir="$2"; shift 2 ;;
    --dry-run) _cp_dry=1; shift ;;
    --selftest) _cp_want_selftest=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "close-push: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# The scan must see the objects the push sends: no replace refs, no textconv (review round 4).
export GIT_NO_REPLACE_OBJECTS=1
# An inherited GIT_DIR / GIT_WORK_TREE beats `git -C` and would make every command below act on a
# DIFFERENT repository than -C names (round 7 measured a push to the wrong repo). Clear them all.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_NAMESPACE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM
_CP_SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
_CP_DIR_OF_SELF="$(dirname "$_CP_SELF")"
_CP_TO="${GOV_CLOSE_PUSH_TIMEOUT:-20}"
_CP_PUSH_TO="${GOV_CLOSE_PUSH_PUSH_TIMEOUT:-120}"   # the push itself may carry a lot

_cp_log() {
  local log="$HOME/.claude/logs/governance.log"
  [ -d "$HOME/.claude/logs" ] || return 0
  printf '[%s] [close-push] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$log" 2>/dev/null
  return 0
}
_cp_out() { printf '[close-push] %s\n' "$1"; _cp_log "$1"; }

# _cp_t <cmd...>: run with a timeout when `timeout` exists (macOS has none by default).
_cp_t() { if command -v timeout >/dev/null 2>&1; then timeout "$_CP_TO" "$@"; else "$@"; fi; }

# ── secret shapes: the PII scanner's own SECRET rule, plus AWS access keys (that rule has none) ───
_cp_secret_re() {
  local re=""
  if [ -f "$_CP_DIR_OF_SELF/check-no-pii.sh" ]; then
    re=$(bash "$_CP_DIR_OF_SELF/check-no-pii.sh" --list-rules 2>/dev/null \
         | awk '$1=="SECRET"{sub(/^SECRET[[:space:]]+/,""); print; exit}')
  fi
  [ -n "$re" ] || re='(gh[pousr]_[A-Za-z0-9]{28,})|(github_pat_[A-Za-z0-9_]{40,})|(sk-[A-Za-z0-9_-]{24,})|(-----BEGIN [A-Z ]{0,24}PRIVATE KEY-----)'
  printf '%s|(AKIA[0-9A-Z]{16})|(ASIA[0-9A-Z]{16})' "$re"
}

# ── manifest frontmatter: close_push: on|off|auto (absent = auto) ────────────────────────────────
# stdin = a manifest's text. Tolerates a UTF-8 BOM, CRLF and `close_push :` spacing - a parser that
# misread the owner's `off` as `auto` would push the very repo he held.
# With frontmatter the key is read inside it only; a manifest WITHOUT frontmatter is searched in its
# first 60 lines, so an owner's `close_push: off` written as a plain line is not silently ignored.
# EVERY close_push line is read, not the first: with `on` and a later `off`, `off` wins (round 5).
_cp_mode_of() {
  local vals v bad="" seen_on=0 seen_off=0
  vals=$(sed '1s/^\xEF\xBB\xBF//' 2>/dev/null | tr -d '\r' | awk '
        NR==1 { fm = ($0 ~ /^---[[:space:]]*$/); if (fm) next }
        fm && /^---[[:space:]]*$/ {exit}
        !fm && NR>60 {exit}
        { l = tolower($0) }
        l ~ /^[[:space:]]*[-*]?[[:space:]]*`?close[-_ ]?push`?[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*/,"",l); sub(/[[:space:]]*#.*$/,"",l); gsub(/[`"'"'"'[:space:]]/,"",l); print l}' 2>/dev/null)
  while IFS= read -r v; do
    case "$v" in on) seen_on=1 ;; off) seen_off=1 ;; auto|"") ;; *) [ -n "$bad" ] || bad="$v" ;; esac
  done <<EOF
$vals
EOF
  if [ -n "$bad" ]; then printf 'invalid:%s' "$bad"
  elif [ "$seen_off" = 1 ]; then printf 'off'
  elif [ "$seen_on" = 1 ]; then printf 'on'
  else printf 'auto'; fi
}
# Effective mode, read AFTER a fresh fetch: `off` or an invalid value from the working tree, HEAD or
# the upstream wins; `on` counts only from the upstream (a value the session itself wrote stays
# `auto` until the owner has pushed it).
# Every governed manifest between the -C directory and the repo root counts (round 7: a project in a
# SUBFOLDER of a bigger repo had its `off` ignored because only <root>/docs/context/ was read). $4..
# are the manifest paths relative to the root. `off`/invalid in ANY of them wins; `on` needs the
# upstream copy of the manifest NEAREST the -C directory (the first one given).
_cp_mode() {
  local root="$1" up="$2" sha="$3"; shift 3
  local rel wt hd us all="" nearest_us="" nearest_hd="" first=1
  for rel in "$@"; do
    wt=$( { [ -f "$root/$rel" ] && cat "$root/$rel"; } 2>/dev/null | _cp_mode_of)
    hd=$(git -C "$root" show "$sha:$rel" 2>/dev/null | _cp_mode_of)   # the pinned commit, not HEAD
    us=$(git -C "$root" show "$up:$rel" 2>/dev/null | _cp_mode_of)
    all="$all $wt $hd $us"
    if [ "$first" = 1 ]; then nearest_us="$us"; nearest_hd="$hd"; first=0; fi
  done
  case "$all" in *invalid:*) printf '%s\n' $all | grep -m1 '^invalid:'; return ;; esac
  case "$all" in *off*) printf 'off'; return ;; esac
  [ "$nearest_us" = "on" ] && { printf 'on'; return; }
  # The pinned commit carries an `on` the upstream does not have: pushing it would put the session's
  # own `on` on the remote, where it lifts every later hold (round 4). Held until the owner pushes it.
  case "$all" in *on*) [ "$nearest_us" = "on" ] || { printf 'pending-on'; return; } ;; esac
  printf 'auto'
}
# Manifest paths (relative to <root>) from the -C directory up to the root, nearest first.
# git itself gives the -C directory's path relative to the root (`--show-prefix`), so a -C spelled in
# a different letter case than the folder on disk (NTFS is case-insensitive) still walks every level
# (final review: a string compare of two `pwd -P` spellings skipped the root manifest).
_cp_manifests() {
  local root="$1" d="$2" pre list=""
  pre=$(git -C "$d" rev-parse --show-prefix 2>/dev/null) || pre=""
  pre="${pre%/}"
  while :; do
    if [ -n "$pre" ]; then list="$list$pre/docs/context/CONTEXT-MANIFEST.md
"
    else list="${list}docs/context/CONTEXT-MANIFEST.md
"; break; fi
    case "$pre" in */*) pre="${pre%/*}" ;; *) pre="" ;; esac
  done
  printf '%s' "$list"
}

# ── CI / deploy signals: ANY one holds an `auto` push ───────────────────────────────────────────
# Rounds 5-6 showed that deciding "does this CI deploy on push?" from file contents cannot be done
# reliably: CircleCI, Travis, Azure (`trigger:`), GitLab, Bitbucket, Buildkite and Jenkins start on a
# push without the word in the file, and a GitHub `workflow_run` chain splits test and deploy across
# two files. So the rule is presence, not content: a repo whose pushed commit carries ANY CI
# definition or ANY deploy tool's config is held under `auto`, and the owner - who knows what his CI
# does - writes `close_push: on` for it once. A false hold costs one line; a miss is an unattended
# production deploy. Read from the COMMIT (ls-tree -z, quotePath off, so non-ASCII paths match),
# never the working tree; a listing that fails is a hold, not "no signal".
# Still invisible, and documented as such: a host wired through its own dashboard with no file in
# the repo (a Vercel / Netlify / Cloudflare Pages Git integration).
_cp_deploy_signal() {
  local r="$1" sha="$2" f base listing
  git -C "$r" cat-file -e "$sha^{tree}" 2>/dev/null \
    || { printf 'the file list of the pushed commit could not be read'; return 0; }
  listing=$(git -c core.quotePath=false -C "$r" ls-tree -r -z --name-only "$sha" 2>/dev/null | tr '\0' '\n')
  [ -n "$listing" ] || { printf 'the file list of the pushed commit is empty or unreadable'; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="${f##*/}"
    case "$base" in
      vercel.json|netlify.toml|fly.toml|render.yaml|render.yml|Procfile|app.yaml|app.json|wrangler.toml|wrangler.json|wrangler.jsonc|firebase.json|.firebaserc|amplify.yml|now.json|serverless.yml|serverless.yaml|heroku.yml|railway.json|railway.toml|nixpacks.toml|apprunner.yaml|apprunner.yml|.platform.app.yaml|codefresh.yml|.cirrus.yml|.cirrus.star|.gitlab-ci.yml|bitbucket-pipelines.yml|azure-pipelines.yml|azure-pipelines.yaml|.travis.yml|Jenkinsfile|.drone.yml|.woodpecker.yml|.woodpecker.yaml|cloudbuild.yaml|cloudbuild.yml|buildspec.yml|buildspec.yaml|appveyor.yml|.appveyor.yml|codemagic.yaml|bitrise.yml|skaffold.yaml|Tiltfile|wercker.yml|shippable.yml|.gocd.yaml|.deployment|deploy.yml|deploy.yaml)
        printf '%s' "$f"; return 0 ;;
      # Coarse name catch-alls for CI systems not listed above: a false hold costs one `on`.
      *-ci.yml|*-ci.yaml|*.ci.yml|*.ci.yaml|*pipeline.yml|*pipeline.yaml|*pipelines.yml|*pipelines.yaml)
        printf '%s' "$f"; return 0 ;;
    esac
    case "$f" in
      .github/workflows/*|.circleci/*|.buildkite/*|.woodpecker/*|.gitea/workflows/*|.forgejo/workflows/*|.azure-pipelines/*|.semaphore/*|.teamcity/*|.eas/*|.upsun/*|.platform/*|.harness/*|.tekton/*|.argo/*|.cloudbuild/*|.github/actions/*)
        printf '%s' "$f"; return 0 ;;
    esac
  done <<EOF
$listing
EOF
  if git -C "$r" remote -v 2>/dev/null | grep -qi 'heroku'; then printf 'heroku remote'; return 0; fi
  return 1
}

# ── Git LFS: the push uploads the real objects, the scan only ever sees pointer text ─────────────
_cp_uses_lfs() {
  local r="$1" sha="$2" f
  while IFS= read -r f; do
    case "$f" in .gitattributes|*/.gitattributes)
      git -C "$r" show "$sha:$f" 2>/dev/null | grep -qiE 'filter[[:space:]]*=[[:space:]]*lfs' && { printf '%s' "$f"; return 0; } ;;
    esac
  done < <(git -c core.quotePath=false -C "$r" ls-tree -r -z --name-only "$sha" 2>/dev/null | tr '\0' '\n')
  return 1
}

# ── a LOCAL-path remote that deploys when it receives a push ────────────────────────────────────
# Classic push-to-deploy: a bare repo with a post-receive / post-update / update hook, or a non-bare
# target with receive.denyCurrentBranch=updateInstead (round 7 measured a DEPLOYED marker written).
# The path is resolved the way git resolves it (final review): relative to the repo ROOT, not the
# caller's cwd; `file:///C:/x` -> `C:/x`. A remote that is a local path but cannot be found is a HOLD
# (fail closed), not "does not deploy". Hooks are looked for where receive-pack runs them: the
# target's core.hooksPath (its own or the global one) as well as <gitdir>/hooks.
_cp_local_remote_deploys() {
  local url="$1" root="$2" p g h hp dir
  case "$url" in
    file://localhost/*) p="${url#file://localhost}" ;;
    file:///*)          p="${url#file://}" ;;
    //*|\\\\*|file://*|*://*) return 1 ;;          # network share or a real host: not ours to check
    *) p="$url" ;;
  esac
  case "$p" in /[A-Za-z]:[/\\]*) p="${p#/}" ;; esac   # /C:/x (Windows file URL) -> C:/x
  case "$p" in
    /*|[A-Za-z]:[/\\]*) ;;
    *) case "$url" in *:*) return 1 ;; esac          # scp-form user@host:path is a real host
       p="$root/$p" ;;
  esac
  if [ ! -d "$p" ]; then printf 'the local remote path %s could not be found' "$p"; return 0; fi
  g=$(git -C "$p" rev-parse --absolute-git-dir 2>/dev/null) || g="$p"
  hp=$(git -C "$p" config --get core.hooksPath 2>/dev/null)
  for dir in "$g/hooks" ${hp:+"$hp"} ${hp:+"$p/$hp"} ${hp:+"$g/$hp"}; do
    for h in pre-receive update post-receive post-update push-to-checkout reference-transaction proc-receive; do
      [ -f "$dir/$h" ] && { printf 'the target repo has a %s hook (%s)' "$h" "$dir"; return 0; }
    done
  done
  [ "$(git -C "$p" config --get receive.denyCurrentBranch 2>/dev/null)" = "updateInstead" ] \
    && { printf 'the target repo updates its working tree on push (updateInstead)'; return 0; }
  return 1
}

# ── the HOST of a remote URL (not a substring match) ────────────────────────────────────────────
# scheme://[user@]host[:port]/path -> host ; [user@]host:path (scp form) -> host ; a path -> "" .
_cp_host() {
  local u="$1" h
  case "$u" in
    file://*|/*|[A-Za-z]:[/\\]*|./*|../*|\\\\*) printf ''; return ;;
    *://*) h="${u#*://}"; h="${h%%/*}"; h="${h##*@}"; h="${h%%:*}" ;;
    *:*)   h="${u%%:*}"; h="${h##*@}" ;;
    *)     h="" ;;
  esac
  printf '%s' "$h" | tr 'A-Z' 'a-z'
}

# ── visibility: PUBLIC / PRIVATE / INTERNAL / UNKNOWN / LOCAL ────────────────────────────────────
# Only the exact host github.com is asked (via gh). Any other host - GitLab, Bitbucket, a proxy whose
# PATH merely contains "github.com", an SSH alias like github-work - is UNKNOWN, held under `auto`.
# LOCAL = a single-slash path, a drive path or a host-less file:/// URL (an NFS/SMB mount under a
# plain path cannot be told apart - stated limit). `//server/share`, `\\server\share` and
# file://host/... are network shares: UNKNOWN.
# The selftest's override is honoured ONLY when $HOME holds the nonce file the selftest wrote.
_cp_visibility() {
  local url="$1" host slug v
  if [ -n "${_CP_IN_SELFTEST:-}" ] && [ -n "${_CP_TEST_VISIBILITY:-}" ] \
     && [ "$(cat "$HOME/.close-push-selftest" 2>/dev/null)" = "$_CP_IN_SELFTEST" ]; then
    printf '%s' "$_CP_TEST_VISIBILITY"; return
  fi
  case "$url" in
    //*|\\\\*|file://[!/]*) printf 'UNKNOWN'; return ;;
    file:///*|/*|[A-Za-z]:[/\\]*|./*|../*) printf 'LOCAL'; return ;;
  esac
  host=$(_cp_host "$url")
  [ "$host" = "github.com" ] || { printf 'UNKNOWN'; return; }
  case "$url" in
    *://*) slug="${url#*://}"; slug="${slug#*/}" ;;
    *)     slug="${url#*:}" ;;
  esac
  slug="${slug%.git}"; slug="${slug%/}"
  command -v gh >/dev/null 2>&1 || { printf 'UNKNOWN'; return; }
  v=$(GH_PROMPT_DISABLED=1 _cp_t gh repo view "github.com/$slug" --json visibility -q .visibility 2>/dev/null | tr -d '\r[:space:]')
  case "$v" in PUBLIC|PRIVATE|INTERNAL) printf '%s' "$v" ;; *) printf 'UNKNOWN' ;; esac
}

# ── is this the framework's own clone? (URL or structure; a push there is the public release) ────
_cp_is_governance_repo() {
  local r="$1" url="$2"
  case "$url" in */claude-code-governance|*/claude-code-governance.git) return 0 ;; esac
  [ -f "$r/install.sh" ] && [ -f "$r/bundle/settings-hooks.json" ] && [ -f "$r/bundle/VERSION" ] && return 0
  return 1
}

close_push_main() {
  local dir="$1" root branch up remote rbranch url mode ahead behind sig vis re hits src rc lock
  local nurl npurl prem pdef added pf purls sha upn

  [ "${GOVERNANCE_HOOKS:-1}" = "0" ] && { _cp_out "SKIP (GOVERNANCE_HOOKS=0)"; return 0; }
  [ "${GOV_CLOSE_PUSH:-1}" = "0" ] && { _cp_out "SKIP (GOV_CLOSE_PUSH=0)"; return 0; }

  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || { _cp_out "SKIP (not a git repository: $dir)"; return 0; }
  branch=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null) || { _cp_out "SKIP (detached HEAD)"; return 0; }
  remote=$(git -C "$root" config --get "branch.$branch.remote" 2>/dev/null)
  rbranch=$(git -C "$root" config --get "branch.$branch.merge" 2>/dev/null); rbranch="${rbranch#refs/heads/}"
  if [ -z "$remote" ] || [ -z "$rbranch" ] || [ "$remote" = "." ]; then
    _cp_out "SKIP (branch $branch has no upstream; this script never creates one)"; return 0
  fi
  # The full ref, never the short `origin/main`: a local tag or branch literally named origin/main
  # would win git's disambiguation and skew every count, the scan range and the verify.
  up="refs/remotes/$remote/$rbranch"; upn="$remote/$rbranch"
  if [ "$branch" != "$rbranch" ]; then
    _cp_out "HOLD (local branch $branch tracks $upn - a different name; this script pushes only to a same-name upstream)"; return 0
  fi
  prem=$(git -C "$root" config --get "branch.$branch.pushRemote" 2>/dev/null)
  pdef=$(git -C "$root" config --get remote.pushDefault 2>/dev/null)
  if { [ -n "$prem" ] && [ "$prem" != "$remote" ]; } || { [ -z "$prem" ] && [ -n "$pdef" ] && [ "$pdef" != "$remote" ]; }; then
    _cp_out "HOLD (a push remote other than $remote is configured (pushRemote/pushDefault); push by hand)"; return 0
  fi
  # git pushes to EVERY url when a remote has several, and to the pushurl(s) when any is set; the
  # checks below only look at the one fetch URL, so either shape is held.
  nurl=$(git -C "$root" config --get-all "remote.$remote.url" 2>/dev/null | grep -c .)
  npurl=$(git -C "$root" config --get-all "remote.$remote.pushurl" 2>/dev/null | grep -c .)
  if [ "${nurl:-0}" -ne 1 ] || [ "${npurl:-0}" -ne 0 ]; then
    _cp_out "HOLD (remote $remote has $nurl url(s) and $npurl push url(s); only one url and no push url is pushed automatically)"; return 0
  fi
  # receivepack / uploadpack pick the PROGRAM at the other end - a wrapper can send the push to a
  # different repository than the URL names, and the verify fetch would read the same wrapper.
  if [ -n "$(git -C "$root" config --get "remote.$remote.receivepack" 2>/dev/null)" ] \
     || [ -n "$(git -C "$root" config --get "remote.$remote.uploadpack" 2>/dev/null)" ]; then
    _cp_out "HOLD (remote $remote sets receivepack/uploadpack; push by hand)"; return 0
  fi
  if [ "$(git -C "$root" config --type=bool --get "remote.$remote.mirror" 2>/dev/null)" = "true" ]; then
    _cp_out "HOLD (remote $remote is a mirror remote; a push would rewrite every ref)"; return 0
  fi
  # The URLs git will REALLY use, after url.<X>.insteadOf / pushInsteadOf rewriting (round 4: a
  # pushInsteadOf rule sent the push to another repository). One fetch URL and one push URL, equal.
  url=$(git -C "$root" remote get-url "$remote" 2>/dev/null)
  purls=$(git -C "$root" remote get-url --push --all "$remote" 2>/dev/null)
  if [ -z "$url" ] || [ "$(printf '%s\n' "$purls" | grep -c .)" -ne 1 ] || [ "$purls" != "$url" ]; then
    _cp_out "HOLD (remote $remote pushes to a different URL than it fetches from (pushurl / insteadOf / pushInsteadOf); push by hand)"; return 0
  fi
  if _cp_is_governance_repo "$root" "$url"; then
    _cp_out "HOLD (the governance framework's own clone: a push here is the public release - GOV_PUBLISH + gov-release.sh only)"; return 0
  fi

  # Decide on the REMOTE's real state, never a stale local tracking ref.
  if ! GIT_TERMINAL_PROMPT=0 _cp_t git -C "$root" fetch --quiet --no-tags "$remote" "+refs/heads/$rbranch:refs/remotes/$remote/$rbranch" >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 _cp_t git -C "$root" ls-remote --exit-code --heads "$remote" "$rbranch" >/dev/null 2>&1; rc=$?
    case "$rc" in
      0) _cp_out "NOT PUSHED (could not fetch $upn)" ;;
      2) _cp_out "HOLD ($upn no longer exists on the remote (deleted, e.g. after a merged PR); this script never recreates a branch)" ;;
      *) _cp_out "NOT PUSHED (remote unreachable; commits stay local on $branch)" ;;
    esac
    return 0
  fi
  # Pin the commit now. Everything below - counts, scan, push, verify - is about THIS sha, so a
  # commit another session makes in this worktree meanwhile is never pushed unscanned (round 4).
  # Pin the BRANCH's tip, not HEAD: another session checking out a different branch in this worktree
  # during the fetch must not get its tip pushed onto this branch's upstream (final review).
  sha=$(git -C "$root" rev-parse --verify "refs/heads/$branch^{commit}" 2>/dev/null) || { _cp_out "NOT PUSHED (cannot read refs/heads/$branch)"; return 0; }
  behind=$(git -C "$root" rev-list --count "$sha..$up" 2>/dev/null)
  ahead=$(git -C "$root" rev-list --count "$up..$sha" 2>/dev/null)
  [ -n "$behind" ] && [ -n "$ahead" ] || { _cp_out "NOT PUSHED (cannot compare $branch with $upn)"; return 0; }
  if [ "$behind" != "0" ]; then
    _cp_out "NOT PUSHED ($branch is $behind commit(s) behind $upn - merge or rebase by hand; the close never rewrites history)"; return 0
  fi
  [ "$ahead" = "0" ] && { _cp_out "NOTHING to push ($branch is not ahead of $upn)"; return 0; }

  local -a mans=()
  while IFS= read -r _m; do [ -n "$_m" ] && mans+=("$_m"); done < <(_cp_manifests "$root" "$dir")
  [ ${#mans[@]} -gt 0 ] || mans=("docs/context/CONTEXT-MANIFEST.md")
  mode=$(_cp_mode "$root" "$up" "$sha" "${mans[@]}")
  case "$mode" in
    off) _cp_out "HOLD (close_push: off in CONTEXT-MANIFEST)"; return 0 ;;
    invalid:*) _cp_out "HOLD (close_push has an unknown value '${mode#invalid:}' - expected on|off|auto)"; return 0 ;;
    pending-on) _cp_out "HOLD (the outgoing commits carry 'close_push: on' that the remote does not have yet - the owner pushes that line himself)"; return 0 ;;
  esac

  vis=$(_cp_visibility "$url")
  if [ "$mode" = "auto" ]; then
    case "$vis" in
      PUBLIC)  _cp_out "HOLD (remote is PUBLIC; the owner's 'close_push: on', once it is on the remote, lets a close push it)"; return 0 ;;
      UNKNOWN) _cp_out "HOLD (remote visibility could not be read - not github.com, or gh missing or failing; the owner's 'close_push: on' lifts this)"; return 0 ;;
      INTERNAL) _cp_out "HOLD (remote is INTERNAL - visible to the whole organisation; the owner's 'close_push: on' lifts this)"; return 0 ;;
    esac
    if sig=$(_cp_deploy_signal "$root" "$sha"); then
      _cp_out "HOLD (CI or deploy config in the pushed commit: $sig; the owner's 'close_push: on' lifts this)"; return 0
    fi
    if sig=$(_cp_local_remote_deploys "$url" "$root"); then   # any remote that is a directory on this machine
      _cp_out "HOLD (local remote may deploy on push: $sig; the owner's 'close_push: on' lifts this)"; return 0
    fi
  fi

  # Git LFS content is uploaded by the push but invisible to the scan below - held in every mode.
  if sig=$(_cp_uses_lfs "$root" "$sha"); then
    _cp_out "HOLD (Git LFS in use ($sig): LFS file contents cannot be scanned - push by hand)"; return 0
  fi

  # Secret scan of everything the push publishes, as two separate streams so neither can be mistaken
  # for the other (rounds 4-5): (1) the ADDED lines of every commit (-m: merges too; --text: binaries
  # as text) - only `+` lines, never context lines that already sit on the remote; (2) every commit
  # message, whole. Fail-closed: grep exits 2 on a pattern it cannot compile, and no count must never
  # read as no hits.
  re=$(_cp_secret_re)
  # The user's own log config must not narrow the scan (final review): log.diffMerges=off hid merge
  # diffs, log.showRoot=false hid a root commit. Both are pinned per call, plus explicit
  # --diff-merges=separate and --root.
  local -a _lg=(-c log.diffMerges=separate -c log.showRoot=true -c diff.noprefix=false -c diff.mnemonicPrefix=false -c core.quotePath=false)
  src=$(git "${_lg[@]}" -C "$root" log -p --diff-merges=separate --root --text --no-textconv --no-color --no-ext-diff --format= "$up..$sha" 2>/dev/null) || {
    _cp_out "NOT PUSHED (could not read the outgoing commits for the secret scan)"; return 0; }
  local msgs; msgs=$(git "${_lg[@]}" -C "$root" log --no-color --format='%B' "$up..$sha" 2>/dev/null) || {
    _cp_out "NOT PUSHED (could not read the outgoing commit messages for the secret scan)"; return 0; }
  # Author / committer identities are published too: they go through the SECRET scan (a token pasted
  # into a name), but not the PII scan - a commit identity in a repo the owner chose to publish is
  # expected, and blocking it would hold every public push (use a noreply address to keep it private).
  local idents; idents=$(git "${_lg[@]}" -C "$root" log --no-color --format='%an <%ae>%n%cn <%ce>' "$up..$sha" 2>/dev/null) || {
    _cp_out "NOT PUSHED (could not read the outgoing commit identities for the secret scan)"; return 0; }
  # File PATHS are published too, so they are a third stream (a secret-shaped or PII-bearing name).
  local names; names=$(git "${_lg[@]}" -C "$root" log --diff-merges=separate --root --no-color --name-only --format= "$up..$sha" 2>/dev/null) || {
    _cp_out "NOT PUSHED (could not read the outgoing file names for the secret scan)"; return 0; }
  # Diff STRUCTURE decides what is a header (round 7): everything from a `diff --git` line up to the
  # first `@@` hunk line is header; inside a hunk every `+` line is content, whatever it looks like.
  added=$( { printf '%s\n' "$src" | awk '
               /^diff --git / { hdr=1; next }
               hdr && /^@@/   { hdr=0; next }
               hdr            { next }
               /^\+/          { print substr($0, 2) }'
             printf '%s\n' "$msgs"; printf '%s\n' "$names"; } )
  hits=$( { printf '%s\n' "$added"; printf '%s\n' "$idents"; } | grep -acE "$re" 2>/dev/null); rc=$?
  if [ "$rc" -gt 1 ] || [ -z "$hits" ]; then
    _cp_out "NOT PUSHED (the secret scan could not run - grep rc=$rc; nothing is pushed unscanned)"; return 0
  fi
  if [ "$hits" != "0" ]; then
    _cp_out "NOT PUSHED (secret-shaped string in $hits line(s) of the outgoing commits or their messages - rotate it, rewrite that history, then push by hand)"; return 0
  fi
  # The PII scanner runs for everything not known to stay private: PUBLIC, UNKNOWN (reachable here
  # only with the owner's `on`) and INTERNAL. Fail-closed when the scanner is missing.
  if [ "$vis" != "PRIVATE" ] && [ "$vis" != "LOCAL" ]; then
    if [ ! -f "$_CP_DIR_OF_SELF/check-no-pii.sh" ]; then
      _cp_out "NOT PUSHED ($vis remote and check-no-pii.sh is missing - nothing is published unscanned)"; return 0
    fi
    pf=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/cp-pii.$$")
    printf '%s\n' "$added" > "$pf"
    if ! bash "$_CP_DIR_OF_SELF/check-no-pii.sh" "$pf" >/dev/null 2>&1; then
      rm -f "$pf"; _cp_out "NOT PUSHED (PII scanner hit in the outgoing commits of a $vis repo - run check-no-pii.sh on them)"; return 0
    fi
    rm -f "$pf"
  fi

  if [ "$_cp_dry" = 1 ]; then _cp_out "DRY-RUN would push $ahead commit(s): git push $remote HEAD:$rbranch"; return 0; fi

  # One close at a time in this worktree: `mkdir` is atomic. A lock left by a dead close is NOT taken
  # over automatically (a takeover can race a live one); it is reported for a human to remove.
  lock="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)/gov-close.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
      _cp_out "NOT PUSHED (a close lock older than 15 min is left at $lock - remove it if no close is running)"
    else
      _cp_out "NOT PUSHED (another close holds $lock)"
    fi
    return 0
  fi
  trap 'rm -rf "$lock" 2>/dev/null' RETURN

  # A plain push only fast-forwards; if the remote moved since the fetch it is rejected - and then
  # nothing is retried. --no-follow-tags / --recurse-submodules=no: a user's push.followTags or
  # submodule.recurse must not turn a close into a tag or a submodule push.
  # The pinned, scanned sha is pushed - never whatever HEAD has become since.
  local prc=0
  _CP_TO="$_CP_PUSH_TO" GIT_TERMINAL_PROMPT=0 _cp_t git -C "$root" push --quiet --no-follow-tags --recurse-submodules=no "$remote" "$sha:refs/heads/$rbranch" >/dev/null 2>&1 || prc=$?

  # Verify against the REMOTE whatever the push reported: a push killed by the timeout after the
  # remote accepted it must not be recorded as "not pushed" (round 6), nor a reported success believed.
  if GIT_TERMINAL_PROMPT=0 _cp_t git -C "$root" fetch --quiet --no-tags "$remote" "+refs/heads/$rbranch:refs/remotes/$remote/$rbranch" >/dev/null 2>&1; then
    # Our commit is ON the remote branch - the tip itself, or an ancestor of it when another client
    # pushed on top in the meantime.
    if git -C "$root" merge-base --is-ancestor "$sha" "$up" 2>/dev/null; then
      _cp_out "PUSHED ${sha:0:7} -> $upn (verified after fetch)"; return 0
    fi
    if [ "$prc" != 0 ]; then
      _cp_out "NOT PUSHED (push rejected or unreachable - the remote moved, or the branch is protected; commits stay local)"; return 0
    fi
    _cp_out "NOT PUSHED (push reported success but $upn != ${sha:0:7} after fetch)"; return 0
  fi
  if [ "$prc" != 0 ]; then
    _cp_out "NOT PUSHED (push failed (rc=$prc) and the remote could not be re-read - state UNKNOWN; check $upn by hand)"; return 0
  fi
  _cp_out "PUSHED ${sha:0:7} -> $upn (NOT verified: the verifying fetch failed)"
  return 0
}

# ══ --selftest: every branch against LOCAL bare origins, both directions ═══════════════════════
close_push_selftest() {
  local T pass=0 fail=0 o rc
  T=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/cp-st.$$"); mkdir -p "$T"
  export HOME="$T/home"; mkdir -p "$HOME/.claude/logs"
  export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.email "you@example.com"; git config --global user.name "selftest"
  git config --global init.defaultBranch main
  git config --global protocol.file.allow always
  _ck() { # _ck <label> <expected-prefix> <output>
    case "$3" in "[close-push] $2"*) pass=$((pass+1)); echo "  [PASS] $1" ;;
      *) fail=$((fail+1)); echo "  [FAIL] $1 - expected '$2', got: $3" ;; esac
  }
  _yes() { pass=$((pass+1)); echo "  [PASS] $1"; }
  _no()  { fail=$((fail+1)); echo "  [FAIL] $1"; }
  _mk() { # _mk <name> [manifest-extra-line] -> a clone of a fresh bare origin, one commit ahead
    local n="$1" extra="${2:-}"
    git init --quiet --bare "$T/$n.git"
    git clone --quiet "$T/$n.git" "$T/$n" 2>/dev/null
    mkdir -p "$T/$n/docs/context"
    { printf -- '---\ntype: manifest\n'; [ -n "$extra" ] && printf '%s\n' "$extra"; printf -- '---\n'; } > "$T/$n/docs/context/CONTEXT-MANIFEST.md"
    printf 'a\n' > "$T/$n/a.txt"
    git -C "$T/$n" add -A; git -C "$T/$n" commit --quiet -m base
    git -C "$T/$n" push --quiet -u origin main 2>/dev/null
    printf 'b\n' >> "$T/$n/a.txt"; git -C "$T/$n" commit --quiet -am ahead
  }
  _other() { # _other <name>: a second clone pushes one new commit to the origin
    git clone --quiet "$T/$1.git" "$T/$1-o" 2>/dev/null
    printf 'o\n' > "$T/$1-o/o.txt"; git -C "$T/$1-o" add o.txt; git -C "$T/$1-o" commit --quiet -m other
    git -C "$T/$1-o" push --quiet origin main 2>/dev/null
  }
  _origin_has() { git --git-dir="$T/$1.git" rev-parse --verify --quiet "$2" >/dev/null; }
  local NONCE="st-$$-$RANDOM$RANDOM"; printf '%s' "$NONCE" > "$HOME/.close-push-selftest"
  _run() { _CP_IN_SELFTEST="$NONCE" bash "$_CP_SELF" -C "$1" 2>&1 | tail -1; }
  unset GOV_CLOSE_PUSH GOVERNANCE_HOOKS
  export _CP_TEST_VISIBILITY=PRIVATE
  local tok36; tok36=$(printf 'A%.0s' $(seq 1 36))

  # 1. MUST PUSH - private, clean, ahead; the origin really holds HEAD; a second run has nothing
  _mk p1; o=$(_run "$T/p1"); _ck "private clean repo one commit ahead: pushed and verified" "PUSHED" "$o"
  [ "$(git -C "$T/p1" rev-parse HEAD)" = "$(git --git-dir="$T/p1.git" rev-parse main)" ] && _yes "the bare origin really holds HEAD" || _no "the bare origin does not hold HEAD"
  o=$(_run "$T/p1"); _ck "second run: nothing to push" "NOTHING" "$o"
  # 2. no upstream -> skipped, never created
  git -C "$T/p1" checkout --quiet -b lonely; printf 'c\n' >> "$T/p1/a.txt"; git -C "$T/p1" commit --quiet -am c
  o=$(_run "$T/p1"); _ck "branch without upstream: skipped" "SKIP (branch lonely has no upstream" "$o"
  _origin_has p1 refs/heads/lonely && _no "a remote branch was created" || _yes "no remote branch created"
  # 3-4. off / kill switch
  _mk p3 "close_push: off"; o=$(_run "$T/p3"); _ck "close_push: off wins" "HOLD (close_push: off" "$o"
  _mk p3b; printf '\xEF\xBB\xBF---\r\ntype: manifest\r\nclose_push : off\r\n---\r\n' > "$T/p3b/docs/context/CONTEXT-MANIFEST.md"
  o=$(_run "$T/p3b"); _ck "off with a BOM, CRLF and 'close_push :' spacing is still off" "HOLD (close_push: off" "$o"
  _mk p4; o=$(GOV_CLOSE_PUSH=0 _run "$T/p4"); _ck "GOV_CLOSE_PUSH=0 skips" "SKIP (GOV_CLOSE_PUSH=0)" "$o"
  # 5. PUBLIC: auto holds; a session-written `on` still holds; `on` already on the remote pushes
  _mk p5; o=$(_CP_TEST_VISIBILITY=PUBLIC _run "$T/p5"); _ck "PUBLIC remote under auto: held" "HOLD (remote is PUBLIC" "$o"
  printf -- '---\ntype: manifest\nclose_push: on\n---\n' > "$T/p5/docs/context/CONTEXT-MANIFEST.md"; git -C "$T/p5" commit --quiet -am "session writes on"
  o=$(_CP_TEST_VISIBILITY=PUBLIC _run "$T/p5"); _ck "close_push: on committed by the session, not on the remote: held" "HOLD (the outgoing commits carry 'close_push: on'" "$o"
  _mk p5d; printf -- '---\ntype: manifest\nclose_push: on\n---\n' > "$T/p5d/docs/context/CONTEXT-MANIFEST.md"; git -C "$T/p5d" commit --quiet -am "session writes on"
  o=$(_run "$T/p5d"); _ck "a PRIVATE repo does not carry the session's own on to the remote either" "HOLD (the outgoing commits carry 'close_push: on'" "$o"
  _origin_has p5d "$(git -C "$T/p5d" rev-parse HEAD)^{commit}" && _no "the session's on reached the remote" || _yes "the session's on did not reach the remote"
  _mk p5e "close_push: off"; printf -- '---\ntype: manifest\n---\n' > "$T/p5e/docs/context/CONTEXT-MANIFEST.md"; git -C "$T/p5e" commit --quiet -am "session drops off"
  o=$(_run "$T/p5e"); _ck "off only on the upstream (the session removed it locally): still off" "HOLD (close_push: off" "$o"
  _mk p5g; printf -- '---\ntype: manifest\nclose_push: on\nclose_push: off\n---\n' > "$T/p5g/docs/context/CONTEXT-MANIFEST.md"
  o=$(_CP_TEST_VISIBILITY=PUBLIC _run "$T/p5g"); _ck "duplicate keys on then off: off wins" "HOLD (close_push: off" "$o"
  _mk p5f; printf '# Manifest\n\nclose_push: off\n' > "$T/p5f/docs/context/CONTEXT-MANIFEST.md"
  o=$(_run "$T/p5f"); _ck "a manifest WITHOUT frontmatter: its close_push: off line is honoured" "HOLD (close_push: off" "$o"
  _mk p5c "close_push: on"; o=$(_CP_TEST_VISIBILITY=PUBLIC _run "$T/p5c"); _ck "PUBLIC, the owner's on already on the remote: pushed" "PUSHED" "$o"
  # 5b. the visibility override is refused without the selftest's nonce file
  # A forged override claims PUBLIC on a LOCAL remote: honoured it would HOLD; ignored (correct) the
  # remote stays LOCAL and is pushed. Then the real nonce DOES apply PUBLIC - both directions.
  _mk p5b
  o=$(_CP_IN_SELFTEST=forged _CP_TEST_VISIBILITY=PUBLIC bash "$_CP_SELF" -C "$T/p5b" 2>&1 | tail -1)
  _ck "a forged selftest override is ignored (the local remote stays LOCAL and is pushed)" "PUSHED" "$o"
  _mk p5bb; o=$(_CP_TEST_VISIBILITY=PUBLIC _run "$T/p5bb"); _ck "the real nonce does apply the override (control)" "HOLD (remote is PUBLIC" "$o"
  # 6. unknown visibility, a proxy whose PATH contains github.com, scp form, a UNC share
  _mk p6; o=$(_CP_TEST_VISIBILITY=UNKNOWN _run "$T/p6"); _ck "unreadable visibility under auto: held" "HOLD (remote visibility could not be read" "$o"
  o=$(_CP_TEST_VISIBILITY=INTERNAL _run "$T/p6"); _ck "INTERNAL (organisation-visible) under auto: held" "HOLD (remote is INTERNAL" "$o"
  [ "$(_cp_host 'https://git-proxy.example.invalid/github.com/acme/r.git')" = "git-proxy.example.invalid" ] && _yes "a proxy URL is classified by its HOST, not by a github.com substring" || _no "proxy URL host misread"
  [ "$(_cp_host "$(printf '%s@%s:acme/r.git' git github.com)")" = "github.com" ] && _yes "scp-form github URL: host github.com" || _no "scp-form host misread"
  [ "$(_CP_IN_SELFTEST= _cp_visibility '//fileserver/share/repo.git')" = "UNKNOWN" ] && _yes "//server/share is a network share (UNKNOWN), not LOCAL" || _no "UNC path classed LOCAL"
  # 7. deploy signal -> hold
  _mk p7; printf '{}\n' > "$T/p7/vercel.json"; git -C "$T/p7" add vercel.json; git -C "$T/p7" commit --quiet -m v
  o=$(_run "$T/p7"); _ck "deploy-on-push signal under auto: held" "HOLD (CI or deploy config in the pushed commit: vercel.json" "$o"
  _mk p7b; mkdir -p "$T/p7b/.github/workflows"; printf '"on": [push]\njobs:\n  d:\n    steps:\n      - run: npm run deploy\n' > "$T/p7b/.github/workflows/d.yml"
  git -C "$T/p7b" add -A; git -C "$T/p7b" commit --quiet -m wf
  o=$(_run "$T/p7b"); _ck "a quoted \"on\": [push] deploy workflow: held" "HOLD (CI or deploy config in the pushed commit: .github/workflows/d.yml" "$o"
  _mk p7c; mkdir -p "$T/p7c/.github/workflows"; printf 'on:\n  - push\njobs:\n  d:\n    steps:\n      - run: ./release.sh\n' > "$T/p7c/.github/workflows/r.yaml"
  git -C "$T/p7c" add -A; git -C "$T/p7c" commit --quiet -m wf
  o=$(_run "$T/p7c"); _ck "a list-form on: / - push deploy workflow: held" "HOLD (CI or deploy config in the pushed commit: .github/workflows/r.yaml" "$o"
  _mk p7d; printf '{}\n' > "$T/p7d/vercel.json"; git -C "$T/p7d" add vercel.json; git -C "$T/p7d" commit --quiet -m v; rm -f "$T/p7d/vercel.json"
  o=$(_run "$T/p7d"); _ck "vercel.json committed but deleted only in the working tree: still held" "HOLD (CI or deploy config in the pushed commit: vercel.json" "$o"
  _mk p7e; printf 'name = "w"\n' > "$T/p7e/wrangler.toml"; git -C "$T/p7e" add wrangler.toml; git -C "$T/p7e" commit --quiet -m w
  o=$(_run "$T/p7e"); _ck "a wrangler.toml (Cloudflare) deploy config: held" "HOLD (CI or deploy config in the pushed commit: wrangler.toml" "$o"
  _mk p7f; mkdir -p "$T/p7f/.github/workflows"; printf 'on: [pull_request]\njobs:\n  t:\n    steps:\n      - run: npm test\n' > "$T/p7f/.github/workflows/t.yml"
  git -C "$T/p7f" add -A; git -C "$T/p7f" commit --quiet -m wf
  o=$(_run "$T/p7f"); _ck "ANY CI definition holds under auto (presence, not content)" "HOLD (CI or deploy config in the pushed commit: .github/workflows/t.yml" "$o"
  _mk p7g "close_push: on"; mkdir -p "$T/p7g/.circleci"; printf 'jobs:\n  deploy:\n    steps: [run: ./deploy.sh]\n' > "$T/p7g/.circleci/config.yml"
  git -C "$T/p7g" add -A; git -C "$T/p7g" commit --quiet -m ci
  o=$(_run "$T/p7g"); _ck "the owner's on (already on the remote) lifts the CI hold" "PUSHED" "$o"
  _mk p7h; printf 'trigger:\n  - main\nsteps:\n  - script: ./deploy.sh\n' > "$T/p7h/azure-pipelines.yml"; git -C "$T/p7h" add -A; git -C "$T/p7h" commit --quiet -m az
  o=$(_run "$T/p7h"); _ck "an Azure pipeline with an implicit trigger: held" "HOLD (CI or deploy config in the pushed commit: azure-pipelines.yml" "$o"
  _mk p7i; mkdir -p "$T/p7i/apps/caf$(printf '\303\251')"; printf '{}\n' > "$T/p7i/apps/caf$(printf '\303\251')/vercel.json"
  git -C "$T/p7i" add -A; git -C "$T/p7i" commit --quiet -m nonascii
  o=$(_run "$T/p7i"); _ck "a deploy config under a non-ASCII directory: held" "HOLD (CI or deploy config in the pushed commit: apps/caf" "$o"
  _mk p7j; printf 'deploy_task:\n  script: ./deploy.sh\n' > "$T/p7j/.cirrus.yml"; git -C "$T/p7j" add -A; git -C "$T/p7j" commit --quiet -m cirrus
  o=$(_run "$T/p7j"); _ck "Cirrus CI (.cirrus.yml): held" "HOLD (CI or deploy config in the pushed commit: .cirrus.yml" "$o"
  _mk p7k; printf '[deploy]\n' > "$T/p7k/railway.toml"; git -C "$T/p7k" add -A; git -C "$T/p7k" commit --quiet -m rw
  o=$(_run "$T/p7k"); _ck "Railway (railway.toml): held" "HOLD (CI or deploy config in the pushed commit: railway.toml" "$o"
  _mk p7l; printf 'x: 1\n' > "$T/p7l/release-pipeline.yml"; git -C "$T/p7l" add -A; git -C "$T/p7l" commit --quiet -m pl
  o=$(_run "$T/p7l"); _ck "an unknown CI caught by the *pipeline.yml name catch-all: held" "HOLD (CI or deploy config in the pushed commit: release-pipeline.yml" "$o"
  # a LOCAL bare remote with a post-receive hook deploys on push: held
  _mk p7m; printf '#!/bin/sh\necho deployed\n' > "$T/p7m.git/hooks/post-receive"; chmod +x "$T/p7m.git/hooks/post-receive"
  o=$(_run "$T/p7m"); _ck "a local bare remote with a post-receive hook: held" "HOLD (local remote may deploy on push: the target repo has a post-receive hook" "$o"
  # a governed project in a SUBFOLDER of a bigger repo: its own close_push: off is honoured
  _mk p7n; mkdir -p "$T/p7n/app/docs/context"; printf -- '---\ntype: manifest\nclose_push: off\n---\n' > "$T/p7n/app/docs/context/CONTEXT-MANIFEST.md"
  git -C "$T/p7n" add -A; git -C "$T/p7n" commit --quiet -m sub
  o=$(_CP_IN_SELFTEST="$NONCE" bash "$_CP_SELF" -C "$T/p7n/app" 2>&1 | tail -1); _ck "a subfolder project's own close_push: off: held" "HOLD (close_push: off" "$o"
  # an inherited GIT_DIR / GIT_WORK_TREE must not redirect the push to another repository
  _mk p7o; _mk p7p; local h7p; h7p=$(git --git-dir="$T/p7p.git" rev-parse main)
  o=$(GIT_DIR="$T/p7p/.git" GIT_WORK_TREE="$T/p7p" _run "$T/p7o"); _ck "an inherited GIT_DIR: the -C repo is the one pushed" "PUSHED" "$o"
  [ "$(git --git-dir="$T/p7p.git" rev-parse main)" = "$h7p" ] && _yes "the repo named by GIT_DIR was not pushed" || _no "the GIT_DIR repo was pushed"
  # 8. secrets: in a file, added-then-deleted, in a merge, on a ++ line, in a commit message, in a binary, AWS key
  _mk s1; printf 'token=ghp_%s\n' "$tok36" > "$T/s1/cfg.txt"; git -C "$T/s1" add -A; git -C "$T/s1" commit --quiet -m s
  o=$(_run "$T/s1"); _ck "secret in an outgoing file: refused" "NOT PUSHED (secret-shaped" "$o"
  _mk s2; printf 'k=ghp_%s\n' "$tok36" > "$T/s2/k.txt"; git -C "$T/s2" add -A; git -C "$T/s2" commit --quiet -m add; git -C "$T/s2" rm --quiet k.txt; git -C "$T/s2" commit --quiet -m rm
  o=$(_run "$T/s2"); _ck "secret added then deleted across commits: refused" "NOT PUSHED (secret-shaped" "$o"
  _mk s3; git -C "$T/s3" checkout --quiet -b side; printf 's\n' > "$T/s3/s.txt"; git -C "$T/s3" add s.txt; git -C "$T/s3" commit --quiet -m side
  git -C "$T/s3" checkout --quiet main; git -C "$T/s3" merge --quiet --no-ff --no-commit side >/dev/null 2>&1
  printf 'tok=ghp_%s\n' "$tok36" > "$T/s3/tok"; git -C "$T/s3" add tok; git -C "$T/s3" commit --quiet -m merge
  o=$(_run "$T/s3"); _ck "secret added only inside a merge commit: refused" "NOT PUSHED (secret-shaped" "$o"
  _mk s4; printf '++ghp_%s\n' "$tok36" > "$T/s4/pp.txt"; git -C "$T/s4" add pp.txt; git -C "$T/s4" commit --quiet -m pp
  o=$(_run "$T/s4"); _ck "secret on an added line beginning with ++: refused" "NOT PUSHED (secret-shaped" "$o"
  _mk s4b; printf '++ b/ghp_%s\n' "$tok36" > "$T/s4b/pb.txt"; git -C "$T/s4b" add pb.txt; git -C "$T/s4b" commit --quiet -m pb
  o=$(_run "$T/s4b"); _ck "an added line reading '++ b/<secret>' (looks like a diff header): refused" "NOT PUSHED (secret-shaped" "$o"
  _mk s4d; printf -- '-- x\nkeep\n' > "$T/s4d/d.txt"; git -C "$T/s4d" add d.txt; git -C "$T/s4d" commit --quiet -m d0; git -C "$T/s4d" push --quiet origin main 2>/dev/null
  printf -- '++ ghp_%s\nkeep\n' "$tok36" > "$T/s4d/d.txt"; git -C "$T/s4d" commit --quiet -am d1
  o=$(_run "$T/s4d"); _ck "removed '-- x' then added '++ <secret>' (header look-alikes in a hunk): refused" "NOT PUSHED (secret-shaped" "$o"
  _mk s4c; : > "$T/s4c/ghp_$tok36"; git -C "$T/s4c" add -A; git -C "$T/s4c" commit --quiet -m name
  o=$(_run "$T/s4c"); _ck "a secret-shaped FILE NAME: refused" "NOT PUSHED (secret-shaped" "$o"
  _mk s5; printf 'x\n' >> "$T/s5/a.txt"; git -C "$T/s5" commit --quiet -am "rotate: old key ghp_$tok36"
  o=$(_run "$T/s5"); _ck "secret in a commit MESSAGE: refused" "NOT PUSHED (secret-shaped" "$o"
  _mk s5b; printf 'y\n' >> "$T/s5b/a.txt"; git -C "$T/s5b" commit --quiet -am "$(printf 'rotate keys\n\n- old key ghp_%s\n@@ index diff' "$tok36")"
  o=$(_run "$T/s5b"); _ck "secret on a message line starting with '- ': refused" "NOT PUSHED (secret-shaped" "$o"
  _mk s6; printf 'bin\000ghp_%s\n' "$tok36" > "$T/s6/blob.bin"; git -C "$T/s6" add blob.bin; git -C "$T/s6" commit --quiet -m bin
  o=$(_run "$T/s6"); _ck "secret inside a binary (NUL-containing) file: refused" "NOT PUSHED (secret-shaped" "$o"
  _mk s7; printf 'aws=AKIA%s\n' "ABCDEFGHIJKLMNOP" > "$T/s7/aws.txt"; git -C "$T/s7" add aws.txt; git -C "$T/s7" commit --quiet -m aws
  o=$(_run "$T/s7"); _ck "AWS access key shape: refused" "NOT PUSHED (secret-shaped" "$o"
  # 9. the governance framework's own clone -> held always
  _mk p9; printf '#!/bin/sh\n' > "$T/p9/install.sh"; mkdir -p "$T/p9/bundle"; printf '{}\n' > "$T/p9/bundle/settings-hooks.json"; printf '9.9.9\n' > "$T/p9/bundle/VERSION"
  o=$(_run "$T/p9"); _ck "the framework's own clone: never pushed here" "HOLD (the governance framework's own clone" "$o"
  # 10. behind the remote -> not pushed, never rebased; local history untouched
  _mk p10; _other p10; local h10; h10=$(git -C "$T/p10" rev-parse HEAD)
  o=$(_run "$T/p10"); _ck "behind the remote: not pushed, no automatic rebase" "NOT PUSHED (main is 1 commit(s) behind" "$o"
  [ "$(git -C "$T/p10" rev-parse HEAD)" = "$h10" ] && _yes "local history untouched when behind" || _no "local history was rewritten"
  # 11. the owner's off pushed to the remote AFTER the session's last fetch: never pushed over (the
  #     fresh fetch sees the branch behind; 5e covers `off` read from the upstream itself)
  _mk p11; git clone --quiet "$T/p11.git" "$T/p11-o" 2>/dev/null
  printf -- '---\ntype: manifest\nclose_push: off\n---\n' > "$T/p11-o/docs/context/CONTEXT-MANIFEST.md"; git -C "$T/p11-o" commit --quiet -am off; git -C "$T/p11-o" push --quiet origin main 2>/dev/null
  o=$(_run "$T/p11"); _ck "an off pushed to the remote meanwhile: not pushed over (branch behind)" "NOT PUSHED (main is 1 commit(s) behind" "$o"
  # 11b. the BRANCH is pinned, not HEAD: a checkout to another branch after the branch was read is
  #      simulated by moving HEAD to a no-upstream branch with an extra commit right before the run
  _mk p11b; git -C "$T/p11b" branch --quiet feat; git -C "$T/p11b" checkout --quiet feat; printf 'w\n' > "$T/p11b/w"; git -C "$T/p11b" add w; git -C "$T/p11b" commit --quiet -m wip
  git -C "$T/p11b" checkout --quiet main; local m11; m11=$(git -C "$T/p11b" rev-parse main)
  o=$(_run "$T/p11b"); _ck "branch main pushed (control)" "PUSHED" "$o"
  [ "$(git --git-dir="$T/p11b.git" rev-parse main)" = "$m11" ] && _yes "the origin holds main's tip, not another branch's" || _no "another branch's tip reached origin/main"
  # 11c. the user's log.diffMerges=off / log.showRoot=false must not hide a secret from the scan
  _mk p11c; git -C "$T/p11c" config log.diffMerges off; git -C "$T/p11c" config log.showRoot false
  git -C "$T/p11c" checkout --quiet -b side; printf 's\n' > "$T/p11c/s.txt"; git -C "$T/p11c" add s.txt; git -C "$T/p11c" commit --quiet -m side
  git -C "$T/p11c" checkout --quiet main; git -C "$T/p11c" merge --quiet --no-ff --no-commit side >/dev/null 2>&1
  printf 'tok=ghp_%s\n' "$tok36" > "$T/p11c/tok"; git -C "$T/p11c" add tok; git -C "$T/p11c" commit --quiet -m merge
  o=$(_run "$T/p11c"); _ck "log.diffMerges=off does not hide a merge secret" "NOT PUSHED (secret-shaped" "$o"
  # 11d. Git LFS in the pushed tree: held in every mode (LFS content is not scanned)
  _mk p11d "close_push: on"; printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > "$T/p11d/.gitattributes"; git -C "$T/p11d" add .gitattributes; git -C "$T/p11d" commit --quiet -m lfs
  o=$(_run "$T/p11d"); _ck "Git LFS in use: held even with the owner's on" "HOLD (Git LFS in use" "$o"
  # 11e. receivepack / uploadpack set on the remote: held
  _mk p11e; git -C "$T/p11e" config remote.origin.receivepack "git-receive-pack"
  o=$(_run "$T/p11e"); _ck "remote.receivepack set: held" "HOLD (remote origin sets receivepack/uploadpack" "$o"
  # 11f. a local remote whose receive hook lives in its core.hooksPath: held
  _mk p11f; mkdir -p "$T/p11f-hooks"; printf '#!/bin/sh\n' > "$T/p11f-hooks/post-receive"; git --git-dir="$T/p11f.git" config core.hooksPath "$T/p11f-hooks"
  o=$(_run "$T/p11f"); _ck "a receive hook in the target's core.hooksPath: held" "HOLD (local remote may deploy on push: the target repo has a post-receive hook" "$o"
  # 11g. a RELATIVE local remote resolves from the repo root, not the caller's cwd
  _mk p11g; printf '#!/bin/sh\n' > "$T/p11g.git/hooks/post-receive"; git -C "$T/p11g" remote set-url origin "../p11g.git"
  o=$(cd / && _run "$T/p11g"); _ck "a relative local remote with a hook, run from another cwd: held" "HOLD (local remote may deploy on push" "$o"
  # 11h. `Close-Push: off` (other spelling / case) is still off
  _mk p11h; printf -- '---\ntype: manifest\nClose-Push: OFF\n---\n' > "$T/p11h/docs/context/CONTEXT-MANIFEST.md"
  o=$(_run "$T/p11h"); _ck "'Close-Push: OFF' spelling: still off" "HOLD (close_push: off" "$o"
  # 12. unreachable remote -> not pushed, rc 0
  _mk p12; git -C "$T/p12" remote set-url origin "$T/does-not-exist.git"
  GOV_CLOSE_PUSH_TIMEOUT=5 _CP_IN_SELFTEST="$NONCE" bash "$_CP_SELF" -C "$T/p12" >/dev/null 2>&1; rc=$?
  o=$(GOV_CLOSE_PUSH_TIMEOUT=5 _run "$T/p12"); _ck "unreachable remote: not pushed" "NOT PUSHED" "$o"
  [ "$rc" = 0 ] && _yes "unreachable remote: exit 0 (a close never blocks)" || _no "unreachable remote: rc=$rc"
  # 13. the upstream branch was deleted on the remote -> held, never recreated
  _mk p13; git -C "$T/p13" checkout --quiet -b feat; printf 'f\n' >> "$T/p13/a.txt"; git -C "$T/p13" commit --quiet -am f
  git -C "$T/p13" push --quiet -u origin feat 2>/dev/null; printf 'g\n' >> "$T/p13/a.txt"; git -C "$T/p13" commit --quiet -am g
  git --git-dir="$T/p13.git" branch -D feat >/dev/null 2>&1
  o=$(_run "$T/p13"); _ck "upstream deleted on the remote: held" "HOLD (origin/feat no longer exists on the remote" "$o"
  _origin_has p13 refs/heads/feat && _no "the deleted branch was recreated" || _yes "the deleted branch was not recreated"
  # 14. different-name upstream, followTags, push URLs, second URL, fork workflow, submodule recurse
  _mk p14; git -C "$T/p14" checkout --quiet -b my-feature --track origin/main 2>/dev/null; printf 'f\n' >> "$T/p14/a.txt"; git -C "$T/p14" commit --quiet -am feat
  o=$(_run "$T/p14"); _ck "branch my-feature tracking origin/main: held" "HOLD (local branch my-feature tracks origin/main" "$o"
  _mk p15; git -C "$T/p15" config push.followTags true; git -C "$T/p15" tag -a v9 -m v9
  o=$(_run "$T/p15"); _ck "followTags configured: the branch is pushed" "PUSHED" "$o"
  _origin_has p15 refs/tags/v9 && _no "a tag reached the origin" || _yes "no tag reached the origin"
  _mk p16; git -C "$T/p16" remote set-url --add --push origin "$T/p16.git"; git -C "$T/p16" remote set-url --add --push origin "$T/second.git"
  o=$(_run "$T/p16"); _ck "two push URLs: held" "HOLD (remote origin has 1 url(s) and 2 push url(s)" "$o"
  _mk p17; git -C "$T/p17" config --add remote.origin.url "$T/second.git"
  o=$(_run "$T/p17"); _ck "a remote with two URLs: held" "HOLD (remote origin has 2 url(s)" "$o"
  _mk p17b; git init --quiet --bare "$T/elsewhere.git"; git -C "$T/p17b" config "url.$T/elsewhere.git.pushInsteadOf" "$T/p17b.git"
  o=$(_run "$T/p17b"); _ck "a pushInsteadOf rewrite to another repo: held" "HOLD (remote origin pushes to a different URL" "$o"
  git --git-dir="$T/elsewhere.git" rev-parse --verify --quiet refs/heads/main >/dev/null && _no "the rewritten target received the push" || _yes "the rewritten target received nothing"
  _mk p18; git -C "$T/p18" config branch.main.pushRemote fork
  o=$(_run "$T/p18"); _ck "branch.pushRemote elsewhere: held" "HOLD (a push remote other than origin" "$o"
  _mk p18b; git -C "$T/p18b" config remote.pushDefault fork
  o=$(_run "$T/p18b"); _ck "remote.pushDefault elsewhere: held" "HOLD (a push remote other than origin" "$o"
  _mk p19; git init --quiet --bare "$T/sub.git"; git clone --quiet "$T/sub.git" "$T/subw" 2>/dev/null
  printf 's\n' > "$T/subw/s"; git -C "$T/subw" add s; git -C "$T/subw" commit --quiet -m s; git -C "$T/subw" push --quiet origin main 2>/dev/null
  git -C "$T/p19" submodule --quiet add "$T/sub.git" sub >/dev/null 2>&1; git -C "$T/p19" commit --quiet -m sub
  printf 't\n' >> "$T/p19/sub/s"; git -C "$T/p19/sub" commit --quiet -am t; git -C "$T/p19" add sub; git -C "$T/p19" commit --quiet -m bump
  git -C "$T/p19" config submodule.recurse true; git -C "$T/p19" config push.recurseSubmodules on-demand
  local subh; subh=$(git --git-dir="$T/sub.git" rev-parse main)
  _run "$T/p19" >/dev/null
  [ "$(git --git-dir="$T/sub.git" rev-parse main)" = "$subh" ] && _yes "push.recurseSubmodules=on-demand did not push the submodule" || _no "the submodule's origin moved"
  # 15. locks: a live lock is respected; an old one is reported, never taken over
  _mk p20; mkdir "$T/p20/.git/gov-close.lock"
  o=$(_run "$T/p20"); _ck "a lock held by another close: respected" "NOT PUSHED (another close holds" "$o"
  _mk p21; mkdir "$T/p21/.git/gov-close.lock"
  if touch -d '30 minutes ago' "$T/p21/.git/gov-close.lock" 2>/dev/null \
     || touch -t "$(date -v-30M +%Y%m%d%H%M 2>/dev/null)" "$T/p21/.git/gov-close.lock" 2>/dev/null; then
    o=$(_run "$T/p21"); _ck "a lock older than 15 min: reported, not taken over" "NOT PUSHED (a close lock older than 15 min" "$o"
    [ -d "$T/p21/.git/gov-close.lock" ] && _yes "the old lock was left for a human" || _no "the old lock was removed"
  else
    echo "  [SKIP] old-lock case: this platform's touch cannot backdate a directory"
  fi
  # 15b. a real value already on the remote in a CONTEXT line (only its neighbour edited) is not
  #      re-scanned: only added lines and messages are
  _mk p23 "close_push: on"; printf 'contact: %s@%s\nline2\n' "dana.levi" "corp-mail.invalid" > "$T/p23/c.txt"
  git -C "$T/p23" add c.txt; git -C "$T/p23" commit --quiet -m c; git -C "$T/p23" push --quiet origin main 2>/dev/null
  printf 'contact: %s@%s\nline2 edited\n' "dana.levi" "corp-mail.invalid" > "$T/p23/c.txt"; git -C "$T/p23" commit --quiet -am edit
  o=$(_CP_TEST_VISIBILITY=PUBLIC _run "$T/p23"); _ck "PUBLIC + on: an unchanged context line is not re-scanned" "PUSHED" "$o"
  # 16. PUBLIC + the owner's on: PII added then deleted across commits is still refused
  _mk p22 "close_push: on"
  printf 'contact: %s@%s\n' "dana.levi" "corp-mail.invalid" > "$T/p22/c.txt"; git -C "$T/p22" add c.txt; git -C "$T/p22" commit --quiet -m addc
  git -C "$T/p22" rm --quiet c.txt; git -C "$T/p22" commit --quiet -m rmc
  o=$(_CP_TEST_VISIBILITY=PUBLIC _run "$T/p22"); _ck "PUBLIC + on: PII added then deleted: refused" "NOT PUSHED (PII scanner hit" "$o"
  o=$(_CP_TEST_VISIBILITY=UNKNOWN _run "$T/p22"); _ck "UNKNOWN visibility + on: the PII scan still runs" "NOT PUSHED (PII scanner hit" "$o"
  o=$(_run "$T/p22"); _ck "PRIVATE + on: no PII scan (a private repo may carry contacts), pushed" "PUSHED" "$o"
  # 17. usage and non-repo
  mkdir -p "$T/plain"; o=$(_run "$T/plain"); _ck "not a git repository: skipped" "SKIP (not a git repository" "$o"
  if command -v timeout >/dev/null 2>&1; then timeout 10 bash "$_CP_SELF" -C >/dev/null 2>&1; rc=$?; else bash "$_CP_SELF" -C >/dev/null 2>&1; rc=$?; fi
  [ "$rc" = 1 ] && _yes "-C without a directory: usage error (rc=1)" || _no "-C without a directory: rc=$rc"

  rm -rf "$T" 2>/dev/null
  echo "close-push selftest: pass=$pass fail=$fail"
  [ "$fail" = 0 ] && [ "$pass" -gt 0 ]
}

if [ "$_cp_want_selftest" = 1 ]; then
  close_push_selftest; exit $?
fi
close_push_main "$_cp_dir"
exit 0
