#!/usr/bin/env bash
# ============================================================================
# Context Governance Installer for Claude Code
# Version: 1.0.0 (2026-04-12)
#
# Installs the full governance architecture at the user level (~/.claude/).
# Idempotent — safe to run multiple times. Existing files are backed up.
#
# Usage:
#   bash ~/.claude/governance-installer/install.sh [--core-only] [--force] [--dry-run]
#
# Options:
#   --core-only   Install only core governance skills (skip extended toolkit)
#   --force       Overwrite existing files without prompting
#   --dry-run     Show what would be installed without making changes
#   --no-claude-md  Skip CLAUDE.md installation (keep your existing one)
#   --uninstall   Remove all governance files (with backup)
#
# What gets installed:
#   ~/.claude/hooks/                 11 governance hook scripts
#   ~/.claude/skills/                7 core + 5 extended skills
#   ~/.claude/docs/                  2 governance guide documents
#   ~/.claude/CLAUDE.md              User-level instructions (if missing or --force)
#   ~/.claude/settings.json          Hooks merged into existing settings
#   ~/.claude/logs/                  Log directory created
# ============================================================================

set -euo pipefail

# ── Colors & formatting ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { printf "${BLUE}ℹ${NC}  %s\n" "$1"; }
success() { printf "${GREEN}✓${NC}  %s\n" "$1"; }
warn()    { printf "${YELLOW}⚠${NC}  %s\n" "$1"; }
error()   { printf "${RED}✗${NC}  %s\n" "$1" >&2; }
header()  { printf "\n${BOLD}${CYAN}── %s ──${NC}\n\n" "$1"; }

# ── Parse arguments ──────────────────────────────────────────────────────────
CORE_ONLY=0
FORCE=0
DRY_RUN=0
NO_CLAUDE_MD=0
UNINSTALL=0

for arg in "$@"; do
  case "$arg" in
    --core-only)    CORE_ONLY=1 ;;
    --force)        FORCE=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    --no-claude-md) NO_CLAUDE_MD=1 ;;
    --uninstall)    UNINSTALL=1 ;;
    --help|-h)
      sed -n '2,/^# ====/{ /^# ====/d; s/^# //; s/^#//; p; }' "$0"
      exit 0
      ;;
    *)
      error "Unknown option: $arg"
      error "Run with --help for usage"
      exit 1
      ;;
  esac
done

# ── Resolve paths ────────────────────────────────────────────────────────────
CLAUDE_HOME="${HOME}/.claude"
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="${INSTALLER_DIR}/bundle"
BACKUP_DIR="${CLAUDE_HOME}/backups/governance-$(date '+%Y%m%d-%H%M%S')"

# Verify bundle exists
if [ ! -d "$BUNDLE_DIR" ]; then
  error "Bundle directory not found at: $BUNDLE_DIR"
  error "Make sure install.sh is inside the governance-installer/ directory."
  exit 1
fi

# ── Uninstall mode ───────────────────────────────────────────────────────────
if [ "$UNINSTALL" = "1" ]; then
  header "Uninstalling Context Governance"

  mkdir -p "$BACKUP_DIR"
  info "Backup directory: $BACKUP_DIR"

  # Backup and remove hooks
  if [ -d "$CLAUDE_HOME/hooks" ]; then
    cp -r "$CLAUDE_HOME/hooks" "$BACKUP_DIR/hooks" 2>/dev/null || true
    rm -rf "$CLAUDE_HOME/hooks"
    success "Removed ~/.claude/hooks/ (backed up)"
  fi

  # Backup and remove docs
  if [ -d "$CLAUDE_HOME/docs" ]; then
    cp -r "$CLAUDE_HOME/docs" "$BACKUP_DIR/docs" 2>/dev/null || true
    rm -rf "$CLAUDE_HOME/docs"
    success "Removed ~/.claude/docs/ (backed up)"
  fi

  # Remove governance skills only
  CORE_SKILLS="bootstrapper context-governance evidence-debugger impact-safe-executor init-governance live-state-orchestrator parallel-session-merge"
  EXTENDED_SKILLS="plan-and-execute qa-sec multi-agents full-finish enable-remote-code"
  for skill in $CORE_SKILLS $EXTENDED_SKILLS; do
    if [ -d "$CLAUDE_HOME/skills/$skill" ]; then
      cp -r "$CLAUDE_HOME/skills/$skill" "$BACKUP_DIR/skill-$skill" 2>/dev/null || true
      rm -rf "$CLAUDE_HOME/skills/$skill"
      success "Removed skill: $skill (backed up)"
    fi
  done

  # Remove hooks from settings.json (keep everything else)
  if [ -f "$CLAUDE_HOME/settings.json" ] && command -v node &>/dev/null; then
    cp "$CLAUDE_HOME/settings.json" "$BACKUP_DIR/settings.json"
    node -e "
      const fs = require('fs');
      const f = process.env.HOME + '/.claude/settings.json';
      const s = JSON.parse(fs.readFileSync(f, 'utf8'));
      delete s.hooks;
      fs.writeFileSync(f, JSON.stringify(s, null, 2) + '\n');
      console.log('Hooks removed from settings.json (backed up)');
    " 2>/dev/null && success "Cleaned settings.json" || warn "Could not clean settings.json — remove hooks section manually"
  fi

  info "Backup saved at: $BACKUP_DIR"
  success "Uninstall complete. CLAUDE.md was NOT removed (manual decision)."
  exit 0
fi

# ── Pre-flight checks ────────────────────────────────────────────────────────
header "Context Governance Installer v1.0.0"

if [ "$DRY_RUN" = "1" ]; then
  warn "DRY RUN — no files will be modified"
fi

info "Claude home: $CLAUDE_HOME"
info "Bundle source: $BUNDLE_DIR"
info "Mode: $([ "$CORE_ONLY" = "1" ] && echo 'core-only (7 skills)' || echo 'full (12 skills)')"

# Check for node (needed for settings.json merge)
if ! command -v node &>/dev/null; then
  warn "Node.js not found — settings.json merge will be skipped"
  warn "You'll need to manually add hooks to ~/.claude/settings.json"
  HAS_NODE=0
else
  HAS_NODE=1
fi

# ── Helper: safe copy with backup ────────────────────────────────────────────
# copy_safe <src> <dest> [description]
copy_safe() {
  local src="$1"
  local dest="$2"
  local desc="${3:-$(basename "$dest")}"

  if [ "$DRY_RUN" = "1" ]; then
    if [ -f "$dest" ]; then
      info "[DRY] Would overwrite: $desc"
    else
      info "[DRY] Would create: $desc"
    fi
    return 0
  fi

  mkdir -p "$(dirname "$dest")"

  if [ -f "$dest" ] && [ "$FORCE" = "0" ]; then
    # File exists — check if identical
    if diff -q "$src" "$dest" &>/dev/null; then
      info "Unchanged: $desc"
      return 0
    fi
    # Different — backup then overwrite
    mkdir -p "$BACKUP_DIR"
    local rel="${dest#$CLAUDE_HOME/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp "$dest" "$BACKUP_DIR/$rel"
    warn "Backed up existing: $desc"
  fi

  cp "$src" "$dest"
  success "Installed: $desc"
}

# ── 1. Install hooks ────────────────────────────────────────────────────────
header "Installing Hooks (11 files)"

# Root-level hook
copy_safe "$BUNDLE_DIR/hooks/check-full-finish.sh" \
          "$CLAUDE_HOME/hooks/check-full-finish.sh" \
          "hooks/check-full-finish.sh"

# Governance hooks
for f in "$BUNDLE_DIR/hooks/governance/"*.sh; do
  fname="$(basename "$f")"
  copy_safe "$f" "$CLAUDE_HOME/hooks/governance/$fname" "hooks/governance/$fname"
done

# Ensure executable
if [ "$DRY_RUN" = "0" ]; then
  chmod +x "$CLAUDE_HOME/hooks/"*.sh 2>/dev/null || true
  chmod +x "$CLAUDE_HOME/hooks/governance/"*.sh 2>/dev/null || true
fi

HOOKS_COUNT=$(find "$CLAUDE_HOME/hooks/" -name "*.sh" -type f 2>/dev/null | wc -l)
success "Hooks installed: $HOOKS_COUNT files"

# ── 2. Install skills ───────────────────────────────────────────────────────
header "Installing Skills"

CORE_SKILLS="bootstrapper context-governance evidence-debugger impact-safe-executor init-governance live-state-orchestrator parallel-session-merge"
EXTENDED_SKILLS="plan-and-execute qa-sec multi-agents full-finish enable-remote-code"

INSTALL_SKILLS="$CORE_SKILLS"
if [ "$CORE_ONLY" = "0" ]; then
  INSTALL_SKILLS="$INSTALL_SKILLS $EXTENDED_SKILLS"
fi

SKILL_COUNT=0
for skill in $INSTALL_SKILLS; do
  src_dir="$BUNDLE_DIR/skills/$skill"
  if [ -d "$src_dir" ]; then
    for f in "$src_dir"/*; do
      fname="$(basename "$f")"
      copy_safe "$f" "$CLAUDE_HOME/skills/$skill/$fname" "skills/$skill/$fname"
    done
    SKILL_COUNT=$((SKILL_COUNT + 1))
  else
    warn "Skill bundle not found: $skill (skipping)"
  fi
done

success "Skills installed: $SKILL_COUNT"

# ── 3. Install docs ─────────────────────────────────────────────────────────
header "Installing Governance Docs"

for f in "$BUNDLE_DIR/docs/"*.md; do
  fname="$(basename "$f")"
  copy_safe "$f" "$CLAUDE_HOME/docs/$fname" "docs/$fname"
done

# ── 4. Install CLAUDE.md ────────────────────────────────────────────────────
header "Installing CLAUDE.md"

if [ "$NO_CLAUDE_MD" = "1" ]; then
  info "Skipped CLAUDE.md (--no-claude-md flag)"
elif [ -f "$CLAUDE_HOME/CLAUDE.md" ] && [ "$FORCE" = "0" ]; then
  warn "CLAUDE.md already exists — skipping (use --force to overwrite)"
  info "Template available at: $BUNDLE_DIR/CLAUDE.md.template"
else
  copy_safe "$BUNDLE_DIR/CLAUDE.md.template" "$CLAUDE_HOME/CLAUDE.md" "CLAUDE.md"
fi

# ── 5. Merge hooks into settings.json ───────────────────────────────────────
header "Configuring settings.json"

if [ "$DRY_RUN" = "1" ]; then
  info "[DRY] Would merge hooks into ~/.claude/settings.json"
elif [ "$HAS_NODE" = "0" ]; then
  warn "Skipped settings.json merge (no Node.js). Manual setup required."
  info "Copy the hooks section from: $BUNDLE_DIR/settings-hooks.json"
else
  SETTINGS_FILE="$CLAUDE_HOME/settings.json"
  HOOKS_FILE="$BUNDLE_DIR/settings-hooks.json"

  # Backup existing settings
  if [ -f "$SETTINGS_FILE" ]; then
    mkdir -p "$BACKUP_DIR"
    cp "$SETTINGS_FILE" "$BACKUP_DIR/settings.json"
  fi

  node -e "
    const fs = require('fs');
    const settingsPath = '${SETTINGS_FILE}'.replace(/\\\\/g, '/');
    const hooksPath = '${HOOKS_FILE}'.replace(/\\\\/g, '/');

    // Load or create settings
    let settings = {};
    try {
      settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
    } catch (e) {
      // File doesn't exist or is invalid — start fresh
    }

    // Load hooks template
    const hooksTemplate = JSON.parse(fs.readFileSync(hooksPath, 'utf8'));

    // Merge hooks (replace entire hooks section — our hooks are the source of truth)
    settings.hooks = hooksTemplate.hooks;

    // Set effort level if not already set
    if (!settings.effortLevel) {
      settings.effortLevel = hooksTemplate.effortLevel || 'max';
    }

    // Write back
    fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
    console.log('Settings merged successfully');
  " 2>&1 && success "settings.json hooks merged" || error "Failed to merge settings.json"
fi

# ── 6. Create log directory ─────────────────────────────────────────────────
if [ "$DRY_RUN" = "0" ]; then
  mkdir -p "$CLAUDE_HOME/logs/governance-success-history"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
header "Installation Complete"

echo ""
printf "${BOLD}Installed components:${NC}\n"
printf "  ${GREEN}✓${NC} Hooks:     %s scripts in ~/.claude/hooks/\n" "$HOOKS_COUNT"
printf "  ${GREEN}✓${NC} Skills:    %s skills in ~/.claude/skills/\n" "$SKILL_COUNT"
printf "  ${GREEN}✓${NC} Docs:      2 governance guides in ~/.claude/docs/\n"
if [ "$NO_CLAUDE_MD" = "0" ]; then
  printf "  ${GREEN}✓${NC} CLAUDE.md: User-level instructions\n"
fi
printf "  ${GREEN}✓${NC} Settings:  Hooks registered in settings.json\n"
printf "  ${GREEN}✓${NC} Logs:      ~/.claude/logs/ directory ready\n"

if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
  printf "\n  ${YELLOW}⚠${NC} Backup of replaced files: %s\n" "$BACKUP_DIR"
fi

echo ""
printf "${BOLD}Next steps:${NC}\n"
printf "  1. Open any project with Claude Code\n"
printf "  2. The SessionStart hook will auto-detect governance state\n"
printf "  3. For new projects, run ${CYAN}/init-governance${NC} to scaffold context files\n"
printf "  4. For existing governed projects, the briefing will appear automatically\n"
echo ""
printf "${BOLD}Kill switch:${NC} export GOVERNANCE_HOOKS=0  (disables all hooks)\n"
echo ""
success "Context Governance is ready."
