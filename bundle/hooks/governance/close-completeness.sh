#!/usr/bin/env bash
# close-completeness.sh — Context Governance hook (Stop event).
#
# BLOCKS the session close when the session changed CODE but never wrote the canonical
# records that are supposed to describe that change.
#
# WHY THIS EXISTS (root-caused 2026-07-27, from the hooks' own log):
#   end-session.sh enforces governance by comparing PLAN.md / MEMORY.md against
#   version.json. Projects WITHOUT a version.json hit its early-out:
#       [end-session] no version.json - skip version check
#   and it exits 0. On a project without one, that line appears at EVERY close, so close-time
#   enforcement had never run there even once. The result was exactly what the owner
#   reported: MEMORY.md untouched by the 07-22 / 07-23 / 07-24 closes, OPEN-PROBLEMS.md
#   eleven days and five ships stale, and Read_Before_Every_Render.md missing an owner
#   clarification despite a standing "refresh at EVERY close" mandate.
#
#   The old check was also the wrong QUESTION. Matching a version STRING says nothing
#   about whether this session's work was written down. This asks the question that
#   actually matters: did the files that must describe the work get touched?
#
# DETERMINISTIC BY CONSTRUCTION:
#   - "What changed" comes from GIT (commits since the session-start SHA + the working
#     tree), never from the model's recollection and never from mtimes. It therefore also
#     catches edits made by scripts, which the Edit/Write changes-log cannot see - the
#     governance docs were in fact rewritten by node scripts today, so a changes-log-based
#     check would have false-blocked.
#   - The required list is DECLARED in the project (docs/context/.close-required), not
#     inferred. A project states its own mandate.
#   - Proportionate: a session that changed no code owes nothing, and is not blocked.
#
# Config format (docs/context/.close-required), one entry per line:
#     <repo-relative-path>[<TAB><condition-regex>]
#   No condition  -> required whenever the session changed code.
#   With a regex  -> required only when a changed path matches it.
#   '#' comments and blank lines ignored. Prefix a path with '?' to WARN instead of BLOCK.
#
# Kill switch: GOVERNANCE_HOOKS=0
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }
gov_disabled && exit 0

PROJECT_ROOT="$(gov_find_project_root 2>/dev/null)"
[ -z "$PROJECT_ROOT" ] && PROJECT_ROOT="$PWD"

# NOTE (2026-09-01): these run HERE, before every early exit below, on purpose.
# Placed at the tail they were unreachable: this hook exits early when a session changed
# only documentation - which is exactly what a governance session does - so the checks
# added to catch governance drift would never have run on a governance session. A control
# behind a gate that skips it is the defect this whole file exists to report.
# ── Universal close-time integrity checks (added 2026-09-01) ────────────────────────────────
#
# These do NOT block. They exist because three defects of the same shape were found at the close
# of one session, none by any control, all by the owner asking "are you sure?" a fourth time.
# They are deliberately GENERIC: every governed project can grow a legacy-named prompt, let a
# self-declared count drift from reality, or accumulate dead [[links]]. Nothing project-specific
# belongs here — that is what made governance-selftest.sh unwireable.
#
# THE VERDICT WORD CARRIES THE RESULT. A caveat printed above a "PASS" is read as noise: a PII
# scanner announced "name list: none" on every run and three review rounds passed the tree anyway
# (gotcha #348). So when anything below fires, the final line says PASS-WITH-WARNINGS, never PASS.
_CC_WARN=""
_cc_warn() { _CC_WARN="${_CC_WARN}
  [!] $1"; }

# 1. A next-session prompt outside the one canonical path, or under a legacy name.
#    The Lite staleness check only stat()s docs/context/NEXT-SESSION-PROMPT.md, so a drifted copy
#    is invisible to it — and a stale one instructs its reader to adopt a dead goal.
if [ -n "${PROJECT_ROOT:-}" ] && [ -d "$PROJECT_ROOT" ]; then
  _cc_strays="$(find "$PROJECT_ROOT" -maxdepth 3 -type f \
      \( -name 'NEXT-SESSION-*.md' -o -name 'NEXT_SESSION_*.md' \) \
      -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null \
    | grep -v '/docs/context/NEXT-SESSION-PROMPT\.md$' || true)"
  if [ -n "$_cc_strays" ]; then
    _cc_warn "next-session prompt outside the canonical path:$(printf '%s' "$_cc_strays" | sed 's|^|\n        |')
        Canonical is docs/context/NEXT-SESSION-PROMPT.md, exactly one per project. A drifted or
        legacy-named copy is invisible to the staleness check and can hand the next session a
        dead goal. Relocate or delete it deliberately — do not leave two."
  fi

  # 2. A file that declares its own entry count, where the declaration disagrees with reality.
  #    Generic: any docs/context/*.md carrying `total_entries:` in frontmatter.
  for _cc_f in "$PROJECT_ROOT"/docs/context/*.md; do
    [ -f "$_cc_f" ] || continue
    _cc_decl="$(grep -m1 -E '^total_entries:[[:space:]]*[0-9]+' "$_cc_f" 2>/dev/null | grep -oE '[0-9]+' || true)"
    [ -n "$_cc_decl" ] || continue
    _cc_real="$(grep -cE '^(#{1,6} )?[0-9]+\.' "$_cc_f" 2>/dev/null || echo 0)"
    if [ "$_cc_decl" != "$_cc_real" ]; then
      _cc_warn "$(basename "$_cc_f") declares total_entries: $_cc_decl but $_cc_real entries are present.
        A file that states its own size and is wrong about it teaches every reader to trust a
        number nobody recomputes."
    fi
  done
fi

# 3. Dead [[wiki-links]] in the agent's own memory for THIS project.
#    A link to a file that does not exist is a pointer the next session will follow into nothing —
#    the same defect as a stale prompt, one layer down. Hyphen and underscore spellings both
#    resolve, because a repair that handled only one spelling reported zero broken while two
#    remained (gotcha #351).
_cc_key="$(printf '%s' "${PROJECT_ROOT:-}" | tr 'A-Z' 'a-z' | tr ':\\/' '---' | sed 's|^-*||')"
_cc_mem="$HOME/.claude/projects/$_cc_key/memory"
if [ -d "$_cc_mem" ]; then
  _cc_dead=""
  for _cc_mf in "$_cc_mem"/*.md; do
    [ -f "$_cc_mf" ] || continue
    for _cc_l in $(grep -oE '\[\[[a-z0-9_-]+\]\]' "$_cc_mf" 2>/dev/null | tr -d '[]' | sort -u); do
      _cc_t="$(printf '%s' "$_cc_l" | tr '-' '_')"
      [ -f "$_cc_mem/$_cc_t.md" ] || _cc_dead="$_cc_dead $_cc_l"
    done
  done
  if [ -n "$_cc_dead" ]; then
    _cc_warn "memory has dead [[links]]:$(printf '%s' "$_cc_dead" | tr ' ' '\n' | sed '/^$/d' | sort -u | sed 's|^|\n        |')
        Either write the memory the link names, or repoint it. A dangling link is a promise the
        next session cannot collect."
  fi
fi

if [ -n "$_CC_WARN" ]; then
  gov_log "close-completeness" "integrity warnings"
  printf '[close-completeness] INTEGRITY WARNINGS (these do not block):%b
' "$_CC_WARN" >&2
  printf '[close-completeness] These are the three shapes that got past four independent
' >&2
  printf '[close-completeness] reviews on 2026-09-01. Silence with GOVERNANCE_HOOKS=0.
' >&2
fi

[ -f "$PROJECT_ROOT/docs/context/CONTEXT-MANIFEST.md" ] || { gov_log "close-completeness" "not governed - skip"; exit 0; }
[ -d "$PROJECT_ROOT/.git" ] || { gov_log "close-completeness" "not a git repo - skip"; exit 0; }

ROLE=$(gov_detect_role "$PROJECT_ROOT")
[ "$ROLE" = "SOURCE" ] || { gov_log "close-completeness" "role=$ROLE - skip"; exit 0; }

# Overridable so tests never touch the live control file. The first version of the test
# harness wrote the SHARED stamp and only restored it when a backup happened to exist, so
# it left a THROWAWAY repo's SHA behind - and this hook then blocked a real session on a
# range that did not exist here. A test that can break production is itself the collision.
START_FILE="${GOV_SESSION_START_FILE:-$(gov_state_file .gov-session-start)}"
START_SHA=""
START_ROOT=""
if [ -f "$START_FILE" ]; then
  START_SHA=$(grep -o '^[0-9a-f]\{7,40\}' "$START_FILE" 2>/dev/null | head -1)
  START_ROOT=$(awk 'NR==1{ $1=""; $2=""; sub(/^[[:space:]]+/,""); print }' "$START_FILE" 2>/dev/null)
fi

# No start marker means we cannot tell this session's work from history. Silence is the
# only honest answer - guessing a range would block on someone else's commits.
if [ -z "$START_SHA" ]; then
  gov_log "close-completeness" "no session-start SHA - skip (cannot scope the diff)"
  exit 0
fi

# The stamp must actually belong to THIS repo. A SHA from another repository (or a rebased
# away commit) makes every `git diff` return nothing, which reads as "no file was written"
# and blocks a session that did everything right. Refuse to judge instead.
if ! (cd "$PROJECT_ROOT" && git cat-file -e "${START_SHA}^{commit}" 2>/dev/null); then
  gov_log "close-completeness" "session-start SHA $START_SHA not in this repo - skip"
  exit 0
fi
if [ -n "$START_ROOT" ] && [ "$(cd "$START_ROOT" 2>/dev/null && pwd)" != "$(cd "$PROJECT_ROOT" && pwd)" ]; then
  gov_log "close-completeness" "session-start stamped for $START_ROOT, now in $PROJECT_ROOT - skip"
  exit 0
fi

COMMITTED=$( cd "$PROJECT_ROOT" && git diff --name-only "$START_SHA" HEAD 2>/dev/null | sed 's#\\#/#g' | sort -u | grep -v '^$' )
CHANGED=$( { printf '%s\n' "$COMMITTED"; \
             cd "$PROJECT_ROOT" && git status --porcelain 2>/dev/null | sed 's/^...//' | sed 's/.* -> //'; \
           } | sed 's#\\#/#g' | sort -u | grep -v '^$' )

# Subtract the working tree that was ALREADY dirty when the session began (bug fixed
# 2026-07-27). The start SHA scopes the COMMIT half of the range; nothing scoped the
# WORKING-TREE half, so a previous session's leftovers - a crash leaves untracked artifacts
# behind - were read as this session's code and blocked a session that had written nothing.
# That block is permanent by construction: the leftovers stay leftover, so every later
# session inherits it until a human cleans the tree.
#
# A baselined path is dropped only when its snapshot line is byte-identical (same status,
# same size) AND it is not part of a commit made this session - so a leftover that this
# session actually edited, or committed, still counts. Missing baseline = pre-fix behaviour.
DIRTY_FILE="${GOV_SESSION_DIRTY_FILE:-$(gov_state_file .gov-session-dirty)}"
if [ -s "$DIRTY_FILE" ] && [ -n "$CHANGED" ]; then
  PREEXISTING=$(comm -12 \
      <(gov_dirty_snapshot "$PROJECT_ROOT" | sort -u) \
      <(sort -u "$DIRTY_FILE" 2>/dev/null) \
    2>/dev/null | cut -f3- | grep -v '^$' | sort -u)
  if [ -n "$PREEXISTING" ]; then
    CARRIED=$(comm -23 <(printf '%s\n' "$PREEXISTING") <(printf '%s\n' "$COMMITTED") 2>/dev/null | grep -v '^$')
    if [ -n "$CARRIED" ]; then
      CHANGED=$(comm -23 <(printf '%s\n' "$CHANGED") <(printf '%s\n' "$CARRIED" | sort -u) 2>/dev/null | grep -v '^$')
      gov_log "close-completeness" "excluded $(printf '%s\n' "$CARRIED" | grep -c '^') path(s) already dirty at session start"
    fi
  fi
fi

[ -z "$CHANGED" ] && { gov_log "close-completeness" "no changes this session - nothing to document"; exit 0; }

# A session that only edited documentation owes no further documentation.
CODE_CHANGED=$(printf '%s\n' "$CHANGED" | grep -vE '^(docs/|Plans/|MDs/|.*\.md$)' | head -1)
if [ -z "$CODE_CHANGED" ]; then
  gov_log "close-completeness" "docs-only session - skip"
  exit 0
fi

CFG="$PROJECT_ROOT/docs/context/.close-required"
if [ ! -f "$CFG" ]; then
  # Fallback so an un-configured governed project still gets the two records that answer
  # "what happened" - the pair whose absence caused this hook to be written.
  CFG=$(mktemp 2>/dev/null) || exit 0
  printf 'Plans/PLAN.md\ndocs/context/MEMORY.md\n?docs/context/OPEN-PROBLEMS.md\n' > "$CFG"
  TMP_CFG=1
fi

MISSING_BLOCK=""
MISSING_WARN=""
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue;; esac
  path=$(printf '%s' "$line" | cut -f1 | sed 's/[[:space:]]*$//')
  cond=$(printf '%s' "$line" | cut -f2 -s | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  warn_only=0
  case "$path" in '?'*) warn_only=1; path="${path#\?}";; esac
  [ -z "$path" ] && continue

  # Conditional entries only apply when the session touched the area they guard.
  if [ -n "$cond" ]; then
    printf '%s\n' "$CHANGED" | grep -qE "$cond" || continue
  fi

  # SUBSTANCE, not mere modification. end-session.sh runs sync-governance.sh BEFORE its own
  # checks, and that does `sed -i` on Plans/PLAN.md and docs/context/MEMORY.md to fix version
  # lines. Since this hook is registered last on Stop, those edits land first - so a
  # "was it touched?" test would be satisfied by a machine rewriting one line, and would pass
  # while the session's work went unrecorded. That is precisely the empty compliance this
  # hook exists to prevent. PLAN and MEMORY are append-only by contract, so a real entry
  # GROWS the file; an in-place sed does not.
  grown=0
  if printf '%s\n' "$CHANGED" | grep -qxF "$path"; then
    stat_line=$(cd "$PROJECT_ROOT" && git diff --numstat "$START_SHA" -- "$path" 2>/dev/null | head -1)
    add=$(printf '%s' "$stat_line" | cut -f1); del=$(printf '%s' "$stat_line" | cut -f2)
    case "$add$del" in *[!0-9]*|'') add=0; del=0;; esac
    [ "$add" -gt "$del" ] && grown=1
  fi

  if [ "$grown" -eq 0 ]; then
    if [ "$warn_only" -eq 1 ]; then
      MISSING_WARN="${MISSING_WARN}\n  - $path"
    else
      MISSING_BLOCK="${MISSING_BLOCK}\n  - $path"
    fi
  fi
done < "$CFG"
[ "${TMP_CFG:-0}" = "1" ] && rm -f "$CFG"

if [ -n "$MISSING_WARN" ]; then
  gov_log "close-completeness" "WARN not updated:$(printf '%b' "$MISSING_WARN" | tr '\n' ' ')"
  printf '[GOVERNANCE ADVISORY] These canonical files were NOT updated this session:%b\n' "$MISSING_WARN"
fi

if [ -n "$MISSING_BLOCK" ]; then
  gov_log "close-completeness" "BLOCKED missing:$(printf '%b' "$MISSING_BLOCK" | tr '\n' ' ')"
  gov_notify "סגירת סשן" "קבצי תיעוד קנוניים לא עודכנו בסשן הזה." "/live-state-orchestrator"
  printf "[close-completeness] BLOCKED - this session changed code but not its canonical records.\n" >&2
  cat <<ENDMSG

[GOVERNANCE-ENFORCEMENT] Session stop BLOCKED by close-completeness.

This session changed code, but these canonical files were never written:$(printf '%b' "$MISSING_BLOCK")

This is the failure the owner reported on 2026-07-27: several recent closes wrote code and
skipped the records that describe it, so the canonical files fell days behind reality.

Required before stopping:
  1. governance-guard.sh protects docs/context/{MEMORY,OPEN-PROBLEMS,HANDOFF,GOTCHAS}.md and
     will REFUSE the edit without a fresh success token. Mint one first, or you will loop:
       bash ~/.claude/hooks/governance/commit-task-success.sh "<what you completed>"
     (Plans/PLAN.md is not protected and needs no token.)
  2. Run /live-state-orchestrator, which writes each of the files above.
  3. Record what THIS session actually did - a milestone entry in PLAN.md, and any durable
     decision or lesson in MEMORY.md. Append; never overwrite an existing entry.
  4. Stop again. This hook re-reads git, so a real write clears it and a no-op does not.

A TOUCH WILL NOT CLEAR THIS. The check requires the file to GROW (added lines > deleted),
because these records are append-only and because another hook rewrites version lines in
place - counting that as compliance is exactly how the drift stayed invisible.

Override (user only): GOVERNANCE_HOOKS=0

ENDMSG
  exit 2
fi

gov_log "close-completeness" "passed - canonical records updated"
exit 0
