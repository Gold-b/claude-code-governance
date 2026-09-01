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
      mkdir -p "$(dirname "$DEST")" 2>/dev/null
      cp "$FILE_PATH" "$DEST" 2>/dev/null && SYNCED=$((SYNCED + 1))
      echo "$(date +%Y-%m-%dT%H:%M:%S%z) $FILE_PATH" >> "$HOME/.claude/logs/.governance-push-pending" 2>/dev/null
      gov_log "sync-copies" "docs synced to installer bundle: $DOC_REL"
      echo "[GOVERNANCE-SYNC] Governance doc copied to the installer bundle. GitHub push queued for session end."
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
        cp "$SOURCE" "$_t" && CHANGES=$((CHANGES + 1))
      fi
    fi
  done <<EOF
$(gov_mirror_roots)
EOF

  # Target 3: Installer bundle
  if [ -d "$INSTALLER_HOOKS" ]; then
    TARGET3="$INSTALLER_HOOKS/$BASENAME"
    if ! diff -q "$SOURCE" "$TARGET3" &>/dev/null; then
      cp "$SOURCE" "$TARGET3" && CHANGES=$((CHANGES + 1))
    fi
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
        cp "$SOURCE" "$_t" && CHANGES=$((CHANGES + 1))
      fi
    fi
  done <<EOF
$(gov_mirror_roots)
EOF

  # Target 3: Installer bundle
  if [ -d "$INSTALLER_SKILLS" ]; then
    TARGET3="$INSTALLER_SKILLS/$SKILL_REL_PATH"
    mkdir -p "$(dirname "$TARGET3")" 2>/dev/null
    if ! diff -q "$SOURCE" "$TARGET3" &>/dev/null; then
      cp "$SOURCE" "$TARGET3" && CHANGES=$((CHANGES + 1))
    fi
  fi
fi

# --- Set push-pending flag if anything changed ---
if [ $CHANGES -gt 0 ]; then
  echo "$(date -Iseconds) $FILE_PATH" >> "$FLAG_FILE"
  gov_log "sync-copies" "Synced $BASENAME to $CHANGES location(s). Push pending."
  echo "[GOVERNANCE-SYNC] Auto-copied governance file to $CHANGES additional location(s). GitHub push queued for session end."
fi

exit 0
