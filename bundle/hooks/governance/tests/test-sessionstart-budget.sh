#!/usr/bin/env bash
# test-sessionstart-budget.sh — every SessionStart hook finishes inside its budget (2026-09-26)
#
# WHY. SessionStart hooks BLOCK Claude Code's start-up, and the VS Code extension gives the whole
# subprocess 60 s before it fails with "Subprocess initialization did not complete within
# 60000ms". On 2026-09-26 pre-session.sh took 40 s on the owner's machine: gov_other_sessions
# forked ~8 processes for EACH of 87 session dirs, and on Windows a fork costs 30-100 ms. With the
# registered timeout at 10 s the hook was killed at every start and its briefing lost; raised to
# 120 s it outlived the extension's 60 s and the extension refused to start at all. Every failed
# start left one more session dir, so each start was slower than the last.
#
# The earlier probe that "proved" the hook fast (1.7 s) piped `{}` — no session_id — which skips
# the per-session scan entirely. So every run below carries a real session_id and a realistic
# number of other session dirs, and pipes stdout through `cat`, so a background child that keeps
# the hook's stdout open is timed too (Claude Code waits for EOF, not for the script's exit).
#
# Asserts:
#   1. SessionStart timeouts in settings-hooks.json: pre-session.sh <= 10, every other one <= 15
#   2. every SessionStart hook, run with 80 other session dirs and `| cat`, finishes < budget
#   2b. pre-session.sh with 200 session dirs costs < GROWTH_MS more than with none (the root cause)
#   3. the session scan keeps its meaning: a live dir is PARALLEL, a silent one with changes is a
#      CRASH (archived, emptied, closed), a dir untouched for 14+ days is pruned, the rest survive -
#      on the fast path AND on the per-dir loop kept for a find without -printf (run here with GNU
#      find: it proves the loop means the same, not how BSD find behaves)
#   5. the updater is only REPORTED at session start: an apply in progress, an interrupted one, a
#      staged release (silent when opted out) - never run, nothing restored by the hook
#   6. gov_dirty_snapshot prints exactly what the per-path loop it replaced printed
#
# Budget: GOV_SS_BUDGET_MS (default 9000, median of 3); growth 0 -> 200 dirs: GOV_SS_GROWTH_MS (default 2000). Template: GOV_SS_TEMPLATE (default: the bundle's).
# Usage: bash ~/.claude/hooks/governance/tests/test-sessionstart-budget.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
# The template sits two levels above the hooks in a bundle (bundle/hooks/governance), and in the
# installer staging copy when run from the live tree (~/.claude/hooks/governance).
TEMPLATE="${GOV_SS_TEMPLATE:-}"
if [ -z "$TEMPLATE" ]; then
  for _t in "$HOOKS_SRC/../../settings-hooks.json" "$HOME/.claude/governance-installer/bundle/settings-hooks.json"; do
    [ -f "$_t" ] && { TEMPLATE="$(cd "$(dirname "$_t")" && pwd)/settings-hooks.json"; break; }
  done
fi
# 9 s, median of 3: 1 s under the 10 s timeout. The hook's BASE cost on Windows is
# ~4.5 s idle and ~8 s with three test suites running (MEASURED 2026-09-26) - an open problem.
BUDGET_MS="${GOV_SS_BUDGET_MS:-9000}"
# What must NOT happen again: time that grows with the number of session dirs.
GROWTH_MS="${GOV_SS_GROWTH_MS:-2000}"
N_DIRS="${GOV_SS_DIRS:-80}"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
ms()   { date +%s%3N; }
# BSD date (macOS) has no %N: it prints a literal "3N". Fall back to python, then to whole seconds.
case "$(date +%s%3N)" in
  *[!0-9]*) if command -v python3 >/dev/null 2>&1; then ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
            else ms() { echo "$(( $(date +%s) * 1000 ))"; }; fi ;;
esac
# `timeout` is absent on stock macOS. Without it the hook runs unbounded rather than not at all: a
# missing wrapper that made the pipeline return at once would read as a fast hook (fail open).
_bounded() { if command -v timeout >/dev/null 2>&1; then timeout 60 "$@"; else "$@"; fi; }
case "$(ms)" in *N|*[!0-9]*) echo "date +%s%3N is not supported here - cannot time anything"; echo "pass=0 fail=1"; exit 1 ;; esac

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/gov-ssbudget-XXXXXX")"
trap 'rm -rf "$SANDBOX" 2>/dev/null' EXIT
export HOME="$SANDBOX/home" USERPROFILE="$SANDBOX/home"
mkdir -p "$HOME/.claude/logs/sessions" "$HOME/.claude/hooks/governance"
cp "$HOOKS_SRC"/*.sh "$HOOKS_SRC"/*.js "$HOOKS_SRC"/*.py "$HOME/.claude/hooks/governance/" 2>/dev/null
H="$HOME/.claude/hooks/governance"
export GOVERNANCE_HOOKS=1 GOV_NOTIFY=0 GOV_WHATSAPP=0 GOVERNANCE_LOG="$HOME/.claude/logs/governance.log"
# The update advisory stays ON (its background fetch is part of what is timed), aimed at a port
# that refuses at once, so the test never touches the network.
export GOV_UPDATE_VERSION_URL="http://127.0.0.1:9/VERSION"
unset GOV_SESSION_ID GOV_DRY_RUN GOVERNANCE_UPDATE_CHECK GOV_AUTO_UPDATE GOV_FIND_PRINTF 2>/dev/null || true

PROJ="$SANDBOX/proj"; mkdir -p "$PROJ/docs/context" "$PROJ/Plans"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false   # no CRLF warnings in the output
( cd "$PROJ" && git init -q . && git config user.email t@t && git config user.name t \
  && printf '# m\ncanonical_working_copy: %s\n' "$PROJ" > docs/context/CONTEXT-MANIFEST.md \
  && printf '# plan\n' > Plans/PLAN.md && printf -- '---\nstatus: active\n---\n# h\n' > docs/context/HANDOFF.md \
  && printf '# mem\n' > docs/context/MEMORY.md && git add -A && git commit -q -m init )
cd "$PROJ" || exit 1

S="$HOME/.claude/logs/sessions"
seed() {   # the shapes found on the owner's machine, repeated to N_DIRS; all 2 h old
  rm -rf "$S"; mkdir -p "$S"
  local i d
  for i in $(seq 1 "$N_DIRS"); do
    d="$S/seed-$i"; mkdir -p "$d"
    case $((i % 4)) in
      0) : > "$d/.gov-session-dirty"; printf 'abc 2026 x sid=seed-%s\n' "$i" > "$d/.gov-session-start" ;;
      1) mkdir -p "$d/file-shas" && : > "$d/file-shas/a" && : > "$d/.gov-session-closed" && : > "$d/.gov-session-changes" ;;
      2) : ;;   # an empty dir
      3) printf 'x\n' > "$d/close-report.md" ;;
    esac
  done
  find "$S" -mindepth 1 -exec touch -d '2 hours ago' {} + 2>/dev/null
}
payload() { printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$1" "$PROJ"; }

echo "[1] registered SessionStart timeouts: pre-session <= 10, others <= 15 (the VS Code extension waits 60 s for ALL of start-up)"
LINES=""
if [ -z "$TEMPLATE" ]; then
  fail "settings-hooks.json not found (set GOV_SS_TEMPLATE)"
elif command -v node >/dev/null 2>&1; then
  _tpl="$TEMPLATE"; command -v cygpath >/dev/null 2>&1 && _tpl="$(cygpath -m "$TEMPLATE")"
  LINES=$(node -e '
    const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    for (const g of (t.hooks.SessionStart || [])) for (const h of (g.hooks || [])) console.log((h.timeout ?? "none") + "\t" + h.command);
  ' "$_tpl" 2>/dev/null)
  [ -n "$LINES" ] && ok "template lists $(printf '%s\n' "$LINES" | grep -c .) SessionStart hooks" || fail "no SessionStart hooks read from $TEMPLATE"
  while IFS="$(printf '\t')" read -r to cmd; do
    [ -z "$cmd" ] && continue
    case "$to" in (*[!0-9]*|"") fail "$(basename "$cmd"): timeout '$to' is not a number" ;;
      # pre-session.sh: 10, never more (owner, 2026-09-26). The others: 15, the ceiling they already
      # had — each one registered is a hook that can hold start-up, and the extension's 60 s is for all.
      (*) _cap=15; case "$cmd" in *pre-session.sh*) _cap=10 ;; esac
          if [ "$to" -le "$_cap" ]; then ok "$(basename "$cmd"): timeout $to <= $_cap"; else fail "$(basename "$cmd"): timeout $to > $_cap"; fi ;; esac
  done <<EOF
$LINES
EOF
else
  fail "node missing - cannot read $TEMPLATE"
fi

echo "[2] each SessionStart hook with $N_DIRS other session dirs, stdout piped through cat, < ${BUDGET_MS} ms"
seed
while IFS="$(printf '\t')" read -r to cmd; do
  [ -z "$cmd" ] && continue
  f="$H/$(basename "${cmd%% *}")"
  [ -f "$f" ] || { fail "$(basename "$f") not found beside the hooks"; continue; }
  # Median of 3: one run landing on a burst of load is noise; a median over the budget is a hook that
  # a loaded machine will kill at its timeout at real session starts.
  _r=""
  for _i in 1 2 3; do
    t0=$(ms); payload "budget-$RANDOM" | _bounded bash "$f" 2>&1 | cat >/dev/null; _r="$_r$(( $(ms) - t0 ))"$'\n'
  done
  dt=$(printf '%s' "$_r" | sort -n | sed -n 2p)
  if [ "$dt" -lt "$BUDGET_MS" ]; then ok "$(basename "$f"): median ${dt} ms"; else fail "$(basename "$f"): median ${dt} ms >= ${BUDGET_MS} ms (runs: $(printf '%s' "$_r" | tr '\n' ' '))"; fi
done <<EOF
$LINES
EOF

echo "[2b] pre-session.sh time does not grow with the number of session dirs (0 vs 200)"
_ps_time() {   # median of 3 runs, ms
  local a b c
  a=$(ms); payload "g-$RANDOM" | bash "$H/pre-session.sh" 2>&1 | cat >/dev/null; a=$(( $(ms) - a ))
  b=$(ms); payload "g-$RANDOM" | bash "$H/pre-session.sh" 2>&1 | cat >/dev/null; b=$(( $(ms) - b ))
  c=$(ms); payload "g-$RANDOM" | bash "$H/pre-session.sh" 2>&1 | cat >/dev/null; c=$(( $(ms) - c ))
  printf '%s\n%s\n%s\n' "$a" "$b" "$c" | sort -n | sed -n 2p
}
_keep_n="$N_DIRS"
N_DIRS=0; seed; _t0=$(_ps_time)
N_DIRS=200; seed; _t200=$(_ps_time)
N_DIRS="$_keep_n"
_g=$(( _t200 - _t0 ))
if [ "$_g" -lt "$GROWTH_MS" ]; then ok "0 dirs ${_t0} ms, 200 dirs ${_t200} ms: +${_g} ms"; else fail "0 dirs ${_t0} ms, 200 dirs ${_t200} ms: +${_g} ms >= ${GROWTH_MS} ms (per-dir forks are back)"; fi

semantics() {   # $1 = label; the scan's meaning, on whichever find path is active
  local lbl="$1" OUT rc _leak
  echo "[3$lbl] the scan keeps its meaning (live, crash, prune, odd names)"
  N_DIRS=8 seed
  rm -f "$HOME"/.claude/logs/.gov-crashed-session-* 2>/dev/null
  mkdir -p "$S/live-1" "$S/crash-1" "$S/stale-1" "$S/stale-empty"
  printf 'a\nb\n\nc\n' > "$S/crash-1/.gov-session-changes"
  : > "$S/live-1/.gov-session-start"
  printf 'x\n' > "$S/stale-1/close-report.md"
  find "$S/crash-1" -exec touch -d '8 hours ago' {} + 2>/dev/null
  find "$S/stale-1" "$S/stale-empty" -exec touch -d '20 days ago' {} + 2>/dev/null
  OUT=$(payload "me-1" | bash "$H/pre-session.sh" 2>&1)
  printf '%s' "$OUT" | grep -q "PARALLEL SESSION" && ok "$lbl live dir reported as parallel" || fail "$lbl live dir not reported as parallel"
  printf '%s' "$OUT" | grep -q "session live…" && ok "$lbl parallel hint names the live session" || fail "$lbl parallel hint lacks the live session: $(printf '%s' "$OUT" | grep -m1 PARALLEL)"
  # With a live session present too, the crash is reported inside the PARALLEL line (pre-session.sh).
  printf '%s' "$OUT" | grep -q "CRASH RECOVERY\|crashed session was archived" && ok "$lbl silent dir with changes reported as crash" || fail "$lbl crash not reported"
  ls "$HOME/.claude/logs/.gov-crashed-session-crash-1-"*.log >/dev/null 2>&1 && ok "$lbl crash archived" || fail "$lbl crash archive missing"
  [ "$(cat "$HOME"/.claude/logs/.gov-crashed-session-crash-1-*.log 2>/dev/null | grep -c .)" = "3" ] && ok "$lbl archive holds the 3 non-empty change lines" || fail "$lbl archive line count wrong"
  [ -f "$S/crash-1/.gov-session-closed" ] && ok "$lbl crash dir marked closed" || fail "$lbl crash dir not closed"
  [ ! -s "$S/crash-1/.gov-session-changes" ] && ok "$lbl crash change log emptied" || fail "$lbl crash change log not emptied"
  [ ! -e "$S/stale-1" ] && ok "$lbl dir untouched for 20 days pruned" || fail "$lbl stale dir survived the prune"
  [ ! -e "$S/stale-empty" ] && ok "$lbl empty dir untouched for 20 days pruned" || fail "$lbl stale empty dir survived"
  [ -d "$S/seed-1" ] && [ -d "$S/seed-2" ] && [ -d "$S/live-1" ] && ok "$lbl recent dirs (incl. an empty one) kept" || fail "$lbl a recent dir was pruned"
  _leak=$(printf '%s\n' "$OUT" | grep -c "session seed\|crashed-session-seed")
  [ "$_leak" = "0" ] && ok "$lbl 2 h old seed dirs are neither parallel nor crash" || fail "$lbl seed dirs leaked into the report ($_leak lines)"
  mkdir -p "$S/odd name" && : > "$S/odd name/.gov-session-start"
  OUT=$(payload "me-2" | bash "$H/pre-session.sh" 2>&1); rc=$?
  [ "$rc" = "0" ] && ok "$lbl pre-session rc=0 with a dir name holding a space" || fail "$lbl pre-session rc=$rc"
  printf '%s' "$OUT" | grep -q "session odd name" && ok "$lbl that dir reported as parallel with its full name" || fail "$lbl odd dir not reported: $(printf '%s' "$OUT" | grep -m1 PARALLEL)"
}
semantics ""
# The per-dir loop kept for a find without -printf must mean the same thing. Run with GNU find here,
# this proves its meaning, not BSD behaviour (on BSD it reads every age as 0: see _common.sh).
GOV_FIND_PRINTF=0; export GOV_FIND_PRINTF
semantics " [loop path]"
unset GOV_FIND_PRINTF

echo "[5] the updater is REPORTED at session start, never run (2026-09-26)"
U="$HOME/.claude/.governance-update"; mkdir -p "$U"
rm -rf "$S"; mkdir -p "$S"
# An apply in progress (its pid alive) vs one that died mid-swap.
printf 'version=9.9.9\nfrom=1.0.0\npid=%s\n' "$$" > "$U/APPLYING"
OUT=$(payload "me-5" | bash "$H/pre-session.sh" 2>&1)
printf '%s' "$OUT" | grep -q "being applied right now (pid $$)" && ok "live apply pid: reported as in progress" || fail "live apply pid not reported: $(printf '%s' "$OUT" | grep -m1 'GOVERNANCE UPDATE')"
printf '%s' "$OUT" | grep -q "INTERRUPTED" && fail "  live apply pid wrongly called INTERRUPTED" || ok "  and not called interrupted"
_dead=$(bash -c 'echo $$'); sleep 0.2
printf 'version=9.9.9\nfrom=1.0.0\npid=%s\n' "$_dead" > "$U/APPLYING"
OUT=$(payload "me-5" | GOVERNANCE_UPDATE_CHECK=0 bash "$H/pre-session.sh" 2>&1)
printf '%s' "$OUT" | grep -q "was INTERRUPTED while being applied" && ok "dead apply pid: INTERRUPTED reported, even with the update check off" || fail "interrupted apply not reported: $(printf '%s' "$OUT" | grep -m1 'GOVERNANCE UPDATE')"
[ -f "$U/APPLYING" ] && ok "  the hook restored nothing itself (journal kept)" || fail "  the hook removed the journal"
rm -f "$U/APPLYING"
printf 'version=9.9.9 staged\n' > "$U/READY"
t0=$(ms); OUT=$(payload "me-5" | bash "$H/pre-session.sh" 2>&1); dt=$(( $(ms) - t0 ))
printf '%s' "$OUT" | grep -q "v9.9.9 is downloaded and its signature verified, but it is NOT applied at session start" && ok "READY: one line naming the version (${dt} ms)" || fail "READY not reported: $(printf '%s' "$OUT" | grep -m1 'GOVERNANCE UPDATE')"
printf '%s' "$OUT" | grep -q "gov-update.sh --apply --force-live" && ok "  with the command that actually applies" || fail "  apply command missing"
OUT=$(payload "me-5" | GOV_AUTO_UPDATE=0 bash "$H/pre-session.sh" 2>&1)
printf '%s' "$OUT" | grep -q "is downloaded and its signature verified" && fail "GOV_AUTO_UPDATE=0 (env) still shows the READY line" || ok "GOV_AUTO_UPDATE=0 (env): READY line silent"
printf 'GOV_AUTO_UPDATE="0"\n' > "$HOME/.claude/.governance-local.env"
OUT=$(payload "me-5" | bash "$H/pre-session.sh" 2>&1)
printf '%s' "$OUT" | grep -q "is downloaded and its signature verified" && fail "GOV_AUTO_UPDATE=0 (local env file) still shows the READY line" || ok "GOV_AUTO_UPDATE=0 (local env file): READY line silent"
rm -f "$HOME/.claude/.governance-local.env" "$U/READY"

echo "[6] gov_dirty_snapshot: same lines as the per-path loop it replaced, in constant processes"
# Expected output recorded from the pre-2026-09-26 loop on this exact fixture (byte-identical then).
R="$SANDBOX/dirty"; mkdir -p "$R"
( cd "$R" && git init -q . && git config user.email t@t && git config user.name t && git config core.autocrlf false \
  && printf 'a\n' > mod.txt && printf 'b\n' > del.txt && printf 'c\n' > ren-src.txt && printf 'x\n' > total \
  && printf 'y\n' > "sp ace.txt" && mkdir -p sub && printf 'z\n' > sub/k.txt && git add -A && git commit -qm i \
  && printf 'aaaa\n' >> mod.txt && rm del.txt && git mv ren-src.txt ren-dst.txt && printf 'more\n' >> total \
  && printf 'q\n' >> "sp ace.txt" && printf 'new\n' > untracked.txt && mkdir -p newdir/deep emptydir \
  && printf '12345\n' > newdir/a && printf '1\n' > newdir/deep/b && printf 'w\n' > sub/k.txt ) >/dev/null 2>&1
_exp=$(printf ' D\t-\tdel.txt\n M\t7\tmod.txt\nR \t2\tren-dst.txt\n M\t-\t"sp ace.txt"\n M\t2\tsub/k.txt\n M\t7\ttotal\n??\t8\tnewdir/\n??\t4\tuntracked.txt')
_got=$(bash -c '. "$1/_common.sh" </dev/null >/dev/null 2>&1; gov_dirty_snapshot "$2"' _ "$H" "$R" </dev/null)
[ "$_got" = "$_exp" ] && ok "8 entries (modified, deleted, renamed, quoted, nested, 'total', untracked dir + file) match" \
  || { fail "gov_dirty_snapshot output differs"; printf '%s\n' "$_got" | sed 's/^/       got | /'; }
_got=$(bash -c '. "$1/_common.sh" </dev/null >/dev/null 2>&1; gov_dirty_snapshot "$2"' _ "$H" "$SANDBOX" </dev/null)
[ -z "$_got" ] && ok "not a git repo: no output" || fail "non-repo produced output: $_got"

printf '\npass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
