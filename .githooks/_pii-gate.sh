#!/usr/bin/env bash
# ============================================================================
# _pii-gate.sh — shared body of the pre-commit / pre-push PII gates.
#
# WHY THIS EXISTS
#   This repository is PUBLIC. Every tracked file in it is meant to carry a
#   placeholder or an env lookup; the real value lives in a machine-local,
#   gitignored config (README "Placeholder convention"). .gitignore stops the
#   whole secrets FILE from being staged. This gate is the other half: it stops
#   a real value that leaked INTO a tracked file.
#
#   It scans the content git is actually about to record — the staged blob for
#   pre-commit, the pushed tip for pre-push — not the working tree. A gate that
#   reads the working tree passes a `git add`-then-edit sequence it should fail.
#
# CADENCE (measured on this machine, Git Bash / Windows, 2026-09-01)
#   Measured, not guessed: 1 file 13.5 s / 3 files 31.9 s / 6 files 13.9 s.
#   The spread is startup and filesystem warmth, not file count — process spawn
#   on Windows dominates, so a typical commit costs ~15-35 s whether it touches
#   one file or six. --selftest costs ~80 s.
#   The gate therefore scans ONLY the files in this commit/push, never the tree:
#   a tree-wide scan at the commit boundary would be switched off within a week,
#   and a control that gets switched off is how controls die.
#
# FAILURE POLICY (deliberate, asymmetric)
#   scanner absent .......... BLOCK, loudly, naming every path it looked for.
#                             A gate that cannot find its scanner and shrugs is
#                             precisely the failure this framework shipped with.
#   scanner says exit 2 ..... BLOCK. Contamination found.
#   scanner says exit 0 ..... allow.
#   scanner errors/times out  WARN LOUDLY and ALLOW. That is the gate itself
#                             being broken, not evidence about the content, and
#                             a broken gate must not block all work.
#
# KILL SWITCHES (both documented in README.md)
#   GOV_GIT_PII_GATE=0 git commit ...   skip this gate, with a printed notice
#   git commit --no-verify              skip every hook (git's own)
#
# TUNABLES
#   GOV_PII_SCANNER   explicit path to check-no-pii.sh (wins over discovery)
#   GOV_PII_TIMEOUT   seconds for the whole scan (default 300)
#   GOV_PII_MAX_FILES advisory cap; above it the gate warns about the wait and
#                     then scans everything anyway. It NEVER truncates a scan —
#                     a partial scan reported as a pass is a lie.
# ============================================================================
set -uo pipefail

GATE_PHASE="${GATE_PHASE:-pii-gate}"
GATE_NOUN="${GATE_PHASE#pre-}"
PII_TIMEOUT="${GOV_PII_TIMEOUT:-300}"
PII_MAX_FILES="${GOV_PII_MAX_FILES:-40}"

g_say()  { printf '%s: %s\n'  "$GATE_PHASE" "$1" >&2; }
g_warn() { printf '%s: [WARN] %s\n' "$GATE_PHASE" "$1" >&2; }
g_die()  { printf '%s: [BLOCKED] %s\n' "$GATE_PHASE" "$1" >&2; }

# --- kill switch -----------------------------------------------------------
# Never silent. "the gate did not run" has to be readable in the output, or a
# machine with the switch left on looks exactly like a machine that is protected.
gate_disabled() {
  if [ "${GOV_GIT_PII_GATE:-1}" = "0" ]; then
    g_warn "DISABLED via GOV_GIT_PII_GATE=0 — nothing was scanned for PII."
    return 0
  fi
  return 1
}

# --- scanner discovery -----------------------------------------------------
# Order matters: the live installed hook first (it is the one that gets fixes),
# then the copy this repo ships, so a fresh clone on a machine that has never
# run install.sh is still gated.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCANNER=""
SCANNER_SRC=""
resolve_scanner() {
  tried=""
  for c in \
    "${GOV_PII_SCANNER:-}" \
    "$HOME/.claude/hooks/governance/check-no-pii.sh" \
    "$REPO_ROOT/bundle/hooks/governance/check-no-pii.sh"
  do
    [ -n "$c" ] || continue
    tried="$tried
      $c"
    if [ -f "$c" ]; then SCANNER="$c"; SCANNER_SRC="$c"; return 0; fi
  done
  g_die "cannot find check-no-pii.sh. Looked for:$tried"
  g_die "This repo is public and the PII gate is the only thing standing between"
  g_die "a real phone number / path / token and a public commit. Refusing to guess."
  g_die "Fix: install the framework (bash install.sh), or point at it directly:"
  g_die "     GOV_PII_SCANNER=/path/to/check-no-pii.sh git $GATE_NOUN ..."
  g_die "Override the gate (you own the consequences): GOV_GIT_PII_GATE=0 git $GATE_NOUN ..."
  return 1
}

# --- materialise the content git will actually record ----------------------
# $1 = "index" (staged blobs) | a commit-ish (that tree's blobs)
# stdin = newline list of repo-relative paths
# Mirrors the relative path under a temp dir so the scanner's basename-based
# skips (*.png, .governance-local.env, ...) behave identically to a real tree.
#
# Sets the GLOBALS  STAGE_DIR  and  STAGED_N. It must NOT be called through a
# pipeline or a command substitution: both run it in a subshell, the caller
# gets STAGE_DIR="" back, and — because `cd ""` SUCCEEDS in bash rather than
# failing — the scan then silently walks the repo root instead of the mirror.
# That exact bug shipped in the first draft of this file and was caught only
# because the scan hung: it was scanning every file in the repository.
STAGE_DIR=""
STAGED_N=0
MKTEMP_FAILED=0
materialise() {
  src="$1"; STAGED_N=0; MKTEMP_FAILED=0
  STAGE_DIR="$(mktemp -d 2>/dev/null)"
  if [ -z "$STAGE_DIR" ] || [ ! -d "$STAGE_DIR" ]; then
    STAGE_DIR=""; MKTEMP_FAILED=1; return 0
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "$src" = "index" ]; then spec=":$p"; else spec="$src:$p"; fi
    mkdir -p "$STAGE_DIR/$(dirname "$p")" 2>/dev/null || continue
    # A path listed in the range but absent from this tree (deleted, or a rename
    # source) simply has nothing to scan. Skip it; it is not an error.
    if git show "$spec" > "$STAGE_DIR/$p" 2>/dev/null; then
      STAGED_N=$((STAGED_N+1))
    else
      rm -f "$STAGE_DIR/$p" 2>/dev/null
    fi
  done
  return 0
}

cleanup_stage() { [ -n "$STAGE_DIR" ] && rm -rf "$STAGE_DIR" 2>/dev/null; return 0; }

# --- run the scan ----------------------------------------------------------
# $1 = "index" | commit-ish ; stdin = path list. Returns 0 allow / 1 block.
run_gate() {
  src="$1"
  files="$(cat)"
  files="$(printf '%s\n' "$files" | sed '/^[[:space:]]*$/d')"
  if [ -z "$files" ]; then
    g_say "no added/modified files in this $GATE_NOUN — nothing to scan."
    return 0
  fi

  resolve_scanner || return 1

  count="$(printf '%s\n' "$files" | wc -l | tr -d ' ')"
  if [ "$count" -gt "$PII_MAX_FILES" ]; then
    g_warn "$count files to scan — this will take several minutes (~15-35 s per batch, and it grows)."
    g_warn "Nothing is skipped: a truncated scan reported as a pass is worse than no scan."
    g_warn "Raise the wait budget with GOV_PII_TIMEOUT=<seconds> if it trips the timeout."
  fi

  # Deliberately NOT a pipeline and NOT a command substitution — see materialise().
  LIST="$(mktemp 2>/dev/null)"
  if [ -z "$LIST" ]; then
    g_warn "mktemp failed — could not stage the content, so nothing was scanned."
    g_warn "ALLOWING this $GATE_NOUN: a broken gate must not block all work."
    g_warn "Run it yourself before you publish: bash $SCANNER_SRC --tree ."
    return 0
  fi
  printf '%s\n' "$files" > "$LIST"
  materialise "$src" < "$LIST"
  rm -f "$LIST" 2>/dev/null

  if [ "$MKTEMP_FAILED" = "1" ]; then
    g_warn "mktemp failed — could not stage the content, so nothing was scanned."
    g_warn "ALLOWING this $GATE_NOUN: a broken gate must not block all work."
    g_warn "Run it yourself before you publish: bash $SCANNER_SRC --tree ."
    return 0
  fi
  if [ "$STAGED_N" = "0" ]; then
    cleanup_stage
    g_say "nothing scannable in this $GATE_NOUN (deletions only?) — allowed."
    return 0
  fi
  # Belt to the brace above: `cd ""` succeeds, so an empty STAGE_DIR would scan
  # the whole repository from wherever git happened to leave us. Refuse instead.
  if [ -z "$STAGE_DIR" ] || [ ! -d "$STAGE_DIR" ]; then
    g_warn "the staging mirror vanished — nothing was scanned."
    g_warn "ALLOWING this $GATE_NOUN: a broken gate must not block all work."
    return 0
  fi

  g_say "scanning $STAGED_N file(s) with $SCANNER_SRC (typically 15-35 s)..."
  out="$(cd "$STAGE_DIR" && timeout "$PII_TIMEOUT" bash "$SCANNER" --tree . 2>&1)"
  rc=$?
  # Report the real repo path, not the scratch mirror.
  out="$(printf '%s\n' "$out" | sed -e "s#$STAGE_DIR/\{0,1\}##g" -e 's#^\./##')"
  cleanup_stage

  case "$rc" in
    0)
      printf '%s\n' "$out" | tail -3 >&2
      g_say "PASS — no PII in the content being recorded."
      return 0 ;;
    2)
      printf '%s\n' "$out" >&2
      echo >&2
      g_die "a file in this $GATE_NOUN carries a REAL value, and this repo is public."
      g_die "Fix the DATA, not the scanner: move the real value to ~/.claude/.governance-local.env"
      g_die "and leave a placeholder or an env lookup in the tracked file."
      g_die "One deliberate exception: put  pii-allow: <reason>  in a comment on that line."
      g_die "Override the gate (you own the consequences): GOV_GIT_PII_GATE=0 git $GATE_NOUN ..."
      return 1 ;;
    124)
      g_warn "the scan hit the ${PII_TIMEOUT}s timeout and did NOT finish."
      g_warn "ALLOWING this $GATE_NOUN: an unfinished scan is the gate failing, not evidence."
      g_warn "Please run it yourself before you publish: bash $SCANNER_SRC --tree ."
      g_warn "Or raise the budget: GOV_PII_TIMEOUT=900 git $GATE_NOUN ..."
      return 0 ;;
    *)
      printf '%s\n' "$out" | tail -10 >&2
      g_warn "the scanner exited $rc — that is neither clean (0) nor contaminated (2)."
      g_warn "ALLOWING this $GATE_NOUN: a broken gate must not block all work."
      g_warn "But the content was NOT checked. Run: bash $SCANNER_SRC --tree . and fix the scanner."
      return 0 ;;
  esac
}
