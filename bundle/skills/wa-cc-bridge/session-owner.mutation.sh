#!/usr/bin/env bash
# Mutation proof for session-owner.test.js.
#
# A green suite proves nothing until you have watched it go red for the right reason. Each
# case below breaks ONE thing in a COPY of the skill (never the live files) and asserts that
# the specific assertion which exists to catch it actually fails.
#
# Run: bash ~/.claude/skills/wa-cc-bridge/session-owner.mutation.sh
#
# Note on structure: the working copy is made by a function that assigns a GLOBAL, never by
# `d=$(newcopy ...)`. A command-substitution subshell inherits the EXIT trap and fires the
# cleanup when it returns - which deleted every copy the instant it was made, and the first
# version of this harness then reported mutations as "unproven" for the wrong reason.
set +e
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${USERPROFILE:-$HOME}"
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

work="${TMPDIR:-/tmp}/wa-mutation-$$"
mkdir -p "$work"
cleanup() { rm -rf "$work" 2>/dev/null; }
trap cleanup EXIT

COPY=""
newcopy() {                     # newcopy <name>  -> sets $COPY
  COPY="$work/$1"
  mkdir -p "$COPY"
  cp "$SRC/session-owner.js" "$SRC/session-owner.test.js" "$SRC/wa-session-inbox.js" \
     "$SRC/wa-inbox.js" "$COPY/" || { echo "HARNESS: copy failed"; exit 2; }
  cp "$HOME_DIR/.claude/settings.json" "$COPY/settings.json" \
     || { echo "HARNESS: settings copy failed"; exit 2; }
}

run_copy() {                    # run the suite against $COPY, echo its output
  WA_SETTINGS_PATH="$COPY/settings.json" node "$COPY/session-owner.test.js" 2>&1
}

# A mutation is proven only when the suite RAN and the named assertion went red. A suite
# that crashed proves nothing - that distinction is the whole point of this file.
assert_red() {
  local out="$1" needle="$2" label="$3"
  if ! printf '%s' "$out" | grep -q '^pass='; then
    bad "$label (HARNESS: the suite never completed)"
    printf '%s\n' "$out" | tail -5
    return
  fi
  if printf '%s' "$out" | grep -q "FAIL  $needle"; then ok "$label"
  else bad "$label (assertion stayed GREEN under the mutation)"; fi
}

mutate() {                      # mutate <file> <from> <to>
  MUT_FILE="$COPY/$1" MUT_FROM="$2" MUT_TO="$3" node -e '
    const fs = require("fs");
    const p = process.env.MUT_FILE;
    const s = fs.readFileSync(p, "utf8");
    if (!s.includes(process.env.MUT_FROM)) { console.error("MUTATION DID NOT APPLY"); process.exit(9); }
    fs.writeFileSync(p, s.replace(process.env.MUT_FROM, process.env.MUT_TO));
  ' || { echo "HARNESS: mutation did not apply to $1"; exit 3; }
}

echo "== M1: the close hook is put back on Stop =="
newcopy m1
MUT_SETTINGS="$COPY/settings.json" node -e '
  const fs=require("fs"), p=process.env.MUT_SETTINGS, j=JSON.parse(fs.readFileSync(p,"utf8"));
  j.hooks.Stop[0].hooks.unshift({type:"command",command:"~/.claude/hooks/wa-session-inbox-stop.sh"});
  fs.writeFileSync(p, JSON.stringify(j,null,2));
'
assert_red "$(run_copy)" "wa-session-inbox-stop.sh is NOT on Stop" \
  "the registration guard catches the real outage"

echo "== M2: the deterministic release is dropped from SessionEnd =="
newcopy m2
MUT_SETTINGS="$COPY/settings.json" node -e '
  const fs=require("fs"), p=process.env.MUT_SETTINGS, j=JSON.parse(fs.readFileSync(p,"utf8"));
  j.hooks.SessionEnd=(j.hooks.SessionEnd||[]).map(g=>({...g,
    hooks:(g.hooks||[]).filter(h=>!String(h.command||"").includes("wa-session-inbox-stop"))}));
  fs.writeFileSync(p, JSON.stringify(j,null,2));
'
assert_red "$(run_copy)" "wa-session-inbox-stop.sh IS on SessionEnd" \
  "the release guard catches a missing SessionEnd hook"

echo "== M3: the owner is matched on the command line instead of the process name =="
newcopy m3
mutate session-owner.js \
  "if (name === 'claude.exe') return e;" \
  "if (name === 'claude.exe' || /claude/i.test(e.commandLine)) return e;"
assert_red "$(run_copy)" "MUTATION GUARD" "the .claude-in-the-path trap is actually guarded"

echo "== M4: the watchdog never acts on a dead session =="
newcopy m4
mutate wa-session-inbox.js "if (sessionOwner.isAlive(OWNER)) return;" "return;"
assert_red "$(run_copy)" "killing the session" "the live E2E actually depends on the watchdog"

echo "== M5: the monitor exits without releasing presence =="
newcopy m5
mutate wa-session-inbox.js "  unregisterMonitor();
  inbox.clearPresence(PRESENCE);
  process.exit(code || 0);" "  process.exit(code || 0);"
mutate wa-session-inbox.js "process.on('exit', () => { unregisterMonitor(); inbox.clearPresence(PRESENCE); });" ""
assert_red "$(run_copy)" "killing the session" \
  "a monitor that exits without releasing presence is caught"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
