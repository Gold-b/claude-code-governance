#!/usr/bin/env bash
# ============================================================================
# Context Governance Installer for Claude Code
# Version: read from bundle/VERSION (single source — do not hardcode it here again)
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
#   --deep-verify Also run governance-selftest.sh after installing (~2 min extra)
#   --no-verify   Skip the post-install verification. The run still completes and
#                 still exits 0 -- a kill switch that fails the build is a nag,
#                 not a switch -- but it is loudly reported as UNVERIFIED both at
#                 the skip and in the closing summary.
#                 (env equivalent: GOV_INSTALL_VERIFY=0 / GOV_INSTALL_DEEP_VERIFY=1)
#
# What gets installed:
#   ~/.claude/hooks/                 11 governance hook scripts
#   ~/.claude/skills/                9 core + 5 extended skills
#   ~/.claude/docs/                  3 governance documents (2 guides + handover protocol)
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
# Post-install verification. ON by default: an installer whose only evidence is
# "the files are there" is the failure this framework already shipped once —
# verify.sh reported 37/37 from `[ -f ]` tests while a --force run had reverted a
# fix and deleted 6 of 11 test cases. Existence is not execution.
DO_VERIFY="${GOV_INSTALL_VERIFY:-1}"
DEEP_VERIFY="${GOV_INSTALL_DEEP_VERIFY:-0}"

for arg in "$@"; do
  case "$arg" in
    --core-only)    CORE_ONLY=1 ;;
    --force)        FORCE=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    --no-claude-md) NO_CLAUDE_MD=1 ;;
    --uninstall)    UNINSTALL=1 ;;
    --no-verify)    DO_VERIFY=0 ;;
    --deep-verify)  DEEP_VERIFY=1 ;;
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

# ── Framework version (ONE definition — bundle/VERSION) ──────────────────────
# Written to ~/.claude/.governance-version at install time. pre-session.sh compares that marker
# against the version published on GitHub and prints an advisory when an update exists. Without
# the marker there is no way for a machine to learn that a release happened, which is the state
# this framework shipped in until 2026-08-25.
# `VAR=$(cmd < missing_file)` under `set -euo pipefail` aborts the ENTIRE script with one cryptic
# line and no output — `2>/dev/null` hides the message, not the failure — and the `|| "unknown"`
# fallback below never runs. Reachable in practice: the installer bundle is maintained by
# file-by-file copy, so a bundle without VERSION is a normal state, not a corrupt one.
BUNDLE_VERSION=$( { cat "$BUNDLE_DIR/VERSION" 2>/dev/null || true; } | tr -d '[:space:]')
[ -n "$BUNDLE_VERSION" ] || BUNDLE_VERSION="unknown"

# Tracks whether every step actually succeeded. The version marker is a CLAIM about what is
# installed; stamping it after a failed step tells the machine it is current when it is not.
INSTALL_DEGRADED=0
# Which step failed matters for the summary line. Before this split, ANY degraded
# install printed "Settings: NOT registered", which sends the reader to fix a
# settings.json that is perfectly fine.
SETTINGS_FAILED=0
VERIFY_FAILED=0
VERIFY_SKIPPED=0

# Local read helper — install.sh must work before the framework is installed, so it cannot source
# _common.sh. Same fail-safe shape: `< missing_file` under `set -euo pipefail` kills the script.
gov_read_version_local() { { cat "$CLAUDE_HOME/.governance-version" 2>/dev/null || true; } | tr -d '[:space:]'; }

# ── Skill inventory (ONE definition — install, uninstall and the mode line all read it) ──────
#
# A skill that ships in bundle/skills/ but appears in NEITHER list is bundled and never
# installed — a silent gap. It bit twice: `pre-close-check` is documented as MANDATORY before
# every handoff write (GOVERNANCE-AGENT-GUIDE §9.1) and `/pr-to-git` is named by the default
# Definition of Done (NEXT-SESSION-HANDOVER.md §2); both were bundled, referenced, and absent
# from a clean install. The lists also used to be duplicated (install + uninstall + a hardcoded
# "12 skills" banner), so adding a skill in one place left the other two lying.
#
# Deliberately NOT installed — machine-specific or superseded. Keep accurate if you add one:
#   end-session          — deprecated, merged into /full-finish
#   wa-cc-bridge         — WhatsApp bridge; runs as a service on one host, not a per-machine skill
#   wa-cc-poll           — helper for the above
#   whatsapp             — per-user credentials, not part of the governance framework
#   whatsapp-checkpoints — same
# `pr-to-git` is CORE, not extended, and the reason is not "it is important": bundle/docs/ is
# installed UNCONDITIONALLY, --core-only included. So a --core-only machine receives
# NEXT-SESSION-HANDOVER.md and its default Definition of Done, which names /pr-to-git as a
# mandatory bullet — while the skill itself would be absent. A doc that ships in core may only
# mandate skills that ship in core.
CORE_SKILLS="bootstrapper context-governance evidence-debugger impact-safe-executor init-governance live-state-orchestrator parallel-session-merge pre-close-check pr-to-git"
EXTENDED_SKILLS="plan-and-execute qa-sec multi-agents full-finish enable-remote-code"

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

  # Remove governance skills only (inventory defined once, above)
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

  # Remove the version marker. Leaving it behind makes an UNINSTALLED machine report
  # "installed v1.1.0" with a green version check sitting beside every other check failing.
  if [ -f "$CLAUDE_HOME/.governance-version" ]; then
    cp "$CLAUDE_HOME/.governance-version" "$BACKUP_DIR/.governance-version" 2>/dev/null || true
    rm -f "$CLAUDE_HOME/.governance-version"
    success "Removed version marker (backed up)"
  fi
  # The update-check cache is regenerated on demand; a stale one would outlive the framework.
  # The glob catches `.governance-latest.<pid>` temp files left by fetches that were killed.
  rm -f "$CLAUDE_HOME/logs/.governance-latest" "$CLAUDE_HOME/logs/.governance-latest".* 2>/dev/null || true

  info "Backup saved at: $BACKUP_DIR"
  success "Uninstall complete. CLAUDE.md was NOT removed (manual decision)."
  exit 0
fi

# ── Pre-flight checks ────────────────────────────────────────────────────────
header "Context Governance Installer v${BUNDLE_VERSION}"

if [ "$DRY_RUN" = "1" ]; then
  warn "DRY RUN — no files will be modified"
fi

info "Claude home: $CLAUDE_HOME"
info "Bundle source: $BUNDLE_DIR"
CORE_N=$(printf '%s\n' $CORE_SKILLS | wc -l | tr -d ' ')
EXT_N=$(printf '%s\n' $EXTENDED_SKILLS | wc -l | tr -d ' ')
info "Mode: $([ "$CORE_ONLY" = "1" ] && echo "core-only ($CORE_N skills)" || echo "full ($((CORE_N + EXT_N)) skills)")"

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

  if [ -f "$dest" ]; then
    # File exists — check if identical
    if diff -q "$src" "$dest" &>/dev/null; then
      info "Unchanged: $desc"
      return 0
    fi
    # Different — backup then overwrite. UNCONDITIONAL: the backup must happen with
    # --force too. On 2026-08-16 a --force run silently overwrote the user's personal
    # ~/.claude/CLAUDE.md with zero backup (this branch was FORCE=0-only) and the
    # content was only recoverable because a live session happened to hold a copy.
    # --force means "don't prompt", never "don't back up".
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
header "Installing Hooks (12 files)"

# Root-level hook
copy_safe "$BUNDLE_DIR/hooks/check-full-finish.sh" \
          "$CLAUDE_HOME/hooks/check-full-finish.sh" \
          "hooks/check-full-finish.sh"

# Governance hooks — EVERY FILE THE BUNDLE CARRIES, enumerated by the bundle itself.
#
# DO NOT REINTRODUCE AN EXTENSION LIST HERE. It has now been wrong twice, and the second time it
# was wrong ONE LINE BELOW A COMMENT RECORDING THE FIRST:
#   2026-08-16  `*.sh` only -> wa-send.js and gov-notify.ps1 were left permanently stale on every
#               install. Fixed by adding `*.js` and `*.ps1`, and a comment was written about it.
#   2026-09-01  pii-gate-parse.py was added, `*.py` was not. A fresh install then REGISTERED the
#               blocking PII gate and shipped it INERT: the hook printed "MALFUNCTION - parser
#               missing ... Gate is OPEN", exited 1, and the write proceeded — while install.sh
#               printed "Verified". Reproduced end-to-end before this fix.
# The class is the defect, not the instance: any list of suffixes is a prediction about files that
# do not exist yet, and it will be wrong again the next time someone adds a file type. So the
# bundle's own contents are the list. `find` also carries subdirectories (tests/) for free, which
# the hand-written `tests` loop below used to do separately and could equally have been forgotten.
#
# (A NOTE THAT WAS FALSE, corrected 2026-09-01. It used to say that _common.sh gov_notify()
# calls gov-notify.ps1 to raise the Windows popup, and warned the reader not to tidy it away.
# `grep -rn gov-notify ~/.claude/hooks` returns nothing but the comment itself: the file is an
# ORPHAN, and the sole justification for keeping it was a claim nobody had checked. That is why
# governance-selftest.sh now VERIFIES every "invoked-by" declaration against its named caller
# rather than believing it. Tracked as B11, with render-gate.sh and render-rules-read.sh.)
if [ -d "$BUNDLE_DIR/hooks/governance" ]; then
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    rel="${f#$BUNDLE_DIR/hooks/governance/}"
    case "$rel" in *.bak|*.bak-*|*.tmp|*.orig|*.rej) continue ;; esac
    dest="$CLAUDE_HOME/hooks/governance/$rel"
    mkdir -p "$(dirname "$dest")" 2>/dev/null
    copy_safe "$f" "$dest" "hooks/governance/$rel"
  done <<HOOKFILES
$(find "$BUNDLE_DIR/hooks/governance" -type f 2>/dev/null | sort)
HOOKFILES
fi

# ── 1b. Assert the copy actually happened ────────────────────────────────────
# EXISTENCE OF THE SOURCE IS NOT ARRIVAL AT THE DESTINATION. Every failure above was invisible
# because nothing compared the two sides; the installer's own summary counted files in the
# DESTINATION and was therefore happy with whatever it had managed to write. This compares.
HOOK_MISSING=""
if [ "$DRY_RUN" = "0" ] && [ -d "$BUNDLE_DIR/hooks/governance" ]; then
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    rel="${f#$BUNDLE_DIR/hooks/governance/}"
    case "$rel" in *.bak|*.bak-*|*.tmp|*.orig|*.rej) continue ;; esac
    [ -f "$CLAUDE_HOME/hooks/governance/$rel" ] || HOOK_MISSING="$HOOK_MISSING $rel"
  done <<HOOKCHECK
$(find "$BUNDLE_DIR/hooks/governance" -type f 2>/dev/null | sort)
HOOKCHECK
  if [ -n "$HOOK_MISSING" ]; then
    error "These bundled files did NOT reach ~/.claude/hooks/governance/:$HOOK_MISSING"
    error "A registered hook whose helper is missing does not fail loudly — it reports itself"
    error "verified and lets the write through. Treating this as fatal."
    INSTALL_DEGRADED=1
  fi

  # A registered hook is only a control if the files it CANNOT RUN WITHOUT are beside it. The
  # dependency is declared here rather than discovered, because a wrong guess is silent.
  for pair in \
      "pii-gate-pretooluse.sh:pii-gate-parse.py" \
      "pii-gate-pretooluse.sh:check-no-pii.sh" \
      "selftest-advisory-stop.sh:governance-selftest.sh" \
      "close-report.sh:_common.sh" \
      "close-completeness.sh:_common.sh" \
      "end-session.sh:check-no-pii.sh"; do
    hook="${pair%%:*}"; dep="${pair##*:}"
    if [ -f "$CLAUDE_HOME/hooks/governance/$hook" ] && [ ! -f "$CLAUDE_HOME/hooks/governance/$dep" ]; then
      error "$hook is installed but its hard dependency $dep is NOT. That hook is INERT."
      INSTALL_DEGRADED=1
    fi
  done
fi

# Ensure executable
if [ "$DRY_RUN" = "0" ]; then
  chmod +x "$CLAUDE_HOME/hooks/"*.sh 2>/dev/null || true
  chmod +x "$CLAUDE_HOME/hooks/governance/"*.sh 2>/dev/null || true
  chmod +x "$CLAUDE_HOME/hooks/governance/tests/"*.sh 2>/dev/null || true
fi

# `set -euo pipefail` + a `find` on a directory that does not exist = the assignment inherits
# find's failure and the script dies HERE, silently. Under --dry-run nothing has been created yet,
# so ~/.claude/hooks/ is absent on a fresh machine and the whole preview stopped after step 1 while
# still looking like a normal run. A dry-run that quits a third of the way through is worse than no
# dry-run: it reports that an install you never previewed will be fine. Swallow find's status.
HOOKS_COUNT=$( { find "$CLAUDE_HOME/hooks/" -name "*.sh" -type f 2>/dev/null || true; } | wc -l | tr -d ' ')
success "Hooks installed: $HOOKS_COUNT files"

# ── 2. Install skills ───────────────────────────────────────────────────────
header "Installing Skills"

# CORE_SKILLS / EXTENDED_SKILLS are defined ONCE near the top of this file.
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

# Count what the bundle actually carries. The summary line below used to hardcode "2", which
# went stale the moment a third document was added — a summary that lies is worse than none.
DOCS_COUNT=$( { find "$BUNDLE_DIR/docs/" -maxdepth 1 -name "*.md" -type f 2>/dev/null || true; } | wc -l | tr -d ' ')


# ── 4. Install CLAUDE.md ────────────────────────────────────────────────────
header "Installing CLAUDE.md"

if [ "$NO_CLAUDE_MD" = "1" ]; then
  info "Skipped CLAUDE.md (--no-claude-md flag)"
elif [ -f "$CLAUDE_HOME/CLAUDE.md" ]; then
  # NEVER overwrite an existing CLAUDE.md — not even with --force. It is the user's
  # PERSONAL instruction file (preferences, protocols, security rules), not a managed
  # artifact of this framework; replacing it with the generic template is pure data
  # loss. (2026-08-16: a --force update run did exactly that, compounded by the
  # then-missing backup.) --force governs managed hooks/skills/docs only.
  warn "CLAUDE.md already exists — NOT overwritten (personal file; --force does not apply)"
  info "Template for manual merge: $BUNDLE_DIR/CLAUDE.md.template"
else
  copy_safe "$BUNDLE_DIR/CLAUDE.md.template" "$CLAUDE_HOME/CLAUDE.md" "CLAUDE.md"
fi

# ── 5. Merge hooks into settings.json ───────────────────────────────────────
header "Configuring settings.json"

if [ "$DRY_RUN" = "1" ]; then
  info "[DRY] Would merge hooks into ~/.claude/settings.json"
  # `[ cond ] && VAR=1` leaks status 1 when the condition is false, which is a live hazard as the
  # last statement of a function or a script under `set -e`. An if-block cannot.
  if [ "$HAS_NODE" = "0" ]; then INSTALL_DEGRADED=1; SETTINGS_FAILED=1; fi   # a preview must predict the real refusal
elif [ "$HAS_NODE" = "0" ]; then
  warn "Skipped settings.json merge (no Node.js). Manual setup required."
  INSTALL_DEGRADED=1; SETTINGS_FAILED=1
  info "Copy the hooks section from: $BUNDLE_DIR/settings-hooks.json"
else
  SETTINGS_FILE="$CLAUDE_HOME/settings.json"
  HOOKS_FILE="$BUNDLE_DIR/settings-hooks.json"

  # Backup existing settings
  if [ -f "$SETTINGS_FILE" ]; then
    mkdir -p "$BACKUP_DIR"
    cp "$SETTINGS_FILE" "$BACKUP_DIR/settings.json"
  fi

  # Pass hooks JSON via stdin to avoid MSYS/Windows path mangling
  cat "$HOOKS_FILE" | node -e "
    const fs = require('fs');
    const path = require('path');

    // Read hooks template from stdin
    let input = '';
    const stdin = fs.readFileSync(0, 'utf8');
    const hooksTemplate = JSON.parse(stdin);

    // Resolve settings path (handles both Unix and Windows)
    const settingsPath = path.resolve(process.env.HOME || process.env.USERPROFILE, '.claude', 'settings.json');

    // Load or create settings
    let settings = {};
    try {
      settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
    } catch (e) {
      // File doesn't exist or is invalid — start fresh
    }

    // Merge hooks (replace entire hooks section — our hooks are the source of truth)
    settings.hooks = hooksTemplate.hooks;

    // Set effort level if not already set
    if (!settings.effortLevel) {
      settings.effortLevel = hooksTemplate.effortLevel || 'max';
    }

    // Write back
    fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
    console.log('Settings merged successfully');
  " 2>&1 && success "settings.json hooks merged" || { error "Failed to merge settings.json"; INSTALL_DEGRADED=1; SETTINGS_FAILED=1; }
fi

# -- 5b. Seed the machine-local config a fresh install cannot work without ----
#
# WHY (task B3, 2026-09-01). Two files hold the real values that tracked files only reference by
# placeholder. Neither was ever seeded, and three shipped scripts referenced an .example that did
# not exist in the repo. The consequence on a NEW machine was not a crash - it was silence:
#   ~/.claude/.pii-names             absent -> NAME_DENY inert -> every scan prints PASS while the
#                                    one rule that catches proper nouns has never run. That is
#                                    precisely how two people's names sat in a public repository
#                                    for four months.
#   ~/.claude/.governance-local.env  absent -> GOV_REPO_PATH, the commit identity and
#                                    GOV_SELFTEST_PROJECT all unset; the framework audit then
#                                    verifies nothing and reports GREEN-PARTIAL.
#
# NEITHER IS EVER OVERWRITTEN, not even with --force: they are the designated homes for real
# values, so replacing one with a template is a silent downgrade of a live gate. Only the
# .example is refreshed; .pii-names is CREATED, and only when absent.
header "Seeding machine-local config (never overwritten)"

if [ "$DRY_RUN" = "1" ]; then
  info "[DRY] Would install .governance-local.env.example and create an empty ~/.claude/.pii-names if absent."
else
  if [ -f "$BUNDLE_DIR/.governance-local.env.example" ]; then
    if cp "$BUNDLE_DIR/.governance-local.env.example" "$CLAUDE_HOME/.governance-local.env.example" 2>/dev/null; then
      success "Installed: .governance-local.env.example (copy it to .governance-local.env and fill it in)"
    else
      warn "Could not write $CLAUDE_HOME/.governance-local.env.example"; INSTALL_DEGRADED=1
    fi
  else
    warn "bundle/.governance-local.env.example is MISSING - three shipped scripts point users at it."
    INSTALL_DEGRADED=1
  fi

  if [ -f "$CLAUDE_HOME/.governance-local.env" ]; then
    success "Kept existing ~/.claude/.governance-local.env (machine-local; never overwritten)"
  else
    warn "~/.claude/.governance-local.env does not exist. Until you create it from the .example,"
    warn "GOV_REPO_PATH, the commit identity and GOV_SELFTEST_PROJECT are all unset."
  fi

  if [ -f "$CLAUDE_HOME/.pii-names" ]; then
    success "Kept existing ~/.claude/.pii-names (machine-local; never overwritten)"
  elif [ -f "$BUNDLE_DIR/.pii-names.example" ]; then
    if cp "$BUNDLE_DIR/.pii-names.example" "$CLAUDE_HOME/.pii-names" 2>/dev/null; then
      success "Created ~/.claude/.pii-names (empty - see the warning in the summary)"
    else
      warn "Could not create $CLAUDE_HOME/.pii-names"
    fi
  else
    warn "bundle/.pii-names.example is MISSING - NAME_DENY will be inert on this machine."
    INSTALL_DEGRADED=1
  fi
  chmod 600 "$CLAUDE_HOME/.pii-names" "$CLAUDE_HOME/.governance-local.env" 2>/dev/null || true
fi

# Real entries = non-comment, non-blank. Reported as its OWN summary line: a "clean" printed above
# an inert rule is exactly what three review rounds read past on 2026-09-01.
PII_NAMES_N=0
if [ -f "$CLAUDE_HOME/.pii-names" ]; then
  PII_NAMES_N=$( { grep -cE '^[[:space:]]*[^#[:space:]]' "$CLAUDE_HOME/.pii-names" 2>/dev/null || true; } | head -1 )
  case "$PII_NAMES_N" in ''|*[!0-9]*) PII_NAMES_N=0 ;; esac
fi

# ── 6. Create log directory ─────────────────────────────────────────────────
if [ "$DRY_RUN" = "0" ]; then
  mkdir -p "$CLAUDE_HOME/logs/governance-success-history"
fi

# ── 6.5 Post-install verification — EXECUTE, do not just look ────────────────
#
# WHY THIS EXISTS
#   The framework's admission criterion used to be EXISTENCE. verify.sh reports
#   "37/37" from 18 `[ -f ]` file tests and 5 settings-truthiness tests, and on
#   2026-08-30 it was green across a --force run that reverted a fix and deleted
#   6 of 11 test cases. A file test cannot see a file that is present and wrong.
#   So this step RUNS the thing that was just installed and reads its verdict.
#
# WHAT IT PROVES, AND WHAT IT DOES NOT
#   check-no-pii.sh --selftest asserts, on the copy now on disk, that every rule
#   fires on real-shaped values AND that every documented placeholder stays green
#   — both directions, which is the only shape of proof that catches a scanner
#   that has quietly stopped scanning.
#   It does NOT prove the installed version is the NEWEST one: a stale bundle
#   whose selftest still passes installs and verifies clean. Freshness is the
#   version marker's job; this step's job is "what is on disk actually works".
#
# CADENCE
#   ~80 s here for the default check; governance-selftest.sh adds ~2 min and is
#   therefore opt-in (--deep-verify). An install is a rare, deliberate act, so
#   80 s of proof is affordable in a way that 80 s per session close would not be.
#
# FAILURE POLICY
#   Red -> loud, the backup path is named, INSTALL_DEGRADED=1 so the version is
#   NOT stamped and the script exits 1. Nothing is deleted or rolled back
#   automatically: an installer that starts undoing things on a failed check is
#   a second way to lose files. The operator restores from the backup.
#
# KILL SWITCH
#   --no-verify / GOV_INSTALL_VERIFY=0 skips it — but the run is then marked
#   UNVERIFIED and still refuses to stamp the version marker, because an install
#   that was never proven must not be able to claim it is current.
if [ "$DRY_RUN" = "1" ]; then
  if [ "$DO_VERIFY" = "1" ]; then
    info "[DRY] Would verify the install by RUNNING check-no-pii.sh --selftest (~80 s)."
    # `[ cond ] && cmd` standing alone leaks status 1 under `set -e` (see the note at the
    # settings.json step). An if-block cannot.
    if [ "$DEEP_VERIFY" = "1" ]; then info "[DRY] Would also run governance-selftest.sh (~2 min)."; fi
  else
    warn "[DRY] Would SKIP verification (--no-verify) and would NOT stamp the version."
  fi
elif [ "$DO_VERIFY" = "0" ]; then
  # A kill switch that still fails the run is not a kill switch, it is a nag. Skipping is a
  # deliberate human choice: it completes normally, stamps, and exits 0. The gate is the
  # DEFAULT path being armed, not the impossibility of opting out. What it does NOT get is
  # silence -- the warning prints here AND as its own line in the closing summary, so "this
  # machine was never proven" is readable in the transcript instead of inferred from absence.
  VERIFY_SKIPPED=1
  warn "Post-install verification SKIPPED (--no-verify / GOV_INSTALL_VERIFY=0)."
  warn "NOTHING was executed. This install is UNVERIFIED: the files are present, and that is"
  warn "the exact claim that was green over a broken tree on 2026-08-30. Run it when you can:"
  warn "    bash $CLAUDE_HOME/hooks/governance/check-no-pii.sh --selftest"
else
  header "Verifying the install (executing, not just checking files)"

  VERIFY_TIMEOUT="${GOV_INSTALL_VERIFY_TIMEOUT:-600}"
  # `timeout` is not universally present (busybox, some minimal images). Missing it
  # must not turn into a silent hang and must not turn into a silent skip.
  if command -v timeout >/dev/null 2>&1; then
    RUN_BOUNDED() { timeout "$VERIFY_TIMEOUT" "$@"; }
  else
    warn "coreutils 'timeout' not found — verification will run unbounded."
    RUN_BOUNDED() { "$@"; }
  fi

  verify_one() {
    # $1 = human label, $2 = script path, $3.. = args
    v_label="$1"; v_script="$2"; shift 2
    if [ ! -f "$v_script" ]; then
      error "$v_label: MISSING at $v_script — the install did not put it there."
      VERIFY_FAILED=1
      return 0
    fi
    info "$v_label: running $v_script $* ..."
    # Under `set -e` a bare `VAR="$(failing-cmd)"` aborts the script before $? can be read,
    # so a RED selftest would surface as install.sh dying with no verdict. The && || form
    # is a condition context and is therefore exempt.
    v_rc=0
    v_out="$(RUN_BOUNDED bash "$v_script" "$@" 2>&1)" || v_rc=$?
    if [ "$v_rc" -eq 0 ]; then
      success "$v_label: PASS"
      printf '%s\n' "$v_out" | tail -2
    elif [ "$v_rc" -eq 124 ]; then
      error "$v_label: TIMED OUT after ${VERIFY_TIMEOUT}s — treated as RED, not as a pass."
      error "If this machine is simply slow: GOV_INSTALL_VERIFY_TIMEOUT=1800 bash install.sh"
      VERIFY_FAILED=1
    else
      error "$v_label: FAILED (exit $v_rc)"
      printf '%s\n' "$v_out" | tail -25
      VERIFY_FAILED=1
    fi
    return 0
  }

  verify_one "PII scanner selftest" "$CLAUDE_HOME/hooks/governance/check-no-pii.sh" --selftest

  if [ "$DEEP_VERIFY" = "1" ]; then
    verify_one "Governance selftest" "$CLAUDE_HOME/hooks/governance/governance-selftest.sh"
  else
    info "Deep verification skipped (add --deep-verify to also run governance-selftest.sh)."
  fi

  if [ "$VERIFY_FAILED" = "1" ]; then
    INSTALL_DEGRADED=1
    echo ""
    error "POST-INSTALL VERIFICATION FAILED — the installed framework does not work."
    error "This install is NOT usable as governance. Do not trust a green file listing over this."
    if [ -d "$BACKUP_DIR" ] && [ -n "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
      # The backup holds only what this run actually REPLACED (copy_safe backs up on
      # difference), so it is usually a subset — list it rather than assuming a shape.
      error "RESTORE FROM THE BACKUP THIS RUN MADE:"
      error "    $BACKUP_DIR"
      error "    ls \"$BACKUP_DIR\"            # exactly what this run replaced"
      error "    cp -r \"$BACKUP_DIR\"/* \"$CLAUDE_HOME\"/   # put every one of them back"
    else
      error "This run replaced nothing, so there is no backup to restore — the bundle itself is bad."
      error "Re-install from a clean clone of the governance repo."
    fi
    error "Then re-run and read this section, not the file count."
  else
    success "Verification passed — the installed framework proves itself, not just its file list."
  fi
fi

# ── 7. Stamp the installed version (GENUINELY LAST — see below) ──────────────
# pre-session.sh reads this marker to decide whether a published release is newer. It is written
# after every install step precisely so a run that died partway through does NOT leave a marker
# claiming a version it does not have. An earlier revision of this file wrote it in section 3 of
# 6 while its own comment said "written last": a machine without Node would have been stamped
# v1.1.0 with the settings.json hook registration skipped, and then told it was up to date.
if [ "$DRY_RUN" = "1" ]; then
  # A preview that promises the opposite of the real run is worse than no preview. This branch
  # comes FIRST in the chain, so it has to repeat the two refusal conditions or it silently
  # reports success for a run that would warn, refuse to stamp and exit 1.
  if [ "$BUNDLE_VERSION" = "unknown" ]; then
    warn "[DRY] Would NOT stamp — this bundle carries no VERSION file. The real run would exit 1."
    INSTALL_DEGRADED=1   # so the preview's EXIT CODE mirrors the real run too, not just its text
  elif [ "$INSTALL_DEGRADED" = "1" ]; then
    warn "[DRY] Would NOT stamp — a step above would fail. The real run would exit 1."
  else
    info "[DRY] Would stamp version: $BUNDLE_VERSION -> $CLAUDE_HOME/.governance-version"
  fi
elif [ "$BUNDLE_VERSION" = "unknown" ]; then
  # NEVER stamp the literal "unknown". pre-session.sh rejects it as not-a-version and advises
  # "re-run install.sh --force", which would write "unknown" again — a nag loop with no exit but
  # the kill switch. No marker at all is the honest state, and gives the same advice once.
  warn "No bundle/VERSION found — version NOT stamped. Install from a clone of the repo (a clone always carries bundle/VERSION)."
  # This run DID overwrite hooks/skills/docs with content of unknown provenance, so a marker left
  # from an earlier install now describes files that are no longer there. Remove it — but BACK IT
  # UP first, exactly as --uninstall does. Deleting a record without keeping a copy is not a thing
  # this installer gets to do quietly.
  if [ -f "$CLAUDE_HOME/.governance-version" ]; then
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    cp "$CLAUDE_HOME/.governance-version" "$BACKUP_DIR/.governance-version" 2>/dev/null || true
    rm -f "$CLAUDE_HOME/.governance-version"
    warn "Removed the previous marker (backed up to $BACKUP_DIR) — it no longer describes what is installed."
  fi
  INSTALL_DEGRADED=1
elif [ "$INSTALL_DEGRADED" = "1" ]; then
  # Do NOT touch an existing marker here. The failed step may have nothing to do with the files on
  # disk — a settings.json merge failure on a machine whose settings.json is already correct is a
  # no-op — and deleting a valid marker turns a fully working machine into one that nags "no usable
  # version marker" at every session start, forever. Leaving the old value is the honest record:
  # this run did not complete, so the machine is still whatever it was before.
  if [ -f "$CLAUDE_HOME/.governance-version" ]; then
    warn "Version NOT updated to $BUNDLE_VERSION: a step above failed. The existing marker ($(gov_read_version_local)) is left untouched."
  else
    warn "Version NOT stamped: a step above failed, so this install cannot claim to be v$BUNDLE_VERSION. Fix the failure and re-run."
  fi
else
  printf '%s\n' "$BUNDLE_VERSION" > "$CLAUDE_HOME/.governance-version"
  success "Version stamped: $BUNDLE_VERSION"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
header "Installation Complete"

echo ""
printf "${BOLD}Installed components:${NC}\n"
printf "  ${GREEN}✓${NC} Hooks:     %s scripts in ~/.claude/hooks/\n" "$HOOKS_COUNT"
printf "  ${GREEN}✓${NC} Skills:    %s skills in ~/.claude/skills/\n" "$SKILL_COUNT"
printf "  ${GREEN}✓${NC} Docs:      %s governance documents in ~/.claude/docs/\n" "${DOCS_COUNT:-?}"
if [ "$NO_CLAUDE_MD" = "0" ]; then
  printf "  ${GREEN}✓${NC} CLAUDE.md: User-level instructions\n"
fi
if [ "$SETTINGS_FAILED" = "1" ]; then
  printf "  ${RED}✗${NC} Settings:  NOT registered — see the error above. The hooks will not run.\n"
else
  printf "  ${GREEN}✓${NC} Settings:  Hooks registered in settings.json\n"
fi
printf "  ${GREEN}✓${NC} Logs:      ~/.claude/logs/ directory ready\n"
if [ "$PII_NAMES_N" -gt 0 ] 2>/dev/null; then
  success "Name list: $PII_NAMES_N proper noun(s) in ~/.claude/.pii-names - NAME_DENY is ARMED"
else
  warn "Name list: ~/.claude/.pii-names is EMPTY - NAME_DENY does nothing."
  warn "           Every scan will print PASS with the one proper-noun rule switched off."
  warn "           Add the names of people, clients and private projects BEFORE you publish."
fi
if [ "$VERIFY_FAILED" = "1" ]; then
  printf "  ${RED}✗${NC} Verified:  NO — the installed framework FAILED its own selftest (see above)
"
elif [ "$VERIFY_SKIPPED" = "1" ]; then
  printf "  ${YELLOW}⚠${NC} Verified:  NOT CHECKED (--no-verify). Files are present; nothing was proven.
"
elif [ "$DRY_RUN" = "0" ]; then
  printf "  ${GREEN}✓${NC} Verified:  selftest executed and passed on the installed copy
"
fi

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
if [ "$INSTALL_DEGRADED" = "1" ]; then
  # A run that printed a red ✗ must not sign off as "ready", and must not exit 0 — a caller or a
  # CI step reading only the exit code would record a clean install.
  if [ "$DRY_RUN" = "1" ]; then
    # Mirror the real run's exit code. A preview whose exit status says "fine" for a run that
    # would exit 1 is the same lie as the message that used to say "Would stamp".
    error "[DRY] The real run would complete with FAILURES (see above) and exit 1."
  else
    error "Install completed with FAILURES (see above). Not stamped, not ready. Fix and re-run."
  fi
  exit 1
fi
success "Context Governance is ready."
