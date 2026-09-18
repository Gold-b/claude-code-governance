#!/usr/bin/env bash
# sync-governance-copies.sh — Auto-sync governance files to all 4 locations
# Fires on PostToolUse (Edit/Write/MultiEdit/NotebookEdit).
#
# When a governance file (hook or skill) is edited at the PRIMARY location
# (~/.claude/hooks/governance/ or ~/.claude/skills/), this hook automatically
# copies it to:
#   1. The installer bundle: ~/.claude/governance-installer/bundle/…  (always)
#   2. Any checkout listed in ~/.claude/.governance-mirrors            (optional, machine-local)
#
# MIRROR ROOTS ARE CONFIGURATION, NOT CODE (2026-08-18). They used to be two hardcoded
# absolute paths naming private repositories - in a PUBLIC repository, and useless to
# anyone else installing this framework. `.governance-mirrors` is machine-local, never
# shipped in the bundle: one absolute checkout root per line, `#` for comments, blank
# lines ignored. Absent file = no repo mirrors, which is the correct default for a fresh
# install. See GOVERNANCE-AGENT-GUIDE §19.
#
# Also sets a flag file so end-session.sh knows to commit+push to GitHub.
#
# Created: 2026-04-12 (eliminates manual 4-location sync)
# Kill switch: GOVERNANCE_HOOKS=0
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }
gov_disabled && exit 0

# ---------------------------------------------------------------------------
# WHAT SHIPS — one definition, read here and by install.sh: bundle/DISTRIBUTED
#
# Before 1.7.0 this hook decided the private->public crossing with a DENYLIST
# (GOV_NEVER_DISTRIBUTE_SKILLS) and an unconditional `mkdir -p` into the bundle for
# everything else, while install.sh carried its own hardcoded lists. Two owners for one
# invariant, never compared: MEASURED, every user-level skill on this machine — including
# deployment tooling naming real clients and containers — was one Edit-tool save away from
# entering a PUBLIC bundle, gated only by a scanner that models shapes and cannot see a
# product name.
#
# An allow-list fails the safe way round: a new skill/agent/root-hook does not cross until a
# human writes its name in bundle/DISTRIBUTED. A MISSING or unparseable DISTRIBUTED therefore
# means "nothing crosses", and says so out loud — a silent fail-open here is the whole bug.
# ---------------------------------------------------------------------------
GOV_DISTRIBUTED_FILE="${GOV_DISTRIBUTED_FILE:-$HOME/.claude/governance-installer/bundle/DISTRIBUTED}"

# _gov_distributed <section> — one name per line from [section].
# LITERAL header equality, never `$0 ~ want`: with want="[core]" a regex match reads the
# brackets as a CHARACTER CLASS and every section header matches, returning the whole file
# for every query. That bug was caught by a parity assertion in install.sh, not by review.
_gov_distributed() {
  [ -f "$GOV_DISTRIBUTED_FILE" ] || return 1
  awk -v want="[$1]" '
    /^[[:space:]]*\[/ {
      hdr = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", hdr)
      inside = (hdr == want)
      next
    }
    inside {
      sub(/#.*$/, "");
      gsub(/^[[:space:]]+|[[:space:]]+$/, "");
      if (length($0)) print
    }
  ' "$GOV_DISTRIBUTED_FILE" 2>/dev/null
}

# _gov_is_distributed <section> <name> — 0 = may cross into the bundle.
_gov_is_distributed() {
  local _sect="$1" _want="$2" _n
  [ -n "$_want" ] || return 1
  if [ ! -f "$GOV_DISTRIBUTED_FILE" ]; then
    echo "[GOVERNANCE-SYNC] bundle/DISTRIBUTED is MISSING at $GOV_DISTRIBUTED_FILE - nothing may cross into the publishable bundle until it exists. (Nothing was copied; the live file is untouched.)" >&2
    gov_log "sync-copies" "DISTRIBUTED missing - crossing refused for $_sect/$_want"
    return 1
  fi
  while IFS= read -r _n; do
    [ "$_n" = "$_want" ] && return 0
  done <<GOVDISTEOF
$(_gov_distributed "$_sect")
GOVDISTEOF
  return 1
}

# ── CLAUDE.md: SOURCE-CLEAN + CUT, never scrub (1.7.0) ─────────────────────────────────
# ~/.claude/CLAUDE.md is prose policy that LEGITIMATELY names its owner, their language and
# their preferences - that is what a personal instruction file IS. Three options were weighed:
#   A. raw copy + the PII gate  - rejected: the gate models SHAPES (its own header says so).
#      A name has no shape, so a possessive first name in a section header, or a medical
#      detail, passes a shape scanner; the one backstop, NAME_DENY, is case-insensitive
#      substring matching and unusable for a two-letter first name. MEASURED 2026-09-18: two
#      agent definitions naming the owner in their second paragraph scanned CLEAN.
#   B. a real->placeholder substitution map at the crossing - rejected as the primary: it is a
#      denylist, and this framework's 2026-08-18 and 2026-09-01 incidents are both denylists
#      lagging reality. Regex over prose also rewrites code samples and cannot be reviewed
#      with a plain diff. Kept only as the fail-closed backstop it already is (.pii-names).
#   C. CUT at a marker - CHOSEN. Everything above the marker is publishable verbatim, the
#      local part lives below it, and the transform is `sed -n` with no pattern matching on
#      the content at all.
# The RENDERED file is then PII-scanned like every other bundle file, so a name that drifts
# above the marker REFUSES the copy instead of publishing. Marker absent => the whole file is
# treated as local and NOTHING is published. Never "copy the whole file".
GOV_CLAUDE_LOCAL_MARKER='GOV-LOCAL-ONLY'
GOV_CLAUDE_MD="${GOV_CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"
GOV_TEMPLATE_HEAD="${GOV_TEMPLATE_HEAD:-$HOME/.claude/governance-installer/bundle/CLAUDE.md.template.head}"
GOV_TEMPLATE_DEST="${GOV_TEMPLATE_DEST:-$HOME/.claude/governance-installer/bundle/CLAUDE.md.template}"

# _gov_render_claude_md <outfile>
#   0 rendered - 1 live file unreadable/write failed - 4 marker missing - 5 head file missing
_gov_render_claude_md() {
  local out="$1" m
  [ -f "$GOV_CLAUDE_MD" ] || return 1
  [ -f "$GOV_TEMPLATE_HEAD" ] || return 5
  m=$(grep -n "$GOV_CLAUDE_LOCAL_MARKER" "$GOV_CLAUDE_MD" 2>/dev/null | head -1 | cut -d: -f1)
  [ -n "$m" ] || return 4
  [ "$m" -gt 1 ] 2>/dev/null || return 4
  # head carries the H1 and the generic User Preferences stanza, so the live file's own line 1
  # (its H1) is dropped - otherwise the template would carry two titles.
  { cat "$GOV_TEMPLATE_HEAD"; sed -n "2,$((m-1))p" "$GOV_CLAUDE_MD"; } > "$out" 2>/dev/null || return 1
  [ -s "$out" ] || return 1
  return 0
}

# --sync-all is a CLI reconcile, not a hook event: remember it here, ACT on it further down.
# The reconciler needs the PII helpers, and those are defined below — while the stdin read a few
# lines from here exits 0 on an empty payload, which is exactly what a CLI invocation has. Both
# constraints are real, so the mode is latched first and executed after the helpers exist.
GOV_SYNC_ALL=0
case "${1:-}" in --sync-all) GOV_SYNC_ALL=1 ;; esac

# --sync-if-drifted (2026-09-14): THE RECONCILER NOW HAS A CALLER.
# The block further down has correctly described this hook's own blind spot since 2026-09-01 —
# "PostToolUse does NOT fire for Bash, so a file changed with sed, python, a heredoc, cp or a
# script is never synced at all" — and it ends by saying drift "needs a reconciler". The
# reconciler was then written, and NOTHING EVER CALLED IT. A documented gap with a working fix
# nobody invokes is still an open gap; measured twice in two days, once in this very session:
# two hooks edited through the Edit tool mirrored instantly, a third edited through a shell
# splice did not, and no signal was produced at any point.
#
# So this mode is registered on Stop. It is cheap on the happy path ON PURPOSE: a `cmp` per file
# against the installer bundle, stopping at the FIRST difference, no PII scan, no copying. Only
# when drift actually exists does it fall through to the full --sync-all reconcile, which is the
# expensive-but-rare path. Session close is the right moment because it is the last instant
# before a publish can consume the queue.
# Deliberately NOT a new script: a new script needs its own registration and its own selftest in
# both directions, and this invariant already belongs to this file. One owner per invariant.
if [ "${1:-}" = "--sync-if-drifted" ]; then
  _sid_live_h="$HOME/.claude/hooks/governance"
  _sid_live_s="$HOME/.claude/skills"
  _sid_inst="$HOME/.claude/governance-installer/bundle"
  _sid_drift=""
  if [ -d "$_sid_inst" ]; then
    while IFS= read -r _sid_f; do
      [ -n "$_sid_f" ] || continue
      _sid_rel="${_sid_f#"$_sid_live_h"/}"
      _sid_dst="$_sid_inst/hooks/governance/$_sid_rel"
      # A file the bundle has never carried is NOT drift: the sync is deliberately
      # "MIRROR, NEVER RESURRECT", so absence there is a decision, not a stale copy.
      [ -f "$_sid_dst" ] || continue
      cmp -s "$_sid_f" "$_sid_dst" || { _sid_drift="$_sid_rel"; break; }
    done <<SIDEOF
$(find "$_sid_live_h" -type f \( -name '*.sh' -o -name '*.js' -o -name '*.py' -o -name '*.ps1' \) 2>/dev/null | sort)
SIDEOF
  fi
  if [ -z "$_sid_drift" ] && [ -d "$_sid_inst/skills" ]; then
    while IFS= read -r _sid_f; do
      [ -n "$_sid_f" ] || continue
      _sid_rel="${_sid_f#"$_sid_live_s"/}"
      _sid_dst="$_sid_inst/skills/$_sid_rel"
      [ -f "$_sid_dst" ] || continue
      cmp -s "$_sid_f" "$_sid_dst" || { _sid_drift="skills/$_sid_rel"; break; }
    done <<SIDSEOF
$(find "$_sid_live_s" -type f -name 'SKILL.md' 2>/dev/null | sort)
SIDSEOF
  fi
  if [ -z "$_sid_drift" ]; then
    gov_log "sync-governance-copies" "Stop drift check: live and installer bundle agree - nothing to reconcile"
    exit 0
  fi
  gov_log "sync-governance-copies" "Stop drift check: DRIFT at $_sid_rel - a copy was changed outside Edit/Write (Bash, sed, cp, a script). Running the full reconcile."
  echo "[sync-governance] Drift detected ($_sid_drift). A governance file was changed outside the Edit/Write tools, which this hook cannot see. Reconciling all copies now." >&2
  GOV_SYNC_ALL=1
  set -- --sync-all
fi

# --- Read tool result from stdin (JSON with file_path) ---
INPUT=$(gov_hook_input)
if [ -z "$INPUT" ] && [ "$GOV_SYNC_ALL" = "0" ]; then
  exit 0
fi

# Extract file_path from JSON. Claude Code PostToolUse schema is:
#   {"tool_input":{"file_path":"..."}, "tool_name":"Edit", "cwd":"..."}
# Older format had file_path at top-level. Handle both.
FILE_PATH=""
if command -v python3 &>/dev/null; then
  FILE_PATH=$(echo "$INPUT" | timeout 5 python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  # Try nested (correct for PostToolUse), then top-level, then tool_response
  p = d.get('tool_input', {}).get('file_path', '') or d.get('file_path', '') or d.get('tool_response', {}).get('filePath', '')
  print(p)
except: pass
" 2>/dev/null)
fi
# Fallback: regex catches either nested or top-level file_path
if [ -z "$FILE_PATH" ]; then
  FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"//;s/"$//')
fi
if [ -z "$FILE_PATH" ]; then
  gov_log "sync-copies" "no file_path extracted from stdin (len=${#INPUT})"
  # A CLI reconcile has no payload BY DESIGN; only the hook path needs a file_path.
  [ "$GOV_SYNC_ALL" = "1" ] || exit 0
fi

# --- Normalize path (Windows backslash -> forward slash) ---
FILE_PATH=$(echo "$FILE_PATH" | tr '\\' '/')

# gov_same_file: are two paths the same file, across the forms this hook receives?
# The payload gives `C:/Users/<user>/.claude/...` while every SOURCE this script builds is
# `$HOME/...` = `/c/Users/<user>/.claude/...`. A raw string compare therefore says "different"
# for a legitimate HOME edit and would disable syncing entirely. Fold `C:/` -> `/c/`, drop a
# trailing slash, and compare case-insensitively (Windows paths are case-insensitive).
gov_norm_path() {
  # Pure shell on purpose: no sed backreference and no backslash literal. An escaped capture
  # group did not survive being written into this file, and it failed in the LOOKS-CORRECT
  # direction - it silently dropped the drive letter, so a legitimate HOME edit compared as a
  # foreign path and was refused. FILE_PATH is already slash-normalised above.
  _p=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$_p" in
    [a-z]:/*) _p="/${_p%%:*}/${_p#*:/}" ;;
  esac
  while [ "${_p%/}" != "$_p" ]; do _p="${_p%/}"; done
  printf '%s' "$_p"
}
gov_same_file() { [ "$(gov_norm_path "$1")" = "$(gov_norm_path "$2")" ]; }

# ---------------------------------------------------------------------------
# PRIVATE -> PUBLIC BOUNDARY GATE (armed 2026-09-01)
#
# WHY THIS EXISTS. Everything this hook does is a *copy*, and exactly ONE of those copies
# leaves the machine: the one into ~/.claude/governance-installer/bundle/, which end-session.sh
# commits and pushes to a PUBLIC repository. The live tree is ALLOWED to hold this machine's
# real values - that is what a running installation IS - so the question at this boundary is
# never "is the live file clean", it is "may this file cross". Until today nothing asked, and
# real phone numbers reached the public repo through the two cp lines below.
#
# WHAT IS GATED, AND WHAT IS NOT
#   installer bundle -> ALWAYS. It is the only publishable destination on this machine.
#   mirror roots     -> ON by default (B28, 2026-09-02). A mirror listed in
#                       ~/.claude/.governance-mirrors can be a REAL GitHub repo (a product
#                       checkout), and the previous leak also travelled through a tree
#                       everyone assumed was private, so the safe default is to scan the crossing.
#                       The verdict is already computed by then and the union pre-filter makes a
#                       clean file one grep, so the cost is small. GOV_PII_GATE_MIRRORS=0 turns it
#                       off, accepting that a leak refused from the bundle could still reach a
#                       mirror ungated (say so in the guide — the silence used to read as "scanned").
#   the live tree    -> never. That is where the real values legitimately live.
#
# COST, AND WHY THE GATE IS SHAPED THIS WAY. Measured on this machine: ONE check-no-pii.sh run
# costs ~13 s regardless of file size (it is fork-bound - ~180 ms per grep, ~20 greps and ~40
# command substitutions per file; a one-line file measured 14.3 s). A 13 s tax on every
# governance edit is exactly how a control gets switched off, and a switched-off control is how
# controls die. So the gate is two-stage:
#   stage 1  ONE grep against the union of the SCANNER'S OWN rule regexes (~0.35 s measured).
#            A miss is a PROOF of no hit: check-no-pii cannot report what its own regexes never
#            matched. So a clean file is cleared without paying for the full run.
#   stage 2  ONLY for a file that tripped stage 1 (~31% of the current hook tree): the real
#            check-no-pii.sh, which applies the exemptions and prints the rule and the remedy.
# The regexes are NEVER copied into this file - they are read out of "check-no-pii.sh
# --list-rules" and cached against that script mtime+size, so a rule added there is
# automatically a rule here. If the extracted rule count ever disagrees with the scanner own
# RULES list, the prefilter is refused and stage 2 runs unconditionally: an under-covering
# prefilter must cost time, never safety.
#
# FAILURE DIRECTION. If the gate cannot run at all (scanner missing, unreadable, prefilter
# unbuildable) the BUNDLE COPY IS REFUSED, loudly. That blocks no work: this is a PostToolUse
# hook, the user's edit is already on disk, and only PUBLICATION is withheld. The opposite
# default - copy anyway and print "skipped" - is the precise failure this session exists to fix.
#
# Kill switches: GOVERNANCE_HOOKS=0 (all governance) - GOV_PII_GATE=0 (this gate only)
#                GOV_PII_GATE_MIRRORS=0 (STOP scanning mirror roots; on by default since B28)
# ---------------------------------------------------------------------------
# Overridable so the gate can be exercised against a stub in a test, and so an installer
# that relocates the scanner does not silently turn the gate into a no-op.
PII_SCANNER="${GOV_PII_SCANNER:-$SCRIPT_DIR/check-no-pii.sh}"
# B10: announce a scanner override — a silent GOV_PII_SCANNER swap could disable the sync gate.
[ -n "${GOV_PII_SCANNER:-}" ] && { [ "${GOV_BYPASS_QUIET:-0}" = "1" ] || echo "[governance] GOV_PII_SCANNER override active — sync boundary gate is using $GOV_PII_SCANNER instead of the built-in check-no-pii.sh. (GOV_BYPASS_QUIET=1 to mute)" >&2; }
PII_UNION_CACHE="$HOME/.claude/logs/.gov-pii-union.cache"
PII_UNION_SIG="$HOME/.claude/logs/.gov-pii-union.sig"
PII_NAMES_FILE="${GOV_PII_NAMES:-$HOME/.claude/.pii-names}"
PII_DENY_FILE="${GOV_PII_DENYLIST:-$HOME/.claude/.governance-pii-denylist}"
DIVERGENCE_LOG="$HOME/.claude/logs/.governance-bundle-divergence"
FLAG_FILE="$HOME/.claude/logs/.governance-push-pending"
PII_REPORT=""
REFUSED_BUNDLE=0
_PII_MEMO_F=""; _PII_MEMO_RC=""

gov_pii_gate_off() { [ "${GOV_PII_GATE:-1}" = "0" ]; }

# Prefilter, rebuilt whenever check-no-pii.sh changes. Prints the pattern-file path on stdout;
# returns 1 when it cannot be TRUSTED, which makes the caller scan unconditionally.
_pii_union_file() {
  local sig tmp n_have n_expect
  [ -f "$PII_SCANNER" ] || return 1
  sig="v1 $(gov_mtime "$PII_SCANNER") $(wc -c < "$PII_SCANNER" 2>/dev/null | tr -d ' ')"
  if [ -s "$PII_UNION_CACHE" ] && [ -f "$PII_UNION_SIG" ]; then
    if [ "$(cat "$PII_UNION_SIG" 2>/dev/null)" = "$sig" ]; then
      printf '%s' "$PII_UNION_CACHE"; return 0
    fi
  fi
  tmp="$PII_UNION_CACHE.$$"
  bash "$PII_SCANNER" --list-rules 2>/dev/null \
    | grep -E '^[A-Z][A-Z0-9_]*[[:space:]]' \
    | grep -v 'machine-local file:' \
    | sed -E 's/^[A-Z0-9_]+[[:space:]]+//' > "$tmp" 2>/dev/null
  n_have=$(grep -c . "$tmp" 2>/dev/null | tr -d ' ')
  # The scanner's own inventory of shape rules. Disagreement => the extraction drifted away
  # from the scanner, so the prefilter is thrown away rather than silently under-covering.
  n_expect=$(grep -E '^RULES=' "$PII_SCANNER" 2>/dev/null | head -1 | sed -e 's/^RULES=//' -e 's/"//g' | wc -w | tr -d ' ')
  if [ -z "$n_have" ] || [ -z "$n_expect" ] || [ "$n_expect" -lt 1 ] 2>/dev/null || [ "$n_have" -ne "$n_expect" ] 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null; return 1
  fi
  mkdir -p "$(dirname "$PII_UNION_CACHE")" 2>/dev/null
  mv -f "$tmp" "$PII_UNION_CACHE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  printf '%s' "$sig" > "$PII_UNION_SIG" 2>/dev/null
  printf '%s' "$PII_UNION_CACHE"; return 0
}

# The machine-local literal lists (names / denylist) compiled to a fixed-string pattern file.
# grep -F is deliberately LOOSER than the scanner's word-bounded match: a superset can only
# cost a stage-2 run, never a miss. Comments and blank lines are stripped - a blank -F pattern
# matches every line and would turn the prefilter into a no-op.
_pii_list_file() {
  local out l n
  out="$HOME/.claude/logs/.gov-pii-lists.$$"
  : > "$out" 2>/dev/null || return 1
  for l in "$PII_NAMES_FILE" "$PII_DENY_FILE"; do
    [ -s "$l" ] || continue
    sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$l" 2>/dev/null \
      | tr 'A-Z' 'a-z' >> "$out"
  done
  n=$(grep -c . "$out" 2>/dev/null | tr -d ' ')
  if [ -z "$n" ] || [ "$n" -eq 0 ] 2>/dev/null; then rm -f "$out" 2>/dev/null; return 1; fi
  printf '%s' "$out"; return 0
}

# _pii_scan <file>...
#   0 = clean - 2 = contaminated (details in $PII_REPORT) - 3 = the gate itself is unusable
_pii_scan() {
  local uf lf f g rc out
  local -a cand
  cand=()
  PII_REPORT=""
  if [ $# -eq 1 ] && [ -n "$_PII_MEMO_F" ] && [ "$_PII_MEMO_F" = "$1" ]; then
    # B28-fix: restore the REPORT too, not just the rc. Since B28 defaulted the mirror gate ON,
    # the mirror scans a file BEFORE the bundle does; the bundle's memo hit would otherwise return
    # rc=2 with an EMPTY report, and _pii_refuse would log the public-crossing refusal as
    # "(gate-error)" (losing the real rule + remedy, and nudging toward the leaking GOV_PII_GATE=0).
    PII_REPORT="$_PII_MEMO_REPORT"
    return "$_PII_MEMO_RC"
  fi
  if [ ! -f "$PII_SCANNER" ]; then
    PII_REPORT="check-no-pii.sh is MISSING at $PII_SCANNER - the boundary has no scanner."
    return 3
  fi
  uf="$(_pii_union_file)" || uf=""
  lf="$(_pii_list_file)" || lf=""
  for f in "$@"; do
    [ -f "$f" ] || continue
    # Unreadable, or no trustworthy prefilter: escalate rather than clear.
    if [ ! -r "$f" ] || [ -z "$uf" ]; then cand[${#cand[@]}]="$f"; continue; fi
    grep -qEf "$uf" -- "$f" 2>/dev/null; g=$?
    # 0 = a PII shape is present -> stage 2. 1 = none -> cleared. ANYTHING ELSE is grep
    # failing to answer, and a prefilter that cannot answer must escalate, never clear.
    # This branch is not theoretical: measured 2026-09-01, Git Bash grep SIGABRTs (rc 134)
    # on `-i -F -f`, and without this the crash read as "no match" and cleared every file.
    if [ "$g" -ne 1 ]; then cand[${#cand[@]}]="$f"; continue; fi
    if [ -n "$lf" ]; then
      # Case-insensitive fixed-string matching is done by lowercasing BOTH sides instead of
      # with -i, because -i + -F + -f aborts this platform's grep outright. Hebrew and other
      # caseless scripts are unaffected by the fold, so nothing is lost.
      tr 'A-Z' 'a-z' < "$f" 2>/dev/null | grep -qFf "$lf" 2>/dev/null; g=$?
      if [ "$g" -ne 1 ]; then cand[${#cand[@]}]="$f"; continue; fi
    fi
  done
  [ -n "$lf" ] && rm -f "$lf" 2>/dev/null
  if [ ${#cand[@]} -eq 0 ]; then
    rc=0
  else
    out="$(bash "$PII_SCANNER" "${cand[@]}" 2>&1)"; rc=$?
    case "$rc" in
      0) : ;;
      2) PII_REPORT="$out" ;;
      *) PII_REPORT="check-no-pii.sh exited $rc (expected 0 or 2); treating the gate as unusable. $out"; rc=3 ;;
    esac
  fi
  if [ $# -eq 1 ]; then _PII_MEMO_F="$1"; _PII_MEMO_RC="$rc"; _PII_MEMO_REPORT="$PII_REPORT"; fi
  return "$rc"
}

# A refused copy means the live file and the bundle now DIVERGE - the exact drift this framework
# exists to prevent. So the divergence is never silent: it goes to the assistant's context, to
# the governance log, to the user's phone, and to a durable record end-session.sh re-reads. The
# record deliberately carries file + rule NAMES only: writing the matched value into a log, or
# sending it over WhatsApp, would re-publish the very thing that was just refused.
_pii_refuse() {
  local src="$1" dest="$2" label="$3" rc="$4" rules kind
  # A mirror and the bundle are different destinations with different stakes; a message that
  # calls a mirror "the public bundle" trains the reader to stop believing the message.
  case "$label" in mirror:*) kind="MIRROR" ;; *) kind="BUNDLE" ;; esac
  [ "$kind" = "BUNDLE" ] && REFUSED_BUNDLE=$((REFUSED_BUNDLE + 1))
  rules=$(printf '%s\n' "$PII_REPORT" | grep -oE '\[[A-Z0-9_]+\]' | sort -u | tr -d '[]' | tr '\n' ' ' | sed 's/ $//')
  [ -n "$rules" ] || rules="(gate-error)"
  mkdir -p "$(dirname "$DIVERGENCE_LOG")" 2>/dev/null
  printf '%s\tREFUSED\t%s\t%s\t%s\n' "$(date -Iseconds 2>/dev/null || date)" "$label" "$rules" "$src" >> "$DIVERGENCE_LOG" 2>/dev/null
  gov_log "sync-copies" "BUNDLE COPY REFUSED (rc=$rc) label=$label rules=$rules src=$src"
  gov_notify \
    "PII gate: $kind copy refused" \
    "$label was NOT copied (rules: $rules). The live file and that destination are now out of sync until it scans clean." \
    ""
  if [ "$rc" -eq 3 ]; then
    {
      echo "[GOVERNANCE-PII-GATE] $kind COPY REFUSED - the gate itself could not run."
      echo "  file    : $src"
      echo "  target  : $dest"
      echo "  reason  : $PII_REPORT"
      echo "  effect  : the live file and the installer bundle now DIVERGE (recorded in $DIVERGENCE_LOG)."
      echo "  fix     : repair check-no-pii.sh, then re-save the file to re-trigger this hook."
      echo "  bypass  : GOV_PII_GATE=0 (publishes UNCHECKED - that is how real numbers leaked on 2026-09-01)"
    } >&2
    return 0
  fi
  {
    echo "[GOVERNANCE-PII-GATE] $kind COPY REFUSED - this file carries a real value and may not be copied."
    echo "  file    : $src"
    echo "  target  : $dest"
    echo "  rules   : $rules"
    printf '%s\n' "$PII_REPORT" | grep -E '^[^ ]+:[0-9]+: \[|^    -> ' | head -30
    echo "  WHAT THIS MEANS: the edit is saved; only PUBLICATION was withheld. The live file and"
    echo "  the installer bundle now DIVERGE, and stay diverged until this file scans clean."
    echo "  REMEDY: put the real value in ~/.claude/.governance-local.env (see the .example file)"
    echo "          and leave a placeholder or an env lookup in the tracked file. Save again - this"
    echo "          hook re-runs and the copy goes through."
    echo "  Recorded in: $DIVERGENCE_LOG    Bypass (publishes unchecked): GOV_PII_GATE=0"
  } >&2
  return 0
}

# Drop this path's divergence record once it crosses cleanly again.
_pii_clear_divergence() {
  local src="$1" tmp
  [ -s "$DIVERGENCE_LOG" ] || return 0
  grep -qF "	$src" "$DIVERGENCE_LOG" 2>/dev/null || return 0
  tmp="$DIVERGENCE_LOG.$$"
  grep -vF "	$src" "$DIVERGENCE_LOG" > "$tmp" 2>/dev/null
  mv -f "$tmp" "$DIVERGENCE_LOG" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  gov_log "sync-copies" "divergence cleared for $src"
  return 0
}

# ── --sync-all: reconcile EVERY file, not just the one that was edited (task B7, 2026-09-01) ──
#
# WHY THE PER-FILE HOOK CANNOT KEEP THE COPIES EQUAL, EVER.
#   1. This hook is PostToolUse with matcher `Edit|Write|MultiEdit|NotebookEdit`. PostToolUse does
#      NOT fire for Bash — so a file changed with sed, python, a heredoc, cp or a script is never
#      synced at all. Measured 2026-09-01: a session that edited through Bash left the project
#      mirror 5 files divergent and 2 absent, and nothing said so (gotcha #355 is the same input
#      blindness, one hook over).
#   2. Even for tool-made edits it derives ONE basename from the edited path and copies only that.
#      A file that has not been edited since a mirror appeared stays stale forever, and a file the
#      mirror never had is never created — the branch is deliberately "MIRROR, NEVER RESURRECT".
#   So drift is not a bug in the sync; it is the shape of the sync. It needs a reconciler.
#
# Usage:  bash sync-governance-copies.sh --sync-all [--dry-run]
# Every file crossing into the publishable installer bundle is PII-scanned first, exactly as the
# per-file path does; a refusal leaves that one file diverged and is reported, never silent.
# Counts are printed beside the verdict: "0 refused" out of 0 files examined is not agreement.
if [ "$GOV_SYNC_ALL" = "1" ]; then
  _SA_DRY=0; [ "${2:-}" = "--dry-run" ] && _SA_DRY=1
  _SA_LIVE_HOOKS="$HOME/.claude/hooks/governance"
  _SA_LIVE_SKILLS="$HOME/.claude/skills"
  _SA_INST_HOOKS="$HOME/.claude/governance-installer/bundle/hooks/governance"
  _sa_mirror_roots() {
    local f="${GOV_MIRRORS_FILE:-$HOME/.claude/.governance-mirrors}"
    [ -f "$f" ] || return 0
    sed -e 's/#.*$//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$f" 2>/dev/null | grep -v '^$'
  }
  _sa_n=0; _sa_copied=0; _sa_same=0; _sa_refused=0; _sa_created=0; _sa_targets=0
  _sa_report=""

  _sa_one() {   # $1 live file, $2 relative path, $3 destination dir, $4 label, $5 gated(1/0)
    local src="$1" rel="$2" dstdir="$3" label="$4" gated="$5"
    # dst on its OWN line: bash expands every word of a `local` before performing any of its
    # assignments, so `local dstdir="$3" dst="$dstdir/$2"` reads the OLD (empty) dstdir and yields
    # "/wa-send.js". The dry run caught it before 80 files were written to the filesystem root -
    # which is the entire argument for having a dry run at all.
    local dst="$dstdir/$rel"
    [ -d "$dstdir" ] || return 0
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then _sa_same=$((_sa_same+1)); return 0; fi
    if [ "$gated" = "1" ] && ! gov_pii_gate_off; then
      _pii_scan "$src"; local rc=$?
      if [ "$rc" -ne 0 ]; then
        _sa_refused=$((_sa_refused+1))
        _sa_report="$_sa_report
    REFUSED (PII rc=$rc): $rel -> $label"
        return 0
      fi
    fi
    # "First time entering this destination" is the moment junk reaches a publishable tree, so it
    # is named, never folded into a count.
    local _new=0; [ -f "$dst" ] || _new=1
    if [ "$_SA_DRY" = "1" ]; then
      if [ "$_new" = "1" ]; then
        _sa_created=$((_sa_created+1))
        _sa_report="$_sa_report
    [dry] would CREATE (new to that destination): $rel -> $label"
      else
        _sa_copied=$((_sa_copied+1))
        _sa_report="$_sa_report
    [dry] would copy: $rel -> $label"
      fi
      return 0
    fi
    mkdir -p "$(dirname "$dst")" 2>/dev/null
    if cp -f "$src" "$dst" 2>/dev/null; then
      # Counted from the state BEFORE the copy. Testing `[ -f "$dst" ]` afterwards is always true
      # and would report every creation as an ordinary copy.
      if [ "$_new" = "1" ]; then
        _sa_created=$((_sa_created+1))
        _sa_report="$_sa_report
    CREATED (new to that destination): $rel -> $label"
      else
        _sa_copied=$((_sa_copied+1))
        _sa_report="$_sa_report
    copied: $rel -> $label"
      fi
    else
      _sa_report="$_sa_report
    FAILED to write: $rel -> $label"
    fi
  }

  echo "[sync-all] reconciling live governance files to every configured copy"
  # The file set is taken from the LIVE tree itself — never an extension list. An enumeration of
  # suffixes has been wrong twice in this framework already (.js/.ps1, then .py), the second time
  # one line below the comment recording the first.
  _SA_DESTS=""
  [ -d "$_SA_INST_HOOKS" ] && _SA_DESTS="installer-bundle|$_SA_INST_HOOKS|1"
  while IFS= read -r _root; do
    [ -n "$_root" ] || continue
    [ -d "$_root/.claude/hooks/governance" ] || continue
    _SA_DESTS="$_SA_DESTS
mirror:$_root|$_root/.claude/hooks/governance|${GOV_PII_GATE_MIRRORS:-1}"
  done <<SAEOF
$(_sa_mirror_roots)
SAEOF
  _sa_targets=$(printf '%s\n' "$_SA_DESTS" | grep -c . )

  while IFS= read -r _f; do
    [ -f "$_f" ] || continue
    _rel="${_f#$_SA_LIVE_HOOKS/}"
    # A DENY list of ARTIFACTS, deliberately not an allow list of source extensions. An allow list
    # is a prediction about files that do not exist yet and it has been wrong twice here already
    # (.js/.ps1, then .py). A deny list fails the safe way round: a new SOURCE type is included by
    # default, and a new artifact type shows up in the "entering for the first time" report below
    # instead of slipping into a publishable bundle unseen.
    case "$_rel" in
      *.bak|*.bak-*|*.tmp|*.orig|*.rej)  continue ;;
      *.local.md|*.local.json|*.local.sh|*.local.env|*.local.*) continue ;;  # machine-local by convention (1.7.0) — same rule as the per-file path
      __pycache__/*|*/__pycache__/*|*.pyc|*.pyo) continue ;;   # build cache
      services/*)                        continue ;;           # 2-byte stray fixture (2026-07-27) from the render-gate family; task B11
      *.lock)                            continue ;;           # concurrency lock files are never content
      desktop.ini|*/desktop.ini)         continue ;;           # Google-Drive folder metadata, not content. It was being scanned and
                                                               # REFUSED on every reconcile (2 hits, MEASURED 2026-09-18), which is
                                                               # noise in the one report that must stay readable: a real refusal has
                                                               # to stand out from a permanent one.
    esac
    _sa_n=$((_sa_n+1))
    while IFS= read -r _d; do
      [ -n "$_d" ] || continue
      _lbl="${_d%%|*}"; _rest="${_d#*|}"; _dir="${_rest%%|*}"; _gate="${_rest##*|}"
      _sa_one "$_f" "$_rel" "$_dir" "$_lbl" "$_gate"
    done <<SADEOF
$_SA_DESTS
SADEOF
  done <<SAFEOF
$(find "$_SA_LIVE_HOOKS" -type f 2>/dev/null | sort)
SAFEOF

  # ── CLAUDE.md: compare the RENDERED output, never the raw file (1.7.0) ────────────────
  # The reconciler exists because PostToolUse cannot see a Bash/sed/heredoc edit. CLAUDE.md is
  # edited that way often, and it is the one watched file whose bundle form is COMPUTED, so a
  # raw `cmp` against bundle/CLAUDE.md.template would report permanent drift and copy the
  # local section into the public bundle. Render first, then compare.
  if [ -f "$GOV_CLAUDE_MD" ] && [ -d "$(dirname "$GOV_TEMPLATE_DEST")" ]; then
    _sa_cmd_tmp="$HOME/.claude/logs/.gov-claude-template-sa.$$"
    mkdir -p "$(dirname "$_sa_cmd_tmp")" 2>/dev/null
    _gov_render_claude_md "$_sa_cmd_tmp"; _sa_rr=$?
    if [ "$_sa_rr" -eq 4 ]; then
      _sa_report="$_sa_report
    SKIPPED CLAUDE.md: no '$GOV_CLAUDE_LOCAL_MARKER' marker - the whole file is treated as local, nothing published."
    elif [ "$_sa_rr" -eq 5 ]; then
      _sa_report="$_sa_report
    SKIPPED CLAUDE.md: bundle/CLAUDE.md.template.head missing at $GOV_TEMPLATE_HEAD."
    elif [ "$_sa_rr" -eq 0 ]; then
      _sa_n=$((_sa_n+1))
      # rc captured on its own line: `_pii_scan x; [ $? -ne 0 ]` inside a compound condition
      # is readable but reads $? of whatever the shell evaluated last, which is not always the
      # scan. An explicit variable cannot drift.
      _sa_cmd_pii=0
      if ! gov_pii_gate_off; then
        _pii_scan "$_sa_cmd_tmp"; _sa_cmd_pii=$?
      fi
      if [ -f "$GOV_TEMPLATE_DEST" ] && cmp -s "$_sa_cmd_tmp" "$GOV_TEMPLATE_DEST"; then
        _sa_same=$((_sa_same+1))
      elif [ "$_sa_cmd_pii" -ne 0 ]; then
        _sa_refused=$((_sa_refused+1))
        _sa_report="$_sa_report
    REFUSED (PII rc=$_sa_cmd_pii): CLAUDE.md.template (rendered) -> installer-bundle"
      elif [ "$_SA_DRY" = "1" ]; then
        _sa_copied=$((_sa_copied+1))
        _sa_report="$_sa_report
    [dry] would render: CLAUDE.md -> bundle/CLAUDE.md.template (cut at the local-only marker)"
      elif cp -f "$_sa_cmd_tmp" "$GOV_TEMPLATE_DEST" 2>/dev/null; then
        _sa_copied=$((_sa_copied+1))
        _sa_report="$_sa_report
    rendered: CLAUDE.md -> bundle/CLAUDE.md.template (cut at the local-only marker)"
      else
        _sa_report="$_sa_report
    FAILED to write: bundle/CLAUDE.md.template"
      fi
    fi
    rm -f "$_sa_cmd_tmp" 2>/dev/null
  fi

  # ── Allow-listed agents and root hooks (1.7.0) ───────────────────────────────────────
  # Same reconcile, driven by bundle/DISTRIBUTED. Mirrors get nothing (a project-level
  # agents/ or hooks/ entry SHADOWS the user-level one), so the bundle is the only target.
  for _sa_kind in agents hooks; do
    case "$_sa_kind" in
      agents) _sa_src_dir="$HOME/.claude/agents"; _sa_dst_dir="$HOME/.claude/governance-installer/bundle/agents"; _sa_sfx=".md" ;;
      hooks)  _sa_src_dir="$HOME/.claude/hooks";  _sa_dst_dir="$HOME/.claude/governance-installer/bundle/hooks";  _sa_sfx="" ;;
    esac
    [ -d "$_sa_src_dir" ] || continue
    [ -d "$_sa_dst_dir" ] || continue
    while IFS= read -r _sa_name; do
      [ -n "$_sa_name" ] || continue
      _sa_f="$_sa_src_dir/$_sa_name$_sa_sfx"
      [ -f "$_sa_f" ] || { _sa_report="$_sa_report
    MISSING live source for allow-listed $_sa_kind entry: $_sa_name$_sa_sfx"; continue; }
      _sa_n=$((_sa_n+1))
      _sa_one "$_sa_f" "$_sa_name$_sa_sfx" "$_sa_dst_dir" "installer-bundle" "1"
    done <<SAALEOF
$(_gov_distributed "$_sa_kind")
SAALEOF
  done

  [ -n "$_sa_report" ] && printf '%s\n' "$_sa_report"
  printf '[sync-all] %s live file(s) x %s destination(s): %s already identical, %s copied, %s created, %s REFUSED by the PII gate\n' \
    "$_sa_n" "$_sa_targets" "$_sa_same" "$_sa_copied" "$_sa_created" "$_sa_refused"
  if [ "$_sa_n" -eq 0 ] || [ "$_sa_targets" -eq 0 ]; then
    echo "[sync-all] NOTHING WAS EXAMINED (files=$_sa_n destinations=$_sa_targets) — this is not agreement." >&2
    exit 1
  fi
  if [ "$_sa_copied" -gt 0 ] || [ "$_sa_created" -gt 0 ]; then
    [ "$_SA_DRY" = "1" ] || echo "$(date -Iseconds) $_SA_LIVE_HOOKS (--sync-all)" >> "$HOME/.claude/logs/.governance-push-pending"
    echo "[sync-all] the installer bundle changed; a GitHub push is queued for session end."
  fi
  [ "$_sa_refused" -gt 0 ] && exit 2
  exit 0
fi

# _bundle_copy <src> <dest> <label>
#   0 copied - 1 nothing to do - 2 refused (contaminated) - 3 refused (gate unusable)
_bundle_copy() {
  local src="$1" dest="$2" label="$3" rc
  [ -f "$src" ] || return 1
  diff -q "$src" "$dest" >/dev/null 2>&1 && return 1
  if gov_pii_gate_off; then
    mkdir -p "$(dirname "$dest")" 2>/dev/null
    if cp "$src" "$dest" 2>/dev/null; then
      gov_log "sync-copies" "GOV_PII_GATE=0 - copied $label into the bundle UNCHECKED"
      echo "[GOVERNANCE-PII-GATE] DISABLED (GOV_PII_GATE=0): $label copied into the publishable bundle without a scan." >&2
      return 0
    fi
    return 1
  fi
  _pii_scan "$src"; rc=$?
  if [ "$rc" -eq 0 ]; then
    mkdir -p "$(dirname "$dest")" 2>/dev/null
    if cp "$src" "$dest" 2>/dev/null; then _pii_clear_divergence "$src"; return 0; fi
    return 1
  fi
  _pii_refuse "$src" "$dest" "$label" "$rc"
  return "$rc"
}

# Same verdict, applied to a machine-local mirror root. ON by default (B28, 2026-09-02) — a mirror
# can be a real GitHub repo (a product checkout), and the previous leak also travelled through a
# tree everyone assumed was private. GOV_PII_GATE_MIRRORS=0 turns it off (accepting that a leak
# refused from the publishable bundle could still reach a mirror ungated). The scan is cheap in the
# common case: the union pre-filter makes a clean file one grep, not a full scanner run.
# Returns 0 when the copy may proceed.
_mirror_allowed() {
  local src="$1" dest="$2" label="$3" rc
  if [ "${GOV_PII_GATE_MIRRORS:-1}" != "1" ]; then
    # B10 principle: a bypass is legitimate, a SILENT one is not. Opting out of the mirror scan
    # copies governance files to a (possibly real GitHub) mirror UNSCANNED — announce once/process.
    if [ -z "${_GOV_MIRROR_OFF_ANNOUNCED:-}" ] && [ "${GOV_BYPASS_QUIET:-0}" != "1" ]; then
      _GOV_MIRROR_OFF_ANNOUNCED=1
      echo "[governance] GOV_PII_GATE_MIRRORS=${GOV_PII_GATE_MIRRORS} — mirror PII scan is OFF; governance files copy to mirror roots UNSCANNED. (GOV_BYPASS_QUIET=1 to mute)" >&2
    fi
    return 0
  fi
  gov_pii_gate_off && return 0
  _pii_scan "$src"; rc=$?
  [ "$rc" -eq 0 ] && return 0
  _pii_refuse "$src" "$dest" "mirror:$label" "$rc"
  return 1
}

# ── *.local.* NEVER CROSSES, unconditionally (2.2, 1.7.0) ──────────────────────────────
# The `.local.` infix is already the convention on this machine for machine-local companions
# to tracked files (config.local.json, routine-prompt.local.md). MEASURED 2026-09-18: one of
# those carries a full name, a GitHub login and a Slack user id on its FIRST LINE. Nothing
# enforced the convention - it was a naming habit that happened to sit outside a watched
# directory. This makes the name binding, and it is checked BEFORE any branch so it holds for
# docs, skills, hooks and agents alike.
#
# The convention cuts both ways, and that is the point: a THIRD `.local.md` in the same
# directory turned out to be entirely generic instructions, so on 2026-09-18 it was RENAMED out
# of the convention (-> docs/ROTATE-CONNECTOR-TOKEN.md) and now ships. `.local.` is a claim
# about a file's CONTENT, not a place to park things.
# Paired with the same pattern in the reconciler skip list and in the repo .gitignore.
case "$FILE_PATH" in
  *.local.md|*.local.json|*.local.sh|*.local.env|*.local.*)
    gov_log "sync-copies" "*.local.* is machine-local by convention - not synced: $FILE_PATH"
    exit 0
    ;;
esac

# --- Detect: is this a governance file? ---
HOOK_DIR="$HOME/.claude/hooks/governance"
SKILL_DIR="$HOME/.claude/skills"
INSTALLER_HOOKS="$HOME/.claude/governance-installer/bundle/hooks/governance"
INSTALLER_SKILLS="$HOME/.claude/governance-installer/bundle/skills"

# Normalize HOME for comparison
NORM_HOME=$(echo "$HOME" | tr '\\' '/')

IS_HOOK=0
IS_SKILL=0
BASENAME=""
SKILL_NAME=""
SKILL_REL_PATH=""

case "$FILE_PATH" in
  */.claude/hooks/governance/*)
    IS_HOOK=1
    BASENAME=$(basename "$FILE_PATH")
    ;;
  */.claude/docs/*.md)
    # Governance docs (agent/human guides) -> installer bundle only (mirrors carry hooks/skills)
    DOC_REL=$(echo "$FILE_PATH" | sed "s|.*/.claude/docs/||")
    DEST="$HOME/.claude/governance-installer/bundle/docs/$DOC_REL"
    # This branch is the ONE that copies the EDITED file itself into the publishable bundle
    # (every other branch rebuilds its source from $HOME). So a `.claude/docs/*.md` inside ANY
    # project checkout would publish that project's content. Require the HOME copy explicitly.
    if ! gov_same_file "$FILE_PATH" "$HOME/.claude/docs/$DOC_REL"; then
      echo "[GOVERNANCE-SYNC] $FILE_PATH is a PROJECT doc, not the framework doc at ~/.claude/docs/$DOC_REL - nothing synced, nothing queued for GitHub."
      gov_log "sync-copies" "project-scoped doc refused at the private->public crossing: $FILE_PATH"
      exit 0
    fi
    if [ -f "$FILE_PATH" ]; then
      if gov_dry; then echo "[GOVERNANCE DRY-RUN] sync-copies: would copy $FILE_PATH -> $DEST"; exit 0; fi
      # GATED. A guide is the likeliest carrier of a real value - guides quote real paths,
      # real hosts and real numbers - and this destination is the publishable one. The push
      # flag is queued ONLY when the copy actually happened: queueing a path that was refused
      # would ask end-session.sh to stage a file the bundle does not have.
      _bundle_copy "$FILE_PATH" "$DEST" "docs/$DOC_REL"; _rc=$?
      if [ "$_rc" -eq 0 ]; then
        echo "$(date +%Y-%m-%dT%H:%M:%S%z) $FILE_PATH" >> "$FLAG_FILE" 2>/dev/null
        gov_log "sync-copies" "docs synced to installer bundle: $DOC_REL"
        echo "[GOVERNANCE-SYNC] Governance doc copied to the installer bundle. GitHub push queued for session end."
      fi
    fi
    exit 0
    ;;
  */.claude/CLAUDE.md)
    # RENDERED, not copied (see _gov_render_claude_md above). Only the HOME file: a
    # `.claude/CLAUDE.md` inside any project checkout is that PROJECT's instruction file and
    # publishing it would be a straight data leak - the same trap the docs branch below
    # guards against, and the reason that guard is repeated here rather than assumed.
    if ! gov_same_file "$FILE_PATH" "$GOV_CLAUDE_MD"; then
      echo "[GOVERNANCE-SYNC] $FILE_PATH is a PROJECT CLAUDE.md, not the user-level file at $GOV_CLAUDE_MD - nothing synced, nothing queued for GitHub."
      gov_log "sync-copies" "project-scoped CLAUDE.md refused at the private->public crossing: $FILE_PATH"
      exit 0
    fi
    if gov_dry; then echo "[GOVERNANCE DRY-RUN] sync-copies: would render $GOV_CLAUDE_MD -> $GOV_TEMPLATE_DEST"; exit 0; fi
    _CMD_TMP="$HOME/.claude/logs/.gov-claude-template.$$"
    mkdir -p "$(dirname "$_CMD_TMP")" 2>/dev/null
    _gov_render_claude_md "$_CMD_TMP"; _rr=$?
    case "$_rr" in
      4)
        # FAIL CLOSED AND SAY WHICH LINE TO ADD. A CLAUDE.md with no marker is treated as
        # 100% local: publishing "everything" from a file whose local part is unmarked is
        # exactly the leak this design exists to prevent.
        rm -f "$_CMD_TMP" 2>/dev/null
        echo "[GOVERNANCE-SYNC] CLAUDE.md has NO local-only marker, so NOTHING was published from it." >&2
        echo "  Add this line immediately above the last (personal) section:" >&2
        echo "    <!-- $GOV_CLAUDE_LOCAL_MARKER: nothing below this line is synced or published -->" >&2
        echo "  Everything ABOVE it is published verbatim into bundle/CLAUDE.md.template; everything below stays on this machine." >&2
        gov_log "sync-copies" "CLAUDE.md render refused: marker '$GOV_CLAUDE_LOCAL_MARKER' not found"
        exit 0
        ;;
      5)
        rm -f "$_CMD_TMP" 2>/dev/null
        echo "[GOVERNANCE-SYNC] bundle/CLAUDE.md.template.head is MISSING at $GOV_TEMPLATE_HEAD - the template cannot be rendered, so nothing was published." >&2
        gov_log "sync-copies" "CLAUDE.md render refused: head file missing at $GOV_TEMPLATE_HEAD"
        exit 0
        ;;
      0) : ;;
      *)
        rm -f "$_CMD_TMP" 2>/dev/null
        gov_log "sync-copies" "CLAUDE.md render failed (rc=$_rr)"
        exit 0
        ;;
    esac
    # The GATE SCANS THE RENDERED FILE, which is the whole point: a name that drifts ABOVE
    # the marker refuses this copy and is reported, instead of reaching the public repo.
    _bundle_copy "$_CMD_TMP" "$GOV_TEMPLATE_DEST" "CLAUDE.md.template (rendered)"; _rc=$?
    rm -f "$_CMD_TMP" 2>/dev/null
    if [ "$_rc" -eq 0 ]; then
      echo "$(date +%Y-%m-%dT%H:%M:%S%z) bundle/CLAUDE.md.template" >> "$FLAG_FILE" 2>/dev/null
      gov_log "sync-copies" "CLAUDE.md rendered into bundle/CLAUDE.md.template (cut at the local-only marker)"
      echo "[GOVERNANCE-SYNC] CLAUDE.md rendered into the installer bundle (content above the local-only marker only). GitHub push queued for session end."
    fi
    exit 0
    ;;
  */.claude/agents/*.md)
    # ALLOW-LISTED raw copy. No marker mechanism: an agent definition is either fully generic
    # or it does not ship (owner-specific text belongs below the marker in CLAUDE.md, and the
    # agent refers to "the owner's standing policy in CLAUDE.md" instead - which is how both
    # shipped definitions are already phrased).
    #
    # Mirrors get NOTHING. Agents are user-level, and a project-level .claude/agents/<x> would
    # SHADOW the user-level definition for every session opened in that project - the exact
    # failure that made "MIRROR, NEVER RESURRECT" the rule for skills on 2026-08-17.
    AGENT_REL=$(echo "$FILE_PATH" | sed "s|.*/.claude/agents/||")
    AGENT_NAME="${AGENT_REL%.md}"
    if ! gov_same_file "$FILE_PATH" "$HOME/.claude/agents/$AGENT_REL"; then
      echo "[GOVERNANCE-SYNC] $FILE_PATH is a PROJECT-level agent, not the user-level one at ~/.claude/agents/$AGENT_REL - nothing synced."
      gov_log "sync-copies" "project-scoped agent refused at the private->public crossing: $FILE_PATH"
      exit 0
    fi
    if ! _gov_is_distributed agents "$AGENT_NAME"; then
      echo "[GOVERNANCE-SYNC] agent '$AGENT_NAME' is not listed under [agents] in bundle/DISTRIBUTED - NOT copied into the public bundle. Local copy untouched."
      gov_log "sync-copies" "agent '$AGENT_NAME' not allow-listed - crossing refused"
      exit 0
    fi
    if [ -f "$FILE_PATH" ]; then
      if gov_dry; then echo "[GOVERNANCE DRY-RUN] sync-copies: would copy $FILE_PATH -> bundle/agents/$AGENT_REL"; exit 0; fi
      _bundle_copy "$FILE_PATH" "$HOME/.claude/governance-installer/bundle/agents/$AGENT_REL" "agents/$AGENT_REL"; _rc=$?
      if [ "$_rc" -eq 0 ]; then
        echo "$(date +%Y-%m-%dT%H:%M:%S%z) $FILE_PATH" >> "$FLAG_FILE" 2>/dev/null
        gov_log "sync-copies" "agent synced to installer bundle: $AGENT_REL"
        echo "[GOVERNANCE-SYNC] Agent definition copied to the installer bundle. GitHub push queued for session end."
      fi
    fi
    exit 0
    ;;
  */.claude/hooks/*)
    # ROOT-LEVEL hooks only (depth 1) - hooks/governance/** is matched by the branch above and
    # ships whole. This directory was UNWATCHED until 1.7.0, which is why a hook carrying a
    # real container name sat in the public bundle while a clean copy existed locally: nothing
    # compared them because nothing synced them.
    #
    # Allow-listed, because the live hooks/ root is mostly machine-local: the WhatsApp-bridge
    # family and client-named tooling live here. Unlisted files exit quietly with a log line,
    # exactly as a never-distributed skill does.
    ROOTHOOK_REL=$(echo "$FILE_PATH" | sed "s|.*/.claude/hooks/||")
    case "$ROOTHOOK_REL" in
      */*)
        # A subdirectory of hooks/ that is not hooks/governance/. Never distributed.
        gov_log "sync-copies" "hooks/ subdirectory is not a distributable surface: $ROOTHOOK_REL"
        exit 0
        ;;
    esac
    if ! gov_same_file "$FILE_PATH" "$HOME/.claude/hooks/$ROOTHOOK_REL"; then
      gov_log "sync-copies" "project-scoped root hook refused at the private->public crossing: $FILE_PATH"
      exit 0
    fi
    if ! _gov_is_distributed hooks "$ROOTHOOK_REL"; then
      echo "[GOVERNANCE-SYNC] root hook '$ROOTHOOK_REL' is not listed under [hooks] in bundle/DISTRIBUTED - NOT copied into the public bundle. Local copy untouched."
      gov_log "sync-copies" "root hook '$ROOTHOOK_REL' not allow-listed - crossing refused"
      exit 0
    fi
    if [ -f "$FILE_PATH" ]; then
      if gov_dry; then echo "[GOVERNANCE DRY-RUN] sync-copies: would copy $FILE_PATH -> bundle/hooks/$ROOTHOOK_REL"; exit 0; fi
      _bundle_copy "$FILE_PATH" "$HOME/.claude/governance-installer/bundle/hooks/$ROOTHOOK_REL" "hooks/$ROOTHOOK_REL"; _rc=$?
      if [ "$_rc" -eq 0 ]; then
        echo "$(date +%Y-%m-%dT%H:%M:%S%z) $FILE_PATH" >> "$FLAG_FILE" 2>/dev/null
        gov_log "sync-copies" "root hook synced to installer bundle: $ROOTHOOK_REL"
        echo "[GOVERNANCE-SYNC] Root hook copied to the installer bundle. GitHub push queued for session end."
      fi
    fi
    exit 0
    ;;
  */.claude/skills/*)
    IS_SKILL=1
    # Extract skill name and relative path: ~/.claude/skills/<name>/SKILL.md -> <name>/SKILL.md
    SKILL_REL_PATH=$(echo "$FILE_PATH" | sed "s|.*/.claude/skills/||")
    SKILL_NAME=$(echo "$SKILL_REL_PATH" | cut -d'/' -f1)
    ;;
  *)
    # Not a governance file — exit silently
    exit 0
    ;;
esac

CHANGES=0
FLAG_FILE="$HOME/.claude/logs/.governance-push-pending"

# Machine-local list of checkout roots that carry a mirror of the framework. One absolute path per
# line; '#' comments and blank lines ignored. Missing file -> no repo mirrors (correct default).
MIRRORS_FILE="${GOV_MIRRORS_FILE:-$HOME/.claude/.governance-mirrors}"
gov_mirror_roots() {
  [ -f "$MIRRORS_FILE" ] || return 0
  sed -e 's/#.*$//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$MIRRORS_FILE" 2>/dev/null | grep -v '^$'
}

# --- Sync hooks to all locations ---
if [ $IS_HOOK -eq 1 ] && [ -n "$BASENAME" ]; then
  SOURCE="$HOOK_DIR/$BASENAME"
  if [ ! -f "$SOURCE" ]; then
    exit 0
  fi

  # Targets: every configured mirror root. MIRROR, NEVER RESURRECT - only refresh a mirror that
  # already exists (see the skills section below for the full reasoning).
  while IFS= read -r _root; do
    [ -n "$_root" ] || continue
    if [ -d "$_root/.claude/hooks/governance" ]; then
      _t="$_root/.claude/hooks/governance/$BASENAME"
      if ! diff -q "$SOURCE" "$_t" &>/dev/null; then
        _mirror_allowed "$SOURCE" "$_t" "hooks/governance/$BASENAME" || continue
        cp "$SOURCE" "$_t" && CHANGES=$((CHANGES + 1))
      fi
    fi
  done <<EOF
$(gov_mirror_roots)
EOF

  # Target 3: Installer bundle - THIS IS THE PRIVATE->PUBLIC CROSSING. Gated (see above).
  if [ -d "$INSTALLER_HOOKS" ]; then
    TARGET3="$INSTALLER_HOOKS/$BASENAME"
    _bundle_copy "$SOURCE" "$TARGET3" "hooks/governance/$BASENAME" && CHANGES=$((CHANGES + 1))
  fi
fi

# --- Sync skills to all locations ---
if [ $IS_SKILL -eq 1 ] && [ -n "$SKILL_REL_PATH" ]; then
  SOURCE="$SKILL_DIR/$SKILL_REL_PATH"
  if [ ! -f "$SOURCE" ]; then
    exit 0
  fi

  # MIRROR, NEVER RESURRECT (2026-08-17). These two used to `mkdir -p` the destination
  # unconditionally, so editing ANY user-level skill re-created that skill inside both repos - and
  # on 2026-08-17 three such shadow copies (`wa-cc-bridge`, `whatsapp`, `wa-cc-poll`) were
  # deliberately deleted from them, because a project-level `.claude/skills/<x>` SHADOWS the
  # user-level copy for every session opened in that project, and two of the three had already
  # drifted away from the original. Wiring this hook up with the old behaviour would have quietly
  # rebuilt all three on the next skill edit. Only refresh a mirror that already exists.
  #
  # The gate is the SKILL's own directory, not the `skills/` root: an existing root would otherwise
  # let a brand-new shadow copy of any other skill appear.

  # Targets: every configured mirror root (see ~/.claude/.governance-mirrors).
  while IFS= read -r _root; do
    [ -n "$_root" ] || continue
    if [ -d "$_root/.claude/skills/$SKILL_NAME" ]; then
      _t="$_root/.claude/skills/$SKILL_REL_PATH"
      mkdir -p "$(dirname "$_t")" 2>/dev/null
      if ! diff -q "$SOURCE" "$_t" &>/dev/null; then
        _mirror_allowed "$SOURCE" "$_t" "skills/$SKILL_REL_PATH" || continue
        cp "$SOURCE" "$_t" && CHANGES=$((CHANGES + 1))
      fi
    fi
  done <<EOF
$(gov_mirror_roots)
EOF

  # NEVER-DISTRIBUTED skills. These are machine- and deployment-specific tooling (WhatsApp bridge
  # internals, a retired skill): they carry group names, server addresses, operator phones and
  # client names, and `install.sh` does not install ANY of them - CORE_SKILLS/EXTENDED_SKILLS omit
  # them entirely, so nobody who installs the framework ever received them. They were nonetheless
  # copied into the public bundle on every edit, which is the pipe that leaked a real WhatsApp
  # group name into the published repo (2026-09-07). Deleting them from the bundle is NOT enough:
  # _bundle_copy does `mkdir -p "$(dirname "$dest")"`, so the very next edit recreates the path.
  # The block has to be here, at the crossing.
  case " ${GOV_NEVER_DISTRIBUTE_SKILLS:-wa-cc-bridge wa-cc-poll whatsapp whatsapp-checkpoints end-session} " in
    *" $SKILL_NAME "*)
      echo "[GOVERNANCE-SYNC] '$SKILL_NAME' is a never-distributed skill - NOT copied into the public bundle. Local copies are untouched."
      gov_log "sync-copies" "skill '$SKILL_NAME' blocked at the private->public crossing (never-distributed list)"
      exit 0
      ;;
  esac

  # ── AND the skill must be ALLOW-LISTED (1.7.0). The denylist above is now a BELT, not the
  # mechanism. It only ever named the skills somebody had already thought of. MEASURED
  # 2026-09-18: the live tree held SEVEN more distributable-by-default skill paths - remote-host
  # tooling named after a real client, three project-specific rebuild/revert skills, a
  # third-party skill, a `synced/` subtree and a stray top-level `skills/*.md` file. Every one
  # was one Edit-tool save away from entering a PUBLIC bundle, none was on any denylist, and
  # none is installed by install.sh. "Protected by accident" is not protected. (The names are
  # deliberately not written here: this file ships in the public bundle, and one of them is a
  # client organisation - the PII gate blocked an earlier draft of this very comment.)
  #
  # A name that is BOTH allow-listed AND denied is refused by the block above and is a bug to
  # be SEEN - the contradiction is deliberately not resolved by a precedence rule.
  if ! _gov_is_distributed core "$SKILL_NAME" && ! _gov_is_distributed extended "$SKILL_NAME"; then
    echo "[GOVERNANCE-SYNC] skill '$SKILL_NAME' is not listed in bundle/DISTRIBUTED ([core] or [extended]) - NOT copied into the public bundle. Local copies are untouched."
    gov_log "sync-copies" "skill '$SKILL_NAME' not allow-listed in bundle/DISTRIBUTED - crossing refused"
    exit 0
  fi

  # Target 3: Installer bundle - THIS IS THE PRIVATE->PUBLIC CROSSING. Gated (see above).
  if [ -d "$INSTALLER_SKILLS" ]; then
    TARGET3="$INSTALLER_SKILLS/$SKILL_REL_PATH"
    _bundle_copy "$SOURCE" "$TARGET3" "skills/$SKILL_REL_PATH" && CHANGES=$((CHANGES + 1))
  fi
fi

# --- Set push-pending flag if anything changed ---
if [ $CHANGES -gt 0 ]; then
  echo "$(date -Iseconds) $FILE_PATH" >> "$FLAG_FILE"
  gov_log "sync-copies" "Synced $BASENAME to $CHANGES location(s). Push pending."
  echo "[GOVERNANCE-SYNC] Auto-copied governance file to $CHANGES additional location(s). GitHub push queued for session end."
fi
# Say it plainly when the one copy that did NOT happen is the publishable one: a summary that
# reads like a clean sync while the bundle was refused is how a divergence becomes invisible.
if [ "$REFUSED_BUNDLE" -gt 0 ]; then
  echo "[GOVERNANCE-SYNC] NOT queued for GitHub: the installer-bundle copy was REFUSED by the PII gate (see above). The bundle is now BEHIND this file."
fi

exit 0
