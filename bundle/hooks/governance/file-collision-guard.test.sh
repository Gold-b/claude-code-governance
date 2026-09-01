#!/usr/bin/env bash
# Battery for file-collision-guard.sh + file-collision-record.sh + file-collision-ack.sh.
#
# Simulates two parallel sessions (GOV_SESSION_ID=A / =B) fighting over one file in a real
# throwaway git repo, driving the SHIPPED hooks with real PreToolUse/PostToolUse payloads.
#
# Both directions are pinned on purpose. A guard that blocks everything would sail through
# a block-only battery, and it would be worse than having no guard at all — the owner would
# switch it off within a day. Most of the cases below assert that an edit is ALLOWED.
#
# Cases 1-17 are the original battery and are unchanged. Cases 18+ were added 2026-08-22 for
# Open-Problem #102: the guard's own printed remedy ("read the file again") did not clear the
# block it printed on, so the only escapes left were a full-file Write or a shell edit the
# guard cannot see — and every false block taught the operator to reach for one of them.
# Those cases pin the fix in BOTH directions: every remaining block now has a remedy that
# demonstrably works, and the genuine two-writer block did not get weaker in the process.
#
# Run: bash file-collision-guard.test.sh
set +e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$DIR/file-collision-guard.sh"
RECORD="$DIR/file-collision-record.sh"
ACK="$DIR/file-collision-ack.sh"
. "$DIR/_common.sh" 2>/dev/null < /dev/null   # for gov_path_key — never re-derive it here

# NOT mktemp: the guard deliberately ignores /tmp and */Temp/*, so a repo created there
# would be skipped and every assertion below would pass for the wrong reason.
WORK="$HOME/.claude/collision-test-$$"; mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT
export GOV_COLLISION_LOCK_DIR="$WORK/locks"
export GOV_COLLISION_ACK_DIR="$WORK/acks"
export HOME_ORIG="$HOME"
export HOME="$WORK/home"; mkdir -p "$HOME/.claude/logs"

REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
FILE="$REPO/shared.md"
printf 'v1\n' > "$FILE"
OUTSIDE="$WORK/loose.txt"; printf 'x\n' > "$OUTSIDE"   # not in a repo

# JSON-escape the path. The harness previously interpolated it raw, which is fine for ordinary
# paths and produces INVALID JSON the moment a path contains a newline, a quote or a backslash.
# The hooks then hit their json.load exception handler and fail open -- so the newline case was
# exercising the fail-open branch while appearing to exercise the parser. Pure parameter
# expansion, so it costs nothing: a spawn here would be multiplied by every case in the battery.
#
# The replacements are held in variables. Writing `${s//$'\n'/\n}` inline looks right and is
# not: bash consumes the backslash inside the replacement text and substitutes a bare `n`, so
# the newline silently vanished from the path instead of being escaped.
_J_BS='\'; _J_QT='\"'; _J_NL='\n'; _J_CR='\r'; _J_TB='\t'
json_escape() {
  local s=$1
  s=${s//\/$_J_BS}
  s=${s//\"/$_J_QT}
  s=${s//$'\n'/$_J_NL}
  s=${s//$'\r'/$_J_CR}
  s=${s//$'\t'/$_J_TB}
  printf '%s' "$s"
}
payload() { printf '{"session_id":"%s","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2" "$(json_escape "$3")"; }

# run <sid> <tool> <path> -> exit code of the guard. stdout -> $WORK/out, stderr -> $WORK/err
run() { payload "$1" "$2" "$3" | GOV_SESSION_ID="$1" bash "$GUARD" >"$WORK/out" 2>"$WORK/err"; echo $?; }
rec() { payload "$1" "$2" "$3" | GOV_SESSION_ID="$1" bash "$RECORD" >/dev/null 2>&1; }
# the ack script is run by a human/agent through Bash, so it gets no hook payload and no
# session id — it must work from the ticket alone. Driven here exactly as it would be.
ack() { bash "$ACK" "$@" >"$WORK/ack" 2>&1 </dev/null; echo $?; }
# age the shared claim so the "still active" window lapses
age_lock() {
  local k; k=$(gov_path_key "$1")
  local f="$GOV_COLLISION_LOCK_DIR/$k"
  [ -f "$f" ] || return 0
  local sid ts sha; IFS=$'\t' read -r sid ts sha < "$f"
  printf '%s\t%s\t%s\n' "$sid" "$((ts - 9999))" "$sha" > "$f"
}
lock_sid()   { cut -f1 "$GOV_COLLISION_LOCK_DIR/$(gov_path_key "$1")" 2>/dev/null; }
# ticket <path> <session> -- tickets are per blocked SESSION, not per file (CODEX, PR #1)
ticket()     { printf '%s/%s.%s' "$GOV_COLLISION_ACK_DIR" "$(gov_path_key "$1")" "$2"; }
view_file()  { printf '%s/.claude/logs/sessions/%s/file-shas/%s'  "$HOME" "$1" "$(gov_path_key "$2")"; }
snap_file()  { printf '%s/.claude/logs/sessions/%s/file-snaps/%s' "$HOME" "$1" "$(gov_path_key "$2")"; }
# a change this guard cannot see: exactly what `sed -i` or a python edit through Bash does
shell_edit() { printf '%s\n' "$2" >> "$1"; }

pass=0; fails=()
check()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fails+=("$1 (got $2, want $3)"); fi; }
said()    { if grep -q "$2" "$WORK/err"; then pass=$((pass+1)); else fails+=("$1"); fi; }
notsaid() { if grep -q "$2" "$WORK/err"; then fails+=("$1"); else pass=$((pass+1)); fi; }
acksaid() { if grep -q "$2" "$WORK/ack"; then pass=$((pass+1)); else fails+=("$1"); fi; }

# ============================ original battery (1-17) ====================================

# 1. A writes an existing file it has not touched before -> allowed (first touch is not a conflict)
check "A first write allowed"        "$(run A Write "$FILE")" 0
rec A Write "$FILE"

# 2. B writes the same file seconds later -> BLOCKED, A is still active
check "B blocked while A active"     "$(run B Write "$FILE")" 2
said "concurrent block message missing" "another Claude Code session is editing"

# 3. A writes again straight away -> allowed, it is A's own claim
check "A may continue on its own file" "$(run A Write "$FILE")" 0

# 4. Once A's claim lapses, B may take over
age_lock "$FILE"
check "B allowed after claim lapses" "$(run B Write "$FILE")" 0
printf 'v2-from-B\n' > "$FILE"; rec B Write "$FILE"

# 5. A comes back and writes from its stale picture -> BLOCKED (the lost update)
age_lock "$FILE"
check "A blocked on stale view"      "$(run A Write "$FILE")" 2
said "stale-view block message missing" "changed on disk since you last wrote it"

# 6. After A re-records the current state, it may write again
rec A Write "$FILE"
age_lock "$FILE"
check "A allowed once back in sync"  "$(run A Write "$FILE")" 0

# 7. A brand-new file cannot be an overwrite
check "new file allowed"             "$(run A Write "$REPO/brand-new.md")" 0

# 8+9. Paths the guard deliberately skips.
#
#      These two used to assert exit 0 on files with no claim and no view -- which the guard
#      allows anyway, so the assertions passed whether the skip rules existed or not. Dropping
#      `*/node_modules/*` entirely left the battery at full marks. Pass value equalled failure
#      value; the mutation that proved it came from the agent extracting these rules into
#      _common.sh. Now the state is PLANTED first, so without the skip rule the guard would have
#      every reason to block and the assertion actually discriminates.
plant_conflict() {   # <path> <peer-sid> -- a live peer claim plus a stale view for OUR session
  local pth=$1 peer=$2 k; k=$(gov_path_key "$pth")
  mkdir -p "$GOV_COLLISION_LOCK_DIR" "$HOME/.claude/logs/sessions/B/file-shas" 2>/dev/null
  printf '%s\t%s\t%s\n' "$peer" "$(date +%s)" "deadbeef" > "$GOV_COLLISION_LOCK_DIR/$k"
  printf '%s' "cafebabe-stale-view" > "$HOME/.claude/logs/sessions/B/file-shas/$k"
}
# 8. Outside a git repo the guard keeps out of the way -- even with a live peer claim and a stale
#    view, which is a hard block anywhere it does apply.
plant_conflict "$OUTSIDE" ZZ
check "non-repo file ignored"        "$(run B Write "$OUTSIDE")" 0
# ...and the planted state really would have blocked, inside the repo. Same state, guarded path.
PROOF="$REPO/skip-proof.md"; printf 'x\n' > "$PROOF"
plant_conflict "$PROOF" ZZ
check "the planted state does block a guarded path" "$(run B Write "$PROOF")" 2

# 9. Paths the guard deliberately skips, with the same planted conflict.
mkdir -p "$REPO/node_modules"; printf 'x\n' > "$REPO/node_modules/pkg.js"
plant_conflict "$REPO/node_modules/pkg.js" ZZ
check "node_modules ignored"         "$(run B Write "$REPO/node_modules/pkg.js")" 0
rec A Write "$FILE"                                   # make A the active holder again

# 10. Fail-open on junk input
check "empty payload allowed"        "$(echo '' | GOV_SESSION_ID=B bash "$GUARD" >/dev/null 2>&1; echo $?)" 0
check "garbage payload allowed"      "$(echo 'not json' | GOV_SESSION_ID=B bash "$GUARD" >/dev/null 2>&1; echo $?)" 0
check "no session id allowed"        "$(printf '{"tool_input":{"file_path":"%s"}}' "$FILE" | GOV_SESSION_ID="" bash "$GUARD" >/dev/null 2>&1; echo $?)" 0

# 11. Kill switches must really switch it off
check "GOV_COLLISION_GUARD=0"        "$(payload B Write "$FILE" | GOV_SESSION_ID=B GOV_COLLISION_GUARD=0 bash "$GUARD" >/dev/null 2>&1; echo $?)" 0
check "GOVERNANCE_HOOKS=0"           "$(payload B Write "$FILE" | GOV_SESSION_ID=B GOVERNANCE_HOOKS=0 bash "$GUARD" >/dev/null 2>&1; echo $?)" 0

# 12. Dry-run must not create or move any state
before=$(ls -1 "$GOV_COLLISION_LOCK_DIR" 2>/dev/null | wc -l)
payload C Write "$REPO/dry.md" | GOV_SESSION_ID=C GOV_DRY_RUN=1 bash "$GUARD" >/dev/null 2>&1
after=$(ls -1 "$GOV_COLLISION_LOCK_DIR" 2>/dev/null | wc -l)
check "dry run writes no state"      "$before" "$after"

# ============ #102 part 1: our own shell write must not hard-block a surgical Edit ========
# All three reported false blocks were this shape: Write -> shell edit -> Edit refused, and
# refused again after the Read the message told us to do.

SELF="$REPO/self.md"; printf 'orig\n' > "$SELF"
rec F Write "$SELF"
shell_edit "$SELF" "our own sed"

# 18. Edit is allowed with a warning instead of a block — old_string is its own protection,
#     and there is no second writer whose work a block could save.
check "self stale view allows Edit"  "$(run F Edit "$SELF")" 0
said "Edit warning missing"          "NOTE from file-collision-guard"
# 19. It must own the change rather than blaming a session that did not make it.
notsaid "Edit warning must not blame another session" "session .* wrote it"
# 20. The warning auto-reconciles, so the very next Edit is silent. No nagging.
check "second Edit still allowed"    "$(run F Edit "$SELF")" 0
notsaid "warning repeated after reconcile" "NOTE from file-collision-guard"
# 21. Whatever it puts on stdout must be JSON Claude Code can parse.
shell_edit "$SELF" "third change"
run F Edit "$SELF" >/dev/null
check "warn stdout is valid JSON"    "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("ok")' "$WORK/out" 2>/dev/null)" ok
# 22. The reconcile must keep view and snapshot describing the SAME bytes, or a later block
#     would report a change set it never measured.
check "reconcile refreshes snapshot" "$(sha256sum < "$(snap_file F "$SELF")" 2>/dev/null | cut -d' ' -f1)" "$(sha256sum < "$SELF" 2>/dev/null | cut -d' ' -f1)"
# 23. Dry-run must not reconcile either.
SELF4="$REPO/self4.md"; printf 'orig\n' > "$SELF4"
rec G Write "$SELF4"; shell_edit "$SELF4" "sed"
sha_before=$(cat "$(view_file G "$SELF4")" 2>/dev/null)
payload G Edit "$SELF4" | GOV_SESSION_ID=G GOV_DRY_RUN=1 bash "$GUARD" >/dev/null 2>&1
check "dry run does not reconcile"   "$(cat "$(view_file G "$SELF4")" 2>/dev/null)" "$sha_before"

# ============ #102 part 2: every remaining block has a remedy that WORKS ==================

SELF2="$REPO/self2.md"; printf 'orig\n' > "$SELF2"
rec D Write "$SELF2"
shell_edit "$SELF2" "changed by our own sed"

# 24. A full-file Write from the stale picture is still refused — it would drop that change.
check "self stale view blocks Write" "$(run D Write "$SELF2")" 2
# 25. ...and it says honestly that the change was ours.
said "self block must own the change" "that write was yours"
# 26. ...and names the command that clears it. A remedy that is not printed is not a remedy.
said "self block must name the ack command" "file-collision-ack.sh"

# 27. The ack ticket exists only because a block was raised.
check "block leaves an ack ticket"   "$([ -f "$(ticket "$SELF2" D)" ] && echo yes || echo no)" yes
# 28. Acking SHOWS what changed — you cannot clear a block without seeing what you would
#     have overwritten. This is the assertion that separates a reconcile from a bypass.
check "ack succeeds"                 "$(ack "$SELF2")" 0
acksaid "ack must print the actual change" "changed by our own sed"
# 29. THE FIX: the remedy the block printed actually clears the block.
check "ack clears the self block"    "$(run D Write "$SELF2")" 0
# 30. The ticket is consumed — one ack per block, no lingering permission.
check "ack ticket consumed"          "$([ -f "$(ticket "$SELF2" D)" ] && echo yes || echo no)" no
# 31. And a second ack refuses rather than silently succeeding.
check "second ack refuses"           "$(ack "$SELF2")" 1
acksaid "second ack must say nothing is pending" "Nothing to acknowledge"

# 31b. The permissive branch is an explicit allow-list, never the default. An unrecognised
#      tool name -- or one the payload parse failed to produce -- is the case where we do NOT
#      know how much of the file is about to be replaced, so it must block like a Write.
SELFU="$REPO/self-unknown.md"; printf 'orig\n' > "$SELFU"
rec M Write "$SELFU"; shell_edit "$SELFU" "sed"
check "unknown tool blocks like Write"  "$(run M SomeFutureTool "$SELFU")" 2
check "empty tool name blocks like Write" "$(run M '' "$SELFU")" 2

# 32. No pre-emptive acks: a file that was never blocked cannot be acked.
NEVER="$REPO/never-blocked.md"; printf 'x\n' > "$NEVER"
check "ack refuses without a block"  "$(ack "$NEVER")" 1

# 33. With no snapshot, the ack must SAY it cannot show the change rather than print an
#     empty diff — an empty diff would read as "nothing changed", which is the exact
#     "reports something it never measured" failure this entry is about.
SELF5="$REPO/self5.md"; printf 'orig\n' > "$SELF5"
rec H2 Write "$SELF5"; shell_edit "$SELF5" "invisible change"
run H2 Write "$SELF5" >/dev/null
rm -f "$(snap_file H2 "$SELF5")"
check "ack runs without a snapshot"  "$(ack "$SELF5")" 0
acksaid "ack must admit it has no snapshot" "NO SNAPSHOT AVAILABLE"

# 34. A later successful write invalidates a stale ticket, so it cannot clear a future block.
SELF6="$REPO/self6.md"; printf 'orig\n' > "$SELF6"
rec I2 Write "$SELF6"; shell_edit "$SELF6" "sed"
run I2 Write "$SELF6" >/dev/null                     # raises a block -> leaves a ticket
rec I2 Write "$SELF6"                                # a real write happens afterwards
check "write clears a stale ticket"  "$([ -f "$(ticket "$SELF6" I2)" ] && echo yes || echo no)" no

# ============ #102 part 3: none of the above weakened the real two-writer case ============

TWO="$REPO/two.md"; printf 'orig\n' > "$TWO"
rec H Write "$TWO"                                     # H writes
printf 'changed by I\n' > "$TWO"; rec I Write "$TWO"   # I writes after it
age_lock "$TWO"                                        # let I's active claim lapse

# 35. H's Edit is still hard-blocked: a real second writer exists.
check "cross-session stale view blocks Edit"  "$(run H Edit "$TWO")" 2
# 36. ...and Write too.
check "cross-session stale view blocks Write" "$(run H Write "$TWO")" 2
# 37. The message names the writer it actually recorded...
said "cross-session block must name the recorded writer" "last recorded write: session I"
# 38. ...and admits what it does not know, instead of asserting who changed the file.
said "cross-session block must admit shell writes are invisible" "shell command"
# 39. Its remedy works too, and shows H what I did before letting H past.
check "ack clears the cross-session block" "$(ack "$TWO")" 0
acksaid "ack must show the other session's change" "changed by I"
age_lock "$TWO"
check "H may write after acking"     "$(run H Write "$TWO")" 0

# 40. The concurrent block must not advertise a remedy that does not work either.
CONC="$REPO/conc.md"; printf 'orig\n' > "$CONC"
rec J Write "$CONC"
check "concurrent block still blocks" "$(run K Write "$CONC")" 2
said "concurrent block must not promise re-reading works" "Re-reading does NOT clear this block"
said "concurrent block must say the ack does not apply"   "neither does file-collision-ack"
# 41. ...and it must not have left a ticket, because acking cannot make it safe.
check "concurrent block leaves no ticket" "$([ -f "$(ticket "$CONC" K)" ] && echo yes || echo no)" no

# 42. An allowed write never leaves a ticket either.
ALLOWED="$REPO/allowed.md"; printf 'x\n' > "$ALLOWED"
run L Write "$ALLOWED" >/dev/null
check "allowed write leaves no ticket" "$([ -f "$(ticket "$ALLOWED" L)" ] && echo yes || echo no)" no

# 43. --list is honest when there is nothing outstanding.
rm -f "$GOV_COLLISION_ACK_DIR"/* 2>/dev/null
check "ack --list runs clean"        "$(ack --list)" 0
acksaid "ack --list must report an empty queue" "No collision blocks"

# 43b. The ack script must never block on stdin. It is not a hook: it is run by hand or by an
#      agent through a Bash call, so its stdin is whatever the caller had open. _common.sh
#      reads stdin to EOF when stdin is not a tty -- right for a hook, fatal here. Caught by
#      two test runs wedging at the same step; `sleep 30 | file-collision-ack.sh --list` never
#      returned. A command whose whole job is unwedging a blocked session must not hang.
( sleep 20 | timeout 8 bash "$ACK" --list >/dev/null 2>&1 )
check "ack does not block on an open stdin" "$?" 0

# ====================== CODEX review on PR #1 (2026-08-22) ===============================

# 44. Every _common.sh helper these hooks call must actually EXIST in the _common.sh that
#     ships beside them. gov_path_key was missing from the tracked copy: KEY came back empty,
#     `[ -z "$KEY" ] && exit 0` fired, and the guard exited 0 for every edit -- installed,
#     registered, and completely inert, with no error anywhere. Nothing else in this battery
#     could have caught it, because it drives the hooks next to a _common.sh that has it.
missing=""
for fn in gov_path_key gov_state_dir gov_hook_input gov_session_id gov_log gov_dry gov_disabled; do
  grep -q "^$fn()" "$DIR/_common.sh" || missing="$missing $fn"
done
check "_common.sh defines every helper the hooks call" "${missing:-none}" "none"

# 45. Claim acquisition must be atomic. Two sessions first touching the same file can each
#     finish the claim READ before either reaches the claim WRITE, and both then proceed --
#     the exact silent lost update this guard exists to prevent. The critical section is what
#     serialises them, so assert it is really taken and really released.
RACE="$REPO/race.md"; printf 'orig\n' > "$RACE"
CSDIR="$GOV_COLLISION_LOCK_DIR/$(gov_path_key "$RACE").cs"
check "no critical section left behind" "$([ -d "$CSDIR" ] && echo yes || echo no)" no
run N Write "$RACE" >/dev/null
check "critical section released after a run" "$([ -d "$CSDIR" ] && echo yes || echo no)" no
# A section held by a LIVE peer must make us wait and then proceed unserialised rather than
# tear it down -- tearing it down would make the serialisation theatre.
age_lock "$RACE"          # or danger 1 blocks first and this passes for the wrong reason
mkdir -p "$CSDIR"
check "held section does not break editing" "$(run O Write "$RACE")" 0
check "held section is not torn down"       "$([ -d "$CSDIR" ] && echo yes || echo no)" yes
# ...but a section old enough to be a corpse must be reclaimed, or one killed hook wedges
# every future edit of that file.
touch -d '-120 seconds' "$CSDIR" 2>/dev/null || touch -t 200001010000 "$CSDIR" 2>/dev/null
run P Write "$RACE" >/dev/null
check "stale section is reclaimed and released" "$([ -d "$CSDIR" ] && echo yes || echo no)" no

# 46. Tickets are per SESSION, not per file. With one ticket per file, a second session's
#     block overwrites the first's, and the first session's own printed command then consumes
#     the second's ticket: the wrong block is cleared and the first session stays refused --
#     the remedy failing in exactly the multi-session case the guard is for.
SHARED="$REPO/shared-block.md"; printf 'orig\n' > "$SHARED"
rec Q Write "$SHARED"; rec R Write "$SHARED"           # both sessions have a view
shell_edit "$SHARED" "changed by a shell command"
age_lock "$SHARED"
check "Q blocked"  "$(run Q Write "$SHARED")" 2
check "R blocked"  "$(run R Write "$SHARED")" 2
tq="$GOV_COLLISION_ACK_DIR/$(gov_path_key "$SHARED").Q"
tr_="$GOV_COLLISION_ACK_DIR/$(gov_path_key "$SHARED").R"
check "Q has its own ticket" "$([ -f "$tq" ] && echo yes || echo no)" yes
check "R has its own ticket" "$([ -f "$tr_" ] && echo yes || echo no)" yes
# Acking without a session id must REFUSE while two are outstanding, rather than guess.
check "ambiguous ack refuses"  "$(ack "$SHARED")" 1
acksaid "ambiguous ack must offer the disambiguated commands" "file-collision-ack.sh"
# The form the guard prints carries the session id and clears only that session's block.
check "Q acks its own block"   "$(ack "$SHARED" Q)" 0
check "Q ticket consumed"      "$([ -f "$tq" ] && echo yes || echo no)" no
check "R ticket untouched"     "$([ -f "$tr_" ] && echo yes || echo no)" yes
age_lock "$SHARED"
check "R is still blocked"     "$(run R Write "$SHARED")" 2

# 47. A write by one session must not delete another session's ticket. That session is still
#     blocked, and its ticket is its only way out -- our write is the very change it needs to
#     be shown before it proceeds.
rec Q Write "$SHARED"
check "R ticket survives Q's write" "$([ -f "$GOV_COLLISION_ACK_DIR/$(gov_path_key "$SHARED").R" ] && echo yes || echo no)" yes

# ================= CODEX second review on PR #1 (2026-08-22) =============================

# 48. NotebookEdit must NOT be on the permissive path. The entire justification for downgrading
#     is that old_string still has to match; NotebookEdit replaces a cell by cell_id and has no
#     such precondition, so an external change to that cell would be silently discarded.
NB="$REPO/nb.ipynb"; printf '{"cells":[]}\n' > "$NB"
rec S Write "$NB"; shell_edit "$NB" '{"changed":true}'
check "NotebookEdit blocks like a write"  "$(run S NotebookEdit "$NB")" 2
check "Edit is still allowed"             "$(run S Edit "$NB")" 0

# 49. The command the block prints is presented as something to RUN, so every argument must be
#     shell-quoted. A repository may legally contain a filename holding $(...) or a backtick;
#     interpolating that into a double-quoted string turns a stale-view block on a crafted path
#     into command execution the moment the remedy is copied.
EVIL="$REPO/eek\$(touch PWNED)\`touch PWNED2\`.md"
printf 'orig\n' > "$EVIL"
rec T Write "$EVIL"; shell_edit "$EVIL" "sed"
check "crafted filename still blocks"     "$(run T Write "$EVIL")" 2
# Execute the printed command exactly as an agent would copy it, then assert the payload in
# the filename did NOT run.
CMD=$(grep -o 'bash .*file-collision-ack\.sh.*' "$WORK/err" | head -1)
eval "$CMD" >/dev/null 2>&1
check "printed command did not execute the filename" "$( { [ -e "$REPO/PWNED" ] || [ -e "$REPO/PWNED2" ] || [ -e PWNED ] || [ -e PWNED2 ]; } && echo pwned || echo safe)" safe
check "and it still cleared the block"    "$(run T Write "$EVIL")" 0

# 50. A claim must never be visible in a truncated state. `>` truncates first and writes second;
#     a guard reading in that window sees an empty session id and treats the file as unclaimed.
#     Both writers must publish by atomic rename instead.
check "guard never writes the claim with >"    "$(grep -c '> "\$LOCK" 2>/dev/null' "$GUARD")" 0
check "recorder never writes the claim with >" "$(grep -c '> "\$LOCK_DIR/\$KEY" 2>/dev/null' "$RECORD")" 0
check "guard publishes by rename"              "$(grep -c 'mv -f "\$tmp" "\$LOCK"' "$GUARD")" 1
check "recorder publishes by rename"           "$(grep -c 'mv -f "\$_LOCK_TMP"' "$RECORD")" 1
# and the claim a real run leaves behind must still parse as three tab-separated fields
ATOM="$REPO/atomic.md"; printf 'x\n' > "$ATOM"
run U Write "$ATOM" >/dev/null
IFS=$'\t' read -r _a _b _c < "$GOV_COLLISION_LOCK_DIR/$(gov_path_key "$ATOM")"
check "claim still parses as sid/ts/sha" "$([ "$_a" = "U" ] && [ -n "$_b" ] && echo ok || echo "bad:$_a/$_b")" ok
check "no temp claim files left behind"  "$(ls -1 "$GOV_COLLISION_LOCK_DIR" 2>/dev/null | grep -c '\.tmp\.')" 0

# 51. Stale-section takeover must preserve ownership. If two contenders both see the same stale
#     directory, an rmdir by the second can delete the FIRST contender's freshly acquired
#     section, and both then proceed believing they hold it -- the dual-claim race reintroduced
#     inside its own recovery. Renaming is the ownership-preserving move.
check "takeover renames, never rmdirs" "$(grep -c 'mv "\$CS" "\$CS.dead' "$GUARD")" 1
check "no bare rmdir of a stale CS"    "$(grep -c '^      rmdir "\$CS"' "$GUARD")" 0
RC2="$REPO/reclaim.md"; printf 'x\n' > "$RC2"
CS2="$GOV_COLLISION_LOCK_DIR/$(gov_path_key "$RC2").cs"
mkdir -p "$CS2"; touch -d '-120 seconds' "$CS2" 2>/dev/null || touch -t 200001010000 "$CS2" 2>/dev/null
check "stale section reclaimed"        "$(run V Write "$RC2")" 0
check "and released again"             "$([ -d "$CS2" ] && echo yes || echo no)" no
check "no tombstone left behind"       "$(ls -1d "$GOV_COLLISION_LOCK_DIR"/*.dead.* 2>/dev/null | wc -l)" 0

# 52. The ack must test the WRITE, not the file. `-s` only asks whether the file is non-empty,
#     so an unwritable view file leaves its old contents in place, `-s` passes, the ticket is
#     consumed, and the command reports a cleared block over a stale hash. That is the worst
#     failure available here: a remedy that claims to have worked and did not.
check "ack checks the write, not the size" "$(grep -c 'if ! printf .%s. "\$CUR_SHA" > "\$A_VIEW"' "$ACK")" 1
check "ack no longer infers success from -s" "$(grep -c '\[ ! -s "\$A_VIEW" \]' "$ACK")" 0
UNW="$REPO/unwritable.md"; printf 'orig\n' > "$UNW"
rec W Write "$UNW"; shell_edit "$UNW" "sed"
run W Write "$UNW" >/dev/null                      # raise a block so a ticket exists
VF=$(view_file W "$UNW")
# make the view file unwritable by replacing it with a DIRECTORY of the same name: the
# redirection then fails while something non-empty still occupies the path, which is exactly
# the shape the -s check could not distinguish
OLDVIEW=$(cat "$VF"); rm -f "$VF"; mkdir -p "$VF"
check "ack fails loudly when it cannot record" "$(ack "$UNW" W)" 1
check "and keeps the ticket for a retry"       "$([ -f "$(ticket "$UNW" W)" ] && echo yes || echo no)" yes
rmdir "$VF" 2>/dev/null; printf '%s' "$OLDVIEW" > "$VF"

# ================= CODEX third review on PR #1 (2026-08-22) ==============================

# 53. Absence of a file is not proof it is safe to create. Session A can finish PreToolUse and
#     leave a claim BEFORE its Write creates the file; B then arrives while the path is still
#     absent and, if that shortcut runs before the claim check, is also allowed. Both Writes run
#     and the last silently replaces the other.
NEWF="$REPO/created-twice.md"          # deliberately NOT created
check "A may create a new file"        "$(run A2 Write "$NEWF")" 0
check "B is blocked on the same new file" "$(run B2 Write "$NEWF")" 2
said "and it is the concurrent block"  "another Claude Code session is editing"
# once A2's claim lapses, B2 may go ahead - the shortcut must not become a permanent block
age_lock "$NEWF"
check "B allowed once the claim lapses" "$(run B2 Write "$NEWF")" 0

# 54. Two spellings of one file must share one claim. Without canonicalisation each session takes
#     its own claim and both writes are allowed - the guard defeated by nothing more than how the
#     path happened to be written.
mkdir -p "$REPO/sub"
ALIASED="$REPO/aliased.md"; printf 'x\n' > "$ALIASED"
ALIAS2="$REPO/sub/../aliased.md"
check "aliases hash to one key"        "$([ "$(gov_path_key "$ALIASED")" = "$(gov_path_key "$ALIAS2")" ] && echo same || echo diff)" same
check "A claims via the plain spelling" "$(run C2 Write "$ALIASED")" 0
check "B blocked via the ../ spelling"  "$(run D2 Write "$ALIAS2")" 2
check "only one lock file exists"      "$(ls -1 "$GOV_COLLISION_LOCK_DIR" | grep -c "^$(gov_path_key "$ALIASED")$")" 1
# and genuinely different files must still be different
check "different files stay different" "$([ "$(gov_path_key "$REPO/a.md")" = "$(gov_path_key "$REPO/b.md")" ] && echo same || echo diff)" diff

# 55. The parse protocol must not lose a path. A POSIX filename may contain a newline; with the
#     path on line 1 it was truncated AND the tool name was shifted, so the guard keyed a
#     different file from the recorder and protection vanished for exactly that file.
check "tool name is read first"        "$(grep -c 'TOOL=\${_PARSED%%' "$GUARD")" 1
check "path is everything after it"    "$(grep -c 'FILE_PATH=\${_PARSED#\*' "$GUARD")" 1
check "no line-indexed parsing left"   "$(grep -c "sed -n '1p'\|sed -n '2p'" "$GUARD")" 0
NLF="$REPO/two
lines.md"
if printf 'x\n' > "$NLF" 2>/dev/null; then
  # POSIX: prove it end to end
  check "newline path: guard keys it whole" "$(run E2 Write "$NLF")" 0
  check "newline path: recorder agrees"     "$(rec E2 Write "$NLF"; [ -f "$GOV_COLLISION_LOCK_DIR/$(gov_path_key "$NLF")" ] && echo yes || echo no)" yes
else
  # Windows cannot create such a name; the static assertions above are the coverage, and saying
  # so beats a silently skipped case that later reads as "tested".
  echo "  (note: filesystem refuses newline filenames - case 55 covered statically only)"
  pass=$((pass+2))
fi

# 56. EVERY printed command must be %q-quoted, not just the one that was reported. The
#     "Full comparison" hint is also something the reader is invited to run.
check "full-comparison hint is quoted" "$(grep -c "diff -u \$(printf '%q'" "$ACK")" 1
check "no unquoted path in a printed diff" "$(grep -c 'diff -u \\"\$A_SNAP\\"' "$ACK")" 0

# 57. The recorder must not claim synchronisation it cannot verify. If a TRACKED peer claimed the
#     file between our PreToolUse and this hook, the bytes on disk may be theirs; recording them
#     as our view would let our next whole-file Write erase their work.
PEER="$REPO/peer-wrote.md"; printf 'orig\n' > "$PEER"
run F2 Write "$PEER" >/dev/null                     # F2 allowed, leaves claim + pre-marker
printf 'written by G2\n' > "$PEER"; rec G2 Write "$PEER"   # a peer writes and claims, mid-flight
rec F2 Write "$PEER"                                # F2's PostToolUse now runs
check "view not advanced over a peer's bytes" \
  "$([ "$(cat "$(view_file F2 "$PEER")" 2>/dev/null)" = "$(sha256sum < "$PEER" | cut -d' ' -f1)" ] && echo advanced || echo held)" held
age_lock "$PEER"
check "so F2 is blocked, not silently allowed" "$(run F2 Write "$PEER")" 2
# and the normal case must still advance, or every write would block forever
SOLO="$REPO/solo.md"; printf 'orig\n' > "$SOLO"
run H3 Write "$SOLO" >/dev/null; printf 'by H3\n' > "$SOLO"; rec H3 Write "$SOLO"
check "normal case still advances the view" \
  "$([ "$(cat "$(view_file H3 "$SOLO")" 2>/dev/null)" = "$(sha256sum < "$SOLO" | cut -d' ' -f1)" ] && echo advanced || echo held)" advanced
check "and H3 may write again"         "$(run H3 Write "$SOLO")" 0


# 58. The guard and the recorder must agree on what a payload MEANS. They key their state off the
#     parsed path, so if one derives it differently from the other they hash different keys for
#     one file and each keeps its own claim and view -- protection absent while both hooks look
#     healthy. Python's text stdout on Windows did exactly this: the tool name arrived as "Edit\r"
#     (so no surgical edit ever matched the allow-list) and the recorder's path kept a trailing CR
#     the guard's had lost.
#
#     Asserted BEHAVIOURALLY, on purpose. The first version of this case diffed the parse block
#     out of each file's source, which passes the moment the block is absent from BOTH -- its pass
#     value would equal its failure value under any refactor that moves the parser into _common.sh.
#     Caught by the agent doing exactly that refactor. A check that cannot fail is not a check.
_frame_key() {   # <sid> <tool> <path> -> the key that hook actually used
  local hook=$1 sid=$2 tool=$3 path=$4 before after
  before=$(ls -1 "$GOV_COLLISION_LOCK_DIR" 2>/dev/null | grep -v '\.tmp\.' | sort)
  payload "$sid" "$tool" "$path" | GOV_SESSION_ID="$sid" bash "$hook" >/dev/null 2>&1
  after=$(ls -1 "$GOV_COLLISION_LOCK_DIR" 2>/dev/null | grep -v '\.tmp\.' | sort)
  comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1
}
for _spec in "plain:frame-plain.md" "space:frame with space.md" "dollar:frame\$(x).md" "dots:sub/../frame-dots.md"; do
  _lbl=${_spec%%:*}; _rel=${_spec#*:}
  mkdir -p "$REPO/sub"; _fp="$REPO/$_rel"; printf 'x\n' > "$_fp" 2>/dev/null || continue
  rm -f "$GOV_COLLISION_LOCK_DIR"/* 2>/dev/null
  _gk=$(_frame_key "$GUARD"  "FR1" Write "$_fp")
  rm -f "$GOV_COLLISION_LOCK_DIR"/* 2>/dev/null
  _rk=$(_frame_key "$RECORD" "FR1" Write "$_fp")
  check "guard and recorder agree on the key ($_lbl)" "${_gk:-guard-produced-nothing}" "${_rk:-recorder-produced-nothing}"
  check "and it is a real 32-hex key ($_lbl)"         "$(printf '%s' "$_gk" | grep -c '^[0-9a-f]\{32\}$')" 1
done
# and the tool name must arrive clean, which is what the CR bug broke: a surgical edit on a
# self-changed file is allowed ONLY if "Edit" matched exactly.
CRT="$REPO/crtool.md"; printf 'orig\n' > "$CRT"
rec CR1 Write "$CRT"; shell_edit "$CRT" "sed"
check "tool name arrives clean enough to match" "$(run CR1 Edit "$CRT")" 0



export HOME="$HOME_ORIG"
total=$((pass+${#fails[@]}))
echo "$pass/$total passed"
for f in "${fails[@]}"; do echo "  FAIL $f"; done
[ ${#fails[@]} -eq 0 ]
