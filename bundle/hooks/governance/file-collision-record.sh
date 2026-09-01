#!/usr/bin/env bash
# file-collision-record.sh -- PostToolUse companion to file-collision-guard.sh.
# Created: 2026-08-20
#
# The guard can only detect "this changed under me" if it knows what the file looked like
# when THIS session last left it. PreToolUse runs before the write, so it cannot know the
# result; this records the post-write hash.
#
# It updates three things:
#   * the shared claim  (~/.claude/logs/file-locks/<key>)  -- who touched it, when, resulting hash
#   * this session's own view (<session dir>/file-shas/<key>) -- what we believe is on disk
#   * a snapshot of the bytes we left behind (<session dir>/file-snaps/<key>)
#
# WHY THE SNAPSHOT (2026-08-22, Open-Problem #102)
# A hash can only say "this differs". It cannot say WHAT differs, so a stale-view block could
# tell a session it was about to overwrite something without ever showing it what. The
# snapshot is what file-collision-ack.sh diffs against, which is what makes the block's
# remedy real rather than a slogan: you cannot clear a block without being shown the change
# you were about to destroy. Capped at 1 MB via head -c -- a truncated snapshot still shows
# the head of the diff, and an uncapped one would put arbitrary file sizes in the session
# state dir.
#
# Silent and fail-open by design: a recording failure must never turn into a visible error
# after a write that already succeeded.

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || exit 0

gov_disabled && exit 0
[ "${GOV_COLLISION_GUARD:-1}" = "0" ] && exit 0

LOCK_DIR="${GOV_COLLISION_LOCK_DIR:-$HOME/.claude/logs/file-locks}"

PAYLOAD=$(gov_hook_input)
[ -z "$PAYLOAD" ] && exit 0

# Byte-for-byte identical framing to file-collision-guard.sh, and it MUST stay identical.
# These two hooks key their state off this path; if one of them alters it and the other does
# not, they hash different keys for the same file and each maintains its own claim and its own
# view -- the protection is then absent while both hooks appear to be running normally. That is
# not hypothetical: print() on Windows emits "\r\n", which briefly left the recorder's path
# carrying a trailing carriage return that the guard's did not.
_PARSED=$(printf '%s' "$PAYLOAD" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input") or {}
    tool = (d.get("tool_name") or "")
    path = (ti.get("file_path") or ti.get("notebook_path") or "")
    sys.stdout.buffer.write((tool + "\n" + path).encode("utf-8", "surrogateescape"))
except Exception:
    sys.stdout.buffer.write(b"\n")
' 2>/dev/null)
TOOL=${_PARSED%%$'\n'*}
TOOL=${TOOL%$'\r'}
FILE_PATH=${_PARSED#*$'\n'}
[ "$FILE_PATH" = "$_PARSED" ] && FILE_PATH=""
FILE_PATH=${FILE_PATH%$'\r'}
[ -z "$FILE_PATH" ] && exit 0

SID=$(gov_session_id)
[ -z "$SID" ] && exit 0

# Same scope rules as the guard -- recording a file the guard ignores is pure noise.
case "$FILE_PATH" in
  */.git/*|*/node_modules/*|*/logs/*|*/.claude/logs/*) exit 0 ;;
  /tmp/*|*/Temp/*|*/temp/*|*/scratchpad/*)             exit 0 ;;
esac
DIR=$(dirname -- "$FILE_PATH")
[ -d "$DIR" ] || exit 0
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || exit 0
[ -f "$FILE_PATH" ] || exit 0

gov_dry && exit 0

KEY=$(gov_path_key "$FILE_PATH")
[ -z "$KEY" ] && exit 0
SHA=$(sha256sum < "$FILE_PATH" 2>/dev/null | cut -d" " -f1)
[ -z "$SHA" ] && exit 0

mkdir -p "$LOCK_DIR" 2>/dev/null
# Read the claim BEFORE replacing it with our own. The check further down asks "did a tracked
# peer claim this file during our tool call?", and our own write destroys the answer -- read it
# back afterwards and the session id is always ours, so the check silently never fires. It did
# exactly that until a behavioural test caught it.
_P_SID=""; _P_TS=""
[ -f "$LOCK_DIR/$KEY" ] && IFS=$'\t' read -r _P_SID _P_TS _P_SHA < "$LOCK_DIR/$KEY" 2>/dev/null


STATE="$(gov_state_dir)"
MINE="$STATE/file-shas"
mkdir -p "$MINE" 2>/dev/null

# DO NOT claim to be synchronized when the bytes on disk may not be ours.
#
# This hook runs AFTER the tool wrote. If an editor, a shell command, or a peer session wrote in
# between, SHA describes THEIR bytes, and recording it as our view tells the guard we have seen
# something we have not. Our next whole-file Write then sails through the stale-view check and
# erases their work -- the exact lost update, produced by the mechanism meant to prevent it.
# (CODEX, PR #1.)
#
# A hook cannot fully close this: it never receives the bytes the tool intended to write, so it
# cannot tell "the tool's result" from "the tool's result, overwritten". What it CAN do is refuse
# to advance the view in the one case it can actually observe -- a TRACKED peer claiming the file
# between our PreToolUse and now. Leaving the view stale means our next write is blocked and the
# ack shows us the diff, which is the correct outcome.
#
# STATED LIMIT, so nobody mistakes this for coverage: an UNTRACKED writer (a shell command, an
# editor, a session with the guard disabled) leaves no claim, so this check cannot see it and the
# view still advances. That case remains open and is documented in Open-Problem #102.
_PRE_TS=""
_PRE_SHA=""
[ -f "$MINE/$KEY.pre" ] && IFS=$'\t' read -r _PRE_TS _PRE_SHA < "$MINE/$KEY.pre" 2>/dev/null
rm -f "$MINE/$KEY.pre" 2>/dev/null
_ADVANCE=1
if [ -n "$_PRE_TS" ] && [ -n "$_P_SID" ]; then
  _p_sid="$_P_SID"; _p_ts="$_P_TS"
  # A stale pre-marker (a block, or a crashed run) must not suppress a legitimate advance.
  _AGE=$(( $(date +%s) - _PRE_TS ))
  if [ "$_AGE" -ge 0 ] && [ "$_AGE" -le "${GOV_COLLISION_PRE_TTL_S:-300}" ] \
     && [ -n "$_p_sid" ] && [ "$_p_sid" != "$SID" ] && [ "${_p_ts:-0}" -ge "$_PRE_TS" ]; then
    _ADVANCE=0
    gov_log "file-collision-record" "NOT advancing view for $FILE_PATH - session $_p_sid claimed it during our tool call"
  fi
fi

if [ "$_ADVANCE" = "1" ]; then
  # Replace the claim by an atomic rename, never by `>`. The guard now serialises its own
  # read-decide-write inside a critical section, but THIS hook does not participate in it, and a
  # critical section is no protection against a writer that ignores it. `>` truncates first and
  # writes second, so a guard reading in that window sees an empty session id, concludes the file
  # is unclaimed, and can allow the very stale whole-file write the claim exists to stop. A
  # rename is atomic: a reader sees either the whole old claim or the whole new one, never a
  # half-written file, and no lock is needed for that. (CODEX, PR #1.)
  _LOCK_TMP="$LOCK_DIR/$KEY.tmp.$$"
  if printf '%s\t%s\t%s\n' "$SID" "$(date +%s)" "$SHA" > "$_LOCK_TMP" 2>/dev/null; then
    mv -f "$_LOCK_TMP" "$LOCK_DIR/$KEY" 2>/dev/null || rm -f "$_LOCK_TMP" 2>/dev/null
  else
    rm -f "$_LOCK_TMP" 2>/dev/null
  fi
else
  # We are not asserting ownership of bytes we could not verify. Leaving the peer's claim in
  # place also keeps the NEXT block truthful: if we took the claim here, the guard would report
  # "that write was yours" about a change the peer made -- the same over-claiming this whole
  # revision exists to remove, reintroduced from the other side.
  gov_log "file-collision-record" "not claiming $FILE_PATH - could not verify our own result"
fi

if [ "$_ADVANCE" = "1" ]; then
  printf '%s' "$SHA" > "$MINE/$KEY" 2>/dev/null
elif [ -n "$_PRE_SHA" ]; then
  # Declining to advance is only protective if a view REMAINS. With no view at all the
  # guard skips the stale-view check and the next whole-file write sails through -- so the
  # refusal has to leave the last state we actually observed, not leave nothing.
  printf '%s' "$_PRE_SHA" > "$MINE/$KEY" 2>/dev/null
else
  gov_log "file-collision-record" "declined to advance $FILE_PATH but have no pre-write sha to hold - view left as-is"
fi

# The bytes we are leaving behind, so a later block can show what it is protecting.
# head -c both caps the size and copies in one spawn; no stat call needed.
#
# The snapshot must describe the SAME state as the view, or the ack diffs against the wrong base
# and reports a change set nobody made. So when the advance was declined -- view held at the
# pre-write sha, current bytes possibly a peer's -- the snapshot is REMOVED rather than updated.
# The ack then takes its "NO SNAPSHOT AVAILABLE" branch, which says plainly that it cannot show
# the difference and tells the reader to open the file. Refusing to show a diff is honest;
# showing a confident diff computed from mismatched halves is not.
SNAPS="$STATE/file-snaps"
mkdir -p "$SNAPS" 2>/dev/null
if [ "$_ADVANCE" = "1" ]; then
  head -c "${GOV_COLLISION_SNAP_MAX:-1048576}" "$FILE_PATH" > "$SNAPS/$KEY" 2>/dev/null
else
  rm -f "$SNAPS/$KEY" 2>/dev/null
fi

# OUR stale ack ticket for this file is now meaningless: we have just written the file and
# re-synced our view, so whatever block it was issued for is resolved. Leaving it would let a
# much later ack clear a future block it was never raised for.
#
# Only ours -- the ticket name carries the session id. Another session blocked on this same
# file is still blocked, its ticket is still the only way out for it, and our write is exactly
# the change it needs to be shown. Removing it here would strand that session with a block and
# no remedy, which is the shape of the defect this whole revision exists to remove.
rm -f "${GOV_COLLISION_ACK_DIR:-$HOME/.claude/logs/file-acks}/$KEY.$SID" 2>/dev/null

# Claims are tiny but they are per-file-ever-touched, so they would grow without bound.
# Only sweep once the directory is actually large -- a find over a handful of files on every
# single write would be a silly price to pay for tidiness. Snapshots are the opposite: few
# files, but up to 1 MB each, so they are swept on the same trigger.
COUNT=$(ls -1 "$LOCK_DIR" 2>/dev/null | wc -l)
if [ "${COUNT:-0}" -gt 200 ]; then
  find "$LOCK_DIR" -type f -mtime +7 -delete 2>/dev/null
  find "$SNAPS" -type f -mtime +7 -delete 2>/dev/null
fi

exit 0
