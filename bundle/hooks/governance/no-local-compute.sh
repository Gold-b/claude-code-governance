#!/usr/bin/env bash
# PreToolUse (Bash) guard — owner rule 2026-09-06: project scripts do NOT run on the owner's PC; they
# run on the project's remote servers. Active only in projects that carry a `.remote-compute` marker at
# the root; the marker lists the servers and their roles (one per line: <role> <user@host> <purpose>),
# so this hook stays generic and publishable. It blocks local execution of project scripts and local
# data pulls; it allows unit tests, self-tests, syntax checks, git, ssh/scp to a server, notification
# sends, and tiny `python -c` probes. Exit 2 = block (the model sees the reason and re-routes).
# Kill switch: GOVERNANCE_HOOKS=0 or NO_LOCAL_COMPUTE=0.
set -u
[ "${GOVERNANCE_HOOKS:-1}" = "0" ] && exit 0
[ "${NO_LOCAL_COMPUTE:-1}" = "0" ] && exit 0
PAYLOAD="$(cat 2>/dev/null || true)"
CMD="$(printf '%s' "$PAYLOAD" | python -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("tool_input",{}).get("command",""))
except Exception: print("")' 2>/dev/null)"
# NO SILENT FAIL-OPEN (2026-09-09). With no python on PATH the line above yields "" and the old
# next line exited 0 - the guard simply switched itself off, for that user, forever, with no
# message. Measured: rc=0 on a no-python PATH, rc=2 with python. Same class as the B1 incident
# (parser missing => gate open). Framework pattern from pii-gate-pretooluse.sh: try a fallback,
# then announce MALFUNCTION loudly and exit 1 (advisory-open), never exit 0 in silence and never
# exit 2 (blocking every shell command on a python-less machine gets the hook disabled).
if [ -z "$CMD" ] && ! command -v python >/dev/null 2>&1; then
  # Fallback tier: pull the command string out of the JSON without python. No backslashes in
  # this pattern on purpose (gotcha #359): it stops at the first inner quote, which is fine for
  # a guard that only needs to SEE its tokens, and if it yields nothing we say so below.
  CMD="$(printf '%s' "$PAYLOAD" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/^"command"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  if [ -z "$CMD" ]; then
    echo "[$(basename "$0" .sh)] MALFUNCTION - no python on PATH and the fallback could not read the command. Guard is OPEN for this call." >&2
    exit 1
  fi
fi
[ -z "$CMD" ] && exit 0
# STATED LIMIT (2026-09-07, hit within an hour of arming this): the marker search starts at the
# shell's CURRENT directory, which PreToolUse sees BEFORE any `cd` inside the command itself. So
#     cd /some/unmarked/project && ./build.sh
# issued from a MARKED project is judged as still being inside the marked one, and is blocked.
# It fails in the SAFE direction (a false block, never a false allow) and it is loud, so it is a
# stated limit rather than a bug to paper over: guessing which `cd` in an arbitrary shell command
# will win is exactly the kind of parsing that makes a gate unreliable. Work around it by moving
# the shell first, in its own call, and then running the command.
ROOT="$(pwd)"
MARK=""
while [ -n "$ROOT" ] && [ "$ROOT" != "/" ]; do
  if [ -f "$ROOT/.remote-compute" ]; then MARK="$ROOT/.remote-compute"; break; fi
  ROOT="$(dirname "$ROOT")"
done
[ -z "$MARK" ] && exit 0
SERVERS="$(grep -vE '^\s*#|^\s*$' "$MARK" | tr '\n' ' ')"
# PER-SEGMENT EVALUATION (2026-09-14). This replaces three whole-string tests that ran in sequence,
# and it closes a real bypass in this guard. The allow test used to be an OR over the ENTIRE command
# string with most alternatives unanchored, and it ran BEFORE the deny test, so any harmless-looking
# token anywhere in the line excused everything else on it:
#     python tools/backfill.py && bash -n /dev/null     -> matched `bash -n`,   whole command allowed
#     ssh box && python tools/backfill.py               -> matched `^\s*ssh`,   whole command allowed
# An allow-list satisfied by any substring anywhere is not a guard. The command is now split on shell
# separators and EVERY segment is judged on its own: ONE segment of project compute blocks the whole
# command, whatever the other segments look like, and an allow token excuses only the segment it sits
# in. Order inside a segment preserves the original semantics exactly - data-pull first (it must beat
# the ssh/scp allowance), then allow, then deny.
# The split is deliberately naive about quoting, and that is the SAFE direction: a separator inside a
# quoted string yields extra segments, and an extra segment can only ever cause a false BLOCK, never
# a false ALLOW. Same stance as the `cd` limit stated above - fail toward refusing.
ALLOW_GOV='(^|[;&| /])(commit-task-success|end-session|pre-session|pre-task|post-milestone|governance-guard|close-completeness|check-full-finish)\.sh\b'
# `hooks/governance/` is allowed by INTENT, not as an exception: this hook exists to stop PROJECT
# compute, and a governance hook is not project compute - it lives in ~/.claude, reads the repo, and
# writes only to logs and governance docs. Naming scripts one at a time was the wrong shape; it took
# two rounds (governance-selftest.sh on 2026-09-13, close-report.sh at a session close on 2026-09-14)
# to see that the category, not the filename, is what belongs here.
ALLOW_GEN='pytest|--selftest|hooks/governance/|unittest|ast\.parse|py_compile|bash -n|^[[:space:]]*(ssh|scp)\b|^[[:space:]]*(git|gh|ls|cat|grep|sed|awk|head|tail|wc|du|rm|mkdir|cp|mv|echo|date|stat|find|diff|node [^ ]*send\.js|timeout [0-9]+ bash )'
DENY_PULL='scp .*@[^ ]+:[^ ]*/(var/lib|research)[^ ]* +("?\$HOME|~|/c/|[A-Za-z]:|\.)'
DENY_COMPUTE='(^|[;&| ])(python[0-9.]*|node|bash|sh)[[:space:]]+[^ ]*(tools/|strategies/|scripts/|\.py\b|\.js\b|\.sh\b)'

# The while loop reads from a HERE-DOC, not a pipe, so it runs in THIS shell and `exit 2` really
# exits. A `cmd | while ...` here would block nothing at all: the exit would leave the subshell only.
while IFS= read -r SEG; do
  case "$SEG" in *[![:space:]]*) ;; *) continue ;; esac
  if printf '%s' "$SEG" | grep -qE "$DENY_PULL" ; then
    echo "[no-local-compute] BLOCKED: pulling server data to the PC. Process it on the server and bring back only the report. Servers: $SERVERS" >&2
    exit 2
  fi
  printf '%s' "$SEG" | grep -qE "$ALLOW_GOV" && continue
  printf '%s' "$SEG" | grep -qE "$ALLOW_GEN" && continue
  if printf '%s' "$SEG" | grep -qE "$DENY_COMPUTE" ; then
    echo "[no-local-compute] BLOCKED: this project runs scripts ONLY on its remote servers (owner rule 2026-09-06). Allowed locally: pytest / --selftest / syntax checks / git / ssh. The block is per-segment, so adding an allowed command to this line will NOT unlock it. Re-route to: $SERVERS" >&2
    exit 2
  fi
done <<SEGMENTS
$(printf '%s' "$CMD" | tr ';&|' '\n\n\n')
SEGMENTS
exit 0
