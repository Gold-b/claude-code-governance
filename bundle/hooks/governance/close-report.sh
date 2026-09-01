#!/usr/bin/env bash
# close-report.sh — the closing summary is GENERATED FROM the canonical record, never typed.
#
# WHY THIS EXISTS (2026-09-01 — "a report is the last action of a turn")
# ----------------------------------------------------------------------
#   At one session close the owner asked "is everything recorded?" eight times, and eight times
#   the answer was no. The WORK was never wrong: it was implemented, verified, usually proven by
#   mutation, and pushed. What went missing was the RECORD — and twice the thing not recorded was
#   the rule about recording.
#
#   The mechanism is structural, not carelessness. An assistant message is the TERMINAL action of
#   a turn: no tool call follows it. So anything identified WHILE WRITING the closing report has
#   no execution phase left and can only become prose. Measured over that whole session:
#       work discovered during tool use      -> done, every time (more calls followed)
#       work discovered while summarising    -> done 0 of 8 times
#
#   It is the framework's own recurring disease one layer up: verify.sh COUNTED files instead of
#   running them; a comment above an install glob DESCRIBED a lesson instead of enforcing it; a
#   closing summary STATES instead of writing. In all three an artifact that describes is
#   mistaken for one that acts.
#
#   A transcript-scanning detector was considered and rejected: it finds the symptom after the
#   fact, it adds false positives, and a noisy gate gets switched off — which is how controls die
#   here. This script is the INVERSION instead. Every line it prints is READ from a canonical file
#   or MEASURED by a command; there is no place in it for a sentence that is not in the record.
#       - something not in a file CANNOT appear in the report — there is nowhere to put it;
#       - something in the report IS proof it is in a file — it is the same read.
#   The gap is not caught. It has nowhere to exist.
#
#   The same shape already existed twice in this framework and was never applied to the report:
#   GENERATED-FACTS.md is produced BY the selftest so it cannot carry an unmeasured number, and
#   the copy-parity md5 comparison IS the assertion, so no separate claim can drift from it.
#
# WHAT IT READS — all relative to the project root taken from the hook PAYLOAD, never from $PWD
# ---------------------------------------------------------------------------------------------
#   docs/context/HANDOFF.md            the pointer: frontmatter + the newest recorded session entry
#   MDs/HANDOFF*.md, docs/context/*    every handoff whose frontmatter says `status: active` (TL;DR)
#   Plans/PLAN.md                      the version line + the newest milestone rows
#   docs/context/MEMORY.md             the newest dated entries of the Active Summary
#   ~/.claude/projects/<key>/memory/   the agent's auto-memory: files touched this session, dead links
#   docs/context/GOTCHAS.md            declared vs measured entry count, entries added this session
#   docs/context/NEXT-SESSION-PROMPT.md   age vs the handoff, open/closed task ids (heuristic)
#   git                                commits + paths since the session-start stamp, dirty tree,
#                                      HEAD vs the local tracking ref — for the project AND every
#                                      extra repo (--repo, GOV_REPO_PATH, GOV_CLOSE_REPORT_REPOS)
#   controls                           governance-selftest verdict, copy parity of the governance
#                                      hooks across live/installer/repo/mirrors, push flag, refusals
#   session state                      writes logged this session, whether a handoff is among them
#
# MODES
# -----
#   (no args, hook mode)   Stop event. Reads the payload, resolves the project from it, writes the
#                          report to the per-session state dir and prints it. NEVER exits 2 —
#                          a report is not a gate; the gates are the other Stop hooks.
#   --project <root>       CLI. The model runs this and pastes the OUTPUT as its closing summary,
#                          instead of composing one. `--project .` is accepted.
#   --repo <path>          extra repository to report on (repeatable)
#   --since <rev|date>     override the session range for the project repo
#   --out <file>           also write the report to <file>
#   --session <id>         use that session's state dir (default: newest stamp for this project)
#
# EXIT CODES: 0 always in hook mode. CLI: 0 report printed · 1 usage / project root not found.
# KILL SWITCHES: GOV_CLOSE_REPORT=0 (hook mode only) · GOVERNANCE_HOOKS=0 (the whole family).
#   The CLI form ignores both on purpose: a human asking for the record must always get it.
set +e
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
if [ ! -f "$SCRIPT_DIR/_common.sh" ]; then
  echo "[close-report] _common.sh is missing beside this script; nothing can be read" >&2
  exit 0
fi
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || exit 0

# ── Arguments ────────────────────────────────────────────────────────────────────────────────
MODE=hook; PROJECT_ARG=""; EXTRA_REPOS=""; SINCE_ARG=""; OUT_ARG=""; SESSION_ARG=""
usage() {
  sed -n '2,3p;40,52p' "$0" | sed 's/^# \{0,1\}//'
}
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT_ARG="${2:-}"; MODE=cli; shift 2 ;;
    --repo)    EXTRA_REPOS="$EXTRA_REPOS
${2:-}"; shift 2 ;;
    --since)   SINCE_ARG="${2:-}"; shift 2 ;;
    --out)     OUT_ARG="${2:-}"; shift 2 ;;
    --session) SESSION_ARG="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[close-report] unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ "$MODE" = hook ]; then
  gov_disabled && exit 0
  [ "${GOV_CLOSE_REPORT:-1}" = "0" ] && exit 0
fi
[ -n "$SESSION_ARG" ] && export GOV_SESSION_ID="$SESSION_ARG"

# ── Path helpers ─────────────────────────────────────────────────────────────────────────────
# Windows drive path -> the msys form this shell can stat. Idempotent on POSIX paths.
_posix() {
  local p; p="$(printf '%s' "$1" | tr '\\' '/')"
  case "$p" in [A-Za-z]:/*) p="/$(printf '%s' "${p%%:*}" | tr 'A-Z' 'a-z')/${p#*:/}" ;; esac
  printf '%s' "${p%/}"
}
_same_dir() { [ "$(cd "$1" 2>/dev/null && pwd -P)" = "$(cd "$2" 2>/dev/null && pwd -P)" ] 2>/dev/null; }

# ── Project root: from the PAYLOAD (hook) or --project (CLI); $PWD is the last resort ─────────
GOV_INPUT="$(gov_hook_input)"
ROOT=""
if [ "$MODE" = hook ]; then
  ROOT="$(gov_payload_root "$GOV_INPUT" 2>/dev/null)"
else
  ROOT="$(_posix "$PROJECT_ARG")"
  [ "$PROJECT_ARG" = "." ] && ROOT="$PWD"
fi
[ -z "$ROOT" ] && ROOT="${GOV_PROJECT_ROOT:-}"
[ -z "$ROOT" ] && ROOT="$(gov_find_project_root 2>/dev/null)"
ROOT="$(_posix "$ROOT")"
if [ ! -d "$ROOT" ]; then
  echo "[close-report] project root not found: '$ROOT'" >&2
  [ "$MODE" = cli ] && exit 1
  exit 0
fi
export GOV_PROJECT_ROOT="$ROOT"

# ── Output buffer: the whole report is assembled, then printed AND persisted ─────────────────
REPORT_TMP="$(mktemp 2>/dev/null)" || REPORT_TMP="$SCRIPT_DIR/.close-report.$$.tmp"
: > "$REPORT_TMP"
out()      { printf '%s\n' "$1" >> "$REPORT_TMP"; }
out_cmd()  { "$@" 2>/dev/null | sed 's/^/      /' >> "$REPORT_TMP"; }   # indented command output
trunc()    { local n="${2:-200}"; local s="$1"; if [ "${#s}" -gt "$n" ]; then printf '%s…' "${s:0:$n}"; else printf '%s' "$s"; fi; }

# count_lines — non-blank lines on stdin, ALWAYS exactly one integer.
# NOT `grep -c . || echo 0`: on empty input grep PRINTS "0" and EXITS 1, so the fallback fires
# too and the caller receives "0\n0", which every later `[ "$n" -gt 0 ]` rejects with
# "integer expression expected". Measured on this script's first run, twice. It is the same
# shape as the framework's other favourite defect — a fallback that fires ALONGSIDE the real
# value instead of instead of it — so the guard is on the VALUE, not on the exit status.
count_lines() {
  local n; n="$(grep -c . 2>/dev/null | head -1)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# json_str <file> <key> — the string value of a top-level JSON key, without a JSON parser.
# gov_read_version() slurps line 1, which on a pretty-printed version.json is "{" — the report
# then announced `version.json={`. A version is a fact the report states, so it is read, not
# guessed at.
json_str() {
  [ -f "$1" ] || return 0
  grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null \
    | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
}
FILES_READ=0
reads() { FILES_READ=$((FILES_READ + 1)); }

# ── Session stamp: SHA + timestamp + root, written by pre-session.sh at SessionStart ─────────
# Hook mode has a session id (state dir is per-session). CLI mode usually does not: the model
# runs this from Bash. Then take the NEWEST stamp whose root is this project; say so.
START_FILE="${GOV_SESSION_START_FILE:-}"
START_NOTE=""
if [ -z "$START_FILE" ]; then
  sid="$(gov_session_id)"
  if [ -n "$sid" ]; then
    START_FILE="$(gov_state_file .gov-session-start)"
  else
    newest=""; newest_t=0
    for f in "$HOME"/.claude/logs/sessions/*/.gov-session-start "$HOME/.claude/logs/.gov-session-start"; do
      [ -f "$f" ] || continue
      r="$(awk 'NR==1{print $3}' "$f" 2>/dev/null)"
      [ -n "$r" ] && _same_dir "$(_posix "$r")" "$ROOT" || continue
      t="$(gov_mtime "$f")"
      if [ "$t" -gt "$newest_t" ] 2>/dev/null; then newest="$f"; newest_t="$t"; fi
    done
    START_FILE="$newest"
    [ -n "$newest" ] && START_NOTE="(newest stamp for this project, no session id given)"
  fi
fi
START_SHA=""; START_TS=""; START_ROOT=""; START_EPOCH=0
if [ -n "$START_FILE" ] && [ -f "$START_FILE" ]; then
  START_SHA="$(grep -o '^[0-9a-f]\{7,40\}' "$START_FILE" 2>/dev/null | head -1)"
  START_TS="$(awk 'NR==1{print $2}' "$START_FILE" 2>/dev/null)"
  START_ROOT="$(awk 'NR==1{print $3}' "$START_FILE" 2>/dev/null)"
  [ -n "$START_TS" ] && START_EPOCH="$(date -d "$START_TS" +%s 2>/dev/null || echo 0)"
fi
[ "$START_EPOCH" -gt 0 ] 2>/dev/null || START_EPOCH=$(( $(date +%s) - 86400 ))

# ── Header ───────────────────────────────────────────────────────────────────────────────────
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ROLE="$(gov_detect_role "$ROOT" 2>/dev/null)"
VER=""; if [ -f "$ROOT/version.json" ]; then VER="$(json_str "$ROOT/version.json" version)"; reads; fi
out "# Close report — generated from the record"
out ""
out "- generated: $NOW_ISO by close-report.sh (mode: $MODE)"
out "- project:   $ROOT  (role=${ROLE:-?}${VER:+ · version.json=$VER})"
if [ -n "$START_SHA" ]; then
  out "- session started: $START_TS at ${START_SHA:0:7}${START_ROOT:+ in $START_ROOT} $START_NOTE"
else
  out "- session started: NO STAMP FOUND — ranges below fall back to the last 24 h (pre-session.sh writes the stamp only when the session's cwd is inside a git repo)"
fi
out ""

# ── Git range for the project repo ───────────────────────────────────────────────
# Computed HERE, above every section, because sections 2, 3, 5 and 7 all cite it. It used to sit
# between sections 4 and 5: the two sections above it read an EMPTY $RANGE and silently dropped
# their "added in this range" half — a report omitting the very lines the session had just
# written, which is the defect this script exists to end, reproduced inside the script itself.────────────────────
RANGE=""; RANGE_LABEL=""
_git() { git -C "$ROOT" "$@" 2>/dev/null; }
if [ -d "$ROOT/.git" ]; then
  if [ -n "$SINCE_ARG" ]; then
    if _git cat-file -e "${SINCE_ARG}^{commit}"; then RANGE="$SINCE_ARG..HEAD"; RANGE_LABEL="$SINCE_ARG..HEAD (--since)"
    else RANGE="--since=$SINCE_ARG"; RANGE_LABEL="since $SINCE_ARG (--since)"; fi
  elif [ -n "$START_SHA" ] && _git cat-file -e "${START_SHA}^{commit}" && { [ -z "$START_ROOT" ] || _same_dir "$(_posix "$START_ROOT")" "$ROOT"; }; then
    RANGE="$START_SHA..HEAD"; RANGE_LABEL="${START_SHA:0:7}..HEAD (session-start stamp)"
  elif [ -n "$START_TS" ]; then
    RANGE="--since=$START_TS"; RANGE_LABEL="since $START_TS (stamp time; SHA is from another repo)"
  else
    RANGE="--since=24.hours.ago"; RANGE_LABEL="last 24 h (no session-start stamp)"
  fi
fi
# A time-based range is resolved ONCE to a base commit, so every later query is a cheap two-point
# `git diff` instead of a `git log -p` that re-walks and re-diffs the whole history per file.
# Measured on this repo: the log form cost ~20 s for two large files, the diff form ~1 s. Speed is
# a correctness property here — a Stop hook that costs 20 s is a Stop hook someone deletes.
if [ -n "$RANGE" ]; then
  case "$RANGE" in
    --since=*)
      _base="$(_git rev-list -1 --before="${RANGE#--since=}" HEAD)"
      [ -z "$_base" ] && _base="$(_git rev-list --max-parents=0 HEAD | tail -1)"
      if [ -n "$_base" ]; then RANGE="$_base..HEAD"; RANGE_LABEL="$RANGE_LABEL → ${_base:0:7}..HEAD"; fi
      ;;
  esac
fi
_range_files() {  # paths touched in the range, committed only
  case "$RANGE" in
    *..HEAD) _git diff --name-only "${RANGE%..HEAD}" HEAD ;;
    --since=*) _git log --name-only --pretty=format: "$RANGE" | grep -v '^$' | sort -u ;;
  esac
}
_range_added_lines() {  # $1 path: '+' lines added to that path in the range
  case "$RANGE" in
    *..HEAD) _git diff "${RANGE%..HEAD}" HEAD -- "$1" | grep -E '^\+[^+]' | sed 's/^+//' ;;
    --since=*) _git log -p --pretty=format: "$RANGE" -- "$1" | grep -E '^\+[^+]' | sed 's/^+//' ;;
  esac
}

# ── 1. The handoff pointer and the active handoff(s) ─────────────────────────────────────────
out "## 1. Handoff — what the record says happened"
HP="$ROOT/docs/context/HANDOFF.md"
if [ -f "$HP" ]; then
  reads
  out "### docs/context/HANDOFF.md (pointer)"
  for k in status type points_to created_at superseded_by; do
    v="$(sed -n '1,60p' "$HP" | grep -m1 -E "^$k:" | sed "s/^$k:[[:space:]]*//")"
    [ -n "$v" ] && out "- $k: $v"
  done
  newest_item="$(grep -m1 -E '^[[:space:]]+- "' "$HP" | sed 's/^[[:space:]]*- "//; s/"$//')"
  if [ -n "$newest_item" ]; then
    out "- newest recorded session entry (consumed_items[0]):"
    out "      $(trunc "$newest_item" 700)"
  fi
else
  out "- docs/context/HANDOFF.md: ABSENT"
fi
ACTIVE_HANDOFFS=""
for f in "$ROOT"/MDs/HANDOFF*.md "$ROOT"/docs/context/HANDOFF*.md; do
  [ -f "$f" ] || continue
  [ "$f" = "$HP" ] && continue
  head -n 12 "$f" 2>/dev/null | grep -qE '^status:[[:space:]]*active' || continue
  head -n 12 "$f" 2>/dev/null | grep -qE '^(type:[[:space:]]*pointer|points_to:)' && continue
  ACTIVE_HANDOFFS="$ACTIVE_HANDOFFS
$f"
done
ACTIVE_HANDOFFS="$(printf '%s\n' "$ACTIVE_HANDOFFS" | grep -v '^$')"
N_ACTIVE="$(printf '%s\n' "$ACTIVE_HANDOFFS" | count_lines)"
out "### active handoff files (frontmatter \`status: active\`, pointers excluded): $N_ACTIVE"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  reads
  rel="${f#$ROOT/}"
  ca="$(head -n 12 "$f" | grep -m1 -E '^created_at:' | sed 's/^created_at:[[:space:]]*//')"
  su="$(head -n 12 "$f" | grep -m1 -E '^supersedes:' | sed 's/^supersedes:[[:space:]]*//')"
  out "- $rel${ca:+ · created_at $ca}${su:+ · supersedes $su}"
  tldr="$(awk '/^## TL;DR/{p=1; next} p && /^## /{exit} p' "$f" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n 14)"
  if [ -n "$tldr" ]; then
    out "  TL;DR (as written in the file):"
    printf '%s\n' "$tldr" | sed 's/^/      /' >> "$REPORT_TMP"
  else
    out "  (no \`## TL;DR\` section in this handoff)"
  fi
done <<EOF
$ACTIVE_HANDOFFS
EOF
[ "$N_ACTIVE" -gt 1 ] && out "  [!] more than one active handoff — a dual source of truth"
PROSE_ACTIVE="$(grep -liE '^[[:space:]]*>?[[:space:]]*\*\*status:\*\*[[:space:]]*active' "$ROOT"/MDs/HANDOFF*.md 2>/dev/null | count_lines)"
[ "$PROSE_ACTIVE" -gt 0 ] && out "- handoffs with a PROSE \`**Status:** active\` (unstamped when superseded): $PROSE_ACTIVE"
out ""

# ── 2. PLAN.md ───────────────────────────────────────────────────────────────────────────────
out "## 2. Plans/PLAN.md — version line and the newest milestone rows"
PLAN="$ROOT/Plans/PLAN.md"
if [ -f "$PLAN" ]; then
  reads
  pv="$(grep -m1 -E 'Project version' "$PLAN" | sed 's/^[>[:space:]]*//')"
  [ -n "$pv" ] && out "- $(trunc "$pv" 220)"
  rows="$(awk '/Milestone Log/{p=1} p && /^\| *20[0-9][0-9]-/' "$PLAN" 2>/dev/null | head -n 3)"
  if [ -n "$rows" ]; then
    out "- newest milestone rows (top of the log):"
    printf '%s\n' "$rows" | while IFS= read -r r; do out "      $(trunc "$r" 240)"; done
  else
    out "- no milestone rows found under a 'Milestone Log' heading"
  fi
else
  out "- Plans/PLAN.md: ABSENT"
fi
out ""

# ── 3. Project memory ────────────────────────────────────────────────────────────────────────
out "## 3. docs/context/MEMORY.md — what this session recorded, and the newest dated entries"
PMEM="$ROOT/docs/context/MEMORY.md"
if [ -f "$PMEM" ]; then
  reads
  # Lines ADDED to MEMORY.md inside the session range are the truest answer to "did this session
  # record anything durable" — it is a diff, so neither position nor date convention can hide it.
  if [ -n "$RANGE" ]; then
    madd="$(_range_added_lines docs/context/MEMORY.md | grep -E '^[[:space:]]*[-*] ' | head -n 6)"
    if [ -n "$madd" ]; then
      out "- lines added in range ($RANGE_LABEL):"
      printf '%s\n' "$madd" | while IFS= read -r l; do out "      $(trunc "$l" 260)"; done
    else
      out "- [!] NOTHING was added to docs/context/MEMORY.md in range ($RANGE_LABEL) — if this session"
      out "      learned anything durable, it is not in the file that carries it to every clone."
    fi
  fi
  # "Newest" by DATE, not by position. The first version took `head -1` of the matches, i.e. the
  # entry that happens to sit highest in the file. This project writes newest-first so it looked
  # correct; on a file that APPENDS, the session's own entry — the newest — was silently omitted
  # from the report while sitting in the file. A report that drops the very entry a session just
  # wrote is the failure this script exists to end, so the date is now compared, never assumed.
  nd="$(grep -oE '^[[:space:]]*[-*] \**20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$PMEM" \
        | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' | sort -r | head -1)"
  if [ -n "$nd" ]; then
    ndn="$(grep -cE "^[[:space:]]*[-*] \**$nd" "$PMEM")"
    out "- newest entry date: $nd ($ndn entr(ies) carry it)"
    grep -E "^[[:space:]]*[-*] \**$nd" "$PMEM" | head -n 4 | while IFS= read -r l; do out "      $(trunc "$l" 260)"; done
  else
    out "- no dated \`- **YYYY-MM-DD** …\` entries found"
  fi
  out "- lines: $(wc -l < "$PMEM" | tr -d ' ')"
else
  out "- docs/context/MEMORY.md: ABSENT"
fi
out ""

# ── 4. Agent auto-memory ─────────────────────────────────────────────────────────────────────
out "## 4. Agent auto-memory (~/.claude/projects/<key>/memory/) — touched this session"
if command -v gov_memory_dir >/dev/null 2>&1; then MEMDIR="$(gov_memory_dir "$ROOT")"; else MEMDIR=""; fi
if [ -n "$MEMDIR" ] && [ -d "$MEMDIR" ]; then
  reads
  out "- directory: $MEMDIR"
  # ONE `find` and ONE `grep` over the whole directory, not one spawn PER FILE. The first version
  # spawned gov_mtime + a grep for each of ~110 memory files; on this platform a process spawn is
  # ~50 ms, so a Stop hook paid tens of seconds — and a slow hook is a hook that gets switched off,
  # which is how every control in this framework has died so far. Cost is now flat in file count.
  touched="$(find "$MEMDIR" -maxdepth 1 -name '*.md' -newermt "@$START_EPOCH" -printf '%f
' 2>/dev/null | sort)"
  n_t="$(printf '%s
' "$touched" | count_lines)"
  out "- files modified since session start: $n_t"
  printf '%s
' "$touched" | grep -v '^$' | head -n 12 | sed 's/^/      /' >> "$REPORT_TMP"
  if [ -f "$MEMDIR/MEMORY.md" ]; then
    ml="$(wc -l < "$MEMDIR/MEMORY.md" | tr -d ' ')"
    if [ "$ml" -gt 200 ] 2>/dev/null; then out "- MEMORY.md index: $ml lines [!] over the 200-line load limit — lines past 200 are never read"
    else out "- MEMORY.md index: $ml lines"; fi
  fi
  # Dead [[links]]: every link name in one pass, every existing memory name in one pass, then
  # compare the two SETS. Hyphen and underscore spellings both resolve — a repair that handled
  # only underscores once reported "0 broken" while two hyphenated links were still dangling
  # (gotcha #351). Link names are normalised to underscores on BOTH sides so the comparison
  # cannot depend on which spelling an author happened to use.
  _mem_have="$(find "$MEMDIR" -maxdepth 1 -name '*.md' -printf '%f
' 2>/dev/null                | sed 's/\.md$//' | tr '-' '_' | sort -u)"
  # `grep -r` would descend into archive/ and superseded-*/ subdirectories while the name side
  # above is maxdepth 1 — two sides of one comparison drawn from DIFFERENT sets, which is how a
  # sweep reports a difference that is not there (B22). Same depth on both sides, and backticked
  # spans are stripped first: prose that MENTIONS the `[[wiki-link]]` syntax is documentation, not
  # a dangling pointer, and a check that flags its own description is the other half of that bug.
  _mem_want="$(find "$MEMDIR" -maxdepth 1 -name '*.md' -print0 2>/dev/null                | xargs -0 -r sed -E 's/`[^`]*`//g' 2>/dev/null                | grep -oE '\[\[[A-Za-z0-9_-]+\]\]' | tr -d '[]' | tr '-' '_' | sort -u)"
  dead="$(comm -23 <(printf '%s
' "$_mem_want" | grep -v '^$') <(printf '%s
' "$_mem_have" | grep -v '^$') 2>/dev/null)"
  nd_links="$(printf '%s
' "$dead" | count_lines)"
  if [ "$nd_links" -gt 0 ] 2>/dev/null; then
    out "- dead [[links]]: $nd_links → $(printf '%s
' "$dead" | tr '
' ' ')"
    out "      (a link naming no file is a promise the next session cannot collect: write it, or repoint it)"
  else
    out "- dead [[links]]: 0"
  fi
else
  out "- no auto-memory directory found for this project (looked under ~/.claude/projects/ for every spelling of the key)"
fi
out ""

# ── 5. GOTCHAS.md ────────────────────────────────────────────────────────────────────────────
out "## 5. docs/context/GOTCHAS.md — declared vs measured, entries added this session"
GOT="$ROOT/docs/context/GOTCHAS.md"
if [ -f "$GOT" ]; then
  reads
  # Same entry regex as governance-selftest.sh part B. Two copies, kept identical on purpose.
  ENTRY_RE='^(#{1,6}[[:space:]]*)?#?[0-9]+[.)]'
  decl="$(grep -m1 -oE '^total_entries:[[:space:]]*[0-9]+' "$GOT" | grep -oE '[0-9]+')"
  meas="$(grep -cE "$ENTRY_RE" "$GOT")"
  if [ -n "$decl" ]; then
    if [ "$decl" = "$meas" ]; then out "- total_entries declared $decl, measured $meas — agree"
    else out "- total_entries declared $decl, measured $meas — [!] DISAGREE"; fi
  else
    out "- no total_entries in frontmatter; measured $meas"
  fi
  if [ -n "$RANGE" ]; then
    # Take only the LEADING entry number of each added entry line. A bare `grep -oE '[0-9]+'`
    # also harvests every number inside the title ("0 of 8", a year, a line reference) and the
    # list then reads as a dozen new gotchas where one was added.
    added="$(_range_added_lines docs/context/GOTCHAS.md | grep -E "$ENTRY_RE" \
             | sed -E 's/^(#{1,6}[[:space:]]*)?#?([0-9]+)[.)].*/\2/' | sort -un | head -n 20 | tr '\n' ' ')"
    out "- entries added in range ($RANGE_LABEL): ${added:-none}"
  fi
else
  out "- docs/context/GOTCHAS.md: ABSENT"
fi
out ""

# ── 6. Next-session prompt ───────────────────────────────────────────────────────────────────
out "## 6. docs/context/NEXT-SESSION-PROMPT.md — age and open items"
NSP="$ROOT/docs/context/NEXT-SESSION-PROMPT.md"
if [ -f "$NSP" ]; then
  reads
  pm="$(gov_mtime "$NSP")"; hm="$(gov_mtime "$HP")"
  if [ "$hm" -gt "$pm" ] 2>/dev/null; then
    out "- [!] STALE: prompt is $(( (hm - pm) / 60 )) min older than docs/context/HANDOFF.md — rewrite it at close or delete it"
  else
    out "- fresh: prompt is not older than docs/context/HANDOFF.md"
  fi
  # Task ids of the form B12 / T3 at the start of a heading or bold item. Heuristic, labelled as such.
  items="$(grep -oE '^(#{1,6} .{0,20}|- \*\*|\*\*)[A-Z][0-9]{1,3}[ —-][^|]{0,120}' "$NSP" 2>/dev/null)"
  ids_all="$(printf '%s\n' "$items" | grep -oE '\b[A-Z][0-9]{1,3}\b' | sort -u)"
  ids_closed="$(printf '%s\n' "$items" | grep -E 'DONE|CLOSED|✅|RESOLVED' | grep -oE '\b[A-Z][0-9]{1,3}\b' | sort -u)"
  ids_open="$(comm -23 <(printf '%s\n' "$ids_all" | grep -v '^$') <(printf '%s\n' "$ids_closed" | grep -v '^$') 2>/dev/null)"
  out "- task ids seen (heuristic on headings/bold items): $(printf '%s\n' "$ids_all" | count_lines) · marked DONE/CLOSED: $(printf '%s\n' "$ids_closed" | count_lines) · not marked: $(printf '%s\n' "$ids_open" | count_lines)"
  [ -n "$ids_open" ] && out "      not marked closed: $(printf '%s\n' "$ids_open" | tr '\n' ' ')"
  strays="$(find "$ROOT" -maxdepth 3 -type f \( -name 'NEXT-SESSION-*.md' -o -name 'NEXT_SESSION_*.md' \) -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | grep -v '/docs/context/NEXT-SESSION-PROMPT\.md$')"
  [ -n "$strays" ] && out "- [!] next-session prompt(s) OUTSIDE the canonical path:$(printf '%s\n' "$strays" | sed "s|^$ROOT/||" | tr '\n' ' ')"
else
  out "- absent (normal when the last session closed with nothing open)"
fi
out ""

# ── 7. Git — the project repo and every extra repo ───────────────────────────────────────────
out "## 7. Git — what is committed, what is dirty, what is pushed"
out "   (push state is HEAD vs the LOCAL tracking ref; no fetch is performed here)"
_repo_block() {  # $1 path (posix), $2 label, $3 range-or-empty, $4 range label
  local r="$1" label="$2" rng="$3" rlabel="$4"
  if [ ! -d "$r/.git" ]; then out "- $label: $r — not a git repository"; return; fi
  reads
  local head branch dirty up ahead behind pushstate treestate n
  head="$(git -C "$r" rev-parse --short HEAD 2>/dev/null)"
  branch="$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  dirty="$(git -C "$r" status --porcelain 2>/dev/null | count_lines)"
  if up="$(git -C "$r" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" && [ -n "$up" ]; then
    ahead="$(git -C "$r" rev-list --count '@{u}..HEAD' 2>/dev/null)"; behind="$(git -C "$r" rev-list --count 'HEAD..@{u}' 2>/dev/null)"
    if [ "${ahead:-0}" = 0 ] && [ "${behind:-0}" = 0 ]; then pushstate="PUSHED (HEAD == $up)"
    else pushstate="NOT PUSHED — ahead ${ahead:-?} / behind ${behind:-?} vs $up"; fi
  else
    pushstate="NO UPSTREAM configured"
  fi
  if [ "$dirty" -gt 0 ]; then treestate="DIRTY ($dirty path(s))"; else treestate="clean"; fi
  out "- $label: $r"
  out "  HEAD ${head:-?} on ${branch:-?} · working tree $treestate · $pushstate"
  [ "$dirty" -gt 0 ] && git -C "$r" status --porcelain 2>/dev/null | head -n 15 | sed 's/^/      /' >> "$REPORT_TMP"
  if [ -n "$rng" ]; then
    case "$rng" in
      *..HEAD) n="$(git -C "$r" rev-list --count "$rng" 2>/dev/null)" ;;
      *)       n="$(git -C "$r" log --oneline "$rng" 2>/dev/null | count_lines)" ;;
    esac
    out "  commits in range [$rlabel]: ${n:-0}"
    git -C "$r" log --oneline "$rng" 2>/dev/null | head -n 12 | sed 's/^/      /' >> "$REPORT_TMP"
  fi
}
_repo_block "$ROOT" "project" "$RANGE" "$RANGE_LABEL"
if [ -n "$RANGE" ]; then
  chg="$(_range_files)"
  nchg="$(printf '%s\n' "$chg" | count_lines)"
  out "  paths changed in range: $nchg"
  printf '%s\n' "$chg" | grep -v '^$' | head -n 30 | sed 's/^/      /' >> "$REPORT_TMP"
  [ "$nchg" -gt 30 ] && out "      … $((nchg - 30)) more"
fi
# Extra repos: --repo, then GOV_REPO_PATH and GOV_CLOSE_REPORT_REPOS from the machine-local env file
# (KEY=value lines; ';' or newline separated for the list). Never a path baked into this script.
ENVF="$HOME/.claude/.governance-local.env"
if [ -f "$ENVF" ]; then
  EXTRA_REPOS="$EXTRA_REPOS
$( ( . "$ENVF" 2>/dev/null; printf '%s\n' "${GOV_REPO_PATH:-}"; printf '%s\n' "${GOV_CLOSE_REPORT_REPOS:-}" | tr ';' '\n' ) 2>/dev/null )"
fi
# Deliberately NOT `printf ... | while read`: a piped loop runs in a SUBSHELL, so every
# SEEN_REPOS update is discarded when it ends and the same repo is reported twice the moment two
# sources name it — GOV_REPO_PATH and --repo routinely do. Here-doc redirection keeps the loop in
# this shell. Dedup is by resolved directory (pwd -P), not by string: `C:/x`, `/c/x` and `/c/x/`
# are one repo.
SEEN_REPOS="|$(cd "$ROOT" 2>/dev/null && pwd -P)|"
while IFS= read -r r; do
  [ -n "$(printf '%s' "$r" | tr -d '[:space:]')" ] || continue
  r="$(_posix "$(printf '%s' "$r" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')")"
  if [ ! -d "$r" ]; then out "- extra repo: $r — directory NOT FOUND (named by --repo or the machine-local env)"; continue; fi
  rp="$(cd "$r" 2>/dev/null && pwd -P)"
  case "$SEEN_REPOS" in *"|$rp|"*) continue ;; esac
  SEEN_REPOS="$SEEN_REPOS$rp|"
  if [ -n "$START_TS" ]; then _repo_block "$r" "extra repo" "--since=$START_TS" "since $START_TS"
  else _repo_block "$r" "extra repo" "--since=24.hours.ago" "last 24 h"; fi
done <<XEOF_REPOS
$EXTRA_REPOS
XEOF_REPOS
out ""

# ── 8. Controls ──────────────────────────────────────────────────────────────────────────────
out "## 8. Controls — measured now"
RES="${GOV_SELFTEST_LOGDIR:-$HOME/.claude/logs}/governance-selftest.result"
if [ -f "$RES" ]; then
  reads
  v="$(grep -m1 '^verdict=' "$RES" | cut -d= -f2-)"; s="$(grep -m1 '^summary=' "$RES" | cut -d= -f2-)"
  fin="$(grep -m1 '^finished=' "$RES" | cut -d= -f2-)"; age=""
  case "$fin" in ''|*[!0-9]*) ;; *) age=" · finished $(( ( $(date +%s) - fin ) / 60 )) min ago" ;; esac
  out "- governance-selftest: ${v:-?}$age"
  out "      ${s:-no summary line}"
else
  out "- governance-selftest: no completed run recorded (no $RES)"
fi
# Copy parity of the governance hooks: live vs installer bundle vs repo bundle vs mirrors.
LIVE_DIR="$SCRIPT_DIR"
INST_DIR="$HOME/.claude/governance-installer/bundle/hooks/governance"
REPO_DIR=""
[ -f "$ENVF" ] && REPO_DIR="$( ( . "$ENVF" 2>/dev/null; printf '%s' "${GOV_REPO_PATH:-}" ) 2>/dev/null )"
[ -n "$REPO_DIR" ] && REPO_DIR="$(_posix "$REPO_DIR")/bundle/hooks/governance"
MIRROR_DIRS=""
if [ -f "$HOME/.claude/.governance-mirrors" ]; then
  MIRROR_DIRS="$(sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$HOME/.claude/.governance-mirrors" | grep -v '^$' | while IFS= read -r m; do printf '%s/.claude/hooks/governance\n' "$(_posix "$m")"; done)"
fi
COPIES="$INST_DIR
$REPO_DIR
$MIRROR_DIRS"
COPIES="$(printf '%s\n' "$COPIES" | grep -v '^$')"
n_copies="$(printf '%s\n' "$COPIES" | count_lines)"
# ONE md5sum invocation per DIRECTORY, not one per file per directory. The first version spawned
# ~105 processes here and made the whole report too slow to sit on a Stop hook. `md5sum dir/*`
# hashes the lot in a single read; the results are keyed by basename and compared in the shell.
_hash_dir() {   # $1 dir -> "<relpath>\t<md5>" per file, backups excluded
  # md5sum takes the whole glob in ONE invocation. NOT `ls | tr '\n' '\0' | xargs -0`: on this
  # platform `tr '\n' '\0'` dies with "string2 must be non-empty", which went to stderr while the
  # empty result read as "0 differing, 0 absent" — a parity check reporting perfect agreement
  # BECAUSE it had produced nothing. That is the exact shape this whole framework keeps failing on,
  # so the output is now shaped by md5sum itself and an empty table is impossible to mistake for
  # agreement (the caller states the file count it compared).
  [ -d "$1" ] || return 0
  ( cd "$1" 2>/dev/null || exit 0
    md5sum *.sh *.py *.js *.ps1 tests/*.sh 2>/dev/null \
      | sed -E 's/^([0-9a-f]{32})[[:space:]]+[*]?/\1\t/' \
      | awk -F'\t' 'NF==2 && $2 !~ /\.bak/ && $2 !~ /\.tmp$/ {print $2 "\t" $1}' | sort )
}
div=0; div_list=""; absent=0
if [ "$n_copies" -gt 0 ]; then
  LIVE_TBL="$(_hash_dir "$LIVE_DIR")"
  n_live="$(printf '%s\n' "$LIVE_TBL" | count_lines)"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if [ ! -d "$c" ]; then div_list="$div_list
      (whole directory absent) $c"; continue; fi
    # ONE awk per directory, both tables on its stdin. The previous form ran an awk lookup per
    # live file per directory - 111 process spawns for 37 files - and cost more than the hashing
    # it was comparing. Same finding as the loops above: on this platform the spawn IS the cost.
    _res="$( { printf '%s\n' "$LIVE_TBL"; printf '\034\n'; _hash_dir "$c"; } \
             | awk -F'\t' -v dir="$c" '
                 $0=="\034" { side=1; next }
                 side==0 { live[$1]=$2; next }
                 { other[$1]=$2 }
                 END {
                   d=0; a=0
                   for (k in live) {
                     if (!(k in other))      { a++; print "ABSENT\t" k "\t" dir }
                     else if (other[k]!=live[k]) { d++; print "DIFFER\t" k "\t" dir }
                   }
                   print "COUNT\t" d "\t" a
                 }' )"
    _c_div="$(printf  '%s\n' "$_res" | awk -F'\t' '$1=="COUNT"{print $2; exit}')"
    _c_abs="$(printf  '%s\n' "$_res" | awk -F'\t' '$1=="COUNT"{print $3; exit}')"
    case "$_c_div" in ''|*[!0-9]*) _c_div=0 ;; esac
    case "$_c_abs" in ''|*[!0-9]*) _c_abs=0 ;; esac
    div=$((div + _c_div)); absent=$((absent + _c_abs))
    div_list="$div_list
$(printf '%s\n' "$_res" | awk -F'\t' '$1=="DIFFER"{print "      " $2 " — differs in " $3} $1=="ABSENT"{print "      " $2 " — ABSENT in " $3}' | sort)"
  done <<COPIES_EOF
$COPIES
COPIES_EOF
  reads
  if [ "$n_live" -eq 0 ] 2>/dev/null; then
    out "- governance-hook copy parity: [!] COULD NOT HASH the live directory ($LIVE_DIR) — this is NOT agreement"
  else
    out "- governance-hook copy parity: $n_live live file(s) vs $n_copies other location(s) — $div differing, $absent absent"
  fi
  out "      (live -> installer bundle -> framework repo -> project mirrors; a dirty live file is two hops from a public commit)"
  printf '%s\n' "$div_list" | grep -v '^$' | head -n 12 >> "$REPORT_TMP"
else
  out "- governance-hook copy parity: no installer bundle / GOV_REPO_PATH / mirrors configured to compare against"
fi
PUSH_FLAG="$HOME/.claude/logs/.governance-push-pending"
if [ -f "$PUSH_FLAG" ]; then out "- governance push flag: PRESENT ($(count_lines < "$PUSH_FLAG") queued path(s)) — end-session.sh will publish them at the next Stop"
else out "- governance push flag: absent (nothing queued for the framework repo)"; fi
DIVLOG="$HOME/.claude/logs/.governance-bundle-divergence"
if [ -s "$DIVLOG" ]; then out "- bundle copies REFUSED by the PII gate this session: $(grep -c 'REFUSED' "$DIVLOG" 2>/dev/null)"; fi
out ""

# ── 9. Session state ─────────────────────────────────────────────────────────────────────────
out "## 9. Session state (per-session governance files)"
CHG="$(gov_state_file .gov-session-changes)"
if [ -f "$CHG" ]; then
  reads
  nw="$(count_lines < "$CHG")"
  hf="$(grep -ciE 'HANDOFF[^/\\]*\.md' "$CHG" 2>/dev/null)"
  out "- writes logged by post-milestone.sh: $nw · handoff files among them: ${hf:-0}"
  out "- distinct paths (newest 10):"
  awk '{print $NF}' "$CHG" 2>/dev/null | sort -u | tail -n 10 | sed 's/^/      /' >> "$REPORT_TMP"
else
  out "- no change log for this session id at $(dirname "$CHG") (CLI runs without --session read the legacy path)"
fi
out ""
out "---"
out "[close-report] $FILES_READ source(s) read. Every line above was read from a file or measured by a command;"
out "[close-report] nothing was typed. If something you did this session is not above, it is NOT in the record —"
out "[close-report] write it into the canonical file it belongs to, then run this again. Do not describe it in prose."

# ── Emit + persist ───────────────────────────────────────────────────────────────────────────
cat "$REPORT_TMP"
DEST="$(gov_state_file close-report.md 2>/dev/null)"
if [ -n "$DEST" ]; then gov_dry || cp -f "$REPORT_TMP" "$DEST" 2>/dev/null; fi
if [ -n "$OUT_ARG" ]; then gov_dry || cp -f "$REPORT_TMP" "$OUT_ARG" 2>/dev/null; fi
rm -f "$REPORT_TMP" 2>/dev/null
if [ "$MODE" = hook ]; then
  gov_log "close-report" "generated for $ROOT ($FILES_READ sources) -> $DEST"
  printf '[close-report] closing report generated from the record -> %s\n' "$DEST" >&2
  printf '[close-report] paste THAT as the closing summary (bash %s --project <root>), do not compose one.\n' "$0" >&2
fi
exit 0
