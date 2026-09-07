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
[ -z "$CMD" ] && exit 0
ROOT="$(pwd)"
MARK=""
while [ -n "$ROOT" ] && [ "$ROOT" != "/" ]; do
  if [ -f "$ROOT/.remote-compute" ]; then MARK="$ROOT/.remote-compute"; break; fi
  ROOT="$(dirname "$ROOT")"
done
[ -z "$MARK" ] && exit 0
SERVERS="$(grep -vE '^\s*#|^\s*$' "$MARK" | tr '\n' ' ')"
if printf '%s' "$CMD" | grep -qE '^\s*(ssh|scp)\b' ; then
  # scp from a server's data/research dir to a local path = a local data pull -> block
  if printf '%s' "$CMD" | grep -qE 'scp .*@[^ ]+:[^ ]*/(var/lib|research)[^ ]* +("?\$HOME|~|/c/|[A-Za-z]:|\.)' ; then
    echo "[no-local-compute] BLOCKED: pulling server data to the PC. Process it on the server and bring back only the report. Servers: $SERVERS" >&2
    exit 2
  fi
  exit 0
fi
# .claude/hooks/governance/* are governance plumbing, NOT project compute. Blocking them once
# deadlocked a session: governance-guard demanded a re-issued success token, and the only way to
# issue one is a local governance script this hook refused to run (2026-09-06, owner approved).
if printf '%s' "$CMD" | grep -qE '(^|[;&| /])(commit-task-success|end-session|pre-session|pre-task|post-milestone|governance-guard|close-completeness|check-full-finish)\.sh\b' ; then
  exit 0
fi
if printf '%s' "$CMD" | grep -qE 'pytest|--selftest|unittest|ast\.parse|py_compile|bash -n|^\s*(git|gh|ls|cat|grep|sed|awk|head|tail|wc|du|rm|mkdir|cp|mv|echo|date|stat|find|diff|node [^ ]*send\.js|timeout [0-9]+ bash )' ; then
  exit 0
fi
if printf '%s' "$CMD" | grep -qE '(^|[;&| ])(python[0-9.]*|node|bash|sh)\s+[^ ]*(tools/|strategies/|scripts/|\.py\b|\.js\b|\.sh\b)' ; then
  echo "[no-local-compute] BLOCKED: this project runs scripts ONLY on its remote servers (owner rule 2026-09-06). Allowed locally: pytest / --selftest / syntax checks / git / ssh. Re-route to: $SERVERS" >&2
  exit 2
fi
exit 0
