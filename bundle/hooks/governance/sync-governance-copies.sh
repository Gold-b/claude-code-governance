#!/usr/bin/env bash
# sync-governance-copies.sh — Auto-sync governance files to all 4 locations
# Fires on PostToolUse (Edit/Write/MultiEdit/NotebookEdit).
#
# When a governance file (hook or skill) is edited at the PRIMARY location
# (~/.claude/hooks/governance/ or ~/.claude/skills/), this hook automatically
# copies it to the other 3 locations:
#   1. Source repo:  C:\openclaw-docker\.claude\hooks\governance\
#   2. Client repo:  C:\GoldB-Agent\.claude\hooks\governance\
#   3. Installer bundle: ~/.claude/governance-installer/bundle/hooks/governance/
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
INPUT=$(cat 2>/dev/null)
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

# --- Sync hooks to all locations ---
if [ $IS_HOOK -eq 1 ] && [ -n "$BASENAME" ]; then
  SOURCE="$HOOK_DIR/$BASENAME"
  if [ ! -f "$SOURCE" ]; then
    exit 0
  fi

  # Target 1: Source repo
  TARGET1="/c/openclaw-docker/.claude/hooks/governance/$BASENAME"
  if [ -d "/c/openclaw-docker/.claude/hooks/governance" ]; then
    if ! diff -q "$SOURCE" "$TARGET1" &>/dev/null; then
      cp "$SOURCE" "$TARGET1" && CHANGES=$((CHANGES + 1))
    fi
  fi

  # Target 2: Client repo
  TARGET2="/c/GoldB-Agent/.claude/hooks/governance/$BASENAME"
  if [ -d "/c/GoldB-Agent/.claude/hooks/governance" ]; then
    if ! diff -q "$SOURCE" "$TARGET2" &>/dev/null; then
      cp "$SOURCE" "$TARGET2" && CHANGES=$((CHANGES + 1))
    fi
  else
    mkdir -p "/c/GoldB-Agent/.claude/hooks/governance" 2>/dev/null
    cp "$SOURCE" "$TARGET2" && CHANGES=$((CHANGES + 1))
  fi

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

  # Target 1: Source repo
  TARGET1="/c/openclaw-docker/.claude/skills/$SKILL_REL_PATH"
  mkdir -p "$(dirname "$TARGET1")" 2>/dev/null
  if ! diff -q "$SOURCE" "$TARGET1" &>/dev/null; then
    cp "$SOURCE" "$TARGET1" && CHANGES=$((CHANGES + 1))
  fi

  # Target 2: Client repo
  TARGET2="/c/GoldB-Agent/.claude/skills/$SKILL_REL_PATH"
  mkdir -p "$(dirname "$TARGET2")" 2>/dev/null
  if ! diff -q "$SOURCE" "$TARGET2" &>/dev/null; then
    cp "$SOURCE" "$TARGET2" && CHANGES=$((CHANGES + 1))
  fi

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
