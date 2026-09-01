#!/usr/bin/env bash
# canonical-cwd-check.sh — Context Governance guard (SessionStart helper)
#
# Purpose: catch the "wrong copy of the repo" failure mode — a session opened on
# a STALE duplicate of a governed project (e.g. an abandoned OneDrive clone) while
# the real work lives elsewhere. Governance-lite only checks that canonical files
# EXIST and that one handoff is active; it has no notion of WHERE the repo should
# live, so it passes happily on a zombie copy. This guard adds that invariant.
#
# Two independent signals (covers both directions, because a stale copy's own
# CONTEXT-MANIFEST predates the relocation and lacks the canonical field):
#   1. A `_STALE_DO_NOT_USE.md` tombstone in the project root  -> STOP, redirect.
#   2. CONTEXT-MANIFEST `canonical_working_copy:` != current root -> STOP, redirect.
#
# Fail-soft: prints an advisory to stdout (which the SessionStart hook injects into
# context) and ALWAYS exits 0. Never blocks a session. Generic across all governed
# projects. Kill switch: GOVERNANCE_HOOKS=0.
set +e
[ "${GOVERNANCE_HOOKS:-1}" = "0" ] && exit 0

# Normalize a Windows/POSIX path for comparison: lowercase, backslashes->slashes,
# strip surrounding quotes/space, drop the drive colon, strip trailing slashes.
_norm() {
  printf '%s' "$1" \
    | tr 'A-Z' 'a-z' \
    | tr '\\' '/' \
    | sed -e "s/^[[:space:]'\"]*//" -e "s/[[:space:]'\"]*$//" -e 's#:##g' -e 's#/*$##'
}

# Strip markdown emphasis, surrounding whitespace/quotes/backticks and trailing
# sentence punctuation from an extracted path. Tombstones and manifests write
# paths inside prose ("...is retired, use C:\Foo."), so the raw regex match
# routinely carries a trailing , . ; : ) that is NOT part of the path.
_clean_path() {
  printf '%s' "$1" \
    | sed -e 's/\*\*//g' \
          -e "s/^[[:space:]\`'\"]*//" -e "s/[[:space:]\`'\"]*$//" \
          -e 's/[,.;:)]*$//'
}

# Match a `canonical_working_copy` declaration in ANY of the shapes projects
# actually write it in. Historically this only accepted a bare
# "canonical_working_copy:" at line start, which silently matched NOTHING on a
# manifest that writes the fact as a markdown bullet:
#   - **canonical_working_copy = `C:\dev\example-project`**
# Signals 2 and 3 were therefore dead on such projects. Accept an optional list
# marker (-/*/+), optional ** emphasis, and either ':' or '=' as the separator.
_canon_line() {
  grep -iE '^[[:space:]]*([-*+][[:space:]]+)?(\*\*)?[[:space:]]*canonical_working_copy[[:space:]]*(\*\*)?[[:space:]]*[:=]' \
    "$1" 2>/dev/null | head -1
}

# Extract the path out of such a line. NEVER `cut -d: -f2-` — that splits on the
# DRIVE colon and truncates "C:\dev\example-project" to "\example-project". Prefer a
# backticked path, then a quoted one, and only then fall back to "everything
# after the first : or =" (safe, because the key name always precedes it).
_canon_path() {
  local _l="$1" _p=""
  _p="$(printf '%s' "$_l" | grep -oE '`[^`]+`' | head -1)"
  [ -z "$_p" ] && _p="$(printf '%s' "$_l" | grep -oE '"[^"]+"' | head -1)"
  [ -z "$_p" ] && _p="$(printf '%s' "$_l" | sed -E 's/^[^:=]*[:=][[:space:]]*//')"
  _clean_path "$_p"
}

# THE SESSION'S DIRECTORY COMES FROM THE PAYLOAD, NOT FROM `pwd` (2026-08-17).
# This guard asks "is the session sitting on the canonical copy?", so it must read the SESSION's
# directory. A hook process's `pwd` is not reliably that - it was proven on 2026-08-17 that hooks
# can run with a wandering working directory, which is how post-milestone.sh silently discarded a
# whole session's change log. Here the same drift is worse than a lost record: comparing the wrong
# directory against `canonical_working_copy` either raises a false "WRONG WORKING COPY" alarm or,
# far worse, stays silent while the session really is on a stale duplicate - the exact failure this
# guard exists to catch, and one that has already cost this toolchain a corrupted .git once.
#
# Extracted inline rather than via `_common.sh`: this hook is deliberately standalone (kill switch
# only, no sourcing) so that it still works when the rest of the framework does not.
_payload=""
if [ ! -t 0 ]; then _payload="$(timeout 3 head -c 262144 2>/dev/null || true)"; fi
_payload_cwd="$(printf '%s' "$_payload" | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//')"
# JSON escapes backslashes; turn '\\' back into a single separator before use.
_payload_cwd="$(printf '%s' "$_payload_cwd" | sed 's#\\\\#\\#g')"

if [ -n "$_payload_cwd" ]; then
  ROOT_WIN="$_payload_cwd"
  ROOT_DIR="$(printf '%s' "$_payload_cwd" | tr '\\' '/')"
else
  ROOT_WIN="$(pwd -W 2>/dev/null || pwd)"
  ROOT_DIR="."
fi
ROOT_NORM="$(_norm "$ROOT_WIN")"

# --- Signal 1: tombstone marker in the project root ---
if [ -f "$ROOT_DIR/_STALE_DO_NOT_USE.md" ]; then
  # Pick the REDIRECT TARGET, not just "the first path in the file".
  # A tombstone written the normal way names the condemned folder FIRST
  # ("this folder, C:\Stale, is retired; use C:\Canonical instead"), so a bare
  # `head -1` pointed the session straight back at the folder it had just
  # condemned — reproduced verbatim in a sandbox on 2026-08-31. Selection order:
  #   1. a path on a line that labels itself SOURCE / canonical / "edit here";
  #   2. otherwise the first path that is NOT this root (normalized comparison);
  #   3. otherwise nothing — say so honestly rather than print a wrong path.
  _TOMB="$ROOT_DIR/_STALE_DO_NOT_USE.md"
  _PATH_RE='[A-Za-z]:[\\/][^[:space:]`*"'"'"']+'
  TARGET=""
  _LABELLED="$(grep -iE 'source|canonical|edit here|use instead|instead use|moved to|replaced by|live (copy|install)' "$_TOMB" 2>/dev/null | grep -oiE "$_PATH_RE")"
  _ALLPATHS="$(grep -oiE "$_PATH_RE" "$_TOMB" 2>/dev/null)"
  for _LIST in "$_LABELLED" "$_ALLPATHS"; do
    [ -n "$TARGET" ] && break
    [ -z "$_LIST" ] && continue
    while IFS= read -r _CAND; do
      _CAND="$(_clean_path "$_CAND")"
      [ -z "$_CAND" ] && continue
      if [ "$(_norm "$_CAND")" != "$ROOT_NORM" ]; then TARGET="$_CAND"; break; fi
    done <<< "$_LIST"
  done

  if [ -n "$TARGET" ]; then
    echo "[CANONICAL-CWD-CHECK] 🛑 STOP — this folder is a STALE/abandoned copy (found _STALE_DO_NOT_USE.md). Do NOT edit anything here. Switch your working directory to the canonical copy: $TARGET and read its docs/context/CONTEXT-MANIFEST.md before any action."
  else
    echo "[CANONICAL-CWD-CHECK] 🛑 STOP — this folder is a STALE/abandoned copy (found _STALE_DO_NOT_USE.md). Do NOT edit anything here. The tombstone does not name a usable canonical path (the only path it names is this folder) — do NOT guess: ask the user where the canonical working copy is before any action."
  fi
  exit 0
fi

# --- Signal 2: manifest canonical_working_copy vs current root ---
MANIFEST="$ROOT_DIR/docs/context/CONTEXT-MANIFEST.md"
if [ -f "$MANIFEST" ]; then
  CANON_RAW="$(_canon_path "$(_canon_line "$MANIFEST")")"
  if [ -n "$CANON_RAW" ]; then
    CANON_NORM="$(_norm "$CANON_RAW")"
    if [ -n "$CANON_NORM" ] && [ "$CANON_NORM" != "$ROOT_NORM" ]; then
      CANON_SHOW="$CANON_RAW"
      echo "[CANONICAL-CWD-CHECK] ⚠️ WRONG WORKING COPY — the manifest declares the canonical working copy as '$CANON_SHOW' but this session is in '$ROOT_WIN'. STOP, switch to the canonical copy, and do not edit files here. (See GOTCHAS #11.)"
    fi
  fi
fi

# --- Signal 3: cross-file canonical-fact consistency (manifest vs CLAUDE.md banner) ---
# Catches the original H:\ root cause: a canonical fact (the working-copy path) recorded in
# ONE always-read file but not propagated to the other. Advisory only.
if [ -f "$MANIFEST" ] && [ -f "$ROOT_DIR/CLAUDE.md" ]; then
  C3_RAW="$(_canon_path "$(_canon_line "$MANIFEST")")"
  if [ -n "$C3_RAW" ]; then
    C3_NORM="$(_norm "$C3_RAW")"
    # All drive paths mentioned in the CLAUDE.md "Canonical Working Copy" banner window.
    # Membership test (not first-match): consistent if the manifest path appears among them —
    # robust even if a banner also lists an OLD/stale path before the canonical one.
    BANNER_PATHS="$(grep -iE -A4 'canonical working copy' "$ROOT_DIR/CLAUDE.md" 2>/dev/null | grep -oiE '[A-Za-z]:[\\/][^[:space:]`*]+')"
    if [ -n "$BANNER_PATHS" ] && [ -n "$C3_NORM" ]; then
      C3_MATCH=0
      while IFS= read -r _bp; do
        [ -n "$_bp" ] && [ "$(_norm "$_bp")" = "$C3_NORM" ] && { C3_MATCH=1; break; }
      done <<< "$BANNER_PATHS"
      if [ "$C3_MATCH" -eq 0 ]; then
        C3_SHOW="$C3_RAW"
        C3_FIRST="$(printf '%s' "$BANNER_PATHS" | head -1)"
        echo "[CANONICAL-CWD-CHECK] ⚠️ INCONSISTENT CANONICAL FACT — CONTEXT-MANIFEST canonical_working_copy ('$C3_SHOW') is not among the path(s) in the CLAUDE.md 'Canonical Working Copy' banner (e.g. '$C3_FIRST'). A canonical fact may have been updated in one always-read file but not the other — reconcile across CLAUDE.md, CONTEXT-MANIFEST and MEMORY. (See GOTCHAS #11.)"
      fi
    fi
  fi
fi
exit 0
