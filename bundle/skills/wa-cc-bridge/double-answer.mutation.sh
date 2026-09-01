#!/usr/bin/env bash
# Mutation proof for double-answer.test.js.
#
# Each case restores ONE of the defects the owner actually hit, in a COPY, and asserts that the
# assertion written to catch it goes red. Two of these mutations are simply "the code as it was
# this morning".
#
# The mutation strings live in a quoted heredoc, never in bash argument quoting: the first version
# passed them as `\x27`-escaped arguments, bash handed the escapes through literally, nothing
# matched, and the harness stopped with "MUTATION DID NOT APPLY" - which at least fails loudly
# rather than reporting a proof it never ran.
#
# Run: bash ~/.claude/skills/wa-cc-bridge/double-answer.mutation.sh
set +e
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${USERPROFILE:-$HOME}"
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

work="${TMPDIR:-/tmp}/wa-da-mutation-$$"
mkdir -p "$work"
trap 'rm -rf "$work" 2>/dev/null' EXIT

cat > "$work/mutate.js" <<'MUTJS'
const fs = require('fs');
const [, , root, name] = process.argv;
const M = {
  // the separator rule, i.e. the code exactly as it was on the morning of 2026-07-29
  separators: ['skills/wa-cc-bridge/wa-inbox.js',
    "return String(p || '').replace(/[\\\\/]+/g, '/').replace(/\\/+$/, '').toLowerCase();",
    "return String(p || '').replace(/[\\\\/]+$/, '').toLowerCase();"],
  // delivery judged by the status code alone
  status_only: ['.claude/skills/whatsapp/send.js',
    'const ok = res.statusCode >= 200 && res.statusCode < 300 && !!id;',
    'const ok = true;'],
  // no retry for a transient failure
  no_retry: ['.claude/skills/whatsapp/send.js',
    'const ATTEMPTS = Number(process.env.WA_SEND_ATTEMPTS || 3);',
    'const ATTEMPTS = 1;'],
  // the silent-loss defect: a failed send still exits 0
  exit_zero: ['.claude/skills/whatsapp/send.js',
    '  process.exit(1);\n})();',
    '  process.exit(0);\n})();'],
  // a starting monitor no longer seizes the bridge -> back to first-wins
  no_takeover: ['skills/wa-cc-bridge/wa-session-inbox.js',
    'let role = inbox.claimPresence(PRESENCE, CWD, Date.now(), process.pid, { takeover: true });',
    'let role = inbox.claimPresence(PRESENCE, CWD);'],
  // the asymmetry is gone: heartbeats seize too, so two live monitors trade the bridge
  beat_seizes: ['skills/wa-cc-bridge/wa-inbox.js',
    '  if (!opts.takeover) {',
    '  if (false) {'],
};
const [rel, from, to] = M[name] || [];
if (!rel) { console.error('unknown mutation ' + name); process.exit(8); }
const p = root + '/' + rel;
const s = fs.readFileSync(p, 'utf8');
if (!s.includes(from)) { console.error('MUTATION DID NOT APPLY: ' + name + ' in ' + p); process.exit(9); }
fs.writeFileSync(p, s.replace(from, to));
MUTJS

COPY=""
newcopy() {                       # newcopy <name> -> sets $COPY
  COPY="$work/$1"
  mkdir -p "$COPY/skills/wa-cc-bridge" "$COPY/.claude/skills/whatsapp"
  cp "$SRC"/*.js "$COPY/skills/wa-cc-bridge/" 2>/dev/null
  cp "$HOME_DIR/.claude/skills/whatsapp/send.js" "$COPY/.claude/skills/whatsapp/send.js"
  [ -f "$COPY/skills/wa-cc-bridge/double-answer.test.js" ] || { echo "HARNESS: copy failed"; exit 2; }
}

run_copy() { USERPROFILE="$COPY" HOME="$COPY" node "$COPY/skills/wa-cc-bridge/double-answer.test.js" 2>&1; }

assert_red() {
  local out="$1" needle="$2" label="$3"
  if ! printf '%s' "$out" | grep -q '^pass='; then
    bad "$label (HARNESS: the suite never completed)"; printf '%s\n' "$out" | tail -4; return
  fi
  if printf '%s' "$out" | grep -q "FAIL  $needle"; then ok "$label"
  else bad "$label (assertion stayed GREEN under the mutation)"; fi
}

mutate() { node "$work/mutate.js" "$COPY" "$1" || { echo "HARNESS: mutation $1 failed"; exit 3; }; }

echo "== M1: the separator rule is removed (the code as it was this morning) =="
newcopy m1; mutate separators
assert_red "$(run_copy)" "THE BUG: forward-slash presence" "the double-answer bug is actually guarded"

echo "== M2: send.js judges delivery by the status code alone =="
newcopy m2; mutate status_only
assert_red "$(run_copy)" "a 200 with NO messageId" "a status code alone can no longer pass for a delivery"

echo "== M3: the retry is removed =="
newcopy m3; mutate no_retry
assert_red "$(run_copy)" "THE OWNER BUG: a transient 400" "the transient-400 retry is actually exercised"

echo "== M4: a failure exits 0 again (the silent-loss defect) =="
newcopy m4; mutate exit_zero
assert_red "$(run_copy)" "a persistent failure EXITS NON-ZERO" "the caller can still tell a lost message from a sent one"

echo "== M5: a standby monitor emits events again (the owner's two answers to one message) =="
newcopy m5
MUT_FILE="$COPY/skills/wa-cc-bridge/wa-session-inbox.js" \
MUT_FROM="  if (role !== 'owner') return;" \
MUT_TO="  // standby suppression removed" node -e '
  const fs = require("fs");
  const p = process.env.MUT_FILE;
  const s = fs.readFileSync(p, "utf8");
  if (!s.includes(process.env.MUT_FROM)) { console.error("MUTATION DID NOT APPLY: standby"); process.exit(9); }
  fs.writeFileSync(p, s.replace(process.env.MUT_FROM, process.env.MUT_TO));
' || { echo "HARNESS: M5 mutation failed"; exit 3; }
assert_red "$(run_copy)" "the NEWER monitor leads" "a standby that emits again is caught end to end"

echo "== M6: a starting monitor no longer takes over (back to first-wins) =="
newcopy m6; mutate no_takeover
assert_red "$(run_copy)" "the NEWER monitor leads" "newest-wins is actually exercised end to end"

echo "== M7: the heartbeat seizes too (two monitors trading the bridge every beat) =="
newcopy m7; mutate beat_seizes
assert_red "$(run_copy)" "a HEARTBEAT never seizes" "the takeover asymmetry is guarded"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
