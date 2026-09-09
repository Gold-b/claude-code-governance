#!/usr/bin/env bash
# pr-watch.sh — in-session PR watcher (Context Governance, generic; carries NO project data).
#
# Polls GitHub through `gh` for the CALLER'S OWN open pull requests on ONE repository and prints
# one line per change. Stdout is the event stream: arm it with the Monitor tool and every line
# becomes a notification in the session. On a merge it fast-forwards the local clone's base branch.
# It exits by itself when no open PR of the caller remains.
#
# Usage:
#   pr-watch.sh [--repo owner/name] [--clone <path>] [--session <id>] [--interval <sec>] [--once]
#   pr-watch.sh --selftest
#
#   --repo      GitHub repo. Default: `gh repo view` inside --clone (or the cwd).
#   --clone     local clone to fast-forward when a PR merges. Default: cwd when it is that repo.
#   --session   a key that keeps this watcher's state apart from another session's watcher on
#               the same repo (the guard hook passes the Claude session id). Default: "default".
#   --interval  poll interval in seconds. Default 90, floor 30 (GitHub rate limits).
#   --once      a single poll: print the baseline / the events since the last snapshot, exit 0.
#   --selftest  offline positive+negative control of the diff engine. No network, no gh.
#
# Events (one per line, always with the PR url so a reader can jump in):
#   PR #n TRACKING [state] title url          first time a PR is seen by this watcher
#   PR #n COMMENT by <login> at <ts> url      a new issue comment by someone other than the caller
#   PR #n REVIEW <STATE> by <login> url       a new review (APPROVED / CHANGES_REQUESTED / COMMENTED)
#   PR #n REVIEW_DECISION <old>-><new> url
#   PR #n THUMBS_UP total=<n> url             a new +1 reaction on the PR body
#   PR #n REACTION total=<n> url              any other reaction change on the PR body
#   PR #n CHECKS <old>-><new> url             CI rollup: none | pending | pass | fail
#   PR #n MERGE_STATE <old>-><new> url        CLEAN | BLOCKED | BEHIND | DIRTY | UNSTABLE ...
#   PR #n MERGED by <login> at <ts> url       terminal; followed by a PULLED / PULL SKIPPED line
#   PR #n CLOSED (not merged) url             terminal
#   NO OPEN PRS of <login> on <repo> - watcher exiting
#
# State (per repo + session key), under $PR_WATCH_STATE_DIR (default ~/.claude/state/pr-watch):
#   <owner>__<repo>__<session>.snap        last snapshot, one fingerprint line per OPEN PR
#   <owner>__<repo>__<session>.heartbeat   unix time of the last poll (the guard hook reads it)
#   <owner>__<repo>__<session>.pid
#
# Kill switch: GOV_PR_WATCH=0 (exits 0 at once). Needs: bash, gh (authenticated), git, GNU date.
# Never merges, never comments, never pushes. Reads GitHub, writes only its own state files and
# a fast-forward of the clone's base branch.
set -u

REPO=""; CLONE=""; SESSION="default"; INTERVAL=90; ONCE=0; SELFTEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --clone) CLONE="${2:-}"; shift 2 ;;
    --session) SESSION="${2:-default}"; shift 2 ;;
    --interval) INTERVAL="${2:-90}"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --selftest) SELFTEST=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "pr-watch: unknown argument: $1" >&2; exit 64 ;;
  esac
done

[ "${GOV_PR_WATCH:-1}" = "0" ] && exit 0
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=90 ;; esac
[ "$INTERVAL" -lt 30 ] && INTERVAL=30
SESSION=$(printf '%s' "$SESSION" | tr -cd 'A-Za-z0-9._-'); [ -n "$SESSION" ] || SESSION=default

STATE_DIR="${PR_WATCH_STATE_DIR:-$HOME/.claude/state/pr-watch}"

# --- pure part: fingerprints and their diff --------------------------------------------------
# One line per PR. 14 fields, '|' separated (the title is scrubbed of '|' and newlines):
#  1 number | 2 title | 3 url | 4 state | 5 reviewDecision | 6 mergeStateStatus | 7 checks
#  8 comments=n;lastBy;lastAt | 9 reviews=n;lastState;lastBy;lastAt
# 10 plus1=n;eyes=n;react=n | 11 mergedAt | 12 mergedBy | 13 baseRefName | 14 updatedAt
GH_FIELDS='number,title,url,state,reviewDecision,mergeStateStatus,statusCheckRollup,comments,reviews,reactionGroups,mergedAt,mergedBy,baseRefName,updatedAt'
GH_JQ='[
 (.number|tostring),
 ((.title // "")|gsub("[|\r\n]";" ")|.[0:80]),
 (.url // ""),
 (.state // ""),
 (.reviewDecision // "NONE" | if .=="" then "NONE" else . end),
 (.mergeStateStatus // "UNKNOWN"),
 ( (.statusCheckRollup // []) as $c
   | if ($c|length)==0 then "none"
     elif ([ $c[] | ((.conclusion // .state // "")|ascii_upcase) | select(test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE")) ]|length)>0 then "fail"
     elif ([ $c[] | select( (((.status // "")|ascii_upcase) as $s | ($s!="" and $s!="COMPLETED")) or (((.state // "")|ascii_upcase) as $t | ($t=="PENDING" or $t=="EXPECTED")) ) ]|length)>0 then "pending"
     else "pass" end ),
 ( (.comments // []) as $x | "comments=\($x|length);\($x|last|.author.login // "-");\($x|last|.createdAt // "-")" ),
 ( (.reviews // []) as $x | "reviews=\($x|length);\($x|last|.state // "-");\($x|last|.author.login // "-");\($x|last|.submittedAt // "-")" ),
 ( (.reactionGroups // []) as $r | "plus1=\([ $r[] | select(.content=="THUMBS_UP") | .users.totalCount ] | add // 0);eyes=\([ $r[] | select(.content=="EYES") | .users.totalCount ] | add // 0);react=\([ $r[] | .users.totalCount ] | add // 0)" ),
 (.mergedAt // "-"),
 (.mergedBy.login // "-"),
 (.baseRefName // "-"),
 (.updatedAt // "-")
] | join("|")'

field() { printf '%s' "$1" | cut -d';' -f"$2"; }          # sub-field of "k=v;a;b"
count() { local v; v=$(field "$1" 1); printf '%s' "${v#*=}"; }

# diff_snapshots <old-file> <new-file> <me>
# Prints event lines. Internal directives start with '@PULL|<n>|<base>' and are consumed by the
# main loop (never printed).
diff_snapshots() {
  local old="$1" new="$2" me="$3"
  local n title url state dec ms chk com rev rea mAt mBy base upd o
  local _ otitle ourl ostate odec oms ochk ocom orev orea omAt omBy obase oupd
  while IFS='|' read -r n title url state dec ms chk com rev rea mAt mBy base upd; do
    [ -z "$n" ] && continue
    o=$(grep -m1 "^$n|" "$old" 2>/dev/null || true)
    if [ -z "$o" ]; then
      echo "PR #$n TRACKING [$state] $title $url"
      continue
    fi
    IFS='|' read -r _ otitle ourl ostate odec oms ochk ocom orev orea omAt omBy obase oupd <<<"$o"
    if [ "$state" != "$ostate" ]; then
      case "$state" in
        MERGED) echo "PR #$n MERGED by $mBy at $mAt $url"; echo "@PULL|$n|$base" ;;
        CLOSED) echo "PR #$n CLOSED (not merged) $url" ;;
        *)      echo "PR #$n STATE $ostate->$state $url" ;;
      esac
    fi
    if [ "$(count "$com")" != "$(count "$ocom")" ]; then
      local cby cat; cby=$(field "$com" 2); cat=$(field "$com" 3)
      [ "$cby" != "$me" ] && echo "PR #$n COMMENT by $cby at $cat (total $(count "$com")) $url"
    fi
    if [ "$(count "$rev")" != "$(count "$orev")" ]; then
      local rst rby; rst=$(field "$rev" 2); rby=$(field "$rev" 3)
      [ "$rby" != "$me" ] && echo "PR #$n REVIEW $rst by $rby $url"
    fi
    [ "$dec" != "$odec" ] && echo "PR #$n REVIEW_DECISION $odec->$dec $url"
    local p1 op1 rt ort
    p1=$(count "$rea"); op1=$(count "$orea")
    rt=$(field "$rea" 3); rt=${rt#react=}; ort=$(field "$orea" 3); ort=${ort#react=}
    if [ "$p1" != "$op1" ]; then echo "PR #$n THUMBS_UP total=$p1 $url"
    elif [ "$rt" != "$ort" ]; then echo "PR #$n REACTION total=$rt $url"; fi
    [ "$chk" != "$ochk" ] && echo "PR #$n CHECKS $ochk->$chk $url"
    [ "$ms" != "$oms" ] && echo "PR #$n MERGE_STATE $oms->$ms $url"
  done < "$new"
  return 0
}

# --- offline selftest: one control that MUST fire, one that MUST NOT -------------------------
if [ "$SELFTEST" = "1" ]; then
  T=$(mktemp -d 2>/dev/null || mktemp -d -t prw); fails=0
  L1='14|fix(market): feeds|https://x/pull/14|OPEN|NONE|CLEAN|pass|comments=1;me;2026-01-01T00:00:00Z|reviews=0;-;-;-|plus1=0;eyes=0;react=0|-|-|main|2026-01-01T00:00:00Z'
  L2='15|fix(security): xss|https://x/pull/15|OPEN|NONE|CLEAN|pass|comments=0;-;-|reviews=0;-;-;-|plus1=0;eyes=0;react=0|-|-|main|2026-01-01T00:00:00Z'
  printf '%s\n%s\n' "$L1" "$L2" > "$T/old"
  # positive control: a reviewer comment, an approval, a +1 and a merge must all surface
  printf '%s\n%s\n' \
    '14|fix(market): feeds|https://x/pull/14|OPEN|APPROVED|CLEAN|pass|comments=2;reviewer;2026-01-02T00:00:00Z|reviews=1;APPROVED;reviewer;2026-01-02T00:00:00Z|plus1=1;eyes=0;react=1|-|-|main|2026-01-02T00:00:00Z' \
    '15|fix(security): xss|https://x/pull/15|MERGED|NONE|UNKNOWN|pass|comments=0;-;-|reviews=0;-;-;-|plus1=0;eyes=0;react=0|2026-01-02T00:00:00Z|owner|main|2026-01-02T00:00:00Z' > "$T/new"
  out=$(diff_snapshots "$T/old" "$T/new" "me")
  for must in 'PR #14 COMMENT by reviewer' 'PR #14 REVIEW APPROVED by reviewer' 'PR #14 REVIEW_DECISION NONE->APPROVED' 'PR #14 THUMBS_UP total=1' 'PR #15 MERGED by owner' '@PULL|15|main'; do
    case "$out" in *"$must"*) echo "PASS must-fire: $must" ;; *) echo "FAIL must-fire: $must"; fails=$((fails+1)) ;; esac
  done
  # the caller's own comment must NOT be an event
  printf '%s\n' '14|fix(market): feeds|https://x/pull/14|OPEN|NONE|CLEAN|pass|comments=2;me;2026-01-02T00:00:00Z|reviews=0;-;-;-|plus1=0;eyes=0;react=0|-|-|main|2026-01-02T00:00:00Z' > "$T/new2"
  out2=$(diff_snapshots "$T/old" "$T/new2" "me")
  case "$out2" in *COMMENT*) echo "FAIL must-not-fire: own comment produced an event"; fails=$((fails+1)) ;; *) echo "PASS must-not-fire: own comment is silent" ;; esac
  # negative control: identical snapshots must be silent
  out3=$(diff_snapshots "$T/old" "$T/old" "me")
  if [ -z "$out3" ]; then echo "PASS must-not-fire: identical snapshots are silent"; else echo "FAIL must-not-fire: identical snapshots produced: $out3"; fails=$((fails+1)); fi
  # a PR never seen before is announced once
  out4=$(diff_snapshots /dev/null "$T/old" "me")
  case "$out4" in *"PR #14 TRACKING [OPEN]"*"PR #15 TRACKING [OPEN]"*) echo "PASS must-fire: new PRs announced" ;; *) echo "FAIL must-fire: new PRs not announced: $out4"; fails=$((fails+1)) ;; esac
  rm -rf "$T"
  [ "$fails" -eq 0 ] && { echo "pr-watch selftest: ALL GREEN"; exit 0; } || { echo "pr-watch selftest: $fails FAILURE(S)"; exit 1; }
fi

# --- live part ---------------------------------------------------------------------------------
command -v gh >/dev/null 2>&1 || { echo "pr-watch: gh not found" >&2; exit 69; }
[ -n "$CLONE" ] || CLONE="$PWD"
if [ -z "$REPO" ]; then
  REPO=$(cd "$CLONE" 2>/dev/null && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || true
fi
[ -n "$REPO" ] || { echo "pr-watch: no --repo and the cwd is not a GitHub clone" >&2; exit 65; }
# only fast-forward a clone that really is this repo
if ! (cd "$CLONE" 2>/dev/null && [ "$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" = "$REPO" ]); then
  CLONE=""
fi
ME=$(gh api user --jq .login 2>/dev/null) || ME=""
[ -n "$ME" ] || { echo "pr-watch: gh is not authenticated (gh api user failed)" >&2; exit 77; }

KEY=$(printf '%s__%s' "${REPO%/*}" "${REPO#*/}" | tr -cd 'A-Za-z0-9._-')__$SESSION
mkdir -p "$STATE_DIR" 2>/dev/null
SNAP="$STATE_DIR/$KEY.snap"; HB="$STATE_DIR/$KEY.heartbeat"; PIDF="$STATE_DIR/$KEY.pid"; NEW="$STATE_DIR/$KEY.new"
echo $$ > "$PIDF"
trap 'rm -f "$PIDF" "$NEW" 2>/dev/null' EXIT
[ -f "$SNAP" ] || : > "$SNAP"

pull_base() { # <n> <base>
  local n="$1" base="$2" cur dirty
  [ -n "$CLONE" ] || { echo "PR #$n PULL SKIPPED (no local clone given)"; return 0; }
  cur=$(git -C "$CLONE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
  dirty=$(git -C "$CLONE" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  git -C "$CLONE" fetch -q origin "$base" 2>/dev/null || { echo "PR #$n PULL FAILED (fetch origin/$base)"; return 0; }
  if [ "$cur" = "$base" ] && [ "$dirty" = "0" ]; then
    if git -C "$CLONE" pull -q --ff-only origin "$base" >/dev/null 2>&1; then
      echo "PR #$n PULLED $base@$(git -C "$CLONE" rev-parse --short HEAD 2>/dev/null) in $CLONE"
    else
      echo "PR #$n PULL FAILED (not fast-forward) on $base in $CLONE"
    fi
  else
    echo "PR #$n PULL SKIPPED (clone on '$cur', $dirty dirty file(s)); origin/$base fetched"
  fi
}

consecutive_fail=0
while :; do
  date +%s > "$HB"
  if ! open=$(gh pr list --repo "$REPO" --author "@me" --state open --json number --jq '.[].number' 2>/dev/null); then
    consecutive_fail=$((consecutive_fail+1))
    [ "$consecutive_fail" -eq 3 ] && echo "WARN pr-watch: gh pr list failed 3 times in a row on $REPO (network/auth?) - still watching"
    [ "$ONCE" = "1" ] && exit 1
    sleep "$INTERVAL"; continue
  fi
  consecutive_fail=0
  tracked=$( { printf '%s\n' $open; cut -d'|' -f1 "$SNAP"; } | grep -E '^[0-9]+$' | sort -un)
  : > "$NEW"
  for n in $tracked; do
    gh pr view "$n" --repo "$REPO" --json "$GH_FIELDS" --jq "$GH_JQ" >> "$NEW" 2>/dev/null \
      || echo "WARN pr-watch: gh pr view #$n failed on $REPO"
  done
  events=$(diff_snapshots "$SNAP" "$NEW" "$ME")
  if [ -n "$events" ]; then
    printf '%s\n' "$events" | while IFS= read -r line; do
      case "$line" in
        @PULL\|*) IFS='|' read -r _ pn pb <<<"$line"; pull_base "$pn" "$pb" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done
  fi
  # the next baseline keeps OPEN PRs only; merged/closed ones leave the snapshot after one report
  grep -E '^[0-9]+\|[^|]*\|[^|]*\|OPEN\|' "$NEW" > "$SNAP" 2>/dev/null || : > "$SNAP"
  if [ ! -s "$SNAP" ]; then
    echo "NO OPEN PRS of $ME on $REPO - watcher exiting"
    exit 0
  fi
  [ "$ONCE" = "1" ] && exit 0
  sleep "$INTERVAL"
done
