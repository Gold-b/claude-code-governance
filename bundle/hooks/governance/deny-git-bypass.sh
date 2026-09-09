#!/usr/bin/env bash
# PreToolUse (Bash|PowerShell) guard — deny hook-bypass flags around git push / gh pr create.
# Fable review #3 (PR #10 follow-up). The committed pre-push CI gate and commit hooks can be
# skipped with `git push --no-verify`, `git -c core.hooksPath=/dev/null push`, `HUSKY=0`, or a
# policed env token placed inline (GOVERNANCE_HOOKS=0 / NO_LOCAL_COMPUTE=0). The sibling
# no-local-compute.sh matches only the Bash tool, so every one of those was still reachable via
# the PowerShell tool. This guard matches BOTH tools. Exit 2 = block (the model sees the reason).
#
# Scope: blocks ONLY when a bypass token appears in a command that ALSO runs one of the
# hook-bearing actions: git push / git commit / git merge / gh pr create|merge. Wiring the hook
# (`git config core.hooksPath .githooks`, which has no `=`) and all non-push commands are untouched.
#
# Deliberate: this guard does NOT honor GOVERNANCE_HOOKS=0 as a disable, because that token is one
# of the bypasses it polices — honoring it would let the guard be switched off by the very thing it
# guards against. The owner's dedicated override is the env switch DENY_GIT_BYPASS=0.
#
# STATED LIMIT (found within minutes of registering it, 2026-09-09): this is a regex over the whole
# command string, so a command that merely MENTIONS a policed token next to a hook-bearing action
# verb - an echo, a printf building a test fixture, a grep for the pattern - is blocked exactly like
# a real bypass. It failed in the safe direction (a false block, loud, with the override named) and
# it stays that way on purpose: telling "mentions" from "runs" means parsing arbitrary shell, and an
# unreliable gate gets switched off. Put such text in a file and reference the file instead.
set -u
[ "${DENY_GIT_BYPASS:-1}" = "0" ] && exit 0

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

# (a) Does the command run a hook-bearing git/gh action? If not, do not interfere.
printf '%s' "$CMD" | grep -qiE '\bgit\b[^;&|]*\b(push|commit|merge)\b|\bgh\b[[:space:]]+pr[[:space:]]+(create|merge)\b' || exit 0

# (a2) ADVISORY, never a block: this guard stops an EXPLICIT bypass flag. It cannot stop the case
# where the git hooks are simply not wired - a fresh clone never gets them (git does not copy
# hooks), so `git push` with no flag at all runs no pre-push scan and this guard, seeing no flag,
# stays silent. Found on a fresh clone 2026-09-07: `core.hooksPath` was empty. So, when the repo
# SHIPS hooks (a tracked .githooks/ dir) but they are not wired, say so - loudly, on stderr, once
# per command - and let the command proceed. Warning here, not blocking, because a repo may
# legitimately keep .githooks/ for consumers who wire it themselves; the wiring is one command.
if [ -d .githooks ] && [ "$(git config --get core.hooksPath 2>/dev/null)" != ".githooks" ]; then
  echo "[deny-git-bypass] WARNING: this repo ships git hooks in .githooks/ but core.hooksPath is not set," >&2
  echo "  so NO pre-commit / pre-push scan will run for this command. A fresh clone never wires them." >&2
  echo "  Wire once:  git config core.hooksPath .githooks" >&2
fi

# (b) Does it also carry a hook-bypass token?
if printf '%s' "$CMD" | grep -qiE '(--no-verify|-c[[:space:]]+core\.hookspath[[:space:]]*=|HUSKY=0|HUSKY_SKIP_HOOKS=1|GOVERNANCE_HOOKS=0|NO_LOCAL_COMPUTE=0)'; then
  echo "[deny-git-bypass] BLOCKED: this git push/commit/merge/PR command carries a hook-bypass flag." >&2
  echo "  Policed: --no-verify, -c core.hooksPath=, HUSKY=0, GOVERNANCE_HOOKS=0, NO_LOCAL_COMPUTE=0." >&2
  echo "  The committed pre-push CI gate (npm run ci:local) and commit hooks MUST run — remove the" >&2
  echo "  bypass and run the command normally. Genuine override (owner only): set DENY_GIT_BYPASS=0." >&2
  exit 2
fi
exit 0
