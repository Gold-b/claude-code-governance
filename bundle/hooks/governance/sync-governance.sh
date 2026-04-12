#!/usr/bin/env bash
# sync-governance.sh — Mechanically sync governance file values from SSOTs
# Created: 2026-04-12 (Context Governance DRY enforcement)
#
# Reads version from version.json, counts gotchas from GOTCHAS.md,
# and updates all files that contain hardcoded versions/counts.
# Idempotent — running twice produces the same result.
# Exit 0 on success.

set -euo pipefail

# --- Detect project root (walk up to find CLAUDE.md) ---
find_project_root() {
  local dir="$1"
  while [ "$dir" != "/" ] && [ "$dir" != "." ]; do
    if [ -f "$dir/CLAUDE.md" ] && [ -f "$dir/version.json" ]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

PROJECT_ROOT="$(find_project_root "$(pwd)")" || {
  echo "[sync-governance] ERROR: Could not find project root (CLAUDE.md + version.json)" >&2
  exit 0  # fail-soft per governance contract
}

# --- Source _common.sh for logging ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/_common.sh" ]; then
  # shellcheck source=_common.sh
  source "$SCRIPT_DIR/_common.sh"
  gov_disabled && exit 0
else
  # Fallback logging if _common.sh missing
  gov_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2"; }
fi

HOOK_NAME="sync-governance"
CHANGES=0

# --- Step 1: Read version from version.json (SSOT) ---
VERSION_FILE="$PROJECT_ROOT/version.json"
if [ ! -f "$VERSION_FILE" ]; then
  gov_log "$HOOK_NAME" "ERROR: version.json not found at $VERSION_FILE"
  exit 0
fi

# Extract version using sed (no jq dependency)
CURRENT_VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_FILE")
if [ -z "$CURRENT_VERSION" ]; then
  gov_log "$HOOK_NAME" "ERROR: Could not parse version from $VERSION_FILE"
  exit 0
fi

gov_log "$HOOK_NAME" "SSOT version: $CURRENT_VERSION"

# --- Step 2: Count gotchas entries from GOTCHAS.md ---
GOTCHAS_FILE="$PROJECT_ROOT/docs/context/GOTCHAS.md"
GOTCHAS_COUNT=0
if [ -f "$GOTCHAS_FILE" ]; then
  # Gotcha entries are numbered lines like "1. **...", "215. **..."
  GOTCHAS_COUNT=$(grep -c '^[0-9]\+\.' "$GOTCHAS_FILE" 2>/dev/null || echo "0")
  gov_log "$HOOK_NAME" "SSOT gotchas count: $GOTCHAS_COUNT"
fi

# --- Step 3: Read active handoff filename from HANDOFF.md ---
HANDOFF_FILE="$PROJECT_ROOT/docs/context/HANDOFF.md"
HANDOFF_TARGET=""
if [ -f "$HANDOFF_FILE" ]; then
  HANDOFF_TARGET=$(sed -n 's/^points_to:[[:space:]]*\.\.\/..\///p' "$HANDOFF_FILE")
  if [ -z "$HANDOFF_TARGET" ]; then
    # Try without ../ prefix stripping
    HANDOFF_TARGET=$(sed -n 's/^points_to:[[:space:]]*//p' "$HANDOFF_FILE")
  fi
  gov_log "$HOOK_NAME" "Active handoff: $HANDOFF_TARGET"
fi

# --- Helper: update a file with sed, track changes ---
# Usage: update_file <file> <sed_expression> <description>
update_file() {
  local file="$1"
  local sed_expr="$2"
  local desc="$3"

  if [ ! -f "$file" ]; then
    gov_log "$HOOK_NAME" "SKIP $desc — file not found: $file"
    return
  fi

  # Capture before state
  local before
  before=$(md5sum "$file" 2>/dev/null || cat "$file" | wc -c)

  # Apply sed in-place
  sed -i "$sed_expr" "$file"

  # Check if changed
  local after
  after=$(md5sum "$file" 2>/dev/null || cat "$file" | wc -c)

  if [ "$before" != "$after" ]; then
    CHANGES=$((CHANGES + 1))
    gov_log "$HOOK_NAME" "UPDATED $desc"
    echo "  [UPDATED] $desc"
  fi
}

echo "[sync-governance] Syncing from SSOTs (version=$CURRENT_VERSION, gotchas=$GOTCHAS_COUNT)"

# --- Step 4a: Update CLAUDE.md — Project Overview version ---
# Pattern: **Gold-B's Agent** (v1.4.NNN) in the Project Overview line
update_file \
  "$PROJECT_ROOT/CLAUDE.md" \
  "s|\*\*Gold-B's Agent\*\* (v[0-9]\+\.[0-9]\+\.[0-9]\+)|\*\*Gold-B's Agent\*\* (v${CURRENT_VERSION})|g" \
  "CLAUDE.md Project Overview version"

# --- Step 4b: Update CLAUDE.md — Version & Release section ---
# Pattern: Current: **1.4.NNN**
update_file \
  "$PROJECT_ROOT/CLAUDE.md" \
  "s|Current: \*\*[0-9]\+\.[0-9]\+\.[0-9]\+\*\*|Current: \*\*${CURRENT_VERSION}\*\*|g" \
  "CLAUDE.md Version & Release current version"

# --- Step 4c: Update Plans/PLAN.md — Project version line ---
# Pattern: **Project version:** v1.4.NNN (per `version.json`)
update_file \
  "$PROJECT_ROOT/Plans/PLAN.md" \
  "s|\*\*Project version:\*\* v[0-9]\+\.[0-9]\+\.[0-9]\+|\*\*Project version:\*\* v${CURRENT_VERSION}|g" \
  "Plans/PLAN.md project version"

# --- Step 4d: Update docs/context/MEMORY.md — Active Summary version ---
# Pattern: Project version: **v1.4.NNN** (per `version.json`)
update_file \
  "$PROJECT_ROOT/docs/context/MEMORY.md" \
  "s|Project version: \*\*v[0-9]\+\.[0-9]\+\.[0-9]\+\*\*|Project version: \*\*v${CURRENT_VERSION}\*\*|g" \
  "docs/context/MEMORY.md active summary version"

# --- Step 4e: Update GOTCHAS.md footer — entry count ---
if [ -f "$GOTCHAS_FILE" ] && [ "$GOTCHAS_COUNT" -gt 0 ]; then
  update_file \
    "$GOTCHAS_FILE" \
    "s|[0-9]\+ entries\.\$|${GOTCHAS_COUNT} entries.|g" \
    "docs/context/GOTCHAS.md footer entry count"
fi

# --- Summary ---
if [ "$CHANGES" -eq 0 ]; then
  echo "[sync-governance] All files already in sync. No changes needed."
  gov_log "$HOOK_NAME" "All files in sync — 0 changes"
else
  echo "[sync-governance] Done. $CHANGES file(s) updated."
  gov_log "$HOOK_NAME" "Sync complete — $CHANGES file(s) updated"
fi

exit 0
