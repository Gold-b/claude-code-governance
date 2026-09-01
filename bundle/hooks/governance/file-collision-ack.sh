#!/usr/bin/env bash
# file-collision-ack.sh -- the way out of a collision block, for Open-Problem #102.
# Created: 2026-08-22
#
# WHY THIS EXISTS
# file-collision-guard.sh used to print "read the file again first" and a Read updated
# nothing, so the identical retry was refused identically. That left exactly two escapes: a
# full-file Write (the most destructive operation there is, out of a guard built to prevent
# lost writes) or an edit through the shell -- the one write path the guard cannot see. Both
# are worse than the hazard, and every false block taught the operator to reach for one of
# them. A guard whose printed remedy does not work is worse than one that prints nothing.
#
# WHAT IT DOES
# Shows exactly what changed since the last write the guard recorded, then clears the block
# for that one file. Seeing the change is not optional -- the diff is printed before the
# record is updated, so no one can get past a block without being shown what they were about
# to overwrite. That is the whole point: this is a reconcile path, not a bypass.
#
# WHAT IT CANNOT DO
#   * It cannot clear a block that was never raised. The guard writes a ticket only on the
#     block path; with no ticket this script refuses. There is no pre-emptive ack.
#   * It cannot clear a CONCURRENT block (another session writing the same file seconds
#     ago). That block is about the other session, not about our picture of the file, and
#     no amount of reconciling makes it safe. The guard says so in its own message.
#   * It does not merge anything. It tells you what changed; redoing the change on top is
#     yours to do.
#
# ONE TICKET PER BLOCKED SESSION, NOT PER FILE
# Tickets are keyed by file AND session id. Sharing one ticket per file would make it a shared
# capability: if two sessions are blocked on the same file, the second block would overwrite
# the first session's ticket, and the first session running its own printed command would
# consume the SECOND session's ticket -- clearing the wrong block and leaving the first
# session refused on an identical retry. The remedy would fail precisely in the multi-session
# collision the guard exists for. The session id is therefore part of the ticket name, and the
# guard prints it in the command it tells you to run.
#
# Usage:
#   file-collision-ack.sh --ticket <id>     THE FORM THE GUARD PRINTS -- copy it as-is. The id
#                                           is a hex key, a dot, and the session id, so there
#                                           is nothing in it for a shell to interpret and
#                                           nothing for a shell to eat.
#   file-collision-ack.sh <file>            by path, for humans (works when only one session
#                                           is blocked on that file)
#   file-collision-ack.sh <file> <session>  by path, naming the session explicitly
#   file-collision-ack.sh --list            show tickets waiting to be acknowledged
#
# WHY THE PRINTED FORM STOPPED USING A PATH (2026-08-22, found by running it for real)
# The guard used to print a %q-quoted path. %q is the correct answer to the SECURITY question --
# a filename may legally contain $(...) or a backtick, and interpolating that into a command
# presented as runnable is command execution. It is not sufficient for the CORRECTNESS one. On
# Windows a path is full of backslashes; %q escapes each one, and whether the escaping survives
# depends on how many layers of shell the command crosses before it arrives. One layer too many
# and every backslash is eaten: `C:\dir\x.md` arrives as `C:dirx.md`, gov_path_key hashes a
# different string, and this script answers "nothing to acknowledge" -- a remedy that fails on
# the project's primary platform, which is exactly the class of defect it was written to remove.
# Reproduced live before this change. The ticket id has no separators to lose.
#
# Tuning: GOV_COLLISION_ACK_TTL_S (default 86400) -- how long a ticket stays valid.
#         GOV_COLLISION_ACK_DIFF_LINES (default 200) -- cap on printed diff lines.

set +e

# THIS SCRIPT MUST NEVER READ STDIN, and must not inherit one either.
# Unlike the guard and the recorder, it is not a hook: it is run by hand (or by an agent
# through a Bash tool call), so its stdin is whatever the caller happened to have open.
# `_common.sh`'s gov_hook_input reads stdin to EOF whenever stdin is not a tty -- correct for
# a hook, fatal here: piped or held-open stdin makes this script block forever. Reproduced
# (`sleep 30 | file-collision-ack.sh --list` never returned), which would be an especially
# poor failure for the one command whose entire job is to get a blocked session unstuck.
exec 0</dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { echo "file-collision-ack: cannot load _common.sh" >&2; exit 1; }

ACK_DIR="${GOV_COLLISION_ACK_DIR:-$HOME/.claude/logs/file-acks}"
TTL="${GOV_COLLISION_ACK_TTL_S:-86400}"
DIFF_LINES="${GOV_COLLISION_ACK_DIFF_LINES:-200}"

if [ "$1" = "--list" ] || [ "$1" = "-l" ]; then
  if [ ! -d "$ACK_DIR" ] || [ -z "$(ls -A "$ACK_DIR" 2>/dev/null)" ]; then
    echo "No collision blocks are waiting to be acknowledged."
    exit 0
  fi
  echo "Collision blocks waiting to be acknowledged:"
  now=$(date +%s)
  for t in "$ACK_DIR"/*; do
    [ -f "$t" ] || continue
    IFS=$'\t' read -r a_sid a_ts a_view a_snap a_sha a_reason a_path < "$t"
    printf '  %s\n     file: %s\n     raised %ss ago by session %s   (%s)\n' \
      "$(basename "$t")" "${a_path:-<unknown - older ticket>}" "$(( now - ${a_ts:-0} ))" "${a_sid:-?}" "${a_reason:-?}"
    printf '     clear with: bash %s --ticket %s\n' "$(printf '%q' "$SCRIPT_DIR/file-collision-ack.sh")" "$(basename "$t")"
  done
  echo
  echo "Prefer the --ticket form shown above: a path can be altered crossing a shell, an id cannot."
  exit 0
fi

TICKET=""
FILE_PATH=""
WANT_SID=""

if [ "$1" = "--ticket" ] || [ "$1" = "-t" ]; then
  # The id is opaque and self-describing: the ticket carries the file path, so nothing has to be
  # re-derived from an argument that may have been altered crossing a shell.
  _id="$2"
  case "$_id" in
    ""|*/*|*[!A-Za-z0-9._-]*)
      echo "file-collision-ack: --ticket needs the id the block printed (hex key, a dot, the session id)." >&2
      exit 1 ;;
  esac
  TICKET="$ACK_DIR/$_id"
  if [ ! -f "$TICKET" ]; then
    echo "file-collision-ack: no block is recorded under ticket '$_id'." >&2
    echo "It may already have been acknowledged, or superseded by a later write of the same file." >&2
    echo "  bash \"$SCRIPT_DIR/file-collision-ack.sh\" --list" >&2
    exit 1
  fi
else
  FILE_PATH="$1"
  WANT_SID="$2"
  if [ -z "$FILE_PATH" ]; then
    echo "usage: file-collision-ack.sh --ticket <id>   |   <file> [session]   |   --list" >&2
    exit 1
  fi

  KEY=$(gov_path_key "$FILE_PATH")
  [ -z "$KEY" ] && { echo "file-collision-ack: cannot derive a key for $FILE_PATH" >&2; exit 1; }

  # With a session id, take exactly that ticket. Without one, take the only ticket if there is
  # only one -- and REFUSE if there are several, because guessing would clear another session's
  # block and leave the caller still refused, the failure per-session keying exists to prevent.
  if [ -n "$WANT_SID" ]; then
    TICKET="$ACK_DIR/$KEY.$WANT_SID"
    [ -f "$TICKET" ] || TICKET=""
  else
    _n=0
    for t in "$ACK_DIR/$KEY".*; do
      [ -f "$t" ] || continue
      _n=$((_n+1)); TICKET="$t"
    done
    if [ "$_n" -gt 1 ]; then
      echo "More than one session is blocked on this file, so I will not guess which block to clear:" >&2
      echo >&2
      for t in "$ACK_DIR/$KEY".*; do
        [ -f "$t" ] || continue
        IFS=$'\t' read -r a_sid a_ts a_view a_snap a_sha a_reason a_path < "$t"
        echo "  session $a_sid  ($a_reason)" >&2
        echo "      bash $(printf '%q' "$SCRIPT_DIR/file-collision-ack.sh") --ticket $(basename "$t")" >&2
      done
      echo >&2
      echo "Run the one the guard printed for YOUR session. Clearing another session's block" >&2
      echo "would leave you refused and unblock work that has not been reviewed." >&2
      exit 1
    fi
  fi

  if [ -z "$TICKET" ] || [ ! -f "$TICKET" ]; then
    cat >&2 <<EOF
Nothing to acknowledge for:
  $FILE_PATH${WANT_SID:+
  (session $WANT_SID)}

This script only clears a block the guard actually raised, and no such block is recorded for
this file. If you were blocked just now, prefer the --ticket form the block printed: a path
retyped or copied through a shell can arrive altered, and then it hashes to a different key.

  bash "$SCRIPT_DIR/file-collision-ack.sh" --list

If you were NOT blocked, nothing is needed -- just make your edit.
EOF
    exit 1
  fi
fi
IFS=$'\t' read -r A_SID A_TS A_VIEW A_SNAP A_SHA A_REASON A_PATH < "$TICKET"
# In --ticket mode the path comes from the ticket -- the copy that was never retyped,
# re-quoted, or passed through a shell that could eat its separators.
[ -z "$FILE_PATH" ] && FILE_PATH="$A_PATH"
[ -z "$FILE_PATH" ] && { echo "file-collision-ack: this ticket carries no file path (written by an older guard); use the <file> form." >&2; exit 1; }
now=$(date +%s)
age=$(( now - ${A_TS:-0} )); [ "$age" -lt 0 ] && age=0
if [ "$age" -gt "$TTL" ]; then
  rm -f "$TICKET" 2>/dev/null
  echo "file-collision-ack: that block is ${age}s old (older than the ${TTL}s ticket lifetime) and has been discarded." >&2
  echo "Re-try your edit; if the guard still blocks, acknowledge the fresh block." >&2
  exit 1
fi

[ -f "$FILE_PATH" ] || { echo "file-collision-ack: $FILE_PATH does not exist now." >&2; exit 1; }
CUR_SHA=$(sha256sum < "$FILE_PATH" 2>/dev/null | cut -d" " -f1)
[ -z "$CUR_SHA" ] && { echo "file-collision-ack: cannot hash $FILE_PATH" >&2; exit 1; }

echo "=============================================================================="
echo " Reconciling: $FILE_PATH"
echo " Block reason: ${A_REASON:-unknown}   (raised ${age}s ago by session ${A_SID:-?})"
echo "=============================================================================="
echo

# The snapshot is what the file looked like the last time this session wrote it. Diffing
# against it answers the only question that matters here: what am I about to overwrite?
if [ -f "$A_SNAP" ]; then
  echo "--- what changed since your last recorded write (- yours, + on disk now) ---"
  diff -u "$A_SNAP" "$FILE_PATH" 2>/dev/null | tail -n +3 | head -n "$DIFF_LINES"
  produced=$(diff -q "$A_SNAP" "$FILE_PATH" >/dev/null 2>&1; echo $?)
  if [ "$produced" = "0" ]; then
    echo "(no textual difference -- the change may have been to file mode, or the content was"
    echo " changed and changed back)"
  fi
  total=$(diff -u "$A_SNAP" "$FILE_PATH" 2>/dev/null | wc -l)
  if [ "${total:-0}" -gt "$(( DIFF_LINES + 3 ))" ]; then
    echo
    echo "... diff truncated at $DIFF_LINES lines. Full comparison:"
    # This line is a command too, so it gets the same %q treatment as the ack command.
    # Missing it left the crafted-filename execution path reachable on any diff over the
    # cap -- a fix applied to one printed command and not its neighbour. (CODEX, PR #1.)
    echo "    diff -u $(printf '%q' "$A_SNAP") $(printf '%q' "$FILE_PATH")"
  fi
else
  # No snapshot: either the write predates snapshotting, or the file was too large. Say so
  # rather than implying the file is unchanged -- a silent empty diff here would be exactly
  # the "reports something it did not measure" failure this whole entry is about.
  echo "--- NO SNAPSHOT AVAILABLE for the version you last wrote ---"
  echo "This guard could not keep a copy of your last write (too large, or the write predates"
  echo "snapshotting), so it cannot show you the difference. Do NOT assume nothing changed."
  DIR=$(dirname -- "$FILE_PATH")
  if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo
    echo "Uncommitted changes to this file, for whatever they are worth:"
    git -C "$DIR" --no-pager diff -- "$FILE_PATH" 2>/dev/null | head -n "$DIFF_LINES"
    echo "(if that is empty, the change is committed -- check: git -C \"$DIR\" log -2 -- \"$FILE_PATH\")"
  fi
  echo
  echo "READ THE FILE before you continue. You are about to write over a change you have not seen."
fi

echo
# Test the WRITE, not the file. `-s` only asks whether the file is non-empty -- and if the view
# file is unwritable the redirection fails while its old contents stay exactly where they are,
# so `-s` passes, the ticket gets consumed, and this command reports a cleared block over a
# stale hash that will refuse the very next edit. The consequence is the worst one available
# here: a remedy that claims to have worked and did not. (CODEX, PR #1.)
if ! printf '%s' "$CUR_SHA" > "$A_VIEW" 2>/dev/null; then
  echo "file-collision-ack: could not write the guard's record at $A_VIEW -- the block is STILL" >&2
  echo "in place and the ticket has been left alone so you can retry. Check that the path exists" >&2
  echo "and is writable. Tell the user rather than editing through the shell." >&2
  exit 1
fi
# Belt and braces: prove the bytes we intended are the bytes on disk before consuming the ticket.
if [ "$(cat "$A_VIEW" 2>/dev/null)" != "$CUR_SHA" ]; then
  echo "file-collision-ack: the record at $A_VIEW does not read back as written -- the block is" >&2
  echo "STILL in place and the ticket has been kept. This is a bug; report it." >&2
  exit 1
fi
rm -f "$TICKET" 2>/dev/null
gov_log "file-collision-ack" "ACK $FILE_PATH (reason=${A_REASON:-unknown}, was=${A_SHA:0:12}, now=${CUR_SHA:0:12})"

echo "Block cleared for this file. Redo your change on top of what is shown above."
echo "(recorded: the guard now believes this file is at ${CUR_SHA:0:12}...)"
exit 0
