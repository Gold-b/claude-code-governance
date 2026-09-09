#!/usr/bin/env bash
# pr-watch-guard.sh — Context Governance hook: keeps a PR watcher armed for the caller's open PRs.
#
# One script, registered on three events, branching on the payload's hook_event_name:
#   PostToolUse (Bash|PowerShell)  after a PR action (gh pr create/view/comment/review/merge/edit/
#                                  ready/checks/status/list, git push): when the cwd repo has open
#                                  PRs authored by the caller and no LIVE watcher for this session,
#                                  returns {"decision":"block","reason":...} telling the session to
#                                  arm pr-watch.sh through the Monitor tool. A cool-down (the stale
#                                  window) keeps it from repeating while the session is arming.
#   SessionStart                   same test; prints one context line so the session arms it first.
#   Stop                           same test; holds the stop ONCE per repo+session (marker file) -
#                                  "arm the watcher, then stop" - the next stop passes.
#
# "Live watcher" = <state-dir>/<owner>__<repo>__<session>.heartbeat written less than
# PR_WATCH_STALE_SEC ago (default 300 s; pr-watch.sh rewrites it on every poll).
# The guard itself never blocks a tool (PostToolUse cannot), never merges, never comments, never
# pushes; it reads GitHub (two gh calls) and writes only its own marker files.
#
# Kill switches: GOV_PR_WATCH=0, or the framework-wide GOVERNANCE_HOOKS=0 (gov_disabled).
# Selftest seams, honoured ONLY when GOV_SELFTEST_SBX is set (governance-selftest.sh exports it):
#   PR_WATCH_GUARD_REPO=owner/name   pretend the cwd is this repo      (no gh call)
#   PR_WATCH_GUARD_OPEN=<n>          pretend n open PRs of the caller  (no gh call)
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0
[ "${GOV_PR_WATCH:-1}" = "0" ] && exit 0

INPUT="$(gov_hook_input)"
EVENT=$(printf '%s' "$INPUT" | grep -o '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//')
case "$EVENT" in PostToolUse|SessionStart|Stop) ;; *) exit 0 ;; esac

SID=$(gov_session_id); [ -n "$SID" ] || SID=default
CWD=$(gov_payload_root "$INPUT"); [ -n "$CWD" ] || CWD="$PWD"
STATE_DIR="${PR_WATCH_STATE_DIR:-$HOME/.claude/state/pr-watch}"
STALE="${PR_WATCH_STALE_SEC:-300}"; case "$STALE" in ''|*[!0-9]*) STALE=300 ;; esac
WATCH="$SCRIPT_DIR/pr-watch.sh"

_to() { if command -v timeout >/dev/null 2>&1; then timeout 8 "$@"; else "$@"; fi; }

# --- PostToolUse: only after a PR-shaped command ----------------------------------------------
if [ "$EVENT" = "PostToolUse" ]; then
  CMD=""
  if command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
    PY=python3; command -v python3 >/dev/null 2>&1 || PY=python
    CMD=$(printf '%s' "$INPUT" | "$PY" -X utf8 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print((d.get("tool_input") or {}).get("command") or "")
except Exception:
    print("")
' 2>/dev/null)
  fi
  if [ -z "$CMD" ]; then
    # python-free fallback: the raw command text is enough for a pattern test
    CMD=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*' | head -1 | sed 's/.*:[[:space:]]*"//')
  fi
  printf '%s' "$CMD" | grep -qE '(^|[^A-Za-z0-9_./-])gh[[:space:]]+pr[[:space:]]+(create|view|comment|review|merge|edit|ready|checks|status|list)([[:space:]]|$)|(^|[^A-Za-z0-9_./-])git[[:space:]]+push([[:space:]]|$)' || exit 0
fi

# --- which repo, how many open PRs of the caller -----------------------------------------------
REPO=""
if [ -n "${GOV_SELFTEST_SBX:-}" ] && [ -n "${PR_WATCH_GUARD_REPO:-}" ]; then
  REPO="$PR_WATCH_GUARD_REPO"
else
  command -v gh >/dev/null 2>&1 || exit 0
  # no network unless the clone points at GitHub at all
  git -C "$CWD" remote get-url origin 2>/dev/null | grep -qi 'github\.com' || exit 0
  REPO=$(cd "$CWD" 2>/dev/null && _to gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
fi
[ -n "$REPO" ] || exit 0

OPEN=""
if [ -n "${GOV_SELFTEST_SBX:-}" ] && [ -n "${PR_WATCH_GUARD_OPEN:-}" ]; then
  OPEN="$PR_WATCH_GUARD_OPEN"
else
  OPEN=$(_to gh pr list --repo "$REPO" --author "@me" --state open --json number --jq 'length' 2>/dev/null)
fi
case "$OPEN" in ''|*[!0-9]*) exit 0 ;; esac
[ "$OPEN" -gt 0 ] || exit 0

KEY=$(printf '%s__%s' "${REPO%/*}" "${REPO#*/}" | tr -cd 'A-Za-z0-9._-')__$(printf '%s' "$SID" | tr -cd 'A-Za-z0-9._-')
mkdir -p "$STATE_DIR" 2>/dev/null
HB="$STATE_DIR/$KEY.heartbeat"
NOW=$(date +%s)
if [ -f "$HB" ]; then
  LAST=$(head -c 32 "$HB" 2>/dev/null | tr -cd '0-9'); [ -n "$LAST" ] || LAST=0
  [ $((NOW - LAST)) -lt "$STALE" ] && exit 0      # a live watcher exists - nothing to do
fi

ARM="$WATCH --repo $REPO --clone \"$CWD\" --session $SID"
MSG="[pr-watch] $REPO has $OPEN open PR(s) authored by you and no live watcher for this session. Arm it now with the Monitor tool: command = $ARM ; persistent = true ; description = PR watch $REPO. Every stdout line is a PR event (comment, review, +1, CI, merge - the clone's base branch is fast-forwarded on merge). Keep it armed until every PR is merged; re-arm after it exits if you open another PR. Flow and cadence rules: /pr-follow-through."

emit_block() {  # $1 reason -> {"decision":"block","reason":...} on stdout, exit 0
  local PY=""; command -v python3 >/dev/null 2>&1 && PY=python3; [ -n "$PY" ] || { command -v python >/dev/null 2>&1 && PY=python; }
  if [ -n "$PY" ] && printf '%s' "$1" | "$PY" -X utf8 -c 'import json,sys; print(json.dumps({"decision":"block","reason":sys.stdin.read()}))' 2>/dev/null; then
    return 0
  fi
  printf '{"decision":"block","reason":"%s"}\n' "$(printf '%s' "$1" | tr '\n\r' '  ' | sed 's/["\\]/ /g')"
}

case "$EVENT" in
  PostToolUse)
    NAG="$STATE_DIR/$KEY.nag"
    if [ -f "$NAG" ]; then
      LASTNAG=$(head -c 32 "$NAG" 2>/dev/null | tr -cd '0-9'); [ -n "$LASTNAG" ] || LASTNAG=0
      [ $((NOW - LASTNAG)) -lt "$STALE" ] && exit 0
    fi
    printf '%s' "$NOW" > "$NAG"
    gov_log "pr-watch-guard" "PostToolUse: $REPO open=$OPEN, no live watcher for $SID - asked the session to arm"
    emit_block "$MSG"
    ;;
  SessionStart)
    gov_log "pr-watch-guard" "SessionStart: $REPO open=$OPEN, no live watcher for $SID"
    printf '%s\n' "$MSG"
    ;;
  Stop)
    MARK="$STATE_DIR/$KEY.stopheld"
    [ -f "$MARK" ] && exit 0                       # held once already - let this stop through
    printf '%s' "$NOW" > "$MARK"
    gov_log "pr-watch-guard" "Stop: $REPO open=$OPEN, no live watcher for $SID - stop held once"
    emit_block "$MSG This stop was held once so the watcher gets armed before the session goes idle; the next stop passes."
    ;;
esac
exit 0
