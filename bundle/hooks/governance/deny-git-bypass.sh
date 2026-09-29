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
CMD="$(printf '%s' "$PAYLOAD" | timeout 5 python -c 'import json,sys
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

# (0) DESTRUCTIVE git (2026-09-29, HITL-removal board, CEO condition 5). Once canonical writes and
# the close push run unattended, "never force-push" and "never reset --hard" can no longer rest on
# prose: the session that would do it is the one nobody is watching. Blocked: a push that rewrites
# or deletes remote history (--force, --force-with-lease, --force-if-includes, -f in a short-flag
# cluster, a +refspec, --delete, a :ref deletion refspec, --mirror, --prune) and `reset --hard`.
# Anchored to the git SEGMENT: `[^;&|]*` stops at the next command separator, so `rm -f x && git
# push` is allowed and so is a later `; rm -f x`. The override is the owner's, not the model's: hooks
# read Claude Code's environment, so GOV_GIT_DESTRUCTIVE_OK=1 typed into a command does nothing -
# the owner sets it in settings.json "env", or runs the command himself in his own terminal.
# COST: bash's own [[ =~ ]], no grep. This guard runs on EVERY Bash/PowerShell call; the first
# version used three `printf | grep` forks and, measured interleaved under full CPU load, put +1.6 s
# on the median `git push` (6724 -> 8344 ms). A glob prefilter skips everything that does not
# contain both words, so an ordinary command pays one `case`. A newline counts as a separator, like
# ; & | - bash regex spans lines where grep did not.
_dz_candidate=0
case "$CMD" in *[Gg][Ii][Tt]*[Pp][Uu][Ss][Hh]*|*[Gg][Ii][Tt]*[Rr][Ee][Ss][Ee][Tt]*|*[Ss][Ee][Nn][Dd]-[Pp][Aa][Cc][Kk]*) _dz_candidate=1 ;; esac
# A backslash-newline (bash) or backtick-newline (PowerShell) continuation joins two lines into ONE
# command; the patterns below treat a newline as a separator, so join them first (final review).
_DZ="$CMD"
_DZ="${_DZ//\\$'\r\n'/ }"; _DZ="${_DZ//\\$'\n'/ }"
_DZ="${_DZ//\`$'\r\n'/ }"; _DZ="${_DZ//\`$'\n'/ }"
if [ "$_dz_candidate" = 1 ] && [ "${GOV_GIT_DESTRUCTIVE_OK:-0}" != "1" ]; then
  # Review round 1 (zero-context verifier, 2026-09-29) measured real deletes and forced updates
  # getting through the first patterns, so they now also cover: `-d` (short --delete) in a short-flag
  # cluster; git's unambiguous ABBREVIATED long options (`--del`, `--force-w`, `--m` - the only push
  # option starting with m is --mirror, and round 2 measured `--m` deleting remote branches -
  # `--pru`, `reset --h`). The shortest unambiguous prefix is covered for each: `--for` (not `--fo`:
  # --follow-tags), `--de` (not `--d`: --dry-run), `--m`, `--pru` (not `--pr`: --progress), `--h`; quoted option values with spaces (`-C "C:/My Projects/x"`, `-c user.name="a b"`);
  # quoted refspecs (`"+main"`, `':old'`); and `git.exe`. Still a regex over a string, not a shell
  # parser: an alias, a variable holding the flag, or a wrapper script is out of its reach.
  _nl=$'\n'
  _ns="[^;&|${_nl}]"                                    # any char inside ONE command segment
  _q1='"[^"]*"'; _q2="'[^']*'"
  _plain="[^[:space:];&|\"'${_nl}]"
  _esc='\\.'                                            # a backslash-escaped char (`My\ Projects`)
  _tok="(${_esc}|${_plain}|${_q1}|${_q2})+"             # one shell word, quoted/escaped parts allowed
  _val="(${_esc}|[^-[:space:];&|\"'${_nl}\\]|${_q1}|${_q2})(${_esc}|${_plain}|${_q1}|${_q2})*"
  _gopt="([[:space:]]+-${_tok}([[:space:]]+${_val})?)*"
  _gpre="(^|[^A-Za-z0-9_.-])git(\\.exe)?[\"']?${_gopt}[[:space:]]+"
  _re_force="${_gpre}push([[:space:]]${_ns}*)?[[:space:]][\"']?(--for[a-z-]*|--de[a-z]*|--m[a-z]*|--pru[a-z]*|-[A-Za-z]*[fd][A-Za-z]*)([\"'=[:space:]]|\$)"
  # A refspec starting with + (force) or : (delete), whatever follows: `+@:main`, `+"main"`,
  # `:"old"`, `+{main,dev}` (final review).
  _re_spec="${_gpre}push([[:space:]]${_ns}*)?[[:space:]][\"']?[+:][^[:space:];&|${_nl}]"
  # --h, --ha, --har, --hard - but not --help (a harmless read, final review).
  _re_reset="${_gpre}reset([[:space:]]${_ns}*)?[[:space:]][\"']?--h(a(r(d)?)?)?([\"'[:space:]]|\$)"
  _re_sendpack="${_gpre}send-pack([[:space:]]${_ns}*)?[[:space:]](--force|-f)([[:space:]]|\$)"
  # Config injected inline (review round 3): `git -c remote.origin.mirror=true push` deletes remote
  # branches, `-c remote.origin.push=+refs/...` force-pushes - with no flag after `push` at all.
  # Round 4: `-c remote.origin.mirror` with NO `=` means true, `--config-env=remote.X.mirror=VAR` and
  # the GIT_CONFIG_KEY_<n> / GIT_CONFIG_PARAMETERS environment forms do the same. Any mention of a
  # remote.*.mirror or remote.*.push key in the same segment as a `push` is blocked.
  _re_cfg="(-c[[:space:]]*|--config-env[=[:space:]]*|GIT_CONFIG_[A-Z_0-9]*=)[\"']*remote\\.${_ns}*\\.(mirror|push)([^A-Za-z0-9_-]${_ns}*)?[^A-Za-z0-9_.-]push([[:space:]]|\$)"
  _dz=""
  shopt -s nocasematch
  if   [[ $_DZ =~ $_re_force ]]; then _dz="git push that rewrites or deletes remote history"
  elif [[ $_DZ =~ $_re_spec  ]]; then _dz="git push with a force (+ref) or delete (:ref) refspec"
  elif [[ $_DZ =~ $_re_reset ]]; then _dz="git reset --hard"
  elif [[ $_DZ =~ $_re_cfg   ]]; then _dz="git push with an inline remote.*.mirror / remote.*.push config"
  elif [[ $_DZ =~ $_re_sendpack ]]; then _dz="git send-pack --force"
  fi
  shopt -u nocasematch
  if [ -n "$_dz" ]; then
    echo "[deny-git-bypass] BLOCKED: destructive git - $_dz." >&2
    echo "  Force-push, remote deletes and reset --hard keep their HUMAN approval: they destroy history" >&2
    echo "  nobody can get back. Do the non-destructive thing instead (a normal push after fetch + rebase," >&2
    echo "  git stash / git restore -- <path>), or report to the owner and stop." >&2
    echo "  Owner-only override: GOV_GIT_DESTRUCTIVE_OK=1 in ~/.claude/settings.json \"env\"." >&2
    exit 2
  fi
fi

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
