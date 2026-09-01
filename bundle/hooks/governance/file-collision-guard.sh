#!/usr/bin/env bash
# file-collision-guard.sh -- stop two parallel sessions silently overwriting each other.
# Created: 2026-08-20 (owner: "צריך ליצור מנגנון מניעת דריסה/התנגשות")
# Revised: 2026-08-22 -- Open-Problem #102 (the false blocks were self-defeating).
#
# WHY THIS EXISTS
# The global CLAUDE.md already mandates file locking, an MD diff check and conflict
# avoidance. All three were prose -- a request to the model, not a constraint on it. A
# session that never read the rule, or read it and moved on, overwrote another session's
# work exactly as before, and the loss was silent: no error, no conflict marker, just an
# older version of the file winning.
#
# WHAT IT ACTUALLY CATCHES
# Two different dangers, deliberately separated, because blocking on anything less than
# real evidence turns into noise the owner will disable:
#
#   1. CONCURRENT -- another session wrote this same file seconds ago and is still active.
#      Both are working on it right now; whoever writes last wins and nobody is told.
#
#   2. STALE VIEW -- the file changed since the last write THIS session recorded, and we are
#      about to write again from our old picture of it. This is the classic lost update.
#
# WHAT IT CAN AND CANNOT SEE  (Open-Problem #102 -- read before changing any message below)
# It sees exactly one thing: writes made through the Edit/Write/MultiEdit/NotebookEdit
# tools, because those are the only ones it is hooked to. A change made by a shell command
# -- sed, python, a heredoc, git checkout -- is invisible to it. That has one hard consequence
# for the wording: when a file has changed, this guard does NOT know who changed it. It
# knows only who made the last write it recorded. Saying "another session has written it
# since" when the change may have been this session's own sed is a false statement about a
# real event, and it is what first made the guard untrustworthy. Every message below now
# states what was measured and nothing beyond it.
#
# THE ESCAPE-HATCH TRAP THIS REVISION CLOSES
# The old stale-view block told the session to "read the file again first" -- and a Read
# updated nothing, so the identical retry was refused identically. The only ways out were a
# full-file Write (the most destructive operation available, out of a guard whose whole
# purpose is preventing lost writes) or a shell edit (the one write path it cannot see). A
# guard whose printed remedy does not work trains the operator to reach for the action that
# disables it, and it makes the next REAL block less believable. Two changes close that:
#
#   * A SELF-CHANGE IS NO LONGER A HARD BLOCK FOR SURGICAL EDITS. When no other session has
#     ever claimed the file, there is no second writer whose work could be lost -- the change
#     is our own untracked shell write. An Edit is allowed with a warning and the record
#     auto-reconciles. All three reported false blocks were this case. A full-file Write
#     still blocks, because it really would drop that shell change.
#
#   * EVERY REMAINING BLOCK NAMES A REMEDY THAT WORKS: file-collision-ack.sh. It prints the
#     diff between what we last recorded and what is on disk now, then clears the block. It
#     is first-class and logged, so nobody has to reach for the shell to get unstuck, and
#     you cannot clear a block without being shown what you were about to overwrite.
#
# WHY NOT "let a Read update the record", which an earlier write-up recommends as the
# smallest fix: measured on this machine, one invocation of the recorder costs ~6.2 s --
# two python3 spawns at ~1.09 s each, ~0.93 s to source _common.sh, plus git and the hash.
# Hooking it to Read would put that on EVERY file read in every session. That is a worse
# defect than the one it fixes. The ack path costs nothing until a block actually happens.
# (Recorded as measurement, not opinion -- re-measure before revisiting.)
#
# WHAT IT DELIBERATELY DOES NOT DO
# It does not block the first touch of a file this session has never written. It only guards
# files inside a git repository -- scratch files, temp dirs and one-off scripts are none of
# its business.
#
# Fail-open everywhere: no payload, no path, no python, unreadable state -> exit 0. A guard
# that breaks editing is worse than the problem it prevents.
#
# Kill switch: GOV_COLLISION_GUARD=0 (or the global GOVERNANCE_HOOKS=0).
# Tuning: GOV_COLLISION_ACTIVE_S (default 180) -- how long another session counts as active.

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || exit 0

gov_disabled && exit 0
[ "${GOV_COLLISION_GUARD:-1}" = "0" ] && exit 0

ACTIVE_S="${GOV_COLLISION_ACTIVE_S:-180}"
LOCK_DIR="${GOV_COLLISION_LOCK_DIR:-$HOME/.claude/logs/file-locks}"
ACK_DIR="${GOV_COLLISION_ACK_DIR:-$HOME/.claude/logs/file-acks}"

PAYLOAD=$(gov_hook_input)
[ -z "$PAYLOAD" ] && exit 0

# TOOL NAME FIRST, PATH LAST -- and the path is everything after the first newline.
#
# The previous protocol put the path on line 1 and the tool on line 2, read with `sed -n 1p`
# and `sed -n 2p`. A POSIX filename may legally contain a NEWLINE, and such a path arrives here
# as several lines: line 1 is a truncated path and line 2 is the REST OF THE PATH, not the tool
# name. The guard then guards a path that does not exist while the recorder -- which never split
# on lines -- keys the whole thing, so the two hooks use different state and the protection is
# simply absent for that file. (CODEX, PR #1.)
#
# A tool name cannot contain a newline, so putting it first makes the framing unambiguous: the
# first line is the tool, everything after the first newline is the path, verbatim.
#
# sys.stdout.buffer, NOT print(). On Windows, Python's TEXT stdout translates "\n" into "\r\n",
# which put a carriage return on the end of the tool name -- so `Edit` never matched `Edit` and
# every surgical edit took the blocking branch. It also left the recorder's path carrying a
# trailing \r while the guard's did not, which meant the two hooks hashed DIFFERENT KEYS for the
# same file: separate claims, separate views, no protection at all. Writing bytes disables the
# translation. The ${VAR%$'\r'} strips below are belt and braces for any other producer.
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
[ -z "$SID" ] && exit 0          # cannot attribute anything without a session id

# ---- scope: only real project files -----------------------------------------------------
case "$FILE_PATH" in
  */.git/*|*/node_modules/*|*/logs/*|*/.claude/logs/*) exit 0 ;;
  /tmp/*|*/Temp/*|*/temp/*|*/scratchpad/*)             exit 0 ;;
esac
DIR=$(dirname -- "$FILE_PATH")
[ -d "$DIR" ] || DIR=$(dirname -- "$DIR")
[ -d "$DIR" ] || exit 0
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# ---- state paths ------------------------------------------------------------------------
mkdir -p "$LOCK_DIR" 2>/dev/null
KEY=$(gov_path_key "$FILE_PATH")
[ -z "$KEY" ] && exit 0
LOCK="$LOCK_DIR/$KEY"
MINE="$(gov_state_dir)/file-shas"; mkdir -p "$MINE" 2>/dev/null
MY_SHA_FILE="$MINE/$KEY"
SNAP_FILE="$(gov_state_dir)/file-snaps/$KEY"

# The ack ticket is keyed by file AND session. One ticket per file would be a shared
# capability: two sessions blocked on the same file would overwrite each other's ticket, and
# the first session's printed command would then consume the SECOND session's ticket --
# clearing the wrong block and leaving the first session refused on an identical retry. That
# is the advertised remedy failing in exactly the multi-session case the guard exists for.
TICKET="$ACK_DIR/$KEY.$SID"
# THE PRINTED COMMAND CARRIES A TICKET ID, NOT A PATH -- a correctness fix, not only a
# security one.
#
# Security: this command is presented as something to RUN, and a repository may legally hold a
# filename containing $(...), backticks or a quote. Interpolating that into a double-quoted
# string turned a stale-view block on a crafted path into command execution the moment the
# remedy was copied (CODEX, PR #1). printf %q fixed that.
#
# Correctness: %q alone was still not enough, found by running the printed command for real on
# a Windows path. A path like C:\dir\x.md %q-escapes to C:\\dir\\x.md, and whether that
# survives depends on how many layers of shell it crosses on the way. One layer too many and
# the backslashes are eaten, the path arrives as C:dirx.md, gov_path_key hashes something else,
# and the remedy answers 'nothing to acknowledge'. A remedy that fails on this project's own
# primary platform is the #102 defect all over again, one level down.
#
# The ticket id is 32 hex characters plus a session id already sanitised to [A-Za-z0-9._-].
# There is nothing in it for a shell to interpret and nothing for a shell to eat. The path form
# still works and is offered to humans, %q-quoted.
TICKET_ID="$KEY.$SID"
ACK_CMD="bash $(printf '%q' "$SCRIPT_DIR/file-collision-ack.sh") --ticket $TICKET_ID"
ACK_CMD_PATH="bash $(printf '%q' "$SCRIPT_DIR/file-collision-ack.sh") $(printf '%q' "$FILE_PATH") $(printf '%q' "$SID")"

# Leave the ticket the ack script consumes. Writing it is the ONLY thing that lets a block be
# cleared, so it is written on the block path and nowhere else: an ack cannot be issued
# pre-emptively, and cannot clear a block that was never raised.
_leave_ack_ticket() {
  gov_dry && return 0
  mkdir -p "$ACK_DIR" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$SID" "$now" "$MY_SHA_FILE" "$SNAP_FILE" "$cur_sha" "$1" "$FILE_PATH" > "$TICKET" 2>/dev/null
}

# ---- the claim must be acquired atomically ----------------------------------------------
# Reading the claim, deciding, and then writing it is a read-modify-write. Two sessions
# first touching the same file -- or both finding an expired claim -- can each finish the
# read before either reaches the write. Both then return 0 and both edits proceed, which is
# precisely the silent lost update this guard exists to prevent.
#
# `mkdir` is the atomic primitive available to a shell script: it succeeds for exactly one
# caller. Everything from the claim read to the claim write happens inside it, so the two
# sessions serialise and the second one sees the first one's claim.
#
# Two deliberate choices:
#   * A critical section left behind by a killed hook must not wedge editing forever, so one
#     older than CS_STALE_S is taken over rather than waited on.
#   * If the section cannot be entered at all, the hook proceeds WITHOUT it and logs that it
#     did. Degrading to the previous (racy) behaviour is bad; refusing every edit because a
#     lock directory is wedged is worse.
# A claim is replaced by an atomic rename, never by `>`. `>` truncates first and writes second,
# so a concurrent guard reading in that window sees an empty session id, concludes the file is
# unclaimed, and can allow the very write this claim exists to stop. (CODEX, PR #1.)
#
# It also leaves a PRE-MARKER: the moment this hook ran, which the PostToolUse recorder uses to
# tell whether a tracked peer wrote during our tool call. See the recorder for why that matters.
_write_claim() {
  local tmp="$LOCK.tmp.$$"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$LOCK" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  # ts AND the sha we saw BEFORE the tool ran. The sha is what makes a declined advance
  # useful: it is genuinely the last state this session observed, so writing it as our view
  # leaves a view that is STALE rather than MISSING -- and a missing view disables the
  # stale-view check entirely, which would turn 'we refuse to claim synchronisation' into
  # 'we impose no check at all', the opposite of the intent.
  printf '%s\t%s' "$2" "$3" > "$MY_SHA_FILE.pre" 2>/dev/null
}

CS="$LOCK.cs"
CS_HELD=0
CS_STALE_S="${GOV_COLLISION_CS_STALE_S:-30}"
_cs_exit() { [ "$CS_HELD" = "1" ] && rmdir "$CS" 2>/dev/null; CS_HELD=0; }
_cs_enter() {
  gov_dry && return 0
  local i
  for i in 1 2 3 4 5; do
    if mkdir "$CS" 2>/dev/null; then
      CS_HELD=1
      trap _cs_exit EXIT
      return 0
    fi
    # Held by someone. If it is old enough to be a corpse, clear it and retry immediately.
    # The age test is written so that a FAILURE to determine the age leaves the section
    # alone: an unreadable mtime must not read as "stale", or a working section would be
    # torn down on every contended write and the serialisation would be theatre.
    local cs_mtime
    cs_mtime=$(stat -c %Y "$CS" 2>/dev/null)
    if [ -n "$cs_mtime" ] && [ "$(( $(date +%s) - cs_mtime ))" -gt "$CS_STALE_S" ]; then
      # Do NOT rmdir it. Two contenders can both see the same stale directory; the first
      # removes it and immediately acquires a fresh one, and the second's rmdir then deletes
      # the FIRST's live section -- both callers proceed believing they hold it, which is the
      # dual-claim race this section exists to prevent, reintroduced during its own recovery.
      # Renaming is the ownership-preserving move: exactly one contender's mv can succeed,
      # because after it the source no longer exists. (CODEX, PR #1.)
      if mv "$CS" "$CS.dead.$$" 2>/dev/null; then
        gov_log "file-collision-guard" "reclaimed a stale critical section for $FILE_PATH"
        rm -rf "$CS.dead.$$" 2>/dev/null
        continue
      fi
      # Someone else won the takeover. Fall through and wait like any other contender.
    fi
    sleep 0.2
  done
  gov_log "file-collision-guard" "could not enter the critical section for $FILE_PATH - proceeding unserialised"
  return 1
}

now=$(date +%s)
cur_sha=""
[ -f "$FILE_PATH" ] && cur_sha=$(sha256sum < "$FILE_PATH" 2>/dev/null | cut -d" " -f1)

_cs_enter

# ---- danger 1: another session is active on this exact file -----------------------------
if [ -f "$LOCK" ]; then
  IFS=$'\t' read -r l_sid l_ts l_sha < "$LOCK" 2>/dev/null
  if [ -n "$l_sid" ] && [ "$l_sid" != "$SID" ]; then
    age=$(( now - ${l_ts:-0} ))
    [ "$age" -lt 0 ] && age=0
    if [ "$age" -lt "$ACTIVE_S" ]; then
      gov_log "file-collision-guard" "BLOCK concurrent $FILE_PATH (held by $l_sid, ${age}s ago)"
      # The old text here offered "re-read and make a surgical Edit instead" as a way out. It
      # is not one: this branch never consults our view of the file, so a re-read changes
      # nothing and the retry is refused identically -- the same broken-remedy bug as the
      # stale-view message (#102). Nor does the ack path apply: the ack clears a stale view,
      # and the reason for this block is the other session, not our picture of the file.
      cat >&2 <<EOF
BLOCKED -- another Claude Code session is editing this file right now.

  file:    $FILE_PATH
  session: $l_sid wrote it ${age}s ago (still counted active for ${ACTIVE_S}s)

Two sessions writing the same file means whoever saves last wins and the other's work
disappears with no error.

Re-reading does NOT clear this block, and neither does file-collision-ack.sh: the reason is
the other session, not your picture of the file. What actually works:
  * work on a different file and come back to this one later
  * wait for the claim to lapse (${ACTIVE_S}s after that session's last write)
  * if you know that session is finished, tell the user and let them decide

Never work around this by writing to a copy and renaming it over the original.
EOF
      exit 2
    fi
  fi
fi

# A file that does not exist yet cannot be OVERWRITTEN -- but it can still be created twice.
# This check used to sit above danger 1, which meant absence was treated as automatically safe:
# session A finished PreToolUse and left its claim before its Write had created the file, B then
# arrived while the path was still absent, took this shortcut, overwrote A's claim and was also
# allowed. Both Writes ran and the last silently replaced the other -- the exact lost update,
# reached through the one branch that never consulted a claim. CODEX reproduced it (PR #1).
# It now runs AFTER the concurrent-claim check, so a live claim is honoured either way.
if [ -z "$cur_sha" ]; then
  gov_dry || _write_claim "$SID" "$now" ""
  _cs_exit
  exit 0
fi

# ---- danger 2: the file changed since the last write we recorded ------------------------
if [ -f "$MY_SHA_FILE" ]; then
  my_sha=$(cat "$MY_SHA_FILE" 2>/dev/null)
  if [ -n "$my_sha" ] && [ "$my_sha" != "$cur_sha" ]; then

    # The shared claim names the last writer this guard SAW. That is the only writer it can
    # name, and it is not necessarily the one who made the change just detected.
    last_writer=""
    [ -f "$LOCK" ] && last_writer=$(cut -f1 "$LOCK" 2>/dev/null)

    if [ -n "$last_writer" ] && [ "$last_writer" != "$SID" ]; then
      # Evidence of a second writer. Hard block for every tool -- this is exactly the lost
      # update the guard exists to prevent.
      gov_log "file-collision-guard" "BLOCK stale-view $FILE_PATH (last recorded write by $last_writer)"
      _leave_ack_ticket "stale-view-other:$last_writer"
      cat >&2 <<EOF
BLOCKED -- this file changed on disk since you last wrote it.

  file:                $FILE_PATH
  last recorded write: session $last_writer
  your session:        $SID

Your picture of this file is older than what is on disk, so writing now would drop whatever
changed in between.

To clear this block, run:

  $ACK_CMD

It prints exactly what changed since your last write and then clears the block, so you
cannot get past this without seeing what you were about to overwrite. Redo your change on
top of what it shows you. If the two changes genuinely conflict, stop and ask the user; do
not guess which version to keep.

What this guard actually measured: $last_writer made the last write it recorded. It does NOT know
who made the change since -- it only sees Edit/Write, so that change could equally have been a
shell command (sed, python, a heredoc) from any session, including your own.
EOF
      exit 2
    fi

    # Nobody else has ever claimed this file, so there is no second writer whose work could
    # be lost. The change is almost certainly an untracked shell write from this very
    # session -- the case that produced three false blocks in one day (#102).
    # Only the surgical tools are downgraded to a warning, named explicitly. Anything else --
    # including an unrecognised tool, or a tool_name we failed to parse -- is treated as a
    # whole-file write and blocks. The permissive branch must never be the default: an unknown
    # tool is exactly the case where we do not know how much of the file is about to be
    # replaced. This matches file-collision-record.sh, which also treats an unknown tool as a
    # write.
    #
    # NotebookEdit is NOT on this list, and the omission is deliberate (CODEX, PR #1). The whole
    # justification for downgrading is that old_string must still match, so a moved or changed
    # region fails the edit on its own. NotebookEdit has no such precondition -- it replaces a
    # cell by cell_id -- so an external change to that cell would be silently discarded by a
    # stale replacement. The safety argument does not cover it, so neither does the allow-list.
    case "$TOOL" in
      Edit|MultiEdit)
        # Surgical, and old_string is its own protection. Warn, re-sync the record, and get
        # out of the way. Blocking here has no second writer's work to save and only teaches
        # the shell-shaped escape.
        if ! gov_dry; then
          printf '%s' "$cur_sha" > "$MY_SHA_FILE" 2>/dev/null
          # Re-snapshot too. The view and the snapshot must describe the same bytes: if only
          # the hash moved, a later block would diff against a version older than the one it
          # claims, and report a change set that is not the one it measured.
          mkdir -p "$(dirname "$SNAP_FILE")" 2>/dev/null
          head -c "${GOV_COLLISION_SNAP_MAX:-1048576}" "$FILE_PATH" > "$SNAP_FILE" 2>/dev/null
        fi
        gov_log "file-collision-guard" "WARN stale-view-self $FILE_PATH ($TOOL allowed, record re-synced)"
        MSG="NOTE from file-collision-guard: $FILE_PATH changed since the last write this guard recorded, and that write was yours. No other session has ever claimed this file, so the change was most likely a shell command from this session (sed/python/heredoc) -- a write path this guard cannot see. The $TOOL is allowed: it is surgical, and its old_string fails on its own if the region moved. The record has been re-synced to what is on disk now. If you did NOT make that change yourself, stop and re-read the file before continuing."
        printf '%s\n' "$MSG" >&2
        printf '%s' "$MSG" | python3 -c '
import sys, json
print(json.dumps({
  "systemMessage": "[collision-guard] stale view re-synced to disk - see note",
  "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": sys.stdin.read()}
}))
' 2>/dev/null
        exit 0
        ;;
      *)
        # A full-file replace really would drop that shell change, so the block stands. What
        # changed from before is that the remedy it prints now works.
        gov_log "file-collision-guard" "BLOCK stale-view-self $FILE_PATH ($TOOL, no other claimant)"
        _leave_ack_ticket "stale-view-self"
        cat >&2 <<EOF
BLOCKED -- this file changed since the last write recorded here, and that write was yours.

  file: $FILE_PATH

No other session has ever claimed this file. This guard only sees Edit/Write, so the change
was almost certainly made by a shell command from this session (sed, python, a heredoc). A
full-file Write from your current picture would silently drop it.

Two ways forward, both of which work:
  * make the change with Edit instead -- it is surgical, it is allowed here immediately, and
    its old_string check fails on its own if the region moved
  * or run this, which shows you what changed and then clears the block:

      $ACK_CMD
EOF
        exit 2
        ;;
    esac
  fi
fi

# ---- allowed: claim the file so other sessions can see we are on it ---------------------
gov_dry || _write_claim "$SID" "$now" "$cur_sha"
exit 0
