#!/usr/bin/env bash
# bootstrap-gate.sh — REAL enforcement of "run /bootstrapper before acting" (2026-09-28).
#
# WHY. pre-task.sh only INJECTS text ("You MUST run /bootstrapper"). Ignoring it cost nothing, and
# on 2026-09-28 a governed session did exactly that: it ran /context-governance lite, skipped
# /bootstrapper, and sent the owner a status (chat + WhatsApp) with a figure its own HANDOFF,
# OPEN-PROBLEMS and memory had already corrected. Text is advice; this is the gate.
#
# WHY IT CANNOT DEADLOCK (the reason pre-task.sh never blocks). The earlier design asked the LLM to
# `touch` a marker; the LLM forgot and every prompt was blocked. Here the LLM never writes the proof:
#   * the MARKER is written by the HARNESS - this script in `--mark` mode, registered as a
#     PostToolUse hook on the `Skill` tool - when tool_input.skill is `bootstrapper` (a plugin- or
#     directory-prefixed `x:bootstrapper`, or a leading `/`, is accepted);
#   * fallback on the would-block path: the session transcript already records a Skill(bootstrapper)
#     tool_use, or a user-typed `/bootstrapper` slash command (which never goes through the Skill
#     tool). Only harness-written JSON shapes match - escaped text inside tool output cannot;
#   * the gate NEVER blocks Skill or Agent (they are not in its matcher) nor any read, so the one
#     action that clears it is always available.
#
# Marker: ~/.claude/logs/sessions/<session_id>/.gov-bootstrapper-ran — the same per-session
# directory _common.sh's gov_state_file uses (the test asserts parity). NOT .gov-session-bootstrapped:
# pre-task.sh auto-creates that one on the first prompt, so it proves nothing.
#
# WHAT IS GATED (marker missing, governed SOURCE project):
#   Edit / Write / MultiEdit / NotebookEdit;
#   Bash / PowerShell commands that: send WhatsApp (send.js, wa-send, wa_send); git commit / push;
#   scp / rsync; systemctl start|stop|restart|reload|enable|disable|kill|mask|...; docker [compose]
#   up|down|restart|stop|start|kill|rm. The command string is scanned whole, so the same verbs inside
#   an `ssh host '...'` remote command are caught, and a plain `ssh host 'cat /x'` passes.
# NOT gated: Read/Grep/Glob, git status/log/diff/fetch, plain shell, Skill, Agent. Local writes via
#   shell redirection (`>`, sed -i, Set-Content) are deliberately out of scope - gating every shell
#   write would fire on ordinary work (CLAUDE.md "measure a control... cost when WRONG").
#
# SUBAGENTS share the parent's session_id, so they are gated by the PARENT's bootstrap: a subagent
# of a session that bootstrapped passes; one of a session that did not is told to run the skill
# (running it from inside the subagent also clears the gate for the whole session). Accepted.
#
# FAIL MODES. Internal errors fail OPEN with a logged warning (payload not a JSON object, no
# session_id, no tool_name, bootstrapper skill not installed): a gate that crashes must not freeze
# all work. The normal "marker missing" path fails CLOSED (exit 2).
#
# COST. Pure bash, no python/jq, no _common.sh: sourcing _common.sh alone measured ~500 ms here
# (its stdin priming forks), and the reads this gate lets through must stay cheap. The allow path
# forks nothing except `cat` for payloads > 4 KB (bash `read` on a pipe is byte-wise: 1 s / 150 KB),
# and no `$( )` at all. Bench: tests/bench-bootstrap-gate.sh [--load].
#
# Scope: governed projects only (docs/context/CONTEXT-MANIFEST.md at the project root, resolved from
# CLAUDE_PROJECT_DIR, else the payload cwd walked up to the nearest CLAUDE.md/manifest), SOURCE role
# only (mirrors pre-task.sh's gov_role_guard SOURCE).
# Kill switches: GOVERNANCE_HOOKS=0 (all governance hooks), GOV_BOOTSTRAP_GATE=0 (this gate only).
#   Hooks inherit Claude Code's environment, not the Bash tool's shell: an `export` typed by the
#   model does not reach this script. The owner sets them in ~/.claude/settings.json "env".
#
# Usage (registered in ~/.claude/settings.json, user level only):
#   PreToolUse  matcher Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell -> bootstrap-gate.sh
#   PostToolUse matcher Skill                                              -> bootstrap-gate.sh --mark
# Tests: tests/test-bootstrap-gate.sh
set +e

GATE_MODE=gate
[ "${1:-}" = "--mark" ] && GATE_MODE=mark

_bg_log() {
  local log="${GOVERNANCE_LOG:-$HOME/.claude/logs/governance.log}" ts msg="$1"
  case "$log" in "$HOME/.claude/"*) ;; *) log="$HOME/.claude/logs/governance.log" ;; esac
  [ -L "$log" ] && return 0
  msg="${msg//[$'\n\r']/ }"
  printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1 2>/dev/null
  printf '[%s] [bootstrap-gate] %s\n' "$ts" "$msg" >> "$log" 2>/dev/null
  return 0
}

# ── Kill switches (checked before stdin is read) ─────────────────────────────
if [ "${GOVERNANCE_HOOKS:-1}" = "0" ]; then
  [ "${GOV_BYPASS_QUIET:-0}" = "1" ] || echo "[governance] GOVERNANCE_HOOKS=0 — governance hooks are DISABLED; bypassing bootstrap-gate. (silence this notice with GOV_BYPASS_QUIET=1)" >&2
  exit 0
fi
[ "${GOV_BOOTSTRAP_GATE:-1}" = "0" ] && exit 0

# ── Read the payload: first 4 KB with the builtin (no fork), the rest with one `cat` ──
_in=""
if [ ! -t 0 ]; then
  IFS= read -r -N 4096 _in
  [ "${#_in}" -ge 4096 ] && _in+="$(cat)"
fi

# Sanity: must look like a JSON object. Anything else is an internal error -> fail OPEN.
_head="${_in:0:64}"; _tail="$_in"; [ "${#_in}" -gt 64 ] && _tail="${_in: -64}"
if ! [[ $_head =~ ^[[:space:]]*\{ ]] || ! [[ $_tail =~ \}[[:space:]]*$ ]]; then
  _bg_log "WARNING: payload is not a JSON object (${#_in} chars) - failing OPEN ($GATE_MODE)"
  exit 0
fi

_re_str='"((\\.|[^"\\])*)"'
_jfield() {  # _jfield <key> -> sets _JF to the first "key":"value" (raw, JSON-escaped) in $_in.
  # Sets a variable instead of printing: a `$(...)` is a fork, ~40-50 ms each on MSYS.
  local re="\"$1\"[[:space:]]*:[[:space:]]*$_re_str"
  _JF=""; [[ $_in =~ $re ]] && _JF="${BASH_REMATCH[1]}"
}
# Escaped text inside tool_input (`\"session_id\":`) cannot match these patterns: the key's closing
# quote would be preceded by a backslash.
_tool=""; _re="\"tool_name\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_.:-]*)\""
[[ $_in =~ $_re ]] && _tool="${BASH_REMATCH[1]}"
if [ -n "${GOV_SESSION_ID:-}" ]; then
  _sid="$GOV_SESSION_ID"
else
  _sid=""; _re="\"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
  [[ $_in =~ $_re ]] && _sid="${BASH_REMATCH[1]}"
fi
_sid="${_sid//[^A-Za-z0-9._-]/}"

if [ -z "$_tool" ]; then
  _bg_log "WARNING: no tool_name in payload - failing OPEN ($GATE_MODE)"
  exit 0
fi
if [ -z "$_sid" ]; then
  # Without an id there is no per-session place for the proof; the legacy shared ~/.claude/logs
  # would leak one session's bootstrap to every other session. Fail OPEN, loudly in the log.
  _bg_log "WARNING: no session_id in payload - failing OPEN ($GATE_MODE, tool=$_tool)"
  exit 0
fi

_state_dir="$HOME/.claude/logs/sessions/$_sid"
MARKER="$_state_dir/.gov-bootstrapper-ran"

_write_marker() {  # _write_marker <how>
  [ -d "$_state_dir" ] || mkdir -p "$_state_dir" 2>/dev/null
  local ts; printf -v ts '%(%Y-%m-%dT%H:%M:%S)T' -1 2>/dev/null
  printf '%s %s\n' "$ts" "$1" > "$MARKER" 2>/dev/null
  if [ -f "$MARKER" ]; then _bg_log "marker written ($1) sid=$_sid"
  else _bg_log "WARNING: could not write marker $MARKER ($1)"; fi
}

# ════ --mark : PostToolUse on the Skill tool ════════════════════════════════
if [ "$GATE_MODE" = "mark" ]; then
  [ "$_tool" = "Skill" ] || exit 0
  case "$_in" in *bootstrapper*) ;; *) exit 0 ;; esac   # cheap glob before any regex
  _jfield skill; _skill="$_JF"
  _skill="${_skill#/}"; _skill="${_skill##*:}"
  [ "$_skill" = "bootstrapper" ] && _write_marker "PostToolUse Skill(bootstrapper)"
  exit 0
fi

# ════ gate : PreToolUse ═════════════════════════════════════════════════════
# 1. Classify the action. Anything not mutating passes before any filesystem work.
_what=""
case "$_tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    _what="$_tool" ;;
  Bash|PowerShell)
    # Cheap glob prefilter: no keyword anywhere in the payload -> nothing to classify.
    case "$_in" in *send.js*|*wa-send*|*wa_send*|*git*|*scp*|*rsync*|*systemctl*|*docker*) ;; *) exit 0 ;; esac
    _jfield command; _cmd="$_JF"
    [ -n "$_cmd" ] || exit 0
    _B='(^|[^A-Za-z0-9_.-])'          # word start
    _E='([^A-Za-z0-9_-]|$)'           # word end
    _OPT='([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*'   # -C dir / --flag
    _re_wa='(send\.js|wa-send|wa_send)'
    _re_git="${_B}git${_OPT}[[:space:]]+(commit|push)${_E}"
    _re_copy="${_B}(scp|rsync)[[:space:]]"
    _re_sysd="${_B}systemctl([[:space:]]+-[^[:space:]]+)*[[:space:]]+(start|stop|restart|try-restart|reload|reload-or-restart|enable|disable|kill|mask|unmask|daemon-reload|isolate)${_E}"
    _re_dock="${_B}docker(-compose|[[:space:]]+compose)?${_OPT}[[:space:]]+(up|down|restart|stop|start|kill|rm)${_E}"
    if   [[ $_cmd =~ $_re_wa   ]]; then _what="WhatsApp send"
    elif [[ $_cmd =~ $_re_git  ]]; then _what="git ${BASH_REMATCH[4]}"
    elif [[ $_cmd =~ $_re_copy ]]; then _what="${BASH_REMATCH[2]}"
    elif [[ $_cmd =~ $_re_sysd ]]; then _what="systemctl ${BASH_REMATCH[3]}"
    elif [[ $_cmd =~ $_re_dock ]]; then _what="docker ${BASH_REMATCH[5]}"
    fi
    [ -n "$_what" ] || exit 0 ;;
  *)
    exit 0 ;;
esac

# 2. Proof already on disk -> pass (the hot path for every mutating call after bootstrap).
[ -f "$MARKER" ] && exit 0

# 3. Governed SOURCE project? Resolve the root without forks.
_root="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$_root" ]; then
  _jfield cwd; _root="$_JF"
  _root="${_root//\\\\//}"
fi
_root="${_root//\\//}"; _root="${_root%/}"
_p="$_root"; _found=""
while [ -n "$_p" ] && [ "$_p" != "." ]; do
  if [ -f "$_p/docs/context/CONTEXT-MANIFEST.md" ] || [ -f "$_p/CLAUDE.md" ]; then _found="$_p"; break; fi
  case "$_p" in */*) _n="${_p%/*}" ;; *) _n="" ;; esac
  [ "$_n" = "$_p" ] && break
  _p="$_n"
done
[ -n "$_found" ] && [ -f "$_found/docs/context/CONTEXT-MANIFEST.md" ] || exit 0

if [ "${GOV_ROLE_FRAMEWORK:-1}" != "0" ]; then
  _role=""
  if [ -f "$_found/.governance-role" ]; then
    IFS= read -r _role < "$_found/.governance-role"; _role="${_role//[[:space:]]/}"
  fi
  case "$_role" in
    SOURCE) ;;
    DEPLOYMENT|FROZEN) exit 0 ;;
    # -e, not -d: a git worktree (and a submodule) holds a `.git` FILE. Same inference as
    # gov_detect_role (CTO/QA board condition 4, 2026-09-29).
    *) [ -e "$_found/.git" ] || exit 0 ;;
  esac
fi

# 4. Cannot comply if the skill is not installed -> fail OPEN (no deadlock by construction).
_skills="${GOVERNANCE_SKILLS_DIR:-$HOME/.claude/skills}"
if [ ! -f "$_skills/bootstrapper/SKILL.md" ]; then
  _bg_log "WARNING: bootstrapper skill not installed under $_skills - failing OPEN (would have blocked $_what)"
  exit 0
fi

# 5. Transcript fallback: a Skill(bootstrapper) tool_use the PostToolUse hook missed, or a user-typed
#    /bootstrapper (slash commands do not go through the Skill tool). Harness-written JSON shapes only.
_jfield transcript_path; _tp="$_JF";_tp="${_tp//\\\\//}"
if [ -n "$_tp" ] && [ -f "$_tp" ] && grep -qF \
     -e '"name":"Skill","input":{"skill":"bootstrapper"' \
     -e '"role":"user","content":"<command-message>bootstrapper</command-message>' "$_tp" 2>/dev/null; then
  _write_marker "transcript fallback"
  exit 0
fi

# 6. Block.
_bg_log "BLOCK $_what (tool=$_tool) sid=$_sid root=$_found - bootstrapper has not run"
cat >&2 <<EOF
[GOVERNANCE BOOTSTRAP GATE] BLOCKED: $_what — the /bootstrapper skill has not run in this session.
This is a governed project ($_found). Invoke the Skill tool with skill "bootstrapper" NOW, read its
briefing (HANDOFF / PLAN / OPEN-PROBLEMS / memory), then retry this action. Reads, Skill and Agent
are never blocked. The harness records the run itself - do not create any marker by hand.
[שער ממשל] נחסם: עוד לא הורץ /bootstrapper בסשן הזה. הפעל עכשיו את הכלי Skill עם "bootstrapper",
קרא את התדריך, ואז נסה שוב. קריאות לא נחסמות.
Owner-only bypass: GOV_BOOTSTRAP_GATE=0 in ~/.claude/settings.json "env".
EOF
exit 2
