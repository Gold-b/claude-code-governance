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

# --- Read tool result from stdin (JSON with file_path) ---
INPUT=$(gov_hook_input)
if [ -z "$INPUT" ]; then
  exit 0
fi

# Extract file_path from JSON. Claude Code PostToolUse schema is:
#   {"tool_input":{"file_path":"..."}, "tool_name":"Edit", "cwd":"..."}
# Older format had file_path at top-level. Handle both.
FILE_PATH=""
if command -v python3 &>/dev/null; then
  FILE_PATH=$(echo "$INPUT" | python3 -c "
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
  exit 0
fi

# --- Normalize path (Windows backslash -> forward slash) ---
FILE_PATH=$(echo "$FILE_PATH" | tr '\\' '/')

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
#   mirror roots     -> NOT by default. A mirror listed in ~/.claude/.governance-mirrors is a
#                       machine-local checkout of a PRIVATE repo; refusing those copies would
#                       manufacture local drift while protecting nothing public. The verdict is
#                       already computed by then, so opting in is free: GOV_PII_GATE_MIRRORS=1.
#                       If a PUBLIC checkout is ever listed there, that is the switch to flip.
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
#                GOV_PII_GATE_MIRRORS=1 (extend it to mirror roots)
# ---------------------------------------------------------------------------
# Overridable so the gate can be exercised against a stub in a test, and so an installer
# that relocates the scanner does not silently turn the gate into a no-op.
PII_SCANNER="${GOV_PII_SCANNER:-$SCRIPT_DIR/check-no-pii.sh}"
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
  if [ $# -eq 1 ]; then _PII_MEMO_F="$1"; _PII_MEMO_RC="$rc"; fi
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

# Same verdict, applied to a machine-local mirror root. Off unless GOV_PII_GATE_MIRRORS=1.
# Returns 0 when the copy may proceed.
_mirror_allowed() {
  local src="$1" dest="$2" label="$3" rc
  [ "${GOV_PII_GATE_MIRRORS:-0}" = "1" ] || return 0
  gov_pii_gate_off && return 0
  _pii_scan "$src"; rc=$?
  [ "$rc" -eq 0 ] && return 0
  _pii_refuse "$src" "$dest" "mirror:$label" "$rc"
  return 1
}

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
