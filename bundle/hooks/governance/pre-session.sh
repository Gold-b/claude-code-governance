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

# --- The updater NEVER runs in this hook's foreground (2026-09-26/27) ---
# 2.0.0 applied a staged release (and recovered an interrupted one) right here, with the hook's
# timeout raised 10 -> 120 s to fit it. SessionStart hooks block Claude Code's start-up, and the
# VS Code extension gives the whole start-up 60 s before failing with "Subprocess initialization did
# not complete within 60000ms" — an apply measures 18-28 s and a restore ~17 s, on top of this hook.
# 2.0.0 has no automatic update. The only updater work this hook does: spawn the detached ROLLBACK
# of an apply that was cut off (gov-update.sh --recover-detached) and print REPORT. The SessionEnd
# trigger of 2026-09-27 was removed on 2026-09-30. Everything else here only reports, with
# builtins, and the timeout is 10 s, never more.
_GOV_UPD_DIR="$HOME/.claude/.governance-update"
# This session is live again (a resume, or compact/clear mid-task): drop a `.gov-session-closed`
# marker on its own state dir. Nothing writes that marker when a session ends (there is no SessionEnd
# hook since 2026-09-30); the one writer is Step 1 below, in ANOTHER session's start-up, which marks
# a dir closed when it looks crashed (silent > 6 h with tracked changes) - and a long-idle session
# that is resumed looks exactly like that. gov-update.sh --apply skips a closed dir when it counts
# live sessions (upd_other_live), so a marker left in place would let a hand-run apply - one that
# should have deferred - swap hooks under this one.
# HERE, before any role gate: the later reset (Step 2) runs only on a SOURCE project.
# A builtin regex on the payload _common.sh already read - not $(gov_session_id), a subshell plus a
# four-process pipeline on every start in every project (~0.4 s under load, review 2026-09-27).
_GOV_SID0="${GOV_SESSION_ID:-}"
_GOV_SID_RE='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]*)"'
if [ -z "$_GOV_SID0" ] && [[ "${_GOV_HOOK_INPUT:-}" =~ $_GOV_SID_RE ]]; then _GOV_SID0="${BASH_REMATCH[1]}"; fi
case "$_GOV_SID0" in ''|*[!A-Za-z0-9_-]*) ;; *) gov_dry || rm -f "$HOME/.claude/logs/sessions/$_GOV_SID0/.gov-session-closed" 2>/dev/null ;; esac
# An interrupted apply is handled whatever the advisory's gates say: a half-applied tree is not an
# update, so a FROZEN role or GOVERNANCE_UPDATE_CHECK=0 must not leave it. One builtin file test
# when nothing was interrupted, which is every session.
if [ -f "$_GOV_UPD_DIR/APPLYING" ] && [ -f "$SCRIPT_DIR/gov-update.sh" ]; then
  _GOV_JPID=""
  # The braces put the redirect under 2>/dev/null: an apply finishing between the -f test and this
  # read removes the file, and a bare `done < file 2>/dev/null` still prints "No such file".
  { while IFS= read -r _GOV_JL; do
      case "$_GOV_JL" in pid=*) _GOV_JPID="${_GOV_JL#pid=}" ;; esac
    done < "$_GOV_UPD_DIR/APPLYING"; } 2>/dev/null
  case "$_GOV_JPID" in ''|*[!0-9]*) _GOV_JPID="" ;; esac
  if [ -n "$_GOV_JPID" ] && kill -0 "$_GOV_JPID" 2>/dev/null; then
    echo "[GOVERNANCE UPDATE] An update is being applied right now (pid $_GOV_JPID: a gov-update.sh --apply you ran in a terminal, or the restore of one that was cut off). A hand-run --apply prints its result in its own terminal; a background restore prints it here at the next session start. Hook files may change under this session for the next ~30 s - if a hook misbehaves, restart the session once it is done."
  elif [ ! -f "$_GOV_UPD_DIR/APPLYING" ]; then
    :   # it finished (or was restored) while we looked: nothing to report
  elif gov_dry; then
    echo "[GOVERNANCE UPDATE] (dry-run) An update was INTERRUPTED while being applied; a real start would roll it back in the background."
  else
    # The apply died mid-swap (the machine was shut down, the process killed). Running this session
    # whole on a half-updated tree is worse than a restore in the background: one short bash that
    # only spawns the detached rollback and returns (board, 2026-09-27). It rolls back; it never
    # starts an apply (source `recovery`, refused by upd_apply).
    bash "$SCRIPT_DIR/gov-update.sh" --recover-detached </dev/null >/dev/null 2>&1
    echo "[GOVERNANCE UPDATE] A gov-update.sh --apply was INTERRUPTED part-way; it is being rolled back to its backup in the background now (about 20 s). The result prints at the next session start (or: bash ~/.claude/hooks/governance/gov-update.sh --status). Restart this session once it is done."
  fi
elif [ -s "$_GOV_UPD_DIR/REPORT" ] && [ ! -L "$_GOV_UPD_DIR/REPORT" ] && [ ! -d "$_GOV_UPD_DIR/lock.d" ]; then
  # The result of the background restore of an interrupted apply (gov-update.sh --recover-detached
  # appends it to REPORT; nothing else runs in the background in 2.0.0). Not while an
  # apply or a fetch holds the lock: its last line may not be written yet. Only the updater's own
  # line shape is echoed, at most 20 lines, printable characters only - this text enters the model's
  # context, so nothing else in the file may ride along.
  _GOV_RN=0
  { while IFS= read -r _GOV_JL; do
      case "$_GOV_JL" in "[GOVERNANCE UPDATE] "*) ;; *) continue ;; esac
      _GOV_JL="${_GOV_JL//[^[:print:]]/}"
      [ "${#_GOV_JL}" -gt 600 ] && _GOV_JL="${_GOV_JL:0:600}..."
      echo "$_GOV_JL"
      _GOV_RN=$((_GOV_RN + 1)); [ "$_GOV_RN" -ge 20 ] && break
    done < "$_GOV_UPD_DIR/REPORT"; } 2>/dev/null
  # Emptied IN PLACE, not removed: a child spawned a moment ago may already hold it open, and its
  # line then lands in this same file and prints next time instead of vanishing with an unlinked one.
  gov_dry || : > "$_GOV_UPD_DIR/REPORT" 2>/dev/null
fi
if [ "$_GOV_ADVISORY_ELIGIBLE" = "1" ] && [ -f "$_GOV_UPD_DIR/READY" ] && [ ! -f "$_GOV_UPD_DIR/APPLYING" ] && [ -f "$SCRIPT_DIR/gov-update.sh" ]; then
  _GOV_RV=""
  { while IFS= read -r _GOV_JL; do
      case "$_GOV_JL" in version=*) _GOV_RV="${_GOV_JL#version=}"; _GOV_RV="${_GOV_RV%% *}"; break ;; esac
    done < "$_GOV_UPD_DIR/READY"; } 2>/dev/null
  gov_is_semver "$_GOV_RV" || _GOV_RV=""
  # 2.0.0 has no automatic update: a staged release exists only because the user ran --fetch, so
  # the line is printed whenever one is staged - no setting silences it and none is read here.
  if [ -n "$_GOV_RV" ]; then
    # --force-live for the hand-run, because a session dir counts as live for 10 minutes after its
    # last hook write - including the one that printed this line.
    echo "[GOVERNANCE UPDATE] v$_GOV_RV is downloaded and verified (your --fetch); nothing installs on its own. To install: close every Claude Code session, then in your own terminal run  bash ~/.claude/hooks/governance/gov-update.sh --apply --force-live"
  fi
fi
# HELD-TERMS (2026-09-30): a fetched release whose terms changed waits, none of its code run, until
# the human accepts. One glob test; the one fork (the record parser) runs only when a release is held.
# Named only while its staged tree exists: an install.sh run that cleared staged/ leaves no stale line.
if [ "$_GOV_ADVISORY_ELIGIBLE" = "1" ] && [ ! -f "$_GOV_UPD_DIR/APPLYING" ] && [ -f "$SCRIPT_DIR/gov-update.sh" ]; then
  for _GOV_HF in "$_GOV_UPD_DIR"/HELD-TERMS-*; do
    [ -f "$_GOV_HF" ] || break
    _GOV_HV="${_GOV_HF##*/HELD-TERMS-}"
    gov_is_semver "$_GOV_HV" && [ -f "$_GOV_UPD_DIR/staged/v$_GOV_HV/RELEASE-MANIFEST" ] || break
    _GOV_HT=$(gov_record_field "$_GOV_HF" terms_version 2>/dev/null)
    case "$_GOV_HT" in ''|*[!0-9]*) _GOV_HT="?" ;; esac
    echo "[GOVERNANCE UPDATE] v$_GOV_HV is waiting: its terms changed (v$_GOV_HT) and none of its code has run. For the human: read ~/.claude/.governance-update/staged/v$_GOV_HV/NOTICE-AUTO-UPDATE.md, then run in your own terminal: bash ~/.claude/hooks/governance/gov-update.sh --accept-terms   (it refuses when it detects an AI-agent session - a safeguard, not a guarantee)"
    break
  done
fi

if [ "$_GOV_ADVISORY_ELIGIBLE" = "1" ]; then

  _GOV_LATEST="$HOME/.claude/logs/.governance-latest"
  # B13: overridable so a private-repo operator can point it at an authenticated/raw-with-token
  # VERSION (the default 404s to an unauthenticated fetch while the repo is PRIVATE).
  _GOV_URL="${GOV_UPDATE_VERSION_URL:-https://raw.githubusercontent.com/Gold-b/claude-code-governance/master/bundle/VERSION}"

  _LOCAL_V=""
  gov_read_version_var _LOCAL_V "$HOME/.claude/.governance-version"
  gov_is_semver "$_LOCAL_V" || _LOCAL_V=""

  # B13: surface an INERT advisory instead of failing soft and silent. The background fetch (from
  # a PRIOR session) records the HTTP code whenever it cannot get a usable VERSION; a 4xx is the
  # known permanent state while the repo is PRIVATE (an unauthenticated raw.githubusercontent
  # fetch 404s). Say so — throttled to once / 12h so it is visible without being noise.
  _GOV_STATUS_F="$HOME/.claude/logs/.governance-version-status"
  if [ -n "$_LOCAL_V" ] && [ ! -s "$_GOV_LATEST" ] && [ -s "$_GOV_STATUS_F" ]; then
    _GOV_HTTP=$(tr -d '[:space:]' < "$_GOV_STATUS_F" 2>/dev/null)
    case "$_GOV_HTTP" in
      401|403|404)
        _GOV_UNREACH_MARK="$HOME/.claude/logs/.governance-advised-unreachable"
        if [ -z "$(find "$_GOV_UNREACH_MARK" -maxdepth 0 -mmin -720 2>/dev/null)" ]; then
          touch "$_GOV_UNREACH_MARK" 2>/dev/null
          gov_log "pre-session" "update advisory INERT: VERSION source returned HTTP $_GOV_HTTP (repo private?)"
          echo "[GOVERNANCE UPDATE] The framework update check is INERT: the published VERSION source returned HTTP $_GOV_HTTP (the governance repo is PRIVATE, or the path moved), so this machine cannot tell whether a newer version exists. This is expected while the repo stays private. Point GOV_UPDATE_VERSION_URL at a reachable VERSION, or silence with GOVERNANCE_UPDATE_CHECK=0."
        fi
        ;;
    esac
  fi

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
          # 2.0.0 has NO automatic update: this hook tells, it never downloads. It spawns no
          # gov-update.sh --fetch and reads no setting that could make it (owner decision
          # 2026-09-29/30; a test goes red if a spawn comes back). A version the user's own --fetch
          # halted keeps its line; otherwise the legacy manual line, word for word, plus the signed
          # manual path when the updater sits beside this file.
          if [ -f "$SCRIPT_DIR/gov-update.sh" ] && [ -f "$_GOV_UPD_DIR/HALT-$_REMOTE_V" ]; then
            _GOV_HALT=""
            read -r _GOV_HALT < "$_GOV_UPD_DIR/HALT-$_REMOTE_V" 2>/dev/null || true
            _GOV_HALT="${_GOV_HALT#reason=}"; _GOV_HALT="${_GOV_HALT%% *}"
            gov_is_semver "$_REMOTE_V" || _GOV_HALT="unknown"
            case "$_GOV_HALT" in
              no-tag) echo "[GOVERNANCE UPDATE] v$_REMOTE_V is published as a VERSION but has no release tag - nothing to install; this is a maintainer problem, not yours. This machine stays on v$_LOCAL_V." ;;
              # The same advice as gov-update.sh upd_halt_advice: --clear-halt re-checks against the
              # same pinned key, so after a key rotation it would fail the same way (finding 7).
              signature) echo "[GOVERNANCE UPDATE] v$_REMOTE_V was NOT installed (halted: signature) - nothing changed on this machine, it stays on v$_LOCAL_V. Read ~/.claude/logs/governance-update.log. The release is not signed by the key pinned on this machine: if the maintainer rotated the key, re-pin from a FRESH clone (README, \"Release signing key\"); --clear-halt alone will fail the same way." ;;
              *) echo "[GOVERNANCE UPDATE] v$_REMOTE_V was NOT installed (halted: ${_GOV_HALT:-unknown}) - nothing changed on this machine, it stays on v$_LOCAL_V. Read ~/.claude/logs/governance-update.log. To retry after the cause is fixed: bash ~/.claude/hooks/governance/gov-update.sh --clear-halt" ;;
            esac
          else
            _GOV_SIGNED=""
            [ -f "$SCRIPT_DIR/gov-update.sh" ] && _GOV_SIGNED=" Signed manual update: bash ~/.claude/hooks/governance/gov-update.sh --fetch $_REMOTE_V  then, with every session closed,  --apply --force-live  (run these yourself; nothing installs on its own)."
            echo "[GOVERNANCE UPDATE] Context Governance v$_REMOTE_V is published; this machine has v$_LOCAL_V. Update deliberately: git pull in your clone of Gold-b/claude-code-governance, then 'bash install.sh --force' (it backs up first). Nothing installs on its own — install.sh replaces hooks and skills that are running right now. Silence with GOVERNANCE_UPDATE_CHECK=0.$_GOV_SIGNED"
          fi
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
        # B13: capture the HTTP status (drop -f so a 404 is visible, not swallowed). Body to a
        # temp file, code from -w, so a private-repo 404 is RECORDED rather than silently touched.
        _bodyf="$_GOV_LATEST.body.$$"
        _code=$(curl -sS -m 3 -o "$_bodyf" -w '%{http_code}' "$_GOV_URL" 2>/dev/null)
        _v=$(tr -d '[:space:]' < "$_bodyf" 2>/dev/null)
        rm -f "$_bodyf" 2>/dev/null
        case "$_code" in ''|*[!0-9]*) _code=000 ;; esac
        if gov_is_semver "$_v" && [ "$_code" = "200" ]; then
          _tmp="$_GOV_LATEST.$$"
          echo "$_v" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$_GOV_LATEST" 2>/dev/null
          rm -f "$_tmp" 2>/dev/null
          rm -f "$HOME/.claude/logs/.governance-version-status" 2>/dev/null
        else
          # Record WHY there is no usable version (an HTTP code) instead of a silent touch, so the
          # foreground can announce the advisory is INERT. 4xx is the known state while PRIVATE.
          touch "$_GOV_LATEST" 2>/dev/null
          echo "$_code" > "$HOME/.claude/logs/.governance-version-status" 2>/dev/null
          gov_log "pre-session" "update advisory: VERSION fetch HTTP $_code (no usable version) — INERT (repo private? set GOV_UPDATE_VERSION_URL, or silence GOVERNANCE_UPDATE_CHECK=0)"
        fi
      ) >/dev/null 2>&1 &
    fi
  fi
fi

# ── STALE PUBLISH QUEUE — one line at session start (4.1, 1.7.0) ───────────────────────────
#
# WHAT THIS IS NOT: it is not a step toward auto-publishing. GOV_PUBLISH=1 stays a deliberate,
# per-close human act, forever — it is the one place a human reviews what leaves the machine,
# and the publish path does real work unattended (fresh clone, stage, push).
#
# THE ACTUAL DEFECT. A HELD queue was announced ONLY at Stop, inside a wall of close output,
# at the moment attention is lowest. MEASURED 2026-09-18: the queue held 18 distinct files,
# the oldest entry dated 2026-09-14 — four days of "queued for session end" that no session
# end ever mentioned twice. A reminder that only fires where nobody reads it is not a
# reminder; session START is where a decision can still be acted on.
#
# Deliberately NOT a server cron, and this is worth writing down so nobody "fixes" it into
# one: the Server-Only Automation rule sends monitors to the remote host, but this queue
# exists only on this PC and only a session HERE can publish it. A session-start line is the
# correct shape for a PC-local, session-actionable fact.
#
# Never blocking, once per session, and silenced by GOV_PUBLISH_NAG_DAYS=0.
_GOV_NAG_DAYS="${GOV_PUBLISH_NAG_DAYS:-7}"
_GOV_PUSH_FLAG="$HOME/.claude/logs/.governance-push-pending"
if [ "$_GOV_NAG_DAYS" != "0" ] && [ -s "$_GOV_PUSH_FLAG" ] && ! gov_dry; then
  # UNIQUE FILES, not lines. The flag is append-only, so one file edited three times is three
  # lines: the raw count overstated the queue 3x (52 lines / 18 files, MEASURED). A count that
  # exaggerates is a count that gets discounted.
  _GOV_NAG_N=$(sed 's|^[^ ]* ||' "$_GOV_PUSH_FLAG" 2>/dev/null | sort -u | grep -c . )
  [ -n "$_GOV_NAG_N" ] || _GOV_NAG_N=0
  if [ "$_GOV_NAG_N" -gt 0 ] 2>/dev/null; then
    # Age from the OLDEST line's own timestamp, not the file mtime: the file is appended to on
    # every governance edit, so its mtime is always "now" and would report age 0 forever.
    _GOV_NAG_OLDEST=$(awk 'NF{print $1; exit}' "$_GOV_PUSH_FLAG" 2>/dev/null | cut -c1-10)
    _GOV_NAG_AGE=""
    case "$_GOV_NAG_OLDEST" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
        _GOV_NAG_T0=$(date -d "$_GOV_NAG_OLDEST" +%s 2>/dev/null)
        _GOV_NAG_NOW=$(date +%s 2>/dev/null)
        if [ -n "$_GOV_NAG_T0" ] && [ -n "$_GOV_NAG_NOW" ] && [ "$_GOV_NAG_NOW" -ge "$_GOV_NAG_T0" ] 2>/dev/null; then
          _GOV_NAG_AGE=$(( (_GOV_NAG_NOW - _GOV_NAG_T0) / 86400 ))
        fi
        ;;
    esac
    # Undecidable age => stay SILENT about the number rather than print a wrong one. The queue
    # is still reported at close either way; this line only exists to be trustworthy.
    if [ -n "$_GOV_NAG_AGE" ] && [ "$_GOV_NAG_AGE" -ge "$_GOV_NAG_DAYS" ] 2>/dev/null; then
      _GOV_NAG_FILE=$(sed 's|^[^ ]* ||' "$_GOV_PUSH_FLAG" 2>/dev/null | grep . | head -1)
      gov_log "pre-session" "stale publish queue: $_GOV_NAG_N file(s), oldest $_GOV_NAG_AGE day(s) (threshold $_GOV_NAG_DAYS)"
      echo "[GOVERNANCE] $_GOV_NAG_N governance file(s) have waited $_GOV_NAG_AGE days for GOV_PUBLISH=1 (oldest: $_GOV_NAG_FILE). Publish deliberately, or clear the queue: rm \"$_GOV_PUSH_FLAG\". Silence with GOV_PUBLISH_NAG_DAYS=0."
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
  # $'\t', not "$(printf '\t')": the condition is re-evaluated on every iteration, and a command
  # substitution there forked once per session dir (~120 ms each on Windows, 2026-09-26).
  while IFS=$'\t' read -r o_sid o_age o_state o_changes; do
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
  # The id gov_session_id already read at the top (GOV_SID), not a second parse of the same payload
  # in a python process (2026-09-26: ~300 ms on Windows, in a hook that blocks start-up). It is also
  # the id every other hook uses, which is what a reader of this stamp compares it with.
  _GOV_SID="$GOV_SID"
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
    # comment, then leading and trailing whitespace - builtins, not a sed per line
    _m="${_m%%#*}"; _m="${_m#"${_m%%[![:space:]]*}"}"; _m="${_m%"${_m##*[![:space:]]}"}"
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
    # ONE awk per destination (2026-09-26). The per-file loop forked an awk for every live file
    # against every destination - 62 files x 2 destinations = 124 forks, seconds on Windows, inside a
    # SessionStart hook that blocks start-up. Output: "<differing> <absent>[ name...]".
    _res="$(printf '%s\n@@GOV-LIVE@@\n%s\n' "$_o" "$_GOV_LIVE_H" | awk '
      $0 == "@@GOV-LIVE@@" { live = 1; next }
      $0 == "" { next }
      { h = $0; sub(/ .*/, "", h); n = substr($0, length(h) + 2) }
      !live { if (!(n in o)) o[n] = h; next }
      { if (!(n in o)) { abs++; names = names " " n "(absent)" } else if (o[n] != h) { dif++; names = names " " n } }
      END { printf "%d %d%s", dif, abs, names }')"
    _diff="${_res%% *}"; _res="${_res#* }"; _abs="${_res%% *}"; _names="${_res#"$_abs"}"
    case "$_diff$_abs" in ''|*[!0-9]*) _diff=0; _abs=1; _names=" (drift comparison failed)" ;; esac
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
