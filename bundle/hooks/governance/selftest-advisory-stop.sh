#!/usr/bin/env bash
# selftest-advisory-stop.sh — makes governance-selftest.sh actually RUN on a cadence, and
# puts its verdict somewhere a human sees, WITHOUT charging a session close ~2 minutes.
#
# THE CADENCE PROBLEM, AND THE CHOICE MADE
# ----------------------------------------
# governance-selftest.sh costs ~118 s: it builds a sandbox, executes every registered hook in
# both directions, then MUTATES each hook and re-executes to prove the assertions can go red.
# Its own header says, correctly, that wiring it to an event "makes every session pay". A
# 2-minute blocking Stop hook gets switched off inside a week, and a switched-off control is
# how controls die. But leaving it unwired is how it got here: the framework's whole failure
# was admission-by-existence, and a diagnostic nobody runs is a file, not a control.
#
# So the run and the report are SPLIT:
#
#   * REPORT — synchronous, every Stop, ~0.3 s: read the verdict of the LAST completed run and,
#     if it is red (or if a launched run never finished), print a banner on stderr and exit 1.
#     Stop treats a non-zero, non-2 exit as a non-blocking error and SURFACES THE STDERR, so
#     the human sees red without the session being blocked. It nags every close until fixed.
#   * RUN — asynchronous and throttled: at most once per GOV_SELFTEST_INTERVAL_HOURS (default
#     6), the Stop hook launches the selftest DETACHED (nohup) and returns immediately. The
#     session close pays ~0.3 s, never 118 s. Detached survival was measured on this machine
#     2026-09-01: a nohup child wrote its output 7 s after its parent had exited.
#
# The cost of the split is latency: a regression introduced now is reported at a session close
# up to ~6 h later, not instantly. That is the right trade for a whole-framework mutation
# audit — the INSTANT gate is pii-gate-pretooluse.sh, which blocks at the write boundary. Cheap
# and blocking at the boundary; expensive and advisory behind it.
#
# WHY IT REFUSES TO SAY A BARE "GREEN"
# ------------------------------------
# governance-selftest.sh part (b) audits ONE project, named by GOV_SELFTEST_PROJECT. That
# variable is NOT set on this machine, and when it is unset the script's own header warns that
# part (b) "does not fail loudly — its checks go SKIP/NOT-FOUND and the suite can still print a
# green-looking tail". Reporting that as GREEN would reproduce the exact defect this whole
# exercise exists to kill. So the verdict is read back out of the run's own log: a pass with an
# unconfigured project root is recorded and reported as GREEN-PARTIAL, never GREEN.
#
# This hook is deliberately NEVER able to exit 2. It does not block a session close: the audit
# is broad, slow and machine-wide, and a broad slow check with veto power over "stop working"
# is the thing that gets ripped out. Its teeth are that it will not go quiet: red persists in
# the result file and is re-announced at every single close until a run comes back clean.
#
# MODES
#   (no args)   hook mode — report + maybe launch. Always fast. Exit 0 (quiet) or 1 (red).
#   --run       worker mode — the actual 118 s run. Invoked detached; also runnable by hand.
#   --status    print the current recorded state and exit 0. For humans.
#   --force     launch a run now even if the throttle says no (detached), then exit.
#
# KILL SWITCHES
#   GOV_SELFTEST_HOOK=0     disable this wrapper entirely (report and launch both)
#   GOV_SELFTEST_NAG=0      keep launching + recording, but never exit 1 (silence the banner)
#   GOVERNANCE_HOOKS=0      disable the whole governance hook family
#
# ENV
#   GOV_SELFTEST_INTERVAL_HOURS   throttle interval, default 6
#   GOV_SELFTEST_STALE_MIN        a run holding the lock this long is presumed dead, default 45
set +e

LOGDIR="${GOV_SELFTEST_LOGDIR:-$HOME/.claude/logs}"
RESULT="$LOGDIR/governance-selftest.result"
RUNLOG="$LOGDIR/governance-selftest.log"
LAUNCHED="$LOGDIR/governance-selftest.launched"
LOCK="$LOGDIR/governance-selftest.lock"
SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
SUITE="$(dirname "$SELF")/governance-selftest.sh"
INTERVAL_H="${GOV_SELFTEST_INTERVAL_HOURS:-6}"
STALE_MIN="${GOV_SELFTEST_STALE_MIN:-45}"

now() { date +%s; }

# --------------------------------------------------------------------------------------------
# Worker: the real run. Holds a mkdir lock so two sessions closing together cannot both start
# a 118 s sandbox build.
# --------------------------------------------------------------------------------------------
do_run() {
  mkdir -p "$LOGDIR" 2>/dev/null
  if ! mkdir "$LOCK" 2>/dev/null; then
    exit 0   # another run holds it; the hook side is what reaps a stale lock
  fi
  printf '%s\n%s\n' "$$" "$(now)" > "$LOCK/owner" 2>/dev/null
  trap 'rm -rf "$LOCK" 2>/dev/null' EXIT

  start="$(now)"
  # cd to HOME on purpose: with GOV_SELFTEST_PROJECT unset the suite falls back to walking UP
  # from $PWD for a docs/context/CONTEXT-MANIFEST.md, and a detached job inheriting a session's
  # cwd would then silently audit whatever repo that session happened to be parked in --
  # including a retired duplicate. Better to audit nothing and SAY SO than to audit the wrong
  # tree and call it fact.
  cd "$HOME" 2>/dev/null
  GOV_NOTIFY=0 GOV_WHATSAPP=0 GOV_SELFTEST_NO_WRITE=1 \
    bash "$SUITE" > "$RUNLOG" 2>&1
  rc=$?
  end="$(now)"

  tail_line="$(grep -a '^\[governance-selftest\] ' "$RUNLOG" 2>/dev/null | tail -1)"
  [ -n "$tail_line" ] || tail_line="[governance-selftest] (no summary line — the run did not reach its own tail)"

  # Read the project root back out of the RUN'S OWN LOG rather than re-deriving it here.
  proj="$(grep -a '^  project:  ' "$RUNLOG" 2>/dev/null | tail -1 | sed 's/^  project:  //')"
  partial=0
  case "$proj" in ""|*"(unset:"*) partial=1 ;; esac
  [ -d "$proj" ] || partial=1

  case "$rc" in
    0) verdict="GREEN" ;;
    1) verdict="RED" ;;
    *) verdict="ERROR" ;;
  esac
  [ "$verdict" = "GREEN" ] && [ "$partial" = "1" ] && verdict="GREEN-PARTIAL"

  tmp="$RESULT.tmp.$$"
  {
    printf 'verdict=%s\n' "$verdict"
    printf 'rc=%s\n' "$rc"
    printf 'finished=%s\n' "$end"
    printf 'seconds=%s\n' "$(( end - start ))"
    printf 'project=%s\n' "${proj:-<none>}"
    printf 'summary=%s\n' "$tail_line"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$RESULT" 2>/dev/null
  exit 0
}

launch() {
  mkdir -p "$LOGDIR" 2>/dev/null
  now > "$LAUNCHED" 2>/dev/null
  nohup bash "$SELF" --run >/dev/null 2>&1 &
  disown 2>/dev/null
  return 0
}

read_field() { grep -a "^$1=" "$RESULT" 2>/dev/null | tail -1 | sed "s/^$1=//"; }

print_status() {
  if [ -f "$RESULT" ]; then
    v="$(read_field verdict)"; f="$(read_field finished)"; s="$(read_field summary)"
    p="$(read_field project)"; secs="$(read_field seconds)"
    age="?"; [ -n "$f" ] && age="$(( ( $(now) - f ) / 60 ))"
    printf 'governance-selftest: %s (finished %s min ago, took %ss)\n' "${v:-?}" "$age" "${secs:-?}"
    printf '  %s\n' "$s"
    printf '  project audited by part B: %s\n' "${p:-<none>}"
    printf '  full log: %s\n' "$RUNLOG"
  else
    printf 'governance-selftest: no run has completed yet.\n'
    printf '  it is launched in the background at most once per %sh from the Stop hook.\n' "$INTERVAL_H"
  fi
  if [ -d "$LOCK" ]; then
    printf '  a run is IN PROGRESS (lock: %s)\n' "$LOCK"
  fi
}

case "${1:-}" in
  --run)    do_run ;;
  --status) print_status; exit 0 ;;
  --force)  launch; echo "governance-selftest: launched in the background; check with --status"; exit 0 ;;
  "")       : ;;
  *)        echo "usage: $(basename "$0") [--run|--status|--force]" >&2; exit 1 ;;
esac

# --------------------------------------------------------------------------------------------
# Hook mode. Must stay well under a second.
# --------------------------------------------------------------------------------------------
[ "${GOV_SELFTEST_HOOK:-1}" = "0" ] && exit 0
if [ "${GOVERNANCE_HOOKS:-1}" = "0" ]; then [ "${GOV_BYPASS_QUIET:-0}" = "1" ] || echo "[governance] GOVERNANCE_HOOKS=0 — bypassing selftest-advisory. (GOV_BYPASS_QUIET=1 to mute)" >&2; exit 0; fi
cat >/dev/null 2>&1   # drain the Stop payload; we do not need any field from it

mkdir -p "$LOGDIR" 2>/dev/null
NOW="$(now)"
BANNER=""

# A lock older than STALE_MIN means a launched run died (killed with the terminal, machine
# slept, sandbox blew up). Reap it and SAY so — a run that silently never finishes is the same
# invisible failure as a hook that silently never fires.
if [ -d "$LOCK" ]; then
  started="$(sed -n 2p "$LOCK/owner" 2>/dev/null)"
  case "$started" in
    ''|*[!0-9]*) started=0 ;;
  esac
  if [ "$started" -gt 0 ] && [ $(( NOW - started )) -gt $(( STALE_MIN * 60 )) ]; then
    rm -rf "$LOCK" 2>/dev/null
    BANNER="${BANNER}governance-selftest: the previous background run never finished (started $(( (NOW-started)/60 )) min ago) and has been reaped. The framework is UNVERIFIED since then.
"
  fi
fi

# Throttle.
LAST=0
[ -f "$LAUNCHED" ] && LAST="$(cat "$LAUNCHED" 2>/dev/null)"
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
if [ ! -d "$LOCK" ] && [ $(( NOW - LAST )) -ge $(( INTERVAL_H * 3600 )) ]; then
  launch
fi

# Report the last completed run.
if [ -f "$RESULT" ]; then
  V="$(read_field verdict)"
  case "$V" in
    RED|ERROR)
      BANNER="${BANNER}governance-selftest: $V — the framework failed its own execution audit.
  $(read_field summary)
  finished $(( ( NOW - $(read_field finished) ) / 60 )) min ago · full log: $RUNLOG
  Hooks that FAIL or are UNCOVERED are not controls. Read the log before trusting any of them.
"
      ;;
    GREEN-PARTIAL)
      BANNER="${BANNER}governance-selftest: GREEN-PARTIAL — hook execution and mutation passed, but the
  countable-claims audit (part B) had no project root, so it verified NOTHING and its
  green is not evidence. Set GOV_SELFTEST_PROJECT in ~/.claude/.governance-local.env.
  $(read_field summary) · log: $RUNLOG
"
      ;;
  esac
fi

if [ -n "$BANNER" ] && [ "${GOV_SELFTEST_NAG:-1}" != "0" ]; then
  printf '%s' "$BANNER" >&2
  echo "  (silence this: GOV_SELFTEST_NAG=0 · disable entirely: GOV_SELFTEST_HOOK=0 · run now: $SELF --force)" >&2
  exit 1
fi
exit 0
