#!/usr/bin/env bash
# pre-session.sh — Context Governance hook (SessionStart)
# Cannot block (exit 2 would prevent session from starting = deadlock).
# Instead: sets up state, detects crashed previous sessions, outputs instructions.
#
# Responsibilities:
#   1. Reset session marker + prompt counter (clean slate)
#   2. Detect orphan session (previous crash — changes log exists without cleanup)
#   3. Output IMPERATIVE instructions for governed/ungoverned projects
#
# 2026-08-16 UNION MERGE: this file is the reconciliation of three divergent lineages —
#   (a) repo HEAD b1c555d: Step 2b session-start stamp + Step 2c dirty-tree baseline,
#   (b) the orphaned 4-line stdin guard defining _GOV_HOOK_INPUT (existed only in the
#       the source repo mirror until a 2026-08-15 23:57 sync overwrote it; Step 2b's sid=
#       stamp reads this var — without the guard the sid is silently empty),
#   (c) the parallel-session detection block (GOVERNANCE-AGENT-GUIDE §16, session bda1c0a8).
# A 13:16:26 batch copy had regressed the live file to a pre-2b/2c version; do not
# "restore" from any copy with that mtime.
#
# Kill switch: GOVERNANCE_HOOKS=0
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }
gov_disabled && exit 0

# Read the payload once and resolve the project it is ABOUT, before anything branches on it.
# Sets GOV_PROJECT_ROOT. Without this, `gov_state_file` drains stdin inside a subshell and
# every governed-project test below silently falls back to $PWD - which resolves to the
# USER-LEVEL ~/.claude/CLAUDE.md whenever the session's shell is standing there.
gov_prime_payload

# Hook payload (carries session_id). Guarded so a tty never makes this hang.
_GOV_HOOK_INPUT="${_GOV_HOOK_INPUT:-}"   # keep what _common.sh primed
# (_common.sh already primed _GOV_HOOK_INPUT; only read here if an older _common.sh did not)
[ -z "${_GOV_HOOK_INPUT:-}" ] && [ "${_GOV_HOOK_INPUT_READ:-0}" != "1" ] && [ ! -t 0 ] && _GOV_HOOK_INPUT=$(cat 2>/dev/null)

# --- Framework-version advisory (§20) ---
#
# Runs BEFORE the node-role gate on purpose: the framework version is a property of THIS MACHINE
# (~/.claude/), not of the project. A machine whose only projects are DEPLOYMENT targets still
# needs to learn that a release happened. FROZEN stays silent — that node type prints nothing.
#
# NEVER blocks. The network call is fully detached and only refreshes a cache; what a session
# prints is the result of a PREVIOUS run.
#
# FORK BUDGET IS THE DESIGN CONSTRAINT HERE. This runs at every session start in every project,
# and on Windows/MSYS2 a fork costs ~60-75 ms. The first version spent about ten of them — two
# gov_detect_role lookups, two command-substitution reads, a date, a gov_mtime, a sort -V probe —
# and added a measured median 494 ms to every session, for a feature that matters once per
# release. Everything below that CAN be a bash builtin IS one: read, printf -v, parameter
# substitution, and ONE cached role lookup. Do not reintroduce a command substitution in this
# block without measuring an interleaved A/B first: a single before/after pair reads as noise at
# this scale, which is exactly how the cost was missed the first time.
#
# Advisory only, never installs. install.sh replaces the very hooks and skills that are running
# at that moment, so the update is always a deliberate operator action.
#
# No backslash escapes in the strings below on purpose: this file is edited through tooling that
# JSON-decodes them, silently turning \t and \n into real control characters inside quotes.
_GOV_ROLE_CACHED=""
gov_detect_role_var _GOV_ROLE_CACHED "$GOV_PROJECT_ROOT" 2>/dev/null   # ONE fork-free lookup, reused below
_GOV_ADVISORY_ELIGIBLE=0
if [ "$_GOV_ROLE_CACHED" != "FROZEN" ] \
   && [ "${GOVERNANCE_UPDATE_CHECK:-1}" != "0" ] \
   && [ -f "$HOME/.claude/hooks/governance/_common.sh" ]; then
  # The helper guard is not defensive padding. sync-governance-copies.sh mirrors hook files
  # INDIVIDUALLY, so a machine can legitimately hold this file next to an older _common.sh that
  # lacks these helpers. Bash then reports "command not found", the call returns 127, and 127 is
  # indistinguishable from "rejected" — which printed two error lines and a FALSE "no version
  # marker" advisory on a machine that was exactly up to date. Absent helpers means we know
  # nothing, so we say nothing.
  #
  # The skip is written to governance.log because silence here is genuinely silent on a DEPLOYMENT
  # node: [GOVERNANCE DRIFT] lives ~200 lines below, runs AFTER gov_role_guard SOURCE, and is
  # skipped without an installer-bundle mirror — so it is not the safety net it once claimed.
  if command -v gov_read_version_var >/dev/null 2>&1 && command -v gov_is_semver >/dev/null 2>&1; then
    _GOV_ADVISORY_ELIGIBLE=1
  else
    gov_log "pre-session" "update advisory SKIPPED: _common.sh is missing gov_read_version_var/gov_is_semver (hook lineage skew — reconcile with the installer bundle)"
  fi
fi

if [ "$_GOV_ADVISORY_ELIGIBLE" = "1" ]; then
  _GOV_LATEST="$HOME/.claude/logs/.governance-latest"
  _GOV_URL="https://raw.githubusercontent.com/Gold-b/claude-code-governance/master/bundle/VERSION"

  _LOCAL_V=""
  gov_read_version_var _LOCAL_V "$HOME/.claude/.governance-version"
  gov_is_semver "$_LOCAL_V" || _LOCAL_V=""

  # An installed framework with NO usable marker predates versioning (or was stamped by a failed
  # install). Gating the whole advisory on the marker would have excluded exactly the machines the
  # advisory exists for: the ones running an old copy with no idea a release happened.
  if [ -z "$_LOCAL_V" ]; then
    gov_log "pre-session" "unversioned install (no usable ~/.claude/.governance-version)"
    echo "[GOVERNANCE UPDATE] This machine has no usable framework version marker, so it cannot tell whether it is up to date — it predates versioning, or it was installed from a copy of the bundle that carried no VERSION file. Re-run 'bash install.sh --force' from a CURRENT CLONE of Gold-b/claude-code-governance (a clone always has bundle/VERSION; a hand-copied bundle may not). Silence with GOVERNANCE_UPDATE_CHECK=0."
  else
    # 1. Report on the CACHED answer. No network on this path.
    if [ -s "$_GOV_LATEST" ]; then
      _REMOTE_V=""
      gov_read_version_var _REMOTE_V "$_GOV_LATEST"
      # Validate on READ, not only on write. This value came off the network and is echoed into
      # the session context; a cache file can also be hand-edited, truncated by a full disk, or
      # hold a proxy error page. Trusting it because WE wrote it is the same mistake as trusting a
      # config because it parsed.
      gov_is_semver "$_REMOTE_V" || _REMOTE_V=""
      if [ -n "$_REMOTE_V" ] && [ "$_REMOTE_V" != "$_LOCAL_V" ]; then
        # Only advise UPGRADES; a local version AHEAD of published is a dev machine mid-release.
        # Needs a version-aware compare (1.9.0 -> 1.10.0 is an upgrade a string compare misses),
        # done as a builtin loop rather than a sort -V fork. Any component that is not a plain
        # number makes it UNDECIDABLE, and undecidable means SILENT: a false "update available"
        # trains people to ignore the line.
        _gv_newer=""
        _gv_a="$_LOCAL_V"; _gv_b="$_REMOTE_V"
        while [ -n "$_gv_a$_gv_b" ]; do
          _gv_x="${_gv_a%%.*}"; _gv_y="${_gv_b%%.*}"
          [ -n "$_gv_x" ] || _gv_x=0
          [ -n "$_gv_y" ] || _gv_y=0
          case "$_gv_x$_gv_y" in *[!0-9]*) _gv_newer="undecidable"; break ;; esac
          if [ "$_gv_y" -gt "$_gv_x" ]; then _gv_newer="remote"; break; fi
          if [ "$_gv_x" -gt "$_gv_y" ]; then _gv_newer="local"; break; fi
          case "$_gv_a" in *.*) _gv_a="${_gv_a#*.}" ;; *) _gv_a="" ;; esac
          case "$_gv_b" in *.*) _gv_b="${_gv_b#*.}" ;; *) _gv_b="" ;; esac
        done
        if [ "$_gv_newer" = "remote" ]; then
          gov_log "pre-session" "update available: local=$_LOCAL_V published=$_REMOTE_V"
          echo "[GOVERNANCE UPDATE] Context Governance v$_REMOTE_V is published; this machine has v$_LOCAL_V. Update deliberately: git pull in your clone of Gold-b/claude-code-governance, then 'bash install.sh --force' (it backs up first). Nothing installs on its own — install.sh replaces hooks and skills that are running right now. Silence with GOVERNANCE_UPDATE_CHECK=0."
        elif [ "$_gv_newer" = "undecidable" ]; then
          gov_log "pre-session" "version compare undecidable (local=$_LOCAL_V published=$_REMOTE_V); staying silent"
        fi
      fi
    fi
  fi

  # 2. Refresh the cache in the background when stale, and sweep temp files orphaned by fetches
  #    whose subshell was killed before its own cleanup ran. ONE find decides staleness; the
  #    previous version spent a date, a gov_mtime and two command substitutions to learn the same.
  if ! gov_dry && command -v curl >/dev/null 2>&1; then
    _GOV_LOGDIR="${_GOV_LATEST%/*}"
    [ -d "$_GOV_LOGDIR" ] || mkdir -p "$_GOV_LOGDIR" 2>/dev/null
    _NEED_FETCH=1
    if [ -f "$_GOV_LATEST" ] && [ -z "$(find "$_GOV_LATEST" -maxdepth 0 -mmin +720 2>/dev/null)" ]; then
      _NEED_FETCH=0
    fi
    if [ "$_NEED_FETCH" = "1" ]; then
      find "$_GOV_LOGDIR" -maxdepth 1 -name ".governance-latest.*" -mmin +60 -delete 2>/dev/null || true
      (
        _v=$(curl -fsS -m 3 "$_GOV_URL" 2>/dev/null | tr -d '[:space:]')
        if gov_is_semver "$_v"; then
          _tmp="$_GOV_LATEST.$$"
          echo "$_v" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$_GOV_LATEST" 2>/dev/null
          rm -f "$_tmp" 2>/dev/null
        else
          touch "$_GOV_LATEST" 2>/dev/null
        fi
      ) >/dev/null 2>&1 &
    fi
  fi
fi

# Node-role gate (Framework v2): only run full bootstrap on SOURCE.
# DEPLOYMENT/FROZEN nodes skip — they don't originate sessions.
gov_role_guard SOURCE

# Read the hook payload once (Claude Code passes {"session_id": ...} on stdin).
_GOV_HOOK_INPUT=$(gov_hook_input)
GOV_SID=$(gov_session_id)
STATE_DIR=$(gov_state_dir)
SESSION_MARKER="$STATE_DIR/.gov-session-bootstrapped"
PROMPT_COUNTER="$STATE_DIR/.gov-session-prompt-count"
CHANGES_LOG="$STATE_DIR/.gov-session-changes"
CRASH_FLAG=""
PARALLEL_HINT=""
ORPHAN_COUNT=0

# --- Step 1: Other sessions - crashed (archive) vs alive (parallel) ---
# Session state is per session id (GOVERNANCE-AGENT-GUIDE §17). A dir that still has a
# change log and was silent for > 6 h belongs to a crashed / force-killed session: archive
# it. A dir touched in the last 10 min belongs to a session that is ALIVE right now:
# that is a parallel session on this machine (maybe this very tree) - not a crash.
if [ -n "$GOV_SID" ]; then
  while IFS="$(printf '\t')" read -r o_sid o_age o_state o_changes; do
    [ -z "$o_sid" ] && continue
    if [ "$o_age" -le 600 ] && [ "$o_state" = "open" ]; then
      PARALLEL_HINT="${PARALLEL_HINT:+$PARALLEL_HINT; }session ${o_sid%%-*}… active ${o_age}s ago"
    elif [ "$o_age" -gt 21600 ] && [ "$o_changes" -gt 0 ] && [ "$o_state" = "open" ]; then
      CRASH_FLAG="true"; ORPHAN_COUNT=$((ORPHAN_COUNT + o_changes))
      if ! gov_dry; then
        ARCHIVE="$HOME/.claude/logs/.gov-crashed-session-${o_sid}-$(date +%Y%m%d-%H%M%S).log"
        cp "$HOME/.claude/logs/sessions/$o_sid/.gov-session-changes" "$ARCHIVE" 2>/dev/null
        : > "$HOME/.claude/logs/sessions/$o_sid/.gov-session-changes" 2>/dev/null
        touch "$HOME/.claude/logs/sessions/$o_sid/.gov-session-closed" 2>/dev/null
      fi
      gov_log "pre-session" "CRASH DETECTED: session $o_sid left $o_changes tracked changes (silent ${o_age}s). Archived."
    fi
  done <<EOF_SESSIONS
$(gov_other_sessions)
EOF_SESSIONS
  gov_prune_sessions 14
else
  # Legacy path (no session id): the shared change log is the only signal we have.
  if [ -f "$CHANGES_LOG" ]; then
    ORPHAN_COUNT=$(wc -l < "$CHANGES_LOG" 2>/dev/null | tr -d ' ')
    if [ "${ORPHAN_COUNT:-0}" -gt 0 ]; then
      CRASH_FLAG="true"
      if ! gov_dry; then
        ARCHIVE="$HOME/.claude/logs/.gov-crashed-session-$(date +%Y%m%d-%H%M%S).log"
        cp "$CHANGES_LOG" "$ARCHIVE" 2>/dev/null
      fi
      gov_log "pre-session" "CRASH DETECTED (legacy shared state): $ORPHAN_COUNT tracked changes without cleanup"
    fi
  fi
fi

# --- Step 2: Reset THIS session's state (clean slate) ---
if ! gov_dry; then
  rm -f "$SESSION_MARKER" "$PROMPT_COUNTER" "$CHANGES_LOG" 2>/dev/null
  rm -f "$STATE_DIR/.gov-milestone-state" "$STATE_DIR/.post-milestone-last" "$STATE_DIR/.gov-qa-notified" 2>/dev/null
  rm -f "$STATE_DIR/.gov-session-closed" 2>/dev/null
  # the success token is global (created by the model via Bash, which has no session id)
  rm -f "$HOME/.claude/logs/governance-success-token.json" 2>/dev/null
fi

# --- Step 2b: Stamp the session-start commit (close-completeness.sh reads this) ---
# Without a start SHA the close hook cannot tell THIS session's work from history, and it
# refuses to judge rather than block on someone else's commits. Stamped here because this
# is the only hook that reliably runs once, at the beginning.
_GOV_START="$STATE_DIR/.gov-session-start"
gov_dry || rm -f "$_GOV_START" 2>/dev/null
_GOV_ROOT="$(gov_find_project_root 2>/dev/null)"; [ -z "$_GOV_ROOT" ] && _GOV_ROOT="$PWD"
if [ -d "$_GOV_ROOT/.git" ]; then
  _GOV_SHA=$(cd "$_GOV_ROOT" && git rev-parse HEAD 2>/dev/null)
  # The SESSION ID is stamped alongside the SHA. This file is a single shared path, so with two
  # sessions open the later one silently overwrites the earlier one's start point - and the
  # earlier session's close is then measured against commits it never made. That is not
  # hypothetical: on 2026-07-28 a parallel session stamped its own SHA at 18:01, and the first
  # session's close was blocked for "changing code" that belonged entirely to the other one.
  _GOV_SID=$(printf '%s' "${_GOV_HOOK_INPUT:-}" | python3 -c "
import sys, json
try: print((json.load(sys.stdin) or {}).get('session_id',''))
except Exception: print('')
" 2>/dev/null)
  [ -n "$_GOV_SHA" ] && ! gov_dry && printf '%s %s %s sid=%s\n' \
    "$_GOV_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_GOV_ROOT" "$_GOV_SID" > "$_GOV_START" 2>/dev/null
fi

# --- Step 2c: Baseline the working tree that was ALREADY dirty before this session ---
# The start SHA alone does not scope the close check: `git status` reports a previous
# session's leftovers too (a crash leaves untracked artifacts), so close-completeness.sh read
# them as THIS session's code changes and blocked a session that had written nothing. Left
# unfixed it blocks every session from then on, until a human cleans the tree - the opposite
# of the hook's own "a session that changed no code owes nothing". Subtracted at close.
_GOV_DIRTY="${GOV_SESSION_DIRTY_FILE:-$STATE_DIR/.gov-session-dirty}"
if ! gov_dry; then
  rm -f "$_GOV_DIRTY" 2>/dev/null
  gov_dirty_snapshot "$_GOV_ROOT" > "$_GOV_DIRTY" 2>/dev/null
fi

gov_log "pre-session" "fired (state=$(gov_phase_state))"

# --- Step 3: Output instructions ---
# --- Parallel-session detection (GOVERNANCE-AGENT-GUIDE §16/§17) ---
# Primary signal: another session dir active in the last 10 min (set in Step 1).
# Secondary: the project's .claude/scheduled_tasks.lock names a DIFFERENT session id
# whose pid is alive; and the count of running claude processes. Advisory only.
_LOCK=".claude/scheduled_tasks.lock"
if [ -f "$_LOCK" ]; then
  _LOCK_SID=$(grep -o '"sessionId":"[^"]*"' "$_LOCK" 2>/dev/null | head -1 | cut -d'"' -f4)
  _LOCK_PID=$(grep -o '"pid":[0-9]*' "$_LOCK" 2>/dev/null | head -1 | cut -d: -f2)
  if [ -n "$_LOCK_PID" ] && [ -n "$_LOCK_SID" ] && [ "$_LOCK_SID" != "$GOV_SID" ]; then
    _ALIVE=""
    if command -v tasklist >/dev/null 2>&1; then
      tasklist //FI "PID eq $_LOCK_PID" 2>/dev/null | grep -q "$_LOCK_PID" && _ALIVE=1
    elif kill -0 "$_LOCK_PID" 2>/dev/null; then
      _ALIVE=1
    fi
    [ -n "$_ALIVE" ] && PARALLEL_HINT="${PARALLEL_HINT:+$PARALLEL_HINT; }lock held by session ${_LOCK_SID%%-*}… (pid $_LOCK_PID alive)"
  fi
fi
_OTHER_CLAUDE=0
if command -v tasklist >/dev/null 2>&1; then
  _OTHER_CLAUDE=$(tasklist //FI "IMAGENAME eq claude.exe" 2>/dev/null | grep -c "claude.exe" || true)
elif command -v pgrep >/dev/null 2>&1; then
  _OTHER_CLAUDE=$(pgrep -fc "claude" 2>/dev/null || true)
fi
[ "${_OTHER_CLAUDE:-0}" -gt 1 ] && [ -n "$PARALLEL_HINT" ] && PARALLEL_HINT="$PARALLEL_HINT; $_OTHER_CLAUDE claude processes"

# --- Drift advisory (SS17): live governance files vs EVERY copy (rewritten 2026-09-01, task B7) ---
#
# The previous version had three holes, each the same shape as the bugs it was meant to surface,
# and together they made it blind to the drift that actually happens here:
#   1. `for _f in "$SCRIPT_DIR"/*.sh` - only `.sh`, only the top directory. It could not see
#      pii-gate-parse.py, wa-send.js, gov-notify.ps1 or anything under tests/.
#   2. `[ -f "$_b" ] || continue` - a file ABSENT from the bundle was SKIPPED, not reported. A new
#      live hook that never reached the bundle was invisible, and that is the most consequential
#      drift of all: the one that publishes nothing while everything looks fine.
#   3. It compared the installer bundle only. The divergence measured on 2026-09-01 was in the
#      PROJECT MIRROR - 5 files behind, 2 missing - and this check never looked there.
# It also never stated how much it compared, so "no drift" was indistinguishable from "the
# comparison examined nothing" (gotcha #353).
#
# Why it must exist: the sync is PostToolUse, PostToolUse does not fire for Bash, so any session
# that edits with sed/python/cp leaves the copies diverged silently. The reconciler is
# `sync-governance-copies.sh --sync-all`; this is the thing that tells you to run it.
# Cost: one md5sum per directory (a few processes), not one cmp per file per destination.
_gov_dir_hashes() {
  # awk, NOT sed. Written through one layer of escaping too many, the sed form landed on disk with
  # its \1 backreference turned into a literal control character, so EVERY line was rewritten to
  # the same "hash" and the comparison found perfect agreement across a tree with a planted
  # divergence in it. Third escape-layer failure in one session to manufacture a false GREEN
  # (gotcha #353). The output is now built by awk from md5sum's own fields, and its shape is
  # ASSERTED below instead of assumed.
  [ -d "$1" ] || return 0
  ( cd "$1" 2>/dev/null || exit 0
    find . -type f ! -name '*.bak*' ! -name '*.tmp' ! -path './__pycache__/*' ! -path './services/*' \
      -exec md5sum {} + 2>/dev/null \
    | awk '{ h=$1; n=$2; sub(/^\*/,"",n); sub(/^\.\//,"",n);
             if (h ~ /^[0-9a-f]{32}$/ && n != "") print h" "n }' \
    | sort -k2 )
}
# The hasher must emit 32 hex digits. If it ever stops, every comparison below silently AGREES, so
# the shape is checked once here and a failure is announced rather than absorbed.
_GOV_HASHER_OK=1
case "$(_gov_dir_hashes "$SCRIPT_DIR" | head -1 | cut -d' ' -f1)" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) _GOV_HASHER_OK=0 ;;
esac

_GOV_DRIFT_DESTS="$HOME/.claude/governance-installer/bundle/hooks/governance"
if [ -f "$HOME/.claude/.governance-mirrors" ]; then
  while IFS= read -r _m; do
    _m="$(printf '%s' "$_m" | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -n "$_m" ] && [ -d "$_m/.claude/hooks/governance" ]; then
      _GOV_DRIFT_DESTS="$_GOV_DRIFT_DESTS
$_m/.claude/hooks/governance"
    fi
  done < "$HOME/.claude/.governance-mirrors"
fi
_GOV_LIVE_H="$(_gov_dir_hashes "$SCRIPT_DIR")"
_GOV_LIVE_N="$(printf '%s' "$_GOV_LIVE_H" | grep -c . )"
_GOV_DRIFT_MSG=""
_GOV_DEST_N=0
if [ "$_GOV_LIVE_N" -gt 0 ]; then
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    [ -d "$_d" ] || continue
    _GOV_DEST_N=$((_GOV_DEST_N + 1))
    _o="$(_gov_dir_hashes "$_d")"
    _diff=0; _abs=0; _names=""
    while IFS= read -r _line; do
      [ -n "$_line" ] || continue
      _h="${_line%% *}"
      _n="${_line#* }"
      _oh="$(printf '%s' "$_o" | awk -v k="$_n" '{h=$1; $1=""; sub(/^ /,""); if ($0==k) {print h; exit}}')"
      if [ -z "$_oh" ]; then
        _abs=$((_abs+1)); _names="$_names $_n(absent)"
      elif [ "$_oh" != "$_h" ]; then
        _diff=$((_diff+1)); _names="$_names $_n"
      fi
    done <<GOVDRIFTEOF
$_GOV_LIVE_H
GOVDRIFTEOF
    if [ "$_diff" -gt 0 ] || [ "$_abs" -gt 0 ]; then
      _GOV_DRIFT_MSG="$_GOV_DRIFT_MSG
  $_d - $_diff differing, $_abs absent:$(printf '%s' "$_names" | cut -c1-220)"
    fi
  done <<GOVDESTEOF
$_GOV_DRIFT_DESTS
GOVDESTEOF
fi
if [ "$_GOV_LIVE_N" -eq 0 ] || [ "$_GOV_DEST_N" -eq 0 ] || [ "$_GOV_HASHER_OK" = "0" ]; then
  gov_log "pre-session" "DRIFT CHECK INERT: live=$_GOV_LIVE_N destinations=$_GOV_DEST_N"
  echo "[GOVERNANCE DRIFT] The drift check examined NOTHING it could trust (live files: $_GOV_LIVE_N, destinations: $_GOV_DEST_N, hasher-ok: $_GOV_HASHER_OK). That is not agreement - it means the installer bundle and every mirror are unreachable from here."
elif [ -n "$_GOV_DRIFT_MSG" ]; then
  gov_log "pre-session" "DRIFT detected across $_GOV_DEST_N destination(s)"
  echo "[GOVERNANCE DRIFT] $_GOV_LIVE_N live governance file(s) compared against $_GOV_DEST_N copy location(s) - they do NOT agree:$_GOV_DRIFT_MSG"
  echo "  A file marked (absent) never reached that copy at all. Reconcile before editing hooks:  bash ~/.claude/hooks/governance/sync-governance-copies.sh --sync-all --dry-run"
  echo "  The per-file PostToolUse sync cannot do this: it never fires for a Bash edit, and it only ever copies the one file that was edited (GOTCHAS #355, task B7)."
else
  gov_log "pre-session" "drift check: $_GOV_LIVE_N file(s) x $_GOV_DEST_N destination(s) all agree"
fi


if [ -n "$CRASH_FLAG" ]; then
  if [ -n "$PARALLEL_HINT" ]; then
    echo "[GOVERNANCE PARALLEL SESSION?] A crashed session was archived ($ORPHAN_COUNT tracked writes) AND another Claude session is ALIVE ($PARALLEL_HINT). This is probably NOT a crash but a parallel session on this working tree. Follow GOVERNANCE-AGENT-GUIDE §16: commit only your own paths (git commit -- <paths>), never git add -A/-u/stash/checkout --/reset --hard, re-read files before editing, run /parallel-session-merge before any HANDOFF write. Then: (1) /context-governance lite, (2) /bootstrapper."
  else
    echo "[GOVERNANCE CRASH RECOVERY] A previous session CRASHED or was force-killed ($ORPHAN_COUNT file writes were tracked but end-session.sh never ran; its log was archived). Governance state may be stale. You MUST: (1) run /context-governance lite to check for drift, (2) run /bootstrapper, (3) check if HANDOFF.md and PLAN.md are up to date with the latest changes. Orphan log archived."
  fi
elif [ -n "$PARALLEL_HINT" ]; then
  echo "[GOVERNANCE PARALLEL SESSION?] Another Claude session is ALIVE ($PARALLEL_HINT). Follow GOVERNANCE-AGENT-GUIDE §16 (commit only your own paths, no git add -A/-u/stash/checkout --/reset --hard, re-read before edit, /parallel-session-merge before HANDOFF writes)."
fi

if gov_is_governed "$GOV_PROJECT_ROOT"; then
  gov_log "pre-session" "governed project detected (CONTEXT-MANIFEST.md found)"
  echo "[GOVERNANCE] Governed project detected. Execute Mandatory Session Start Protocol: (1) run /context-governance lite, (2) run /bootstrapper, (3) prepend briefing to first response. See ~/.claude/CLAUDE.md."
elif [ -f "$GOV_PROJECT_ROOT/CLAUDE.md" ] || [ -d "$GOV_PROJECT_ROOT/.git" ] || [ -f "$GOV_PROJECT_ROOT/package.json" ] || [ -f "$GOV_PROJECT_ROOT/Cargo.toml" ] || [ -f "$GOV_PROJECT_ROOT/pyproject.toml" ] || [ -f "$GOV_PROJECT_ROOT/go.mod" ] || [ -f "$GOV_PROJECT_ROOT/pom.xml" ] || [ -f "$GOV_PROJECT_ROOT/Makefile" ]; then
  gov_log "pre-session" "ungoverned project detected (has code markers but no CONTEXT-MANIFEST.md)"
  echo "[GOVERNANCE] Ungoverned project detected — code files exist but docs/context/CONTEXT-MANIFEST.md is missing. Run /init-governance NOW to scaffold the governance structure before any work begins. This is automatic — do not ask the user for permission, just run the skill."
else
  gov_log "pre-session" "not a project directory — skipping governance"
  gov_dry || touch "$SESSION_MARKER" 2>/dev/null
fi
gov_dry && echo "[GOVERNANCE DRY-RUN] pre-session: no state was changed"
exit 0
