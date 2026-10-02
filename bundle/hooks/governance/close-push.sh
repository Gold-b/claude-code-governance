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
# WHO DECIDES (owner decision 2026-10-01, Plans/PLAN.md; consent-lib.sh gov_close_push_on is the
# one predicate, checked BEFORE the repository is even opened, so `close_push: on` in a manifest can
# never turn it on (S6) - the manifest can only hold a push that is on):
#   * the MAINTAINER's machine (the regular file ~/.claude/.governance-source): push at session
#     close is ALWAYS ON - no record, no question. GOV_CLOSE_PUSH=0 pauses it, and every hold below
#     applies exactly as on any other machine.
#   * every other machine (legal condition C4): OFF unless the user answered y to the y/N question
#     (default No): the record ~/.claude/.governance-update/close-push must say enabled=1 under the
#     installed terms version, and those terms must be accepted.
# When it is off the script prints `SKIP (push at session close is off on this machine - <reason> - ...)`.
#   --enable   the human's own act, in a terminal: prints the question (consent-lib.sh
#              gov_close_push_ask, the same literal install.sh prints) and turns it ON only when the
#              answer is y or yes (gov_close_push_answer_yes; Enter or anything else records
#              enabled=0 method=declined). shown_sha256 is the hash of exactly the block printed.
#              Refused, in this order and with nothing recorded: inside a detected AI-agent session
#              (C3; detection, not a guarantee - D1), unless stdin AND stdout are a terminal (D2; a
#              pipe is not one, so a piped "y" never enables), without the installed copy of the
#              NOTICE (~/.claude/hooks/governance-terms/, put there by every install), while the
#              installed terms version is unclear (its two sources disagree or one is missing), and
#              while the installed terms are not accepted (D5). On the maintainer's machine it asks
#              nothing and records nothing: it prints that push is always on there - or, while
#              GOV_CLOSE_PUSH=0 holds, that it is paused (rc 0).
#   --disable  records enabled=0 (no terminal needed - anyone, an agent too, may turn it OFF);
#              refused while an update is being applied (APPLYING, or lock.d names a live pid). On
#              the maintainer's machine the record is written but does not decide: push stays on (or
#              stays paused, while GOV_CLOSE_PUSH=0 holds), and it says which.
# The records are written only through gov_consent_write (0600, tmp + rename).
#
# LOG (S5): every line also goes to ~/.claude/logs/governance.log, so no line carries a remote URL,
# a local path, a scan hit or a commit message - names of the remote and branch, counts and reasons.
# A "remote name" read from git config is not trusted to be a name: `git push -u <url> <branch>`
# stores the URL (credentials included) or a local path in branch.<b>.remote. Every line that names
# a remote, a push remote, an upstream or the local branch goes through _cp_rname / _cp_bname, which
# print a fixed label instead of anything that is not plainly a name or that looks like a token (a run
# of 20+ letters/digits, any name-shaped part of the secret scan's SECRET rule, or a -/_-joined run of
# 24+ letters/digits - see _cp_tokenish). A file in the pushed commit (a CI / deploy config, a .gitattributes with
# Git LFS) is reported by a fixed label and a count, never by its path; an invalid close_push value
# is reported as "unknown value (not shown)" (verify round 4 #3, 2026-10-02).
#
# OUTPUT: one line, starting with PUSHED / NOTHING / SKIP / HOLD / NOT PUSHED.
# EXIT: always 0 — a close never blocks on a push; the caller records a HOLD / NOT PUSHED line in
# HANDOFF. Exit 1 only for a usage error, and for a refused or failed --enable / --disable.
#
# Usage: close-push.sh [-C <dir>] [--dry-run] | --enable | --disable | --selftest
# Env:   GOV_CLOSE_PUSH=0 (never push; also read from ~/.claude/.governance-local.env: a pause),
#        GOVERNANCE_HOOKS=0 (all governance off),
#        GOV_CLOSE_PUSH_TIMEOUT (seconds per network step, default 20)
set -u

_cp_dir="$PWD"; _cp_dry=0; _cp_want_selftest=0; _cp_action=push
while [ $# -gt 0 ]; do
  case "$1" in
    -C) [ $# -ge 2 ] && [ -n "$2" ] || { echo "close-push: -C needs a directory" >&2; exit 1; }
        _cp_dir="$2"; shift 2 ;;
    --dry-run) _cp_dry=1; shift ;;
    --selftest) _cp_want_selftest=1; shift ;;
    --enable)  _cp_action=enable; shift ;;
    --disable) _cp_action=disable; shift ;;
    -h|--help) sed -n '2,/^[^#]/{/^#/p;}' "$0"; exit 0 ;;   # the whole header comment, however long
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
# The consent predicate, parser and writer (pure: sourcing defines functions only). Missing = no push
# and no record can be written: fail loud, never fall back to "on".
_CP_HAVE_CONSENT=0
if [ -f "$_CP_DIR_OF_SELF/consent-lib.sh" ]; then
  # shellcheck source=consent-lib.sh
  . "$_CP_DIR_OF_SELF/consent-lib.sh" && type gov_close_push_on >/dev/null 2>&1 && _CP_HAVE_CONSENT=1
fi
_CP_TO="${GOV_CLOSE_PUSH_TIMEOUT:-20}"
_CP_PUSH_TO="${GOV_CLOSE_PUSH_PUSH_TIMEOUT:-120}"   # the push itself may carry a lot

_cp_log() {
  local log="$HOME/.claude/logs/governance.log"
  [ -d "$HOME/.claude/logs" ] || return 0
  printf '[%s] [close-push] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$log" 2>/dev/null
  return 0
}
_cp_out() { printf '[close-push] %s\n' "$1"; _cp_log "$1"; }

# S5 (round 3, finding 2): the only spelling of a remote / upstream name that reaches a log line.
# _cp_rname: a remote NAME is [A-Za-z0-9._-]+ (and not . or ..); anything else - a URL, possibly
# with user:token@, a file:// URL, a local path - prints as a fixed label, never as itself.
_cp_rname() {
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*) printf '<remote given as a URL or path>' ;;
    *) if _cp_tokenish "$1"; then printf '<remote name withheld>'; else printf '%s' "$1"; fi ;;
  esac
}
# _cp_bname NAME [LABEL]: a BRANCH name (the upstream from branch.<b>.merge, or the local branch):
# segments of [A-Za-z0-9._-] joined by single slashes, no leading / trailing slash, no `..` - so no
# scheme, no user@host, no drive path. Anything else prints LABEL (default: the upstream label).
_cp_bname() {
  local lbl="${2:-<upstream branch name withheld>}"
  case "$1" in
    ''|/*|*/|*//*|*..*|*[!A-Za-z0-9._/-]*) printf '%s' "$lbl" ;;
    *) if _cp_tokenish "$1"; then printf '%s' "$lbl"; else printf '%s' "$1"; fi ;;
  esac
}
# _cp_tokenish NAME -> 0 when a name that passed the character test above still looks like a token
# (verify round 4 #3, 2026-10-02): a run of 20 or more letters/digits. An AWS key id is exactly 20;
# the other token formats the secret scan knows (ghp_ + 36, github_pat_, sk-, ...) carry a longer
# run after their prefix. The character test above lets `_` and `-` through, so it does not catch
# them by itself (MEASURED: with this function a no-op, a branch named ghp_<36> was printed). Built-in
# regex, no process: this runs on every close. A false positive only prints the label.
# Fix round 4 G4-2 (2026-10-02): a run of 20 was looser than the scan's own rules - a branch named
# `sk-` + three groups of 10 letters joined by `-` (no run longer than 10) was printed in full, stdout
# and log. So it is also 0 for (a) every shape of the secret scan's SECRET rule that can occur in a
# name (_CP_NAME_SECRET_RE: check-no-pii.sh RE_SECRET without its private-key and sshpass parts, which
# need a blank, plus the AWS AKIA / ASIA ids _cp_secret_re adds; the selftest 22c fails when RE_SECRET
# gains a name-shaped part this copy lacks), and (b) any run joined by `-` or `_` (a part between `.`
# and `/`) that holds 24 or more letters/digits in all. (b) also hides a long descriptive branch name
# such as add-user-authentication-flow: that costs a label, never a leak.
_CP_NAME_SECRET_RE='(gh[pousr]_[A-Za-z0-9]{28,})|(github_pat_[A-Za-z0-9_]{40,})|(xox[baprse]-[A-Za-z0-9-]{16,})|(sk-[A-Za-z0-9_-]{24,})|(AIza[0-9A-Za-z_-]{30,})|(eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,})|(AKIA[0-9A-Z]{16})|(ASIA[0-9A-Z]{16})'
_cp_tokenish() {
  local re='[A-Za-z0-9]{20,}' p IFS='./'
  [[ $1 =~ $re ]] && return 0
  [[ $1 =~ $_CP_NAME_SECRET_RE ]] && return 0
  # (b): split on . and / only (no glob characters can reach here: both callers test the character
  # set first), drop the joiners, count what is left.
  for p in $1; do
    p="${p//-/}"; p="${p//_/}"
    [ "${#p}" -ge 24 ] && return 0
  done
  return 1
}

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
# S5 (verify round 4 #3, 2026-10-02): the reason printed is a FIXED label - the matched rule's own
# literal (a file name from the list below, a directory prefix, or the catch-all's pattern) and a
# count - never the file's path, which is the user's data and was printed BEFORE the file-name secret
# scan (a workflow named .github/workflows/ghp_<token>.yml reached stdout and governance.log).
_cp_deploy_signal() {
  local r="$1" sha="$2" f base listing n=0 lbl="" p
  git -C "$r" cat-file -e "$sha^{tree}" 2>/dev/null \
    || { printf 'the file list of the pushed commit could not be read'; return 0; }
  listing=$(git -c core.quotePath=false -C "$r" ls-tree -r -z --name-only "$sha" 2>/dev/null | tr '\0' '\n')
  [ -n "$listing" ] || { printf 'the file list of the pushed commit is empty or unreadable'; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="${f##*/}"
    case "$base" in
      vercel.json|netlify.toml|fly.toml|render.yaml|render.yml|Procfile|app.yaml|app.json|wrangler.toml|wrangler.json|wrangler.jsonc|firebase.json|.firebaserc|amplify.yml|now.json|serverless.yml|serverless.yaml|heroku.yml|railway.json|railway.toml|nixpacks.toml|apprunner.yaml|apprunner.yml|.platform.app.yaml|codefresh.yml|.cirrus.yml|.cirrus.star|.gitlab-ci.yml|bitbucket-pipelines.yml|azure-pipelines.yml|azure-pipelines.yaml|.travis.yml|Jenkinsfile|.drone.yml|.woodpecker.yml|.woodpecker.yaml|cloudbuild.yaml|cloudbuild.yml|buildspec.yml|buildspec.yaml|appveyor.yml|.appveyor.yml|codemagic.yaml|bitrise.yml|skaffold.yaml|Tiltfile|wercker.yml|shippable.yml|.gocd.yaml|.deployment|deploy.yml|deploy.yaml)
        # $base equals one literal of this list byte for byte (no glob in it): a constant, not data.
        n=$((n+1)); [ -n "$lbl" ] || lbl="$base"; continue ;;
      # Coarse name catch-alls for CI systems not listed above: a false hold costs one `on`.
      *-ci.yml|*-ci.yaml|*.ci.yml|*.ci.yaml|*pipeline.yml|*pipeline.yaml|*pipelines.yml|*pipelines.yaml)
        n=$((n+1)); [ -n "$lbl" ] || lbl="a file named like a CI pipeline (*-ci.yml, *pipeline.yml, ...)"; continue ;;
    esac
    case "$f" in
      .github/workflows/*|.circleci/*|.buildkite/*|.woodpecker/*|.gitea/workflows/*|.forgejo/workflows/*|.azure-pipelines/*|.semaphore/*|.teamcity/*|.eas/*|.upsun/*|.platform/*|.harness/*|.tekton/*|.argo/*|.cloudbuild/*|.github/actions/*)
        n=$((n+1))
        if [ -z "$lbl" ]; then
          for p in .github/workflows/ .circleci/ .buildkite/ .woodpecker/ .gitea/workflows/ .forgejo/workflows/ .azure-pipelines/ .semaphore/ .teamcity/ .eas/ .upsun/ .platform/ .harness/ .tekton/ .argo/ .cloudbuild/ .github/actions/; do
            case "$f" in "$p"*) lbl="a file under $p"; break ;; esac
          done
        fi ;;
    esac
  done <<EOF
$listing
EOF
  if [ "$n" -gt 0 ]; then printf '%s (%s file(s) in all)' "$lbl" "$n"; return 0; fi
  if git -C "$r" remote -v 2>/dev/null | grep -qi 'heroku'; then printf 'heroku remote'; return 0; fi
  return 1
}

# ── Git LFS: the push uploads the real objects, the scan only ever sees pointer text ─────────────
# Prints a fixed label (S5, verify round 4 #3): never the .gitattributes path, which is user data.
_cp_uses_lfs() {
  local r="$1" sha="$2" f
  while IFS= read -r f; do
    case "$f" in .gitattributes|*/.gitattributes)
      git -C "$r" show "$sha:$f" 2>/dev/null | grep -qiE 'filter[[:space:]]*=[[:space:]]*lfs' && { printf 'filter=lfs in a .gitattributes file'; return 0; } ;;
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
  # S5: these reasons go to the log - never the path itself.
  if [ ! -d "$p" ]; then printf 'the local remote path could not be found'; return 0; fi
  g=$(git -C "$p" rev-parse --absolute-git-dir 2>/dev/null) || g="$p"
  hp=$(git -C "$p" config --get core.hooksPath 2>/dev/null)
  for dir in "$g/hooks" ${hp:+"$hp"} ${hp:+"$p/$hp"} ${hp:+"$g/$hp"}; do
    for h in pre-receive update post-receive post-update push-to-checkout reference-transaction proc-receive; do
      [ -f "$dir/$h" ] && { printf 'the target repo has a %s hook' "$h"; return 0; }
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
  local nurl npurl prem pdef added pf purls sha upn rn bn

  [ "${GOVERNANCE_HOOKS:-1}" = "0" ] && { _cp_out "SKIP (GOVERNANCE_HOOKS=0)"; return 0; }
  [ "${GOV_CLOSE_PUSH:-1}" = "0" ] && { _cp_out "SKIP (GOV_CLOSE_PUSH=0)"; return 0; }
  [ "$_CP_HAVE_CONSENT" = 1 ] || { _cp_out "NOT PUSHED (consent-lib.sh missing beside close-push.sh)"; return 0; }
  [ "$(gov_local_env_get GOV_CLOSE_PUSH)" = "0" ] && { _cp_out "SKIP (GOV_CLOSE_PUSH=0 in ~/.claude/.governance-local.env)"; return 0; }
  # The user's recorded choice decides, BEFORE the repository is opened: no manifest value, no
  # remote and no environment variable can turn push at session close on (C4, S6).
  if ! gov_close_push_on; then
    _cp_out "SKIP (push at session close is off on this machine - ${GOV_CONSENT_REASON:-no choice recorded (off)} - for the human: bash ~/.claude/hooks/governance/close-push.sh --enable, in your own terminal)"
    return 0
  fi

  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || { _cp_out "SKIP (not a git repository)"; return 0; }
  branch=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null) || { _cp_out "SKIP (detached HEAD)"; return 0; }
  remote=$(git -C "$root" config --get "branch.$branch.remote" 2>/dev/null)
  rbranch=$(git -C "$root" config --get "branch.$branch.merge" 2>/dev/null); rbranch="${rbranch#refs/heads/}"
  # S5 (verify round 4 #3): the LOCAL branch name is printed only through _cp_bname too - a branch
  # can be named like a token, and these lines reach governance.log.
  bn=$(_cp_bname "$branch" '<branch name withheld>')
  if [ -z "$remote" ] || [ -z "$rbranch" ] || [ "$remote" = "." ]; then
    _cp_out "SKIP (branch $bn has no upstream; this script never creates one)"; return 0
  fi
  # The full ref, never the short `origin/main`: a local tag or branch literally named origin/main
  # would win git's disambiguation and skew every count, the scan range and the verify.
  up="refs/remotes/$remote/$rbranch"
  # S5: what the log may say about the remote and the upstream - names only (see _cp_rname).
  rn=$(_cp_rname "$remote"); upn="$rn/$(_cp_bname "$rbranch")"
  if [ "$branch" != "$rbranch" ]; then
    _cp_out "HOLD (local branch $bn tracks $upn - a different name; this script pushes only to a same-name upstream)"; return 0
  fi
  prem=$(git -C "$root" config --get "branch.$branch.pushRemote" 2>/dev/null)
  pdef=$(git -C "$root" config --get remote.pushDefault 2>/dev/null)
  if { [ -n "$prem" ] && [ "$prem" != "$remote" ]; } || { [ -z "$prem" ] && [ -n "$pdef" ] && [ "$pdef" != "$remote" ]; }; then
    # The push remote is named through _cp_rname as well (a URL or a path prints the fixed label).
    _cp_out "HOLD (a push remote other than $rn is configured (pushRemote/pushDefault: $(_cp_rname "${prem:-$pdef}")); push by hand)"; return 0
  fi
  # git pushes to EVERY url when a remote has several, and to the pushurl(s) when any is set; the
  # checks below only look at the one fetch URL, so either shape is held.
  nurl=$(git -C "$root" config --get-all "remote.$remote.url" 2>/dev/null | grep -c .)
  npurl=$(git -C "$root" config --get-all "remote.$remote.pushurl" 2>/dev/null | grep -c .)
  if [ "${nurl:-0}" -ne 1 ] || [ "${npurl:-0}" -ne 0 ]; then
    _cp_out "HOLD (remote $rn has $nurl url(s) and $npurl push url(s); only one url and no push url is pushed automatically)"; return 0
  fi
  # receivepack / uploadpack pick the PROGRAM at the other end - a wrapper can send the push to a
  # different repository than the URL names, and the verify fetch would read the same wrapper.
  if [ -n "$(git -C "$root" config --get "remote.$remote.receivepack" 2>/dev/null)" ] \
     || [ -n "$(git -C "$root" config --get "remote.$remote.uploadpack" 2>/dev/null)" ]; then
    _cp_out "HOLD (remote $rn sets receivepack/uploadpack; push by hand)"; return 0
  fi
  if [ "$(git -C "$root" config --type=bool --get "remote.$remote.mirror" 2>/dev/null)" = "true" ]; then
    _cp_out "HOLD (remote $rn is a mirror remote; a push would rewrite every ref)"; return 0
  fi
  # The URLs git will REALLY use, after url.<X>.insteadOf / pushInsteadOf rewriting (round 4: a
  # pushInsteadOf rule sent the push to another repository). One fetch URL and one push URL, equal.
  url=$(git -C "$root" remote get-url "$remote" 2>/dev/null)
  purls=$(git -C "$root" remote get-url --push --all "$remote" 2>/dev/null)
  if [ -z "$url" ] || [ "$(printf '%s\n' "$purls" | grep -c .)" -ne 1 ] || [ "$purls" != "$url" ]; then
    _cp_out "HOLD (remote $rn pushes to a different URL than it fetches from (pushurl / insteadOf / pushInsteadOf); push by hand)"; return 0
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
      *) _cp_out "NOT PUSHED (remote unreachable; commits stay local on $bn)" ;;
    esac
    return 0
  fi
  # Pin the commit now. Everything below - counts, scan, push, verify - is about THIS sha, so a
  # commit another session makes in this worktree meanwhile is never pushed unscanned (round 4).
  # Pin the BRANCH's tip, not HEAD: another session checking out a different branch in this worktree
  # during the fetch must not get its tip pushed onto this branch's upstream (final review).
  sha=$(git -C "$root" rev-parse --verify "refs/heads/$branch^{commit}" 2>/dev/null) || { _cp_out "NOT PUSHED (cannot read refs/heads/$bn)"; return 0; }
  behind=$(git -C "$root" rev-list --count "$sha..$up" 2>/dev/null)
  ahead=$(git -C "$root" rev-list --count "$up..$sha" 2>/dev/null)
  [ -n "$behind" ] && [ -n "$ahead" ] || { _cp_out "NOT PUSHED (cannot compare $bn with $upn)"; return 0; }
  if [ "$behind" != "0" ]; then
    _cp_out "NOT PUSHED ($bn is $behind commit(s) behind $upn - merge or rebase by hand; the close never rewrites history)"; return 0
  fi
  [ "$ahead" = "0" ] && { _cp_out "NOTHING to push ($bn is not ahead of $upn)"; return 0; }

  local -a mans=()
  while IFS= read -r _m; do [ -n "$_m" ] && mans+=("$_m"); done < <(_cp_manifests "$root" "$dir")
  [ ${#mans[@]} -gt 0 ] || mans=("docs/context/CONTEXT-MANIFEST.md")
  mode=$(_cp_mode "$root" "$up" "$sha" "${mans[@]}")
  case "$mode" in
    off) _cp_out "HOLD (close_push: off in CONTEXT-MANIFEST)"; return 0 ;;
    # S5 (verify round 4 #3): the value itself is never printed - it is the user's text.
    invalid:*) _cp_out "HOLD (close_push has an unknown value (not shown) - expected on|off|auto)"; return 0 ;;
    pending-on) _cp_out "HOLD (the outgoing commits carry 'close_push: on' that the remote does not have yet - the owner pushes that line himself)"; return 0 ;;
  esac

  vis=$(_cp_visibility "$url")
  if [ "$mode" = "auto" ]; then
    case "$vis" in
      PUBLIC)  _cp_out "HOLD (remote is PUBLIC; the owner's 'close_push: on', once it is on the remote, lets a close push it)"; return 0 ;;
      UNKNOWN) _cp_out "HOLD (remote visibility could not be read - not github.com, or gh missing or failing; the owner's 'close_push: on' lifts this)"; return 0 ;;
      INTERNAL) _cp_out "HOLD (remote is INTERNAL - visible to the whole organisation; the owner's 'close_push: on' lifts this)"; return 0 ;;
    esac
    if sig=$(_cp_deploy_signal "$root" "$sha"); then   # a fixed label and a count, never a path (S5)
      _cp_out "HOLD (CI or deploy config in the pushed commit: $sig; the owner's 'close_push: on' lifts this)"; return 0
    fi
    if sig=$(_cp_local_remote_deploys "$url" "$root"); then   # any remote that is a directory on this machine
      _cp_out "HOLD (local remote may deploy on push: $sig; the owner's 'close_push: on' lifts this)"; return 0
    fi
  fi

  # Git LFS content is uploaded by the push but invisible to the scan below - held in every mode.
  if sig=$(_cp_uses_lfs "$root" "$sha"); then   # a fixed label, never the path (S5)
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

  if [ "$_cp_dry" = 1 ]; then _cp_out "DRY-RUN would push $ahead commit(s): git push $rn HEAD:$(_cp_bname "$rbranch")"; return 0; fi

  # One close at a time in this worktree: `mkdir` is atomic. A lock left by a dead close is NOT taken
  # over automatically (a takeover can race a live one); it is reported for a human to remove.
  lock="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)/gov-close.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    # S5: the repo-relative name, not the absolute path.
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
      _cp_out "NOT PUSHED (a close lock older than 15 min is left at <repo>/.git/gov-close.lock - remove it if no close is running)"
    else
      _cp_out "NOT PUSHED (another close holds <repo>/.git/gov-close.lock)"
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

# ══ --enable / --disable: the user's choice, recorded in ~/.claude/.governance-update/close-push ══
_cp_now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
_cp_today()   { date '+%Y-%m-%d'; }
# The installed framework version (first non-blank line of the marker), or "unknown".
_cp_framework_version() {
  local v
  v=$(sed -n '/[^[:space:]]/{s/[[:space:]]//g;p;q;}' "$HOME/.claude/.governance-version" 2>/dev/null)
  case "$v" in ''|*[!0-9A-Za-z.+-]*) v=unknown ;; esac
  printf '%s' "$v"
}
# 0 when an update is being applied right now: an APPLYING journal, or lock.d/info naming a live pid.
_cp_update_busy() {
  local d pid
  d=$(gov_consent_dir)
  [ -e "$d/APPLYING" ] && return 0
  pid=$(sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p' "$d/lock.d/info" 2>/dev/null | head -1)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
  return 1
}

# _cp_enable_preflight -> 0 when the installed terms are accepted on this machine (terms-accepted
# terms_version >= gov_installed_terms_version); else prints why and how, and returns 1 (D5). A
# function so the selftest can reach it without a terminal; --enable calls it after the terminal
# check. Turning push ON under unaccepted terms would record an ON that gov_close_push_on ignores.
_cp_enable_preflight() {
  local inst atv s mv fv
  # The installed terms version must be CLEAR first (verify round 4 #2): with the two sources apart,
  # gov_close_push_on stays off whatever is recorded, so an ON written here would be a false "ON".
  s=$(_gov_terms_sources); mv="${s%% *}"; fv="${s##* }"
  if [ "$mv" = "-" ] || [ "$fv" = "-" ] || ! [ "$mv" -eq "$fv" ] 2>/dev/null; then
    echo "the installed terms version is unclear on this machine (installed.manifest and ~/.claude/hooks/governance-terms/TERMS-VERSION do not state the same version): re-run install.sh from a clone of the repository, in your own terminal, then this again. Nothing was recorded."
    return 1
  fi
  inst=$(gov_installed_terms_version)
  atv=$(gov_record_field "$(gov_consent_dir)/terms-accepted" terms_version)
  case "$atv" in ''|*[!0-9]*) atv=0 ;; esac
  [ "$atv" -ge "$inst" ] && return 0
  echo "the installed terms (v$inst) are not accepted on this machine yet: run  bash ~/.claude/hooks/governance/gov-update.sh --accept-terms  (or install.sh) in your own terminal first, then this again. Nothing was recorded."
  return 1
}

# _cp_answer_enables ANSWER -> 0 only for y / yes (consent-lib.sh gov_close_push_answer_yes, the one
# rule install.sh uses too). Enter, n, no and anything else keep push OFF: the default is No.
_cp_answer_enables() { gov_close_push_answer_yes "${1:-}"; }

# _cp_maintainer_paused -> 0 when this is the maintainer's machine and the one predicate says it is
# paused (GOV_CLOSE_PUSH=0 in the process env or in ~/.claude/.governance-local.env). Fix round 4 G4-1
# (2026-10-02): --enable / --disable printed "always ON" / "stays ON" while gov_close_push_on, --status,
# verify.sh and the install summary all said paused. The lines below now print what the predicate says.
_cp_maintainer_paused() {
  gov_maintainer_machine || return 1
  gov_close_push_on && return 1
  [ "${GOV_CONSENT_REASON:-}" = "paused by GOV_CLOSE_PUSH=0" ]
}
# The maintainer's-machine line (--enable and --disable print it): one literal while push is on, one
# while it is paused.
_cp_maintainer_line() {
  if _cp_maintainer_paused; then
    echo "Push at session close is PAUSED on this machine by GOV_CLOSE_PUSH=0 (in the environment or in ~/.claude/.governance-local.env). Without the pause it is always ON here: this is the maintainer's machine (~/.claude/.governance-source), and no question is asked and no record is needed. Remove GOV_CLOSE_PUSH=0 to resume; hold one project with close_push: off in its docs/context/CONTEXT-MANIFEST.md."
  else
    echo "Push at session close is always ON on this machine: it is the maintainer's (~/.claude/.governance-source). No question is asked and no record is needed. Pause it with GOV_CLOSE_PUSH=0; hold one project with close_push: off in its docs/context/CONTEXT-MANIFEST.md."
  fi
}

close_push_enable() {
  local d notice notice_t ans nsha ssha tv fv iso en method msg
  [ "$_CP_HAVE_CONSENT" = 1 ] || { echo "[close-push] NOT RECORDED (consent-lib.sh missing beside close-push.sh)"; return 1; }
  # The maintainer's machine: always on, nothing to ask or record (owner decision 2026-10-01).
  if gov_maintainer_machine; then _cp_maintainer_line; echo "Nothing was recorded."; return 0; fi
  # C3: only a person turns it on. Inside a detected AI-agent session this refuses (A.2).
  if ! gov_human_consent_ok; then gov_consent_refusal_line; return 1; fi
  # The INSTALLED copy of the terms (consent-lib.sh gov_terms_copy_dir; verify round 4 #2): every
  # install has it, wherever its clone was - the clone itself may be anywhere or gone.
  notice="$(gov_terms_copy_dir)/NOTICE-AUTO-UPDATE.md"
  notice_t="~/.claude/hooks/governance-terms/NOTICE-AUTO-UPDATE.md"
  # D2: stdin AND stdout must be a terminal - always. A piped "y" is not a person answering.
  # The line goes to stderr too, so a redirected stdout still shows it.
  if ! gov_interactive_terminal; then
    msg="no terminal to ask on: read $notice_t sections 2a and 10.3, then run this in your own terminal. Nothing was recorded."
    echo "$msg"; [ -t 1 ] || echo "$msg" >&2
    return 1
  fi
  if [ ! -f "$notice" ]; then
    echo "no terms text on this machine ($notice_t is missing): re-run install.sh from a clone of the repository, in your own terminal, then this again. Nothing was recorded."
    return 1
  fi
  _cp_enable_preflight || return 1
  # Printed once; shown_sha256 is the hash of exactly those bytes (finding 13).
  GOV_SHOWN_SHA256=""; gov_close_push_ask "$notice"; ssha="$GOV_SHOWN_SHA256"
  ans=""; IFS= read -r ans || true
  d=$(gov_consent_dir)
  tv=$(gov_installed_terms_version); fv=$(_cp_framework_version); iso=$(_cp_now_iso)
  nsha=$(gov_sha256_lf "$notice") || nsha=""
  if _cp_answer_enables "$ans"; then en=1; method=close-push-enable; else en=0; method=declined; fi
  if ! gov_consent_write "$d/close-push" "enabled=$en terms_version=$tv decided_at=$iso framework_version=$fv method=$method${nsha:+ notice_sha256=$nsha}${ssha:+ shown_sha256=$ssha}"; then
    echo "[close-push] NOT RECORDED (could not write ~/.claude/.governance-update/close-push). Nothing changed."
    return 1
  fi
  _cp_log "choice recorded: enabled=$en method=$method terms_version=$tv"
  if [ "$en" = 1 ] && ! gov_close_push_on; then
    # Recorded, but the one predicate still says off (a pause): say what holds, never a bare "ON".
    echo "Push at session close: recorded ON ($(_cp_today)), but it is still off here: ${GOV_CONSENT_REASON:-unknown reason}."
  elif [ "$en" = 1 ]; then
    echo "Push at session close: ON ($(_cp_today)). Turn it off at any time: bash ~/.claude/hooks/governance/close-push.sh --disable"
  else
    echo "Push at session close: OFF. Sessions still commit their own work locally; nothing is pushed."
  fi
  return 0
}

close_push_disable() {
  local d tv fv iso nsha ssha
  [ "$_CP_HAVE_CONSENT" = 1 ] || { echo "[close-push] NOT RECORDED (consent-lib.sh missing beside close-push.sh)"; return 1; }
  # T5 / A20: never race an apply that is swapping the tree this record sits beside.
  if _cp_update_busy; then echo "not now: an update is being applied (try again in a minute)"; return 1; fi
  d=$(gov_consent_dir)
  tv=$(gov_installed_terms_version); fv=$(_cp_framework_version); iso=$(_cp_now_iso)
  nsha=$(gov_sha256_lf "$(gov_terms_copy_dir)/NOTICE-AUTO-UPDATE.md") || nsha=""
  ssha=$(printf '' | gov_sha256_lf_stdin) || ssha=""   # nothing was shown
  if ! gov_consent_write "$d/close-push" "enabled=0 terms_version=$tv decided_at=$iso framework_version=$fv method=close-push-disable${nsha:+ notice_sha256=$nsha}${ssha:+ shown_sha256=$ssha}"; then
    echo "[close-push] NOT RECORDED (could not write ~/.claude/.governance-update/close-push). Nothing changed."
    return 1
  fi
  _cp_log "choice recorded: enabled=0 method=close-push-disable terms_version=$tv"
  if gov_maintainer_machine; then
    # The record is kept for the day the marker goes, but it does not turn push off here. While the
    # pause holds, say so - never "stays ON" (fix round 4 G4-1).
    if _cp_maintainer_paused; then
      echo "Recorded enabled=0 ($(_cp_today)), but on this machine the record does not decide: push at session close is paused by GOV_CLOSE_PUSH=0 now, and is ON again once the pause is removed."
    else
      echo "Recorded enabled=0 ($(_cp_today)), but push at session close stays ON here."
    fi
    _cp_maintainer_line
    return 0
  fi
  echo "Push at session close: OFF (recorded $(_cp_today)). Sessions still commit locally; nothing is pushed."
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
  # The consent sandbox (consent-lib.sh gov_consent_override_ok): this HOME is not the real one and
  # holds the nonce, so --enable's consent check can be passed here and nowhere else.
  printf '%s\n' "$NONCE" > "$HOME/.governance-consent-selftest"; export GOV_CONSENT_SELFTEST="$NONCE"
  _run() { _CP_IN_SELFTEST="$NONCE" bash "$_CP_SELF" -C "$1" 2>&1 | tail -1; }
  unset GOV_CLOSE_PUSH GOVERNANCE_HOOKS
  export _CP_TEST_VISIBILITY=PRIVATE
  local tok36; tok36=$(printf 'A%.0s' $(seq 1 36))
  local CD="$HOME/.claude/.governance-update"
  # _srcs <n>: the two installed-terms sources, both v<n> - installed.manifest and the installed copy
  # ~/.claude/hooks/governance-terms/TERMS-VERSION (what install.sh leaves on every machine).
  local TC="$HOME/.claude/hooks/governance-terms"
  _srcs() {
    mkdir -p "$CD" "$TC"
    printf 'version=2.0.0\nterms_version=%s\n[files]\n' "$1" > "$CD/installed.manifest"
    printf '%s\n' "$1" > "$TC/TERMS-VERSION"
  }
  # _rec on|off|stale|none: the user's recorded choice (literal records, not the writer: the parser is
  # what is under test here). on = enabled under the installed terms, v1. on/off/stale also plant the
  # two installed-terms sources, both v1 (round 3, group B: gov_close_push_on fails closed when
  # either source is absent; verify round 4 #2: the second source is the installed copy); none leaves them.
  _rec() {
    mkdir -p "$CD"
    case "$1" in on|off|stale) _srcs 1 ;; esac
    case "$1" in
      on)    printf 'enabled=1 terms_version=1 decided_at=2026-09-30T00:00:00Z framework_version=2.0.0 method=selftest\n' > "$CD/close-push"
             printf 'terms_version=1 accepted_at=2026-09-30T00:00:00Z framework_version=2.0.0 method=selftest\n' > "$CD/terms-accepted" ;;
      off)   printf 'enabled=0 terms_version=1 decided_at=2026-09-30T00:00:00Z framework_version=2.0.0 method=declined\n' > "$CD/close-push"
             printf 'terms_version=1 accepted_at=2026-09-30T00:00:00Z framework_version=2.0.0 method=selftest\n' > "$CD/terms-accepted" ;;
      stale) printf 'enabled=1 terms_version=0 decided_at=2026-09-30T00:00:00Z framework_version=1.9.0 method=selftest\n' > "$CD/close-push"
             printf 'terms_version=1 accepted_at=2026-09-30T00:00:00Z framework_version=2.0.0 method=selftest\n' > "$CD/terms-accepted" ;;
      none)  rm -f "$CD/close-push" "$CD/terms-accepted" ;;
    esac
  }
  _has() { # _has <label> <needle> <output>: the output CONTAINS the needle
    case "$3" in *"$2"*) pass=$((pass+1)); echo "  [PASS] $1" ;;
      *) fail=$((fail+1)); echo "  [FAIL] $1 - expected to contain '$2', got: $3" ;; esac
  }
  # Every existing case below runs with the choice ON: the positive control that a recorded yes pushes.
  _rec on

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
  o=$(_run "$T/p7b"); _ck "a quoted \"on\": [push] deploy workflow: held" "HOLD (CI or deploy config in the pushed commit: a file under .github/workflows/ (1 file(s) in all)" "$o"
  _mk p7c; mkdir -p "$T/p7c/.github/workflows"; printf 'on:\n  - push\njobs:\n  d:\n    steps:\n      - run: ./release.sh\n' > "$T/p7c/.github/workflows/r.yaml"
  git -C "$T/p7c" add -A; git -C "$T/p7c" commit --quiet -m wf
  o=$(_run "$T/p7c"); _ck "a list-form on: / - push deploy workflow: held" "HOLD (CI or deploy config in the pushed commit: a file under .github/workflows/ (1 file(s) in all)" "$o"
  _mk p7d; printf '{}\n' > "$T/p7d/vercel.json"; git -C "$T/p7d" add vercel.json; git -C "$T/p7d" commit --quiet -m v; rm -f "$T/p7d/vercel.json"
  o=$(_run "$T/p7d"); _ck "vercel.json committed but deleted only in the working tree: still held" "HOLD (CI or deploy config in the pushed commit: vercel.json" "$o"
  _mk p7e; printf 'name = "w"\n' > "$T/p7e/wrangler.toml"; git -C "$T/p7e" add wrangler.toml; git -C "$T/p7e" commit --quiet -m w
  o=$(_run "$T/p7e"); _ck "a wrangler.toml (Cloudflare) deploy config: held" "HOLD (CI or deploy config in the pushed commit: wrangler.toml" "$o"
  _mk p7f; mkdir -p "$T/p7f/.github/workflows"; printf 'on: [pull_request]\njobs:\n  t:\n    steps:\n      - run: npm test\n' > "$T/p7f/.github/workflows/t.yml"
  git -C "$T/p7f" add -A; git -C "$T/p7f" commit --quiet -m wf
  o=$(_run "$T/p7f"); _ck "ANY CI definition holds under auto (presence, not content)" "HOLD (CI or deploy config in the pushed commit: a file under .github/workflows/ (1 file(s) in all)" "$o"
  _mk p7g "close_push: on"; mkdir -p "$T/p7g/.circleci"; printf 'jobs:\n  deploy:\n    steps: [run: ./deploy.sh]\n' > "$T/p7g/.circleci/config.yml"
  git -C "$T/p7g" add -A; git -C "$T/p7g" commit --quiet -m ci
  o=$(_run "$T/p7g"); _ck "the owner's on (already on the remote) lifts the CI hold" "PUSHED" "$o"
  _mk p7h; printf 'trigger:\n  - main\nsteps:\n  - script: ./deploy.sh\n' > "$T/p7h/azure-pipelines.yml"; git -C "$T/p7h" add -A; git -C "$T/p7h" commit --quiet -m az
  o=$(_run "$T/p7h"); _ck "an Azure pipeline with an implicit trigger: held" "HOLD (CI or deploy config in the pushed commit: azure-pipelines.yml" "$o"
  _mk p7i; mkdir -p "$T/p7i/apps/caf$(printf '\303\251')"; printf '{}\n' > "$T/p7i/apps/caf$(printf '\303\251')/vercel.json"
  git -C "$T/p7i" add -A; git -C "$T/p7i" commit --quiet -m nonascii
  o=$(_run "$T/p7i"); _ck "a deploy config under a non-ASCII directory: held" "HOLD (CI or deploy config in the pushed commit: vercel.json (1 file(s) in all)" "$o"
  _mk p7j; printf 'deploy_task:\n  script: ./deploy.sh\n' > "$T/p7j/.cirrus.yml"; git -C "$T/p7j" add -A; git -C "$T/p7j" commit --quiet -m cirrus
  o=$(_run "$T/p7j"); _ck "Cirrus CI (.cirrus.yml): held" "HOLD (CI or deploy config in the pushed commit: .cirrus.yml" "$o"
  _mk p7k; printf '[deploy]\n' > "$T/p7k/railway.toml"; git -C "$T/p7k" add -A; git -C "$T/p7k" commit --quiet -m rw
  o=$(_run "$T/p7k"); _ck "Railway (railway.toml): held" "HOLD (CI or deploy config in the pushed commit: railway.toml" "$o"
  _mk p7l; printf 'x: 1\n' > "$T/p7l/release-pipeline.yml"; git -C "$T/p7l" add -A; git -C "$T/p7l" commit --quiet -m pl
  o=$(_run "$T/p7l"); _ck "an unknown CI caught by the *pipeline.yml name catch-all: held" "HOLD (CI or deploy config in the pushed commit: a file named like a CI pipeline (*-ci.yml, *pipeline.yml, ...) (1 file(s) in all)" "$o"
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

  # 18. THE USER'S CHOICE (C4): off unless the record says on under the installed terms. The same
  #     repo is SKIPPED under none / off / stale and PUSHED under on (control); the origin is checked.
  _rec none; _mk c1; local h0; h0=$(git --git-dir="$T/c1.git" rev-parse main)
  o=$(_run "$T/c1"); _ck "no choice recorded: skipped, with the way to turn it on" "SKIP (push at session close is off on this machine - no choice recorded (off) - for the human: bash ~/.claude/hooks/governance/close-push.sh --enable, in your own terminal)" "$o"
  [ "$(git --git-dir="$T/c1.git" rev-parse main)" = "$h0" ] && _yes "no record: the origin is unchanged" || _no "no record: the origin moved"
  _rec off; o=$(_run "$T/c1"); _ck "enabled=0 (the user's no): skipped" "SKIP (push at session close is off on this machine - off (your choice)" "$o"
  _rec stale; o=$(_run "$T/c1"); _ck "a record under older terms: skipped" "SKIP (push at session close is off on this machine - off (terms changed" "$o"
  _has "the stale-record line names the terms change and the terminal re-enable (D5)" "terms changed to v1; accept them, then turn it on again in your own terminal: bash ~/.claude/hooks/governance/close-push.sh --enable)" "$o"
  case "$o" in *"re-accept: gov-update.sh --accept-terms"*) _no "the stale-record line still sends the user to --accept-terms alone" ;;
    *) _yes "the stale-record line no longer says re-accepting alone turns it back on (finding 9)" ;; esac
  _rec on; printf 'terms_version=0 accepted_at=2026-09-30T00:00:00Z method=selftest\n' > "$CD/terms-accepted"
  o=$(_run "$T/c1"); _ck "record on but the installed terms not accepted: skipped" "SKIP (push at session close is off on this machine - off (terms changed" "$o"
  [ "$(git --git-dir="$T/c1.git" rev-parse main)" = "$h0" ] && _yes "off / stale: the origin is still unchanged" || _no "off / stale: the origin moved"
  _rec on; o=$(_run "$T/c1"); _ck "the same repo with the choice ON: pushed (control)" "PUSHED" "$o"
  # the pause in the user's local env file - and a commented-out pause is not one
  _mk c2; printf 'GOV_OTHER=1\nGOV_CLOSE_PUSH=0\n' > "$HOME/.claude/.governance-local.env"; local h2; h2=$(git --git-dir="$T/c2.git" rev-parse main)
  o=$(_run "$T/c2"); _ck "GOV_CLOSE_PUSH=0 in the local env file: skipped, naming the file" "SKIP (GOV_CLOSE_PUSH=0 in ~/.claude/.governance-local.env)" "$o"
  [ "$(git --git-dir="$T/c2.git" rev-parse main)" = "$h2" ] && _yes "paused: the origin is unchanged" || _no "paused: the origin moved"
  printf '# GOV_CLOSE_PUSH=0\n' > "$HOME/.claude/.governance-local.env"
  o=$(_run "$T/c2"); _ck "a commented-out GOV_CLOSE_PUSH=0 is not a pause: pushed" "PUSHED" "$o"
  rm -f "$HOME/.claude/.governance-local.env"
  # S6: `close_push: on` already on the remote, PUBLIC, and no record -> SKIP (not HOLD, not PUSHED)
  _rec none; _mk c3 "close_push: on"; local h3; h3=$(git --git-dir="$T/c3.git" rev-parse main)
  o=$(_CP_TEST_VISIBILITY=PUBLIC _run "$T/c3"); _ck "S6: the manifest's on + PUBLIC + no record: skipped" "SKIP (push at session close is off on this machine - no choice recorded" "$o"
  [ "$(git --git-dir="$T/c3.git" rev-parse main)" = "$h3" ] && _yes "S6: the origin is unchanged" || _no "S6: the manifest's on pushed without a record"
  # 18b. THE MAINTAINER'S MACHINE (owner decision 2026-10-01): the marker FILE turns push at session
  #      close on with no record and no accepted terms; the pause and every hold still apply; a
  #      DIRECTORY of that name is not the marker; without it the client rule holds (control).
  local MK="$HOME/.claude/.governance-source" hm
  _rec none; rm -rf "$MK"; : > "$MK"
  _mk m1; o=$(_run "$T/m1"); _ck "maintainer marker, no record, no terms accepted: pushed" "PUSHED" "$o"
  [ "$(git -C "$T/m1" rev-parse HEAD)" = "$(git --git-dir="$T/m1.git" rev-parse main)" ] && _yes "maintainer: the bare origin really holds HEAD" || _no "maintainer: the origin does not hold HEAD"
  { [ ! -e "$CD/close-push" ] && [ ! -e "$CD/terms-accepted" ]; } && _yes "maintainer: the push needed and wrote no record" || _no "maintainer: a record exists: $(cat "$CD/close-push" 2>/dev/null)"
  _rec off; _mk m2; o=$(_run "$T/m2"); _ck "maintainer marker + a recorded enabled=0: still pushed (always on)" "PUSHED" "$o"
  _rec stale; _mk m2s; o=$(_run "$T/m2s"); _ck "maintainer marker + a record under older terms: still pushed" "PUSHED" "$o"
  _rec none; _mk m3; hm=$(git --git-dir="$T/m3.git" rev-parse main)
  o=$(GOV_CLOSE_PUSH=0 _run "$T/m3"); _ck "maintainer + GOV_CLOSE_PUSH=0: skipped" "SKIP (GOV_CLOSE_PUSH=0)" "$o"
  printf 'GOV_CLOSE_PUSH=0\n' > "$HOME/.claude/.governance-local.env"
  o=$(_run "$T/m3"); _ck "maintainer + the pause in the local env file: skipped" "SKIP (GOV_CLOSE_PUSH=0 in ~/.claude/.governance-local.env)" "$o"
  rm -f "$HOME/.claude/.governance-local.env"
  [ "$(git --git-dir="$T/m3.git" rev-parse main)" = "$hm" ] && _yes "maintainer paused: the origin is unchanged" || _no "maintainer paused: the origin moved"
  _mk m4 "close_push: off"; o=$(_run "$T/m4"); _ck "maintainer + close_push: off: held" "HOLD (close_push: off" "$o"
  _mk m5; o=$(_CP_TEST_VISIBILITY=PUBLIC _run "$T/m5"); _ck "maintainer + a PUBLIC remote under auto: held" "HOLD (remote is PUBLIC" "$o"
  _mk m6; printf '{}\n' > "$T/m6/vercel.json"; git -C "$T/m6" add vercel.json; git -C "$T/m6" commit --quiet -m v
  o=$(_run "$T/m6"); _ck "maintainer + a deploy config in the pushed commit: held" "HOLD (CI or deploy config in the pushed commit: vercel.json" "$o"
  _mk m7; printf '#!/bin/sh\n' > "$T/m7/install.sh"; mkdir -p "$T/m7/bundle"; printf '{}\n' > "$T/m7/bundle/settings-hooks.json"; printf '9.9.9\n' > "$T/m7/bundle/VERSION"
  o=$(_run "$T/m7"); _ck "maintainer + the framework's own clone: held" "HOLD (the governance framework's own clone" "$o"
  _mk m8; printf 'm\n' >> "$T/m8/a.txt"; git -C "$T/m8" commit --quiet -am "token ghp_$tok36"
  o=$(_run "$T/m8"); _ck "maintainer + a secret in a commit message: refused" "NOT PUSHED (secret-shaped" "$o"
  rm -f "$MK"; mkdir -p "$MK"; _mk m9; o=$(_run "$T/m9")
  _ck "the marker as a DIRECTORY is not the maintainer's machine: skipped like a client" "SKIP (push at session close is off on this machine - no choice recorded (off)" "$o"
  rm -rf "$MK"; o=$(_run "$T/m9")
  _ck "no marker, no record (control): the client rule, skipped" "SKIP (push at session close is off on this machine - no choice recorded (off)" "$o"
  _rec on; o=$(_run "$T/m9"); _ck "no marker, the client's recorded yes (control): pushed" "PUSHED" "$o"
  _rec none
  # 19. --enable: only a person, only in a terminal (stdin AND stdout), only with a y answer, only
  #     under accepted terms. The markers are SET here (never unset - T4), so every refusal is
  #     exercised whatever session runs this suite.
  _rec none
  o=$(CLAUDECODE=1 GOV_CONSENT_SELFTEST= bash "$_CP_SELF" --enable </dev/null 2>&1); rc=$?
  [ "$rc" = 1 ] && _yes "--enable in an agent session without the nonce: rc 1" || _no "--enable without the nonce: rc=$rc"
  _has "--enable in an agent session: the A.2 refusal (refused on detection)" "[GOVERNANCE] Refused: this needs your own decision, typed in your own terminal, and an AI-agent" "$o"
  _has "--enable refusal: 'a safeguard, not a guarantee' (L1)" "session was detected (a safeguard, not a guarantee). Nothing was recorded or changed." "$o"
  case "$o" in *"cannot accept"*) _no "the refusal still claims an agent cannot accept (L1)" ;; *) _yes "the refusal claims no guarantee: no 'cannot accept' (L1)" ;; esac
  [ ! -e "$CD/close-push" ] && _yes "--enable refused: no record written" || _no "--enable refused but a record was written"
  o=$(CLAUDECODE=1 bash "$_CP_SELF" --enable </dev/null 2>&1); rc=$?
  [ "$rc" = 1 ] && _yes "--enable with the nonce but no terminal: rc 1" || _no "--enable without a terminal: rc=$rc"
  _has "--enable without a terminal: the D.3 line" "no terminal to ask on: read ~/.claude/hooks/governance-terms/NOTICE-AUTO-UPDATE.md sections 2a and 10.3, then run this in your own terminal. Nothing was recorded." "$o"
  case "$o" in *"[GOVERNANCE] Refused: this needs your own decision"*) _no "the sandbox nonce did not pass the consent check" ;; *) _yes "the sandbox nonce passes the consent check (it reached the terminal check)" ;; esac
  # no terms-accepted here either (_rec none): the TERMINAL check comes first, so the terms line is not printed
  case "$o" in *"are not accepted on this machine yet"*) _no "no terminal AND no terms: the terms check ran before the terminal check" ;;
    *) _yes "no terminal AND no terms accepted: the terminal refusal comes first (order: consent, terminal, notice, terms)" ;; esac
  [ ! -e "$CD/close-push" ] && _yes "--enable without a terminal: no record written" || _no "--enable without a terminal wrote a record"
  # 19b. The maintainer marker on --enable / --disable (owner decision 2026-10-01). As a FILE:
  #      --enable asks nothing, records nothing, says push is always on here (rc 0) - even with no
  #      nonce, because nothing is consented to. As a DIRECTORY (review finding 17: a plain mkdir
  #      made one) it is not the marker: the A.2 refusal, no record (D3: it exempts no consent act).
  local MKL="Push at session close is always ON on this machine: it is the maintainer's (~/.claude/.governance-source). No question is asked and no record is needed."
  rm -rf "$MK"; : > "$MK"
  o=$(CLAUDECODE=1 GOV_CONSENT_SELFTEST= bash "$_CP_SELF" --enable </dev/null 2>&1); rc=$?
  { [ "$rc" = 0 ] && [ ! -e "$CD/close-push" ]; } && _yes "--enable on the maintainer's machine: rc 0, no record" || _no "--enable on the maintainer's machine: rc=$rc rec=$(cat "$CD/close-push" 2>/dev/null)"
  _has "--enable on the maintainer's machine: the always-ON line" "$MKL" "$o"
  _has "--enable on the maintainer's machine: says nothing was recorded" "Nothing was recorded." "$o"
  case "$o" in *"[y/N]"*) _no "--enable on the maintainer's machine asked the question" ;; *) _yes "--enable on the maintainer's machine asks no question" ;; esac
  o=$(CLAUDECODE=1 bash "$_CP_SELF" --disable </dev/null 2>&1); rc=$?
  { [ "$rc" = 0 ] && grep -q '^enabled=0 .*method=close-push-disable' "$CD/close-push"; } && _yes "--disable on the maintainer's machine: rc 0, enabled=0 recorded" || _no "--disable on the maintainer's machine: rc=$rc"
  _has "--disable on the maintainer's machine: says push stays ON here" "but push at session close stays ON here." "$o"
  _has "--disable on the maintainer's machine: names the marker and the pause" "$MKL Pause it with GOV_CLOSE_PUSH=0" "$o"
  case "$o" in *"Push at session close: OFF"*) _no "--disable on the maintainer's machine claimed OFF" ;; *) _yes "--disable on the maintainer's machine does not claim OFF" ;; esac
  rm -f "$CD/close-push"
  # 19b2. (fix round 4 G4-1) the marker AND the pause - GOV_CLOSE_PUSH=0 in the env, then only in
  #       ~/.claude/.governance-local.env: --enable / --disable say PAUSED, never "always ON" / "stays
  #       ON"; they record exactly what they did before (--enable nothing, --disable enabled=0).
  local MKP="Push at session close is PAUSED on this machine by GOV_CLOSE_PUSH=0 (in the environment or in ~/.claude/.governance-local.env). Without the pause it is always ON here: this is the maintainer's machine (~/.claude/.governance-source)"
  local MKD="but on this machine the record does not decide: push at session close is paused by GOV_CLOSE_PUSH=0 now, and is ON again once the pause is removed."
  local LENV="$HOME/.claude/.governance-local.env" pw
  rm -rf "$MK"; : > "$MK"
  for pw in env file; do
    rm -f "$CD/close-push" "$LENV"
    if [ "$pw" = env ]; then
      o=$(GOV_CLOSE_PUSH=0 CLAUDECODE=1 GOV_CONSENT_SELFTEST= bash "$_CP_SELF" --enable </dev/null 2>&1); rc=$?
    else
      printf 'GOV_CLOSE_PUSH=0\n' > "$LENV"
      o=$(CLAUDECODE=1 GOV_CONSENT_SELFTEST= bash "$_CP_SELF" --enable </dev/null 2>&1); rc=$?
    fi
    { [ "$rc" = 0 ] && [ ! -e "$CD/close-push" ]; } && _yes "marker + pause ($pw): --enable rc 0, no record" || _no "marker + pause ($pw): --enable rc=$rc rec=$(cat "$CD/close-push" 2>/dev/null)"
    _has "marker + pause ($pw): --enable says PAUSED" "$MKP" "$o"
    case "$o" in *"$MKL"*) _no "marker + pause ($pw): --enable still says always ON" ;; *) _yes "marker + pause ($pw): --enable does not say always ON" ;; esac
    if [ "$pw" = env ]; then o=$(GOV_CLOSE_PUSH=0 CLAUDECODE=1 bash "$_CP_SELF" --disable </dev/null 2>&1); rc=$?
    else o=$(CLAUDECODE=1 bash "$_CP_SELF" --disable </dev/null 2>&1); rc=$?; fi
    { [ "$rc" = 0 ] && grep -q '^enabled=0 .*method=close-push-disable' "$CD/close-push"; } && _yes "marker + pause ($pw): --disable rc 0, enabled=0 recorded" || _no "marker + pause ($pw): --disable rc=$rc"
    _has "marker + pause ($pw): --disable says the record does not decide and push is paused" "$MKD" "$o"
    case "$o" in *"stays ON here"*|*"$MKL"*) _no "marker + pause ($pw): --disable still says ON" ;; *) _yes "marker + pause ($pw): --disable does not say ON" ;; esac
  done
  rm -f "$CD/close-push" "$LENV"; printf '# GOV_CLOSE_PUSH=0\n' > "$LENV"
  o=$(CLAUDECODE=1 GOV_CONSENT_SELFTEST= bash "$_CP_SELF" --enable </dev/null 2>&1)
  _has "control: marker + a COMMENTED-OUT pause: --enable says always ON" "$MKL" "$o"
  case "$o" in *"PAUSED"*) _no "control: a commented-out pause read as a pause" ;; *) _yes "control: a commented-out pause is not a pause" ;; esac
  rm -f "$CD/close-push" "$LENV"
  rm -rf "$MK"; mkdir -p "$MK"
  o=$(CLAUDECODE=1 GOV_CONSENT_SELFTEST= bash "$_CP_SELF" --enable </dev/null 2>&1); rc=$?
  { [ "$rc" = 1 ] && [ ! -e "$CD/close-push" ]; } && _yes "--enable with the marker as a directory, no nonce: rc 1, no record (D3)" || _no "--enable with the marker as a directory: rc=$rc"
  _has "--enable with the marker as a directory: the A.2 refusal, not an exemption" "[GOVERNANCE] Refused: this needs your own decision, typed in your own terminal, and an AI-agent" "$o"
  o=$(bash "$_CP_SELF" --disable </dev/null 2>&1)
  _has "--disable with the marker as a directory: the client OFF line (control)" "Push at session close: OFF (recorded " "$o"
  rm -rf "$MK"; rm -f "$CD/close-push"
  # 19c. D2: "y" PIPED in is not a person at a terminal - rc 1, the D.3 line, no record.
  o=$(printf 'y\n' | CLAUDECODE=1 bash "$_CP_SELF" --enable 2>&1); rc=$?
  [ "$rc" = 1 ] && _yes "'y' piped into --enable: rc 1 (a pipe is not a terminal)" || _no "the piped y: rc=$rc"
  _has "the piped y: the D.3 line" "no terminal to ask on: read ~/.claude/hooks/governance-terms/NOTICE-AUTO-UPDATE.md" "$o"
  [ ! -e "$CD/close-push" ] && _yes "the piped y: no record written" || _no "the piped y wrote: $(cat "$CD/close-push")"
  o=$(CLAUDECODE=1 bash "$_CP_SELF" --enable </dev/null 2>&1 >/dev/null); rc=$?
  _has "stdout redirected: the D.3 line still reaches stderr" "no terminal to ask on:" "$o"
  o=$(CLAUDECODE=1 bash "$_CP_SELF" --enable </dev/null 2>/dev/null)
  case "$o" in *"no terminal to ask on:"*"no terminal to ask on:"*) _no "the D.3 line printed twice on stdout" ;;
    *"no terminal to ask on:"*) _yes "stdout alone carries the D.3 line exactly once (control)" ;; *) _no "stdout lost the D.3 line: $o" ;; esac
  # 19d. the y/N answer: y / yes in any case, blanks and CR around it ignored, turn it on; Enter (the
  #      default No), n, no and anything else keep it OFF.
  local ans_t
  for ans_t in y Y yes YES Yes " y" "y " $'y\r' $'yes\r' $'\ty'; do
    _cp_answer_enables "$ans_t" && _yes "answer [$(printf '%s' "$ans_t" | od -An -c | tr -s ' ')]: enables" || _no "answer [$ans_t] did not enable"
  done
  for ans_t in "" n N no NO "yy" "yess" "y es" "ok" "sure" "I ENABLE PUSH AT SESSION CLOSE" "1" "true"; do
    _cp_answer_enables "$ans_t" && _no "answer [$ans_t] enabled push" || _yes "answer [$ans_t]: stays OFF"
  done
  # 19e. D5 preflight: --enable refuses while the installed terms are not accepted - no ON that the
  #      predicate would then ignore. Reached directly (it runs after the terminal check).
  _rec none; _srcs 1; o=$(_cp_enable_preflight 2>&1); rc=$?
  [ "$rc" = 1 ] && _yes "preflight, no terms-accepted record: rc 1" || _no "preflight without terms-accepted: rc=$rc"
  _has "preflight, no terms-accepted: the exact line" "the installed terms (v1) are not accepted on this machine yet: run  bash ~/.claude/hooks/governance/gov-update.sh --accept-terms  (or install.sh) in your own terminal first, then this again. Nothing was recorded." "$o"
  [ ! -e "$CD/close-push" ] && _yes "preflight refused: no record written" || _no "preflight wrote a record"
  mkdir -p "$CD"; printf 'terms_version=0 accepted_at=2026-09-30T00:00:00Z method=selftest\n' > "$CD/terms-accepted"
  o=$(_cp_enable_preflight 2>&1); rc=$?
  { [ "$rc" = 1 ]; } && _yes "preflight, terms_version=0 accepted, v1 installed: rc 1" || _no "preflight with v0 accepted: rc=$rc"
  _srcs 2
  printf 'terms_version=1 accepted_at=2026-09-30T00:00:00Z method=selftest\n' > "$CD/terms-accepted"
  o=$(_cp_enable_preflight 2>&1); rc=$?
  { [ "$rc" = 1 ]; } && _yes "preflight, v1 accepted, v2 installed (a terms bump): rc 1" || _no "preflight after a bump: rc=$rc"
  _has "preflight after a bump names the installed version" "the installed terms (v2) are not accepted on this machine yet" "$o"
  printf 'terms_version=2 accepted_at=2026-09-30T00:00:00Z method=selftest\n' > "$CD/terms-accepted"
  o=$(_cp_enable_preflight 2>&1); rc=$?
  { [ "$rc" = 0 ] && [ -z "$o" ]; } && _yes "preflight, v2 accepted, v2 installed: rc 0, silent (control)" || _no "preflight control: rc=$rc [$o]"
  # 19e2. (verify round 4 #2) the installed terms version must be CLEAR: the two sources disagree, or
  #       the installed copy is missing / garbled -> refused before the question, nothing recorded.
  local UNCL="the installed terms version is unclear on this machine (installed.manifest and ~/.claude/hooks/governance-terms/TERMS-VERSION do not state the same version): re-run install.sh from a clone of the repository, in your own terminal, then this again. Nothing was recorded."
  printf '1\n' > "$TC/TERMS-VERSION"
  o=$(_cp_enable_preflight 2>&1); rc=$?
  { [ "$rc" = 1 ] && [ "$o" = "$UNCL" ]; } && _yes "preflight, manifest v2 / copy v1 (disagree): rc 1, the unclear line" || _no "preflight with the sources apart: rc=$rc [$o]"
  rm -f "$TC/TERMS-VERSION"; o=$(_cp_enable_preflight 2>&1); rc=$?
  { [ "$rc" = 1 ] && [ "$o" = "$UNCL" ]; } && _yes "preflight, the installed copy deleted: rc 1, the unclear line" || _no "preflight without the copy: rc=$rc [$o]"
  printf '2x\n' > "$TC/TERMS-VERSION"; o=$(_cp_enable_preflight 2>&1); rc=$?
  { [ "$rc" = 1 ] && [ "$o" = "$UNCL" ]; } && _yes "preflight, the installed copy garbled ('2x'): rc 1, the unclear line" || _no "preflight with a garbled copy: rc=$rc [$o]"
  printf '2\n' > "$TC/TERMS-VERSION"; o=$(_cp_enable_preflight 2>&1); rc=$?
  { [ "$rc" = 0 ] && [ -z "$o" ]; } && _yes "preflight, the copy restored to v2 (control): rc 0, silent" || _no "preflight after the restore: rc=$rc [$o]"
  [ ! -e "$CD/close-push" ] && _yes "preflight refusals: no record written" || _no "a preflight refusal wrote a record"
  rm -f "$CD/installed.manifest" "$TC/TERMS-VERSION"; _rec none
  # 19f. the yes path on a REAL pseudo-terminal, where util-linux `script` exists.
  if command -v script >/dev/null 2>&1 && script -qec true /dev/null </dev/null >/dev/null 2>&1; then
    _srcs 1; printf '# Notice (selftest fixture)\n' > "$TC/NOTICE-AUTO-UPDATE.md"
    printf 'terms_version=1 accepted_at=2026-09-30T00:00:00Z method=selftest\n' > "$CD/terms-accepted"
    o=$( { sleep 1; printf 'y\n'; } | CLAUDECODE=1 script -qec "bash '$_CP_SELF' --enable" /dev/null 2>&1 )
    local has_rec; has_rec=$(cat "$CD/close-push" 2>/dev/null)
    case "$has_rec" in "enabled=1 "*"method=close-push-enable"*) _yes "pty + y: enabled=1 method=close-push-enable" ;; *) _no "pty + y: record [$has_rec] out [$o]" ;; esac
    [ "$(gov_record_field "$CD/close-push" shown_sha256)" = "$(gov_close_push_question "$TC/NOTICE-AUTO-UPDATE.md" | gov_sha256_lf_stdin)" ] \
      && _yes "pty: shown_sha256 = the question exactly as printed (the real NOTICE path)" || _no "pty: shown_sha256 mismatch"
    _has "pty: the question ends with the [y/N] prompt" "Turn push at session close ON now? [y/N]: " "$o"
    o=$( { sleep 1; printf '\n'; } | CLAUDECODE=1 script -qec "bash '$_CP_SELF' --enable" /dev/null 2>&1 )
    case "$(cat "$CD/close-push" 2>/dev/null)" in "enabled=0 "*"method=declined"*) _yes "pty + Enter (the default No): enabled=0 method=declined" ;; *) _no "pty + Enter: $(cat "$CD/close-push" 2>/dev/null)" ;; esac
    rm -f "$TC/NOTICE-AUTO-UPDATE.md" "$CD/installed.manifest" "$TC/TERMS-VERSION"; _rec none
  else
    echo "  [SKIP] pty --enable run: no util-linux 'script' here (Git for Windows / macOS) - the answer rule is 19d, the terminal refusal 19/19c, the printed-bytes hash 19g"
  fi
  # 19g. shown_sha256 = the hash of exactly what gov_close_push_ask printed (finding 13), reached
  #      without a terminal: the printed bytes are captured and hashed independently.
  local qp="$T/q-printed" qsha
  ( GOV_SHOWN_SHA256=""; gov_close_push_ask "$TC/NOTICE-AUTO-UPDATE.md" > "$qp"; printf '%s' "$GOV_SHOWN_SHA256" > "$qp.sha" )
  qsha=$(gov_sha256_lf "$qp")
  { [ -n "$qsha" ] && [ "$(cat "$qp.sha")" = "$qsha" ]; } && _yes "gov_close_push_ask: GOV_SHOWN_SHA256 = sha256 of the bytes it printed" || _no "gov_close_push_ask: hash [$(cat "$qp.sha")] printed-bytes [$qsha]"
  [ "$(cat "$qp.sha")" != "$(gov_close_push_question NOTICE-AUTO-UPDATE.md | gov_sha256_lf_stdin)" ] \
    && _yes "control: the old canonical-name hash differs from what was printed (the finding-13 mismatch)" || _no "control: the canonical-name hash equals the printed one - the test proves nothing"
  local oldw="ssha=\$(gov_close_push_question NOTICE-AUTO-UPDATE"".md"   # split: this line must not match itself
  grep -qF -- "$oldw" "$_CP_SELF" && _no "--enable still hashes the canonical-name copy" || _yes "--enable no longer hashes a copy it did not print"
  grep -qxF -- '  GOV_SHOWN_SHA256=""; gov_close_push_ask "$notice"; ssha="$GOV_SHOWN_SHA256"' "$_CP_SELF" \
    && _yes "--enable records the hash gov_close_push_ask computed (control: the probe reads this file)" || _no "--enable does not take ssha from gov_close_push_ask"
  # --help prints the whole header, through the Env lines, and no code
  o=$(bash "$_CP_SELF" --help 2>&1)
  _has "--help reaches the last Env line" "GOV_CLOSE_PUSH_TIMEOUT (seconds per network step, default 20)" "$o"
  case "$o" in *"set -u"*) _no "--help printed code past the header" ;; *) _yes "--help stops at the end of the header comment" ;; esac
  # 20. --disable: no terminal needed, an agent may turn it OFF; then a close skips
  _rec on
  o=$(CLAUDECODE=1 bash "$_CP_SELF" --disable </dev/null 2>&1); rc=$?
  [ "$rc" = 0 ] && _yes "--disable in an agent session, no terminal: rc 0" || _no "--disable: rc=$rc ($o)"
  _has "--disable prints the A.7 line" "Push at session close: OFF (recorded " "$o"
  case "$(cat "$CD/close-push" 2>/dev/null)" in
    "enabled=0 terms_version=1 decided_at="*" method=close-push-disable"*) _yes "--disable recorded enabled=0 method=close-push-disable" ;;
    *) _no "--disable record: $(cat "$CD/close-push" 2>/dev/null)" ;;
  esac
  _mk c4; o=$(_run "$T/c4"); _ck "after --disable a close skips" "SKIP (push at session close is off on this machine - off (your choice)" "$o"
  # --disable while an update is being applied (A20): refused, the record unchanged
  _rec on; cp "$CD/close-push" "$T/rec.before"; : > "$CD/APPLYING"
  o=$(bash "$_CP_SELF" --disable </dev/null 2>&1); rc=$?
  [ "$rc" = 1 ] && _yes "--disable with APPLYING present: rc 1" || _no "--disable with APPLYING: rc=$rc"
  _has "--disable with APPLYING: one line saying why" "not now: an update is being applied (try again in a minute)" "$o"
  cmp -s "$CD/close-push" "$T/rec.before" && _yes "--disable with APPLYING: the record is unchanged" || _no "--disable with APPLYING changed the record"
  rm -f "$CD/APPLYING"; mkdir -p "$CD/lock.d"; printf 'pid=%s since=2026-09-30T00:00:00Z mode=apply\n' "$$" > "$CD/lock.d/info"
  o=$(bash "$_CP_SELF" --disable </dev/null 2>&1); rc=$?
  { [ "$rc" = 1 ] && cmp -s "$CD/close-push" "$T/rec.before"; } && _yes "--disable while lock.d names a live pid: refused, record unchanged" || _no "--disable with a live lock: rc=$rc"
  local dp; ( exit 0 ) & dp=$!; wait "$dp" 2>/dev/null
  printf 'pid=%s since=2026-09-30T00:00:00Z mode=apply\n' "$dp" > "$CD/lock.d/info"
  o=$(bash "$_CP_SELF" --disable </dev/null 2>&1); rc=$?
  { [ "$rc" = 0 ] && grep -q '^enabled=0 ' "$CD/close-push"; } && _yes "--disable with a lock left by a dead pid: recorded (not refused)" || _no "--disable with a dead-pid lock: rc=$rc ($o)"
  rm -rf "$CD/lock.d"
  # 21. consent-lib.sh missing: no push and no record, loudly
  _rec on; mkdir -p "$T/nolib"; cp "$_CP_SELF" "$T/nolib/close-push.sh"
  o=$(_CP_IN_SELFTEST="$NONCE" bash "$T/nolib/close-push.sh" -C "$T/c4" 2>&1 | tail -1)
  _ck "consent-lib.sh missing: not pushed, said loudly" "NOT PUSHED (consent-lib.sh missing beside close-push.sh)" "$o"
  o=$(bash "$T/nolib/close-push.sh" --disable </dev/null 2>&1); rc=$?
  { [ "$rc" = 1 ] && grep -q '^enabled=1 ' "$CD/close-push"; } && _yes "consent-lib.sh missing: --disable refuses, record unchanged" || _no "consent-lib.sh missing: --disable rc=$rc ($o)"
  # 22. S5: the log carries no URL / path, no scan hit, no commit message
  _rec on; _mk c5u; local su="SENTINEL-URL-$NONCE" wp u
  mkdir -p "$T/$su x"; mv "$T/c5u.git" "$T/$su x/q.git"
  wp=$(cd "$T" && { pwd -W 2>/dev/null || pwd; })
  case "$wp" in /*) u="file://$wp/$su%20x/q.git" ;; *) u="file:///$wp/$su%20x/q.git" ;; esac
  git -C "$T/c5u" remote set-url origin "$u"   # git decodes %20; the script's -d test does not find it
  o=$(_run "$T/c5u"); _ck "a local remote path that cannot be found: held" "HOLD (local remote may deploy on push: the local remote path could not be found" "$o"
  case "$o" in *"$su"*) _no "the HOLD line printed the remote path" ;; *) _yes "the HOLD line does not print the remote path" ;; esac
  _mk c5m; printf 'm\n' >> "$T/c5m/a.txt"; git -C "$T/c5m" commit --quiet -am "SENTINEL-MSG-$NONCE ghp_$tok36"
  o=$(_run "$T/c5m"); _ck "a secret in a commit message (sentinel case): refused" "NOT PUSHED (secret-shaped" "$o"
  local LOG="$HOME/.claude/logs/governance.log" n s
  n=$(grep -c '\[close-push\]' "$LOG" 2>/dev/null) || true
  [ "${n:-0}" -gt 0 ] && _yes "the log is written ($n close-push lines - the control for the greps below)" || _no "the log is empty: the redaction greps prove nothing"
  # 22b. (round 3, finding 2) a "remote name" read from git config can be a URL with credentials or
  #      a path: `git push -u <url> <branch>` stores it in branch.<b>.remote. Every such spelling -
  #      remote, pushRemote, pushDefault, the merge (upstream) name - is held AND never printed.
  _mk c5r; local sc="SENTINEL-CRED-$NONCE" sf="SENTINEL-FURL-$NONCE" sp="SENTINEL-PATH-$NONCE" \
    spr="SENTINEL-PREM-$NONCE" spd="SENTINEL-PDEF-$NONCE" smg="SENTINEL-MERGE-$NONCE" full
  local xh="example.invalid"   # the host is a variable so no line here reads as an address
  mkdir -p "$T/$sp/q.git"
  _s5() { # _s5 <label> <sentinel> <expected HOLD prefix>: run once, check stdout (all of it) + log
    full=$(_CP_IN_SELFTEST="$NONCE" bash "$_CP_SELF" -C "$T/c5r" 2>&1); o=$(printf '%s\n' "$full" | tail -1)
    _ck "$1: held, the reason still printed" "$3" "$o"
    case "$full" in *"$2"*) _no "$1: stdout carries the sentinel" ;; *) _yes "$1: stdout has no sentinel" ;; esac
    n=$(grep -cF -- "$2" "$LOG" 2>/dev/null) || true
    [ "${n:-0}" = 0 ] && _yes "$1: the log has no sentinel" || _no "$1: the log carries the sentinel ($n line(s))"
  }
  local RL='<remote given as a URL or path>'
  git -C "$T/c5r" config branch.main.remote "https://user:$sc@$xh/x.git"
  _s5 "branch.main.remote = https URL with user:token" "$sc" "HOLD (remote $RL has 0 url(s)"
  git -C "$T/c5r" config branch.main.remote "file:///C:/$sf/q.git"
  _s5 "branch.main.remote = file:/// URL" "$sf" "HOLD (remote $RL has 0 url(s)"
  git -C "$T/c5r" config branch.main.remote "$T/$sp/q.git"
  _s5 "branch.main.remote = a plain local path" "$sp" "HOLD (remote $RL has 0 url(s)"
  git -C "$T/c5r" config branch.main.remote origin
  git -C "$T/c5r" config branch.main.pushRemote "https://user:$spr@$xh/p.git"
  _s5 "branch.main.pushRemote = a URL" "$spr" "HOLD (a push remote other than origin is configured"
  git -C "$T/c5r" config --unset branch.main.pushRemote
  git -C "$T/c5r" config remote.pushDefault "$T/$spd/q.git"
  _s5 "remote.pushDefault = a local path" "$spd" "HOLD (a push remote other than origin is configured"
  git -C "$T/c5r" config --unset remote.pushDefault
  git -C "$T/c5r" config branch.main.merge "refs/heads/https://user:$smg@$xh/m"
  _s5 "branch.main.merge = a URL-shaped upstream name" "$smg" "HOLD (local branch main tracks origin/<upstream branch name withheld> - a different name"
  # Controls: ordinary names are still printed (a redaction that hid every name would pass the above).
  git -C "$T/c5r" config branch.main.merge refs/heads/feature-x
  o=$(_run "$T/c5r"); _ck "control: an ordinary upstream name is still shown" "HOLD (local branch main tracks origin/feature-x - a different name" "$o"
  git -C "$T/c5r" config branch.main.merge refs/heads/main
  git -C "$T/c5r" remote rename origin up-stream_1.x 2>/dev/null
  git -C "$T/c5r" config remote.up-stream_1.x.pushurl "$T/elsewhere.git"
  o=$(_run "$T/c5r"); _ck "control: an ordinary remote name is still shown" "HOLD (remote up-stream_1.x has 1 url(s) and 1 push url(s)" "$o"
  # 22c. (verify round 4 #3) the other lines that printed user data before the file-name secret scan:
  #      a CI file name, a .gitattributes path (LFS), the LOCAL branch name, an invalid close_push
  #      value. Each: held, the reason still printed, the sentinel in neither stdout nor the log.
  #      The sentinels are token-shaped and unique to this run (the digits of the nonce).
  local dg sw sl sb sg sv
  dg=$(printf '%s' "$NONCE" | tr -cd '0-9'); dg="${dg}00000000000000"
  sw="ghp_W$(printf 'W%.0s' $(seq 1 27))${dg:0:8}"      # a workflow file name (ghp_ + 36)
  sl="ghp_L$(printf 'L%.0s' $(seq 1 27))${dg:0:8}"      # a directory holding a .gitattributes (LFS)
  sb="AKIA$(printf 'Q%.0s' $(seq 1 8))${dg:0:8}"        # a local branch name (AWS key id shape, 20)
  sg="ghp_G$(printf 'G%.0s' $(seq 1 27))${dg:0:8}"      # a local branch name with an underscore
  sv="zzsntl${dg:0:14}"                                 # an invalid close_push value (printed lower-cased before)
  _s5d() { # _s5d <label> <repo dir> <sentinel> <expected prefix>: like _s5, for any repo
    full=$(_CP_IN_SELFTEST="$NONCE" bash "$_CP_SELF" -C "$2" 2>&1); o=$(printf '%s\n' "$full" | tail -1)
    _ck "$1: held, the reason still printed" "$4" "$o"
    case "$full" in *"$3"*) _no "$1: stdout carries the sentinel" ;; *) _yes "$1: stdout has no sentinel" ;; esac
    n=$(grep -cF -- "$3" "$LOG" 2>/dev/null) || true
    [ "${n:-0}" = 0 ] && _yes "$1: the log has no sentinel" || _no "$1: the log carries the sentinel ($n line(s))"
  }
  _mk c6w; mkdir -p "$T/c6w/.github/workflows"; printf 'on: [push]\n' > "$T/c6w/.github/workflows/$sw.yml"
  git -C "$T/c6w" add -A; git -C "$T/c6w" commit --quiet -m wf
  _s5d "a workflow file named like a token" "$T/c6w" "$sw" "HOLD (CI or deploy config in the pushed commit: a file under .github/workflows/ (1 file(s) in all)"
  _mk c6l "close_push: on"; mkdir -p "$T/c6l/$sl"; printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > "$T/c6l/$sl/.gitattributes"
  git -C "$T/c6l" add -A; git -C "$T/c6l" commit --quiet -m lfs
  _s5d "a .gitattributes with filter=lfs under a token-named directory" "$T/c6l" "$sl" "HOLD (Git LFS in use (filter=lfs in a .gitattributes file): LFS file contents cannot be scanned"
  _mk c6b; git -C "$T/c6b" checkout --quiet -b "$sb" --track origin/main 2>/dev/null; printf 'k\n' >> "$T/c6b/a.txt"; git -C "$T/c6b" commit --quiet -am k
  _s5d "a local branch named like an AWS key id (tracks origin/main)" "$T/c6b" "$sb" "HOLD (local branch <branch name withheld> tracks origin/main - a different name"
  git -C "$T/c6b" checkout --quiet -b "$sg" 2>/dev/null
  _s5d "a local branch named like a GitHub token, no upstream" "$T/c6b" "$sg" "SKIP (branch <branch name withheld> has no upstream"
  _mk c6v "close_push: $sv"
  _s5d "an invalid close_push value" "$T/c6v" "$sv" "HOLD (close_push has an unknown value (not shown) - expected on|off|auto)"
  # Controls: ordinary names are still shown (a redaction that hid every name would pass the above).
  git -C "$T/c6b" checkout --quiet -b topic-1 --track origin/main 2>/dev/null
  o=$(_run "$T/c6b"); _ck "control: an ordinary local branch name is still shown" "HOLD (local branch topic-1 tracks origin/main - a different name" "$o"
  # 22c2. (fix round 4 G4-2) a name the SECRET rule flags but with no run of 20: sk- + three groups of
  #       10 letters joined by `-` (built here, so no literal token sits in this file). Before the fix
  #       it was printed in full, stdout and log. As a local branch and as an upstream name; controls:
  #       release-2.0 is still printed in both places.
  local ssk; ssk="sk-$(printf 'a%.0s' $(seq 1 10))-$(printf 'b%.0s' $(seq 1 10))-$(printf 'c%.0s' $(seq 1 10))"
  _mk c7b; git -C "$T/c7b" checkout --quiet -b "$ssk" --track origin/main 2>/dev/null; printf 'k\n' >> "$T/c7b/a.txt"; git -C "$T/c7b" commit --quiet -am k
  _s5d "a local branch named sk- + 3x10 letters (tracks origin/main)" "$T/c7b" "$ssk" "HOLD (local branch <branch name withheld> tracks origin/main - a different name"
  git -C "$T/c7b" checkout --quiet main 2>/dev/null; git -C "$T/c7b" config branch.main.merge "refs/heads/$ssk"
  _s5d "an upstream named sk- + 3x10 letters" "$T/c7b" "$ssk" "HOLD (local branch main tracks origin/<upstream branch name withheld> - a different name"
  git -C "$T/c7b" config branch.main.merge refs/heads/release-2.0
  o=$(_run "$T/c7b"); _ck "control: an upstream named release-2.0 is still shown" "HOLD (local branch main tracks origin/release-2.0 - a different name" "$o"
  git -C "$T/c7b" config branch.main.merge refs/heads/main
  git -C "$T/c7b" checkout --quiet -b release-2.0 --track origin/main 2>/dev/null
  o=$(_run "$T/c7b"); _ck "control: a local branch named release-2.0 is still shown" "HOLD (local branch release-2.0 tracks origin/main - a different name" "$o"
  # The name test itself, both directions (no repo needed). Token shapes are built, never literal.
  local tk ok_n=0 bad_n=""
  for tk in "$ssk" "xox""b-$(printf 'x%.0s' $(seq 1 16))" "AKIA$(printf 'Q%.0s' $(seq 1 16))" \
            "abcdefgh-ijklmnop_qrstuvwx" "feature/$(printf 'ab-%.0s' $(seq 1 12))" "sk_live-$(printf 'z%.0s' $(seq 1 12))_$(printf 'y%.0s' $(seq 1 12))"; do
    if [ "$(_cp_bname "$tk")" = "<upstream branch name withheld>" ] && [ "$(_cp_rname "${tk//\//-}")" = "<remote name withheld>" ]; then ok_n=$((ok_n+1)); else bad_n="$bad_n [$tk]"; fi
  done
  [ -z "$bad_n" ] && _yes "_cp_bname / _cp_rname withhold 6 token shapes (sk-, xox, AKIA, -/_-joined 24+, ...)" || _no "printed in full:$bad_n"
  ok_n=0; bad_n=""
  for tk in release-2.0 main feature/add-login topic-1 v2.0.0 up-stream_1.x "fix/$(printf 'ab-%.0s' $(seq 1 11))a"; do
    if [ "$(_cp_bname "$tk")" = "$tk" ]; then ok_n=$((ok_n+1)); else bad_n="$bad_n [$tk]"; fi
  done
  [ -z "$bad_n" ] && _yes "control: 7 ordinary names (23 letters/digits joined, too) are printed as they are" || _no "ordinary names withheld:$bad_n"
  # Drift guard: every part of the scan's SECRET rule that can occur in a name (no blank in it) is in
  # _CP_NAME_SECRET_RE verbatim. A new name-shaped scan rule fails here until the copy carries it.
  local srule sp_part miss="" n_parts=0
  srule=$(bash "$_CP_DIR_OF_SELF/check-no-pii.sh" --list-rules 2>/dev/null | awk '$1=="SECRET"{sub(/^SECRET[[:space:]]+/,""); print; exit}')
  if [ -n "$srule" ]; then
    srule="${srule#(}"; srule="${srule%)}"; srule="${srule//")|("/$'\n'}"
    while IFS= read -r sp_part; do
      case "$sp_part" in ''|*" "*|*"[[:space:]]"*) continue ;; esac
      n_parts=$((n_parts+1))
      case "$_CP_NAME_SECRET_RE" in *"($sp_part)"*) ;; *) miss="$miss ($sp_part)" ;; esac
    done <<EOF
$srule
EOF
    { [ -z "$miss" ] && [ "$n_parts" -ge 6 ]; } && _yes "every name-shaped part of check-no-pii.sh's SECRET rule ($n_parts) is in _CP_NAME_SECRET_RE" || _no "_CP_NAME_SECRET_RE lacks:$miss (parts read: $n_parts)"
  else
    _no "check-no-pii.sh --list-rules gave no SECRET rule: the drift guard cannot run"
  fi
  _mk c6p; git -C "$T/c6p" config branch.main.pushRemote fork
  o=$(_run "$T/c6p"); _ck "control: an ordinary push remote name is still shown" "HOLD (a push remote other than origin is configured (pushRemote/pushDefault: fork); push by hand)" "$o"
  _mk c6c; mkdir -p "$T/c6c/.circleci"; printf 'x: 1\n' > "$T/c6c/.circleci/config.yml"; printf '{}\n' > "$T/c6c/netlify.toml"
  git -C "$T/c6c" add -A; git -C "$T/c6c" commit --quiet -m two
  o=$(_run "$T/c6c"); _ck "control: two CI / deploy files: the first rule's label and the count" "HOLD (CI or deploy config in the pushed commit: a file under .circleci/ (2 file(s) in all)" "$o"
  for s in "SENTINEL-URL-$NONCE" "SENTINEL-MSG-$NONCE" "ghp_" "$T" "$wp" "user:" "$xh"; do
    n=$(grep -cF -- "$s" "$LOG" 2>/dev/null) || true
    [ "${n:-0}" = 0 ] && _yes "the log has no '${s:0:14}...' (S5)" || _no "the log carries '$s' ($n line(s))"
  done

  rm -rf "$T" 2>/dev/null
  echo "close-push selftest: pass=$pass fail=$fail"
  [ "$fail" = 0 ] && [ "$pass" -gt 0 ]
}

if [ "$_cp_want_selftest" = 1 ]; then
  close_push_selftest; exit $?
fi
case "$_cp_action" in
  enable)  close_push_enable;  exit $? ;;
  disable) close_push_disable; exit $? ;;
esac
close_push_main "$_cp_dir"
exit 0
