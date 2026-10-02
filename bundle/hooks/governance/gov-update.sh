#!/usr/bin/env bash
# gov-update.sh — signed, verified, rollback-safe MANUAL updates of this framework (2.0.0).
#
# 2.0.0 has NO automatic update and no setting, variable, record or flag that turns one on (owner
# decision 2026-09-29/30). This script is registered on NO hook event. Its only caller that is not
# a human is pre-session.sh, and only as `--recover-detached` when an apply died mid-swap: that
# restores the backup in the background and never applies anything. `--fetch` and `--apply` are the
# user's own acts, run by hand; nothing spawns them. The predicate that would allow an unattended
# apply is gov_auto_update_on (consent-lib.sh), and it is false unconditionally in this version.
#
# THE CONTRACT, in one paragraph. A release is installed only when its RELEASE-MANIFEST verifies
# under the release key PINNED on this machine (~/.claude/.governance-update/allowed_signers,
# trusted on first install), when every file of the downloaded TAG archive matches the manifest's
# SHA-256 and the archive holds no file the manifest does not list, when every install destination
# is a safe relative path under hooks/ skills/ docs/ agents/, and when every script parses. The
# apply backs up every file it will touch BEFORE the first write, moves files into place by atomic
# rename (_common.sh first), merges only the framework's own settings.json entries, runs verify.sh,
# and on any failure restores the backup and HALTS that version until a human clears it. It never
# runs on the release source machine, never while another session is live (unless --force-live),
# never over files the user modified locally, and never under terms the user has not accepted.
#
# Modes (every mode is a --flag, so _common.sh never waits on stdin — v1.7.3 rule; the session id,
# when a caller has one, arrives in GOV_SESSION_ID; pre-session.sh passes none since 2026-09-26):
#   --fetch <ver>          Phase A (human): download, verify, stage, write READY; the next session
#                          start prints that the release is staged. A release whose terms_version is
#                          above the accepted one is HELD instead (HELD-TERMS-<ver>, no READY):
#                          checked up to syntax, but none of its code runs until --accept-terms.
#                          Every run ends with ONE [GOVERNANCE UPDATE] line on stdout saying what
#                          happened: staged, held, halted, refused and why (URL, source machine,
#                          not a version, not newer, governance off, no network switch), or skipped
#                          and why (already staged, attempt limit, spacing, lock, 404, network);
#                          the log keeps its line too. Exit status 0 on every path.
#   --apply-if-ready       The entry point of the detached recovery child: rolls an interrupted apply
#                          back, then returns. It NEVER applies a staged release (not in this version).
#   --recover-detached     pre-session.sh: roll an interrupted apply back, detached. Never applies.
#   --apply [--force-live] Phase B now (human). --force-live ignores the live-session deferral.
#   --rollback [<dir>]     Restore the last (or the named) update backup and halt that version.
#   --status               What is installed, staged, halted, pinned, accepted.
#   --verify-archive <tgz> Phase A checks on a local archive, nothing written. Exit 0 = verified.
#   --accept-terms         Record acceptance of the staged release's terms (typed I ACCEPT on a tty,
#                          or GOV_ACCEPT_TERMS=1). Installs nothing; a HELD release is then deep-
#                          verified (its first code to run here) and becomes READY. Refuses when it
#                          detects an AI-agent session (a safeguard, not a guarantee: anything that
#                          runs under your account can act as you; consent-lib.sh
#                          gov_human_consent_ok, C3); the record
#                          carries notice_sha256 / shown_sha256 of the text printed (C5), 0600.
#   --clear-halt           Remove every HALT and reset the fetch counters (a HELD-TERMS stays).
#   --selftest             Offline positive/negative controls of the verification chain.
#
# Environment:
#   (no variable turns an automatic update on, off or pauses it: there is none in this version)
#   GOV_REPO_PATH / GOV_RELEASE_KEY  mark the release source machine (also read — with grep, never
#                                `source` — from ~/.claude/.governance-local.env, which can hold a
#                                real token); that machine never fetches or applies
#   GOVERNANCE_UPDATE_CHECK=0    no network at all: the session-start check is off and --fetch
#                                downloads nothing (it says so)
#   GOV_UPDATE_ARCHIVE_URL       default https://github.com/Gold-b/claude-code-governance/archive/refs/tags/v%s.tar.gz
#   GOV_UPDATE_ALLOW_FILE=1      accept a file:// archive URL (tests only)
#   GOV_UPDATE_MAX_ATTEMPTS (10) GOV_UPDATE_ATTEMPT_SPACING (3600 s)
#   GOV_UPDATE_SKIP_DEEP_VERIFY=1  skip the scanner selftest on the staged tree (tests only; announced)
#   GOV_UPDATE_OVERWRITE_LOCAL=1 apply over locally modified files (they are in the backup)
#   GOV_UPDATE_APPLY_BUDGET      seconds an apply may spend before verify.sh (default 600 for
#                                --apply); over it -> clean rollback, not a SIGKILL
#   GOV_UPDATE_VERIFY_TIMEOUT    bound on verify.sh (default 20 s; it takes 1-3 s)
#   GOV_UPDATE_ROLLBACK_ANY=1    let --rollback restore a backup that is not of the installed version
#
# THE TIME BUDGET. The apply was designed to run unattended inside a hook (2.0.0 has no such caller
# - see the header), and a process killed mid-apply leaves an unfinished apply to roll back. So every
# phase is bounded against ONE clock, the script's own SECONDS (pre-checks included): backup + swap
# + installer refresh must finish inside APPLY_BUDGET (600 for --apply), verify.sh inside VERIFY_TIMEOUT (20),
# and a rollback's own re-verify inside 10. The RESTORE itself is deliberately NOT interruptible —
# a half-restored tree is the one state worse than a half-applied one — and it costs about what the
# swap cost (the same per-directory renames; 17-18 s for a whole release, MEASURED idle). So the
# worst case is roughly budget + 20 + swap-time + 10; T12 measures it under load. Files move in per-directory batches of renames
# (one process per directory, not three per file), which is what keeps this in seconds on Windows,
# where a fork costs 20-70 ms.
#
# State: ~/.claude/.governance-update/ (see NOTICE-AUTO-UPDATE.md §5). Log:
# ~/.claude/logs/governance-update.log. Backups: ~/.claude/backups/governance-update-<ts>/.
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { echo "[GOVERNANCE UPDATE] cannot load _common.sh beside $0 - nothing done" >&2; exit 1; }
# The recovery spawner verifies nothing itself (its detached child loads this again), and
# pre-session.sh waits for it: skip ~0.1-0.3 s of parsing.
case "${1:-}" in
  --recover-detached) ;;
  *)
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/release-manifest.sh" 2>/dev/null || { echo "[GOVERNANCE UPDATE] cannot load release-manifest.sh beside $0 - nothing done" >&2; exit 1; } ;;
esac

CH="$HOME/.claude"
UPD="$CH/.governance-update"
LOGF="$CH/logs/governance-update.log"
BACKUPS="$CH/backups"
GI="$CH/governance-installer"
URL_TMPL="${GOV_UPDATE_ARCHIVE_URL:-https://github.com/Gold-b/claude-code-governance/archive/refs/tags/v%s.tar.gz}"
MAX_ATTEMPTS="${GOV_UPDATE_MAX_ATTEMPTS:-10}"
SPACING="${GOV_UPDATE_ATTEMPT_SPACING:-3600}"
APPLY_BUDGET="${GOV_UPDATE_APPLY_BUDGET:-}"
VERIFY_TIMEOUT="${GOV_UPDATE_VERIFY_TIMEOUT:-20}"
MAX_BYTES=20971520          # compressed download cap
MAX_UNPACKED=104857600      # uncompressed cap: a 20 MB gzip bomb must not fill the disk before verify
MAX_MEMBERS=5000
LIVE_WINDOW_MIN=10
for _n in MAX_ATTEMPTS SPACING VERIFY_TIMEOUT; do
  eval "_v=\$$_n"
  case "$_v" in ''|*[!0-9]*) eval "$_n=0" ;; esac
done
case "$APPLY_BUDGET" in ''|*[!0-9]*) APPLY_BUDGET="" ;; esac
[ "$MAX_ATTEMPTS" -gt 0 ] || MAX_ATTEMPTS=10
[ "$VERIFY_TIMEOUT" -gt 0 ] || VERIFY_TIMEOUT=20

LOCK="$UPD/lock.d"
LOCK_HELD=0
LOCK_WHY=""
MV_RETRIES=0

# ── small helpers ────────────────────────────────────────────────────────────────────────────
upd_log() {
  local m="" ts=""
  # Builtins on bash >= 4.2 (the same byte-for-byte result as `tr | tr` + `date`, see gov_log):
  # three forks per log line are ~0.1 s on Windows.
  if [ "${BASH_VERSINFO[0]:-0}" -ge 5 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 2 ]; }; then
    local LC_ALL=C
    m="${2//[$'\n\r']/}"; m="${m//[^[:print:]]/}"
    printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1 2>/dev/null || ts=""
  else
    m=$(printf '%s' "$2" | tr -d '\n\r' | tr -cd '[:print:]')
  fi
  [ -n "$ts" ] || ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
  [ -d "${LOGF%/*}" ] || mkdir -p "${LOGF%/*}" 2>/dev/null
  [ -L "$LOGF" ] && return 0
  printf '[%s] [%s] %s\n' "$ts" "$1" "$m" >> "$LOGF" 2>/dev/null
}
say() { printf '[GOVERNANCE UPDATE] %s\n' "$*"; }
# upd_tilde <path> -> the path with $HOME shown as ~. NOT ${p/#$HOME/~}: bash tilde-expands that
# replacement back into $HOME, so the "short" form printed the full path (MEASURED, T6).
upd_tilde() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }
now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; }

# The machine-local env file (~/.claude/.governance-local.env) is read ONLY through
# gov_local_env_get (consent-lib.sh): process environment first, else grep, never `source` - the
# file can carry a real token. There is no automatic update to read a switch for: the one
# predicate that would allow an unattended apply is gov_auto_update_on, false in this version.

# The release source machine never updates itself: its live tree is where releases are MADE.
SRC_REASON=""
upd_is_source() {
  if [ -e "$CH/.governance-source" ]; then SRC_REASON="marker ~/.claude/.governance-source"; return 0; fi
  if [ -n "$(gov_local_env_get GOV_REPO_PATH)" ]; then SRC_REASON="GOV_REPO_PATH is set"; return 0; fi
  if [ -n "$(gov_local_env_get GOV_RELEASE_KEY)" ]; then SRC_REASON="GOV_RELEASE_KEY is set"; return 0; fi
  return 1
}

# First non-blank line of the marker, whitespace removed. Plain sed: gov_read_version_var uses
# `read -N`, which bash 3.2 (macOS) does not have, and a missing marker must not read as a version.
upd_installed_version() {
  local v
  v=$(sed -n '/[^[:space:]]/{s/[[:space:]]//g;p;q;}' "$CH/.governance-version" 2>/dev/null)
  gov_is_semver "$v" || v=""
  printf '%s' "$v"
}

upd_age() {  # seconds since mtime of $1 (large when missing)
  local m; m=$(gov_mtime "$1")
  [ "$m" = "0" ] && { echo 999999999; return; }
  echo $(( $(date +%s) - m ))
}

upd_count() { local n=""; [ -f "$1" ] && read -r n < "$1" 2>/dev/null; case "$n" in ''|*[!0-9]*) n=0 ;; esac; echo "$n"; }

upd_write() {  # upd_write <file> <content> — tmp + rename in the same directory
  local f="$1" t="$1.tmp.$$"
  printf '%s\n' "$2" > "$t" 2>/dev/null && mv -f "$t" "$f" 2>/dev/null || { rm -f "$t"; return 1; }
}

# upd_halt_advice <reason> -> what a human does next about a halted version. A signature halt is
# not cured by --clear-halt: the retry checks against the same pinned key and fails the same way.
upd_halt_advice() {
  case "$1" in
    signature) printf '%s' 'The release is not signed by the key pinned on this machine: if the maintainer rotated the key, re-pin from a FRESH clone (README, "Release signing key"); --clear-halt alone will fail the same way.' ;;
    *) printf '%s' 'To retry after the cause is fixed: bash ~/.claude/hooks/governance/gov-update.sh --clear-halt' ;;
  esac
}

# upd_halt_quiet <ver> <reason> [detail]: write HALT-<ver> and log it. Only for callers that print
# their own, more specific line (a rollback, a prepare that failed, a downgrade): the generic line
# below says "nothing was prepared or installed", which is false after an apply was rolled back.
upd_halt_quiet() {
  mkdir -p "$UPD" 2>/dev/null
  upd_write "$UPD/HALT-$1" "reason=$2 at=$(now_iso) detail=$(printf '%s' "${3:-}" | tr -d '\n\r' | cut -c1-300)"
  upd_log halt "v$1 reason=$2 ${3:-}"
}

# upd_halt <ver> <reason> [detail]: halt AND say so. Before 2026-09-30 it only logged, so a --fetch
# that refused a release printed nothing at all (review finding 7). A detached recovery child's
# output lands in REPORT, which pre-session.sh prints; it reaches only upd_halt_quiet (rollback).
upd_halt() {
  upd_halt_quiet "$@"
  say "v$1 is halted (reason: $2) - nothing was prepared or installed. Details: ~/.claude/logs/governance-update.log. $(upd_halt_advice "$2")"
}

# The apply journal: one key per line, so a home directory whose name contains a space parses whole.
upd_journal() { sed -n "s/^$1=//p" "$UPD/APPLYING" 2>/dev/null | head -1; }

upd_alive() { [ -n "$1" ] && [ "$1" != "$$" ] && kill -0 "$1" 2>/dev/null; }

# ── cross-session lock (mkdir is atomic everywhere; flock is absent on Git Bash) ─────────────────
# Stale = the recorded pid is provably dead, or (pid unreadable and the lock older than 30 min).
# BREAKING a stale lock is itself serialised by a second mkdir mutex: without it, two processes
# that both read the same dead pid could each remove the lock — the second one removing the FIRST
# one's fresh lock — and both would proceed. Under the mutex the pid is re-read before removal.
# Residual, stated not solved: the mutex's own staleness (> 60 s, i.e. a breaker that crashed while
# holding it) is checked then removed without an atomic step between, so two starters arriving in
# the same instant after such a crash could both pass. It needs a crash inside a 2-line window
# followed by a same-instant collision; the lock still records one holder and the loser's work is
# idempotent (fetch) or journaled (apply).
upd_lock() {
  # LOCK_WHY tells a caller that prints its own line which refusal it was: "state-dir" (the state
  # folder cannot be created) or "busy" (another live process holds the lock).
  LOCK_WHY="busy"
  mkdir -p "$UPD" 2>/dev/null || { LOCK_WHY="state-dir"; upd_log lock "cannot create $UPD - $1 skipped"; return 1; }
  local pid age tries=0 brk="$UPD/lock.break.d"
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    if mkdir "$LOCK" 2>/dev/null; then
      printf 'pid=%s since=%s mode=%s\n' "$$" "$(now_iso)" "$1" > "$LOCK/info" 2>/dev/null
      LOCK_HELD=1
      return 0
    fi
    pid=$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$LOCK/info" 2>/dev/null | head -1)
    if [ -f "$LOCK/info" ]; then age=$(upd_age "$LOCK/info"); else age=$(upd_age "$LOCK"); fi
    if { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; } || { [ -z "$pid" ] && [ "$age" -gt 1800 ]; }; then
      [ -d "$brk" ] && [ "$(upd_age "$brk")" -gt 60 ] && rmdir "$brk" 2>/dev/null
      if mkdir "$brk" 2>/dev/null; then
        # Re-check under the mutex: the lock may have been re-taken by a live process meanwhile.
        if [ "$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$LOCK/info" 2>/dev/null | head -1)" = "$pid" ]; then
          rm -rf "$LOCK" 2>/dev/null
          upd_log lock "stale lock broken (pid=${pid:-unreadable} age=${age}s)"
        fi
        rmdir "$brk" 2>/dev/null
      fi
      continue
    fi
    upd_log lock "locked by pid=${pid:-?} (age ${age}s) - $1 skipped"
    return 1
  done
  return 1
}
upd_unlock() { if [ "$LOCK_HELD" = "1" ]; then rm -rf "$LOCK" 2>/dev/null; LOCK_HELD=0; fi; }
trap 'upd_unlock' EXIT

# ── archive handling (Phase A steps 3-9; shared by --fetch and --verify-archive) ─────────────────
EX_REASON=""; EX_DETAIL=""
# upd_extract <tgz> <empty-dir>: bound it, pre-scan every member, then extract with the top dir stripped.
upd_extract() {
  local tgz="$1" dir="$2" names listing top bad usz nm
  EX_REASON="archive"; EX_DETAIL=""
  # Uncompressed size BEFORE anything is written: stream-count at most MAX_UNPACKED+1 bytes.
  usz=$(gzip -dc "$tgz" 2>/dev/null | head -c $((MAX_UNPACKED + 1)) | wc -c | tr -d ' ')
  case "$usz" in ''|*[!0-9]*) usz=0 ;; esac
  [ "$usz" -gt 0 ] || { EX_DETAIL="not a readable .tar.gz"; return 1; }
  [ "$usz" -le "$MAX_UNPACKED" ] || { EX_DETAIL="unpacks to more than $MAX_UNPACKED bytes"; return 1; }
  names=$(tar -tzf "$tgz" 2>/dev/null) || { EX_DETAIL="not a readable .tar.gz"; return 1; }
  [ -n "$names" ] || { EX_DETAIL="empty archive"; return 1; }
  nm=$(printf '%s\n' "$names" | grep -c .)
  [ "$nm" -le "$MAX_MEMBERS" ] || { EX_DETAIL="$nm members (cap $MAX_MEMBERS)"; return 1; }
  top="${names%%/*}"
  bad=$(printf '%s\n' "$names" | awk -v top="$top" '
    { n = $0
      if (n ~ /^\// || n ~ /^[A-Za-z]:/) { print "absolute: " n; exit }
      if (n ~ /[[:space:]]/) { print "whitespace in a member name: " n; exit }
      if (index(n, top "/") != 1 && n != top) { print "second top directory: " n; exit }
      m = split(n, p, "/"); for (i = 1; i <= m; i++) if (p[i] == "..") { print "dot-dot: " n; exit }
    }')
  [ -z "$bad" ] || { EX_DETAIL="$bad"; return 1; }
  # Only regular files and directories. A symlink or hard link in a release archive has no
  # legitimate use here and could point an install destination anywhere.
  # --numeric-owner: owner and group print as numbers, so a crafted owner NAME containing a space
  # cannot shift the size column (MEASURED in review: "a b" moved the date into the size field).
  listing=$(tar --numeric-owner -tvzf "$tgz" 2>/dev/null) || { EX_DETAIL="cannot list members"; return 1; }
  bad=$(printf '%s\n' "$listing" | awk 'length($0) && substr($0,1,1) != "-" && substr($0,1,1) != "d" { print; exit }')
  [ -z "$bad" ] || { EX_DETAIL="non-regular member: $bad"; return 1; }
  # The stream count above misses a SPARSE member: 170 bytes of archive declared a 200 MB file and
  # passed it (MEASURED in review). So the DECLARED sizes are summed too. GNU tar lists
  # "mode uid/gid SIZE ..." (field 3); bsdtar "mode links uid gid SIZE ..." (field 5). A size that
  # is not a plain number means the listing is not what this parser knows: refuse, never guess.
  bad=$(printf '%s\n' "$listing" | awk 'length($0) { v = (index($2, "/") ? $3 : $5); if (v !~ /^[0-9]+$/) { print; exit } }')
  [ -z "$bad" ] || { EX_DETAIL="unreadable member size: $bad"; return 1; }
  usz=$(printf '%s\n' "$listing" | awk 'length($0) { s += (index($2, "/") ? $3 : $5) } END { printf "%.0f", s }')
  case "$usz" in ''|*[!0-9]*) EX_DETAIL="cannot read member sizes"; return 1 ;; esac
  [ "$usz" -le "$MAX_UNPACKED" ] || { EX_DETAIL="members declare $usz bytes, more than $MAX_UNPACKED"; return 1; }
  mkdir -p "$dir" || { EX_DETAIL="cannot create $dir"; return 1; }
  tar -xzf "$tgz" -C "$dir" --strip-components=1 2>/dev/null || { EX_DETAIL="extraction failed"; return 1; }
  EX_REASON=""
  return 0
}

VERIFY_REASON=""; VERIFY_DETAIL=""
# upd_verify_tree <tree> <ver> <allowed_signers> <full|syntax|recheck>
#   recheck  steps 3-7: signature, every hash, the file set, the install map. Reads only.
#   syntax   + step 8: every script parses (bash -n / node --check). Still EXECUTES nothing.
#   full     + step 9: upd_deep_verify, which RUNS the release's own scanner selftest.
# upd_fetch stops at `syntax` and runs step 9 only once the release's terms are accepted: a release
# whose terms changed is HELD before any of its code has run (HELD-TERMS, 2026-09-30).
upd_verify_tree() {
  local t="$1" v="$2" signers="$3" lvl="$4" m src f sb out
  VERIFY_REASON=""; VERIFY_DETAIL=""
  m="$t/RELEASE-MANIFEST"
  if [ ! -s "$m" ] || [ ! -s "$t/RELEASE-MANIFEST.sig" ]; then
    VERIFY_REASON="manifest"; VERIFY_DETAIL="RELEASE-MANIFEST or RELEASE-MANIFEST.sig missing"; return 1
  fi
  VERIFY_DETAIL=$(relman_validate_header "$m" "$v" 2>&1) || { VERIFY_REASON="manifest"; return 1; }
  if ! relman_have_sshsig; then
    VERIFY_REASON="no-ssh-keygen-Y"
    VERIFY_DETAIL="this machine's ssh-keygen cannot verify signatures (-Y needs OpenSSH 8.2+); nothing is ever installed unverified"
    return 1
  fi
  [ -s "$signers" ] || { VERIFY_REASON="signature"; VERIFY_DETAIL="no pinned release key at $signers - re-run install.sh"; return 1; }
  relman_verify_sig "$m" "$t/RELEASE-MANIFEST.sig" "$signers" \
    || { VERIFY_REASON="signature"; VERIFY_DETAIL="RELEASE-MANIFEST is not signed by the pinned key (or the key's validity window has passed)"; return 1; }
  VERIFY_DETAIL=$(relman_verify_tree "$m" "$t" 2>&1) || { VERIFY_REASON="checksum"; return 1; }
  VERIFY_DETAIL=$(relman_check_map "$m" "$t" 2>&1) || { VERIFY_REASON="install-map"; return 1; }
  VERIFY_DETAIL=""
  [ "$lvl" = "recheck" ] && return 0
  # Step 8: every script in the map must at least parse.
  while read -r src _; do
    f="$t/$src"
    case "$src" in
      *.sh) out=$(bash -n "$f" 2>&1) || { VERIFY_REASON="syntax"; VERIFY_DETAIL="$src: $out"; return 1; } ;;
      *.js)
        if command -v node >/dev/null 2>&1; then
          out=$(node --check "$f" 2>&1) || { VERIFY_REASON="syntax"; VERIFY_DETAIL="$src: $out"; return 1; }
        fi ;;
    esac
  done <<UPDSYN
$(relman_section "$m" install-map | awk '{print $1}')
UPDSYN
  [ "$lvl" = "syntax" ] && return 0
  upd_deep_verify "$t" "$v"
}

# upd_deep_verify <tree> <ver> — step 9: the staged scanner must prove itself, under a sandbox HOME
# so nothing real is read or written. This is the first step that EXECUTES code of the release.
upd_deep_verify() {
  local t="$1" v="$2" sb out
  VERIFY_REASON=""; VERIFY_DETAIL=""
  if [ "${GOV_UPDATE_SKIP_DEEP_VERIFY:-0}" = "1" ]; then
    upd_log verify "deep verify SKIPPED (GOV_UPDATE_SKIP_DEEP_VERIFY=1) for $v"
    echo "gov-update: deep verify SKIPPED (GOV_UPDATE_SKIP_DEEP_VERIFY=1)" >&2
    return 0
  fi
  sb=$(mktemp -d 2>/dev/null) || sb="${TMPDIR:-/tmp}/gov-update-sb.$$"
  mkdir -p "$sb/.claude/logs"
  out=$(HOME="$sb" GOVERNANCE_HOOKS=1 bash "$t/bundle/hooks/governance/check-no-pii.sh" --selftest 2>&1 </dev/null) \
    || { VERIFY_REASON="deep-verify"; VERIFY_DETAIL="check-no-pii.sh --selftest failed: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; rm -rf "$sb"; return 1; }
  out=$(HOME="$sb" bash "$t/bundle/hooks/governance/governance-helpers-check.sh" "$t/bundle/hooks/governance" 2>&1 </dev/null) \
    || { VERIFY_REASON="deep-verify"; VERIFY_DETAIL="governance-helpers-check.sh failed: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; rm -rf "$sb"; return 1; }
  rm -rf "$sb"
  return 0
}

# ── Phase A: fetch, verify, stage ────────────────────────────────────────────────────────────
upd_fetch() {
  local ver="$1" inst cmp n n404 url out code rc sz tmp ready_v proto need
  # A human mode (2.0.0): nothing spawns it, and no setting gates it except the network switch.
  if [ "${GOVERNANCE_UPDATE_CHECK:-1}" = "0" ]; then
    upd_log fetch "skipped: GOVERNANCE_UPDATE_CHECK=0"
    say "GOVERNANCE_UPDATE_CHECK=0 is set (no network) - nothing downloaded."
    return 0
  fi
  # EVERY return below prints exactly one [GOVERNANCE UPDATE] line - staged, refused and why, or
  # skipped and why - and keeps its log line (review finding 7, 2026-09-30; before r2 findings 1, 12
  # and 15 of 2026-10-01 this comment said so while ten of the returns printed nothing). A return
  # through upd_halt, upd_say_held or upd_prepare_held prints that function's line instead.
  if upd_is_source; then
    upd_log fetch "reason=source-machine ($SRC_REASON)"
    say "this is the release source machine ($SRC_REASON) - it never installs releases; nothing downloaded."
    return 0
  fi
  if [ -z "$ver" ]; then
    upd_log fetch "refused: no version given"
    say "no version given - nothing downloaded. Usage: bash ~/.claude/hooks/governance/gov-update.sh --fetch <version>"
    return 0
  fi
  gov_is_semver "$ver" || { upd_log fetch "refused: '$ver' is not a version"; say "'$ver' is not a version - nothing downloaded."; return 0; }
  if [ -e "$UPD/HALT-$ver" ]; then
    local hr; hr=$(gov_record_field "$UPD/HALT-$ver" reason)
    say "v$ver is halted (${hr:-unknown}) - nothing downloaded. $(upd_halt_advice "$hr")"
    return 0
  fi
  inst=$(upd_installed_version)
  if [ -n "$inst" ]; then
    gov_semver_cmp_var cmp "$ver" "$inst"
    [ "$cmp" = "gt" ] || { upd_log fetch "v$ver is not newer than installed v$inst - nothing to do"; say "v$ver is not newer than the installed v$inst - nothing to do."; return 0; }
  fi
  if [ -f "$UPD/READY" ]; then
    ready_v=$(sed -n 's/^version=\([0-9.]*\).*/\1/p' "$UPD/READY" 2>/dev/null | head -1)
    if [ "$ready_v" = "$ver" ]; then
      upd_log fetch "v$ver is already staged (READY) - nothing downloaded again"
      say "v$ver is already downloaded and verified (staged) - nothing downloaded again. To install: close every Claude Code session, then in your own terminal run  bash ~/.claude/hooks/governance/gov-update.sh --apply --force-live"
      return 0
    fi
  fi
  # Already downloaded and HELD for its terms: nothing to download again. If the terms have been
  # accepted meanwhile, this is the retry path of --accept-terms' preparation step.
  if [ -f "$UPD/HELD-TERMS-$ver" ] && [ -s "$UPD/staged/v$ver/RELEASE-MANIFEST" ]; then
    if upd_terms_ok "$(gov_record_field "$UPD/HELD-TERMS-$ver" terms_version)"; then
      upd_lock prepare || { say "another update process holds the lock - nothing done; run this again in a minute."; return 0; }
      upd_prepare_held "$ver"
    else
      upd_say_held "$ver"
    fi
    return 0
  fi
  # The URL is checked BEFORE the attempt counter: a refused URL is a setting to fix, not a download
  # attempt, so it must not use up an attempt or start the spacing window (r2 finding 1).
  url="${URL_TMPL//%s/$ver}"
  case "$url" in
    https://*) proto="=https" ;;
    file://*)
      if [ "${GOV_UPDATE_ALLOW_FILE:-0}" = "1" ]; then proto="=file"
      else
        upd_log fetch "refused file:// URL without GOV_UPDATE_ALLOW_FILE=1"
        say "refused the archive URL: file:// is accepted only with GOV_UPDATE_ALLOW_FILE=1 (tests only) - nothing downloaded."
        return 0
      fi ;;
    *)
      upd_log fetch "refused a non-https archive URL"
      say "refused the archive URL: only https:// is accepted (check GOV_UPDATE_ARCHIVE_URL) - nothing downloaded."
      return 0 ;;
  esac
  n=$(upd_count "$UPD/fetch-attempts-$ver")
  if [ "$n" -ge "$MAX_ATTEMPTS" ]; then
    upd_log fetch "skipped v$ver: $n attempts made, the limit is $MAX_ATTEMPTS"
    say "v$ver: the download was already tried $n times (the limit is $MAX_ATTEMPTS) - nothing downloaded. To reset the counters (this also clears every halt): bash ~/.claude/hooks/governance/gov-update.sh --clear-halt"
    return 0
  fi
  if [ "$n" -gt 0 ]; then
    local age; age=$(upd_age "$UPD/fetch-attempts-$ver")
    if [ "$age" -lt "$SPACING" ]; then
      upd_log fetch "skipped v$ver: inside the attempt spacing ($SPACING s; the last attempt was ${age} s ago)"
      say "v$ver: the last download attempt was ${age} s ago; attempts are at least $SPACING s apart - nothing downloaded. Try again in $(( (SPACING - age + 59) / 60 )) min, or reset the counters (this also clears every halt): bash ~/.claude/hooks/governance/gov-update.sh --clear-halt"
      return 0
    fi
  fi
  if ! upd_lock fetch; then
    if [ "$LOCK_WHY" = "state-dir" ]; then say "cannot create ~/.claude/.governance-update - nothing downloaded."
    else say "another update process holds the lock - nothing downloaded; run this again in a minute."; fi
    return 0
  fi
  n=$((n + 1))
  upd_write "$UPD/fetch-attempts-$ver" "$n"

  mkdir -p "$UPD/dl" "$UPD/staged" 2>/dev/null
  out="$UPD/dl/v$ver.tgz.$$"
  code=$(curl -sSL --proto "$proto" --proto-redir "$proto" --max-filesize "$MAX_BYTES" -m 120 --retry 0 \
           -o "$out" -w '%{http_code}' "$url" 2>/dev/null)
  rc=$?
  case "$code" in ''|*[!0-9]*) code=000 ;; esac
  if [ "$rc" = "63" ]; then
    rm -f "$out"; upd_halt "$ver" oversize "archive larger than $MAX_BYTES bytes"; return 0
  fi
  if [ "$code" = "404" ]; then
    rm -f "$out"
    n404=$(( $(upd_count "$UPD/fetch-404-$ver") + 1 ))
    upd_write "$UPD/fetch-404-$ver" "$n404"
    upd_log fetch "reason=no-tag v$ver (HTTP 404, $n404 of 3)"
    if [ "$n404" -ge 3 ]; then
      upd_halt "$ver" no-tag "published VERSION v$ver has no release tag - nothing to install; maintainer problem"
    else
      say "v$ver: the release tag was not found (HTTP 404, $n404 of 3; the third makes it a halt) - nothing downloaded."
    fi
    return 0
  fi
  if [ "$rc" != "0" ] || { [ "$proto" = "=https" ] && [ "$code" != "200" ]; } || [ ! -s "$out" ]; then
    rm -f "$out"
    upd_log fetch "reason=network v$ver (curl rc=$rc http=$code, attempt $n of $MAX_ATTEMPTS)"
    say "v$ver could not be downloaded (network: curl rc=$rc, HTTP $code; attempt $n of $MAX_ATTEMPTS) - nothing staged. Details: ~/.claude/logs/governance-update.log"
    return 0
  fi
  sz=$(wc -c < "$out" 2>/dev/null | tr -d ' ')
  case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
  if [ "$sz" -gt "$MAX_BYTES" ]; then
    rm -f "$out"; upd_halt "$ver" oversize "archive is $sz bytes"; return 0
  fi

  tmp="$UPD/staged/tmp.$$"
  rm -rf "$tmp"
  if ! upd_extract "$out" "$tmp"; then
    rm -rf "$tmp" "$out"; upd_halt "$ver" "$EX_REASON" "$EX_DETAIL"; return 0
  fi
  rm -f "$out"
  # Steps 3-8 only: signature, hashes, file set, install map, syntax. Nothing of the release runs.
  if ! upd_verify_tree "$tmp" "$ver" "$UPD/allowed_signers" syntax; then
    rm -rf "$tmp"; upd_halt "$ver" "$VERIFY_REASON" "$VERIFY_DETAIL"; return 0
  fi
  need=$(relman_get "$tmp/RELEASE-MANIFEST" terms_version)
  case "$need" in ''|*[!0-9]*) need=999999 ;; esac
  if ! upd_terms_ok "$need"; then
    # HELD-TERMS (T1, C6): the terms changed. The verified tree is kept for the human to read, and
    # the deep verify - the first step that would execute release code - waits for acceptance.
    upd_stage_tree "$tmp" "$ver" || { upd_say_stage_failed "$ver"; return 0; }
    upd_write "$UPD/HELD-TERMS-$ver" "terms_version=$need staged_at=$(now_iso)"
    rm -f "$UPD/fetch-404-$ver"
    upd_log fetch "held: terms v$need not accepted; nothing of v$ver ran"
    upd_say_held "$ver"
    return 0
  fi
  if ! upd_deep_verify "$tmp" "$ver"; then
    rm -rf "$tmp"; upd_halt "$ver" "$VERIFY_REASON" "$VERIFY_DETAIL"; return 0
  fi
  upd_stage_tree "$tmp" "$ver" || { upd_say_stage_failed "$ver"; return 0; }
  if ! upd_write "$UPD/READY" "version=$ver manifest_sha256=$(relman_sha256 "$UPD/staged/v$ver/RELEASE-MANIFEST") staged_at=$(now_iso)"; then
    upd_log fetch "could not write READY for v$ver"
    say "v$ver verified, but ~/.claude/.governance-update/READY could not be written - nothing staged. Details: ~/.claude/logs/governance-update.log"
    return 0
  fi
  rm -f "$UPD/fetch-404-$ver"
  local nfiles; nfiles=$(relman_get "$UPD/staged/v$ver/RELEASE-MANIFEST" files)
  upd_log fetch "STAGED v$ver ($nfiles files verified)"
  say "v$ver is downloaded and verified ($nfiles files) and staged; nothing is installed. To install: close every Claude Code session, then in your own terminal run  bash ~/.claude/hooks/governance/gov-update.sh --apply --force-live"
  return 0
}

# upd_say_stage_failed <ver>: the one --fetch line for a verified tree that could not be moved into
# place (upd_stage_tree logged the detail).
upd_say_stage_failed() {
  say "v$1 verified, but it could not be moved into ~/.claude/.governance-update/staged - nothing staged. Details: ~/.claude/logs/governance-update.log"
}

# upd_terms_ok <n> -> 0 when terms-accepted records terms version >= n.
upd_terms_ok() {
  local need="$1" have
  case "$need" in ''|*[!0-9]*) need=999999 ;; esac
  have=$(gov_record_field "$UPD/terms-accepted" terms_version)
  case "$have" in ''|*[!0-9]*) have=0 ;; esac
  [ "$have" -ge "$need" ]
}

# upd_stage_tree <tmp> <ver>: the one staged tree. Every other staged tree, READY and HELD marker
# goes first - only one release is ever waiting, either READY (prepared) or HELD (terms).
upd_stage_tree() {
  local tmp="$1" ver="$2" f
  for f in "$UPD/staged"/*; do
    [ -e "$f" ] || continue
    [ "$f" = "$tmp" ] && continue
    rm -rf "$f"
  done
  rm -f "$UPD/READY" "$UPD"/HELD-TERMS-* 2>/dev/null
  mv "$tmp" "$UPD/staged/v$ver" || { rm -rf "$tmp"; upd_log fetch "could not move the staged tree into place"; return 1; }
}

# upd_say_held <ver>: the DRAFTS D.2 "terms held" line (pre-session.sh prints the same words).
upd_say_held() {
  local tv
  tv=$(gov_record_field "$UPD/HELD-TERMS-$1" terms_version)
  say "v$1 is waiting: its terms changed (v$tv) and none of its code has run. For the human: read ~/.claude/.governance-update/staged/v$1/NOTICE-AUTO-UPDATE.md, then run in your own terminal: bash ~/.claude/hooks/governance/gov-update.sh --accept-terms   (it refuses when it detects an AI-agent session - a safeguard, not a guarantee)"
}

# upd_prepare_held <ver> (caller holds the lock): the terms of a HELD release are now accepted.
# Re-check the staged tree (it sat on disk), then run the deep verify - the release's first code to
# run on this machine - and only then write READY. Any failure halts that version.
upd_prepare_held() {
  local ver="$1" st="$UPD/staged/v$1"
  if [ ! -s "$st/RELEASE-MANIFEST" ]; then
    rm -f "$UPD/HELD-TERMS-$ver"; upd_log terms "HELD-TERMS-$ver without a staged tree - removed"
    say "v$ver is no longer staged - download it again: bash ~/.claude/hooks/governance/gov-update.sh --fetch $ver"
    return 1
  fi
  if ! upd_verify_tree "$st" "$ver" "$UPD/allowed_signers" recheck; then
    rm -rf "$st"; rm -f "$UPD/HELD-TERMS-$ver"
    upd_halt_quiet "$ver" staged-tampered "$VERIFY_REASON: $VERIFY_DETAIL"
    say "v$ver was NOT prepared: the staged copy no longer verifies ($VERIFY_REASON). Nothing was installed; v$ver is halted. Details: ~/.claude/logs/governance-update.log. $(upd_halt_advice "$VERIFY_REASON")"
    return 1
  fi
  if ! upd_deep_verify "$st" "$ver"; then
    rm -rf "$st"; rm -f "$UPD/HELD-TERMS-$ver"
    upd_halt_quiet "$ver" deep-verify "$VERIFY_DETAIL"
    say "v$ver was NOT prepared: its self-check failed (deep-verify). Nothing was installed; v$ver is halted. Details: ~/.claude/logs/governance-update.log"
    return 1
  fi
  upd_write "$UPD/READY" "version=$ver manifest_sha256=$(relman_sha256 "$st/RELEASE-MANIFEST") staged_at=$(now_iso)"
  rm -f "$UPD/HELD-TERMS-$ver"
  upd_log terms "v$ver prepared after its terms were accepted (deep verify passed)"
  say "v$ver is now prepared; to install: close every session, then --apply --force-live"
  return 0
}

# ── Phase B helpers ──────────────────────────────────────────────────────────────────────────
# upd_order: "src dest" lines -> _common.sh first, then hooks/governance, root hooks, docs, agents, skills
upd_order() {
  awk '{ d = $2; k = 9
         if (d == "hooks/governance/_common.sh") k = 0
         else if (d ~ /^hooks\/governance\//) k = 1
         else if (d ~ /^hooks\//) k = 2
         else if (d ~ /^docs\//) k = 3
         else if (d ~ /^agents\//) k = 4
         else if (d ~ /^skills\//) k = 5
         print k " " $0 }' | LC_ALL=C sort -k1,1n -s | cut -d' ' -f2-
}

# upd_prepare <from-root> <pairs "src dest"> <prep-dir>
# Lays every source file out under <prep-dir>/.d at its DESTINATION path, on the same filesystem as
# ~/.claude, so that putting it in place is a plain rename. One tar pipe for the whole set.
upd_prepare() {
  local root="$1" pairs="$2" prep="$3" src dest shape
  rm -rf "$prep"; mkdir -p "$prep/.d" || return 1
  printf '%s\n' "$pairs" | awk 'NF == 2 { print $1 }' > "$prep.srcs"
  # The two shapes every real map has, done in ONE tar pipe with no per-file process:
  #   strip    dest = src minus its first component   (bundle/hooks/x -> hooks/x)
  #   prefix   dest = governance-installer/ + src     (the installer copy)
  shape=$(printf '%s\n' "$pairs" | awk 'NF == 2 { s = $1; sub(/^[^\/]*\//, "", s)
            if (s == $2) st++; else if ($2 == "governance-installer/" $1) pf++; n++ }
            END { if (n && st == n) print "strip"; else if (n && pf == n) print "prefix"; else print "other" }')
  case "$shape" in
    strip)
      (cd "$root" && tar -cf - -T "$prep.srcs") 2>/dev/null | (cd "$prep/.d" && tar -xf - --strip-components=1 2>/dev/null)
      rm -f "$prep.srcs"; upd_prepared_all "$prep" "$pairs"; return $? ;;
    prefix)
      mkdir -p "$prep/.d/governance-installer" || return 1
      (cd "$root" && tar -cf - -T "$prep.srcs") 2>/dev/null | (cd "$prep/.d/governance-installer" && tar -xf - 2>/dev/null)
      rm -f "$prep.srcs"; upd_prepared_all "$prep" "$pairs"; return $? ;;
  esac
  # Any other shape (a MIXED map, 2026-10-02): the pairs that ARE strip-shaped still go in ONE tar pipe;
  # only the rest are re-homed one by one. Since verify round 4 #2 the install map carries the
  # installed terms copy (bundle/TERMS-VERSION and NOTICE-AUTO-UPDATE.md -> hooks/governance-terms/),
  # which is not strip-shaped, so every real map is mixed. MEASURED on a loaded machine (86 + 2 pairs,
  # 3 runs each): re-homing EVERY file one `mv` at a time took 29 / 74 / 44 s against 4.9 / 4.2 / 6.7 s
  # for the tar pipe - inside the apply budget, so the per-file path is kept for the few pairs only.
  local strips rest
  strips=$(printf '%s\n' "$pairs" | awk 'NF == 2 { s = $1; sub(/^[^\/]*\//, "", s); if (s == $2) print $1 }')
  rest=$(printf '%s\n' "$pairs" | awk 'NF == 2 { s = $1; sub(/^[^\/]*\//, "", s); if (s != $2) print }')
  if [ -n "$strips" ]; then
    printf '%s\n' "$strips" > "$prep.srcs"
    (cd "$root" && tar -cf - -T "$prep.srcs") 2>/dev/null | (cd "$prep/.d" && tar -xf - --strip-components=1 2>/dev/null)
  fi
  printf '%s\n' "$rest" | awk 'NF == 2 { print $1 }' > "$prep.srcs"
  if [ -s "$prep.srcs" ]; then
    (cd "$root" && tar -cf - -T "$prep.srcs") 2>/dev/null | (cd "$prep" && tar -xf - 2>/dev/null) || { rm -f "$prep.srcs"; return 1; }
  fi
  rm -f "$prep.srcs"
  # Re-home each remaining file from its source path to its destination path.
  while read -r src dest; do
    [ -n "$dest" ] || continue
    [ -f "$prep/$src" ] || return 1
    [ -d "$prep/.d/${dest%/*}" ] || mkdir -p "$prep/.d/${dest%/*}" 2>/dev/null
    mv -f "$prep/$src" "$prep/.d/$dest" 2>/dev/null || return 1
  done <<UPDPREP
$rest
UPDPREP
  upd_prepared_all "$prep" "$pairs"
}

# upd_prepared_all <prep-dir> <pairs>: every destination must be laid out, or nothing is placed — a
# file missing here would silently leave the OLD version installed beside new ones.
upd_prepared_all() {
  local src dest
  while read -r src dest; do
    [ -n "$dest" ] || continue
    [ -f "$1/.d/$dest" ] || { UPD_FAIL="prepare: $dest missing"; return 1; }
  done <<UPDPALL
$2
UPDPALL
  return 0
}

# upd_place <prep-dir> <dest list> <label>
# Moves prepared files into ~/.claude one directory at a time, in list order: `mv -f f1 f2 ... dir/`
# is one rename(2) per file (each atomic) in one process. Files a lock kept back stay in the prep
# dir and are retried up to 5 x 200 ms. Returns 1 on a file that never moved or past the budget.
UPD_PLACED=0; UPD_FAIL=""
upd_place() {
  local base="$1/.d" list="$2" label="$3" key dir f cur=""
  local -a files=()
  # One awk groups the list by directory (first-seen order; list order inside a directory, so
  # _common.sh, listed first, is renamed first). A root-level path's directory is "." — without
  # that, a rollback read settings.json as a directory name and restored nothing (MEASURED).
  while IFS=' ' read -r key dir f; do
    [ -n "$f" ] || continue
    if [ "$dir" != "$cur" ]; then
      if [ -n "$cur" ]; then upd_place_dir "$base" "$cur" "$label" "${files[@]}" || return 1; fi
      cur="$dir"; files=()
    fi
    files+=("$f")
  done <<UPDDIRS
$(printf '%s\n' "$list" | awk 'length { d = $0; if (sub(/\/[^\/]*$/, "", d) == 0) d = "."; if (!(d in o)) o[d] = ++n; printf "%08d %s %s\n", o[d] * 100000 + NR, d, $0 }' | LC_ALL=C sort)
UPDDIRS
  if [ -n "$cur" ]; then upd_place_dir "$base" "$cur" "$label" "${files[@]}" || return 1; fi
  return 0
}

# upd_place_dir <base> <dir> <label> <file>... — one `mv` process per attempt for the whole directory.
upd_place_dir() {
  local base="$1" dir="$2" label="$3" f i=0
  shift 3
  local -a left=()
  if [ -n "$APPLY_BUDGET" ] && [ "$SECONDS" -gt "$APPLY_BUDGET" ]; then UPD_FAIL="budget"; return 1; fi
  [ -d "$CH/$dir" ] || mkdir -p "$CH/$dir" 2>/dev/null || { UPD_FAIL="mkdir $dir"; return 1; }
  while :; do
    left=()
    for f in "$@"; do [ -e "$base/$f" ] && left+=("$base/$f"); done
    [ "${#left[@]}" -eq 0 ] && break
    if [ "$i" -ge 5 ]; then UPD_FAIL="rename-failed in $dir"; return 1; fi
    if [ "$i" -gt 0 ]; then MV_RETRIES=$((MV_RETRIES + 1)); sleep 0.2; fi
    mv -f "${left[@]}" "$CH/$dir/" 2>/dev/null
    i=$((i + 1))
  done
  # Journal only inside an apply: a manual --rollback must not create an APPLYING file.
  [ -f "$UPD/APPLYING" ] && echo "$label $dir" >> "$UPD/APPLYING"
  UPD_PLACED=$((UPD_PLACED + 1))
  return 0
}

# upd_restore <backup-dir>: put every recorded path back as it was — restore "present" (mode kept),
# remove "absent", then remove directories the apply created, deepest first, only when empty.
upd_restore() {
  local bk="$1" rp="$UPD/restore.$$" present fails=0 rel save_budget
  [ -f "$bk/.backup-index" ] || return 1
  present=$(awk '$1 == "present" { sub(/^present /, ""); print }' "$bk/.backup-index")
  if [ -n "$present" ]; then
    rm -rf "$rp"; mkdir -p "$rp/.d" || return 1
    printf '%s\n' "$present" > "$rp.list"
    (cd "$bk" && tar -cf - -T "$rp.list") 2>/dev/null | (cd "$rp/.d" && tar -xpf - 2>/dev/null)
    rm -f "$rp.list"
    save_budget="$APPLY_BUDGET"; APPLY_BUDGET=""
    upd_place "$rp" "$present" restored || { fails=1; upd_log rollback "restore stopped: $UPD_FAIL"; }
    APPLY_BUDGET="$save_budget"
    [ -n "$(find "$rp/.d" -type f 2>/dev/null | head -1)" ] && fails=1
    rm -rf "$rp"
    # The restore proves itself the way the backup did: every restored file hashes as backed up.
    upd_backup_verify "$bk" "$present" || { fails=1; upd_log rollback "restored files do not match the backup"; }
  fi
  awk '$1 == "absent" { sub(/^absent /, ""); print }' "$bk/.backup-index" | tr '\n' '\0' \
    | (cd "$CH" && xargs -0 rm -f -- 2>/dev/null)
  awk '$1 == "absentdir" { sub(/^absentdir /, ""); print length($0) " " $0 }' "$bk/.backup-index" \
    | LC_ALL=C sort -rn | cut -d' ' -f2- | while IFS= read -r rel; do
    [ -n "$rel" ] && rmdir "$CH/$rel" 2>/dev/null
  done
  [ "$fails" = "0" ]
}

# upd_rollback <ver> <reason> <backup-dir> [detail]
upd_rollback() {
  local ver="$1" reason="$2" bk="$3" detail="${4:-}" ok="restored" n=0 retry=0
  upd_restore "$bk" || ok="PARTIALLY restored (see the log)"
  rm -rf "$UPD"/prep.* "$UPD"/gi-prep.* 2>/dev/null
  rm -f "$UPD/APPLYING"
  # interrupted / timeout / verify-timeout say nothing about the RELEASE: the process was killed, or
  # the machine was shut down, slept or overloaded mid-apply. Blocking the version on the first such
  # event would need a --clear-halt before the human could try again. So those are kept for a retry
  # BY HAND (READY and the staged tree are kept; the tree is re-verified before any retry) and halt
  # on the 3rd. Nothing retries on its own in this version. Every other reason is about the release
  # itself and halts at once, as before.
  case "$reason" in
    interrupted|timeout|verify-timeout)
      if gov_is_semver "$ver" && [ "$ok" = "restored" ]; then
        n=$(( $(upd_count "$UPD/retry-$ver") + 1 )); upd_write "$UPD/retry-$ver" "$n"
        [ "$n" -lt 3 ] && retry=1
      fi ;;
  esac
  if [ "$retry" = "1" ]; then
    :   # READY kept
  else
    rm -f "$UPD/READY"
    upd_halt_quiet "$ver" "$reason" "$detail"   # the rollback line below says it all
  fi
  if [ -f "$GI/verify.sh" ] && command -v timeout >/dev/null 2>&1; then
    timeout 10 bash "$GI/verify.sh" >/dev/null 2>&1 </dev/null
    upd_log rollback "post-rollback verify.sh rc=$?"
  fi
  upd_log rollback "ROLLED-BACK v$ver reason=$reason backup=$bk ($ok) $detail$([ "$retry" = "1" ] && printf ' - kept for a retry by hand (%s of 3)' "$n")"
  if [ "$retry" = "1" ]; then
    # Three attempts in all: failures 1 and 2 may be retried, the 3rd halts. Nothing retries on its
    # own in this version, so the line names the hand command in every case (A16).
    say "v$ver could NOT be applied ($reason) - everything was $ok from $(upd_tilde "$bk"). Nothing installs on its own in this version; retry it by hand: bash ~/.claude/hooks/governance/gov-update.sh --apply (failed attempt $n of 3)."
  else
    say "v$ver could NOT be applied ($reason) - everything was $ok from $(upd_tilde "$bk"). Details: ~/.claude/logs/governance-update.log. v$ver will not be retried; after fixing the cause run: bash ~/.claude/hooks/governance/gov-update.sh --clear-halt"
  fi
}

# upd_recover: an APPLYING journal survived its process (hook killed at its timeout, a crash).
upd_recover() {
  local jpid ver bk
  jpid=$(upd_journal pid); ver=$(upd_journal version); bk=$(upd_journal backup)
  if upd_alive "$jpid"; then
    # A hook killed at its timeout leaves its children alive, and that child may still finish
    # correctly. Rolling back under it would corrupt both.
    say "an apply is still running (pid $jpid) - nothing done"
    upd_log recover "APPLYING found, pid $jpid alive - left alone"
    return 0
  fi
  if ! grep -q '^backup-complete' "$UPD/APPLYING" 2>/dev/null; then
    # Died while backing up: no file had been replaced yet, so there is nothing to restore.
    rm -f "$UPD/APPLYING"; rm -rf "$UPD"/prep.* "$UPD"/gi-prep.* 2>/dev/null
    upd_log recover "APPLYING without a complete backup (pid ${jpid:-?} dead) - nothing was swapped; cleared"
    return 0
  fi
  # Never resumes forward: a half-known state is restored, not completed.
  upd_rollback "${ver:-unknown}" interrupted "$bk" "the apply process (pid ${jpid:-?}) died mid-apply"
}

# upd_other_live: one line per OTHER open session with a file written in the last 10 minutes.
# `find -mmin` rather than gov_other_sessions: that helper's fast path needs GNU find -printf, and
# its fallback reads ages through stat, which a BSD userland has only in its own dialect — portable
# find is the one thing both agree on, and a wrong age here would defer an apply forever.
upd_other_live() {
  local me d sid
  me=$(gov_session_id)
  for d in "$CH"/logs/sessions/*/; do
    [ -d "$d" ] || continue
    sid="${d%/}"; sid="${sid##*/}"
    [ "$sid" = "$me" ] && continue
    [ -f "$d/.gov-session-closed" ] && continue
    [ -n "$(find "$d" -type f -mmin "-$LIVE_WINDOW_MIN" 2>/dev/null | head -1)" ] && printf '%s\n' "$sid"
  done
}

# ── The detached RESTORE of an interrupted apply (the only background work, 2026-09-30) ────────
# 2.0.0 has no automatic trigger: the SessionEnd registration and its launcher were removed (owner
# decision 2026-09-29/30). What stays is the restore of an apply that died mid-swap: the restore is
# ~17 s and never interruptible, so it cannot run inside pre-session.sh's 10 s budget.
#
# upd_spawn_detached: starts `--apply-if-ready` (source `recovery`) in the background and returns at
# once. That child rolls the interrupted apply back and never applies (upd_apply). It owns nothing
# of the caller: stdin /dev/null, stdout+stderr appended to REPORT (printed by pre-session.sh at the
# next start), no session secrets, low priority, 600 s ceiling. Its only caller: --recover-detached.
upd_spawn_detached() {
  local sid="" src="recovery" rep="$UPD/REPORT" pre=()
  mkdir -p "$UPD" 2>/dev/null || return 1
  [ -L "$rep" ] && { upd_log spawn "REPORT is a symlink - refusing to write through it"; return 1; }
  # Bound it before the child appends: the last 50 lines, rewritten IN PLACE (same file, never a
  # rename: an earlier child may still hold it open for appending, and a replaced file would take
  # that child's result line with it). Skipped while another update process holds the lock.
  # Only when it has actually grown past the bound, which keeps the small check-then-rewrite window
  # (another child could write a quick line inside it) to a rare event rather than every spawn.
  if [ -f "$rep" ] && [ ! -d "$LOCK" ] && [ "$(wc -l < "$rep" 2>/dev/null | tr -d ' ')" -gt 50 ] 2>/dev/null; then
    tail -n 50 "$rep" > "$rep.tmp.$$" 2>/dev/null && cat "$rep.tmp.$$" > "$rep" 2>/dev/null
    rm -f "$rep.tmp.$$" 2>/dev/null
  fi
  command -v timeout >/dev/null 2>&1 && pre+=(timeout 600)
  command -v nice >/dev/null 2>&1 && pre+=(nice -n 19)
  GOV_SESSION_ID="$sid" GOV_SESSION_SOURCE="$src" GOV_UPDATE_DETACHED=1 \
    nohup env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u GH_TOKEN -u GITHUB_TOKEN \
    ${pre[@]+"${pre[@]}"} bash "$SCRIPT_DIR/gov-update.sh" --apply-if-ready >> "$rep" 2>&1 </dev/null &
  disown 2>/dev/null
  return 0
}

# ── Phase B ──────────────────────────────────────────────────────────────────────────────────
upd_apply() {  # upd_apply <auto 1|0> <force_live 1|0>
  local auto="$1" force_live="$2" src ver inst cmp st need have others nd names mod mode hashlist jp \
        need_kb avail_kb newmap known coll held
  [ -n "$APPLY_BUDGET" ] || { if [ "$auto" = "1" ]; then APPLY_BUDGET=50; else APPLY_BUDGET=600; fi; }
  # An interrupted apply is recovered FIRST, whatever else is true: restoring a half-applied tree
  # is not an update, so the source flag or the absence of any automatic update must not leave it.
  if [ -f "$UPD/APPLYING" ]; then
    if upd_lock recover; then upd_recover; return 0; fi
    jp=$(upd_journal pid)
    upd_alive "$jp" && say "an apply is still running (pid $jp) - nothing done"
    return 0
  fi
  # auto=1 is --apply-if-ready, the entry point of the detached recovery child. After the recovery
  # above it has nothing left to do: there is no automatic apply in this version (gov_auto_update_on
  # is false unconditionally), so a staged release stays staged until the human runs --apply.
  if [ "$auto" = "1" ]; then
    gov_auto_update_on || {
      [ -f "$UPD/READY" ] && upd_log apply "automatic apply is not available in this version; a staged release is applied only by hand: --apply --force-live"
      return 0
    }
  fi
  # From here on every refusal also says why (review finding 8, 2026-09-30): only a human reaches it.
  if upd_is_source; then
    upd_log apply "reason=source-machine ($SRC_REASON)"
    say "this is the release source machine ($SRC_REASON) - it never installs releases; nothing applied."
    return 0
  fi
  if [ ! -f "$UPD/READY" ]; then
    # READY is the only trigger: a HELD-TERMS release (no READY) is never applied, only named.
    if [ "$auto" = "0" ]; then
      for held in "$UPD"/HELD-TERMS-*; do
        [ -e "$held" ] || continue
        upd_say_held "${held##*/HELD-TERMS-}"; return 0
      done
      say "nothing is staged - no verified release is waiting to be applied."
    fi
    return 0
  fi
  upd_lock apply || { say "another update process holds the lock - nothing done; run this again in a minute."; return 0; }

  ver=$(sed -n 's/^version=\([0-9.]*\).*/\1/p' "$UPD/READY" 2>/dev/null | head -1)
  gov_is_semver "$ver" || { rm -f "$UPD/READY"; upd_log apply "READY held no valid version - removed"; return 0; }
  if [ -e "$UPD/HALT-$ver" ]; then
    local hr; hr=$(gov_record_field "$UPD/HALT-$ver" reason)
    say "v$ver is halted (${hr:-unknown}) - its staged copy is not applied and READY was removed. $(upd_halt_advice "$hr")"
    upd_log apply "v$ver is halted (${hr:-unknown}) - READY removed, not applied"
    rm -f "$UPD/READY"; return 0
  fi
  inst=$(upd_installed_version)
  if [ -z "$inst" ]; then
    say "v$ver is staged but this machine has no usable version marker - run install.sh --force once from a current clone."
    upd_log apply "no usable installed marker - not applied"
    return 0
  fi
  gov_semver_cmp_var cmp "$ver" "$inst"
  case "$cmp" in
    eq) rm -f "$UPD/READY"; rm -rf "$UPD/staged/v$ver"
        say "v$ver is already installed - the staged copy was removed."; return 0 ;;
    lt) rm -f "$UPD/READY"; upd_halt_quiet "$ver" downgrade "staged v$ver is older than installed v$inst"
        say "refused to apply v$ver: it is OLDER than the installed v$inst (downgrade). Nothing changed."; return 0 ;;
    gt) ;;
    *) upd_log apply "version compare undecidable ($ver vs $inst) - not applied"; return 0 ;;
  esac
  st="$UPD/staged/v$ver"
  [ -s "$st/RELEASE-MANIFEST" ] || { rm -f "$UPD/READY"; upd_log apply "READY without a staged tree - removed"; return 0; }
  need=$(relman_get "$st/RELEASE-MANIFEST" terms_version)
  case "$need" in ''|*[!0-9]*) need=999999 ;; esac
  # The one parser of a consent record (T2): gov_record_field, as upd_terms_ok and --status use.
  have=$(gov_record_field "$UPD/terms-accepted" terms_version)
  case "$have" in ''|*[!0-9]*) have=0 ;; esac
  if [ "$have" -lt "$need" ]; then
    say "v$ver is staged but its terms changed (v$need): read ~/.claude/.governance-update/staged/v$ver/NOTICE-AUTO-UPDATE.md, then run bash ~/.claude/hooks/governance/gov-update.sh --accept-terms"
    upd_log apply "held: terms v$need not accepted (have v$have)"
    return 0
  fi
  if [ "$force_live" != "1" ]; then
    others=$(upd_other_live)
    if [ -n "$others" ]; then
      nd=$(( $(upd_count "$UPD/deferrals") + 1 ))
      upd_write "$UPD/deferrals" "$nd"
      names=""
      [ "$nd" -ge 3 ] && names=" Live: $(printf '%s' "$others" | tr '\n' ' ' | sed 's/ $//')."
      # A session dir counts as live for 10 minutes after its last hook write, closed or not, so a
      # human who has just closed every session needs the override to get anywhere.
      names="$names If every Claude Code session is closed, apply now: bash ~/.claude/hooks/governance/gov-update.sh --apply --force-live"
      say "v$ver is verified and staged; it is not applied while another Claude Code session looks active (deferred $nd time(s)).$names"
      upd_log apply "deferred v$ver: $(printf '%s\n' "$others" | grep -c .) live session(s), deferral $nd"
      return 0
    fi
  fi
  # The full re-verification of the staged tree (signature, every hash) runs only now, AFTER the
  # cheap deferral checks: a start that is going to defer anyway must not pay for it in the
  # foreground. Nothing above acted on the staged tree beyond reading its terms number to decide
  # whether to wait, and nothing below reads it before this passes.
  if ! upd_verify_tree "$st" "$ver" "$UPD/allowed_signers" recheck; then
    rm -f "$UPD/READY"; rm -rf "$st"
    upd_halt_quiet "$ver" staged-tampered "$VERIFY_REASON: $VERIFY_DETAIL"
    say "refused to apply v$ver: the staged copy no longer verifies ($VERIFY_REASON). Nothing changed; v$ver is halted. Details: ~/.claude/logs/governance-update.log. $(upd_halt_advice "$VERIFY_REASON")"
    return 0
  fi
  mode=$(head -1 "$UPD/install-mode" 2>/dev/null | tr -d '[:space:]')
  case "$mode" in core-only) ;; *) mode=full ;; esac
  newmap=$(relman_map_for_mode "$st/RELEASE-MANIFEST" "$mode")
  # Local modifications: (1) every file this framework installed, against the hash recorded when it
  # was written; (2) every path the release claims for the FIRST time, which may be the user's own
  # file (a skill of the same name) — it must equal the incoming file or it is someone's work.
  mod=""; known=""
  if [ -s "$UPD/installed.hashes" ]; then
    hashlist=$(sed 's/^[0-9a-f]\{64\}  //' "$UPD/installed.hashes" | relman_sha256_stdin_list "$CH" 2>/dev/null)
    mod=$(awk 'NR == FNR { p = $0; sub(/^[0-9a-f]+  /, "", p); cur[p] = $1; next }
               { p = $0; sub(/^[0-9a-f]+  /, "", p); if (!(p in cur) || cur[p] != $1) print p }' \
            <(printf '%s\n' "$hashlist") "$UPD/installed.hashes")
    known=$(sed 's/^[0-9a-f]\{64\}  //' "$UPD/installed.hashes")
  else
    if [ ! -f "$UPD/.no-baseline-noted" ]; then
      say "note: no local-modification baseline (installed.hashes) on this machine - applying without that check this once."
      touch "$UPD/.no-baseline-noted" 2>/dev/null
    fi
    upd_log apply "no installed.hashes baseline - local-modification check skipped"
  fi
  if [ -n "$known" ] || [ -s "$UPD/installed.hashes" ]; then
    # awk picks the paths new to the baseline in one pass; only those (usually none) are hashed.
    coll=$(awk 'NR == FNR { k[$0] = 1; next } NF == 2 && !($2 in k) { print $1 " " $2 }' \
             <(printf '%s\n' "$known") <(printf '%s\n' "$newmap") | while read -r src dest; do
             [ -e "$CH/$dest" ] || continue
             [ "$(relman_sha256 "$CH/$dest")" = "$(relman_sha256 "$st/$src")" ] || printf '%s\n' "$dest"
           done)
    [ -n "$coll" ] && mod=$(printf '%s\n%s\n' "$mod" "$coll" | grep -v '^$')
  fi
  if [ -n "$mod" ]; then
    if [ "${GOV_UPDATE_OVERWRITE_LOCAL:-0}" = "1" ]; then
      upd_log apply "GOV_UPDATE_OVERWRITE_LOCAL=1: overwriting locally modified: $(printf '%s' "$mod" | tr '\n' ' ')"
    else
      say "not applied: $(printf '%s\n' "$mod" | grep -c .) installed file(s) were modified locally ($(printf '%s\n' "$mod" | head -5 | tr '\n' ',' | sed 's/,$//; s/,/, /g')) - update by hand with install.sh --force, or set GOV_UPDATE_OVERWRITE_LOCAL=1 (the files go to the backup)."
      upd_log apply "refused v$ver: locally modified: $(printf '%s' "$mod" | tr '\n' ' ')"
      return 0
    fi
  fi
  command -v node >/dev/null 2>&1 || { say "v$ver is staged but node is not installed - the settings.json merge needs it. Nothing changed."; return 0; }
  need_kb=$(du -sk "$st" 2>/dev/null | awk '{print $1 * 3}')
  avail_kb=$(df -Pk "$CH" 2>/dev/null | awk 'NR == 2 {print $4}')
  case "$need_kb$avail_kb" in
    ''|*[!0-9]*) ;;
    *) if [ "$avail_kb" -lt "$need_kb" ]; then say "v$ver is staged but free disk space is below 3x its size. Nothing changed."; return 0; fi ;;
  esac
  upd_do_apply "$ver" "$inst" "$st" "$mode" "$(printf '%s\n' "$newmap" | upd_order)"
}

# upd_backup_copy <backup-dir> <present list>: one tar pipe, modes kept.
upd_backup_copy() {
  [ -n "$2" ] || return 0
  printf '%s\n' "$2" > "$1/.present"
  (cd "$CH" && tar -cf - -T "$1/.present") 2>/dev/null | (cd "$1" && tar -xpf - 2>/dev/null)
  rm -f "$1/.present"
}
# upd_backup_verify <backup-dir> <present list>: by CONTENT, not by count — every file that exists
# now hashes the same in the backup. A backup that does not verify stops the apply before any change.
upd_backup_verify() {
  [ "$(printf '%s\n' "$2" | relman_sha256_stdin_list "$CH" 2>/dev/null)" \
    = "$(printf '%s\n' "$2" | relman_sha256_stdin_list "$1" 2>/dev/null)" ]
}

upd_do_apply() {
  local ver="$1" from="$2" st="$3" mode="$4" newmap="$5" bk oldmap dels touch rel n_present \
        gi_pairs gi_del vrc tmpf prevtpl dests d slow present_list
  bk="$BACKUPS/governance-update-$(date '+%Y%m%d-%H%M%S')-$$"
  oldmap=""
  [ -f "$UPD/installed.manifest" ] && oldmap=$(relman_map_for_mode "$UPD/installed.manifest" "$mode")
  dels=$(awk 'NR == FNR { keep[$2] = 1; next } NF == 2 && !($2 in keep) { print $2 }' \
           <(printf '%s\n' "$newmap") <(printf '%s\n' "$oldmap"))
  gi_pairs=""; gi_del=""
  if [ -d "$GI" ]; then
    gi_pairs=$( { relman_section "$st/RELEASE-MANIFEST" files | sed 's/^[0-9a-f]\{64\}  //' \
                  | grep -E '^(install\.sh|verify\.sh|README\.md|LICENSE|NOTICE-AUTO-UPDATE\.md|bundle/.+)$'
                printf 'RELEASE-MANIFEST\nRELEASE-MANIFEST.sig\n'; } | awk '{ print $1 " governance-installer/" $1 }')
    if [ -f "$UPD/installed.manifest" ]; then
      gi_del=$(awk 'NR == FNR { keep[$1] = 1; next } { p = $0; sub(/^[0-9a-f]+  /, "", p) } p ~ /^bundle\// && !(p in keep) { print "governance-installer/" p }' \
                 <(printf '%s\n' "$gi_pairs") <(relman_section "$UPD/installed.manifest" files))
    fi
  fi
  dests=$( { printf '%s\n' "$newmap" | awk 'NF == 2 {print $2}'; printf '%s\n' "$gi_pairs" | awk 'NF == 2 {print $2}'; } | grep -v '^$')
  touch=$( { printf '%s\n' "$dests"; printf '%s\n' "$dels"; printf '%s\n' "$gi_del"
             printf '%s\n' settings.json .governance-version .governance-update/installed.manifest \
                    .governance-update/installed.hashes .governance-update/settings-hooks.installed.json \
                    .governance-update/allowed_signers; } | grep -v '^$' | awk '!seen[$0]++')
  # A symlinked destination would be replaced by a regular file and could not be restored as a link.
  d=$(printf '%s\n' "$touch" | while IFS= read -r rel; do [ -L "$CH/$rel" ] && printf '%s ' "$rel"; done)
  if [ -n "$d" ]; then
    say "v$ver not applied: these destinations are symlinks ($d) - update by hand with install.sh --force. Nothing changed."
    upd_log apply "refused v$ver: symlinked destination(s): $d"
    return 0
  fi

  mkdir -p "$UPD" "$bk" || { say "cannot create the backup directory $(upd_tilde "$bk") - nothing changed."; return 0; }
  printf 'version=%s\nfrom=%s\nstarted=%s\nbackup=%s\npid=%s\n' "$ver" "$from" "$(now_iso)" "$bk" "$$" > "$UPD/APPLYING"
  upd_log apply "APPLYING v$from -> v$ver backup=$bk"

  # 1. Back up EVERYTHING the apply may touch, completely, before the first write — and record which
  #    paths and directories did not exist, so a rollback removes exactly what the apply created.
  {
    printf '# from=%s to=%s created=%s\n' "$from" "$ver" "$(now_iso)"
    printf '%s\n' "$touch" | while IFS= read -r rel; do
      if [ -f "$CH/$rel" ]; then printf 'present %s\n' "$rel"; else printf 'absent %s\n' "$rel"; fi
    done
    printf '%s\n' "$dests" | awk '{ d = $0; while (sub(/\/[^\/]*$/, "", d)) { if (!(d in s)) { s[d] = 1; print d } } }' \
      | while IFS= read -r d; do [ -d "$CH/$d" ] || printf 'absentdir %s\n' "$d"; done
  } > "$bk/.backup-index"
  present_list=$(awk '$1 == "present" { sub(/^present /, ""); print }' "$bk/.backup-index")
  n_present=$(printf '%s\n' "$present_list" | grep -c .)
  upd_backup_copy "$bk" "$present_list"
  if ! upd_backup_verify "$bk" "$present_list"; then
    rm -f "$UPD/APPLYING"
    upd_log apply "backup did not verify - aborted before any change"
    say "v$ver not applied: the backup did not verify. Nothing changed."
    return 0
  fi
  if [ "$SECONDS" -gt "$APPLY_BUDGET" ]; then
    rm -f "$UPD/APPLYING"
    slow=$(( $(upd_count "$UPD/apply-slow") + 1 )); upd_write "$UPD/apply-slow" "$slow"
    upd_log apply "backup exceeded ${APPLY_BUDGET}s (${SECONDS}s) - aborted before any change ($slow time(s))"
    if [ "$slow" -ge 3 ]; then
      say "v$ver is staged but this machine was too busy to apply it $slow times in a row. Nothing changed. Apply it when the machine is idle: bash ~/.claude/hooks/governance/gov-update.sh --apply"
    else
      say "v$ver not applied: the machine is too busy to finish in time. Nothing changed; try again when the machine is idle: bash ~/.claude/hooks/governance/gov-update.sh --apply"
    fi
    return 0
  fi
  echo "backup-complete files=$n_present" >> "$UPD/APPLYING"

  # 2. Lay the new files out beside ~/.claude, then rename them into place, _common.sh first.
  UPD_FAIL=""
  if ! upd_prepare "$st" "$newmap" "$UPD/prep.$$"; then upd_rollback "$ver" prepare-failed "$bk" "could not lay out the staged files"; return 0; fi
  find "$UPD/prep.$$/.d" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null
  if ! upd_place "$UPD/prep.$$" "$(printf '%s\n' "$newmap" | awk 'NF == 2 {print $2}')" swapped; then
    case "$UPD_FAIL" in budget) upd_rollback "$ver" timeout "$bk" "apply exceeded ${APPLY_BUDGET}s" ;; *) upd_rollback "$ver" rename-failed "$bk" "$UPD_FAIL" ;; esac
    return 0
  fi
  rm -rf "$UPD/prep.$$"
  if [ -n "$dels" ]; then
    printf '%s\n' "$dels" | while IFS= read -r rel; do [ -n "$rel" ] && rm -f "$CH/$rel"; done
    echo "deleted $(printf '%s\n' "$dels" | grep -c .)" >> "$UPD/APPLYING"
  fi

  # 3. settings.json — the framework's own entries only.
  prevtpl=()
  [ -f "$UPD/settings-hooks.installed.json" ] && prevtpl=(--installed "$UPD/settings-hooks.installed.json")
  if ! tmpf=$(node "$CH/hooks/governance/settings-merge.js" --template "$st/bundle/settings-hooks.json" \
                --settings "$CH/settings.json" ${prevtpl[@]+"${prevtpl[@]}"} 2>&1); then
    upd_rollback "$ver" settings "$bk" "$tmpf"; return 0
  fi
  echo "settings $tmpf" >> "$UPD/APPLYING"

  # 4. The installer copy, when this machine keeps one — mandatory: without it the Stop-time drift
  #    reconciler would find live != bundle and start a publish queue on a client machine.
  if [ -n "$gi_pairs" ]; then
    if ! upd_prepare "$st" "$gi_pairs" "$UPD/gi-prep.$$" \
       || ! upd_place "$UPD/gi-prep.$$" "$(printf '%s\n' "$gi_pairs" | awk 'NF == 2 {print $2}')" installer; then
      case "${UPD_FAIL:-}" in budget) upd_rollback "$ver" timeout "$bk" "apply exceeded ${APPLY_BUDGET}s (installer copy)" ;; *) upd_rollback "$ver" rename-failed "$bk" "installer copy: ${UPD_FAIL:-prepare}" ;; esac
      return 0
    fi
    rm -rf "$UPD/gi-prep.$$"
    printf '%s\n' "$gi_del" | while IFS= read -r rel; do [ -n "$rel" ] && rm -f "$CH/$rel"; done
    # When that directory is the user's git clone, its working tree now differs from its HEAD.
    # Refreshing it is still right (the drift reconciler would otherwise queue a publish here), but
    # a later `git pull` there would refuse over "local changes" — and over the UNTRACKED files a
    # release adds, which `checkout -- .` does not remove (MEASURED in review). `stash -u` sets both
    # aside, reversibly; the pull then brings the same release.
    if [ -e "$GI/.git" ]; then
      GI_NOTE=" Your installer clone (~/.claude/governance-installer) now holds v$ver's files; before a git pull there, run: git -C ~/.claude/governance-installer stash -u"
    fi
  fi

  # 5. The new baseline BEFORE verify.sh (which checks that it exists). The backup index lists this
  #    file, so a rollback restores or removes it with everything else.
  printf '%s\n' "$newmap" | awk 'NF == 2 {print $2}' | relman_sha256_stdin_list "$CH" > "$UPD/installed.hashes.tmp.$$" 2>/dev/null \
    && mv -f "$UPD/installed.hashes.tmp.$$" "$UPD/installed.hashes"

  # 6. Prove it: the new verify.sh against the installed tree — never past the budget.
  if [ "$SECONDS" -gt "$APPLY_BUDGET" ]; then upd_rollback "$ver" timeout "$bk" "no time left for verify.sh (${SECONDS}s)"; return 0; fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "$VERIFY_TIMEOUT" bash "$st/verify.sh" >/dev/null 2>&1 </dev/null; vrc=$?
  else
    bash "$st/verify.sh" >/dev/null 2>&1 </dev/null; vrc=$?
  fi
  # Its own reason (verify-timeout), and RETRIED like `timeout`: at nice 19 on a loaded machine a
  # healthy verify.sh can outrun its 20 s, and blocking a valid release for that would be wrong. A
  # verify.sh that really hangs still halts - on the third attempt (upd_rollback).
  if [ "$vrc" = "124" ]; then upd_rollback "$ver" verify-timeout "$bk" "verify.sh did not finish in ${VERIFY_TIMEOUT}s"; return 0; fi
  if [ "$vrc" != "0" ]; then upd_rollback "$ver" verify-failed "$bk" "verify.sh exit $vrc"; return 0; fi

  # 7. Commit the new state.
  cp "$st/RELEASE-MANIFEST" "$UPD/installed.manifest.tmp.$$" && mv -f "$UPD/installed.manifest.tmp.$$" "$UPD/installed.manifest"
  cp "$st/bundle/settings-hooks.json" "$UPD/settings-hooks.installed.json.tmp.$$" \
    && mv -f "$UPD/settings-hooks.installed.json.tmp.$$" "$UPD/settings-hooks.installed.json"
  if ! cmp -s "$st/bundle/release/allowed_signers" "$UPD/allowed_signers"; then
    # Chained trust: this file arrived inside a manifest that verified under the key pinned until now.
    cp "$st/bundle/release/allowed_signers" "$UPD/allowed_signers.tmp.$$" && mv -f "$UPD/allowed_signers.tmp.$$" "$UPD/allowed_signers"
    upd_log apply "pinned release key(s) updated by v$ver (chained trust)"
  fi
  upd_write "$CH/.governance-version" "$ver"
  rm -f "$UPD/READY" "$UPD/APPLYING" "$UPD/deferrals" "$UPD/apply-slow" "$UPD"/fetch-attempts-* "$UPD"/fetch-404-* "$UPD"/retry-* "$UPD"/HELD-TERMS-* 2>/dev/null
  rm -rf "$st"
  upd_log apply "APPLIED v$from -> v$ver ($(relman_get "$UPD/installed.manifest" files) files verified, $UPD_PLACED dir batches, $(printf '%s\n' "$dels" | grep -c .) removed, mv retries $MV_RETRIES, ${SECONDS}s) backup=$bk"
  say "Applied v$ver (was v$from; signed release, $(relman_get "$UPD/installed.manifest" files) files verified). Backup: $(upd_tilde "$bk"). Roll back: bash ~/.claude/hooks/governance/gov-update.sh --rollback. Restart Claude Code if a hook or agent was added.${GI_NOTE:-}"
  return 0
}

# ── human modes ──────────────────────────────────────────────────────────────────────────────
# --rollback restores ONE transition. It refuses a backup that is not of the installed version
# (restoring a weeks-old backup would silently discard every change since), and it first backs up
# the CURRENT state of the same paths, so the rollback itself can be undone with --rollback <dir>.
upd_manual_rollback() {
  local bk="${1:-}" from to inst pre _pre_list
  if [ -z "$bk" ]; then
    bk=$(ls -1d "$BACKUPS"/governance-update-* 2>/dev/null | grep -v 'pre-rollback' | LC_ALL=C sort | tail -1)
  fi
  if [ -z "$bk" ] || [ ! -f "$bk/.backup-index" ]; then say "no update backup found${1:+ at $1} - nothing done."; return 1; fi
  from=$(sed -n '1s/.*from=\([^ ]*\).*/\1/p' "$bk/.backup-index")
  to=$(sed -n '1s/.* to=\([^ ]*\).*/\1/p' "$bk/.backup-index")
  inst=$(upd_installed_version)
  if [ "$inst" != "$to" ] && [ "${GOV_UPDATE_ROLLBACK_ANY:-0}" != "1" ]; then
    say "refused: $(upd_tilde "$bk") undoes v$from -> v$to, but v${inst:-unknown} is installed. Restoring it would discard everything since. Set GOV_UPDATE_ROLLBACK_ANY=1 to do it anyway."
    return 1
  fi
  upd_lock rollback || { say "another update operation holds the lock - try again in a minute."; return 1; }
  pre="$BACKUPS/governance-update-$(date '+%Y%m%d-%H%M%S')-$$-pre-rollback"
  mkdir -p "$pre" || { say "cannot create $(upd_tilde "$pre") - nothing done."; return 1; }
  {
    printf '# from=%s to=%s created=%s\n' "${inst:-unknown}" "$from" "$(now_iso)"
    awk '$1 == "present" || $1 == "absent" { sub(/^[a-z]+ /, ""); print }' "$bk/.backup-index" | while IFS= read -r rel; do
      if [ -f "$CH/$rel" ]; then printf 'present %s\n' "$rel"; else printf 'absent %s\n' "$rel"; fi
    done
  } > "$pre/.backup-index"
  _pre_list=$(awk '$1 == "present" { sub(/^present /, ""); print }' "$pre/.backup-index")
  upd_backup_copy "$pre" "$_pre_list"
  # The copy of the current state is what makes this rollback undoable; if it did not verify, the
  # rollback does not run — a claim "saved in ..." that nothing checked is the thing to never print.
  if ! upd_backup_verify "$pre" "$_pre_list"; then
    say "rollback NOT done: the copy of the current state in $(upd_tilde "$pre") did not verify (disk full? a file locked?). Nothing changed."
    upd_log rollback "aborted: pre-rollback copy did not verify ($pre)"
    return 1
  fi
  if upd_restore "$bk"; then
    rm -f "$UPD/READY"
    [ -n "$to" ] && upd_halt_quiet "$to" manual-rollback "rolled back by hand to v$from"
    upd_log rollback "manual rollback from v$to to v$from using $bk (current state saved in $pre)"
    say "Rolled back to v$from from $(upd_tilde "$bk"). v$to is halted (it will not re-apply); clear with --clear-halt when you want it again. The state before this rollback is saved in $(upd_tilde "$pre")."
    return 0
  fi
  say "rollback from $(upd_tilde "$bk") was INCOMPLETE - see ~/.claude/logs/governance-update.log. The state before it is in $(upd_tilde "$pre")."
  return 1
}

upd_status() {
  local inst f v="" age code pc_at pc_why
  inst=$(upd_installed_version)
  echo "Context Governance update status"
  echo "  installed:        v${inst:-unknown}"
  echo "  automatic update: not available in this version (update by hand: --fetch <ver>, then --apply --force-live)"
  if upd_is_source; then echo "  source machine:   YES ($SRC_REASON) - this machine never updates itself"; fi
  if [ -f "$UPD/READY" ]; then echo "  staged:           $(head -1 "$UPD/READY")"; else echo "  staged:           nothing"; fi
  for f in "$UPD"/HELD-TERMS-*; do
    [ -e "$f" ] || continue
    echo "  held (terms):     v${f##*/HELD-TERMS-} - terms v$(gov_record_field "$f" terms_version) not accepted"
  done
  for f in "$UPD"/HALT-*; do
    [ -e "$f" ] || continue
    echo "  HALTED:           ${f##*/HALT-} - $(head -1 "$f")"
  done
  for f in "$UPD"/fetch-attempts-*; do
    [ -e "$f" ] || continue
    echo "  fetch attempts:   ${f##*/fetch-attempts-} - $(upd_count "$f") of $MAX_ATTEMPTS"
  done
  if [ -f "$CH/logs/.governance-latest" ]; then
    age=$(upd_age "$CH/logs/.governance-latest")
    v=$(sed -n '/[^[:space:]]/{s/[[:space:]]//g;p;q;}' "$CH/logs/.governance-latest" 2>/dev/null)
    gov_is_semver "$v" || v="unknown"
    # A FAILED check also touches .governance-latest (pre-session.sh), so its age alone is the age of
    # the last ATTEMPT. pre-session.sh leaves the HTTP code in .governance-version-status on a
    # failure and removes it on a success: when it is there, say the check failed (finding 6).
    code=""
    [ -f "$CH/logs/.governance-version-status" ] && code=$(sed -n '/[^[:space:]]/{s/[[:space:]]//g;p;q;}' "$CH/logs/.governance-version-status" 2>/dev/null)
    case "$code" in ''|*[!0-9]*) code="" ;; esac
    if [ -n "$code" ]; then
      [ "$v" = "unknown" ] || v="v$v"
      echo "  last check:       $((age / 3600)) h ago - FAILED (HTTP $code); last known published: $v"
    else
      echo "  last check:       $((age / 3600)) h ago (published: $v)"
    fi
  else
    echo "  last check:       never"
  fi
  if [ -s "$UPD/allowed_signers" ]; then
    relman_fingerprints "$UPD/allowed_signers" | sed 's/^/  pinned key:       /'
  else
    echo "  pinned key:       NONE - run install.sh"
  fi
  if [ -f "$LOCK/info" ]; then echo "  lock:             $(head -1 "$LOCK/info")"; fi
  if [ -f "$UPD/APPLYING" ]; then echo "  APPLYING:         v$(upd_journal version) pid $(upd_journal pid) since $(upd_journal started)"; fi
  if [ -s "$UPD/REPORT" ]; then echo "  pending report:   $(grep -m1 -F '[GOVERNANCE UPDATE]' "$UPD/REPORT" 2>/dev/null | cut -c1-160)"; fi
  if [ -f "$UPD/terms-accepted" ]; then echo "  terms:            $(head -1 "$UPD/terms-accepted")"; else echo "  terms:            not accepted"; fi
  # DRAFTS D.2: push at session close, from the one predicate close-push.sh obeys. A record that says
  # ON but that the predicate rejects (terms changed, paused) prints the predicate's reason.
  pc_at=$(gov_record_field "$UPD/close-push" decided_at); pc_at="${pc_at%%T*}"
  # The predicate's own reason decides the wording (round 3, B2): on the maintainer's machine push is
  # on with no record at all, and a recorded "off" there is not what governs - never "your choice".
  local pc_on=0 pc_reason=""
  if type gov_close_push_on >/dev/null 2>&1; then
    gov_close_push_on && pc_on=1
    pc_reason="${GOV_CONSENT_REASON:-}"
  fi
  if [ "$pc_on" = 1 ] && [ "${pc_reason#on (maintainer}" != "$pc_reason" ]; then
    echo "  push at close:    ON ${pc_reason#on }$([ -e "$UPD/close-push" ] && echo " - always on here; the recorded choice does not apply on this machine")"
  elif [ "$pc_on" = 1 ]; then
    echo "  push at close:    ON (your choice, recorded ${pc_at:-unknown date})"
  elif [ "$pc_reason" = "paused by GOV_CLOSE_PUSH=0" ]; then
    # Reached only where push would otherwise be on (the maintainer's machine, or an ON record).
    echo "  push at close:    OFF (paused by GOV_CLOSE_PUSH=0)"
  elif [ ! -e "$UPD/close-push" ]; then
    echo "  push at close:    OFF (no choice recorded)"
  elif [ "$(gov_record_field "$UPD/close-push" enabled)" = "1" ]; then
    pc_why="${GOV_CONSENT_REASON:-consent-lib.sh is missing}"
    case "$pc_why" in "off ("*")") pc_why="${pc_why#off (}"; pc_why="${pc_why%)}" ;; esac
    echo "  push at close:    OFF ($pc_why)"
  else
    # An OFF the installer wrote by default (no terminal, an agent session) or on a terms change was
    # not the user's choice, and --status must not call it one. Only an answer the person gave is
    # "your choice" (round 3). The list is consent-lib.sh gov_close_push_off_kind - the one install.sh
    # and gov_close_push_on read (verify round 4 minor, 2026-10-02).
    local pc_kind=recorded
    type gov_close_push_off_kind >/dev/null 2>&1 && pc_kind=$(gov_close_push_off_kind "$(gov_record_field "$UPD/close-push" method)")
    case "$pc_kind" in
      default) echo "  push at close:    OFF (the default - you were not asked, recorded ${pc_at:-unknown date}); to turn it on, in your own terminal: bash ~/.claude/hooks/governance/close-push.sh --enable" ;;
      terms)   echo "  push at close:    OFF (turned off when the terms changed, recorded ${pc_at:-unknown date}); to turn it on, in your own terminal: bash ~/.claude/hooks/governance/close-push.sh --enable" ;;
      choice)  echo "  push at close:    OFF (your choice, recorded ${pc_at:-unknown date})" ;;
      *)       echo "  push at close:    OFF (recorded off on ${pc_at:-an unknown date})" ;;
    esac
  fi
  echo "  install mode:    $(head -1 "$UPD/install-mode" 2>/dev/null || echo unknown)"
  echo "  deferrals:        $(upd_count "$UPD/deferrals")"
  echo "  log:              ~/.claude/logs/governance-update.log"
}

upd_accept_terms() {
  local notice="" tv="" ver="" ans method held="" f nsha ssha
  # A release HELD for its terms comes first: it is the one waiting on this acceptance.
  for f in "$UPD"/HELD-TERMS-*; do
    [ -e "$f" ] || continue
    ver="${f##*/HELD-TERMS-}"
    if gov_is_semver "$ver" && [ -f "$UPD/staged/v$ver/RELEASE-MANIFEST" ]; then
      held="$ver"
      notice="$UPD/staged/v$ver/NOTICE-AUTO-UPDATE.md"
      tv=$(relman_get "$UPD/staged/v$ver/RELEASE-MANIFEST" terms_version)
    fi
    break
  done
  if [ -z "$held" ] && [ -f "$UPD/READY" ]; then
    ver=$(sed -n 's/^version=\([0-9.]*\).*/\1/p' "$UPD/READY" | head -1)
    if [ -f "$UPD/staged/v$ver/RELEASE-MANIFEST" ]; then
      notice="$UPD/staged/v$ver/NOTICE-AUTO-UPDATE.md"
      tv=$(relman_get "$UPD/staged/v$ver/RELEASE-MANIFEST" terms_version)
    fi
  fi
  if [ -z "$tv" ] && [ -f "$GI/NOTICE-AUTO-UPDATE.md" ]; then
    notice="$GI/NOTICE-AUTO-UPDATE.md"
    tv=$(tr -d '[:space:]' < "$GI/bundle/TERMS-VERSION" 2>/dev/null)
  fi
  # Fix round 4 G4-3 (2026-10-02): the INSTALLED copy of the terms (consent-lib.sh gov_terms_copy_dir,
  # ~/.claude/hooks/governance-terms/ - the NOTICE the install showed and its TERMS-VERSION). A client
  # whose clone is not at ~/.claude/governance-installer, with nothing staged, was told "nothing to
  # accept" here, while close-push.sh --enable sends exactly that client to this command. The copy is
  # used only when its version is clear: installed.manifest and the copy's TERMS-VERSION state the same
  # integer (_gov_terms_sources, the rule gov_close_push_on and --enable apply) - an acceptance recorded
  # under an unclear version would be one that push at session close then ignores.
  local tcd tcs
  if [ -z "$tv" ] && type gov_terms_copy_dir >/dev/null 2>&1 && type _gov_terms_sources >/dev/null 2>&1; then
    tcd=$(gov_terms_copy_dir)
    if [ -f "$tcd/NOTICE-AUTO-UPDATE.md" ]; then
      tcs=$(_gov_terms_sources)
      if [ "${tcs%% *}" != "-" ] && [ "${tcs%% *}" = "${tcs##* }" ]; then
        notice="$tcd/NOTICE-AUTO-UPDATE.md"; tv="${tcs##* }"
      else
        say "the installed terms version is unclear on this machine (installed.manifest and ~/.claude/hooks/governance-terms/TERMS-VERSION do not state the same version): re-run install.sh from a clone of the repository, in your own terminal. Nothing was recorded."
        return 1
      fi
    fi
  fi
  case "$tv" in ''|*[!0-9]*) say "no staged release, no installer copy and no installed copy of the terms carry terms - nothing to accept."; return 1 ;; esac
  [ -f "$notice" ] || { say "the terms text is missing ($notice) - nothing recorded."; return 1; }
  # Only a person accepts (C3): an acceptance would be recorded (GOV_ACCEPT_TERMS=1 or the prompt)
  # and this runs inside an AI-agent session -> the A.2 refusal, nothing recorded. Fails closed when
  # consent-lib.sh (sourced by _common.sh) is missing.
  if ! type gov_human_consent_ok >/dev/null 2>&1 || ! type gov_consent_write >/dev/null 2>&1; then
    say "consent-lib.sh is missing beside gov-update.sh - nothing recorded."; return 1
  fi
  if { [ "${GOV_ACCEPT_TERMS:-0}" = "1" ] || [ -t 0 ]; } && ! gov_human_consent_ok; then
    gov_consent_refusal_line
    upd_log terms "refused: an AI-agent session was detected - terms v$tv not recorded"
    return 1
  fi
  # C5: the hashes are of THIS notice - the one whose summary is printed below.
  nsha=$(gov_sha256_lf "$notice") || nsha=""
  ssha=$(gov_terms_summary "$notice" | gov_sha256_lf_stdin) || ssha=""
  if [ -z "$nsha" ] || [ -z "$ssha" ]; then
    say "cannot compute the SHA-256 of the terms text (sha256sum or shasum is needed) - nothing recorded."; return 1
  fi
  echo "Context Governance for Claude Code — terms version $tv"
  echo "Full text: $notice   License: MIT, provided AS IS (see LICENSE)"
  echo
  gov_terms_summary "$notice"
  echo
  if [ "${GOV_ACCEPT_TERMS:-0}" = "1" ]; then
    method="env"
  elif [ -t 0 ]; then
    read -r -p "Type I ACCEPT to continue (anything else stops here; nothing has been changed yet): " ans || true
    [ "$ans" = "I ACCEPT" ] || { say "terms NOT accepted - nothing recorded."; return 1; }
    method="interactive"
  else
    say "no terminal to ask on: read $notice, then run this yourself, in your own terminal: bash ~/.claude/hooks/governance/gov-update.sh --accept-terms  (or, for an installation without a terminal, GOV_ACCEPT_TERMS=1 set by you for that one command). Nothing was recorded."
    return 1
  fi
  if ! gov_consent_write "$UPD/terms-accepted" "terms_version=$tv accepted_at=$(now_iso) framework_version=$(upd_installed_version) method=$method notice_sha256=$nsha shown_sha256=$ssha"; then
    say "could not write ~/.claude/.governance-update/terms-accepted - nothing recorded."; return 1
  fi
  upd_log terms "terms v$tv accepted ($method)"
  if [ -n "$held" ]; then
    # Only now may the held release run its first code (the deep verify), then become READY.
    say "terms v$tv accepted ($method)."
    upd_lock prepare || { say "another update process holds the lock - v$held stays held; prepare it later with  bash ~/.claude/hooks/governance/gov-update.sh --fetch $held"; return 1; }
    upd_prepare_held "$held"
    return $?
  fi
  if [ -f "$UPD/READY" ] && [ -n "$ver" ]; then
    say "terms v$tv accepted ($method). Nothing installs on its own: to install v$ver, close every Claude Code session, then in your own terminal run  bash ~/.claude/hooks/governance/gov-update.sh --apply --force-live"
  else
    say "terms v$tv accepted ($method). Nothing was installed, and nothing installs on its own."
  fi
}

upd_clear_halt() {
  local f n=0
  for f in "$UPD"/HALT-* "$UPD"/fetch-attempts-* "$UPD"/fetch-404-* "$UPD/deferrals" "$UPD/apply-slow" "$UPD"/retry-* "$UPD"/.advised-gaveup-*; do
    [ -e "$f" ] || continue
    rm -f "$f" && n=$((n + 1))
  done
  upd_log clear-halt "cleared $n halt/counter file(s)"
  say "cleared $n halt/counter file(s). Download it again by hand: bash ~/.claude/hooks/governance/gov-update.sh --fetch <ver>"
}

upd_verify_archive() {
  local tgz="$1" dir ver rc=0
  [ -f "$tgz" ] || { echo "verify-archive: FAIL no such file: $tgz"; return 1; }
  dir=$(mktemp -d 2>/dev/null) || dir="${TMPDIR:-/tmp}/gov-verify.$$"
  if ! upd_extract "$tgz" "$dir/t"; then
    echo "verify-archive: FAIL $EX_REASON: $EX_DETAIL"; rm -rf "$dir"; return 1
  fi
  ver=$(relman_get "$dir/t/RELEASE-MANIFEST" version 2>/dev/null)
  if upd_verify_tree "$dir/t" "$ver" "$UPD/allowed_signers" full; then
    echo "verify-archive: OK v$ver ($(relman_get "$dir/t/RELEASE-MANIFEST" files) files: signature, checksums, file set, install map, syntax$([ "${GOV_UPDATE_SKIP_DEEP_VERIFY:-0}" = "1" ] || printf ', deep verify'))"
  else
    echo "verify-archive: FAIL $VERIFY_REASON: $VERIFY_DETAIL"; rc=1
  fi
  rm -rf "$dir"
  return "$rc"
}

# --selftest: the verification chain against throwaway keys, both directions, fully offline.
upd_selftest() {
  local d pass=0 fail=0 k1 k2 tree r out sbh
  command -v ssh-keygen >/dev/null 2>&1 || { echo "gov-update selftest: SKIP (no ssh-keygen)"; return 0; }
  d=$(mktemp -d 2>/dev/null) || d="${TMPDIR:-/tmp}/gov-upd-st.$$"
  sbh="$d/sandbox-user"
  k1="$d/k1"; k2="$d/k2"
  ssh-keygen -q -t ed25519 -N '' -f "$k1" -C t </dev/null >/dev/null 2>&1
  ssh-keygen -q -t ed25519 -N '' -f "$k2" -C t </dev/null >/dev/null 2>&1
  _st_ok() { if [ "$1" = "$2" ]; then pass=$((pass + 1)); echo "  ok   $3"; else fail=$((fail + 1)); echo "  FAIL $3 (got '$1', want '$2')"; fi; }
  _st_build() {  # _st_build <name> <signing key> [mutation]
    tree="$d/$1/gov-9.9.9"; rm -rf "$d/$1"; mkdir -p "$tree/bundle/release" "$tree/bundle/hooks/governance"
    printf '%s namespaces="%s" %s\n' "$RELMAN_PRINCIPAL" "$RELMAN_NS" "$(cut -d' ' -f1,2 "$k1.pub")" > "$tree/bundle/release/allowed_signers"
    printf '#!/usr/bin/env bash\necho hi\n' > "$tree/bundle/hooks/governance/x.sh"
    printf 'bundle/hooks/governance/x.sh -> hooks/governance/x.sh  core\n' > "$d/$1.map"
    [ "${3:-}" = "badmap" ] && printf 'bundle/hooks/governance/x.sh -> ../x.sh  core\n' > "$d/$1.map"
    relman_build "$tree" 9.9.9 1 "$d/$1.map" 2026-01-01T00:00:00Z > "$tree/RELEASE-MANIFEST"
    ssh-keygen -Y sign -f "$2" -n "$RELMAN_NS" "$tree/RELEASE-MANIFEST" </dev/null >/dev/null 2>&1
    [ "${3:-}" = "tamper" ] && printf 'echo evil\n' >> "$tree/bundle/hooks/governance/x.sh"
    [ "${3:-}" = "extra" ] && printf 'x\n' > "$tree/bundle/extra.txt"
    (cd "$d/$1" && tar -czf "$d/$1.tgz" gov-9.9.9)
  }
  mkdir -p "$sbh/.claude/.governance-update"
  printf '%s namespaces="%s" %s\n' "$RELMAN_PRINCIPAL" "$RELMAN_NS" "$(cut -d' ' -f1,2 "$k1.pub")" > "$sbh/.claude/.governance-update/allowed_signers"
  echo "gov-update selftest (throwaway keys, sandbox HOME):"
  _st_build good "$k1"; _st_build tamper "$k1" tamper; _st_build extra "$k1" extra
  _st_build wrongkey "$k2"; _st_build badmap "$k1" badmap
  out=$(HOME="$sbh" GOV_UPDATE_SKIP_DEEP_VERIFY=1 bash "$0" --verify-archive "$d/good.tgz" 2>/dev/null)
  case "$out" in "verify-archive: OK v9.9.9"*) _st_ok 1 1 "valid signed archive verifies (positive control)" ;; *) _st_ok "$out" "verify-archive: OK" "positive control" ;; esac
  for r in tamper:checksum extra:checksum wrongkey:signature badmap:install-map; do
    out=$(HOME="$sbh" GOV_UPDATE_SKIP_DEEP_VERIFY=1 bash "$0" --verify-archive "$d/${r%%:*}.tgz" 2>/dev/null)
    case "$out" in "verify-archive: FAIL ${r#*:}"*) _st_ok 1 1 "${r%%:*} refused as ${r#*:}" ;; *) _st_ok "$out" "FAIL ${r#*:}" "${r%%:*} refused" ;; esac
  done
  gov_semver_cmp_var r 1.10.0 1.9.0; _st_ok "$r" gt "semver 1.10.0 > 1.9.0"
  gov_semver_cmp_var r 2.0.0 2.0.0; _st_ok "$r" eq "semver 2.0.0 = 2.0.0"
  gov_semver_cmp_var r 1.8.0 1.9.0; _st_ok "$r" lt "semver 1.8.0 < 1.9.0"
  rm -rf "$d"
  echo "gov-update selftest: pass=$pass fail=$fail"
  [ "$fail" = "0" ]
}

# ── dispatch ─────────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
  --fetch)
    # A human ran it: say so even when GOV_BYPASS_QUIET=1 mutes gov_disabled's generic notice.
    if gov_disabled; then say "GOVERNANCE_HOOKS=0 is set (governance is off) - nothing downloaded."; exit 0; fi
    upd_fetch "${2:-}"; exit 0 ;;
  --apply-if-ready)
    # The detached recovery child: rolls an interrupted apply back; never applies a staged release.
    gov_disabled && exit 0
    upd_apply 1 0; exit 0 ;;
  --recover-detached)
    # pre-session.sh, when an apply died mid-swap: restore it in the background (the restore is ~17 s
    # and never interruptible, so it cannot run inside a 10 s SessionStart hook). The child rolls
    # back only - upd_apply never STARTS an apply for it.
    gov_disabled && exit 0
    [ -f "$UPD/APPLYING" ] || exit 0
    upd_spawn_detached; exit 0 ;;
  --apply)
    if [ "${2:-}" = "--force-live" ]; then upd_apply 0 1; else upd_apply 0 0; fi; exit 0 ;;
  --rollback)       upd_manual_rollback "${2:-}"; exit $? ;;
  --status)         upd_status; exit 0 ;;
  --verify-archive) upd_verify_archive "${2:-}"; exit $? ;;
  --accept-terms)   upd_accept_terms; exit $? ;;
  --clear-halt)     mkdir -p "$UPD"; upd_clear_halt; exit 0 ;;
  --selftest)       upd_selftest; exit $? ;;
  *)
    sed -n '/^# Modes/,/^# Environment/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
    # On its own line: the selftest's NOBLOCK mutant rewrites `exit 2` lines, and case_no_auto_update
    # asserts rc=2 here (the SessionEnd mode, removed in 2.0.0) - so an unknown flag can never be
    # silently taken as success.
    exit 2
    ;;
esac
