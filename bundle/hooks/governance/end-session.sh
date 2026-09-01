#!/usr/bin/env bash
# end-session.sh — Context Governance ENFORCEMENT hook (Stop event)
# BLOCKS session stop if governance files are stale.
#
# Phase 4 (2026-04-11): passive reminder ("please run /live-state-orchestrator")
# Phase 5+ (2026-04-12): blocking enforcement (exit 2 + detailed directives).
#
# Checks:
#   1. PLAN.md version matches version.json
#   2. MEMORY.md version matches version.json
#   3. A handoff exists for the current version (or is pointed to by HANDOFF.md)
#
# On failure: exit 2 (blocks stop) + stderr explains WHY blocked +
#   stdout gives the LLM EXACT instructions on what to fix.
#
# Kill switch: GOVERNANCE_HOOKS=0
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }
gov_disabled && exit 0

# ---------------------------------------------------------------------------
# LAST GATE BEFORE THE WORLD (armed 2026-09-01)
#
# The block at the bottom of this file does `cp -r <installer>/bundle/* <repo>/bundle/` and then
# commits and pushes to a PUBLIC repository. On 2026-09-01 that copy restored a pre-sanitization
# bundle over a tree that four separate reviewers had certified clean, and pushed it. Nothing
# looked at the bytes between the copy and the push.
#
# WHAT IS SCANNED: the STAGED SET, taken from git itself (`git diff --cached --name-only`) after
# the copy and after `git add`. That is not a compromise for speed - it is the exact set that
# `git push` can publish. A file left dirty in the working tree cannot reach the remote; a file
# in the index can, and every one of them is scanned before the commit is written.
#
# WHY NOT THE WHOLE TREE: measured 2026-09-01 on this machine, `check-no-pii.sh --tree` over the
# 91-file bundle takes 14 min 49 s. A 15-minute block on every session close would be switched
# off inside a week, and a switched-off gate is how this leak happened in the first place. The
# staged set is typically 1-15 files and is filtered by the same two-stage prefilter used by
# sync-governance-copies.sh, so the common close costs about a second.
#
# FAILURE DIRECTION: any outcome that is not a clean verdict - contamination, a missing scanner,
# a scanner that returns something unexpected - ABORTS the push and KEEPS the push flag, so
# nothing is lost and the next session retries. "It must never push a tree it has not just
# scanned" means a scan that cannot run is a reason not to push, not a reason to continue.
#
# Kill switch: GOV_PII_GATE=0 (pushes UNSCANNED) - GOVERNANCE_HOOKS=0 (no governance at all).
#
# KEEP IN SYNC with the identical helpers in sync-governance-copies.sh. They are duplicated
# rather than shared because both files ship standalone in the installer bundle.
# ---------------------------------------------------------------------------
PII_SCANNER="${GOV_PII_SCANNER:-$SCRIPT_DIR/check-no-pii.sh}"
PII_UNION_CACHE="$HOME/.claude/logs/.gov-pii-union.cache"
PII_UNION_SIG="$HOME/.claude/logs/.gov-pii-union.sig"
PII_NAMES_FILE="${GOV_PII_NAMES:-$HOME/.claude/.pii-names}"
PII_DENY_FILE="${GOV_PII_DENYLIST:-$HOME/.claude/.governance-pii-denylist}"
DIVERGENCE_LOG="$HOME/.claude/logs/.governance-bundle-divergence"
PII_REPORT=""
PII_CAND=""

gov_pii_gate_off() { [ "${GOV_PII_GATE:-1}" = "0" ]; }

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
  n_expect=$(grep -E '^RULES=' "$PII_SCANNER" 2>/dev/null | head -1 | sed -e 's/^RULES=//' -e 's/"//g' | wc -w | tr -d ' ')
  if [ -z "$n_have" ] || [ -z "$n_expect" ] || [ "$n_expect" -lt 1 ] 2>/dev/null || [ "$n_have" -ne "$n_expect" ] 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null; return 1
  fi
  mkdir -p "$(dirname "$PII_UNION_CACHE")" 2>/dev/null
  mv -f "$tmp" "$PII_UNION_CACHE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  printf '%s' "$sig" > "$PII_UNION_SIG" 2>/dev/null
  printf '%s' "$PII_UNION_CACHE"; return 0
}

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
#   0 = clean - 2 = contaminated ($PII_REPORT, $PII_CAND) - 3 = the gate itself is unusable
_pii_scan() {
  local uf lf f g rc out
  local -a cand
  cand=()
  PII_REPORT=""; PII_CAND=""
  if [ ! -f "$PII_SCANNER" ]; then
    PII_REPORT="check-no-pii.sh is MISSING at $PII_SCANNER - there is no scanner to push behind."
    return 3
  fi
  uf="$(_pii_union_file)" || uf=""
  lf="$(_pii_list_file)" || lf=""
  for f in "$@"; do
    [ -f "$f" ] || continue
    if [ ! -r "$f" ] || [ -z "$uf" ]; then cand[${#cand[@]}]="$f"; continue; fi
    grep -qEf "$uf" -- "$f" 2>/dev/null; g=$?
    # 0 = a PII shape is present -> stage 2. 1 = none -> cleared. ANYTHING ELSE is grep failing
    # to answer, and a prefilter that cannot answer must escalate, never clear. (Measured
    # 2026-09-01: this platform's grep SIGABRTs on `-i -F -f`; the crash read as "no match".)
    if [ "$g" -ne 1 ]; then cand[${#cand[@]}]="$f"; continue; fi
    if [ -n "$lf" ]; then
      tr 'A-Z' 'a-z' < "$f" 2>/dev/null | grep -qFf "$lf" 2>/dev/null; g=$?
      if [ "$g" -ne 1 ]; then cand[${#cand[@]}]="$f"; continue; fi
    fi
  done
  [ -n "$lf" ] && rm -f "$lf" 2>/dev/null
  PII_CAND="${cand[*]}"
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
  return "$rc"
}

# --- Step 0: Run sync-governance.sh to auto-fix version/count drift ---
# This runs BEFORE checks, so mechanical drift is fixed automatically.
# Only handoff (which requires LLM content) can't be auto-fixed.
if [ -f "$SCRIPT_DIR/sync-governance.sh" ]; then
  bash "$SCRIPT_DIR/sync-governance.sh" 2>/dev/null || true
fi

# --- Detect project root (walk up to find CLAUDE.md) ---
PROJECT_ROOT="$PWD"
if [ ! -f "$PROJECT_ROOT/CLAUDE.md" ]; then
  d="$PROJECT_ROOT"
  while [ "$d" != "/" ] && [ "$d" != "" ]; do
    if [ -f "$d/CLAUDE.md" ]; then PROJECT_ROOT="$d"; break; fi
    d="$(dirname "$d")"
  done
fi

# --- Only governed projects ---
if [ ! -f "$PROJECT_ROOT/docs/context/CONTEXT-MANIFEST.md" ]; then
  gov_log "end-session" "not governed — skip"
  exit 0
fi

# --- Node-role gate (Framework v2, 2026-04-21) ---
# SOURCE     → full enforcement (default, historical behavior)
# DEPLOYMENT → file-exist check only, no version enforcement
#              (version.json on DEPLOYMENT is a receipt that lags SOURCE until UPDATE.bat)
# FROZEN     → silent exit 0 (no hooks fire)
NODE_ROLE=$(gov_detect_role "$PROJECT_ROOT")
if [ "$NODE_ROLE" = "FROZEN" ]; then
  gov_log "end-session" "FROZEN node — silent exit"
  exit 0
fi
if [ "$NODE_ROLE" = "DEPLOYMENT" ]; then
  # Deployment targets receive state via UPDATE.bat zipball.
  # We only verify canonical files EXIST and are parseable.
  # No version match. No handoff existence enforcement for current version.json.
  MISSING=""
  [ ! -f "$PROJECT_ROOT/Plans/PLAN.md" ] && MISSING="$MISSING PLAN.md"
  [ ! -f "$PROJECT_ROOT/docs/context/MEMORY.md" ] && MISSING="$MISSING MEMORY.md"
  [ ! -f "$PROJECT_ROOT/docs/context/HANDOFF.md" ] && MISSING="$MISSING HANDOFF.md"
  if [ -n "$MISSING" ]; then
    gov_log "end-session" "DEPLOYMENT missing canonical files:$MISSING"
    # Don't block — just log. UPDATE.bat will restore them.
  fi
  gov_log "end-session" "DEPLOYMENT passive check — OK"
  exit 0
fi

# --- SOURCE role: full enforcement below ---

# --- Check 0 (version-INDEPENDENT): was a handoff refreshed for the work done this session? ---
# This is the universal safety net. The version.json checks below are skipped on projects
# that have no version.json — leaving them with NO handoff enforcement. This gate closes that
# hole: if meaningful work happened this session but docs/context/HANDOFF.md was never written,
# block the stop and direct the LLM to run /live-state-orchestrator.
# Signal: ~/.claude/logs/.gov-session-changes (append-only paths, reset each SessionStart).
CHANGES_LOG="$(gov_state_file .gov-session-changes)"
if [ -f "$CHANGES_LOG" ]; then
  SESSION_WRITES=$(grep -c . "$CHANGES_LOG" 2>/dev/null | tr -d ' ')
  [ -z "$SESSION_WRITES" ] && SESSION_WRITES=0
  HANDOFF_REFRESHED=0
  # Match ANY handoff filename, not just the bare pointer. Real handoffs this project
  # writes include HANDOFF.md, HANDOFF-v1.4.194.md and HANDOFF-2026-08-25-token-economy-design.md;
  # the old 'HANDOFF\.md' pattern matched only the first, so a session that wrote a versioned
  # handoff was still BLOCKED as "handoff not refreshed". [^/\\] keeps it to the basename.
  grep -qiE 'HANDOFF[^/\\]*\.md' "$CHANGES_LOG" 2>/dev/null && HANDOFF_REFRESHED=1
  # Threshold: 3+ writes = real work (avoids blocking trivial 1-2 edit / conversation-only sessions).
  if [ "$SESSION_WRITES" -ge 3 ] && [ "$HANDOFF_REFRESHED" -eq 0 ]; then
    gov_log "end-session" "BLOCKED (version-independent): $SESSION_WRITES session writes, HANDOFF.md NOT refreshed"
    gov_notify \
      "שער שמירה" \
      "נעשתה עבודה בסשן אך HANDOFF לא עודכן. הרץ /live-state-orchestrator לפני סגירה." \
      "/live-state-orchestrator"
    printf "[end-session] BLOCKED — %s file writes this session but HANDOFF.md was not refreshed.\n" "$SESSION_WRITES" >&2
    cat <<ENDMSG

[GOVERNANCE-ENFORCEMENT] Session stop BLOCKED. This session made ${SESSION_WRITES} file writes, but docs/context/HANDOFF.md was not refreshed.

Required BEFORE you can stop:
  Run /live-state-orchestrator — it updates Plans/PLAN.md, docs/context/MEMORY.md, and docs/context/OPEN-PROBLEMS.md, writes a fresh docs/context/HANDOFF.md reflecting THIS session's work, and manages the handoff lifecycle (active -> consumed -> archived).

After a new HANDOFF.md is written, try stopping again — this hook re-checks.
If this is a genuine false positive (the session did no state-changing work), override with: GOVERNANCE_HOOKS=0
ENDMSG
    exit 2
  fi
fi

# --- Need version.json to compare ---
if [ ! -f "$PROJECT_ROOT/version.json" ]; then
  gov_log "end-session" "no version.json — skip version check"
  exit 0
fi

# --- Extract current version from version.json ---
# Strip trailing dots from greedy [0-9.]* match via sed
VJ_VER=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PROJECT_ROOT/version.json" 2>/dev/null \
  | grep -o '[0-9][0-9.]*' | sed 's/\.$//' | head -1)
if [ -z "$VJ_VER" ]; then
  gov_log "end-session" "could not parse version.json — skip (fail-soft)"
  exit 0
fi

ISSUES=""
DIRECTIVES=""

# --- Check 1: PLAN.md version ---
if [ -f "$PROJECT_ROOT/Plans/PLAN.md" ]; then
  PLAN_VER=$(grep -o 'Project version:.*v[0-9][0-9.]*' "$PROJECT_ROOT/Plans/PLAN.md" 2>/dev/null \
    | grep -o '[0-9][0-9.]*' | sed 's/\.$//' | head -1)
  if [ -n "$PLAN_VER" ] && [ "$VJ_VER" != "$PLAN_VER" ]; then
    ISSUES="${ISSUES}\n  - Plans/PLAN.md says v${PLAN_VER}, version.json says v${VJ_VER}"
    DIRECTIVES="${DIRECTIVES}\n  (a) Update Plans/PLAN.md: change 'Project version: v${PLAN_VER}' to 'Project version: v${VJ_VER}'. Add milestone log entries for every version between v${PLAN_VER} and v${VJ_VER} (read git log to get details). Update sub-plan statuses if they changed."
  fi
fi

# --- Check 2: MEMORY.md version ---
if [ -f "$PROJECT_ROOT/docs/context/MEMORY.md" ]; then
  MEM_VER=$(grep -o 'Project version:.*v[0-9][0-9.]*' "$PROJECT_ROOT/docs/context/MEMORY.md" 2>/dev/null \
    | grep -o '[0-9][0-9.]*' | sed 's/\.$//' | head -1)
  if [ -n "$MEM_VER" ] && [ "$VJ_VER" != "$MEM_VER" ]; then
    ISSUES="${ISSUES}\n  - docs/context/MEMORY.md says v${MEM_VER}, version.json says v${VJ_VER}"
    DIRECTIVES="${DIRECTIVES}\n  (b) Update docs/context/MEMORY.md Active Summary: change version to v${VJ_VER}, update phase status, update active handoff reference, add any new durable decisions or lessons learned from this session."
  fi
fi

# --- Check 3: Handoff for current version ---
HANDOFF_EXISTS=0
if [ -f "$PROJECT_ROOT/docs/context/HANDOFF.md" ]; then
  # Extract version from the YAML points_to field specifically, not from Markdown body.
  # This avoids false matches on older version references in the file text.
  HANDOFF_POINTS=$(grep '^points_to:' "$PROJECT_ROOT/docs/context/HANDOFF.md" 2>/dev/null \
    | grep -o 'HANDOFF-v[0-9][0-9.]*' | grep -o '[0-9][0-9.]*' | sed 's/\.$//' | head -1)
  if [ -n "$HANDOFF_POINTS" ] && [ "$VJ_VER" = "$HANDOFF_POINTS" ]; then
    HANDOFF_EXISTS=1
  fi
fi
# Also check MDs/ directly for a handoff file with current version
if [ $HANDOFF_EXISTS -eq 0 ]; then
  if ls "$PROJECT_ROOT"/MDs/HANDOFF-v${VJ_VER}* 1>/dev/null 2>&1; then
    HANDOFF_EXISTS=1
  fi
fi
if [ $HANDOFF_EXISTS -eq 0 ]; then
  ISSUES="${ISSUES}\n  - No handoff found for v${VJ_VER} (docs/context/HANDOFF.md points to v${HANDOFF_POINTS:-unknown})"
  DIRECTIVES="${DIRECTIVES}\n  (c) Create a new handoff at MDs/HANDOFF-v${VJ_VER}.md with: session summary, current state, open work, exact next action, and read-these-first list. Then update docs/context/HANDOFF.md pointer to reference it. Archive the previous handoff to MDs/archive/ with status: consumed."
fi

# --- Enforce ---
if [ -n "$ISSUES" ]; then
  gov_log "end-session" "BLOCKED: governance stale — $(printf '%b' "$ISSUES" | tr '\n' ' ')"

  # Show popup notification for stale governance
  gov_notify \
    "שער שמירה" \
    "קבצי governance לא מעודכנים. יש לעדכן לפני סיום הסשן." \
    "/live-state-orchestrator"

  # stderr → shown as hook error (blocks the stop)
  printf "[end-session] BLOCKED — governance files are stale. Fix before stopping.\n" >&2

  # stdout → injected into LLM context as detailed instructions
  cat <<ENDMSG

[GOVERNANCE-ENFORCEMENT] Session stop BLOCKED. Governance files are out of date.

Current version (version.json): v${VJ_VER}

Problems found:
$(printf '%b' "$ISSUES")

Required actions BEFORE you can stop:
$(printf '%b' "$DIRECTIVES")

IMPORTANT:
- Edit this project's canonical files (docs/context/*.md, Plans/PLAN.md) — see docs/context/CONTEXT-MANIFEST.md for the exact paths.
- You need a governance success token to edit protected files:
    bash ~/.claude/hooks/governance/commit-task-success.sh "<description>"
- After fixing all issues, try stopping the session again. This hook will re-check.
- If you believe this is a false positive, the user can override with: GOVERNANCE_HOOKS=0

ENDMSG
  exit 2
fi

# --- All checks passed ---
gov_log "end-session" "passed — PLAN v${PLAN_VER:-?} MEMORY v${MEM_VER:-?} HANDOFF v${HANDOFF_POINTS:-?} == version.json v${VJ_VER}"

# --- Check for unreleased commits (advisory — recommend /full-finish) ---
# Detect commits after the last version.json bump (the release commit).
# Tags aren't synced locally, so we find the commit that last changed version.json.
# Excludes "Build EXE for v*" commits — those ARE part of the release.
if [ -d "$PROJECT_ROOT/.git" ]; then
  LAST_VER_COMMIT=$(cd "$PROJECT_ROOT" && git log -1 --format='%H' -- version.json 2>/dev/null)
  if [ -n "$LAST_VER_COMMIT" ]; then
    # Count commits since version bump, excluding "Build EXE" release-completion commits
    UNRELEASED=$(cd "$PROJECT_ROOT" && git log --format='%s' "${LAST_VER_COMMIT}..HEAD" 2>/dev/null \
      | grep -vcE '^Build EXE for v[0-9]' 2>/dev/null | tr -d ' ')
    # grep -vc returns 1 when no lines match; normalize empty → 0
    [ -z "$UNRELEASED" ] && UNRELEASED=0
    if [ "$UNRELEASED" -gt 0 ]; then
      gov_log "end-session" "ADVISORY: $UNRELEASED unreleased commits since v${VJ_VER} version bump"
      gov_notify \
        "שחרור גרסה" \
        "${UNRELEASED} קומיטים לא שוחררו מאז v${VJ_VER}. מומלץ להריץ שחרור." \
        "/full-finish"
      echo "[GOVERNANCE ADVISORY] $UNRELEASED commits since v${VJ_VER} version bump have not been released. Consider running /full-finish before ending the session."
    fi
  fi
fi

# --- Auto-push governance changes to GitHub if pending ---
PUSH_FLAG="$HOME/.claude/logs/.governance-push-pending"

# A copy refused earlier in the session by sync-governance-copies.sh means the bundle is NOT
# what the live tree says it is. Surface it HERE, at the moment of publication, because that is
# the moment the divergence matters: whatever is about to be pushed is missing those files.
if [ -s "$DIVERGENCE_LOG" ]; then
  _DIV_N=$(grep -c 'REFUSED' "$DIVERGENCE_LOG" 2>/dev/null | tr -d ' ')
  [ -z "$_DIV_N" ] && _DIV_N=0
  if [ "$_DIV_N" -gt 0 ] 2>/dev/null; then
    gov_log "end-session" "ADVISORY: $_DIV_N bundle copy/copies were refused this session - bundle is behind the live tree"
    echo "[GOVERNANCE-PII-GATE] ADVISORY: $_DIV_N governance file(s) were REFUSED entry to the installer"
    echo "  bundle this session, so the bundle is BEHIND the live tree and the push below will not"
    echo "  carry them. Record: $DIVERGENCE_LOG"
    grep 'REFUSED' "$DIVERGENCE_LOG" 2>/dev/null | tail -10 | sed 's/^/    /'
    echo "  Clean the DATA in those files (placeholder + ~/.claude/.governance-local.env), save them"
    echo "  again to re-trigger the sync hook, and the divergence clears itself."
  fi
fi

if [ -f "$PUSH_FLAG" ]; then
  # Overridable so this publish path can be exercised end-to-end against a throwaway repo
  # instead of the real public one. A gate nobody can rehearse is a gate nobody trusts.
  INSTALLER_REPO="${GOV_INSTALLER_REPO:-$HOME/.claude/governance-installer}"
  # Machine-local overrides (GOV_REPO_PATH, GOV_GIT_AUTHOR_*) live in a gitignored env file so
  # that no machine path or identity is carried by this script, which ships in a PUBLIC bundle.
  if [ -f "$HOME/.claude/.governance-local.env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.claude/.governance-local.env" 2>/dev/null || true
  fi
  # Checkout of the PUBLIC framework repo that governance files are mirrored into. NEVER a
  # baked machine path: this hook ships in that same public bundle, so a hardcoded checkout
  # directory is both an identity leak and wrong on every other machine. Override with
  # GOV_REPO_PATH (e.g. in ~/.claude/.governance-local.env); the default is a plain $HOME dir
  # that the clone below will create if it does not exist yet.
  GH_REPO="${GOV_REPO_PATH:-$HOME/claude-code-governance}"

  # Clone if not present, or pull if exists
  if [ ! -d "$GH_REPO/.git" ]; then
    git clone "https://github.com/Gold-b/claude-code-governance.git" "$GH_REPO" 2>/dev/null
  fi

  if [ -d "$GH_REPO/.git" ] && [ -d "$INSTALLER_REPO/bundle" ]; then
    # Sync installer bundle -> git repo (working tree); staging below is per-file
    gov_dry || cp -r "$INSTALLER_REPO/bundle/"* "$GH_REPO/bundle/" 2>/dev/null
    gov_dry || cp "$INSTALLER_REPO/install.sh" "$GH_REPO/install.sh" 2>/dev/null
    gov_dry || cp "$INSTALLER_REPO/verify.sh" "$GH_REPO/verify.sh" 2>/dev/null

    # Run git operations in a subshell to avoid changing the main script's CWD
    (
      cd "$GH_REPO" || exit 1
      if gov_dry; then echo "[GOVERNANCE DRY-RUN] end-session: would sync + push governance repo"; exit 0; fi
      # 1) never push over someone else's commit: rebase on origin first (fail-soft)
      if ! git pull --rebase --autostash origin master >/dev/null 2>&1; then
        git rebase --abort >/dev/null 2>&1 || true
        gov_log "end-session" "GitHub sync: pull --rebase failed (conflict?) — kept push flag for retry"
        echo "[GOVERNANCE] WARNING: governance repo pull --rebase failed; not pushing. Resolve in $GH_REPO." >&2
        # exit 3, not 0: the caller deletes $PUSH_FLAG on a 0, which threw away the retry this
        # very line claims to be keeping.
        exit 3
      fi
      # 2) stage ONLY the files named in the push flag (mapped into bundle/), plus install/verify if changed
      STAGED=0
      while IFS= read -r line; do
        f=$(printf '%s' "$line" | sed 's|^[^ ]* ||')
        [ -z "$f" ] && continue
        rel=""
        case "$f" in
          */.claude/hooks/governance/*) rel="bundle/hooks/governance/${f##*/.claude/hooks/governance/}" ;;
          */.claude/hooks/*)            rel="bundle/hooks/${f##*/.claude/hooks/}" ;;
          */.claude/skills/*)           rel="bundle/skills/${f##*/.claude/skills/}" ;;
          */.claude/docs/*)             rel="bundle/docs/${f##*/.claude/docs/}" ;;
          docs/*|hooks/*|skills/*)      rel="bundle/$f" ;;
          bundle/*)                     rel="$f" ;;
        esac
        [ -n "$rel" ] && [ -f "$rel" ] && git add "$rel" 2>/dev/null && STAGED=$((STAGED + 1))
      done < "$PUSH_FLAG"
      for extra in install.sh verify.sh; do
        git diff --quiet -- "$extra" 2>/dev/null || { git add "$extra" 2>/dev/null && STAGED=$((STAGED + 1)); }
      done
      if [ "$STAGED" -gt 0 ] && ! git diff --cached --quiet 2>/dev/null; then
        # ---- LAST GATE BEFORE THE WORLD -----------------------------------------------
        # Everything staged here is publishable by the `git push` below. Scan it now - after
        # the cp -r, after the git add - or do not push at all.
        if gov_pii_gate_off; then
          gov_log "end-session" "PII GATE DISABLED (GOV_PII_GATE=0) - pushing to the PUBLIC repo UNSCANNED"
          echo "[GOVERNANCE-PII-GATE] DISABLED (GOV_PII_GATE=0): pushing to the PUBLIC repo without a scan." >&2
        else
          _pii_args=()
          while IFS= read -r _sf; do
            [ -n "$_sf" ] && _pii_args[${#_pii_args[@]}]="$_sf"
          done <<GITEOF
$(git diff --cached --name-only 2>/dev/null)
GITEOF
          if [ ${#_pii_args[@]} -eq 0 ]; then
            _GATE_RC=0
          else
            echo "[GOVERNANCE-PII-GATE] scanning ${#_pii_args[@]} staged file(s) before pushing to the PUBLIC repo..."
            _pii_scan "${_pii_args[@]}"; _GATE_RC=$?
          fi
          if [ "$_GATE_RC" -ne 0 ]; then
            _rules=$(printf '%s\n' "$PII_REPORT" | grep -oE '\[[A-Z0-9_]+\]' | sort -u | tr -d '[]' | tr '\n' ' ' | sed 's/ $//')
            [ -n "$_rules" ] || _rules="(gate-error)"
            # Unstage exactly the offending files, so that a stray manual `git commit` in this
            # checkout cannot ship what this gate just refused. The working tree is untouched.
            printf '%s\n' "$PII_REPORT" | grep -oE '^[^ ]+:[0-9]+: \[' | sed 's/:[0-9]*: \[$//' | sort -u \
              | while IFS= read -r _bad; do [ -n "$_bad" ] && git reset -q -- "$_bad" 2>/dev/null; done
            printf '%s\tPUSH-ABORTED\t%s\t%s\trc=%s\n' "$(date -Iseconds 2>/dev/null || date)" \
              "$GH_REPO/bundle" "$_rules" "$_GATE_RC" >> "$DIVERGENCE_LOG" 2>/dev/null
            gov_log "end-session" "PUSH ABORTED by PII gate (rc=$_GATE_RC) rules=$_rules"
            gov_notify \
              "PII gate: push aborted" \
              "The governance push to the PUBLIC repo was aborted (rules: $_rules). Nothing was published; the push flag is kept and will retry." \
              ""
            {
              if [ "$_GATE_RC" -eq 3 ]; then
                echo "[GOVERNANCE-PII-GATE] PUSH ABORTED - the gate could not run, so nothing was pushed."
                echo "  reason : $PII_REPORT"
              else
                echo "[GOVERNANCE-PII-GATE] PUSH ABORTED - a staged file carries a real value."
                echo "  rules  : $_rules"
                printf '%s\n' "$PII_REPORT" | grep -E '^[^ ]+:[0-9]+: \[|^    -> ' | head -40
              fi
              echo "  repo   : $GH_REPO (PUBLIC)"
              echo "  state  : nothing committed, nothing pushed, offending paths unstaged,"
              echo "           push flag KEPT - the next session retries after the data is fixed."
              echo "  REMEDY : fix the DATA (placeholder in the tracked file, real value in"
              echo "           ~/.claude/.governance-local.env), then let the sync hook re-copy it."
              echo "  Bypass (pushes UNSCANNED): GOV_PII_GATE=0"
            } >&2
            exit 3
          fi
        fi
        # ---- /LAST GATE ---------------------------------------------------------------
        CHANGED_FILES=$(sed 's|.* ||' < "$PUSH_FLAG" | while IFS= read -r f; do basename "$f" 2>/dev/null; done | sort -u | tr '\n' ', ' | sed 's/,$//')
        # Commit identity comes from the machine-local config, NEVER from this file: this hook
        # ships in a PUBLIC bundle and a baked address is a real identity leaking into every
        # clone. Set GOV_GIT_AUTHOR_NAME / GOV_GIT_AUTHOR_EMAIL in ~/.claude/.governance-local.env
        # (see .governance-local.env.example). With neither those nor a git-configured identity we
        # fall back to a placeholder, because a governance push that dies on "please tell me who
        # you are" is a silent outage.
        if [ -z "${GOV_GIT_AUTHOR_EMAIL:-}" ] && [ -f "$HOME/.claude/.governance-local.env" ]; then
          # shellcheck disable=SC1091
          . "$HOME/.claude/.governance-local.env" 2>/dev/null || true
        fi
        _gname="${GOV_GIT_AUTHOR_NAME:-$(git config user.name 2>/dev/null)}"
        _gmail="${GOV_GIT_AUTHOR_EMAIL:-$(git config user.email 2>/dev/null)}"
        [ -n "$_gname" ] || _gname="claude-code-governance"
        [ -n "$_gmail" ] || _gmail="you@example.com"
        git -c user.name="$_gname" -c user.email="$_gmail" \
          commit -m "Auto-sync governance files: ${CHANGED_FILES:-updated}" 2>/dev/null
        if git push origin master 2>/dev/null; then
          gov_log "end-session" "GitHub push SUCCESS — Gold-b/claude-code-governance updated"
          echo "[GOVERNANCE] GitHub repo Gold-b/claude-code-governance auto-pushed."
        else
          gov_log "end-session" "GitHub push FAILED — will retry next session"
          echo "[GOVERNANCE] WARNING: GitHub push failed. Changes saved locally, will retry." >&2
          exit 3
        fi
      else
        gov_log "end-session" "GitHub repo already in sync — no push needed"
      fi
    )
    _PUSH_RC=$?
  fi

  # keep the flag when the push failed or the pull needs a human
  if [ "${_PUSH_RC:-0}" -eq 0 ] && ! gov_dry; then
    rm -f "$PUSH_FLAG"
  fi
fi

exit 0
