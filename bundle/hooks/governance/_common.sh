#!/usr/bin/env bash
# _common.sh — Context Governance hook shared utilities
# Created: 2026-04-11 (Phase 4 of Context Governance rollout)
# Master Plan §8 — sourced by all governance hook scripts in this directory.
#
# Behavior contract:
#   * Exit code rules (HARD RULE — 2026-04-13 deadlock incident):
#     - UserPromptSubmit hooks: NEVER exit 2. Exit 2 blocks ALL responses,
#       creating an unrecoverable deadlock. Use exit 0 + warning instead.
#     - PreToolUse hooks: exit 2 is OK (blocks one tool, LLM can adapt).
#       BUT prefer exit 0 + warning unless the action is truly destructive.
#     - Stop hooks: exit 2 is OK (prevents premature session end).
#     - Infrastructure errors (log write, path parse) → fail-soft (exit 0).
#   * Idempotent. Running the same hook twice in a row produces the same result.
#   * Skill-aware. If the corresponding skill is not yet installed (Phase 5
#     deferred), the hook logs the skip and exits 0.
#   * Kill switch: GOVERNANCE_HOOKS=0 disables ALL hooks globally.
#
# Environment variables:
#   GOVERNANCE_HOOKS         (default: 1)   set to "0" to disable all governance hooks globally
#   GOVERNANCE_LOG           (default: ~/.claude/logs/governance.log) path of the rolling hook log
#   GOVERNANCE_SKILLS_DIR    (default: ~/.claude/skills) where to look for skill definitions

GOVERNANCE_LOG="${GOVERNANCE_LOG:-$HOME/.claude/logs/governance.log}"
GOVERNANCE_HOOKS="${GOVERNANCE_HOOKS:-1}"
GOVERNANCE_SKILLS_DIR="${GOVERNANCE_SKILLS_DIR:-$HOME/.claude/skills}"

# Security: validate log path stays under ~/.claude/ to prevent path injection via env var
case "$GOVERNANCE_LOG" in
  "$HOME/.claude/"*) ;; # OK
  *) GOVERNANCE_LOG="$HOME/.claude/logs/governance.log" ;;
esac

# Ensure log dir exists. Failure here is non-fatal — we still try to run.
mkdir -p "$(dirname "$GOVERNANCE_LOG")" 2>/dev/null || true

# gov_log <hook_name> <message>
# Appends a timestamped line to the governance log. Never throws.
# Sanitizes message to prevent log injection (strips newlines/control chars).
gov_log() {
  local hook="$1"
  local msg
  msg=$(printf '%s' "$2" | tr -d '\n\r' | tr -cd '[:print:]')
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown-time")
  # Refuse to write if log is a symlink
  [ -L "$GOVERNANCE_LOG" ] && return 0
  echo "[$ts] [$hook] $msg" >> "$GOVERNANCE_LOG" 2>/dev/null || true
}

# gov_disabled
# Returns 0 (success) if governance hooks are globally disabled (GOVERNANCE_HOOKS=0).
# Use as: `gov_disabled && exit 0`
gov_disabled() {
  if [ "$GOVERNANCE_HOOKS" = "0" ]; then
    return 0
  fi
  return 1
}

# gov_skill_exists <skill_name>
# Returns 0 (success) if the named skill is installed at $GOVERNANCE_SKILLS_DIR/<skill_name>/SKILL.md
gov_skill_exists() {
  local skill="$1"
  if [ -d "$GOVERNANCE_SKILLS_DIR/$skill" ] && [ -f "$GOVERNANCE_SKILLS_DIR/$skill/SKILL.md" ]; then
    return 0
  fi
  return 1
}

# gov_phase_state
# Echoes a one-word state describing what Phase 4 vs Phase 5 should expect.
# Used for diagnostic logging.
gov_phase_state() {
  if gov_skill_exists "context-governance"; then
    echo "phase5+"
  else
    echo "phase4-plumbing"
  fi
}

# ============================================================================
# Node-Role Framework v2 (2026-04-21)
# ----------------------------------------------------------------------------
# Every governance operation knows which node-role it runs on:
#   SOURCE     — source-of-truth repo (has .git with canonical remote).
#                All writes allowed. Full enforcement.
#   DEPLOYMENT — deployment target (no .git, or .git without canonical remote).
#                version.json is a receipt, not SSOT. Hooks run in passive mode.
#                Governance writes blocked; /full-finish refuses to run.
#   FROZEN     — pinned production (e.g., a version-pinned client install). Hooks exit silently.
#                No governance writes at all.
#
# Detection priority:
#   1. .governance-role file at project root (explicit, wins)
#   2. Fallback: has .git → SOURCE, else → DEPLOYMENT
#      (FROZEN cannot be inferred — must be explicitly declared)
#
# Kill switch: GOV_ROLE_FRAMEWORK=0 to disable role-awareness globally
#   (hooks revert to pre-v2 behavior — treating every node as SOURCE).
# ============================================================================

GOV_ROLE_FRAMEWORK="${GOV_ROLE_FRAMEWORK:-1}"

# gov_find_project_root
# Walk up from CWD to find directory containing CLAUDE.md. Echoes path.
# Falls back to CWD if not found.
gov_find_project_root() {
  local d="$PWD"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ -f "$d/CLAUDE.md" ]; then
      echo "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  echo "$PWD"
}

# gov_payload_root
# The project this hook invocation is ABOUT, taken from the hook payload rather than from $PWD.
#
# WHY THIS EXISTS (bug found 2026-08-17, proven by isolation test). Hooks decided "is this a
# governed project?" with a RELATIVE test - `[ ! -f "docs/context/CONTEXT-MANIFEST.md" ]` - which
# asks about the hook process's current directory, not about the project the edit belongs to. The
# payload carries an absolute `file_path` AND a `cwd`, and both were ignored. So whenever a session
# ran shell commands from somewhere outside its project root (running a test suite from a skills
# directory is enough), post-milestone.sh exited 0 and the write was DROPPED from the session
# change log - silently, with the edit itself succeeding.
#
# The visible symptom was a false BLOCK at close ("HANDOFF.md was not refreshed" when it had been).
# The dangerous direction is the opposite one: the same omission under-counts SESSION_WRITES, and
# end-session.sh only fires at >= 3, so a session could close with NO handoff and the gate would
# stay quiet. A clean close and a lost one look identical from outside.
#
# `$PWD`-walking is NOT a safe fallback on its own either: from `~/.claude/skills/<x>` the upward
# walk finds the USER-LEVEL `~/.claude/CLAUDE.md` and happily reports it as "the project".
#
# Order: payload `cwd` -> the edited file's own directory (walked up to a CLAUDE.md) -> $PWD walk.
# Takes the payload TEXT as $1. It must not call gov_hook_input itself: this function is used
# inside `$(...)`, and a subshell that reads stdin consumes the payload while its cache assignment
# is discarded - so the hook's own later read came back empty and every write was dropped. Caller
# reads stdin once, then passes the string down.
gov_payload_root() {
  local input="$1" root p

  if [ -n "$input" ] && command -v python3 >/dev/null 2>&1; then
    root=$(printf '%s' "$input" | python3 -c "
import sys, json, os
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
cwd = d.get('cwd') or ''
if not cwd:
    p = (d.get('tool_input') or {}).get('file_path') or d.get('file_path') or ''
    if p:
        cwd = os.path.dirname(p)
print(cwd)
" 2>/dev/null)
  fi

  # Regex fallback, mirroring the extraction the rest of this hook family already uses: python may
  # be absent, and a payload that fails strict JSON parsing must still not silently degrade into
  # "use $PWD" - that is the very failure this function exists to end.
  if [ -z "$root" ] && [ -n "$input" ]; then
    root=$(printf '%s' "$input" | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//')
    [ -z "$root" ] && root=$(printf '%s' "$input" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//')
  fi

  # Normalise a Windows payload path ('C:\a\b') to the MSYS form this shell can stat ('/c/a/b').
  if [ -n "$root" ]; then
    root=$(printf '%s' "$root" | tr '\\' '/')
    case "$root" in
      [A-Za-z]:/*) root="/$(printf '%s' "${root%%:*}" | tr 'A-Z' 'a-z')/${root#*:/}" ;;
    esac
    # Walk up to the nearest CLAUDE.md so a file_path deep inside the tree still resolves.
    # `dirname` is a FIXED POINT on '.', '/' and bare drive roots - it keeps returning its own
    # input, so a loop that only tests for '/' never terminates. Stop as soon as it stops moving.
    p="$root"
    while [ -n "$p" ] && [ "$p" != "/" ] && [ "$p" != "." ]; do
      if [ -f "$p/CLAUDE.md" ] || [ -f "$p/docs/context/CONTEXT-MANIFEST.md" ]; then
        echo "$p"; return 0
      fi
      next="$(dirname "$p")"
      [ "$next" = "$p" ] && break
      p="$next"
    done
    [ -d "$root" ] && { echo "$root"; return 0; }
  fi

  gov_find_project_root
}

# gov_prime_payload
# Read stdin ONCE, publish it to every subshell, and resolve the project root from it.
#
# WHY (2026-08-17). Two things bite any hook that does not do this, and they compound:
#   1. stdin can be consumed once. `gov_state_file`/`gov_session_id` call `gov_hook_input` from
#      inside `$( )`, so the payload is read and DISCARDED in that subshell - the parent's cache
#      never gets set, and every later read returns empty. A hook can therefore look like it has
#      no payload while having been handed a perfectly good one.
#   2. Any decision that then falls back to `$PWD` is wrong from inside `~/.claude/**`, where the
#      upward walk finds the USER-LEVEL CLAUDE.md and calls it "the project".
# Exporting the cache variables is what makes (1) safe: subshells inherit them, so `gov_hook_input`
# returns the cached string instead of trying to read a stream that is already drained.
#
# Call this at the TOP of a hook, before anything branches. Sets GOV_PROJECT_ROOT.
gov_prime_payload() {
  _GOV_HOOK_INPUT="$(gov_hook_input)"
  _GOV_HOOK_INPUT_READ=1
  export _GOV_HOOK_INPUT _GOV_HOOK_INPUT_READ
  GOV_PROJECT_ROOT="$(gov_payload_root "$_GOV_HOOK_INPUT")"
  export GOV_PROJECT_ROOT
}

# gov_is_governed <root>
# True when <root> carries the governance manifest. Replaces the bare relative
# `[ ! -f "docs/context/CONTEXT-MANIFEST.md" ]` test in every hook that gates on it.
gov_is_governed() {
  local root="${1:-$PWD}"
  [ -f "$root/docs/context/CONTEXT-MANIFEST.md" ]
}

# gov_dirty_snapshot <project_root>
# Echoes one line per dirty working-tree entry: "<status><TAB><size><TAB><path>".
#
# WHY IT IS SHARED (bug fixed 2026-07-27): close-completeness.sh decides what a session
# changed from `git diff <start-sha> HEAD` PLUS `git status --porcelain`. The porcelain half
# also reports leftovers from a PREVIOUS session — a crashed session leaves untracked
# artifacts behind — so a read-only session got blocked for "changing code" it never touched,
# and would have stayed blocked on every future session until someone cleaned the tree by
# hand. That is the exact inverse of this hook's own rule: a session that changed no code
# owes nothing. pre-session.sh baselines this at start and close-completeness.sh subtracts it.
#
# Both callers MUST derive the snapshot from this one function: if the two sides formatted a
# line differently the subtraction would silently match nothing and the block would return.
# Size (not mtime, which this hook family deliberately never trusts) is what makes a
# pre-existing file that got edited AGAIN this session still count as this session's work.
gov_dirty_snapshot() {
  local root="$1" line st p sz
  [ -n "$root" ] && [ -d "$root/.git" ] || return 0
  ( cd "$root" 2>/dev/null || exit 0
    git status --porcelain 2>/dev/null | while IFS= read -r line; do
      st=$(printf '%s' "$line" | cut -c1-2)
      # Same normalisation close-completeness.sh applies: strip the status column, and for a
      # rename keep the destination path.
      p=$(printf '%s' "$line" | sed 's/^...//' | sed 's/.* -> //' | sed 's#\\#/#g')
      [ -z "$p" ] && continue
      # A DELETED path has no bytes to read. Guard on existence rather than letting the stat
      # fail: an unreadable path still yields "-" so the comparison stays correct, but the
      # failure would print to stderr on every session - the same log-noise defect already on
      # record for the notifier's marker path.
      if [ -d "$p" ]; then
        # An untracked DIRECTORY is reported as a single entry; total its bytes so a new file
        # appearing inside it changes the size and is not masked by the parent's baseline.
        sz=$(find "$p" -type f -exec wc -c {} \; 2>/dev/null | awk '{s+=$1} END{print s+0}')
      elif [ -f "$p" ]; then
        sz=$(wc -c < "$p" 2>/dev/null | tr -d ' ')
      else
        sz="-"
      fi
      [ -z "$sz" ] && sz="-"
      printf '%s\t%s\t%s\n' "$st" "$sz" "$p"
    done )
}

# gov_detect_role [project_root]
# Echoes: SOURCE | DEPLOYMENT | FROZEN
# Reads .governance-role file first; falls back to .git presence.
gov_detect_role() {
  # GOV_PROJECT_ROOT lets a hook that already resolved the project from its PAYLOAD hand that root
  # in, instead of this falling back to a $PWD walk. That walk is not merely imprecise, it is
  # actively wrong from inside `~/.claude/**`: it finds the USER-LEVEL `~/.claude/CLAUDE.md`,
  # calls it the project, sees no `.git` beside it and reports DEPLOYMENT - so `gov_role_guard
  # SOURCE` silently skipped every write a session made while its shell sat there (2026-08-17).
  local root="${1:-${GOV_PROJECT_ROOT:-$(gov_find_project_root)}}"

  # Kill switch — always behave as SOURCE (backward compat)
  if [ "$GOV_ROLE_FRAMEWORK" = "0" ]; then
    echo "SOURCE"
    return 0
  fi

  # Priority 1: explicit declaration
  if [ -f "$root/.governance-role" ]; then
    local declared
    declared=$(head -n 1 "$root/.governance-role" 2>/dev/null | tr -d '[:space:]')
    case "$declared" in
      SOURCE|DEPLOYMENT|FROZEN)
        echo "$declared"
        return 0
        ;;
    esac
  fi

  # Priority 2: infer from .git (FROZEN cannot be inferred)
  if [ -d "$root/.git" ]; then
    echo "SOURCE"
  else
    echo "DEPLOYMENT"
  fi
}

# gov_role_is <role>
# Returns 0 if current project role matches the argument.
# Usage: gov_role_is SOURCE && do_source_stuff
gov_role_is() {
  local want="$1"
  local have
  have=$(gov_detect_role)
  [ "$have" = "$want" ]
}

# gov_role_guard <allowed-roles...>
# If current role is NOT in the allowed list, logs and exits 0 (passive skip).
# Usage in hooks:
#   gov_role_guard SOURCE  # this hook only runs on SOURCE
# Exports GOV_CURRENT_ROLE for downstream use.
gov_role_guard() {
  local current
  current=$(gov_detect_role)
  export GOV_CURRENT_ROLE="$current"
  for allowed in "$@"; do
    if [ "$allowed" = "$current" ]; then
      return 0
    fi
  done
  # Not allowed — passive skip (exit 0, log only)
  gov_log "role-guard" "skip: current=$current allowed=$*"
  exit 0
}

# gov_send_whatsapp <message> [trigger_key]
# Sends a WhatsApp message via the local OpenClaw gateway to the configured
# user phone number. Rate-limited per trigger_key (1 per 5 minutes) to prevent
# floods. Fail-soft — never throws. Runs async.
#
# Token discovery: openclaw.json gateway.auth.password (under $HOME/.openclaw/)
# Phone fallback: 972500000000 (a documented placeholder; the real number belongs in the
# machine-local config, never in this file)
#
# Kill switch: GOV_WHATSAPP=0 disables WhatsApp sends globally.
gov_send_whatsapp() {
  local msg="$1"
  local trigger_key="${2:-default}"

  [ "${GOV_WHATSAPP:-1}" = "0" ] && return 0
  command -v node >/dev/null 2>&1 || return 0

  # Rate limit: per trigger_key, max 1 message per 5 minutes
  # Sanitise: trigger_key carries things like "/live-state-orchestrator", and an unescaped
  # slash turns the marker into a path under a directory that does not exist, so every
  # notification printed a "No such file or directory" line to stderr.
  local marker="$HOME/.claude/logs/.gov-wa-$(printf '%s' "$trigger_key" | tr -c 'A-Za-z0-9._-' '_').last"
  local now last
  now=$(date +%s 2>/dev/null || echo 0)
  last=0
  [ -f "$marker" ] && last=$(cat "$marker" 2>/dev/null || echo 0)
  if [ "$now" -gt 0 ] && [ $((now - last)) -lt 300 ]; then
    return 0  # rate limited — silent skip
  fi

  # Resolve helper script path (same dir as this _common.sh)
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  local helper="$script_dir/wa-send.js"
  [ ! -f "$helper" ] && return 0

  # Mark sent BEFORE the send — prevents bursts if delivery is slow
  [ "$now" -gt 0 ] && echo "$now" > "$marker" 2>/dev/null

  # Delegate to node helper — UTF-8-safe, RTL-aware, right-aligned for Hebrew.
  # Pass the FULL message (no truncation here — node handles UTF-8 properly).
  # Prepend [GOVERNANCE] header in node side via WA_MESSAGE.
  local body="[GOVERNANCE]
${msg}"
  ( WA_MESSAGE="$body" node "$helper" </dev/null >/dev/null 2>&1 || true ) &
  disown 2>/dev/null || true
  return 0
}

# gov_notify <title> <message> [skill_name]
# Two-channel notification (rewritten 2026-04-16 — WPF popup proved unreliable):
#   1. STDOUT — structured block surfaced into the assistant's context. The
#      assistant will see it on the next turn and is expected to act on it.
#   2. WhatsApp — sends to user's phone via the gateway (rate-limited 1/5min
#      per skill key). Survives PC closed, Claude not running, etc.
#
# NEVER blocks (no exit 2). NEVER throws. Backward-compatible signature.
# Runs WhatsApp async — returns immediately.
#
# Kill switches:
#   GOV_NOTIFY=0     — disables BOTH stdout and WhatsApp
#   GOV_WHATSAPP=0   — disables WhatsApp only (stdout still emitted)
gov_notify() {
  local title="$1"
  local message="$2"
  local skill="${3:-}"

  [ "${GOV_NOTIFY:-1}" = "0" ] && return 0

  # Sanitize for both channels — strip control chars, cap length
  title=$(printf '%s' "$title"   | tr -d '\r' | head -c 200)
  message=$(printf '%s' "$message" | tr -d '\r' | head -c 1200)
  skill=$(printf '%s' "$skill"   | tr -d '\r\n' | head -c 100)

  # ── Channel 1: STDOUT (assistant context) ──────────────────────────────────
  # Format that Claude reads as a structured directive. Use a recognizable
  # marker so the assistant knows this came from the governance layer, not
  # from the tool result it just received.
  printf '\n[GOVERNANCE NOTIFICATION]\n%s\n' "$title"
  [ -n "$message" ] && printf '%s\n' "$message"
  [ -n "$skill" ] && printf 'RECOMMENDED ACTION: invoke skill %s\n' "$skill"
  printf '[/GOVERNANCE NOTIFICATION]\n\n'

  # ── Channel 2: WhatsApp (user's phone) ─────────────────────────────────────
  # Rate-limited per skill key (or "default" if no skill).
  local wa_msg="$title"
  [ -n "$message" ] && wa_msg="$wa_msg
$message"
  [ -n "$skill" ] && wa_msg="$wa_msg
ACTION: $skill"
  gov_send_whatsapp "$wa_msg" "${skill:-default}"

  return 0
}

# ---------------------------------------------------------------------------
# Session-scoped state (2026-08-16, GOVERNANCE-AGENT-GUIDE §17)
#
# Every hook receives Claude Code's JSON on stdin ({"session_id": ..., ...}).
# State that describes ONE session (bootstrapped marker, prompt counter, change
# log, milestone state, start SHA, dirty baseline) lives in
#   ~/.claude/logs/sessions/<session_id>/
# so two concurrent sessions - even in different projects - can no longer
# overwrite or "crash-recover" each other. When no session id is available
# (manual run, old Claude Code) everything falls back to the legacy shared
# ~/.claude/logs/ paths, i.e. behaviour is unchanged there.
#
# Rules for hooks:
#   * read stdin ONLY via gov_hook_input (it caches; a second raw `cat` sees EOF)
#   * build per-session paths with gov_state_file NAME
#   * wrap state mutations in `gov_dry || ...` (GOV_DRY_RUN=1 = print, do not touch)
#   * override the id for tests/manual runs with GOV_SESSION_ID=...
# ---------------------------------------------------------------------------
_GOV_HOOK_INPUT="${_GOV_HOOK_INPUT:-}"
_GOV_HOOK_INPUT_READ="${_GOV_HOOK_INPUT_READ:-0}"

# gov_hook_input
# Prints the hook's stdin payload; reads it once (cap 256 KB), never blocks on a tty.
gov_hook_input() {
  if [ "$_GOV_HOOK_INPUT_READ" != "1" ]; then
    _GOV_HOOK_INPUT_READ=1
    if [ -z "$_GOV_HOOK_INPUT" ] && [ ! -t 0 ]; then
      _GOV_HOOK_INPUT=$(head -c 262144 2>/dev/null || true)
    fi
  fi
  printf '%s' "$_GOV_HOOK_INPUT"
}

# gov_session_id
# GOV_SESSION_ID env > stdin JSON "session_id" > "" (unknown). Sanitised to [A-Za-z0-9._-].
gov_session_id() {
  if [ -n "${GOV_SESSION_ID:-}" ]; then
    printf '%s' "$GOV_SESSION_ID" | tr -cd 'A-Za-z0-9._-'
    return 0
  fi
  if [ "${_GOV_SID_READY:-0}" != "1" ]; then
    _GOV_SID_READY=1
    _GOV_SID_CACHE=$(gov_hook_input | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null \
      | head -1 | sed 's/.*"session_id"[[:space:]]*:[[:space:]]*"//;s/"$//' | tr -cd 'A-Za-z0-9._-')
  fi
  printf '%s' "${_GOV_SID_CACHE:-}"
}

# gov_state_dir
# ~/.claude/logs/sessions/<sid> when the session id is known (created on demand),
# else the legacy shared ~/.claude/logs.
gov_state_dir() {
  local sid; sid=$(gov_session_id)
  if [ -n "$sid" ]; then
    local d="$HOME/.claude/logs/sessions/$sid"
    [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || true
    printf '%s' "$d"
  else
    printf '%s' "$HOME/.claude/logs"
  fi
}

# gov_state_file <name>  -> full path of a per-session state file
gov_state_file() { printf '%s/%s' "$(gov_state_dir)" "$1"; }

# ── Protected governance documents (#101 A.1) ────────────────────────────────
# ONE definition of "is this a governance doc that needs a success token".
#
# WHY THIS ONE AND NOT THE COLLISION HELPERS: A.1 originally proposed extracting
# gov_collision_check, gov_collision_record AND this predicate together. That was correct when it
# was written and is not correct now: after #102 the recorder acquired an atomic tmp+rename claim
# and a peer-detection view hold that the guard does not share, so check and record are no longer
# one behaviour and merging them would hide a real difference behind a shared name. The predicate,
# by contrast, was three copies of one rule -- and the third (commit-task-success.sh) had already
# drifted, advertising `memory/MEMORY.md` and `Plans/PLAN.md` which the guard does not enforce and
# which the guard's own comment says must NEVER be protected. That is what this fixes structurally:
# the token now prints the list FROM the predicate, so it cannot describe a different one again.
#
# The list is deliberately NOT extended here. Adding a pattern protects a new file class across
# every hook at once, so it is a governance decision, not a refactor.
#
# IMPORTANT: never add "memory/MEMORY.md" under .claude/projects/. Those are user-level Claude
# auto-memory files and MUST stay writable on every session.
GOV_PROTECTED_PATTERNS="MDs/Open-Problems.md
MDs/HANDOFF-
docs/context/GOTCHAS.md
docs/context/OPEN-PROBLEMS.md
docs/context/HANDOFF.md
docs/context/MEMORY.md"

# gov_protected_patterns
# Print the protected patterns, one per line. The single source for both the guard's decision and
# the token's advertised list.
gov_protected_patterns() {
  printf '%s\n' "$GOV_PROTECTED_PATTERNS"
}

# gov_is_protected_doc <path>
# Exit 0 when the path is a protected governance doc, 1 otherwise. On a match the matched pattern
# is printed on stdout, so a caller can report WHICH rule fired (the guard does).
# Path separators are normalised first, so a Windows-spelled path matches the same rule.
gov_is_protected_doc() {
  local _p _pat
  _p=$(printf '%s' "${1:-}" | tr '\\' '/')
  [ -n "$_p" ] || return 1
  while IFS= read -r _pat; do
    [ -n "$_pat" ] || continue
    case "$_p" in
      *"$_pat"*) printf '%s' "$_pat"; return 0 ;;
    esac
  done <<EOF
$GOV_PROTECTED_PATTERNS
EOF
  return 1
}


# gov_path_key <path>
# Stable 32-hex key for a file path, used by the collision guard so that two sessions
# spelling the same file differently still collide. Windows makes this necessary:
# C:\repo\a.md, C:/repo/a.md and /c/repo/a.md are one file with three spellings.
# Backslashes become forward slashes, a drive letter is lower-cased, and /c/... is
# folded onto c:/... . Content is hashed via stdin because coreutils escapes its output
# whenever the FILENAME contains a backslash, which shifts the digest by one character.
gov_path_key() {
  local n
  n=$(printf '%s' "$1" | tr '\\' '/' | sed -e 's|^/\([A-Za-z]\)/|\1:/|')

  # Collapse `.` and `..` segments and duplicate slashes, so two spellings of ONE file share a
  # claim. Without this, /repo/x.md and /repo/sub/../x.md hash differently, each session takes
  # its own claim, and both writes are allowed -- the guard's whole purpose defeated by nothing
  # more than how the path happened to be written. CODEX reproduced it on PR #1 and observed two
  # lock files for one file.
  #
  # Done in pure parameter expansion, deliberately. `realpath` would also resolve symlinks, but
  # it is a process spawn, and this function runs on the hot path of every single edit where a
  # spawn costs ~0.13s on this machine (gotcha #290). Lexical collapse is free.
  #
  # STATED LIMIT: symlink aliases are still NOT resolved. /repo/link.md and /repo/real.md remain
  # two keys. Closing that needs realpath, i.e. a spawn per edit, and it is a rarer shape than a
  # `..` in a path. Recorded rather than quietly left as a surprise.
  case "$n" in
    */./*|*/../*|*/.|*/..|*//*)
      local out="" seg rest="$n" lead=""
      case "$n" in /*) lead="/" ;; [A-Za-z]:/*) lead="${n%%/*}/" ; rest="${n#*/}" ;; esac
      [ "$lead" = "/" ] && rest="${n#/}"
      while [ -n "$rest" ]; do
        seg="${rest%%/*}"
        case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
        case "$seg" in
          ''|'.') ;;
          '..')   out="${out%/*}" ;;
          *)      out="$out/$seg" ;;
        esac
      done
      n="${lead%/}${out}"
      [ -z "$n" ] && n="$lead"
      ;;
  esac

  # A drive letter means Windows, where the whole path is case-insensitive, so fold it.
  # Never fold a POSIX path: there /Repo and /repo really are two different files.
  case "$n" in
    [A-Za-z]:/*) n=$(printf '%s' "$n" | tr 'A-Z' 'a-z') ;;
  esac
  printf '%s' "$n" | sha256sum | cut -c1-32
}

# gov_dry  -> success when GOV_DRY_RUN=1 (hooks must not mutate anything then)
gov_dry() { [ "${GOV_DRY_RUN:-0}" = "1" ]; }

# gov_is_semver <string>
# True only for a bare dotted-numeric version: digits and dots, at least two dots, <=16 chars.
# A GLOB like [0-9]*.[0-9]*.[0-9]* is NOT good enough here: `1.9.9 IGNORE ALL PREVIOUS
# INSTRUCTIONS...` matches it, and the value this validates comes off the NETWORK and is echoed
# straight into a session's context. Anything outside [0-9.] is rejected outright.
gov_is_semver() {
  case "$1" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  case "$1" in
    *.*.*) ;;
    *) return 1 ;;
  esac
  [ "${#1}" -le 16 ] || return 1
  return 0
}

# gov_detect_role_var <varname> <root>
# Fork-free twin of gov_detect_role: assigns instead of printing. `gov_detect_role` is called from
# hot paths that run at every session start, and on Windows/MSYS2 the `$( )` around it costs
# ~75 ms on its own. Same logic, one `printf -v` instead of a subshell.
gov_detect_role_var() {
  local __gr_n="$1" __gr_root="${2:-${GOV_PROJECT_ROOT:-}}" __gr_v=""
  if [ "$GOV_ROLE_FRAMEWORK" = "0" ]; then
    printf -v "$__gr_n" '%s' "SOURCE"; return 0
  fi
  # Mirrors gov_detect_role's Priority-1 parse EXACTLY: first line, all whitespace stripped, and
  # nothing else. Deliberately does NOT strip a trailing `# comment` — the printing form does not
  # either, so `FROZEN  # note` is not a declaration in both. An earlier draft of this twin was
  # more permissive and the two disagreed on that input; a helper that answers differently from
  # the function it shadows is worse than the fork it saves.
  if [ -n "$__gr_root" ] && [ -f "$__gr_root/.governance-role" ]; then
    # `|| true` for the same reason as gov_read_version_var: `read` reports failure at
    # EOF-without-newline after it has already assigned. Here the fallback to the printing form
    # happened to mask it; relying on that is luck, not design.
    read -r __gr_v < "$__gr_root/.governance-role" 2>/dev/null || true
    __gr_v="${__gr_v//[[:space:]]/}"
    case "$__gr_v" in
      SOURCE|DEPLOYMENT|FROZEN) printf -v "$__gr_n" '%s' "$__gr_v"; return 0 ;;
    esac
  fi
  # Fall back to the printing form for every other path (no explicit marker, or a $PWD walk is
  # needed) so the two can never disagree about what a role IS — only about how it is returned.
  printf -v "$__gr_n" '%s' "$(gov_detect_role "$__gr_root")"
}

# gov_read_version_var <varname> <path>
# Fork-free twin of gov_read_version: ASSIGNS instead of printing, so the caller does not pay for
# a `$( )` subshell. On Windows/MSYS2 a fork costs ~60-75 ms, and this runs on every session start
# in every project — the printing form used twice plus a role lookup was most of a measured 494 ms
# regression. `read` and `printf -v` are bash builtins; nothing here forks.
gov_read_version_var() {
  local __gv_n="$1" __gv_p="$2" __gv_v="" __gv_line=""
  # FIRST NON-EMPTY LINE, whitespace stripped. Two subtleties, both learned the hard way:
  #
  # 1. `|| true`, never `|| VAR=""`. `read` returns non-zero at EOF-without-delimiter — a file
  #    whose last line has no trailing newline — but it has ALREADY assigned. The discard form
  #    threw away a good value, so a machine holding `1.1.0` without a final newline, otherwise
  #    exactly up to date, was told "no usable version marker" at every session start.
  # 2. First non-empty LINE, not the whole file. Slurping and stripping all whitespace turns a
  #    two-line file into one concatenated token: `1.0.0` + `2.0.0` becomes `1.0.02.0.0`, which
  #    is digits and dots and therefore PASSES gov_is_semver. Corruption must read as invalid,
  #    not as a plausible version.
  if [ -f "$__gv_p" ]; then
    # Read a BOUNDED buffer, then parse it in memory. A plain `read` consumes the whole first
    # line whatever its length: on a 1 MB single-line file that is 2.6 s of foreground stall, a
    # ~1000x regression against the `cat | tr` reader this replaced. `read -N 4096` on the same
    # file is 28 ms. Truncating AFTER the read does not help — the cost is the read itself, which
    # is why the first attempt at this cap changed nothing and had to be measured to find out.
    # 4 KB is far more than any legitimate marker and still bounds the pathological case.
    local __gv_buf=""
    IFS= read -r -N 4096 __gv_buf < "$__gv_p" 2>/dev/null || true
    while [ -n "$__gv_buf" ]; do
      __gv_line="${__gv_buf%%$'\n'*}"
      __gv_line="${__gv_line//[[:space:]]/}"
      if [ -n "$__gv_line" ]; then __gv_v="$__gv_line"; break; fi
      case "$__gv_buf" in
        *$'\n'*) __gv_buf="${__gv_buf#*$'\n'}" ;;
        *) break ;;
      esac
    done
  fi
  printf -v "$__gv_n" '%s' "$__gv_v"
}

# gov_read_version <path>
# Prints the trimmed contents of a version file, or nothing. NEVER fails, so it is safe inside
# `VAR=$(...)` under `set -euo pipefail` — a bare `< missing_file` redirect there aborts the whole
# script with one cryptic line and no output, which is how a health check that exists to report a
# missing marker died on the missing marker.
gov_read_version() {
  # Delegates, so the printing form and the fork-free form cannot drift apart. They previously
  # disagreed on a file with a leading blank line — this one slurped the whole file and stripped
  # whitespace, the other read line one — and two helpers that answer differently about the same
  # file are the defect this framework keeps producing.
  local __rv=""
  gov_read_version_var __rv "$1"
  printf '%s' "$__rv"
}

# gov_mtime <path>
# Epoch seconds of a file's last modification; "0" if the file is missing or stat is unavailable.
# GNU stat uses -c, BSD/macOS stat uses -f — try both rather than assuming the platform, and
# always emit a number so arithmetic on the result cannot blow up under `set -e`.
gov_mtime() {
  local p="$1" m=""
  [ -e "$p" ] || { echo 0; return 0; }
  m=$(stat -c %Y "$p" 2>/dev/null) || m=$(stat -f %m "$p" 2>/dev/null) || m=""
  case "$m" in (*[!0-9]*|"") echo 0 ;; (*) echo "$m" ;; esac
}

# gov_other_sessions
# One line per OTHER session dir: "<sid>\t<age_seconds>\t<open|closed>\t<changes>"
# age = seconds since the newest file in that dir; changes = lines in its change log.
gov_other_sessions() {
  local me now d sid newest age st ch
  me=$(gov_session_id); now=$(date +%s)
  for d in "$HOME"/.claude/logs/sessions/*/; do
    [ -d "$d" ] || continue
    sid=$(basename "$d"); [ "$sid" = "$me" ] && continue
    newest=$(find "$d" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
    [ -z "$newest" ] && newest=$(stat -c %Y "$d" 2>/dev/null || echo "$now")
    age=$((now - newest)); [ "$age" -lt 0 ] && age=0
    st=open; [ -f "$d/.gov-session-closed" ] && st=closed
    ch=$(grep -c . "$d/.gov-session-changes" 2>/dev/null | tr -d ' '); [ -z "$ch" ] && ch=0
    printf '%s\t%s\t%s\t%s\n' "$sid" "$age" "$st" "$ch"
  done
}

# gov_prune_sessions [days]  -> delete session dirs untouched for N days (default 14)
gov_prune_sessions() {
  local days="${1:-14}" d
  gov_dry && return 0
  for d in "$HOME"/.claude/logs/sessions/*/; do
    [ -d "$d" ] || continue
    # the dir entry itself counts (a fresh, still-empty session dir must survive)
    if [ -z "$(find "$d" -mtime "-$days" -print -quit 2>/dev/null)" ]; then
      rm -rf "$d" 2>/dev/null || true
    fi
  done
}

# gov_memory_dir <project-root>  -> the Claude Code auto-memory directory for that project, or ""
#
# Claude Code keys auto-memory to the session cwd: every non-alphanumeric character of the path
# becomes '-', CASE PRESERVED, so `C:\dev\example-project` -> `C--dev-example-project` while the
# same folder opened as `c:\dev\example-project` -> `c--dev-example-project`, and a POSIX
# `/opt/example-project` -> `-opt-example-project` (leading dash kept). A hook that derives ONE
# spelling and tests `[ -d ]` on it goes silently inert when the user typed the other one -
# measured 2026-09-01: a dead-link check lower-cased the drive and stripped the leading dash,
# looked for a directory that did not exist, and skipped without a word. So this tries every
# spelling the harness could have produced and returns the first that EXISTS; "" means none does,
# which the caller must REPORT, never treat as "clean".
gov_memory_dir() {
  local root="$1" p base cand
  [ -n "$root" ] || return 0
  p="$(printf '%s' "$root" | tr '\\' '/' | sed 's|/*$||')"
  # msys drive form -> Windows drive form, so /c/x and C:/x key identically
  case "$p" in /[A-Za-z]/*) p="${p:1:1}:${p:2}" ;; esac
  base="$(printf '%s' "$p" | sed 's|[^A-Za-z0-9]|-|g')"
  for cand in \
      "$base" \
      "$(printf '%s' "$base" | sed 's|^-*||')" \
      "$(printf '%s' "$base" | tr 'A-Z' 'a-z')" \
      "$(printf '%s' "$base" | tr 'A-Z' 'a-z' | sed 's|^-*||')" \
      "$(printf '%.1s' "$base" | tr 'a-z' 'A-Z')${base:1}" \
      "$(printf '%.1s' "$base" | tr 'A-Z' 'a-z')${base:1}"; do
    [ -n "$cand" ] || continue
    if [ -d "$HOME/.claude/projects/$cand/memory" ]; then
      printf '%s' "$HOME/.claude/projects/$cand/memory"; return 0
    fi
  done
  return 0
}

# Prime the stdin cache in the SOURCING shell: a "$(...)" call would read stdin inside a
# subshell and could not cache it for its parent, so the second reader would see EOF
# (2026-08-16 sandbox finding). Hooks may then call gov_hook_input / gov_session_id freely.
_GOV_HOOK_INPUT=$(gov_hook_input)
_GOV_HOOK_INPUT_READ=1
