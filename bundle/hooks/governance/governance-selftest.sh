#!/usr/bin/env bash
# governance-selftest.sh — EXECUTION-based health check for the Context Governance framework.
#
# ⛔ NOT WIRED, AND NOT PORTABLE AS SHIPPED — READ BEFORE USING ⛔
# ------------------------------------------------------------------------------------------
# 1. This script is deliberately ABSENT from settings.json and install.sh must not add it.
#    It is a diagnostic you RUN BY HAND, not a hook. Wiring it to an event makes every
#    session pay for a sandbox build, a mutation sweep and a full doc recount.
# 2. Part (a) (hook execution) and part (c) (mutation) are generic and work anywhere.
#    Part (b) ("RECOMPUTE every countable claim") is NOT. As written it encodes the layout
#    and the claims of ONE project — it expects, among others:
#        admin/lib/*.js                   (module inventory + a require()-able tool registry)
#        admin/lib/godmode-tools.js       with a getToolNames() export
#        MDs/FILE-ROLES.md                documenting every admin/lib module
#        MDs/Open-Problems.md             whose line count CLAUDE.md/CONTEXT-MANIFEST.md claim
#        version.json                     compared against the git tag on HEAD
#    On a project without those, part (b) does not fail loudly — its checks go SKIP/NOT-FOUND
#    and the suite can still print a green-looking tail. That is precisely the failure this
#    file exists to catch, so ADAPT part (b) to your own countable claims (or delete it)
#    before you trust its numbers.
# 3. The audited project root is NOT baked in: set GOV_SELFTEST_PROJECT, or put it in
#    ~/.claude/.governance-local.env. See ENV OVERRIDES below.
# ------------------------------------------------------------------------------------------
#
# WHY THIS EXISTS
# ---------------
# `~/.claude/governance-installer/verify.sh` reports "37/37 passed" from 18 `[ -f ... ]` file
# tests and 5 `s.hooks?.<Event>` truthiness tests. It never RUNS a hook and never RECOMPUTES a
# documented number. Its admission criterion is EXISTENCE, not EXECUTION. The measured
# consequence on this machine (2026-09-01): every hook that CAN `exit 2` worked, and every hook
# that CANNOT was broken — the correlation was exact in both directions, and verify.sh was green
# through all of it. A guard that exits 0 while printing the WRONG advice is invisible to an
# exit-code-only check; canonical-cwd-check.sh does exactly that.
#
# This script replaces that criterion with three parts:
#   (a) EXECUTE every hook registered in settings.json, in a sandbox, asserting BOTH the exit
#       code AND the text it printed, in BOTH directions (a must-block case and a must-allow
#       case). A hook with no constructible failing case is reported UNCOVERED, never green.
#   (b) RECOMPUTE every countable claim the docs make and fail on mismatch. Recomputed values
#       are written to docs/context/GENERATED-FACTS.md between machine-owned markers. This tool
#       REPORTS drift; repairing prose is a human's job, so no other doc is touched.
#   (c) MUTATION-CHECK ITSELF. Every hook is broken in a sandbox copy and the assertions from
#       (a) must go RED. An assertion set that a dead hook still passes is not a check, and is
#       reported UNCOVERED.
#
# EXIT CODES
#   0 — all green (0 failures, 0 uncovered)
#   1 — something is red (a failed assertion, a surviving mutant, or an uncovered hook)
#   2 — NEVER emitted by this script. Reserved so a caller can use `exit 2` for its own gate
#       semantics (e.g. a PreToolUse/Stop hook that wants to block on our exit 1) without
#       colliding with ours.
#
# SAFETY
#   * Nothing outside the sandbox is written. The sandbox is created under $HOME/.gov-selftest
#     (NOT under /tmp, */temp/* or */logs/* — the collision guard's scope filter skips those
#     paths, which would silently make its coverage vacuous).
#   * Hooks run with HOME pointed at the sandbox, so every state file, token, lock and mirror
#     target they compute lands inside it.
#   * A `git` shim is prepended to PATH for every hook run. Network subcommands (clone/push/
#     pull/fetch/remote) are DENIED unconditionally; mutating subcommands are allowed only
#     inside the sandbox. end-session.sh really does `git clone`+`git push` to a public repo
#     when a flag file exists — the shim is what makes running it safe.
#   * GOV_NOTIFY=0 / GOV_WHATSAPP=0 keep the selftest off the owner's phone.
#
# USAGE
#   bash ~/.claude/hooks/governance/governance-selftest.sh [--no-mutation] [--keep-sandbox] [--only=a.sh,b.sh]
#
# ENV OVERRIDES
#   GOV_SELFTEST_PROJECT   project root audited by part (b)   (no baked default)
#                          If unset, read from ~/.claude/.governance-local.env; else
#                          discovered by walking up from $PWD to the nearest
#                          docs/context/CONTEXT-MANIFEST.md.
#   GOV_SELFTEST_HOME      real ~/.claude to read hooks+settings from (default: $HOME/.claude)
#   GOV_SELFTEST_SANDBOX   sandbox parent dir                 (default: $HOME/.gov-selftest)
#   GOV_SELFTEST_NO_WRITE  1 = do not write GENERATED-FACTS.md (report only)

set +e
umask 077

# ── Options ──────────────────────────────────────────────────────────────────────────────────
DO_MUTATION=1
KEEP_SANDBOX=0
# --only=<a.sh>[,<b.sh>...] (2026-09-29, HITL-removal board, QA condition 2): run Part A for the
# named hooks only (by basename, mutants included) and skip the disk-vs-registration scan, Part B
# and the live invariant. A scoped run is a fast check while editing, never a verdict: it prints
# SCOPED in its summary, and like every direct run it only invalidates the .result file.
ONLY=""
_only_next=0
for _a in "$@"; do
  if [ "$_only_next" = 1 ]; then ONLY="$_a"; _only_next=0; continue; fi
  case "$_a" in
    --only=*)       ONLY="${_a#--only=}" ;;
    --only)         _only_next=1 ;;
    --no-mutation)  DO_MUTATION=0 ;;
    --keep-sandbox) KEEP_SANDBOX=1 ;;
    -h|--help)      sed -n '2,50p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$_a" >&2; exit 1 ;;
  esac
done

# Part (b) audits ONE project, at a root that is NAMED rather than discovered from $PWD: a
# session's shell is routinely parked on a retired duplicate of the repo (that is the failure
# canonical-cwd-check.sh exists for), and a $PWD walk would then cheerfully audit the tombstoned
# copy and report its stale numbers as fact. The walk is only the last-resort fallback.
# The named root is read from the ENVIRONMENT, never carried in this file: this script ships
# in a PUBLIC bundle, where a hardcoded checkout path is both a leak and wrong on every other
# machine. Precedence: $GOV_SELFTEST_PROJECT, then GOV_SELFTEST_PROJECT out of the machine-local
# ~/.claude/.governance-local.env (see .governance-local.env.example), then the $PWD walk.
PROJECT="${GOV_SELFTEST_PROJECT:-}"
if [ -z "$PROJECT" ] && [ -f "$HOME/.claude/.governance-local.env" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.claude/.governance-local.env" 2>/dev/null || true
  PROJECT="${GOV_SELFTEST_PROJECT:-}"
fi
if [ -z "$PROJECT" ] || [ ! -d "$PROJECT" ]; then
  _d="$PWD"
  while [ -n "$_d" ] && [ "$_d" != "/" ]; do
    [ -f "$_d/docs/context/CONTEXT-MANIFEST.md" ] && { PROJECT="$_d"; break; }
    _d="$(dirname "$_d")"
  done
fi
[ -n "$PROJECT" ] || PROJECT="(unset: set GOV_SELFTEST_PROJECT in ~/.claude/.governance-local.env)"
CHOME="${GOV_SELFTEST_HOME:-$HOME/.claude}"
SETTINGS="$CHOME/settings.json"
HOOKS_ROOT="$CHOME/hooks"
GOV_DIR="$HOOKS_ROOT/governance"

PASS=0; FAIL=0; UNCOV=0
FAIL_LOG=""     # accumulated "file :: expected vs actual" lines
UNCOV_LOG=""

# ── Sandbox ──────────────────────────────────────────────────────────────────────────────────
# Deliberately NOT mktemp -d: the system temp dir on both platforms contains a path segment
# ("/tmp/", "/Temp/") that file-collision-guard.sh and file-collision-record.sh skip outright.
# A sandbox there would make both hooks exit 0 on every input and look "covered" while testing
# nothing at all.
SBX_PARENT="${GOV_SELFTEST_SANDBOX:-$HOME/.gov-selftest}"
SBX="$SBX_PARENT/run-$$"
SBX_HOME="$SBX/home"
SBX_BIN="$SBX/bin"
SBX_HOOKS="$SBX/hooks"          # mutant tree (part c)
IO_OUT="$SBX/io.out"; IO_ERR="$SBX/io.err"
GIT_VIOL="$SBX/git-violations.log"

REAL_GIT="$(command -v git 2>/dev/null)"
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1

cleanup() {
  [ "$KEEP_SANDBOX" = "1" ] && { printf '\nsandbox kept at: %s\n' "$SBX"; return 0; }
  case "$SBX" in "$SBX_PARENT"/run-*) rm -rf "$SBX" 2>/dev/null ;; esac
}
trap cleanup EXIT

mkdir -p "$SBX_HOME/.claude/logs" "$SBX_BIN" 2>/dev/null || {
  printf 'cannot create sandbox at %s\n' "$SBX" >&2; exit 1; }
: > "$GIT_VIOL"

# git shim — the containment boundary for hook execution.
cat > "$SBX_BIN/git" <<'GITSHIM'
#!/usr/bin/env bash
# selftest git shim. Reads pass through. Network subcommands are denied outright. Mutating
# subcommands are allowed only when the repo they target lives inside the selftest sandbox.
# Global options are skipped the way git reads them (round 3b, 2026-10-02): `-C <dir>` (cumulative;
# a relative one is taken from the previous), `-c <k=v>`, and `--git-dir` / `--work-tree` /
# `--namespace` with a separate or an `=` value. MEASURED before: the loop took the word after `-C`
# (or `-c`) as the subcommand, so `git -C <outside> push <decoy> master` pushed and
# `git -C <outside> commit` committed, neither logged. Every place git can be pointed at (the -C
# directory, --git-dir, --work-tree, GIT_DIR, GIT_WORK_TREE) must be inside the sandbox for a
# mutating subcommand. Read-only forms of `remote` and `config` pass anywhere (pr-watch-guard.sh runs
# `git -C "$CWD" remote get-url origin`; end-session.sh reads `config --get core.hooksPath`).
_args=("$@"); _n=${#_args[@]}; _i=0; _si=-1
_sub=""; _dir="$PWD"; _gd=""; _wt=""
_abs() { case "$1" in /*|[A-Za-z]:[\\/]*) printf '%s' "$1" ;; *) printf '%s/%s' "$2" "$1" ;; esac; }
while [ "$_i" -lt "$_n" ]; do
  _a="${_args[$_i]}"
  case "$_a" in
    -C)          _i=$((_i+1)); _dir=$(_abs "${_args[$_i]:-}" "$_dir") ;;
    -c|--namespace) _i=$((_i+1)) ;;
    --git-dir)   _i=$((_i+1)); _gd=$(_abs "${_args[$_i]:-}" "$_dir") ;;
    --git-dir=*) _gd=$(_abs "${_a#--git-dir=}" "$_dir") ;;
    --work-tree) _i=$((_i+1)); _wt=$(_abs "${_args[$_i]:-}" "$_dir") ;;
    --work-tree=*) _wt=$(_abs "${_a#--work-tree=}" "$_dir") ;;
    -*) ;;
    *) _sub="$_a"; _si=$_i; break ;;
  esac
  _i=$((_i+1))
done
_sbxm=$(cygpath -m "$GOV_SELFTEST_SBX" 2>/dev/null) || _sbxm="$GOV_SELFTEST_SBX"
# _in_sbx <path> -> 0 when the path is inside the sandbox; an existing directory is resolved first
# (so `..` and the C:/ spelling cannot walk out of the prefix test).
_in_sbx() {
  local r
  r=$(cd "$1" 2>/dev/null && pwd) || r="$1"
  case "$r" in "$GOV_SELFTEST_SBX"|"$GOV_SELFTEST_SBX"/*|"$_sbxm"|"$_sbxm"/*) return 0 ;; esac
  return 1
}
_targets_in_sbx() {
  local t
  for t in "$_dir" "$_gd" "$_wt" "${GIT_DIR:+$(_abs "$GIT_DIR" "$PWD")}" "${GIT_WORK_TREE:+$(_abs "$GIT_WORK_TREE" "$PWD")}"; do
    [ -n "$t" ] || continue
    _in_sbx "$t" || { _outside="$t"; return 1; }
  done
  return 0
}
# Read-only forms that would otherwise fall in a denied list: `remote` alone, `remote -v`,
# `remote get-url ...`; `config` with a read action (--get*, -l/--list, or `get`/`list` as its
# first word) and no write action.
_ro=0
case "$_sub" in
  remote)
    _r1="${_args[$((_si+1))]:-}"
    case "$_r1" in
      ""|-v|--verbose) [ "$_n" -le $((_si+2)) ] && _ro=1 ;;
      get-url) _ro=1 ;;
    esac ;;
  config)
    _w=0; _j=$((_si+1))
    case "${_args[$_j]:-}" in get|list) _ro=1 ;; set|unset|rename-section|remove-section|edit) _w=1 ;; esac
    while [ "$_j" -lt "$_n" ]; do
      case "${_args[$_j]}" in
        --get|--get-all|--get-regexp|--get-urlmatch|-l|--list|--get-color|--get-colorbool) _ro=1 ;;
        --add|--unset|--unset-all|--replace-all|--rename-section|--remove-section|-e|--edit) _w=1 ;;
      esac
      _j=$((_j+1))
    done
    [ "$_w" = 1 ] && _ro=0 ;;
esac
[ "$_ro" = 1 ] && exec "$GOV_SELFTEST_REAL_GIT" "$@"
case "$_sub" in
  clone|push|pull|fetch|remote|submodule|am|request-pull|send-email)
    # ONE exception, for the end-session publish rehearsal (r2 finding 10, 2026-10-01): a `pull` or
    # `push` passes only when the case named a bare repo INSIDE the sandbox in
    # GOV_SELFTEST_LOCAL_REMOTE, the repo the command runs in is inside the sandbox, and that repo's
    # origin fetch AND push URL are exactly that bare repo. Unset (every other case) = denied as before.
    if [ -n "${GOV_SELFTEST_LOCAL_REMOTE:-}" ] && { [ "$_sub" = pull ] || [ "$_sub" = push ]; }; then
      _inside=0
      case "$GOV_SELFTEST_LOCAL_REMOTE" in "$GOV_SELFTEST_SBX"/*|"$_sbxm"/*) _inside=1 ;; esac
      _targets_in_sbx || _inside=0
      # Only the EXACT commands end-session.sh runs (round 3, 2026-10-02): `git pull --rebase
      # --autostash origin master` and `git push origin master`, nothing before the subcommand. The
      # old rule let any `--*` through (`--repo=<url>`, `--receive-pack=<cmd>`, `--exec=`), and a
      # URL or any other remote spelled on the command line is refused, whatever origin says.
      case "$_sub" in
        pull) { [ "$#" = 5 ] && [ "$1" = pull ] && [ "$2" = --rebase ] && [ "$3" = --autostash ] \
                && [ "$4" = origin ] && [ "$5" = master ]; } || _inside=0 ;;
        push) { [ "$#" = 3 ] && [ "$1" = push ] && [ "$2" = origin ] && [ "$3" = master ]; } || _inside=0 ;;
      esac
      if [ "$_inside" = 1 ] \
         && [ "$("$GOV_SELFTEST_REAL_GIT" -C "$_dir" remote get-url origin 2>/dev/null)" = "$GOV_SELFTEST_LOCAL_REMOTE" ] \
         && [ "$("$GOV_SELFTEST_REAL_GIT" -C "$_dir" remote get-url --push origin 2>/dev/null)" = "$GOV_SELFTEST_LOCAL_REMOTE" ]; then
        exec "$GOV_SELFTEST_REAL_GIT" "$@"
      fi
    fi
    printf '%s DENIED-NETWORK git %s (cwd=%s)\n' "$(date +%s)" "$_sub" "$PWD" >> "$GOV_SELFTEST_SBX/git-violations.log"
    echo "selftest: network git subcommand '$_sub' denied" >&2
    exit 1 ;;
  init|add|commit|checkout|reset|stash|tag|merge|rebase|cherry-pick|revert|restore|switch|rm|mv|update-index|update-ref|gc|worktree|config|apply)
    if ! _targets_in_sbx; then
      printf '%s DENIED-OUTSIDE git %s (dir=%s)\n' "$(date +%s)" "$_sub" "$_outside" >> "$GOV_SELFTEST_SBX/git-violations.log"
      echo "selftest: mutating git '$_sub' outside the sandbox denied" >&2
      exit 1
    fi ;;
esac
exec "$GOV_SELFTEST_REAL_GIT" "$@"
GITSHIM
chmod +x "$SBX_BIN/git" 2>/dev/null

# ── Result plumbing ──────────────────────────────────────────────────────────────────────────
# MUT=1 suppresses reporting and only counts failures — that is how a mutant is judged.
MUT=0
CASE_FAILS=0
CUR_SCRIPT=""
CUR_LABEL=""

_snip() { printf '%s' "$1" | tr '\n' '|' | head -c 320; }

_ok()  { CASE_FAILS=$CASE_FAILS; [ "$MUT" = 1 ] && return 0; PASS=$((PASS+1)); printf '    [PASS] %s\n' "$1"; }
# _na <check> <why>: a Part B check whose SUBJECT does not exist in the audited project (e.g. the
# admin/lib inventory in a project with no admin/). Printed, never counted as a pass. It is NOT the
# empty-extraction case — a subject that exists and yields no claim stays a FAIL.
_na()  { [ "$MUT" = 1 ] && return 0; NA_N=$((${NA_N:-0}+1)); printf '    [N/A]  %s — %s\n' "$1" "$2"; }
_bad() {
  CASE_FAILS=$((CASE_FAILS+1))
  [ "$MUT" = 1 ] && return 0
  FAIL=$((FAIL+1))
  printf '    [FAIL] %s\n           %s\n' "$1" "$2"
  FAIL_LOG="$FAIL_LOG
  $CUR_SCRIPT — $1
      $2"
}

expect_rc()   { if [ "$RC" = "$1" ]; then _ok "$2 (rc=$1)"; else _bad "$2" "expected rc=$1, actual rc=$RC; output: $(_snip "$BOTH")"; fi; }
expect_has()  { case "$BOTH" in *"$1"*) _ok "$2" ;; *) _bad "$2" "expected output to contain [$1]; actual: $(_snip "$BOTH")" ;; esac; }
expect_not()  { case "$BOTH" in *"$1"*) _bad "$2" "output must NOT contain [$1]; actual: $(_snip "$BOTH")" ;; *) _ok "$2" ;; esac; }
expect_quiet(){ if [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ]; then _ok "$1"; else _bad "$1" "expected NO stdout; actual: $(_snip "$OUT")"; fi; }
expect_file() { if [ -f "$1" ]; then _ok "$2"; else _bad "$2" "expected file to exist: $1"; fi; }
expect_nofile(){ if [ ! -f "$1" ]; then _ok "$2"; else _bad "$2" "file must NOT exist: $1"; fi; }
expect_grep() { if grep -qF "$1" "$2" 2>/dev/null; then _ok "$3"; else _bad "$3" "expected [$1] inside $2; actual: $(_snip "$(cat "$2" 2>/dev/null)")"; fi; }
expect_nogrep() { if grep -qF "$1" "$2" 2>/dev/null; then _bad "$3" "[$1] must NOT appear inside $2; actual: $(_snip "$(cat "$2" 2>/dev/null)")"; else _ok "$3"; fi; }

# ── Hook runner ──────────────────────────────────────────────────────────────────────────────
# $1 script, $2 cwd, $3 session id, $4 stdin payload
_run() {
  local script="$1" cwd="$2" sid="${3:-selftest-sid}" payload="$4"
  # Args 5+ are passed THROUGH to the script (2026-09-14). Some hooks branch on a CLI flag as well
  # as on the payload — sync-governance-copies.sh has `--sync-all` and `--sync-if-drifted` — and a
  # runner that silently dropped them would run the default path while the case name claimed
  # otherwise: a green with no relation to the thing named in it.
  local extra=(); [ "$#" -gt 4 ] && { shift 4; extra=("$@"); }
  : > "$IO_OUT"; : > "$IO_ERR"
  local runner=(bash "$script" ${extra[@]+"${extra[@]}"})
  # _RUN_TIMEOUT (default 60 s) is raised by a case whose run does real git work - the end-session
  # publish rehearsal measured 60+ s per run on a loaded machine (2026-10-01) and was killed (rc 124).
  [ "$HAVE_TIMEOUT" = 1 ] && runner=(timeout "${_RUN_TIMEOUT:-60}" bash "$script" ${extra[@]+"${extra[@]}"})
  ( cd "$cwd" 2>/dev/null || exit 97
    printf '%s' "$payload" | env \
      HOME="$SBX_HOME" USERPROFILE="$SBX_HOME" \
      PATH="$SBX_BIN:$PATH" \
      GOV_SELFTEST_SBX="$SBX" GOV_SELFTEST_REAL_GIT="$REAL_GIT" \
      GOV_NOTIFY=0 GOV_WHATSAPP=0 GOVERNANCE_UPDATE_CHECK=0 \
      GOVERNANCE_HOOKS=1 GOV_ROLE_FRAMEWORK=1 GOV_COLLISION_GUARD=1 \
      GOV_SESSION_ID="$sid" GIT_TERMINAL_PROMPT=0 \
      ${_RUN_ENV[@]+"${_RUN_ENV[@]}"} \
      "${runner[@]}"
  ) > "$IO_OUT" 2> "$IO_ERR"
  RC=$?
  OUT="$(cat "$IO_OUT" 2>/dev/null)"
  ERR="$(cat "$IO_ERR" 2>/dev/null)"
  BOTH="$OUT
$ERR"
}
run_hook()  { _run "$CUR_SCRIPT" "$@"; }              # the script under test (real or mutant)
run_fixture(){ _run "$CUR_ORIG" "$@"; }               # always the pristine hook (fixture setup)

# ── Sandbox fixtures ─────────────────────────────────────────────────────────────────────────
sbx_git() {   # never let the selftest itself touch a repo outside the sandbox
  case "$1" in "$SBX"*) ;; *) printf 'refusing git outside sandbox: %s\n' "$1" >&2; return 1 ;; esac
  local d="$1"; shift
  "$REAL_GIT" -C "$d" "$@" >/dev/null 2>&1
}

fx_project() {  # $1 dir, $2 role, $3 canonical_working_copy value
  local d="$1" role="$2" canon="$3"
  mkdir -p "$d/docs/context" "$d/Plans" "$d/admin/lib" "$d/MDs" 2>/dev/null
  printf '# Sandbox project\n\n## Canonical Working Copy\n\n- %s\n' "$canon" > "$d/CLAUDE.md"
  {
    printf -- '---\ntype: manifest\n---\n\n'
    printf -- '- **canonical_working_copy = `%s`** — the canonical working copy.\n' "$canon"
    printf 'canonical_working_copy: %s\n' "$canon"
  } > "$d/docs/context/CONTEXT-MANIFEST.md"
  printf '# PLAN\nProject version: v9.9.9\n'  > "$d/Plans/PLAN.md"
  printf '# MEMORY\nv9.9.9\n'                 > "$d/docs/context/MEMORY.md"
  printf '# HANDOFF\npointer\n'               > "$d/docs/context/HANDOFF.md"
  printf '%s\n' "$role"                       > "$d/.governance-role"
}

fx_state_reset() {   # wipe every piece of per-session governance state in the sandbox HOME
  rm -rf "$SBX_HOME/.claude/logs" 2>/dev/null
  mkdir -p "$SBX_HOME/.claude/logs" 2>/dev/null
}
sess_dir() { printf '%s/.claude/logs/sessions/%s' "$SBX_HOME" "$1"; }
fx_changes() {  # $1 sid, then one path per remaining arg
  local sid="$1"; shift
  local d; d="$(sess_dir "$sid")"; mkdir -p "$d" 2>/dev/null
  : > "$d/.gov-session-changes"
  for p in "$@"; do printf '%s\n' "$p" >> "$d/.gov-session-changes"; done
}
fx_token() {   # $1 = seconds until expiry (negative for an expired token); absent = remove
  local t="$SBX_HOME/.claude/logs/governance-success-token.json"
  if [ -z "$1" ]; then rm -f "$t" 2>/dev/null; return 0; fi
  printf '{"task":"selftest","expires_at_epoch":%s}\n' "$(( $(date +%s) + $1 ))" > "$t"
}

# JSON payload builders (posix paths only — no backslashes to escape)
pl_session()  { printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$2" "$1"; }
pl_prompt()   { printf '{"session_id":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$2" "$1" "$3"; }
pl_pre()      { printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$2" "$1" "$3"; }
pl_post()     { printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"},"tool_response":{"filePath":"%s"}}' "$2" "$1" "$3" "$3"; }
pl_plain()    { printf '{"session_id":"%s","cwd":"%s","hook_event_name":"%s"}' "$2" "$1" "$3"; }
# canonical-cwd-check.sh compares the SPELLING of paths, so its payload must carry the cwd the
# way Claude Code really sends it on Windows: a drive path with backslashes, JSON-escaped. Sending
# the msys /c/... form makes the guard's own normaliser compare "/c/x" against "c/x" and report a
# mismatch that does not exist — a fixture artefact that would read as a hook bug.
pl_session_win() { printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$2" "$(_winform "$1" | sed 's/\\/\\\\/g')"; }

# ── Case definitions ─────────────────────────────────────────────────────────────────────────
# One function per hook. Each MUST contain at least one must-block/must-fire case and one
# must-allow case, and MUST assert printed text — not only the exit code.
#
# This table is a table of CASES, not of hooks. The hook list itself always comes from
# settings.json; a hook registered there with no entry here is reported UNCOVERED.
case_fn_for() {
  case "$1" in
    canonical-cwd-check.sh)     echo case_canonical_cwd ;;
    pre-session.sh)             echo case_pre_session ;;
    pre-task.sh)                echo case_pre_task ;;
    plan-gate.sh)               echo case_plan_gate ;;
    parallel-import.sh)         echo case_parallel_import ;;
    file-collision-guard.sh)    echo case_collision_guard ;;
    governance-guard.sh)        echo case_governance_guard ;;
    pre-write.sh)               echo case_pre_write ;;
    post-milestone.sh)          echo case_post_milestone ;;
    sync-governance-copies.sh)  echo case_sync_copies ;;
    file-collision-record.sh)   echo case_collision_record ;;
    check-full-finish.sh)       echo case_check_full_finish ;;
    check-docs-updated.sh)      echo case_check_docs ;;
    pre-done.sh)                echo case_pre_done ;;
    end-session.sh)             echo case_end_session ;;
    pii-gate-pretooluse.sh)     echo case_pii_gate ;;
    selftest-advisory-stop.sh)  echo case_selftest_advisory ;;
    close-report.sh)            echo case_close_report ;;
    close-completeness.sh)      echo case_close_completeness ;;
    no-local-compute.sh)        echo case_no_local_compute ;;
    deny-git-bypass.sh)         echo case_deny_git_bypass ;;
    pr-watch-guard.sh)          echo case_pr_watch_guard ;;
    cross-session-guard.sh)     echo case_cross_session_guard ;;
    render-gate.sh)             echo case_render_gate ;;
    render-rules-read.sh)       echo case_render_rules_read ;;
    bootstrap-gate.sh)          echo case_bootstrap_gate ;;    # PreToolUse gate + PostToolUse --mark (2026-09-29)
    consent-guard.sh)           echo case_consent_guard ;;     # PreToolUse deny of consent acts (2026-09-30, S1/C3/T4)
    *) echo "" ;;
  esac
}

# --- gov-update.sh / gov-release.sh / release-manifest.sh / settings-merge.js (2.0.0) -----------
case_skill_prose() {
  # Prose has no hook to enforce it, so the HITL removal (2026-09-29, owner decision; board QA
  # condition 6) is pinned here: the stop-and-ask phrases must stay OUT of the canonical-file / close
  # skills and docs, and the replacements must stay IN - in the live copy AND the shipped bundle copy.
  # full-finish is deliberately not in the absent-list: its release-state wait is OUT of scope.
  # Negative control, proven once on 2026-09-29: restoring "Wait for user decision before continuing."
  # in pre-close-check turned this case red.
  local base f hits phr
  local -a roots=("$CHOME")
  [ -d "$CHOME/governance-installer/bundle" ] && roots+=("$CHOME/governance-installer/bundle")
  local -a files=(skills/pre-close-check/SKILL.md skills/live-state-orchestrator/SKILL.md
                  skills/parallel-session-merge/SKILL.md skills/context-governance/SKILL.md
                  skills/bootstrapper/SKILL.md skills/init-governance/SKILL.md
                  skills/plan-and-execute/SKILL.md docs/GOVERNANCE-AGENT-GUIDE.md)
  for base in "${roots[@]}"; do
    CUR_SCRIPT="$base (HITL prose)"
    hits=""
    for f in "${files[@]}"; do
      [ -f "$base/$f" ] || continue
      for phr in 'Wait for user decision' 'ask user how to resolve' 'After user approval' 'כן, אני יודע'; do
        grep -qiF "$phr" "$base/$f" 2>/dev/null && hits="$hits $f:'$phr'"
      done
    done
    if [ -z "$hits" ]; then _ok "no stop-and-ask phrase in the canonical/close skills and guide ($base)"
    else _bad "no stop-and-ask phrase in the canonical/close skills and guide ($base)" "found:$hits"; fi
    if grep -qF 'close-push.sh' "$base/skills/live-state-orchestrator/SKILL.md" 2>/dev/null; then
      _ok "live-state-orchestrator pushes through close-push.sh ($base)"
    else _bad "live-state-orchestrator pushes through close-push.sh ($base)" "Step 8b does not name close-push.sh"; fi
    if grep -qF 'formerly Stop-Report' "$base/docs/GOVERNANCE-AGENT-GUIDE.md" 2>/dev/null; then
      _ok "agent guide keeps the 'formerly Stop-Report' alias ($base)"
    else _bad "agent guide keeps the 'formerly Stop-Report' alias ($base)" "old references would no longer resolve"; fi
    # Push at session close is the user's choice (2026-09-30, legal C3/C4/C8; DRAFTS D.4-D.6). Every
    # skill that names close-push.sh as the push path says it pushes only when that choice is on,
    # and that a session never turns it on or accepts terms. The CLAUDE.md Step 5 line (live file;
    # the bundle template is rendered from it) says "only if push at session close is on".
    # Controls, proven once on 2026-09-30 by running this function alone on a sandbox copy: every
    # text right -> 0 red; each of six mutants (D.5 sentence dropped from live-state-orchestrator,
    # "never accept terms" dropped from the bundle impact-safe-executor, the old "turns the push off
    # everywhere" in the guide, an automatic-update switch line or an invitation to put
    # GOV_ACCEPT_TERMS in the env example, the old Step 5 in CLAUDE.md) -> exactly one red. The
    # switch name is written GOV_AUTO[_]UPDATE below so P8's no-auto-update grep of bundle/ stays clean.
    hits=""
    for f in skills/live-state-orchestrator/SKILL.md skills/plan-and-execute/SKILL.md \
             skills/impact-safe-executor/SKILL.md; do
      [ -f "$base/$f" ] || { hits="$hits $f:missing"; continue; }
      grep -qF 'It pushes only when push at session close is on on this machine' "$base/$f" 2>/dev/null \
        || hits="$hits $f:'pushes only when ... on'"
      grep -qF 'Never turn it' "$base/$f" 2>/dev/null && grep -qF 'never accept terms, yourself' "$base/$f" 2>/dev/null \
        || hits="$hits $f:'never turn it on, never accept terms'"
    done
    if grep -qF 'A session never turns it on, and never accepts terms' "$base/docs/GOVERNANCE-AGENT-GUIDE.md" 2>/dev/null; then :
    else hits="$hits docs/GOVERNANCE-AGENT-GUIDE.md:'A session never turns it on, and never accepts terms'"; fi
    if grep -qF 'turns the push off everywhere' "$base/docs/GOVERNANCE-AGENT-GUIDE.md" 2>/dev/null; then
      hits="$hits docs/GOVERNANCE-AGENT-GUIDE.md:stale 'GOV_CLOSE_PUSH=0 turns the push off everywhere' (it is a pause)"
    fi
    if [ -z "$hits" ]; then _ok "close skills and guide: push only if push at session close is on; a session never enables or accepts ($base)"
    else _bad "close skills and guide: push only if push at session close is on; a session never enables or accepts ($base)" "found:$hits"; fi
    if [ "$base" = "$CHOME" ]; then f="CLAUDE.md"; else f="CLAUDE.md.template"; fi
    if [ -f "$base/$f" ]; then
      if grep -qF "then commit and push the session's work" "$base/$f" 2>/dev/null \
         || ! grep -qF 'only if push at session close is on' "$base/$f" 2>/dev/null; then
        _bad "$f Step 5: commit, and push only if push at session close is on ($base)" "Step 5 still says 'then commit and push the session's work' or lacks 'only if push at session close is on' (DRAFTS D.4, legal C4)"
      else _ok "$f Step 5: commit, and push only if push at session close is on ($base)"; fi
    fi
    if [ "$base" != "$CHOME" ] && [ -f "$base/.governance-local.env.example" ]; then
      hits=""
      grep -qE '^[[:space:]]*#?[[:space:]]*GOV_AUTO[_]UPDATE=' "$base/.governance-local.env.example" 2>/dev/null \
        && hits="$hits an automatic-update switch line (this version has no automatic update)"
      grep -qF 'Do not put GOV_ACCEPT_TERMS=1 here' "$base/.governance-local.env.example" 2>/dev/null \
        || hits="$hits no 'Do not put GOV_ACCEPT_TERMS=1 here'"
      grep -qF 'GOV_CLOSE_PUSH=0 - pauses push at session close' "$base/.governance-local.env.example" 2>/dev/null \
        || hits="$hits no 'GOV_CLOSE_PUSH=0 - pauses push at session close'"
      if [ -z "$hits" ]; then _ok ".governance-local.env.example: the A17 block, no automatic-update switch ($base)"
      else _bad ".governance-local.env.example: the A17 block, no automatic-update switch ($base)" "found:$hits"; fi
    fi
  done
}

case_consent_lib() {
  # consent-lib.sh is a library (sourced, never registered), so the registration loop never runs
  # it. tests/test-consent-lib.sh asserts, in a sandbox HOME, both directions of: the close-push
  # predicate (no record / off / on / stale record / stale terms / GOV_CLOSE_PUSH=0 env, file,
  # quoted), gov_auto_update_on false under GOV_AUTO_UPDATE=1 and a planted record, CRLF == LF
  # hashes, the terms-summary extraction, the atomic writer, and the agent refusal + its override.
  # A run that checked nothing is a failure: pass>0 is asserted.
  local _o _rc _p _f
  CUR_SCRIPT="$GOV_DIR/tests/test-consent-lib.sh"
  if [ ! -f "$GOV_DIR/consent-lib.sh" ] || [ ! -f "$GOV_DIR/tests/test-consent-lib.sh" ]; then
    _bad "consent-lib.sh and its test exist" "missing under $GOV_DIR - _common.sh, install.sh and close-push.sh source it"
    return 0
  fi
  _o=$(bash "$GOV_DIR/tests/test-consent-lib.sh" </dev/null 2>&1); _rc=$?
  _p=$(printf '%s' "$_o" | sed -n 's/.*consent-lib selftest: pass=\([0-9]*\) fail=\([0-9]*\).*/\1/p' | tail -1)
  _f=$(printf '%s' "$_o" | sed -n 's/.*consent-lib selftest: pass=\([0-9]*\) fail=\([0-9]*\).*/\2/p' | tail -1)
  if [ "$_rc" = "0" ] && [ "${_p:-0}" -gt 0 ] && [ "${_f:-1}" = "0" ]; then
    _ok "tests/test-consent-lib.sh: pass=$_p fail=0 (predicate, parser, writer, agent refusal - both directions)"
  else
    _bad "tests/test-consent-lib.sh" "rc=$_rc pass=${_p:-?} fail=${_f:-?}: $(_snip "$(printf '%s' "$_o" | grep -E 'FAIL|pass=' | head -5)")"
  fi
}

case_terms_text() {
  # The accepted texts are not code, so no hook case reaches them (2026-09-30, plan task P9; legal
  # C1 C7 C8 C9 C11). tests/test-terms-text.sh checks NOTICE-AUTO-UPDATE.md and README.md of the
  # staging tree: no bare "no liability" (C9), the summary markers / footer / carve-outs, none of the
  # retired automatic-update claims, the printed summary's width and item count, no SessionEnd row
  # in the hook table, and TERMS-VERSION == the NOTICE footer - then kills one mutant per check and
  # proves a benign edit does not fire. A run that checked nothing is a failure: pass>0 is asserted.
  local _o _rc _p _f
  CUR_SCRIPT="$GOV_DIR/tests/test-terms-text.sh"
  if [ ! -f "$GOV_DIR/tests/test-terms-text.sh" ]; then
    _bad "tests/test-terms-text.sh exists" "missing under $GOV_DIR/tests - nothing checks that the terms text matches the code"
    return 0
  fi
  # The texts live in the installer tree, which an install from a clone elsewhere does not have
  # beside ~/.claude: that is an absent SUBJECT (N/A), not a pass and not a failure.
  if [ ! -f "$GOV_DIR/../../governance-installer/NOTICE-AUTO-UPDATE.md" ] && [ ! -f "$GOV_DIR/../../../NOTICE-AUTO-UPDATE.md" ]; then
    _na "NOTICE/README terms text" "no installer tree with NOTICE-AUTO-UPDATE.md beside $GOV_DIR (run tests/test-terms-text.sh <clone> by hand)"
    return 0
  fi
  _o=$(bash "$GOV_DIR/tests/test-terms-text.sh" </dev/null 2>&1); _rc=$?
  _p=$(printf '%s' "$_o" | sed -n 's/.*terms-text selftest: pass=\([0-9]*\) fail=\([0-9]*\).*/\1/p' | tail -1)
  _f=$(printf '%s' "$_o" | sed -n 's/.*terms-text selftest: pass=\([0-9]*\) fail=\([0-9]*\).*/\2/p' | tail -1)
  if [ "$_rc" = "0" ] && [ "${_p:-0}" -gt 0 ] && [ "${_f:-1}" = "0" ]; then
    _ok "tests/test-terms-text.sh: pass=$_p fail=0 (NOTICE/README checks (a)-(f), a mutant per check, a benign control)"
  else
    _bad "tests/test-terms-text.sh" "rc=$_rc pass=${_p:-?} fail=${_f:-?}: $(_snip "$(printf '%s' "$_o" | grep -E 'FAIL|pass=' | head -5)")"
  fi
}

case_release_invariants() {
  # Two push-gate conditions that are properties of the source, not of a run (2026-09-30, legal
  # plan P11; board T2 and T6). tests/test-release-invariants.sh checks the bundle tree: no script
  # but consent-lib.sh extracts a field from a consent record (T2 "one parser"), and the default
  # subset above names only real cases of tests/test-gov-update.sh and includes every T6 name - then
  # kills a mutant of each and proves a benign edit does not fire. pass>0 is asserted.
  local _o _rc _p _f
  CUR_SCRIPT="$GOV_DIR/tests/test-release-invariants.sh"
  if [ ! -f "$GOV_DIR/tests/test-release-invariants.sh" ]; then
    _bad "tests/test-release-invariants.sh exists" "missing under $GOV_DIR/tests - nothing checks T2 (one parser) or T6 (the subset)"
    return 0
  fi
  _o=$(bash "$GOV_DIR/tests/test-release-invariants.sh" </dev/null 2>&1); _rc=$?
  _p=$(printf '%s' "$_o" | sed -n 's/.*release-invariants selftest: pass=\([0-9]*\) fail=\([0-9]*\).*/\1/p' | tail -1)
  _f=$(printf '%s' "$_o" | sed -n 's/.*release-invariants selftest: pass=\([0-9]*\) fail=\([0-9]*\).*/\2/p' | tail -1)
  if [ "$_rc" = "0" ] && [ "${_p:-0}" -gt 0 ] && [ "${_f:-1}" = "0" ]; then
    _ok "tests/test-release-invariants.sh: pass=$_p fail=0 (T2 one parser, T6 subset; a mutant per check, a benign control)"
  else
    _bad "tests/test-release-invariants.sh" "rc=$_rc pass=${_p:-?} fail=${_f:-?}: $(_snip "$(printf '%s' "$_o" | grep -E 'FAIL|pass=' | head -5)")"
  fi
}

case_close_push() {
  # close-push.sh is not a hook (the close skills call it), so the registration loop never runs it.
  # Its --selftest builds local bare origins and asserts every branch in both directions: a private
  # clean repo is pushed AND the origin really holds HEAD; no upstream / close_push: off (BOM, CRLF,
  # no frontmatter, off only on the upstream) / GOV_CLOSE_PUSH=0 / PUBLIC or unknown visibility under
  # auto / a deploy signal / the session's own `on` / secrets in files, merges, binaries and commit
  # messages / PII for a non-private remote / push URLs, insteadOf rewrites, forks, mirrors / a
  # deleted upstream / a held lock / the framework's own clone are all held; a branch behind its
  # upstream is reported, never rebased; an unreachable remote exits 0. A suite that ran zero checks
  # is a failure: pass>0 is asserted.
  local _o _rc _p _f
  CUR_SCRIPT="$GOV_DIR/close-push.sh --selftest"
  if [ ! -f "$GOV_DIR/close-push.sh" ]; then
    _bad "close-push.sh exists" "missing at $GOV_DIR/close-push.sh - the close skills call it"
    return 0
  fi
  _o=$(bash "$GOV_DIR/close-push.sh" --selftest </dev/null 2>&1); _rc=$?
  _p=$(printf '%s' "$_o" | sed -n 's/.*close-push selftest: pass=\([0-9]*\) fail=\([0-9]*\).*/\1/p' | tail -1)
  _f=$(printf '%s' "$_o" | sed -n 's/.*close-push selftest: pass=\([0-9]*\) fail=\([0-9]*\).*/\2/p' | tail -1)
  if [ "$_rc" = "0" ] && [ "${_p:-0}" -gt 0 ] && [ "${_f:-1}" = "0" ]; then
    _ok "close-push.sh --selftest: pass=$_p fail=0 (pushes and holds, both directions)"
  else
    _bad "close-push.sh --selftest" "rc=$_rc pass=${_p:-?} fail=${_f:-?}: $(_snip "$(printf '%s' "$_o" | grep -E 'FAIL|pass=' | head -5)")"
  fi
}

# The default subset case_gov_update runs (one line, read by tests/test-release-invariants.sh).
GOV_SELFTEST_UPDATE_DEFAULT="T1 T2 T3 T7 T11 T13 T18 NOAUTO FETCHMSG MANIFEST CONSENT CLOSEPUSH M1 M2 M4 M8 M10"

case_gov_update() {
  #
  # gov-update.sh is not a registered hook (pre-session.sh calls it only as --recover-detached, and
  # 2.0.0 has no automatic update), so the registration loop
  # never executes it. Two layers, both run here:
  #   1. `gov-update.sh --selftest` — offline controls of the verification chain with throwaway
  #      keys: a valid archive verifies (positive control) and a tampered file, an extra file, a
  #      wrong key and an unsafe install map are each refused with the right reason.
  #   2. tests/test-gov-update.sh — the end-to-end suite in a sandbox HOME (fetch, apply, rollback,
  #      halts, locks, deferral, terms, key rotation, settings merge, pre-push rule) including the
  #      MUTANTS that must turn it red. The full suite takes ~40 min on Windows (every case builds
  #      and applies real releases), too long for a run that recurs every 6 h on a working machine, so
  #      this runs a representative subset by default — one valid apply (T1), the signature and
  #      checksum refusals (T2, T3), the source-machine guard (T7), the terms bump (T11),
  #      kill-mid-apply recovery both ways (T13), the settings merge incl. the removal of the old
  #      SessionEnd trigger (T18), "no automatic update" (NOAUTO, 2026-09-30), every --fetch exit
  #      path printing its one line (FETCHMSG, 2026-10-01, r2 findings 1/12/15), manifest determinism,
  #      the consent records and the install's push question (CONSENT, CLOSEPUSH - board T6, added
  #      2026-09-30), and the mutants proving those can fail (M1 M2 M4; M8 = the predicate forced
  #      true, M10 = a --fetch spawn put back into pre-session.sh). The list is
  #      GOV_SELFTEST_UPDATE_DEFAULT below; tests/test-release-invariants.sh checks that every name
  #      in it is a real case and that the T6 names are all there. GOV_SELFTEST_UPDATE_CASES
  #      overrides it; set it EMPTY to run every case. The full suite is run by hand before a
  #      release (README "Cutting a release").
  # A suite that ran zero checks is a failure, not a pass: pass>0 is asserted, not assumed.
  local _o _rc _p _f
  CUR_SCRIPT="$GOV_DIR/gov-update.sh --selftest"
  _o=$(GOV_NO_STDIN=1 bash "$GOV_DIR/gov-update.sh" --selftest </dev/null 2>&1); _rc=$?
  _p=$(printf '%s' "$_o" | sed -n 's/.*selftest: pass=\([0-9]*\) fail=\([0-9]*\).*/\1/p' | tail -1)
  _f=$(printf '%s' "$_o" | sed -n 's/.*selftest: pass=\([0-9]*\) fail=\([0-9]*\).*/\2/p' | tail -1)
  if [ "$_rc" = "0" ] && [ "${_p:-0}" -gt 0 ] && [ "${_f:-1}" = "0" ]; then
    _ok "gov-update.sh --selftest: pass=$_p fail=0 (positive AND negative controls)"
  else
    _bad "gov-update.sh --selftest" "rc=$_rc pass=${_p:-?} fail=${_f:-?}: $(_snip "$(printf '%s' "$_o" | grep -E 'FAIL|pass=' | head -5)")"
  fi
  CUR_SCRIPT="$GOV_DIR/tests/test-gov-update.sh"
  if [ ! -f "$GOV_DIR/tests/test-gov-update.sh" ]; then
    _bad "tests/test-gov-update.sh exists" "missing at $GOV_DIR/tests/test-gov-update.sh - the updater would ship untested"
    return 0
  fi
  _o=$(GOV_TEST_ONLY="${GOV_SELFTEST_UPDATE_CASES-$GOV_SELFTEST_UPDATE_DEFAULT}" bash "$GOV_DIR/tests/test-gov-update.sh" </dev/null 2>&1); _rc=$?
  _p=$(printf '%s' "$_o" | sed -n 's/^test-gov-update: pass=\([0-9]*\) fail=\([0-9]*\)$/\1/p' | tail -1)
  _f=$(printf '%s' "$_o" | sed -n 's/^test-gov-update: pass=\([0-9]*\) fail=\([0-9]*\)$/\2/p' | tail -1)
  if [ "$_rc" = "0" ] && [ "${_p:-0}" -gt 0 ] && [ "${_f:-1}" = "0" ]; then
    _ok "tests/test-gov-update.sh: pass=$_p fail=0 (incl. mutants M1 M2 M4 M8 M10 detected)"
  else
    _bad "tests/test-gov-update.sh" "rc=$_rc pass=${_p:-?} fail=${_f:-?}: $(_snip "$(printf '%s' "$_o" | grep -E '^  FAIL|pass=' | head -6)")"
  fi
}

# --- no automatic update in 2.0.0 (2026-09-30, owner decision 2026-09-29/30) ---------------------
case_no_auto_update() {
  # gov-update.sh is registered on NO hook event since 2026-09-30 (its SessionEnd trigger was
  # removed), so the registration loop never reaches it; the tail calls this. Three statically
  # checkable facts, each in both directions where a direction exists:
  #   1. no hooks template registers gov-update.sh on any event (a registered one would be an
  #      unattended apply the owner said must not exist) - the installer's bundle copy;
  #   2. pre-session.sh (live AND bundle copy) contains no `--apply-if-ready` and invokes gov-update.sh
  #      only as `--recover-detached` (user-facing text naming `--fetch` is not an invocation);
  #   3. `gov-update.sh --apply-at-session-end` is an unknown flag: rc 2 with the usage text, while a
  #      real mode (--status) answers rc 0 and says automatic updates are not available.
  # The behavioural proof (every old switch planted, nothing applies; a spawn put back goes red) is
  # tests/test-gov-update.sh [NOAUTO], [PRESESSION], M8, M10, run by case_gov_update.
  # _NA_TPLS / _NA_PS (newline lists) override the files checked - the case's own negative control.
  local tpl ps hits n=0 m=0 bad_inv
  local tpls="${_NA_TPLS-$CHOME/governance-installer/bundle/settings-hooks.json}"
  local pss="${_NA_PS-$GOV_DIR/pre-session.sh
$CHOME/governance-installer/bundle/hooks/governance/pre-session.sh}"
  while IFS= read -r tpl; do
    [ -n "$tpl" ] && [ -f "$tpl" ] || continue
    n=$((n+1)); CUR_SCRIPT="$tpl"
    hits=$(node -e 'let s;try{s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))}catch(e){console.log("UNPARSEABLE");process.exit(0)}for(const[e,g]of Object.entries(s.hooks||{}))for(const x of g)for(const h of (x.hooks||[]))if(/gov-update\.sh/.test(h.command||""))console.log(e+": "+h.command)' "$tpl" 2>&1)
    if [ -z "$hits" ]; then _ok "no hook event runs gov-update.sh ($tpl)"
    else _bad "no hook event runs gov-update.sh ($tpl)" "registered: $(_snip "$hits") - 2.0.0 has no automatic update"; fi
  done <<EOF
$tpls
EOF
  [ "$n" -gt 0 ] || { CUR_SCRIPT="(templates)"; _bad "a hooks template was checked" "none found in: $(_snip "$tpls") - zero checks ran"; }
  while IFS= read -r ps; do
    [ -n "$ps" ] && [ -f "$ps" ] || continue
    m=$((m+1)); CUR_SCRIPT="$ps"
    if grep -q -- '--apply-if-ready' "$ps" 2>/dev/null; then
      _bad "pre-session.sh never names --apply-if-ready ($ps)" "$(_snip "$(grep -n -- '--apply-if-ready' "$ps")")"
    else _ok "pre-session.sh never names --apply-if-ready ($ps)"; fi
    # Invocations: gov-update.sh followed by a --flag, on a line that is not a comment, not an echo
    # and not the assignment of the signed-manual sentence. Every one must be --recover-detached.
    bad_inv=$(grep -nE 'gov-update\.sh"?[[:space:]]+--[a-z]' "$ps" 2>/dev/null \
              | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE 'echo "|_GOV_SIGNED="' | grep -v -- '--recover-detached')
    if [ -z "$bad_inv" ]; then _ok "pre-session.sh invokes gov-update.sh only as --recover-detached ($ps)"
    else _bad "pre-session.sh invokes gov-update.sh only as --recover-detached ($ps)" "other invocation: $(_snip "$bad_inv")"; fi
    if grep -qE 'gov-update\.sh"[[:space:]]+--recover-detached' "$ps" 2>/dev/null; then
      _ok "  control: the recovery invocation is still there, so the scan above can see one ($ps)"
    else _bad "  control: the recovery invocation is still there ($ps)" "no --recover-detached call found - the invocation scan may be looking at the wrong shape"; fi
  done <<EOF
$pss
EOF
  [ "$m" -gt 0 ] || { CUR_SCRIPT="(pre-session)"; _bad "a pre-session.sh was checked" "none found in: $(_snip "$pss") - zero checks ran"; }
  #   4. verify.sh (r2 finding 8, 2026-10-01) - EXECUTED in the sandbox HOME, its printed text read:
  #      no line it prints says "automatic update(s)" (its updater section was headed that way), and
  #      the section's real heading is there, so the scan reads the right output. A missing installer
  #      tree is an absent subject (N/A). _NA_VERIFY overrides the file - the negative control.
  local vf vo
  vf="${_NA_VERIFY-$CHOME/governance-installer/verify.sh}"
  CUR_SCRIPT="$vf"
  if [ ! -f "$vf" ]; then
    _na "verify.sh prints no automatic-update claim" "no installer tree at $vf"
  else
    local vr=(bash "$vf"); [ "$HAVE_TIMEOUT" = 1 ] && vr=(timeout 120 bash "$vf")
    vo=$(cd "$SBX" 2>/dev/null && env HOME="$SBX_HOME" USERPROFILE="$SBX_HOME" PATH="$SBX_BIN:$PATH" \
         GOVERNANCE_HOOKS=0 "${vr[@]}" </dev/null 2>&1)
    if printf '%s\n' "$vo" | grep -qi 'automatic update'; then
      _bad "verify.sh prints no automatic-update claim ($vf)" "printed: $(_snip "$(printf '%s\n' "$vo" | grep -i 'automatic update')")"
    else _ok "verify.sh prints no automatic-update claim ($vf)"; fi
    case "$vo" in
      *"Manual updates and consent records:"*) _ok "  control: its updater section prints under 'Manual updates and consent records:' ($vf)" ;;
      *) _bad "  control: its updater section prints under 'Manual updates and consent records:' ($vf)" "not in its output: $(_snip "$vo")" ;;
    esac
  fi
  [ -n "${_NA_TPLS+x}${_NA_PS+x}${_NA_VERIFY+x}" ] && return 0   # negative-control runs stop at the static checks
  CUR_SCRIPT="$GOV_DIR/gov-update.sh"
  run_hook "$SBX" "sid-na-1" '' --apply-at-session-end
  expect_rc 2 "gov-update.sh --apply-at-session-end is an unknown flag (removed in 2.0.0)"
  expect_has "--apply [--force-live]" "  it prints the usage"
  expect_not "--apply-at-session-end" "  the usage lists no such mode"
  run_hook "$SBX" "sid-na-2" '' --status
  expect_rc 0 "control: a real mode (--status) answers"
  expect_has "automatic update: not available in this version" "  and says there is no automatic update"
}

# --- enumerate-before-claiming.sh ---------------------------------------------------------------
case_enumerate_before_claiming() {
  # A NEGATIVE CLAIM NEEDS AN ENUMERATION. This tool exists because a session filtered the
  # Scheduled Tasks for one project name, found three, and reported that nothing else existed.
  # Five more did; one carried the pre-rebranding name and had been failing daily for months.
  # The case asserts BOTH directions - a tree that registers a task is reported, and a tree that
  # does not is reported as 'none'. Asserting only the first would pass a tool that reports
  # everything, which is the same blindness one layer up.
  local tool="$GOV_DIR/enumerate-before-claiming.sh"
  if [ ! -f "$tool" ]; then
    _bad "enumerate-before-claiming.sh is installed" "absent at $tool - the control cannot run"
    return 0
  fi
  local withtask="$SBX/enum-with" without="$SBX/enum-without"
  mkdir -p "$withtask" "$without" 2>/dev/null
  printf '%s
' 'schtasks /Create /F /TN "X-Selftest-Task" /SC DAILY /ST 03:00 /TR "echo hi"' > "$withtask/setup.bat"
  printf '%s
' 'echo this file registers nothing' > "$without/plain.bat"

  CUR_SCRIPT="$tool (--creators)"
  local out
  out=$(bash "$tool" --creators "$withtask" 2>&1)
  case "$out" in
    *X-Selftest-Task*) _ok "--creators names the task a script registers" ;;
    *) _bad "--creators names the task a script registers" "expected X-Selftest-Task in: $(_snip "$out")" ;;
  esac
  out=$(bash "$tool" --creators "$without" 2>&1)
  case "$out" in
    *none*) _ok "--creators reports 'none' for a tree that registers nothing" ;;
    *) _bad "--creators reports 'none' for a tree that registers nothing" "expected 'none' in: $(_snip "$out")" ;;
  esac
}

# --- no-local-compute.sh ----------------------------------------------------------------------
case_no_local_compute() {
  # Registered on PreToolUse(Bash) since v1.1.7 and executed by nothing until now: it was the
  # selftest's only UNCOVERED hook at the 2026-09-07 close. A registered hook with no case is not
  # green, it is unverified - the same hole the pii-gate and close-completeness cases were added
  # to close.
  local proj="$SBX/nlc-proj" plain="$SBX/nlc-plain"
  mkdir -p "$proj" "$plain" 2>/dev/null
  : > "$proj/.remote-compute"        # marks the project as server-only compute
  : > "$proj/run-analysis.sh"

  local pay
  # 1. MUST BLOCK - running a project script locally in a marked project.
  pay="{\"session_id\":\"sid-nlc-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"node run-analysis.js\"}}"
  run_hook "$proj" "sid-nlc-1" "$pay"
  expect_rc 2 "marked project: running project compute on the PC is BLOCKED"

  # 2. MUST ALLOW - the same command where no .remote-compute marker exists. Without this the
  #    case would pass just as well against a hook that blocks everything.
  pay="{\"session_id\":\"sid-nlc-2\",\"cwd\":\"$plain\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"node run-analysis.js\"}}"
  run_hook "$plain" "sid-nlc-2" "$pay"
  expect_rc 0 "unmarked project: the identical command is ALLOWED"

  # 3. MUST ALLOW - ssh, in the marked project: the hook exists to push work TO the server, so
  #    refusing the way there would invert its purpose.
  pay="{\"session_id\":\"sid-nlc-3\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ssh root@203.0.113.10 'systemctl status x'\"}}"
  run_hook "$proj" "sid-nlc-3" "$pay"
  expect_rc 0 "marked project: ssh to the remote server is ALLOWED"

  # 4. MUST ALLOW - governance plumbing, the exemption added 2026-09-06 after blocking it
  #    deadlocked a session (governance-guard wanted a token only a local script could issue).
  pay="{\"session_id\":\"sid-nlc-4\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash .claude/hooks/governance/commit-task-success.sh\"}}"
  run_hook "$proj" "sid-nlc-4" "$pay"
  expect_rc 0 "marked project: governance plumbing is ALLOWED (the 2026-09-06 deadlock fix)"

  # --- THE BYPASS (2026-09-14) -----------------------------------------------------------------
  # The allow-list used to be an OR over the WHOLE command string, evaluated BEFORE the deny test,
  # with most alternatives unanchored. So one innocuous token anywhere on the line excused
  # everything else on it, and cases 1-4 above all still passed. A guard is not tested by the
  # commands people mean to run; it is tested by the ones they can smuggle. Both directions here:
  # the smuggling must fail, and each of the smuggled-in tokens must still work ON ITS OWN --
  # otherwise the fix would just be a blanket block wearing a fix's clothes.
  local c
  for c in "node run-analysis.js && bash -n /dev/null" \
           "ssh root@203.0.113.10 true && node run-analysis.js" \
           "git status; python scripts/pull.py" \
           "echo starting && bash tools/build.sh"; do
    pay="{\"session_id\":\"sid-nlc-b\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}"
    run_hook "$proj" "sid-nlc-b" "$pay"
    expect_rc 2 "an allowed token on the same line does NOT unlock project compute: $c"
  done
  for c in "bash -n /dev/null" "git status" "pytest -q" "cat a.txt | grep x | wc -l"; do
    pay="{\"session_id\":\"sid-nlc-a\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}"
    run_hook "$proj" "sid-nlc-a" "$pay"
    expect_rc 0 "the same token ALONE is still allowed (the fix is per-segment, not a blanket block): $c"
  done
}

# --- deny-git-bypass.sh -------------------------------------------------------------------------
case_deny_git_bypass() {
  # Existed live since Fable review #3, registered nowhere, shipped nowhere - a police officer at
  # home. Found by a parallel session 2026-09-09. Both directions asserted: the bypass is blocked,
  # the clean command and the flag-without-a-git-action are allowed, and the owner override works.
  local proj="$SBX/dgb-proj"
  mkdir -p "$proj" 2>/dev/null
  local pay
  # 1. MUST BLOCK - push with the bypass flag
  pay="{\"session_id\":\"sid-dgb-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push --no-verify\"}}"
  run_hook "$proj" "sid-dgb-1" "$pay"
  expect_rc 2 "git push --no-verify is BLOCKED"
  expect_has "BLOCKED" "block names itself so the agent knows what refused"
  # 2. MUST BLOCK - a policed env token placed inline
  pay="{\"session_id\":\"sid-dgb-2\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"GOVERNANCE_HOOKS=0 git commit -m x\"}}"
  run_hook "$proj" "sid-dgb-2" "$pay"
  expect_rc 2 "GOVERNANCE_HOOKS=0 inline with git commit is BLOCKED"
  # 3. MUST ALLOW - the same push with no flag
  pay="{\"session_id\":\"sid-dgb-3\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push\"}}"
  run_hook "$proj" "sid-dgb-3" "$pay"
  expect_rc 0 "a clean git push is ALLOWED"
  # 4. MUST ALLOW - a bypass-shaped token with NO hook-bearing git action. Without this the case
  #    would pass just as well against a hook that blocks every mention of the token.
  pay="{\"session_id\":\"sid-dgb-4\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status --no-verify\"}}"
  run_hook "$proj" "sid-dgb-4" "$pay"
  expect_rc 0 "a bypass token with no push/commit/merge is ALLOWED"
  # 5. MUST ALLOW - wiring the hooks (no '=' after hooksPath) is exactly what we want people to do
  pay="{\"session_id\":\"sid-dgb-5\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git config core.hooksPath .githooks\"}}"
  run_hook "$proj" "sid-dgb-5" "$pay"
  expect_rc 0 "wiring core.hooksPath is ALLOWED"
  # 6-8. MUST BLOCK - destructive git (2026-09-29, HITL-removal board condition 5): a force push,
  #      a +refspec, reset --hard. These keep their human approval once the close runs unattended.
  pay="{\"session_id\":\"sid-dgb-6\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push -f origin main\"}}"
  run_hook "$proj" "sid-dgb-6" "$pay"
  expect_rc 2 "git push -f is BLOCKED"
  expect_has "destructive git" "force push: the block names the destructive class"
  pay="{\"session_id\":\"sid-dgb-7\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"git -C x push origin +main\"}}"
  run_hook "$proj" "sid-dgb-7" "$pay"
  expect_rc 2 "a +refspec force push (PowerShell tool) is BLOCKED"
  pay="{\"session_id\":\"sid-dgb-8\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git reset --hard HEAD~1\"}}"
  run_hook "$proj" "sid-dgb-8" "$pay"
  expect_rc 2 "git reset --hard is BLOCKED"
  expect_has "reset --hard" "reset --hard: the block names it"
  # 9-10. MUST ALLOW - anchoring: an -f belonging to ANOTHER command, and an ordinary refspec push.
  pay="{\"session_id\":\"sid-dgb-9\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -f x.tmp && git push origin HEAD:main\"}}"
  run_hook "$proj" "sid-dgb-9" "$pay"
  expect_rc 0 "rm -f before an ordinary push is ALLOWED (anchored to the git segment)"
  expect_not "destructive git" "anchoring: no destructive-git text for an ordinary push"
  # 10b. MUST BLOCK - the forms later review rounds measured getting through: `-d` in a cluster,
  #      the one-letter `--m` (mirror), a quoted -C path, an inline mirror config without `=`,
  #      a `+@:ref` refspec, a line continuation. MUST ALLOW - `reset --help`.
  local _c
  for _c in 'git push -d origin old' 'git push --m origin' 'git -C \"C:/My Projects/x\" push --force' \
            'git -c remote.origin.mirror push origin' 'git push origin +@:main' 'git push origin \\\n  --force'; do
    pay="{\"session_id\":\"sid-dgb-x\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$_c\"}}"
    run_hook "$proj" "sid-dgb-x" "$pay"
    expect_rc 2 "destructive form blocked: $_c"
  done
  pay="{\"session_id\":\"sid-dgb-y\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git reset --help\"}}"
  run_hook "$proj" "sid-dgb-y" "$pay"
  expect_rc 0 "git reset --help is a read, not reset --hard: ALLOWED"
  # 11. MUST ALLOW - the owner's override, from the hook environment
  _RUN_ENV=(GOV_GIT_DESTRUCTIVE_OK=1)
  pay="{\"session_id\":\"sid-dgb-10\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git reset --hard HEAD~1\"}}"
  run_hook "$proj" "sid-dgb-10" "$pay"
  expect_rc 0 "GOV_GIT_DESTRUCTIVE_OK=1 in the hook environment lets the owner through"
  _RUN_ENV=()
}

# --- render-gate.sh -------------------------------------------------------------------------------
case_render_gate() {
  # Blocks a render command until the project's Read_Before_Every_Render.md has been read THIS
  # session (render-rules-read.sh mints the token; this gate spends it). Built 2026-07-27 after a
  # dead catbox link reached a CEO. Registered in no event until 2026-09-15 (task B11) - both
  # directions asserted here, plus the two properties that make it safe to register GLOBALLY: it
  # is a total no-op in any project without the rules file, and the token is one-shot (spent per
  # render, not per session).
  local proj="$SBX/rg-proj" noproj="$SBX/rg-noproj"
  mkdir -p "$proj" "$noproj" 2>/dev/null
  fx_project "$proj" "SOURCE" "$proj"
  fx_project "$noproj" "SOURCE" "$noproj"
  printf '# Read before every render\n\nUse the CLI for avatar looks. Verify catbox bytes before sending a link.\n' > "$proj/Read_Before_Every_Render.md"
  local marker="$SBX_HOME/.claude/logs/.gov-render-rules-read"
  local pay
  # 1. MUST BLOCK - a real render, no token, project HAS the rules file
  fx_state_reset
  pay="{\"session_id\":\"sid-rg-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"node remotion-cli.js render out.mp4\"}}"
  run_hook "$proj" "sid-rg-1" "$pay"
  expect_rc 2 "a render with no token is BLOCKED"
  expect_has "RENDER-GATE" "the block names itself"
  # 2. MUST ALLOW - the same render, fresh token present
  mkdir -p "$SBX_HOME/.claude/logs"
  printf '2026-09-15T00:00:00Z %s\n' "$proj/Read_Before_Every_Render.md" > "$marker"
  run_hook "$proj" "sid-rg-1" "$pay"
  expect_rc 0 "the same render with a fresh token is ALLOWED"
  # 3. MUST BLOCK - immediately again: the token is one-shot, spent by #2
  run_hook "$proj" "sid-rg-1" "$pay"
  expect_rc 2 "a second render right after is BLOCKED - one read buys exactly one render"
  # 4. MUST ALLOW - no token anywhere, but THIS project has no Read_Before_Every_Render.md at all
  run_hook "$noproj" "sid-rg-1" "$pay"
  expect_rc 0 "a project with no render-rules file is a total no-op"
  # 5. MUST ALLOW - git/gh are never renders, even when the message mentions one
  pay="{\"session_id\":\"sid-rg-2\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m 'mentions heygen video create'\"}}"
  run_hook "$proj" "sid-rg-2" "$pay"
  expect_rc 0 "git is never a render, even when the message mentions one"
  # 6. MUST ALLOW - a MENTION inside a heredoc is not an invocation
  pay="{\"session_id\":\"sid-rg-3\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat <<EOF\\nheygen video create\\nEOF\"}}"
  run_hook "$proj" "sid-rg-3" "$pay"
  expect_rc 0 "a mention inside a heredoc is not an invocation"
}

# --- render-rules-read.sh -------------------------------------------------------------------------
case_render_rules_read() {
  # Mints the one-shot token render-gate.sh spends. Matches on basename only (case/slash
  # insensitive) so it works from any path style; reading anything else is a pure no-op.
  local proj="$SBX/rrr-proj"
  mkdir -p "$proj" 2>/dev/null
  fx_project "$proj" "SOURCE" "$proj"
  printf '# Read before every render\n' > "$proj/Read_Before_Every_Render.md"
  local marker="$SBX_HOME/.claude/logs/.gov-render-rules-read"
  local pay
  # 1. MUST MINT - reading the canonical file
  fx_state_reset
  pay="{\"session_id\":\"sid-rrr-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$proj/Read_Before_Every_Render.md\"}}"
  run_hook "$proj" "sid-rrr-1" "$pay"
  expect_rc 0 "reading the render-rules file always succeeds silently"
  expect_file "$marker" "reading the render-rules file mints the token"
  # 2. MUST NOT MINT - reading an unrelated file
  fx_state_reset
  pay="{\"session_id\":\"sid-rrr-2\",\"cwd\":\"$proj\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$proj/CLAUDE.md\"}}"
  run_hook "$proj" "sid-rrr-2" "$pay"
  expect_nofile "$marker" "reading an unrelated file does NOT mint a token"
}

# --- consent-guard.sh (2026-09-30, legal conditions S1 / C3 / T4) ------------------------------
case_consent_guard() {
  # PreToolUse deny: a session cannot run a consent command (install.sh --accept-terms,
  # close-push.sh --enable ...), strip the AI-agent markers, or write the consent records.
  # Full matrix (both directions, ~100 checks): tests/test-consent-guard.sh. Here: blocks and
  # allows through run_hook, so the NOOP and NOBLOCK mutants must die on printed text.
  local proj="$SBX/cg-proj" pay
  mkdir -p "$proj" 2>/dev/null
  _RUN_ENV=(GOV_CONSENT_GUARD=1 GOVERNANCE_LOG="$SBX_HOME/.claude/logs/governance.log")
  fx_state_reset
  # 1. MUST BLOCK - a consent flag on the installer, wrapped in ssh
  pay="{\"session_id\":\"sid-cg-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ssh box 'bash install.sh --accept-terms'\"}}"
  run_hook "$proj" "sid-cg-1" "$pay"
  expect_rc 2 "install.sh --accept-terms from a session is BLOCKED"
  expect_has "[GOVERNANCE CONSENT GUARD] BLOCKED: install.sh with --accept-terms" "the block names the script and the flag"
  expect_has "typed in their own terminal" "the block is addressed to the human"
  # 2. MUST BLOCK - a shell write to the close-push record
  pay="{\"session_id\":\"sid-cg-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"printf 'enabled=1' > ~/.claude/.governance-update/close-push\"}}"
  run_hook "$proj" "sid-cg-1" "$pay"
  expect_rc 2 "a shell write to the close-push record is BLOCKED"
  expect_has "to the consent record close-push" "the block names the record"
  # 3. MUST ALLOW - a close (close-push.sh -C <repo>) and a read of the record
  pay="{\"session_id\":\"sid-cg-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash ~/.claude/hooks/governance/close-push.sh -C /repo; cat ~/.claude/.governance-update/close-push\"}}"
  run_hook "$proj" "sid-cg-1" "$pay"
  expect_rc 0 "a close and a read of the record are ALLOWED"
  expect_not "BLOCKED" "an allowed call prints no block"
  # 4. MUST ALLOW - an Edit of an ordinary governance file
  pay="{\"session_id\":\"sid-cg-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$proj/docs/context/HANDOFF.md\",\"old_string\":\"a\",\"new_string\":\"b\"}}"
  run_hook "$proj" "sid-cg-1" "$pay"
  expect_rc 0 "an Edit of HANDOFF.md is ALLOWED"
  expect_not "CONSENT GUARD" "no guard text on an ordinary Edit"
  _RUN_ENV=()
}

# --- bootstrap-gate.sh (registered 2026-09-29) ------------------------------------------------
case_bootstrap_gate() {
  # PreToolUse: blocks Edit/Write and outward shell actions in a governed SOURCE project until the
  # harness records a Skill(bootstrapper) run; PostToolUse `--mark` on Skill writes that proof.
  # Registered twice (PreToolUse + PostToolUse --mark); both registrations run this one case.
  # Full matrix: tests/test-bootstrap-gate.sh. CLAUDE_PROJECT_DIR is pinned so a selftest launched
  # from inside a governed session cannot leak its own project root into the verdict.
  local proj="$SBX/bg-proj" plain="$SBX/bg-plain" skills="$SBX/bg-skills" pay
  mkdir -p "$proj" "$plain" "$skills/bootstrapper" 2>/dev/null
  fx_project "$proj" "SOURCE" "$proj"
  printf '# plain\n' > "$plain/CLAUDE.md"
  printf '# stub\n' > "$skills/bootstrapper/SKILL.md"
  local marker; marker="$(sess_dir sid-bg-1)/.gov-bootstrapper-ran"
  _RUN_ENV=(CLAUDE_PROJECT_DIR="$proj" GOVERNANCE_SKILLS_DIR="$skills" GOV_BOOTSTRAP_GATE=1)
  # 1. MUST BLOCK - Edit before /bootstrapper
  fx_state_reset
  pay="{\"session_id\":\"sid-bg-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$proj/a.md\",\"old_string\":\"a\",\"new_string\":\"b\"}}"
  run_hook "$proj" "sid-bg-1" "$pay"
  expect_rc 2 "Edit before /bootstrapper is BLOCKED"
  expect_has "[GOVERNANCE BOOTSTRAP GATE] BLOCKED" "the block names the gate"
  expect_has 'skill "bootstrapper"' "the block names the Skill call that clears it"
  # 2. MUST BLOCK - outward shell action (git push)
  pay="{\"session_id\":\"sid-bg-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin main\"}}"
  run_hook "$proj" "sid-bg-1" "$pay"
  expect_rc 2 "git push before /bootstrapper is BLOCKED"
  expect_has "BLOCKED: git push" "the block names the outward action"
  # 3. MUST ALLOW - a read-only shell command
  pay="{\"session_id\":\"sid-bg-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"}}"
  run_hook "$proj" "sid-bg-1" "$pay"
  expect_rc 0 "git status is never gated"
  expect_not "BLOCKED" "a read-only command prints no block"
  expect_nofile "$marker" "blocked calls do not create the proof"
  # 4. PostToolUse --mark on Skill(bootstrapper) writes the proof; the same Edit then passes
  pay="{\"session_id\":\"sid-bg-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"bootstrapper\"}}"
  run_hook "$proj" "sid-bg-1" "$pay" --mark
  expect_rc 0 "--mark on Skill(bootstrapper) succeeds"
  expect_file "$marker" "--mark writes sessions/<sid>/.gov-bootstrapper-ran"
  pay="{\"session_id\":\"sid-bg-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$proj/a.md\",\"old_string\":\"a\",\"new_string\":\"b\"}}"
  run_hook "$proj" "sid-bg-1" "$pay"
  expect_rc 0 "Edit after the harness-recorded bootstrap is ALLOWED"
  expect_not "BLOCKED" "no block text once bootstrapped"
  # 5. MUST ALLOW - an ungoverned project is never gated
  _RUN_ENV=(CLAUDE_PROJECT_DIR="$plain" GOVERNANCE_SKILLS_DIR="$skills" GOV_BOOTSTRAP_GATE=1)
  pay="{\"session_id\":\"sid-bg-2\",\"cwd\":\"$plain\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$plain/x\",\"content\":\"x\"}}"
  run_hook "$plain" "sid-bg-2" "$pay"
  expect_rc 0 "an ungoverned project is never gated"
  expect_not "BLOCKED" "ungoverned: no block text"
  _RUN_ENV=()
}

# --- pr-watch-guard.sh --------------------------------------------------------------------------
case_pr_watch_guard() {
  # Keeps a PR watcher armed for the caller's open PRs (v1.4.0). Offline: the two gh calls are
  # replaced by seams the hook honours only under GOV_SELFTEST_SBX. Both directions asserted -
  # it fires (JSON block naming pr-watch.sh) after a PR command with open PRs and no heartbeat,
  # and stays silent on a live heartbeat, a non-PR command, zero PRs, and the kill switch.
  local proj="$SBX/prw-proj" st="$SBX/prw-state"
  mkdir -p "$proj" "$st" 2>/dev/null; rm -f "$st"/* 2>/dev/null
  export PR_WATCH_GUARD_REPO="acme/widgets" PR_WATCH_STATE_DIR="$st"
  local pay
  # 1. MUST FIRE - gh pr create, 2 open PRs, no watcher
  export PR_WATCH_GUARD_OPEN=2
  pay="{\"session_id\":\"sid-prw-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh pr create --title t --body b\"}}"
  run_hook "$proj" "sid-prw-1" "$pay"
  expect_rc 0 "PostToolUse never fails the tool"
  expect_has '"decision": "block"' "a PR command with open PRs and no watcher asks the session to arm"
  expect_has 'pr-watch.sh --repo acme/widgets' "the ask names the exact watcher command"
  # 2. MUST NOT FIRE - the same again inside the cool-down
  run_hook "$proj" "sid-prw-1" "$pay"
  expect_quiet "a second PR command inside the cool-down is silent"
  # 3. MUST NOT FIRE - a live heartbeat (fresh watcher) for this repo+session
  rm -f "$st"/*.nag; date +%s > "$st/acme__widgets__sid-prw-1.heartbeat"
  run_hook "$proj" "sid-prw-1" "$pay"
  expect_quiet "a live watcher heartbeat keeps the guard silent"
  # 4. MUST FIRE - a stale heartbeat (10 minutes old) counts as no watcher
  printf '%s' "$(( $(date +%s) - 600 ))" > "$st/acme__widgets__sid-prw-1.heartbeat"; rm -f "$st"/*.nag
  run_hook "$proj" "sid-prw-1" "$pay"
  expect_has '"decision": "block"' "a stale heartbeat is treated as no watcher"
  # 5. MUST NOT FIRE - a command that is not about PRs
  rm -f "$st"/*
  pay="{\"session_id\":\"sid-prw-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la && git status\"}}"
  run_hook "$proj" "sid-prw-1" "$pay"
  expect_quiet "a non-PR command is ignored"
  # 6. MUST NOT FIRE - zero open PRs
  export PR_WATCH_GUARD_OPEN=0
  pay="{\"session_id\":\"sid-prw-1\",\"cwd\":\"$proj\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push\"}}"
  run_hook "$proj" "sid-prw-1" "$pay"
  expect_quiet "no open PR of the caller means nothing to arm"
  # 7. Stop is held ONCE, then passes
  export PR_WATCH_GUARD_OPEN=1
  pay="{\"session_id\":\"sid-prw-2\",\"cwd\":\"$proj\",\"hook_event_name\":\"Stop\"}"
  run_hook "$proj" "sid-prw-2" "$pay"
  expect_has '"decision": "block"' "the first stop with open PRs and no watcher is held"
  run_hook "$proj" "sid-prw-2" "$pay"
  expect_quiet "the second stop passes (held once only)"
  # 8. SessionStart prints one context line (plain text, not JSON)
  pay="{\"session_id\":\"sid-prw-3\",\"cwd\":\"$proj\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
  run_hook "$proj" "sid-prw-3" "$pay"
  expect_has '[pr-watch] acme/widgets has 1 open PR' "session start announces the open PRs and the arm command"
  expect_not '"decision"' "session start context is plain text"
  # 9. MUST NOT FIRE - the kill switch
  rm -f "$st"/*
  pay="{\"session_id\":\"sid-prw-4\",\"cwd\":\"$proj\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"git push -u origin x\"}}"
  GOV_PR_WATCH=0 run_hook "$proj" "sid-prw-4" "$pay"
  expect_quiet "GOV_PR_WATCH=0 silences the guard"
  # --- cold gh (2026-09-10 Sniper handoff) ------------------------------------------------------
  # These drop the PR_WATCH_GUARD_OPEN seam so the REAL gh call path runs, against a fake `gh` on
  # the sandbox PATH. The bug: an empty/failed gh was read as "no open PRs" and exited 0 with NO
  # log line, so a cold gh at SessionStart silently disarmed monitoring. Both directions matter -
  # a broken gh must be LOUD, and a genuine zero must stay SILENT. Asserting only the first would
  # pass against a hook that logs "gh not ready" on every quiet repo.
  local glog="$SBX_HOME/.claude/logs/governance.log" ghdir="$SBX/prw-gh"
  mkdir -p "$ghdir" 2>/dev/null; rm -f "$st"/* 2>/dev/null
  unset PR_WATCH_GUARD_OPEN

  # 10. MUST RECOVER - the reported scenario: first gh call cold (fails), second one warm.
  #     Before the fix this session got no prompt at all and left no trace.
  rm -f "$ghdir/tries"
  cat > "$SBX_BIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
n=$(cat "$GOV_SELFTEST_SBX/prw-gh/tries" 2>/dev/null || echo 0)
n=$((n+1)); printf '%s' "$n" > "$GOV_SELFTEST_SBX/prw-gh/tries"
[ "$n" -le 1 ] && exit 1      # cold: fails on the first call only
echo 2
FAKEGH
  chmod +x "$SBX_BIN/gh" 2>/dev/null
  : > "$glog"
  pay="{\"session_id\":\"sid-prw-cold1\",\"cwd\":\"$proj\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
  run_hook "$proj" "sid-prw-cold1" "$pay"
  expect_has '[pr-watch] acme/widgets has 2 open PR' "a cold first gh call is retried, not read as zero - the arm prompt still reaches the session"
  expect_grep "recovered on try 2" "$glog" "the recovery is recorded, so a cold gh is visible instead of invisible"

  # 11. MUST LOG - gh never comes back. Silence on stdout is right (we do not know), silence in the
  #     log is the actual defect: it erases the difference between "quiet" and "not answered".
  cat > "$SBX_BIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
exit 1
FAKEGH
  chmod +x "$SBX_BIN/gh" 2>/dev/null
  : > "$glog"; rm -f "$st"/*
  pay="{\"session_id\":\"sid-prw-cold2\",\"cwd\":\"$proj\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
  PR_WATCH_GH_TRIES=1 run_hook "$proj" "sid-prw-cold2" "$pay"
  expect_quiet "an unanswered gh does not fabricate an arm prompt"
  expect_grep "gh not ready" "$glog" "a gh that never answers is LOGGED, not swallowed"
  expect_grep "NOT 'no open PRs'" "$glog" "the log says explicitly that this is not a zero"

  # 12. MUST NOT LOG - the positive control. gh answers "0": a real quiet repo. Without this, a
  #     hook that logged "gh not ready" unconditionally would pass case 11 and be worse than the bug.
  cat > "$SBX_BIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
echo 0
FAKEGH
  chmod +x "$SBX_BIN/gh" 2>/dev/null
  : > "$glog"; rm -f "$st"/*
  pay="{\"session_id\":\"sid-prw-cold3\",\"cwd\":\"$proj\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
  run_hook "$proj" "sid-prw-cold3" "$pay"
  expect_quiet "zero open PRs stays quiet"
  expect_nogrep "gh not ready" "$glog" "a genuine zero is NOT reported as a cold gh"

  # 13. MUST LOG - rc=0 but a non-numeric answer is gh malfunctioning, not an empty repo.
  cat > "$SBX_BIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
echo "gh: could not determine current branch"
FAKEGH
  chmod +x "$SBX_BIN/gh" 2>/dev/null
  : > "$glog"; rm -f "$st"/*
  pay="{\"session_id\":\"sid-prw-cold4\",\"cwd\":\"$proj\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
  run_hook "$proj" "sid-prw-cold4" "$pay"
  expect_quiet "a garbled gh answer does not fabricate an arm prompt"
  expect_grep "not read as zero open PRs" "$glog" "a non-numeric answer is classified, not silently treated as zero"

  rm -f "$SBX_BIN/gh" "$ghdir/tries" 2>/dev/null   # the fake must not leak into other cases
  unset PR_WATCH_GUARD_REPO PR_WATCH_GUARD_OPEN PR_WATCH_STATE_DIR
}

# --- cross-session-guard.sh -------------------------------------------------------------------
case_cross_session_guard() {
  # Enforces the /cross-session-protocol message contract on PreToolUse(SendMessage). The danger it
  # exists for is a confident report another session ACTS on: two sessions measured it on 2026-09-14
  # when two of three claims were wrong and one wrong claim left a project unbacked while the report
  # said otherwise. Both directions matter more than usual here, because this hook fires on EVERY
  # SendMessage - including ordinary delegation to an in-process subagent. A guard that blocked
  # those would be removed within a day, and then it would protect nothing.
  local proj="$SBX/xsession"
  mkdir -p "$proj" 2>/dev/null
  local long short pay
  # >= 400 chars, the length at which a message is a report rather than a note
  long="Here is what I found while auditing your backup script this evening across every project on the machine, with the counts and the paths, so that you can decide what to do about the ones that are missing and how to proceed from here without breaking anything else in the process today."
  long="$long $long"
  short="starting task 3 now"

  _pl_msg() { printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"SendMessage","tool_input":{"to":"peer","message":"%s"}}' "$2" "$1" "$3"; }

  # 1. MUST BLOCK - a long report with neither field.
  pay=$(_pl_msg "$proj" sid-xs-1 "$long")
  run_hook "$proj" "sid-xs-1" "$pay"
  expect_rc 2 "a 400+ char report with no MEASURED/NOT CHECKED is BLOCKED"
  expect_has "BLOCKED" "block names itself"
  expect_has "MEASURED:" "block names the field that is missing"

  # 2. MUST BLOCK - short, but it declared itself a protocol message by carrying a tag.
  pay=$(_pl_msg "$proj" sid-xs-2 "[FYI] the roots table is empty now")
  run_hook "$proj" "sid-xs-2" "$pay"
  expect_rc 2 "a tagged message without the contract is BLOCKED even when short"

  # 3. MUST ALLOW - the same long report, with the contract present.
  pay=$(_pl_msg "$proj" sid-xs-3 "[FYI] audit result. MEASURED: 9 repos, via git log --oneline, 22:10. NOT CHECKED: whether the remote agrees. $long")
  run_hook "$proj" "sid-xs-3" "$pay"
  expect_rc 0 "the same report WITH MEASURED and NOT CHECKED is allowed"

  # 4. MUST ALLOW - ordinary short delegation. Without this case the hook could block everything
  #    and still pass cases 1-2, which is how a guard becomes a blanket refusal wearing a fix's name.
  pay=$(_pl_msg "$proj" sid-xs-4 "$short")
  run_hook "$proj" "sid-xs-4" "$pay"
  expect_rc 0 "a short untagged operational note is allowed"
  expect_quiet "a short untagged note is silent - no nag on ordinary delegation"

  # 5. MUST ALLOW - a different tool entirely must not be policed by this hook.
  pay="{\"session_id\":\"sid-xs-5\",\"cwd\":\"$proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$proj/x.md\",\"content\":\"$long\"}}"
  run_hook "$proj" "sid-xs-5" "$pay"
  expect_rc 0 "a non-SendMessage tool is not this hook's business"

  # 6. MUST ALLOW - the documented kill switch.
  pay=$(_pl_msg "$proj" sid-xs-6 "$long")
  GOV_XSESSION_GUARD=0 run_hook "$proj" "sid-xs-6" "$pay"
  expect_rc 0 "GOV_XSESSION_GUARD=0 bypasses the guard"
}

# --- canonical-cwd-check.sh ------------------------------------------------------------------
# THE stdout-only bug. Signal 1 takes `head -1` of ANY drive path in the tombstone and prints it
# as the redirect target. When the tombstone names the condemned folder before the canonical one
# (the normal way such a note is written: "this folder, C:\Old, is retired; use C:\New"), the
# guard condemns a folder and in the same sentence sends the session back to it — while exiting 0
# with a perfectly correct exit code. An exit-code-only assertion passes this.
case_canonical_cwd() {
  local stale="$SBX/stale" good="$SBX/proj" wrong="$SBX/wrongcopy"
  mkdir -p "$stale" 2>/dev/null
  printf '# STALE — DO NOT USE\n\nThis folder (%s) is retired. The canonical copy is %s.\n' \
      "$(_winform "$stale")" "$(_winform "$good")" > "$stale/_STALE_DO_NOT_USE.md"

  fx_state_reset
  run_hook "$stale" "sid-cwd-1" "$(pl_session_win "$stale" sid-cwd-1)"
  expect_rc 0 "tombstone: advisory only, never blocks the session"
  expect_has "STALE" "tombstone: says the folder is stale"
  expect_not "canonical copy: $(_winform "$stale")" \
             "tombstone: redirect target is NOT the folder it just condemned"

  fx_project "$wrong" SOURCE "$(_winform "$good")"
  run_hook "$wrong" "sid-cwd-2" "$(pl_session_win "$wrong" sid-cwd-2)"
  expect_rc 0 "wrong-copy: advisory only"
  expect_has "WRONG WORKING COPY" "wrong-copy: reports the manifest/root mismatch"

  fx_project "$good" SOURCE "$(_winform "$good")"
  run_hook "$good" "sid-cwd-3" "$(pl_session_win "$good" sid-cwd-3)"
  expect_rc 0 "canonical copy: allowed"
  expect_quiet "canonical copy: prints nothing"

  # --- SIGNAL 4: cloud-sync artefacts inside .git (2026-09-14) ---------------------------------
  # A `desktop.ini` under .git/refs makes every fetch fail while ahead/behind keeps answering
  # from the stale ref — i.e. it reads as "already pushed". Both directions, and the second one
  # is the one that matters: a clean .git must stay SILENT, or the alarm becomes background noise
  # on every Windows machine and gets ignored exactly when it is real.
  # ITS OWN DIRECTORY, not $SBX/proj. Learned the hard way while writing this case: $SBX/proj is a
  # SHARED fixture, and case_collision_record guards its setup with `[ -d "$repo/.git" ] || git
  # init`. Creating a hollow .git here (directories, no repo) therefore made that case skip its
  # init, so the collision hooks saw no git repo, recorded no claim, and FOUR unrelated assertions
  # went red in two other cases. A fixture that another case reuses is shared state; treat writing
  # into it exactly as you would treat a global.
  local cwdgit="$SBX/cwd-gitprobe"
  rm -rf "$cwdgit" 2>/dev/null; mkdir -p "$cwdgit/.git/refs/heads" "$cwdgit/.git/objects/ab" 2>/dev/null
  fx_project "$cwdgit" SOURCE "$(_winform "$cwdgit")"
  printf '[.ShellClassInfo]\n' > "$cwdgit/.git/refs/desktop.ini"
  printf '[.ShellClassInfo]\n' > "$cwdgit/.git/objects/ab/desktop.ini"
  run_hook "$cwdgit" "sid-cwd-4" "$(pl_session_win "$cwdgit" sid-cwd-4)"
  expect_rc 0 "cloud-sync artefacts: advisory, never blocks the session"
  expect_has "CLOUD-SYNC ARTEFACTS IN .git" "a sync client writing into .git is REPORTED"
  expect_nofile "$cwdgit/.git/refs/desktop.ini" "the artefact under .git/refs is removed (git never creates one)"
  expect_nofile "$cwdgit/.git/objects/ab/desktop.ini" "artefacts deeper in .git are removed too"

  run_hook "$cwdgit" "sid-cwd-5" "$(pl_session_win "$cwdgit" sid-cwd-5)"
  expect_not "CLOUD-SYNC ARTEFACTS IN .git" "a clean .git says NOTHING — the alarm must not fire on every run"
  rm -rf "$cwdgit" 2>/dev/null
}

# --- pre-session.sh ---------------------------------------------------------------------------
case_pre_session() {
  local good="$SBX/proj" ungov="$SBX/ungoverned"
  fx_project "$good" SOURCE "$(_winform "$good")"
  fx_state_reset
  run_hook "$good" "sid-ps-1" "$(pl_session "$good" sid-ps-1)"
  expect_rc 0 "governed: SessionStart never blocks"
  expect_has "Governed project detected" "governed: emits the Session Start Protocol directive"

  mkdir -p "$ungov" 2>/dev/null
  printf '# Ungoverned\n' > "$ungov/CLAUDE.md"
  printf 'console.log(1)\n' > "$ungov/index.js"
  printf 'SOURCE\n' > "$ungov/.governance-role"   # role gate is orthogonal to "needs scaffolding"
  fx_state_reset
  run_hook "$ungov" "sid-ps-2" "$(pl_session "$ungov" sid-ps-2)"
  expect_rc 0 "ungoverned: never blocks"
  expect_has "init-governance" "ungoverned: demands the scaffold skill"

  # SessionStart budget (2026-09-26). The cases above run with ~no other session dirs, which is how
  # a 40 s pre-session.sh (8 forks per dir x 87 dirs) passed every check while the VS Code extension
  # failed to start. tests/test-sessionstart-budget.sh times every SessionStart hook with a real
  # session_id, 80-200 other dirs and stdout piped, and checks the registered timeouts.
  # It times the REAL hooks, not the mutant, and costs ~2-3 min: a mutant run is judged above.
  [ "${MUT:-0}" = "1" ] && return 0
  local _o _rc _p _f
  CUR_SCRIPT="$GOV_DIR/tests/test-sessionstart-budget.sh"
  if [ ! -f "$GOV_DIR/tests/test-sessionstart-budget.sh" ]; then
    _bad "tests/test-sessionstart-budget.sh exists" "missing at $GOV_DIR/tests/ - SessionStart speed would ship unmeasured"
  else
    # The template beside the hooks under test (CHOME), never the real home's (round 3b): unset when
    # CHOME has no staging copy, and the test then finds its own.
    local _sst=""; [ -f "$CHOME/governance-installer/bundle/settings-hooks.json" ] && _sst="$CHOME/governance-installer/bundle/settings-hooks.json"
    _o=$(env ${_sst:+GOV_SS_TEMPLATE="$_sst"} bash "$GOV_DIR/tests/test-sessionstart-budget.sh" </dev/null 2>&1); _rc=$?
    _p=$(printf '%s' "$_o" | sed -n 's/^pass=\([0-9]*\) fail=\([0-9]*\)$/\1/p' | tail -1)
    _f=$(printf '%s' "$_o" | sed -n 's/^pass=\([0-9]*\) fail=\([0-9]*\)$/\2/p' | tail -1)
    if [ "$_rc" = "0" ] && [ "${_p:-0}" -gt 0 ] && [ "${_f:-1}" = "0" ]; then
      _ok "tests/test-sessionstart-budget.sh: pass=$_p fail=0 (timeouts, speed with many sessions, no growth)"
    else
      _bad "tests/test-sessionstart-budget.sh" "rc=$_rc pass=${_p:-?} fail=${_f:-?}: $(_snip "$(printf '%s' "$_o" | grep -E '^  FAIL|pass=' | head -6)")"
    fi
  fi
}

# --- pre-task.sh ------------------------------------------------------------------------------
case_pre_task() {
  local good="$SBX/proj"
  fx_project "$good" SOURCE "$(_winform "$good")"

  fx_state_reset
  run_hook "$good" "sid-pt-1" "$(pl_prompt "$good" sid-pt-1 "hello")"
  expect_rc 0 "first prompt: UserPromptSubmit MUST NOT exit 2 (gotcha #218)"
  expect_has "GOVERNANCE ENFORCEMENT" "first prompt: emits the mandatory bootstrapper directive"
  expect_file "$(sess_dir sid-pt-1)/.gov-session-bootstrapped" "first prompt: auto-creates the marker (deadlock fix)"

  run_hook "$good" "sid-pt-1" "$(pl_prompt "$good" sid-pt-1 "second")"
  expect_rc 0 "second prompt: allowed"
  expect_quiet "second prompt: silent once bootstrapped"
}

# --- plan-gate.sh -----------------------------------------------------------------------------
case_plan_gate() {
  local good="$SBX/proj"
  fx_project "$good" SOURCE "$(_winform "$good")"
  fx_state_reset
  # >500 chars is one of plan-gate's two conditions, so the fixture asserts its own length
  # rather than trusting that it looks long enough (the first version was 424 and silently
  # tested the short-message path instead).
  local big="Please implement and refactor the retrieval architecture in admin/lib/server.js and config.js. Step 1: extract the pipeline into a module. Step 2: rewrite the endpoint schema so the container can serve it. Step 3: migrate the database and add a module for the API service middleware. This is a multi phase change and it touches many files across the whole codebase, so plan it properly before writing any code at all please. It should also redesign the middleware layer, migrate the remaining endpoints, and rewrite the container build so the whole service comes up from one command."
  if [ "${#big}" -ge 500 ]; then _ok "plan-gate fixture is over the 500-char threshold (${#big})"
  else _bad "plan-gate fixture is over the 500-char threshold" "fixture is only ${#big} chars, so this case exercises the wrong branch"; fi
  run_hook "$good" "sid-pg-1" "$(pl_prompt "$good" sid-pg-1 "$big")"
  expect_rc 0 "large task: UserPromptSubmit MUST NOT exit 2"
  expect_has "GOVERNANCE RECOMMENDATION" "large task: recommends /plan-and-execute"

  run_hook "$good" "sid-pg-2" "$(pl_prompt "$good" sid-pg-2 "what time is it")"
  expect_rc 0 "small talk: allowed"
  expect_quiet "small talk: no planning nag"
}

# --- parallel-import.sh -----------------------------------------------------------------------
case_parallel_import() {
  local good="$SBX/proj"
  fx_project "$good" SOURCE "$(_winform "$good")"
  fx_state_reset
  local dump="Here is the HANDOFF-v1.2.3 dump from another session, please merge this: status: active and consumed_at: null and remaining_items: 4"
  run_hook "$good" "sid-pi-1" "$(pl_prompt "$good" sid-pi-1 "$dump")"
  expect_rc 0 "pasted session dump: never blocks"
  expect_has "GOVERNANCE WARNING" "pasted session dump: recommends /parallel-session-merge"

  run_hook "$good" "sid-pi-2" "$(pl_prompt "$good" sid-pi-2 "fix the typo in the readme")"
  expect_rc 0 "ordinary prompt: allowed"
  expect_quiet "ordinary prompt: silent"
}

# --- file-collision-guard.sh ------------------------------------------------------------------
case_collision_guard() {
  local repo="$SBX/proj"
  fx_project "$repo" SOURCE "$(_winform "$repo")"
  [ -d "$repo/.git" ] || sbx_git "$repo" init
  fx_state_reset

  local contested="$repo/admin/lib/contested.js"
  local free="$repo/admin/lib/untouched.js"

  # Fixture: another live session claims the file, using the pristine guard's own claim path.
  run_fixture "$repo" "sid-other" "$(pl_pre "$repo" sid-other "$contested")"

  run_hook "$repo" "sid-mine" "$(pl_pre "$repo" sid-mine "$contested")"
  expect_rc 2 "concurrent claim: BLOCKS the second session"
  expect_has "another Claude Code session is editing this file" "concurrent claim: names the real reason"
  expect_has "sid-other" "concurrent claim: names the session holding it"
  expect_has "tell the user" "concurrent claim on CODE: the human remedy stays"

  # 2026-09-29 (HITL removal): on a CANONICAL context file the block is identical, but the remedy
  # never sends the session to a human - it parks its entry in the session's pending-merge.md.
  local canon="$repo/docs/context/OPEN-PROBLEMS.md"
  run_fixture "$repo" "sid-other" "$(pl_pre "$repo" sid-other "$canon")"
  run_hook "$repo" "sid-mine" "$(pl_pre "$repo" sid-mine "$canon")"
  expect_rc 2 "concurrent claim on a CANONICAL file: still BLOCKS"
  expect_has "pending-merge.md" "canonical file: remedy parks the entry in the session's pending merge"
  expect_not "tell the user" "canonical file: remedy never sends the session to a human"
  # The same canonical file spelled with BACKSLASHES, as Windows hands it to the guard (review round 1:
  # a forward-slash-only case passed while the backslash path was classified as code).
  # JSON needs each backslash doubled (the payload carries C:\\x\\docs\\...); a variable does the
  # replacement because bash 5.2 does not treat \\ in a ${x//pattern/..} as a literal backslash.
  local _b='\' _bb='\\' canon_bs
  canon_bs="$(_winform "$repo")\\docs\\context\\GOTCHAS.md"
  canon_bs="${canon_bs//"$_b"/"$_bb"}"
  run_fixture "$repo" "sid-other" "$(pl_pre "$repo" sid-other "$canon_bs")"
  run_hook "$repo" "sid-mine" "$(pl_pre "$repo" sid-mine "$canon_bs")"
  expect_rc 2 "concurrent claim on a canonical file, backslash path: still BLOCKS"
  expect_has "pending-merge.md" "backslash canonical path: classified as canonical"

  run_hook "$repo" "sid-mine" "$(pl_pre "$repo" sid-mine "$free")"
  expect_rc 0 "unclaimed new file: allowed"
}

# --- governance-guard.sh ----------------------------------------------------------------------
case_governance_guard() {
  local src="$SBX/proj" dep="$SBX/deployment"
  fx_project "$src" SOURCE "$(_winform "$src")"
  fx_project "$dep" DEPLOYMENT "$(_winform "$src")"
  fx_state_reset

  local prot="$src/docs/context/GOTCHAS.md"
  printf '# gotchas\n' > "$prot"

  # DEFAULT (1.7.1): the success-token gate is OFF - a protected doc with no token is ALLOWED.
  # Owner decision 2026-09-24: the gate deadlocked every close.
  fx_token
  unset GOV_REQUIRE_SUCCESS_TOKEN
  run_hook "$src" "sid-gg-0" "$(pl_pre "$src" sid-gg-0 "$prot")"
  expect_rc 0 "default (gate off): protected doc, no token: ALLOWED"
  expect_not "requires a success token" "default (gate off): no token demand in the output"
  printf '# gotchas\n' > "$dep/docs/context/GOTCHAS.md"
  run_hook "$dep" "sid-gg-0b" "$(pl_pre "$dep" sid-gg-0b "$dep/docs/context/GOTCHAS.md")"
  expect_rc 2 "default (gate off): DEPLOYMENT node is STILL blocked (role gate is independent)"

  # OPT-IN: everything below exercises the gate with GOV_REQUIRE_SUCCESS_TOKEN=1.
  export GOV_REQUIRE_SUCCESS_TOKEN=1
  fx_token
  run_hook "$src" "sid-gg-1" "$(pl_pre "$src" sid-gg-1 "$prot")"
  expect_rc 2 "protected doc, no token: BLOCKED"
  expect_has "requires a success token" "protected doc: explains the token requirement"
  expect_not "confirm with the user" "opt-in token: asks for evidence, never for a human (2026-09-29)"

  fx_token 300
  run_hook "$src" "sid-gg-2" "$(pl_pre "$src" sid-gg-2 "$prot")"
  expect_rc 0 "protected doc, fresh token: allowed"

  fx_token -60
  run_hook "$src" "sid-gg-3" "$(pl_pre "$src" sid-gg-3 "$prot")"
  expect_rc 2 "protected doc, expired token: BLOCKED"
  expect_has "expired" "expired token: says so"

  fx_token 300
  run_hook "$src" "sid-gg-4" "$(pl_pre "$src" sid-gg-4 "$src/README.md")"
  expect_rc 0 "ordinary file: allowed"

  printf '# gotchas\n' > "$dep/docs/context/GOTCHAS.md"
  run_hook "$dep" "sid-gg-5" "$(pl_pre "$dep" sid-gg-5 "$dep/docs/context/GOTCHAS.md")"
  expect_rc 2 "governance edit on a DEPLOYMENT node: BLOCKED even with a valid token"
  expect_has "DEPLOYMENT" "deployment block: names the node role"

  # --- fail-closed trap (2026-09-14) -----------------------------------------------------------
  # governance.log showed 16 "protected target" lines across its full history with no ALLOW or
  # BLOCK ever following - some runs died or hung between the role check and the token check and
  # silently fell through to allow (settings-hooks.json gives this hook a 10s timeout; the two
  # measurable gaps were 7-12s after their last log line, consistent with the harness killing a
  # hung run). The trap armed right after the "protected target" log must convert ANY exit past
  # that point into a BLOCK unless a legitimate path explicitly clears it first.
  fx_token 300
  export GOV_TEST_UNEXPECTED_EXIT=1
  run_hook "$src" "sid-gg-6" "$(pl_pre "$src" sid-gg-6 "$prot")"
  unset GOV_TEST_UNEXPECTED_EXIT
  expect_rc 2 "unexpected exit after protected-target log: fail-closed BLOCKS instead of falling through"
  expect_grep "fail-closed" "$SBX_HOME/.claude/logs/governance.log" "fail-closed block: names itself so the gap is never silent again"
  fx_token
  unset GOV_REQUIRE_SUCCESS_TOKEN
}

# --- pre-write.sh -----------------------------------------------------------------------------
case_pre_write() {
  local src="$SBX/proj"
  fx_project "$src" SOURCE "$(_winform "$src")"
  fx_state_reset
  local hi="$src/admin/server.js"

  run_hook "$src" "sid-pw-1" "$(pl_pre "$src" sid-pw-1 "$hi")"
  expect_rc 2 "high-impact file without bootstrapper: BLOCKED"
  expect_has "BLOCKED" "high-impact block: says BLOCKED"

  mkdir -p "$(sess_dir sid-pw-2)" 2>/dev/null
  touch "$(sess_dir sid-pw-2)/.gov-session-bootstrapped"
  run_hook "$src" "sid-pw-2" "$(pl_pre "$src" sid-pw-2 "$hi")"
  expect_rc 0 "high-impact file with bootstrapper: allowed"
  expect_has "high-impact file" "bootstrapped write: still warns"

  run_hook "$src" "sid-pw-3" "$(pl_pre "$src" sid-pw-3 "$src/notes.md")"
  expect_rc 0 "ordinary file: allowed"
  expect_quiet "ordinary file: silent"
}

# --- post-milestone.sh ------------------------------------------------------------------------
case_post_milestone() {
  local src="$SBX/proj" ungov="$SBX/ungoverned"
  fx_project "$src" SOURCE "$(_winform "$src")"
  mkdir -p "$ungov" 2>/dev/null; printf '# no manifest\n' > "$ungov/CLAUDE.md"
  fx_state_reset

  local f="$src/admin/lib/tracked.js"; printf 'x\n' > "$f"
  run_hook "$src" "sid-pm-1" "$(pl_post "$src" sid-pm-1 "$f")"
  expect_rc 0 "PostToolUse never blocks"
  expect_grep "$f" "$(sess_dir sid-pm-1)/.gov-session-changes" "governed write is recorded in the session change log"

  run_hook "$ungov" "sid-pm-2" "$(pl_post "$ungov" sid-pm-2 "$ungov/x.js")"
  expect_rc 0 "ungoverned write: allowed"
  expect_nofile "$(sess_dir sid-pm-2)/.gov-session-changes" "ungoverned write is NOT recorded"
}

# --- sync-governance-copies.sh ----------------------------------------------------------------
case_sync_copies() {
  local src="$SBX/proj"
  fx_project "$src" SOURCE "$(_winform "$src")"
  fx_state_reset
  local hookfile="$SBX_HOME/.claude/hooks/governance/dummy-selftest.sh"
  mkdir -p "$(dirname "$hookfile")" 2>/dev/null
  printf '#!/usr/bin/env bash\nexit 0\n' > "$hookfile"
  # The hook mirrors, it never resurrects: it only refreshes a bundle that already exists. The
  # fixture therefore has to create the bundle directory, or the case would test the
  # "no bundle configured" path and call the silence a pass.
  mkdir -p "$SBX_HOME/.claude/governance-installer/bundle/hooks/governance" 2>/dev/null
  local mirror="$SBX_HOME/.claude/governance-installer/bundle/hooks/governance/dummy-selftest.sh"
  rm -f "$mirror" 2>/dev/null

  run_hook "$src" "sid-sc-1" "$(pl_post "$src" sid-sc-1 "$hookfile")"
  expect_rc 0 "hook edit: never blocks"
  expect_file "$mirror" "hook edit is mirrored into the installer bundle"

  local other="$SBX_HOME/.claude/governance-installer/bundle/hooks/governance/not-a-hook.js"
  rm -f "$other" 2>/dev/null
  local proj_js="$src/admin/lib/not-a-hook.js"; printf 'x\n' > "$proj_js"
  run_hook "$src" "sid-sc-2" "$(pl_post "$src" sid-sc-2 "$proj_js")"
  expect_rc 0 "project file: allowed"
  expect_nofile "$other" "project file is NOT mirrored into the bundle"

  # --- --sync-if-drifted, the Stop caller (2026-09-14) -----------------------------------------
  # This hook is PostToolUse on Edit|Write, so a file changed by a SCRIPT (sed, python, cp, a
  # heredoc) is never mirrored and nothing says so. The file's own comment has described that
  # since 2026-09-01 and ends "it needs a reconciler"; the reconciler was then written and
  # NOTHING CALLED IT. This mode is the caller, registered on Stop.
  # Both directions, and the clean one is load-bearing: a Stop hook that speaks on every close
  # trains the operator to skip its output, which is how a real drift goes unread.
  local live_h="$SBX_HOME/.claude/hooks/governance"
  local inst_h="$SBX_HOME/.claude/governance-installer/bundle/hooks/governance"
  mkdir -p "$live_h" "$inst_h" 2>/dev/null
  printf 'echo same\n' > "$live_h/drift-probe.sh"
  cp "$live_h/drift-probe.sh" "$inst_h/drift-probe.sh"

  _run "$CUR_SCRIPT" "$src" "sid-sc-3" '{"hook_event_name":"Stop"}' --sync-if-drifted
  expect_quiet "no drift: the Stop check is SILENT (it must not speak on every close)"

  printf 'echo CHANGED BY A SCRIPT, not by Edit/Write\n' > "$live_h/drift-probe.sh"
  _run "$CUR_SCRIPT" "$src" "sid-sc-4" '{"hook_event_name":"Stop"}' --sync-if-drifted
  expect_has "Drift detected" "a copy changed outside Edit/Write IS detected at Stop"
  expect_grep "CHANGED BY A SCRIPT" "$inst_h/drift-probe.sh" "and the stale copy is reconciled, not merely reported"

  # ══ 1.7.0: the extended sync surface ═══════════════════════════════════════════════════════
  # Every case below is BOTH directions on purpose. A crossing control tested only on its
  # refusal path can be refusing everything, and a control that only ever refuses gets switched
  # off — after which it protects nothing at all.
  local bundle="$SBX_HOME/.claude/governance-installer/bundle"
  mkdir -p "$bundle/agents" "$bundle/hooks" "$bundle/docs" "$bundle/skills" 2>/dev/null

  # bundle/DISTRIBUTED is the allow-list BOTH this hook and install.sh read. Absent, nothing
  # may cross — so the fixture writes one, and its absence is a case of its own at the end.
  cat > "$bundle/DISTRIBUTED" <<'SELFDISTEOF'
[core]
selftest-skill
[extended]
[agents]
selftest-agent
[hooks]
selftest-roothook.sh
SELFDISTEOF

  # --- *.local.* never crosses (2.2) --------------------------------------------------------
  # The name is the rule now, not a habit. MEASURED 2026-09-18: a real .local.md on this
  # machine carries a full name, a GitHub login and a Slack user id on its FIRST line.
  mkdir -p "$SBX_HOME/.claude/docs" 2>/dev/null
  local loc_live="$SBX_HOME/.claude/docs/secrets.local.md"
  printf 'owner-only content\n' > "$loc_live"
  rm -f "$bundle/docs/secrets.local.md" 2>/dev/null
  run_hook "$src" "sid-sc-loc" "$(pl_post "$src" sid-sc-loc "$loc_live")"
  expect_rc 0 "*.local.md edit: never blocks the write"
  expect_nofile "$bundle/docs/secrets.local.md" "*.local.md does NOT cross into the publishable bundle"

  local pub_live="$SBX_HOME/.claude/docs/ordinary.md"
  printf 'ordinary governance doc\n' > "$pub_live"
  rm -f "$bundle/docs/ordinary.md" 2>/dev/null
  run_hook "$src" "sid-sc-loc2" "$(pl_post "$src" sid-sc-loc2 "$pub_live")"
  expect_file "$bundle/docs/ordinary.md" "a NON-.local doc still crosses (the pattern is not over-broad)"

  # --- CLAUDE.md: rendered at the marker, never copied whole (5.2) ---------------------------
  local cmd_live="$SBX_HOME/.claude/CLAUDE.md"
  local cmd_dest="$bundle/CLAUDE.md.template"
  printf '%s\n' '# HEAD' '' '## Generic Preferences' '- generic' '' '---' > "$bundle/CLAUDE.md.template.head"

  # (a) marker ABSENT -> publish NOTHING, and name the line to add. "Copy the whole file" here
  #     would publish the personal section, which is the entire failure mode.
  printf '%s\n' '# Live' '' '## Policy' 'publishable' '' '## Personal' 'private detail' > "$cmd_live"
  rm -f "$cmd_dest" 2>/dev/null
  run_hook "$src" "sid-sc-cmd1" "$(pl_post "$src" sid-sc-cmd1 "$cmd_live")"
  expect_rc 0 "CLAUDE.md without a marker: never blocks the write"
  expect_has "NO local-only marker" "marker absent is REPORTED, not silent"
  expect_nofile "$cmd_dest" "marker absent: NOTHING is published from CLAUDE.md"

  # (b) marker PRESENT -> everything above it verbatim; nothing below it, ever.
  printf '%s\n' '# Live' '' '## Policy' 'publishable line' '' \
    '<!-- GOV-LOCAL-ONLY: nothing below this line is synced or published -->' '' \
    '## Personal' 'PRIVATE-DETAIL-MUST-NOT-SHIP' > "$cmd_live"
  rm -f "$cmd_dest" 2>/dev/null
  run_hook "$src" "sid-sc-cmd2" "$(pl_post "$src" sid-sc-cmd2 "$cmd_live")"
  expect_file "$cmd_dest" "marker present: the template IS rendered"
  expect_grep "publishable line" "$cmd_dest" "content ABOVE the marker is published verbatim"
  expect_nogrep "PRIVATE-DETAIL-MUST-NOT-SHIP" "$cmd_dest" "content BELOW the marker never reaches the bundle"
  expect_grep "Generic Preferences" "$cmd_dest" "the generic head is prepended"
  expect_nogrep "# Live" "$cmd_dest" "the live file's own H1 is dropped (no duplicate title)"

  # (c) a REAL VALUE above the marker -> the gate refuses the copy. The gate scans the RENDERED
  #     file; that is exactly why the render happens BEFORE the scan and not after.
  #     The fixture number is ASSEMBLED from two string literals so the contiguous phone shape
  #     never exists in this file's own text — this script also ships in the public bundle and
  #     is scanned by the same rule it is here to exercise. (A `pii-allow:` marker would work
  #     too; a shape that is simply absent needs no exemption to review later.)
  local _fx_phone='+972-50-'"123-4567"
  printf '%s\n' '# Live' '' '## Policy' "call me on $_fx_phone any time" '' \
    '<!-- GOV-LOCAL-ONLY: nothing below this line is synced or published -->' '' \
    '## Personal' 'x' > "$cmd_live"
  rm -f "$cmd_dest" 2>/dev/null
  run_hook "$src" "sid-sc-cmd3" "$(pl_post "$src" sid-sc-cmd3 "$cmd_live")"
  expect_nofile "$cmd_dest" "a real value ABOVE the marker REFUSES the copy (the gate scans the render)"

  # (d) a PROJECT .claude/CLAUDE.md is not the user-level one and must never be published.
  local proj_cmd="$src/.claude/CLAUDE.md"
  mkdir -p "$src/.claude" 2>/dev/null
  printf '%s\n' '# Project instructions' 'client-specific' > "$proj_cmd"
  printf '%s\n' '# Live' '' '## Policy' 'ok' '' \
    '<!-- GOV-LOCAL-ONLY: nothing below this line is synced or published -->' '' '## Personal' 'x' > "$cmd_live"
  rm -f "$cmd_dest" 2>/dev/null
  run_hook "$src" "sid-sc-cmd4" "$(pl_post "$src" sid-sc-cmd4 "$proj_cmd")"
  expect_has "PROJECT CLAUDE.md" "a project-level CLAUDE.md is refused by name"
  expect_nofile "$cmd_dest" "and nothing is published from it"

  # --- agents: allow-listed raw copy (5.3) --------------------------------------------------
  mkdir -p "$SBX_HOME/.claude/agents" 2>/dev/null
  printf '%s\n' '---' 'name: selftest-agent' 'model: opus' '---' 'generic role text' \
    > "$SBX_HOME/.claude/agents/selftest-agent.md"
  rm -f "$bundle/agents/selftest-agent.md" 2>/dev/null
  run_hook "$src" "sid-sc-ag1" "$(pl_post "$src" sid-sc-ag1 "$SBX_HOME/.claude/agents/selftest-agent.md")"
  expect_file "$bundle/agents/selftest-agent.md" "a LISTED agent crosses into the bundle"

  printf '%s\n' '---' 'name: selftest-unlisted' '---' 'text' \
    > "$SBX_HOME/.claude/agents/selftest-unlisted.md"
  rm -f "$bundle/agents/selftest-unlisted.md" 2>/dev/null
  run_hook "$src" "sid-sc-ag2" "$(pl_post "$src" sid-sc-ag2 "$SBX_HOME/.claude/agents/selftest-unlisted.md")"
  expect_rc 0 "an UNLISTED agent edit: never blocks the write"
  expect_has "not listed under [agents]" "an UNLISTED agent is refused OUT LOUD, not silently"
  expect_nofile "$bundle/agents/selftest-unlisted.md" "and it does NOT reach the bundle"

  # --- root hooks: allow-listed, depth 1 only (5.4) -----------------------------------------
  # This directory was UNWATCHED before 1.7.0, which is how a hook naming a real deployment
  # container sat in the public bundle while a clean copy existed locally: nothing compared
  # them, because nothing synced them.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SBX_HOME/.claude/hooks/selftest-roothook.sh"
  rm -f "$bundle/hooks/selftest-roothook.sh" 2>/dev/null
  run_hook "$src" "sid-sc-rh1" "$(pl_post "$src" sid-sc-rh1 "$SBX_HOME/.claude/hooks/selftest-roothook.sh")"
  expect_file "$bundle/hooks/selftest-roothook.sh" "a LISTED root hook crosses into the bundle"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$SBX_HOME/.claude/hooks/selftest-private.sh"
  rm -f "$bundle/hooks/selftest-private.sh" 2>/dev/null
  run_hook "$src" "sid-sc-rh2" "$(pl_post "$src" sid-sc-rh2 "$SBX_HOME/.claude/hooks/selftest-private.sh")"
  expect_has "not listed under [hooks]" "an UNLISTED root hook is refused OUT LOUD"
  expect_nofile "$bundle/hooks/selftest-private.sh" "and it does NOT reach the bundle"

  # --- skills: the allow-list is the mechanism now, the denylist only a belt (2.4) -----------
  mkdir -p "$SBX_HOME/.claude/skills/selftest-skill" "$SBX_HOME/.claude/skills/selftest-notshipped" 2>/dev/null
  printf 'listed skill\n' > "$SBX_HOME/.claude/skills/selftest-skill/SKILL.md"
  rm -f "$bundle/skills/selftest-skill/SKILL.md" 2>/dev/null
  run_hook "$src" "sid-sc-sk1" "$(pl_post "$src" sid-sc-sk1 "$SBX_HOME/.claude/skills/selftest-skill/SKILL.md")"
  expect_file "$bundle/skills/selftest-skill/SKILL.md" "a LISTED skill still crosses (the allow-list is not over-broad)"

  printf 'unlisted skill\n' > "$SBX_HOME/.claude/skills/selftest-notshipped/SKILL.md"
  rm -rf "$bundle/skills/selftest-notshipped" 2>/dev/null
  run_hook "$src" "sid-sc-sk2" "$(pl_post "$src" sid-sc-sk2 "$SBX_HOME/.claude/skills/selftest-notshipped/SKILL.md")"
  expect_has "not listed in bundle/DISTRIBUTED" "an UNLISTED skill is refused OUT LOUD (it used to be copied by default)"
  expect_nofile "$bundle/skills/selftest-notshipped/SKILL.md" "and it does NOT reach the bundle"

  # --- DISTRIBUTED missing => NOTHING crosses, loudly (fail-closed) -------------------------
  # The failure DIRECTION is the point: an unreadable allow-list must publish nothing, and must
  # not be quiet about it. A silent fail-open here would reintroduce the whole defect.
  mv "$bundle/DISTRIBUTED" "$bundle/DISTRIBUTED.hidden" 2>/dev/null
  rm -f "$bundle/agents/selftest-agent.md" 2>/dev/null
  printf '%s\n' '---' 'name: selftest-agent' '---' 'changed' > "$SBX_HOME/.claude/agents/selftest-agent.md"
  run_hook "$src" "sid-sc-nd" "$(pl_post "$src" sid-sc-nd "$SBX_HOME/.claude/agents/selftest-agent.md")"
  expect_has "DISTRIBUTED is MISSING" "a missing allow-list is announced, not assumed"
  expect_nofile "$bundle/agents/selftest-agent.md" "and NOTHING crosses while it is missing (fail closed)"
  mv "$bundle/DISTRIBUTED.hidden" "$bundle/DISTRIBUTED" 2>/dev/null
}

# --- file-collision-record.sh -----------------------------------------------------------------
case_collision_record() {
  local repo="$SBX/proj"
  fx_project "$repo" SOURCE "$(_winform "$repo")"
  [ -d "$repo/.git" ] || sbx_git "$repo" init
  fx_state_reset
  local f="$repo/admin/lib/recorded.js"; printf 'v1\n' > "$f"

  run_hook "$repo" "sid-cr-1" "$(pl_post "$repo" sid-cr-1 "$f")"
  expect_rc 0 "record: never blocks"
  if [ -n "$(ls -A "$SBX_HOME/.claude/logs/file-locks" 2>/dev/null)" ]; then
    _ok "write claim is recorded so other sessions can see it"
  else
    _bad "write claim is recorded so other sessions can see it" \
         "expected at least one claim under $SBX_HOME/.claude/logs/file-locks (empty)"
  fi

  rm -rf "$SBX_HOME/.claude/logs/file-locks" 2>/dev/null
  printf 'x\n' > "$SBX/outside-any-repo.js"
  run_hook "$SBX" "sid-cr-2" "$(pl_post "$SBX" sid-cr-2 "$SBX/outside-any-repo.js")"
  expect_rc 0 "non-repo write: allowed"
  if [ -z "$(ls -A "$SBX_HOME/.claude/logs/file-locks" 2>/dev/null)" ]; then
    _ok "non-repo write claims nothing"
  else
    _bad "non-repo write claims nothing" "a claim appeared for a file outside any git repo: $(ls -A "$SBX_HOME/.claude/logs/file-locks" 2>/dev/null | head -3)"
  fi
}

# --- check-full-finish.sh ---------------------------------------------------------------------
case_check_full_finish() {
  # A fresh repo per invocation. This hook is registered TWICE (TaskCompleted and Stop), so a
  # shared repo would carry the staged file from the first invocation into the second and turn
  # the must-allow case red for a reason that has nothing to do with the hook.
  FF_SEQ=$(( ${FF_SEQ:-0} + 1 ))
  local repo="$SBX/ffrepo-$FF_SEQ"
  mkdir -p "$repo" 2>/dev/null
  [ -d "$repo/.git" ] || sbx_git "$repo" init
  printf 'x\n' > "$repo/readme.md"
  fx_state_reset

  run_hook "$repo" "sid-ff-1" "$(pl_plain "$repo" sid-ff-1 Stop)"
  expect_rc 0 "clean tree: stop allowed"

  printf 'console.log(1)\n' > "$repo/feature.js"
  sbx_git "$repo" add feature.js
  run_hook "$repo" "sid-ff-2" "$(pl_plain "$repo" sid-ff-2 Stop)"
  expect_rc 2 "staged code changes: stop BLOCKED"
  expect_has "full-finish" "staged code changes: names the release pipeline"
  expect_has "git show --stat" "staged code changes: the remedy is commit-and-verify, not a release (2026-09-29)"
}

# --- check-docs-updated.sh --------------------------------------------------------------------
case_check_docs() {
  local src="$SBX/proj"
  fx_project "$src" SOURCE "$(_winform "$src")"
  fx_state_reset

  fx_changes sid-cd-1 "$src/admin/lib/a.js" "$src/admin/lib/b.js"
  run_hook "$src" "sid-cd-1" "$(pl_plain "$src" sid-cd-1 TaskCompleted)"
  expect_rc 0 "advisory only, never blocks a task"
  expect_has "[doc-check]" "code changed with no doc update: advisory fires"

  fx_changes sid-cd-2 "$src/admin/lib/a.js" "$src/docs/context/GOTCHAS.md"
  run_hook "$src" "sid-cd-2" "$(pl_plain "$src" sid-cd-2 TaskCompleted)"
  expect_rc 0 "documented session: allowed"
  expect_not "[doc-check]" "documented session: no advisory"
}

# --- pre-done.sh ------------------------------------------------------------------------------
case_pre_done() {
  local src="$SBX/proj"
  fx_project "$src" SOURCE "$(_winform "$src")"
  fx_state_reset

  # DEFAULT (1.7.1): gate off - changes without a token do NOT block task completion.
  fx_changes sid-pd-0 "$src/admin/lib/a.js"
  fx_token
  unset GOV_REQUIRE_SUCCESS_TOKEN
  run_hook "$src" "sid-pd-0" "$(pl_plain "$src" sid-pd-0 TaskCompleted)"
  expect_rc 0 "default (gate off): changes without a token: task completion ALLOWED"

  export GOV_REQUIRE_SUCCESS_TOKEN=1
  fx_changes sid-pd-1 "$src/admin/lib/a.js" "$src/admin/lib/b.js"
  fx_token
  run_hook "$src" "sid-pd-1" "$(pl_plain "$src" sid-pd-1 TaskCompleted)"
  expect_rc 2 "changes without evidence token: task completion BLOCKED"
  expect_has "VERIFICATION GATE" "verification gate: names itself"

  fx_token 300
  run_hook "$src" "sid-pd-2" "$(pl_plain "$src" sid-pd-2 TaskCompleted)"
  expect_rc 0 "no tracked changes: allowed"

  fx_changes sid-pd-3 "$src/admin/lib/a.js"
  fx_token 300
  run_hook "$src" "sid-pd-3" "$(pl_plain "$src" sid-pd-3 TaskCompleted)"
  expect_rc 0 "changes with a fresh token: allowed"
  fx_token
  unset GOV_REQUIRE_SUCCESS_TOKEN
}

# --- end-session.sh ---------------------------------------------------------------------------
# The must-allow case deliberately uses a project with NO version.json so the hook returns at its
# "no version.json" gate. Everything past that point in this hook eventually reaches a block that
# does `git clone` + `git push` against a real public repo; the git shim would deny it, but a
# check should not need its own safety net to be safe.
case_end_session() {
  local src="$SBX/proj"
  fx_project "$src" SOURCE "$(_winform "$src")"
  rm -f "$src/version.json" 2>/dev/null
  rm -f "$SBX_HOME/.claude/logs/.governance-push-pending" 2>/dev/null
  fx_state_reset

  fx_changes sid-es-1 "$src/admin/lib/a.js" "$src/admin/lib/b.js" "$src/admin/lib/c.js" "$src/admin/lib/d.js"
  run_hook "$src" "sid-es-1" "$(pl_plain "$src" sid-es-1 Stop)"
  expect_rc 2 "4 writes and no fresh HANDOFF: stop BLOCKED"
  expect_has "no HANDOFF file is among them" "handoff gate: names what is missing"

  fx_changes sid-es-2 "$src/admin/lib/a.js" "$src/admin/lib/b.js" "$src/docs/context/HANDOFF.md" "$src/admin/lib/c.js"
  run_hook "$src" "sid-es-2" "$(pl_plain "$src" sid-es-2 Stop)"
  expect_rc 0 "writes WITH a refreshed HANDOFF: stop allowed"
  expect_not "BLOCKED" "refreshed handoff: no false block"

  # ── The git half (task B27, 2026-09-01) ────────────────────────────────────────────────────
  # Until this shipped, Check 0 read ONLY the PostToolUse change log — which never sees a Bash
  # edit, because PostToolUse does not fire for Bash. Two consequences, and BOTH are asserted here
  # because they pull in opposite directions:
  #   * a session that wrote everything through Bash logged ZERO, stayed under the >= 3 threshold,
  #     and closed with no handoff in SILENCE (the dangerous half);
  #   * a session that DID write a handoff through Bash was blocked for not having one (the loud
  #     half — measured at a real close on 2026-09-01, 6 logged against 23 actually written).
  local grepo="$SBX/esgit"
  rm -rf "$grepo" 2>/dev/null
  mkdir -p "$grepo/admin/lib" "$grepo/MDs" 2>/dev/null
  fx_project "$grepo" SOURCE "$(_winform "$grepo")"
  rm -f "$grepo/version.json" 2>/dev/null
  [ -d "$grepo/.git" ] || sbx_git "$grepo" init
  sbx_git "$grepo" config user.email "you@example.com"
  sbx_git "$grepo" config user.name "Operator One"
  sbx_git "$grepo" add -A
  sbx_git "$grepo" commit -m baseline
  local gbase; gbase="$("$REAL_GIT" -C "$grepo" rev-parse HEAD 2>/dev/null)"

  _es_stamp() {   # $1 sid, $2 root to stamp
    local d; d="$(sess_dir "$1")"; mkdir -p "$d" 2>/dev/null
    : > "$d/.gov-session-changes"     # EMPTY on purpose: this is the Bash-only session
    printf '%s %s %s sid=%s\n' "$gbase" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$1" > "$d/.gov-session-start"
  }

  printf 'a\n' > "$grepo/admin/lib/g1.js"; printf 'b\n' > "$grepo/admin/lib/g2.js"; printf 'c\n' > "$grepo/admin/lib/g3.js"
  sbx_git "$grepo" add -A; sbx_git "$grepo" commit -m "three files, via a script"
  _es_stamp sid-es-3 "$grepo"
  run_hook "$grepo" "sid-es-3" "$(pl_plain "$grepo" sid-es-3 Stop)"
  expect_rc 2 "3 files written through Bash with an EMPTY change log: stop BLOCKED (the log alone saw nothing)"
  expect_has "git " "block: names git as the evidence, not just the log"

  printf -- '---\nstatus: active\n---\n' > "$grepo/MDs/HANDOFF-es.md"
  sbx_git "$grepo" add -A; sbx_git "$grepo" commit -m "handoff, also via a script"
  _es_stamp sid-es-4 "$grepo"
  run_hook "$grepo" "sid-es-4" "$(pl_plain "$grepo" sid-es-4 Stop)"
  expect_rc 0 "a handoff written through Bash (never logged): stop allowed"

  # A stamp belonging to ANOTHER repository must not be used as a range, and the degradation to
  # log-only must be stated out loud rather than absorbed.
  _es_stamp sid-es-5 "$SBX/proj"
  fx_changes sid-es-5 "$grepo/admin/lib/x.js" "$grepo/admin/lib/y.js" "$grepo/admin/lib/z.js"
  run_hook "$grepo" "sid-es-5" "$(pl_plain "$grepo" sid-es-5 Stop)"
  expect_rc 2 "a stamp from another repo: falls back to the log and still blocks"
  expect_has "GIT NOT CONSULTED" "fallback: says the gate is running blind, instead of pretending"

  # ── The publish set (r2 finding 10, 2026-10-01) ────────────────────────────────────────────
  # GOV_PUBLISH=1 at a close copies staging into the public clone and pushes it. It copied bundle/,
  # install.sh, verify.sh and README.md - never NOTICE-AUTO-UPDATE.md or LICENSE - so a publish
  # shipped the new install.sh beside the OLD terms text it prints as the one the user accepts.
  # Rehearsed end to end against throwaway repos (GOV_INSTALLER_REPO / GOV_REPO_PATH, a bare origin
  # inside the sandbox that only the shim's GOV_SELFTEST_LOCAL_REMOTE exception lets pull/push reach),
  # in both directions: clean texts reach the origin; a real value in the NOTICE is stopped by the
  # same PII gate as every other staged file, and nothing reaches the origin.
  # Not under a mutant (MUT=1): NOOP is killed by the cases above, NOBLOCK changes nothing on this
  # path (it never exits 2), and the four runs here (two with git + the PII scanner) would triple a
  # cost that buys no kill. Non-vacuity was shown directly instead: against the unfixed hook these
  # assertions went 6 red, rehearsal control green (2026-10-01).
  [ "$MUT" = 1 ] && return 0
  local pproj="$SBX/pubproj" pst="$SBX/pubstage" pcl="$SBX/pubclone" prem="$SBX/pubremote.git" purl pf
  rm -rf "$pproj" "$pst" "$pcl" "$prem" 2>/dev/null
  fx_project "$pproj" SOURCE "$(_winform "$pproj")"
  printf '{"version":"9.9.9"}\n' > "$pproj/version.json"
  printf -- '---\nstatus: active\n---\n# HANDOFF v9.9.9\n' > "$pproj/MDs/HANDOFF-v9.9.9.md"
  _es_pubtree() {   # $1 dir, $2 tag for the two texts
    mkdir -p "$1/bundle" 2>/dev/null
    printf '9.9.9\n' > "$1/bundle/VERSION"
    printf '#!/usr/bin/env bash\necho install\n' > "$1/install.sh"
    printf '#!/usr/bin/env bash\necho verify\n' > "$1/verify.sh"
    printf '# README (selftest fixture)\n' > "$1/README.md"
    printf '# Notice (selftest fixture) PUB-NOTICE-%s\n\nTerms version: 9\n' "$2" > "$1/NOTICE-AUTO-UPDATE.md"
    printf 'MIT License (selftest fixture) PUB-LICENSE-%s\n' "$2" > "$1/LICENSE"
  }
  "$REAL_GIT" init -q --bare "$prem" >/dev/null 2>&1
  sbx_git "$prem" symbolic-ref HEAD refs/heads/master
  mkdir -p "$pcl" 2>/dev/null; sbx_git "$pcl" init
  sbx_git "$pcl" symbolic-ref HEAD refs/heads/master
  sbx_git "$pcl" config user.email "you@example.com"
  sbx_git "$pcl" config user.name "Operator One"
  _es_pubtree "$pcl" OLD
  sbx_git "$pcl" add -A; sbx_git "$pcl" commit -m "the published state before this close"
  sbx_git "$pcl" remote add origin "$prem"
  purl="$("$REAL_GIT" -C "$pcl" remote get-url origin 2>/dev/null)"
  sbx_git "$pcl" push -q origin master
  _es_pubtree "$pst" NEW
  printf '9.9.10\n' > "$pst/bundle/VERSION"
  pf="$SBX_HOME/.claude/logs/.governance-push-pending"
  _es_pubshow() { "$REAL_GIT" -C "$prem" show "master:$1" 2>/dev/null; }

  fx_state_reset
  printf '2026-10-01T00:00:00Z bundle/VERSION\n' > "$pf"
  # The preview a human reads before GOV_PUBLISH=1 lists the top-level files too.
  _RUN_ENV=(GOV_INSTALLER_REPO="$pst" GOV_REPO_PATH="$pcl")
  run_hook "$pproj" "sid-es-pp1" '' --publish-preview
  _RUN_ENV=()
  expect_has "would update     NOTICE-AUTO-UPDATE.md" "publish preview: names the NOTICE that differs"
  expect_has "would update     LICENSE" "publish preview: names the LICENSE that differs"
  _RUN_ENV=(GOV_PUBLISH=1 GOV_INSTALLER_REPO="$pst" GOV_REPO_PATH="$pcl" GOV_SELFTEST_LOCAL_REMOTE="$purl")
  _RUN_TIMEOUT=600 run_hook "$pproj" "sid-es-6" "$(pl_plain "$pproj" sid-es-6 Stop)"
  _RUN_ENV=()
  expect_rc 0 "GOV_PUBLISH=1 with clean texts: the close publishes"
  expect_has "auto-pushed" "  and says it pushed"
  case "$(_es_pubshow bundle/VERSION)" in
    9.9.10*) _ok "  control: the queued bundle file reached the origin (the rehearsal really pushed)" ;;
    *) _bad "  control: the queued bundle file reached the origin" "origin bundle/VERSION: $(_snip "$(_es_pubshow bundle/VERSION)"); output: $(_snip "$BOTH")" ;;
  esac
  case "$(_es_pubshow NOTICE-AUTO-UPDATE.md)" in
    *PUB-NOTICE-NEW*) _ok "  NOTICE-AUTO-UPDATE.md is in the published set: the origin holds the staging text" ;;
    *) _bad "  NOTICE-AUTO-UPDATE.md is in the published set" "origin NOTICE: $(_snip "$(_es_pubshow NOTICE-AUTO-UPDATE.md)") - the publish shipped install.sh beside the OLD terms text" ;;
  esac
  case "$(_es_pubshow LICENSE)" in
    *PUB-LICENSE-NEW*) _ok "  LICENSE is in the published set: the origin holds the staging text" ;;
    *) _bad "  LICENSE is in the published set" "origin LICENSE: $(_snip "$(_es_pubshow LICENSE)")" ;;
  esac
  expect_nofile "$pf" "  a pushed queue is cleared"
  _RUN_ENV=(GOV_INSTALLER_REPO="$pst" GOV_REPO_PATH="$pcl")
  run_hook "$pproj" "sid-es-pp2" '' --publish-preview
  _RUN_ENV=()
  expect_has "0 file(s) differ, 0 new in staging" "publish preview after the push: nothing differs"
  expect_not "NOTICE-AUTO-UPDATE.md" "  and names no NOTICE"

  # The shim's exception admits only the EXACT commands above (round 3, 2026-10-02). Probed in the
  # same clone with the same exception armed: an option that redirects the push (--repo=) or runs a
  # program at the other end (--receive-pack= / --upload-pack=) is refused before git runs. The
  # violation lines the probes write are checked, then removed, so the suite-wide "no hook
  # attempted a denied git operation" check stays about hooks.
  local _vsave="$SBX/git-violations.save" _dec="$SBX/decoy.git" _rp="$SBX/rp-probe.sh" _vn0 _vn1 _prc
  cp -f "$GIT_VIOL" "$_vsave" 2>/dev/null; _vn0=$(grep -c . "$GIT_VIOL" 2>/dev/null)
  "$REAL_GIT" init -q --bare "$_dec" >/dev/null 2>&1
  printf '#!/bin/sh\n: > "%s/rp-ran"\nexit 1\n' "$SBX" > "$_rp"; chmod +x "$_rp" 2>/dev/null; rm -f "$SBX/rp-ran"
  _shimx() { ( cd "$pcl" && env GOV_SELFTEST_SBX="$SBX" GOV_SELFTEST_REAL_GIT="$REAL_GIT" GOV_SELFTEST_LOCAL_REMOTE="$purl" \
               GIT_TERMINAL_PROMPT=0 "$SBX_BIN/git" "$@" ) >/dev/null 2>&1; }
  _shimx push "--repo=$_dec" origin master; _prc=$?
  if [ "$_prc" != 0 ] && ! "$REAL_GIT" -C "$_dec" rev-parse --verify -q refs/heads/master >/dev/null 2>&1; then
    _ok "  git shim: 'push --repo=<other repo> origin master' refused under the exception (nothing reached it)"
  else _bad "  git shim: push --repo= refused" "rc=$_prc; decoy master: $("$REAL_GIT" -C "$_dec" rev-parse -q refs/heads/master 2>/dev/null)"; fi
  _shimx push "--receive-pack=$_rp" origin master; _prc=$?
  if [ "$_prc" != 0 ] && [ ! -e "$SBX/rp-ran" ]; then _ok "  git shim: 'push --receive-pack=<cmd>' refused (the command never ran)"
  else _bad "  git shim: push --receive-pack= refused" "rc=$_prc; probe ran: $([ -e "$SBX/rp-ran" ] && echo yes || echo no)"; fi
  rm -f "$SBX/rp-ran"
  _shimx pull "--upload-pack=$_rp" --rebase --autostash origin master; _prc=$?
  if [ "$_prc" != 0 ] && [ ! -e "$SBX/rp-ran" ]; then _ok "  git shim: 'pull --upload-pack=<cmd> ...' refused (the command never ran)"
  else _bad "  git shim: pull --upload-pack= refused" "rc=$_prc; probe ran: $([ -e "$SBX/rp-ran" ] && echo yes || echo no)"; fi
  _vn1=$(grep -c . "$GIT_VIOL" 2>/dev/null)
  [ "$(( ${_vn1:-0} - ${_vn0:-0} ))" = 3 ] && _ok "  git shim: each refusal is recorded as a violation (3)" \
    || _bad "  git shim: each refusal is recorded" "violation lines before/after: ${_vn0:-0}/${_vn1:-0}"
  _shimx push origin master; _prc=$?
  [ "$_prc" = 0 ] && _ok "  control: the exact 'push origin master' still passes the shim (rc 0)" \
    || _bad "  control: the exact push still passes" "rc=$_prc"
  # Global options before the subcommand (round 3b, 2026-10-02). MEASURED on the old shim: it took
  # the word after `-C` / `-c` as the subcommand, so `-C <outside> push <decoy> master` pushed and
  # `-C <outside> commit` committed, with no violation line. A repo OUTSIDE the sandbox (a sibling
  # under the sandbox parent, removed below) is the target; the read-only `remote get-url` and
  # `config --get` forms must still pass (pr-watch-guard.sh / end-session.sh run them).
  local _out="$SBX_PARENT/shimprobe-$$" _h0 _vn2 _vn3 _rout
  rm -rf "$_out"; "$REAL_GIT" init -q "$_out" >/dev/null 2>&1
  "$REAL_GIT" -C "$_out" -c user.name=s -c user.email=s@example.com commit -q --allow-empty -m base >/dev/null 2>&1
  "$REAL_GIT" -C "$_out" remote add origin "$_dec" >/dev/null 2>&1; "$REAL_GIT" -C "$_out" config test.key v
  _h0=$("$REAL_GIT" -C "$_out" rev-parse HEAD 2>/dev/null); _vn2=$(grep -c . "$GIT_VIOL" 2>/dev/null)
  _shimx -C "$_out" push "$_dec" master; _prc=$?
  if [ "$_prc" != 0 ] && ! "$REAL_GIT" -C "$_dec" rev-parse --verify -q refs/heads/master >/dev/null 2>&1; then
    _ok "  git shim: '-C <outside> push <decoy> master' refused (nothing reached the decoy)"
  else _bad "  git shim: -C <outside> push refused" "rc=$_prc; decoy master: $("$REAL_GIT" -C "$_dec" rev-parse -q refs/heads/master 2>/dev/null)"; fi
  _shimx -C "$_out" -c user.name=s -c user.email=s@example.com commit -q --allow-empty -m x; _prc=$?
  [ "$_prc" != 0 ] && [ "$("$REAL_GIT" -C "$_out" rev-parse HEAD 2>/dev/null)" = "$_h0" ] \
    && _ok "  git shim: '-C <outside> -c k=v commit' refused (the outside repo is unchanged)" \
    || _bad "  git shim: -C <outside> commit refused" "rc=$_prc; HEAD moved: $("$REAL_GIT" -C "$_out" log -1 --format=%s 2>/dev/null)"
  ( cd "$_out" && env GOV_SELFTEST_SBX="$SBX" GOV_SELFTEST_REAL_GIT="$REAL_GIT" \
      "$SBX_BIN/git" -c user.name=s -c user.email=s@example.com commit -q --allow-empty -m y ) >/dev/null 2>&1; _prc=$?
  [ "$_prc" != 0 ] && [ "$("$REAL_GIT" -C "$_out" rev-parse HEAD 2>/dev/null)" = "$_h0" ] \
    && _ok "  git shim: '-c k=v commit' run in an outside repo refused" \
    || _bad "  git shim: -c k=v commit outside refused" "rc=$_prc"
  _shimx --git-dir="$_out/.git" --work-tree="$_out" -c user.name=s -c user.email=s@example.com commit -q --allow-empty -m z; _prc=$?
  [ "$_prc" != 0 ] && [ "$("$REAL_GIT" -C "$_out" rev-parse HEAD 2>/dev/null)" = "$_h0" ] \
    && _ok "  git shim: '--git-dir=<outside> --work-tree=<outside> commit' refused" \
    || _bad "  git shim: --git-dir=<outside> commit refused" "rc=$_prc"
  _vn3=$(grep -c . "$GIT_VIOL" 2>/dev/null)
  [ "$(( ${_vn3:-0} - ${_vn2:-0} ))" = 4 ] && _ok "  git shim: each of the four refusals is recorded as a violation" \
    || _bad "  git shim: the four refusals are recorded" "violation lines before/after: ${_vn2:-0}/${_vn3:-0}"
  _rout=$( cd "$pcl" && env GOV_SELFTEST_SBX="$SBX" GOV_SELFTEST_REAL_GIT="$REAL_GIT" "$SBX_BIN/git" -C "$_out" remote get-url origin 2>/dev/null ); _prc=$?
  # (git may print the URL in its C:/ spelling on Windows, so the tail is compared)
  case "$_rout" in */decoy.git) ;; *) _prc="$_prc/url" ;; esac
  [ "$_prc" = 0 ] && [ "$(grep -c . "$GIT_VIOL" 2>/dev/null)" = "${_vn3:-0}" ] \
    && _ok "  control: '-C <outside> remote get-url origin' still passes (read-only; pr-watch-guard.sh runs it)" \
    || _bad "  control: -C <outside> remote get-url passes" "rc=$_prc out=[$_rout]"
  _rout=$( cd "$pcl" && env GOV_SELFTEST_SBX="$SBX" GOV_SELFTEST_REAL_GIT="$REAL_GIT" "$SBX_BIN/git" -C "$_out" config --get test.key 2>/dev/null ); _prc=$?
  [ "$_prc" = 0 ] && [ "$_rout" = v ] && [ "$(grep -c . "$GIT_VIOL" 2>/dev/null)" = "${_vn3:-0}" ] \
    && _ok "  control: '-C <outside> config --get' still passes (read-only)" \
    || _bad "  control: -C <outside> config --get passes" "rc=$_prc out=[$_rout]"
  rm -rf "$_out"
  cp -f "$_vsave" "$GIT_VIOL" 2>/dev/null; rm -f "$_vsave" "$_rp"; rm -rf "$_dec"

  # The other direction: the same gate. A live-shaped phone number assembled at runtime (this file is
  # published too - see case_pii_gate), placed only in the NOTICE.
  local _pt='54' _p2='987' _p3='6543'
  printf '# Notice (selftest fixture) PUB-NOTICE-DIRTY\nowner reachable on +972 %s %s %s\n\nTerms version: 9\n' \
    "$_pt" "$_p2" "$_p3" > "$pst/NOTICE-AUTO-UPDATE.md"
  printf '2026-10-01T00:00:01Z bundle/VERSION\n' > "$pf"
  _RUN_ENV=(GOV_PUBLISH=1 GOV_INSTALLER_REPO="$pst" GOV_REPO_PATH="$pcl" GOV_SELFTEST_LOCAL_REMOTE="$purl")
  _RUN_TIMEOUT=600 run_hook "$pproj" "sid-es-7" "$(pl_plain "$pproj" sid-es-7 Stop)"
  _RUN_ENV=()
  expect_rc 0 "  a held publish still ends the close normally (the hook's own exit is 0)"
  expect_has "PUSH ABORTED - a staged file carries a real value" "a real value in the NOTICE: the PII gate aborts the publish"
  expect_has "NOTICE-AUTO-UPDATE.md:" "  and names the NOTICE as the file that carries it"
  case "$(_es_pubshow NOTICE-AUTO-UPDATE.md)" in
    *PUB-NOTICE-DIRTY*) _bad "  nothing reached the origin" "the origin NOTICE holds the dirty text" ;;
    *PUB-NOTICE-NEW*)   _ok "  nothing reached the origin: it still holds the clean NOTICE" ;;
    *) _bad "  nothing reached the origin" "origin NOTICE: $(_snip "$(_es_pubshow NOTICE-AUTO-UPDATE.md)")" ;;
  esac
  expect_file "$pf" "  the queue is kept for the retry"
}

# --- pii-gate-pretooluse.sh -------------------------------------------------------------------
# Armed 2026-09-01 and, until now, EXECUTED BY NOTHING. Three agents proved it by hand that night;
# the selftest still reported it UNCOVERED, and it was right to: a hand-run is not coverage,
# because nothing re-runs it on the next edit. That is the entire thesis of this repair.
#
# The MALFUNCTION case is the one that matters most. The gate's helper is a .py, and install.sh
# copies `*.sh *.js *.ps1` — so a fresh install registers this gate and ships it INERT while
# printing "Verified" (task B1). This case reproduces that state deliberately: the hook alone in a
# directory with no parser beside it. It must announce itself and exit 1 (open but LOUD), never
# exit 0 (open and silent).
case_pii_gate() {
  local gdir="$SBX_HOME/.claude/hooks/governance" nogate="$SBX/nogate"
  mkdir -p "$gdir" "$nogate" 2>/dev/null
  local target="$gdir/probe-hook.sh"
  # A live-shaped Israeli mobile, ASSEMBLED AT RUNTIME so this file never contains the literal.
  # It must NOT be the documented 972500000000 placeholder - the scanner is required to stay green
  # on that, so a placeholder here would assert nothing. But a real-shaped literal in the source
  # makes THIS file fail the very gate it is testing, and the file is published: the sync refused
  # it (rc=2, [IL_PHONE]) the first time, which is the gate working exactly as intended. Fix the
  # DATA, not the scanner - the same trick check-no-pii.sh uses for its own fixtures.
  local _ilt='54' _il2='987' _il3='6543'
  local dirty="# owner reachable on +972 ${_ilt} ${_il2} ${_il3} for escalations"
  local clean='# owner reachable on +972500000000 (placeholder) for escalations'

  # The payloads are built here rather than with pl_pre(): that helper hardcodes content "x", and
  # the PENDING TEXT is the whole point of this gate — it scans what is about to be written, not
  # the bytes already on disk (pointing a scanner at file_path passes every new file ever created).
  local pay_dirty pay_clean pay_out
  pay_dirty="{\"session_id\":\"sid-pii-1\",\"cwd\":\"$SBX\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$target\",\"content\":\"$dirty\"}}"
  pay_clean="{\"session_id\":\"sid-pii-2\",\"cwd\":\"$SBX\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$target\",\"content\":\"$clean\"}}"
  pay_out="{\"session_id\":\"sid-pii-3\",\"cwd\":\"$SBX\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$SBX/elsewhere/notes.md\",\"content\":\"$dirty\"}}"

  run_hook "$SBX" "sid-pii-1" "$pay_dirty"
  expect_rc 2 "a real phone number in a PUBLISHED governance file: write BLOCKED"
  expect_has "BLOCKED by pii-gate" "block: names itself so the agent knows what refused"

  run_hook "$SBX" "sid-pii-2" "$pay_clean"
  expect_rc 0 "the documented placeholder in the same file: write ALLOWED"
  expect_not "BLOCKED" "allow: no block text on a clean write"

  run_hook "$SBX" "sid-pii-3" "$pay_out"
  expect_rc 0 "a file outside the published tree: out of scope, allowed"

  # B1 in miniature: the gate present, its parser absent.
  cp -f "$CUR_SCRIPT" "$nogate/pii-gate-pretooluse.sh" 2>/dev/null
  rm -f "$nogate/pii-gate-parse.py" 2>/dev/null
  _run "$nogate/pii-gate-pretooluse.sh" "$SBX" "sid-pii-4" "$pay_dirty"
  expect_rc 1 "parser missing: exit 1 (open but LOUD), never a silent 0"
  expect_has "MALFUNCTION" "parser missing: says so, instead of passing the leak in silence"
}

# --- selftest-advisory-stop.sh ----------------------------------------------------------------
# The other hook armed that night and executed by nothing. It can NEVER exit 2 by design (a slow
# machine-wide audit with veto power over "stop working" is what gets ripped out), so its teeth are
# entirely in exit 1 + the banner. That makes an exit-code-only assertion worthless here and the
# printed text load-bearing — the same property that hid the canonical-cwd-check bug.
#
# The throttle file is pre-dated to NOW on purpose: without it the hook launches the real ~118 s
# suite, detached, in the middle of this run.
case_selftest_advisory() {
  local L="$SBX_HOME/.claude/logs"
  mkdir -p "$L" 2>/dev/null
  _adv_state() {   # $1 verdict
    rm -rf "$L/governance-selftest.lock" 2>/dev/null
    date +%s > "$L/governance-selftest.launched"
    printf 'verdict=%s\nrc=1\nfinished=%s\nseconds=130\nproject=%s\nsummary=[governance-selftest] pass=1 fail=1 uncovered=0\n' \
      "$1" "$(date +%s)" "$SBX/proj" > "$L/governance-selftest.result"
  }

  _adv_state RED
  run_hook "$SBX" "sid-adv-1" "$(pl_plain "$SBX" sid-adv-1 Stop)"
  expect_rc 1 "a RED framework audit: the close is nagged (exit 1), not blocked (never 2)"
  expect_has "RED" "red: the verdict word reaches the human"

  _adv_state GREEN-PARTIAL
  run_hook "$SBX" "sid-adv-2" "$(pl_plain "$SBX" sid-adv-2 Stop)"
  expect_rc 1 "GREEN-PARTIAL is reported as not-evidence, not as green"
  expect_has "GREEN-PARTIAL" "partial: says which half was not verified"

  _adv_state GREEN
  run_hook "$SBX" "sid-adv-3" "$(pl_plain "$SBX" sid-adv-3 Stop)"
  expect_rc 0 "a GREEN audit: silent close"
  expect_quiet "green: prints nothing at all"
}

# --- close-report.sh --------------------------------------------------------------------------
# The closing summary is GENERATED from the canonical files. Its whole value is one property, so
# that is what is asserted here, as a PAIR: a token that is only in a non-canonical file must not
# render, and the SAME token must render once it is written into a canonical one. Without the
# second half the first proves nothing — "absent" and "the hook never ran" print identically.
case_close_report() {
  local proj="$SBX/crproj"
  mkdir -p "$proj/docs/context" "$proj/MDs" "$proj/Plans" "$proj/scratch" 2>/dev/null
  fx_project "$proj" SOURCE "$(_winform "$proj")"
  printf -- '---\nstatus: active\ncreated_at: 2026-01-02\n---\n\n## TL;DR\n\nCR-RECORDED-LINE is in the handoff.\n' > "$proj/MDs/HANDOFF-cr.md"
  printf -- '---\nstatus: active\ntype: pointer\npoints_to: ../../MDs/HANDOFF-cr.md\n---\n# pointer\n' > "$proj/docs/context/HANDOFF.md"
  printf 'note: CR-UNRECORDED-TOKEN decided while writing the summary, never filed.\n' > "$proj/scratch/notes.md"

  run_hook "$proj" "sid-cr-1" "$(pl_plain "$proj" sid-cr-1 Stop)"
  expect_rc 0 "a report is not a gate: it never blocks a close"
  expect_has "CR-RECORDED-LINE" "renders what IS in the canonical record"
  expect_not "CR-UNRECORDED-TOKEN" "a claim in a scratch file has NO channel into the report"

  printf -- '- **2026-01-03 — CR-UNRECORDED-TOKEN is now filed.**\n' >> "$proj/docs/context/MEMORY.md"
  run_hook "$proj" "sid-cr-2" "$(pl_plain "$proj" sid-cr-2 Stop)"
  expect_has "CR-UNRECORDED-TOKEN" "THE PAIR: the same token renders once it is written into MEMORY.md"
}

# --- close-completeness.sh --------------------------------------------------------------------
# Wired 2026-09-01 after being found registered NOWHERE - the third such file in one session - and
# it went straight from unwired to uncovered, which is the same hole wearing a different label.
# Two behaviours must hold and they pull in opposite directions, so both are asserted:
#   BLOCK  a session that changed CODE and never wrote the records that describe it;
#   ALLOW  the moment those records actually GROW (a touch must not clear it: another Stop hook
#          rewrites version lines in place, and counting that as compliance is how the drift
#          stayed invisible for eleven days).
# The integrity warnings are asserted separately BECAUSE they must never block: they are printed
# on the allow path too, where a blocking assertion could never see them.
case_close_completeness() {
  local repo="$SBX/ccproj" sid
  rm -rf "$repo" 2>/dev/null
  mkdir -p "$repo/admin/lib" 2>/dev/null
  fx_project "$repo" SOURCE "$(_winform "$repo")"
  printf 'Plans/PLAN.md\n' > "$repo/docs/context/.close-required"
  sbx_git "$repo" init
  sbx_git "$repo" config user.email "you@example.com"
  sbx_git "$repo" config user.name "Operator One"
  sbx_git "$repo" add -A
  sbx_git "$repo" commit -m baseline
  local base; base="$("$REAL_GIT" -C "$repo" rev-parse HEAD 2>/dev/null)"

  _cc_stamp() {  # $1 sid — pin THIS session's start to the baseline commit
    local d; d="$(sess_dir "$1")"; mkdir -p "$d" 2>/dev/null
    printf '%s %s %s sid=%s\n' "$base" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$repo" "$1" > "$d/.gov-session-start"
  }

  # 1. Code changed, PLAN.md untouched -> the close is BLOCKED.
  printf 'module.exports = 1;\n' > "$repo/admin/lib/feature.js"
  sbx_git "$repo" add -A; sbx_git "$repo" commit -m "code, no record"
  _cc_stamp sid-cc-1
  run_hook "$repo" "sid-cc-1" "$(pl_plain "$repo" sid-cc-1 Stop)"
  expect_rc 2 "code changed and PLAN.md never written: stop BLOCKED"
  # NOT expect_has "close-completeness": that string also appears in the closing QUESTION this
  # hook prints on every run, so the assertion passed while the hook was allowing the close - a
  # check matching the description of the thing instead of the thing (#351). Match the block text.
  expect_has "GOVERNANCE-ENFORCEMENT" "block: emits the enforcement banner, not merely the reminder"
  expect_has "Plans/PLAN.md" "block: names the canonical file that is missing"

  # 2. A TOUCH must not clear it. Rewriting a line in place is what the other Stop hook does
  #    automatically, so if that counted, the gate would be satisfied by a machine every time.
  sed -i 's/^# PLAN$/# PLAN (version line rewritten in place)/' "$repo/Plans/PLAN.md" 2>/dev/null
  sbx_git "$repo" add -A; sbx_git "$repo" commit -m "touch only"
  _cc_stamp sid-cc-2
  run_hook "$repo" "sid-cc-2" "$(pl_plain "$repo" sid-cc-2 Stop)"
  expect_rc 2 "an in-place rewrite of PLAN.md does NOT satisfy the gate"

  # 3. A real entry GROWS the file -> allowed.
  printf '\n| 2026-01-02 | a real milestone entry for this session |\n' >> "$repo/Plans/PLAN.md"
  sbx_git "$repo" add -A; sbx_git "$repo" commit -m "record the work"
  _cc_stamp sid-cc-3
  run_hook "$repo" "sid-cc-3" "$(pl_plain "$repo" sid-cc-3 Stop)"
  expect_rc 0 "PLAN.md grown by a real entry: stop allowed"
  expect_not "BLOCKED" "allow: no block text once the record exists"

  # 4. The integrity checks warn WITHOUT blocking, and run even on the allow path - they sit above
  #    the early exits precisely because a governance session changes only documentation and would
  #    otherwise never reach them.
  mkdir -p "$repo/Plans" 2>/dev/null
  printf '# NEXT-SESSION KICKOFF\nPaste this as the first message.\n' > "$repo/Plans/NEXT-SESSION-KICKOFF.md"
  _cc_stamp sid-cc-4
  run_hook "$repo" "sid-cc-4" "$(pl_plain "$repo" sid-cc-4 Stop)"
  expect_rc 0 "a stray next-session prompt WARNS, it does not block"
  expect_has "INTEGRITY WARNINGS" "the warning verdict word is never the word PASS"
  expect_has "NEXT-SESSION-KICKOFF.md" "and it names the stray file"
  rm -f "$repo/Plans/NEXT-SESSION-KICKOFF.md"
}

# ── Settings parsing ─────────────────────────────────────────────────────────────────────────
# Priority: jq -> node -> python3 -> awk. NEVER a hard-coded hook list; a hard-coded list is the
# same existence-test disease this script exists to replace (a hook deleted from settings.json
# would still be "tested", and a hook added would never be).
pick_parser() {
  if   command -v jq      >/dev/null 2>&1; then echo jq
  elif command -v node    >/dev/null 2>&1; then echo node
  elif command -v python3 >/dev/null 2>&1; then echo python3
  else echo awk; fi
}

parse_hooks() {
  # PARSER is resolved by pick_parser() in the caller: this function runs inside $( ), so an
  # assignment here would be discarded with the subshell and the report would always say "none".
  if command -v jq >/dev/null 2>&1; then
    jq -r '.hooks | to_entries[] as $e | $e.value[] | .hooks[]? | "\($e.key)\t\(.command)"' "$SETTINGS" 2>/dev/null
    return
  fi
  if command -v node >/dev/null 2>&1; then

    node -e '
      const fs=require("fs");
      const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      for (const [ev,groups] of Object.entries(s.hooks||{}))
        for (const g of (groups||[]))
          for (const h of (g.hooks||[])) if (h && h.command) console.log(ev+"\t"+h.command);
    ' "$SETTINGS" 2>/dev/null
    return
  fi
  if command -v python3 >/dev/null 2>&1; then

    python3 -c '
import json,sys
s=json.load(open(sys.argv[1],encoding="utf-8"))
for ev,groups in (s.get("hooks") or {}).items():
    for g in groups or []:
        for h in g.get("hooks") or []:
            if h.get("command"): print(ev+"\t"+h["command"])
' "$SETTINGS" 2>/dev/null
    return
  fi
  # awk fallback (documented): settings.json is pretty-printed one key per line. Track the most
  # recent top-level event key (a key at 2-space indent directly under "hooks") and pair it with
  # every "command" string that follows. Correct for the pretty-printed layout Claude Code
  # writes; it is a fallback, so it is reported as such in the header.

  awk '
    /"hooks"[[:space:]]*:/ { inhooks=1 }
    inhooks && /^  "[A-Za-z]+"[[:space:]]*:/ { ev=$0; sub(/^  "/,"",ev); sub(/".*/,"",ev) }
    /"command"[[:space:]]*:/ {
      line=$0; sub(/.*"command"[[:space:]]*:[[:space:]]*"/,"",line); sub(/",?[[:space:]]*$/,"",line)
      if (ev != "" && line != "") print ev "\t" line
    }
  ' "$SETTINGS"
}

expand_cmd() {   # ~/.claude -> $CHOME, other ~ -> $HOME; strip trailing args; echo "" when not a file
  local c="$1"
  # `<interpreter> <file> ...` (e.g. `python3 ~/.claude/hooks/x.py`, OPEN-PROBLEMS #33): the
  # file is the hook. Without this the first word `python3` is not a file, the hook is run as an
  # INLINE command in the sandbox HOME, where its file does not exist, and it fails rc=2 - which
  # kept this machine's verdict RED for a user hook the framework does not own.
  case "$c" in
    python3\ *|python\ *|node\ *|bash\ *|sh\ *|pwsh\ *|powershell\ *) c="${c#* }" ;;
  esac
  # Round 3 (2026-10-02): `~/.claude/...` is the tree under test - $CHOME, which GOV_SELFTEST_HOME
  # moves. Resolving it with $HOME ran (and mutated) the REAL ~/.claude hooks in that mode, outside
  # HOOKS_ROOT. Default mode is unchanged: CHOME is $HOME/.claude there.
  case "$c" in
    "~/.claude/"*) c="${CHOME:-$HOME/.claude}/${c#\~/.claude/}" ;;
    "~/"*)         c="$HOME/${c#\~/}" ;;
  esac
  local first="${c%% *}"
  [ -f "$first" ] && printf '%s' "$first" || printf ''
}

_winform() {  # /c/foo/bar -> C:\foo\bar ; anything else passes through with / -> \ on drive paths
  printf '%s' "$1" | sed -e 's|^/\([A-Za-z]\)/|\U\1:/|' | tr '/' '\\'
}

# Run canonical-cwd-check.sh's OWN parser over a manifest, by lifting its helper definitions out
# of the file and evaluating them in a SUBSHELL. Deliberately not a reimplementation: the whole
# point is to compare against the real thing, so that a future fix applied to only one of the two
# copies is caught instead of silently believed. Sourcing the hook itself is not an option — it
# executes its checks at load and writes to stdout. Prints nothing if the helpers are absent
# (an older hook), which the caller treats as "no comparison possible", never as agreement.
_hook_canon_extract() {
  local manifest="$1" hook="$HOOKS_ROOT/governance/canonical-cwd-check.sh" defs
  # HOOKS_ROOT is ~/.claude/hooks (NOT .../governance) — getting this wrong makes the function
  # return empty and the drift check then reports a disagreement that does not exist. Fail LOUD
  # on a missing hook rather than returning "" and being read as "<none>".
  [ -f "$manifest" ] || return 0
  if [ ! -f "$hook" ]; then printf '<hook-not-found:%s>' "$hook"; return 0; fi
  defs="$(awk '/^_(clean_path|canon_line|canon_path|norm)\(\)/{f=1} f{print} f&&/^}/{f=0}' "$hook" 2>/dev/null)"
  case "$defs" in *_canon_line*) ;; *) return 0 ;; esac
  ( eval "$defs" 2>/dev/null && _canon_path "$(_canon_line "$manifest")" 2>/dev/null ) | head -1
}

# ── PART A + C ───────────────────────────────────────────────────────────────────────────────
mutate_and_check() {   # $1 hook path (real), $2 case fn, $3 basename
  local real="$1" fn="$2" base="$3"
  local mutant_dir="$SBX_HOOKS" rel
  rel="${real#$HOOKS_ROOT/}"
  local mutant="$mutant_dir/$rel"
  local survivors=0
  # Round 3 (2026-10-02): a mutant that was never written is an ERROR, never a kill. When the hook
  # path is outside HOOKS_ROOT (the strip above removes nothing) or the write fails, the case runs
  # against a file that does not exist, every assertion fails, and that used to read as "killed".
  _mutant_written() {  # _mutant_written <operator>: 0 when $mutant exists, is non-empty, and differs from $real
    if [ "$rel" = "$real" ] || [ ! -s "$mutant" ] || cmp -s "$real" "$mutant"; then
      _bad "MUTATION[$base/$1] NOT RUN (ERROR: mutant not written)" "no mutant at $mutant (hook $real; HOOKS_ROOT $HOOKS_ROOT) - a case run against a missing file fails every assertion and would have been counted as a kill"
      return 1
    fi
    return 0
  }

  # M1 — NOOP: the hook does nothing at all. Any assertion set a dead hook still satisfies is
  # vacuous, so this is the coverage test, not just a mutation test.
  { printf '%s\n' "$(head -1 "$real")"; printf 'exit 0  # selftest mutant: NOOP\n'; tail -n +2 "$real"; } > "$mutant" 2>/dev/null
  if ! _mutant_written NOOP; then :
  else
  MUT=1; CASE_FAILS=0; CUR_SCRIPT="$mutant"; "$fn" >/dev/null 2>&1; MUT=0
  if [ "$CASE_FAILS" -eq 0 ]; then
    survivors=$((survivors+1))
    _bad "MUTATION[$base/NOOP] survived" "a hook that does NOTHING passes every assertion for it — the assertions are vacuous"
  else
    _ok "MUTATION[$base/NOOP] killed by $CASE_FAILS assertion(s)"
  fi
  fi

  # M2 — NOBLOCK: every `exit 2` becomes `exit 0`. Only meaningful for hooks that block.
  # The trailing-comment form matters: check-full-finish.sh writes `exit 2  # Block stop`, and a
  # `$`-anchored pattern left that mutant byte-identical to the original — which then "survived"
  # and accused a perfectly good assertion set of being vacuous. A mutation operator that fails
  # to mutate is a false alarm, not a finding.
  if grep -qE '^[[:space:]]*exit 2([[:space:]]|#|$)' "$real"; then
    sed -E 's/^([[:space:]]*)exit 2([[:space:]]*(#.*)?)$/\1exit 0\2/' "$real" > "$mutant" 2>/dev/null
    if ! _mutant_written NOBLOCK; then :
    else
    MUT=1; CASE_FAILS=0; CUR_SCRIPT="$mutant"; "$fn" >/dev/null 2>&1; MUT=0
    if [ "$CASE_FAILS" -eq 0 ]; then
      survivors=$((survivors+1))
      _bad "MUTATION[$base/NOBLOCK] survived" "neutralising every 'exit 2' changed nothing — the block is not actually asserted"
    else
      _ok "MUTATION[$base/NOBLOCK] killed by $CASE_FAILS assertion(s)"
    fi
    fi
  fi

  # Restore the copy only where it belongs: never write outside the sandbox mutation tree.
  [ "$rel" = "$real" ] || cp -f "$real" "$mutant" 2>/dev/null
  return $survivors
}

part_a() {
  printf '\n=== PART A — execute every registered hook (settings.json: %s) ===\n' "$SETTINGS"
  [ -f "$SETTINGS" ] || { _bad "settings.json readable" "not found at $SETTINGS"; return; }

  PARSER="$(pick_parser)"
  HOOK_LINES="$(parse_hooks)"
  printf 'hook list parsed with: %s\n' "$PARSER"
  if [ -z "$HOOK_LINES" ]; then
    _bad "settings.json hook list" "parsed 0 hooks from $SETTINGS — every hook is therefore untested"
    return
  fi

  # Mutation tree: the whole hooks dir, because a hook sources _common.sh from its own dir.
  if [ "$DO_MUTATION" = 1 ]; then
    mkdir -p "$SBX_HOOKS" 2>/dev/null
    cp -R "$HOOKS_ROOT/." "$SBX_HOOKS/" 2>/dev/null
  fi

  local n=0
  while IFS="$(printf '\t')" read -r ev cmd; do
    [ -n "$cmd" ] || continue
    n=$((n+1))
    local path base fn
    path="$(expand_cmd "$cmd")"
    if [ -n "$ONLY" ]; then
      case ",$ONLY," in *",$(basename "${path:-inline}"),"*) ONLY_HIT=$((${ONLY_HIT:-0}+1)) ;; *) continue ;; esac
    fi
    if [ -z "$path" ]; then
      # Inline command (e.g. the Stop-event `echo ...` reminder). Still EXECUTED, not assumed.
      printf '\n  [%s] inline command\n' "$ev"
      CUR_SCRIPT=""; CUR_LABEL="inline:$ev"
      local o rc
      o=$(env HOME="$SBX_HOME" PATH="$SBX_BIN:$PATH" bash -c "$cmd" 2>&1); rc=$?
      RC=$rc; OUT="$o"; BOTH="$o"
      CUR_SCRIPT="inline:$(printf '%s' "$cmd" | head -c 60)"
      expect_rc 0 "inline command runs cleanly"
      if [ -n "$(printf '%s' "$o" | tr -d '[:space:]')" ]; then _ok "inline command emits its reminder"
      else _bad "inline command emits its reminder" "produced no output — a silent reminder reminds nobody"; fi
      continue
    fi
    base="$(basename "$path")"
    fn="$(case_fn_for "$base")"
    printf '\n  [%s] %s\n' "$ev" "$path"
    if [ -z "$fn" ] || ! command -v "$fn" >/dev/null 2>&1; then
      # A hook the USER registered that is not the framework's (2026-09-25). Coverage is a promise
      # about THIS framework's hooks — the same ownership line settings-merge.js draws (a command
      # under hooks/governance/, or check-full-finish.sh). A machine-local hook from another project
      # can have no case here and was keeping this machine's verdict RED forever. It is still named
      # on every run, so it cannot go quiet; it is just not counted as a framework gap.
      case "$path" in
        */hooks/governance/*|*/hooks/check-full-finish.sh) : ;;
        *)
          USERHOOK_N=$((${USERHOOK_N:-0}+1))
          USERHOOK_LOG="${USERHOOK_LOG:-}
  $path"
          printf '    [USER HOOK] not part of this framework — its owner tests it, this suite does not\n'
          continue ;;
      esac
      UNCOV=$((UNCOV+1))
      UNCOV_LOG="$UNCOV_LOG
  $path — no must-block/must-allow case is defined for it; it is EXECUTED nowhere and its behaviour is unverified"
      printf '    [UNCOVERED] no case defined — behaviour unverified\n'
      continue
    fi
    CUR_ORIG="$path"; CUR_SCRIPT="$path"
    "$fn"
    if [ "$DO_MUTATION" = 1 ]; then
      mutate_and_check "$path" "$fn" "$base"
      CUR_SCRIPT="$path"
    fi
  done <<EOF
$HOOK_LINES
EOF
  printf '\n  hooks discovered in settings.json: %s\n' "$n"
  if [ -n "$ONLY" ]; then
    printf '  SCOPED run (--only=%s): registration scan, Part B and the live invariant are skipped\n' "$ONLY"
    # A scope that matched nothing ran zero checks; that is a failure, never a pass (a typo, or a
    # TOOL such as close-push.sh - tools are not registered hooks; run their own --selftest).
    CUR_SCRIPT="--only=$ONLY"
    if [ "${ONLY_HIT:-0}" -eq 0 ]; then
      _bad "--only matched a registered hook" "no registered hook is named '$ONLY' - zero checks ran"
    fi
    return
  fi

  # ── Every script on disk is registered, or DECLARED not-a-hook with a reason ────────────────
  #
  # WHY THIS EXISTS. Part A takes its hook list from settings.json, which is right — a hard-coded
  # list is the same existence-test disease this file replaces. But it has a blind spot the exact
  # size of the framework's worst failure: a script that is registered NOWHERE is not reported
  # UNCOVERED, it is INVISIBLE. Three files were found in that state in one session
  # (close-completeness.sh, render-gate.sh, render-rules-read.sh); close-completeness.sh was then
  # wired, and the very next audit found it had been unable to block for 16 days. "uncovered=0"
  # means "everything REGISTERED is covered", never "everything that EXISTS runs".
  #
  # So the rule is inverted: presence on disk must be JUSTIFIED. A script is acceptable when it is
  # registered in settings.json, or named below with a reason. Anything else is a failure — the
  # default for an unknown file is RED, because the whole class was born from files nobody decided
  # about.
  #
  # `invoked-by:` claims are VERIFIED, not believed: the named caller must exist and must actually
  # mention the script. A declaration nobody checks is the same unenforced description this file
  # keeps finding elsewhere.
  script_decl() {
    case "$1" in
      _common.sh)                  echo "library: sourced by every hook" ;;
      check-no-pii.sh)             echo "library: the PII scanner, invoked by the gates and by hand" ;;
      governance-selftest.sh)      echo "library: this suite" ;;
      commit-task-success.sh)      echo "tool: run by the model to mint a success token" ;;
      governance-helpers-check.sh) echo "tool: lint, run by hand and by the test suites" ;;
      close-report.sh)             echo "invoked-by:settings.json" ;;
      sync-governance.sh)          echo "invoked-by:end-session.sh" ;;
      file-collision-ack.sh)       echo "invoked-by:file-collision-guard.sh" ;;
      enumerate-before-claiming.sh) echo "TOOL: operator-invoked, not a hook — enumerates the machine's scheduled tasks / startup / run keys and flags entries whose target is missing; covered by case_enumerate_before_claiming" ;;
      enumerate-tasks.ps1)         echo "TOOL: the PowerShell half of enumerate-before-claiming.sh — a separate file on purpose, because escapes do not survive being embedded (gotcha #359)" ;;
      pr-watch.sh)                 echo "TOOL: the PR watcher the session arms through the Monitor tool (pr-follow-through skill) - not a hook; pr-watch-guard.sh hands the session its exact command, and 'pr-watch.sh --selftest' runs its offline must-fire/must-not-fire controls (v1.4.0)" ;;
      pii-gate-parse.py)           echo "invoked-by:pii-gate-pretooluse.sh" ;;
      wa-send.js)                  echo "invoked-by:_common.sh" ;;
      gov-update.sh)               echo "invoked-by:pre-session.sh" ;;
      close-push.sh)               echo "TOOL: the one place a session close pushes the current repo, called by the close skills (live-state-orchestrator, full-finish, plan-and-execute) - not a hook; case_close_push runs its --selftest against local bare origins (2026-09-29)" ;;
      gov-release.sh)              echo "TOOL: the maintainer's release tool, source machine only (2.0.0) - its preconditions and the manifest it signs are exercised by case_gov_update" ;;
      release-manifest.sh)         echo "library: the release-manifest builder/parser, sourced by gov-update.sh, gov-release.sh and install.sh (2.0.0)" ;;
      consent-lib.sh)              echo "library: consent records — the one parser/predicate/writer, sourced by _common.sh, install.sh, gov-update.sh, close-push.sh (2026-09-30); case_consent_lib runs tests/test-consent-lib.sh" ;;
      settings-merge.js)           echo "invoked-by:gov-update.sh" ;;
      *.test.sh)                   echo "test: a suite, not a hook" ;;
      *) echo "" ;;
    esac
  }

  local n_disk=0 n_reg=0 n_decl=0 n_orph=0 n_undecl=0 orph_list="" undecl_list="" bad_claim=""
  for _s in "$GOV_DIR"/*.sh "$GOV_DIR"/*.py "$GOV_DIR"/*.js "$GOV_DIR"/*.ps1; do
    [ -f "$_s" ] || continue
    local _b; _b="$(basename "$_s")"
    case "$_b" in *.bak|*.bak-*|*.tmp|*.orig) continue ;; esac
    n_disk=$((n_disk+1))
    if printf '%s\n' "$HOOK_LINES" | grep -qF "$_b"; then n_reg=$((n_reg+1)); continue; fi
    local _d; _d="$(script_decl "$_b")"
    case "$_d" in
      "")        n_undecl=$((n_undecl+1)); undecl_list="$undecl_list $_b" ;;
      ORPHAN:*)  n_orph=$((n_orph+1));  orph_list="$orph_list $_b" ;;
      invoked-by:*)
        n_decl=$((n_decl+1))
        local _caller="${_d#invoked-by:}"
        case "$_caller" in
          settings.json) : ;;   # a hook whose registration part A already walked
          *) if [ ! -f "$GOV_DIR/$_caller" ] || ! grep -qF "$_b" "$GOV_DIR/$_caller" 2>/dev/null; then
               bad_claim="$bad_claim $_b(claims $_caller)"
             fi ;;
        esac ;;
      *)         n_decl=$((n_decl+1)) ;;
    esac
  done

  # THE SIZES ARE PART OF THE VERDICT. "0 undeclared" is producible by a loop that examined
  # nothing; "41 scripts on disk, 21 registered, 0 undeclared" is not (gotcha #353).
  printf '\n  scripts on disk: %s · registered: %s · declared not-a-hook: %s · ORPHANED: %s · undeclared: %s\n' \
    "$n_disk" "$n_reg" "$n_decl" "$n_orph" "$n_undecl"
  GF_HOOKS_DISK=$n_disk; GF_HOOKS_REG=$n_reg; GF_HOOKS_ORPH=$n_orph; GF_HOOKS_UNDECL=$n_undecl

  CUR_SCRIPT="$GOV_DIR (registration coverage)"
  if [ "$n_disk" -eq 0 ]; then
    _bad "every script on disk is registered or declared" "found NO scripts at all in $GOV_DIR — this check examined nothing, which is not agreement"
  elif [ "$n_undecl" -gt 0 ]; then
    _bad "every script on disk is registered or declared" \
         "$n_undecl script(s) are registered in no event and declared nowhere:$undecl_list — a file nobody decided about is how a hook stays invisible for weeks"
  else
    _ok "all $n_disk script(s) are registered ($n_reg) or declared with a reason ($((n_decl + n_orph)))"
  fi
  if [ -n "$bad_claim" ]; then
    CUR_SCRIPT="$GOV_DIR (declaration claims)"
    _bad "every 'invoked-by' declaration names a caller that really calls it" \
         "unverified claim(s):$bad_claim — a declaration nobody checks is an unenforced description"
  fi
  if [ "$n_orph" -gt 0 ]; then
    printf '  [ORPHANED, declared and still open] %s\n' "$orph_list"
    printf '      Registered in no event and called by nothing. Named here on every run so the\n'
    printf '      decision (register or delete) cannot go quiet again. Task B11.\n'
  fi

  # ── Every skill in the bundle is actually DISTRIBUTED, and every distributed skill exists ───
  #
  # WHY THIS EXISTS. The loop above proves a hook nobody decided about cannot hide. Skills had no
  # such check, and the gap has now bitten twice. Five skills sat in `bundle/skills/` that
  # `install.sh` never installed (2026-09-07) — they were also carrying private values into a
  # public repo, which is how they were finally noticed, not by anyone auditing distribution. Then
  # `pr-follow-through` shipped at v1.4.0 in neither `CORE_SKILLS` nor `EXTENDED_SKILLS`
  # (2026-09-09), so the installer copied 14 of 15 and skipped it in silence.
  #
  # Both times the same thing was true and misleading: the file WAS in the bundle. **A bundle is
  # not a manifest.** Presence proves a copy happened; whether anyone receives it lives in a
  # different file and needs its own measurement. And it is invisible on the machine that built
  # it, because there the skill is already installed.
  #
  # Checked in BOTH directions, because each failure is silent in its own way:
  #   bundle -> lists : a skill nobody receives (the 2026-09-09 bug)
  #   lists -> bundle : a skill the installer will look for and not find
  _sk_inst="$HOME/.claude/governance-installer/install.sh"
  _sk_dir="$HOME/.claude/governance-installer/bundle/skills"
  CUR_SCRIPT="bundle/skills (distribution coverage)"
  if [ ! -f "$_sk_inst" ] || [ ! -d "$_sk_dir" ]; then
    _bad "every bundled skill is distributed" \
         "installer not found (install.sh=$_sk_inst, skills=$_sk_dir) — this check examined nothing, which is not agreement"
  else
    _sk_core="$(sed -n 's/^CORE_SKILLS="\(.*\)"$/\1/p' "$_sk_inst" 2>/dev/null)"
    _sk_ext="$(sed -n 's/^EXTENDED_SKILLS="\(.*\)"$/\1/p' "$_sk_inst" 2>/dev/null)"
    # Since 1.7.0 install.sh DERIVES the lists from bundle/DISTRIBUTED
    # (CORE_SKILLS="$(gov_distributed_section core)"), so the literal read above yields the
    # unexpanded `$(...)` text and every bundled skill looked undistributed (OPEN-PROBLEMS #13).
    # Read the lists from where install.sh reads them - same literal-header awk as install.sh's
    # gov_distributed_section, including its reason for NOT using a regex match on `[core]`.
    case "$_sk_core $_sk_ext" in
      *'$('*)
        _sk_dist="$(dirname "$_sk_inst")/bundle/DISTRIBUTED"
        _sk_section() {
          awk -v want="[$1]" '
            /^[[:space:]]*\[/ { hdr=$0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", hdr); inside=(hdr==want); next }
            inside { sub(/#.*$/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (length($0)) print }
          ' "$_sk_dist" 2>/dev/null | tr '\n' ' '
        }
        _sk_core="$(_sk_section core)"; _sk_ext="$(_sk_section extended)"
        ;;
    esac
    _sk_never=" ${GOV_NEVER_DISTRIBUTE_SKILLS:-wa-cc-bridge wa-cc-poll whatsapp whatsapp-checkpoints end-session} "
    _sk_listed=" $_sk_core $_sk_ext "
    _sk_n_bundle=0; _sk_n_listed=0; _sk_unshipped=""; _sk_missing=""; _sk_leaked=""
    for _sk_p in "$_sk_dir"/*/; do
      [ -d "$_sk_p" ] || continue
      _sk_b="$(basename "$_sk_p")"
      _sk_n_bundle=$((_sk_n_bundle + 1))
      case "$_sk_listed" in
        *" $_sk_b "*) ;;
        *)
          # Distinguish the two ways a bundled skill can be in no list: forgotten, or one the
          # private->public crossing was supposed to refuse entry to. Different bug, different fix.
          case "$_sk_never" in
            *" $_sk_b "*) _sk_leaked="$_sk_leaked $_sk_b" ;;
            *)            _sk_unshipped="$_sk_unshipped $_sk_b" ;;
          esac
          ;;
      esac
    done
    for _sk_b in $_sk_core $_sk_ext; do
      _sk_n_listed=$((_sk_n_listed + 1))
      [ -d "$_sk_dir/$_sk_b" ] || _sk_missing="$_sk_missing $_sk_b"
    done
    # Sizes are part of the verdict: "0 unshipped" is producible by a loop that examined nothing.
    printf '\n  skills in bundle: %s · listed by install.sh: %s (core+extended) · unshipped: %s · listed-but-absent: %s\n' \
      "$_sk_n_bundle" "$_sk_n_listed" "$(printf '%s' "$_sk_unshipped" | wc -w | tr -d ' ')" \
      "$(printf '%s' "$_sk_missing" | wc -w | tr -d ' ')"
    GF_SKILLS_BUNDLE=$_sk_n_bundle; GF_SKILLS_LISTED=$_sk_n_listed
    if [ "$_sk_n_bundle" -eq 0 ] || [ "$_sk_n_listed" -eq 0 ]; then
      _bad "every bundled skill is distributed" \
           "bundle=$_sk_n_bundle listed=$_sk_n_listed — one of them is empty, so this check examined nothing"
    elif [ -n "$_sk_unshipped" ]; then
      _bad "every bundled skill is distributed" \
           "in bundle/skills but in NEITHER CORE_SKILLS nor EXTENDED_SKILLS:$_sk_unshipped — install.sh copies the rest and skips these in silence, and you cannot see it on the machine that built them"
    else
      _ok "all $_sk_n_bundle bundled skill(s) are in CORE_SKILLS or EXTENDED_SKILLS"
    fi
    if [ -n "$_sk_missing" ]; then
      _bad "every listed skill exists in the bundle" \
           "install.sh will look for and not find:$_sk_missing — the reverse gap, equally silent"
    else
      _ok "all $_sk_n_listed listed skill(s) exist in bundle/skills"
    fi
    if [ -n "$_sk_leaked" ]; then
      _bad "no never-distributed skill reached the bundle" \
           "the private->public crossing should have refused these:$_sk_leaked — they carry machine- and client-specific values, and being in no install list is NOT the control that keeps them out"
    fi
  fi

  # ── Operator tools: not hooks, so the registration loop above never reaches them ────────────
  # A tool that no case executes is exactly the state that made no-local-compute.sh ship an inert
  # exemption for a day (v1.2.1). Call it explicitly.
  if command -v case_enumerate_before_claiming >/dev/null 2>&1; then
    printf '
  [tool] %s
' "$GOV_DIR/enumerate-before-claiming.sh"
    CUR_ORIG="$GOV_DIR/enumerate-before-claiming.sh"
    case_enumerate_before_claiming
  fi
  if command -v case_skill_prose >/dev/null 2>&1; then
    printf '
  [prose] HITL removal predicates
'
    case_skill_prose
  fi
  if command -v case_close_push >/dev/null 2>&1; then
    printf '
  [tool] %s
' "$GOV_DIR/close-push.sh"
    CUR_ORIG="$GOV_DIR/close-push.sh"
    case_close_push
  fi
  if command -v case_consent_lib >/dev/null 2>&1; then
    printf '
  [library] %s
' "$GOV_DIR/consent-lib.sh"
    CUR_ORIG="$GOV_DIR/consent-lib.sh"
    case_consent_lib
  fi
  if command -v case_gov_update >/dev/null 2>&1; then
    printf '
  [tool] %s
' "$GOV_DIR/gov-update.sh"
    CUR_ORIG="$GOV_DIR/gov-update.sh"
    case_gov_update
  fi
  if command -v case_no_auto_update >/dev/null 2>&1; then
    printf '
  [invariant] no automatic update in 2.0.0 (%s)
' "$GOV_DIR/gov-update.sh"
    CUR_ORIG="$GOV_DIR/gov-update.sh"
    case_no_auto_update
  fi
  if command -v case_terms_text >/dev/null 2>&1; then
    printf '
  [text] NOTICE-AUTO-UPDATE.md + README.md (%s)
' "$GOV_DIR/tests/test-terms-text.sh"
    CUR_ORIG="$GOV_DIR/tests/test-terms-text.sh"
    case_terms_text
  fi
  if command -v case_release_invariants >/dev/null 2>&1; then
    printf '
  [invariant] T2 one parser, T6 update subset (%s)
' "$GOV_DIR/tests/test-release-invariants.sh"
    CUR_ORIG="$GOV_DIR/tests/test-release-invariants.sh"
    case_release_invariants
  fi

  # ── COPY PARITY ─────────────────────────────────────────────────────────────────────────────
  # THE check that catches what no rule can. check-no-pii.sh matches SHAPES, so an identity with
  # no shape - a group name, a client name, a codename - scores 0 and every scan prints PASS. On
  # 2026-09-01 the owner's real WhatsApp group name survived four sanitization rounds and five
  # certifications for exactly that reason, and was found ONLY by diffing the copies against each
  # other: one said the placeholder, another said the real name. Gotcha #350 recommended asserting
  # it here; it was not done, and on 2026-09-07 the same string was still sitting in the public
  # repo's initial commit. So it is asserted now: divergence between the copies is a RED result,
  # not something a human has to remember to run.
  #
  # Direction matters. Sync is live -> installer -> repo, so a dirty live file is two hops from a
  # public commit; the copies must agree BEFORE anything is published, whichever way they drifted.
  CUR_SCRIPT="(four-copy parity)"
  _par_live="$HOME/.claude/hooks/governance"
  _par_bundle="$HOME/.claude/governance-installer/bundle/hooks/governance"
  _par_missing=""
  [ -d "$_par_live" ]   || _par_missing="$_par_missing live"
  [ -d "$_par_bundle" ] || _par_missing="$_par_missing installer-bundle"
  if [ -n "$_par_missing" ]; then
    # A missing root means the comparison examined nothing. That is not agreement.
    _bad "the governance copies agree" "cannot compare - absent root(s):$_par_missing. A parity check with nothing to compare is not a pass."
  else
    _par_diff=""
    _par_n=0
    for _pf in "$_par_live"/*.sh; do
      [ -f "$_pf" ] || continue
      _pb=$(basename "$_pf")
      # Only files the bundle actually carries: a live-only file (a .bak, a local experiment) is
      # not a divergence, it is simply not distributed.
      [ -f "$_par_bundle/$_pb" ] || continue
      _par_n=$((_par_n + 1))
      diff -q "$_pf" "$_par_bundle/$_pb" >/dev/null 2>&1 || _par_diff="$_par_diff $_pb"
    done
    if [ "$_par_n" -eq 0 ]; then
      _bad "the governance copies agree" "compared 0 shared file(s) - the check ran but examined nothing"
    elif [ -n "$_par_diff" ]; then
      _bad "the governance copies agree" "live and installer-bundle DIFFER on:$_par_diff - sync is live -> installer -> repo, so this is either an unpublished fix or an unsanitized value one edit from a public commit. Diff them and decide which side is right (gotcha #350)."
    else
      _ok "all $_par_n shared hook(s) are byte-identical across live and the installer bundle"
    fi
  fi

  if [ -s "$GIT_VIOL" ]; then
    CUR_SCRIPT="(git shim)"
    _bad "no hook attempted a denied git operation" "$(_snip "$(cat "$GIT_VIOL")")"
  else
    _ok "no hook attempted a network or out-of-sandbox git operation"
  fi
}

# ── PART B — recompute every countable claim ─────────────────────────────────────────────────
BLOCK="$SBX/facts.block"
GEN_FACTS="$PROJECT/docs/context/GENERATED-FACTS.md"

gf() { printf '%s\n' "$1" >> "$BLOCK"; }

claim_check() {  # $1 label, $2 measured, $3 claimed (may be empty), $4 where
  CUR_SCRIPT="$4"
  if [ -z "$3" ]; then
    _bad "$1" "NO-CLAIM: nothing extracted from $4 - an empty input is not a pass. Either the document states this claim and the extractor is broken, or the claim was removed and this check must be deleted. Measured value: $2"
  elif [ "$2" = "$3" ]; then
    _ok "$1: $4 claims $3, measured $2"
  else
    _bad "$1" "$4 claims $3, measured $2 — the document is wrong"
  fi
}

part_b() {
  printf '\n=== PART B — recompute every countable claim (project: %s) ===\n' "$PROJECT"
  : > "$BLOCK"
  if [ ! -d "$PROJECT" ]; then
    CUR_SCRIPT="$PROJECT"; _bad "project root exists" "not a directory: $PROJECT"; return
  fi

  gf "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gf "hooks_scripts_on_disk: ${GF_HOOKS_DISK:-<not measured>}"
  gf "hooks_registered_in_settings: ${GF_HOOKS_REG:-<not measured>}"
  gf "hooks_orphaned_declared: ${GF_HOOKS_ORPH:-<not measured>}"
  gf "skills_in_bundle: ${GF_SKILLS_BUNDLE:-<not measured>}"
  gf "skills_listed_by_installer: ${GF_SKILLS_LISTED:-<not measured>}"
  gf "hooks_undeclared: ${GF_HOOKS_UNDECL:-<not measured>}"
  gf "generated_by: ~/.claude/hooks/governance/governance-selftest.sh"
  gf "project_root: $PROJECT"

  # canonical_working_copy — ALSO emitted in the strict colon syntax below, so the guard reads a
  # correct value from here regardless of how the manifest spells it.
  #
  # THIS EXTRACTION MUST STAY IN STEP WITH canonical-cwd-check.sh `_canon_line`/`_canon_path`
  # (2026-09-01). It was a stale DUPLICATE of that hook's OLD regex: colon-only, plus a
  # `cut -d: -f2-` that splits on the DRIVE colon and truncates "C:\dev\example-project" to
  # "\example-project". The hook was relaxed to accept a `-`/`*`/`**` bullet and `:` or `=`;
  # this copy was not, so the selftest reported the guard INERT after the guard had been fixed —
  # the tool's own duplicate of a fact outliving the fact. The hook is deliberately standalone
  # (it must work when the rest of the framework does not), so the duplication cannot simply be
  # deleted; instead the drift is now ASSERTED below, the way `protected-list-consistency.test.sh`
  # pins the protected-doc list. A duplicated fact you cannot delete, you must compare.
  local measured_canon declared_canon _canon_l _hook_canon
  measured_canon="$(_winform "$PROJECT")"
  _canon_l="$(grep -iE '^[[:space:]]*([-*+][[:space:]]+)?(\*\*)?[[:space:]]*canonical_working_copy[[:space:]]*(\*\*)?[[:space:]]*[:=]' \
                "$PROJECT/docs/context/CONTEXT-MANIFEST.md" 2>/dev/null | head -1)"
  declared_canon="$(printf '%s' "$_canon_l" | grep -oE '`[^`]+`' | head -1 | tr -d '`')"
  [ -z "$declared_canon" ] && declared_canon="$(printf '%s' "$_canon_l" | grep -oE '"[^"]+"' | head -1 | tr -d '"')"
  [ -z "$declared_canon" ] && declared_canon="$(printf '%s' "$_canon_l" | sed -E 's/^[^:=]*[:=][[:space:]]*//')"
  declared_canon="$(printf '%s' "$declared_canon" | sed -e 's/^[[:space:]`"*'"'"']*//' -e 's/[[:space:]`"*'"'"',.;:)]*$//')"

  # Drift assertion: run the HOOK's own extraction over the same file and require agreement.
  # If someone fixes one copy and not the other again, this goes red instead of lying.
  CUR_SCRIPT="canonical-cwd-check.sh vs governance-selftest.sh"
  _hook_canon="$(_hook_canon_extract "$PROJECT/docs/context/CONTEXT-MANIFEST.md")"
  if [ "$_hook_canon" = "$declared_canon" ]; then
    _ok "canonical_working_copy extraction agrees with canonical-cwd-check.sh ('${declared_canon:-<none>}')"
  else
    _bad "canonical_working_copy extraction drifted from canonical-cwd-check.sh" \
         "hook reads '${_hook_canon:-<none>}', selftest reads '${declared_canon:-<none>}' — the two copies of this parser disagree"
  fi
  gf "canonical_working_copy: $measured_canon"
  gf "canonical_working_copy_declared: ${declared_canon:-<none>}"
  CUR_SCRIPT="docs/context/CONTEXT-MANIFEST.md"
  if [ -z "$declared_canon" ]; then
    _bad "canonical_working_copy declared in the manifest" "no 'canonical_working_copy:' line found — canonical-cwd-check.sh Signal 2 is inert on this project"
  elif [ "$(printf '%s' "$declared_canon" | tr 'A-Z/' 'a-z\\' | tr -d ':')" = "$(printf '%s' "$measured_canon" | tr 'A-Z/' 'a-z\\' | tr -d ':')" ]; then
    _ok "canonical_working_copy matches the audited root ($declared_canon)"
  else
    _bad "canonical_working_copy matches the audited root" "manifest declares [$declared_canon], this run audited [$measured_canon]"
  fi

  # --- GOTCHAS.md entry count ---------------------------------------------------------------
  # THE REGEX. Entries come in two shapes in this file: a flat numbered list (`1. text`) for the
  # early entries and markdown headings (`### 245. text`) for the later ones. A previous sync
  # script counted only `^[0-9]\+\.` and therefore under-counted by exactly the number of heading
  # entries (102 of them here). The expression below covers both, and the contiguity assertion
  # underneath is what proves it is the right expression: extracted numbers must be 1..N with no
  # duplicates and no gaps.
  local G="$PROJECT/docs/context/GOTCHAS.md"
  local GOTCHA_RE='^(#{1,6}[[:space:]]*)?#?[0-9]+[.)]'
  gf "gotchas_entry_regex: $GOTCHA_RE"
  if [ -f "$G" ]; then
    local g_count g_declared g_nums g_uniq g_max
    g_count=$(grep -cE "$GOTCHA_RE" "$G" 2>/dev/null)
    g_declared=$(grep -iE '^total_entries:' "$G" 2>/dev/null | head -1 | tr -dc '0-9')
    g_nums="$SBX/gnums"
    grep -oE "$GOTCHA_RE" "$G" 2>/dev/null | grep -oE '[0-9]+' | sed 's/^0*//' | sort -n > "$g_nums"
    g_uniq=$(sort -nu "$g_nums" | wc -l | tr -d ' ')
    g_max=$(tail -1 "$g_nums" 2>/dev/null)
    gf "gotchas_entries_measured: $g_count"
    gf "gotchas_entries_declared: ${g_declared:-<none>}"
    gf "gotchas_highest_number: ${g_max:-0}"
    gf "gotchas_numbering_contiguous: $([ "$g_count" = "$g_uniq" ] && [ "$g_count" = "${g_max:-0}" ] && echo yes || echo no)"
    CUR_SCRIPT="docs/context/GOTCHAS.md"
    if [ "$g_count" = "$g_uniq" ] && [ "$g_count" = "${g_max:-0}" ]; then
      _ok "gotchas numbering is contiguous 1..$g_max (proves the counting regex is the right one)"
    else
      _bad "gotchas numbering is contiguous" "matched $g_count lines, $g_uniq distinct numbers, highest ${g_max:-0} — the counting regex or the file's numbering is wrong"
    fi
    claim_check "gotchas total_entries" "$g_count" "$g_declared" "docs/context/GOTCHAS.md frontmatter"
  else
    CUR_SCRIPT="docs/context/GOTCHAS.md"; _bad "GOTCHAS.md exists" "not found at $G"
  fi

  # --- line counts --------------------------------------------------------------------------
  local cm_lines op_lines
  cm_lines=$(wc -l < "$PROJECT/CLAUDE.md" 2>/dev/null | tr -d ' ')
  op_lines=$(wc -l < "$PROJECT/MDs/Open-Problems.md" 2>/dev/null | tr -d ' ')
  gf "claude_md_lines: ${cm_lines:-0}"
  gf "open_problems_lines: ${op_lines:-0}"
  # Every hand-written size claim about Open-Problems.md, in the manifest AND in the pointer.
  # Three bugs were fixed here on 2026-09-13, each of which produced a GREEN over a real drift:
  #  (1) the pointer was never in the input set, so it carried "~409 lines" against 3,162 for months;
  #  (2) the em dash was written as one optional character under a BYTE-oriented ERE, so the `?`
  #      quantified only the last byte of a 3-byte sequence and the pattern demanded bytes that
  #      cannot appear - the extraction returned empty and claim_check rendered empty as _ok;
  #  (3) `head -1` over a single file let a correct number in one place mask a wrong one in another.
  local _sz_scanned=0 _sz_found=0 _szf _szclaims _szc
  # Applicability (2026-09-25): Part B used to assume ONE project's layout. Pointed at a project
  # without MDs/Open-Problems.md, "no size claim found" is not drift, it is a question that does not
  # exist there — reported N/A, not FAIL. Where the file exists, an empty extraction stays a FAIL.
  if [ ! -f "$PROJECT/MDs/Open-Problems.md" ]; then
    CUR_SCRIPT="docs/context/CONTEXT-MANIFEST.md"
    _na "Open-Problems.md size claims" "this project has no MDs/Open-Problems.md"
  else
  for _szf in "$PROJECT/docs/context/CONTEXT-MANIFEST.md" "$PROJECT/docs/context/OPEN-PROBLEMS.md"; do
    [ -f "$_szf" ] || continue
    _sz_scanned=$((_sz_scanned+1))
    # A markdown table row puts the filename and its size in DIFFERENT cells, so a [^|] gap can
    # never cross the cell boundary — manifest line 72 was invisible to the first repair of this
    # check. Select the LINE, then extract every size claim on it; grep is already line-scoped.
    _szclaims=$(grep -E 'Open-Problems\.md' "$_szf" 2>/dev/null | grep -oE '[0-9][0-9,]* lines' | tr -d "," | grep -oE '[0-9]+')
    for _szc in $_szclaims; do
      _sz_found=$((_sz_found+1))
      claim_check "Open-Problems.md size claim $_sz_found" "${op_lines:-0}" "$_szc" "${_szf#$PROJECT/}"
    done
  done
  CUR_SCRIPT="docs/context/CONTEXT-MANIFEST.md"
  if [ "$_sz_found" -eq 0 ]; then
    _bad "Open-Problems.md size claims" "NO-CLAIM: scanned $_sz_scanned file(s) and extracted 0 size claims - an empty input set is never a pass"
  else
    _ok "Open-Problems.md size claims: scanned $_sz_scanned file(s), found $_sz_found claim(s), measured ${op_lines:-0} lines"
  fi
  fi

  # --- God Mode tool count + admin/lib inventory: only for a project that HAS admin/lib ---------
  if [ ! -d "$PROJECT/admin/lib" ]; then
    CUR_SCRIPT="admin/lib"
    _na "God Mode tool count / admin/lib module inventory / MDs/FILE-ROLES.md" "this project has no admin/lib"
  else
  # --- God Mode tool count ------------------------------------------------------------------
  local gm_measured=""
  if [ -f "$PROJECT/admin/lib/godmode-tools.js" ] && command -v node >/dev/null 2>&1; then
    gm_measured=$( cd "$PROJECT/admin" && node -e "console.log(require('./lib/godmode-tools.js').getToolNames().length)" 2>/dev/null | tail -1 | tr -dc '0-9')
  fi
  gf "godmode_tool_count: ${gm_measured:-<unmeasurable>}"
  CUR_SCRIPT="admin/lib/godmode-tools.js"
  if [ -z "$gm_measured" ]; then
    _bad "God Mode tool count is measurable" "could not execute getToolNames() in $PROJECT/admin (node missing or module failed to load)"
  else
    _ok "God Mode tool count measured by execution: $gm_measured"
    local c
    # CLAUDE.md writes this as: admin processes with **93 tools** (source of truth = getToolNames().length).
    # The old pattern required the literal "getToolNames().length` = N", which the document has never
    # written - it extracted nothing, and the empty result was rendered as a PASS over an unchecked number.
    c=$(grep -oE '\*\*[0-9]+ tools\*\*' "$PROJECT/CLAUDE.md" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    claim_check "God Mode tools (self-declaring claim)" "$gm_measured" "$c" "CLAUDE.md"
    c=$(grep -oE '[0-9]+ God Mode tools reference' "$PROJECT/CLAUDE.md" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    claim_check "God Mode tools (doc map)" "$gm_measured" "$c" "CLAUDE.md Documentation Map"
    # The manifest row for God-Mode-Capabilities.md deliberately states NO number: it reads
    # "(see file for current count)" and says in the same cell "Do NOT hard-code the tool count
    # here - it has gone stale twice (this row said 65, CLAUDE.md said 84)". That is the correct
    # pattern, so there is nothing here to contradict and this call site was DELETED on 2026-09-13.
    # It is not an oversight: once claim_check stopped rendering an empty extraction as a PASS,
    # a check aimed at a document that is deliberately silent could only ever report a false red.
    # If a number is ever reintroduced into that row, restore a check for it in the same commit.
  fi

  # --- admin/lib module inventory vs FILE-ROLES.md -------------------------------------------
  local lib_all lib_mod missing miss_list
  # NEVER PARSE `ls` FOR A COUNT (fixed 2026-09-01). `ls` classifies executables with a trailing
  # `*` on this platform, so `\.test\.js$` failed to match the three test files that happen to have
  # the executable bit — and this function then reported 91 modules while the FILE-ROLES loop three
  # lines below, which uses a shell GLOB, iterated 88. Two measurements of ONE fact inside one
  # function, disagreeing by 3, one of them printed as "the document is wrong". The glob sees real
  # filenames; `ls` output is a rendering. Both sides now use the glob.
  lib_all=0; lib_mod=0
  for _f in "$PROJECT/admin/lib"/*.js; do
    [ -f "$_f" ] || continue
    lib_all=$((lib_all+1))
    case "$_f" in *.test.js) continue ;; esac
    lib_mod=$((lib_mod+1))
  done
  gf "admin_lib_js_files: ${lib_all:-0}"
  gf "admin_lib_modules_excluding_tests: ${lib_mod:-0}"
  local c2
  c2=$(grep -oE 'Backend modules \([0-9]+ files\)' "$PROJECT/CLAUDE.md" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  claim_check "admin/lib module count" "${lib_mod:-0}" "$c2" "CLAUDE.md directory tree"

  missing=0; miss_list=""
  if [ -f "$PROJECT/MDs/FILE-ROLES.md" ]; then
    for f in "$PROJECT/admin/lib"/*.js; do
      case "$f" in *.test.js) continue ;; esac
      b="$(basename "$f")"
      grep -qF "$b" "$PROJECT/MDs/FILE-ROLES.md" 2>/dev/null || { missing=$((missing+1)); miss_list="$miss_list $b"; }
    done
  else
    missing=-1
  fi
  gf "admin_lib_modules_absent_from_FILE_ROLES: $missing"
  CUR_SCRIPT="MDs/FILE-ROLES.md"
  if [ "$missing" -eq 0 ]; then
    _ok "every admin/lib module is documented in MDs/FILE-ROLES.md"
  elif [ "$missing" -lt 0 ]; then
    _bad "MDs/FILE-ROLES.md exists" "not found — the module inventory claim cannot be checked"
  else
    _bad "every admin/lib module is documented in MDs/FILE-ROLES.md" \
         "$missing of ${lib_mod:-0} modules are absent:$(printf '%s' "$miss_list" | head -c 400)"
  fi
  fi

  # --- canonical documents must contain no control bytes ------------------------------------
  # A single NUL byte makes grep declare a text file BINARY: it prints "Binary file ... matches"
  # and stops emitting lines, while `grep -c` keeps counting. Every extraction pipeline over that
  # document then silently short-reads. Measured 2026-09-01: one NUL in GOTCHAS.md truncated the
  # numbering scan at line 1623 of 1644 and the contiguity check reported "341 distinct, highest
  # 341" for a file whose highest entry was 354 — while awk and python both said 354.
  #
  # It is asserted rather than remembered because the same mistake was made TWICE in one session,
  # hours apart, both times while writing the entry that documents it: a `\0` in the tool composing
  # the file reaches disk as the byte itself. A rule broken twice in two hours is not a rule, it is
  # a wish. The scanned COUNT is printed so an empty sweep cannot read as a clean one.
  local _ctl_n=0 _ctl_bad=""
  for _cf in "$PROJECT"/docs/context/*.md "$PROJECT"/CLAUDE.md "$PROJECT"/Plans/PLAN.md; do
    [ -f "$_cf" ] || continue
    _ctl_n=$((_ctl_n+1))
    # tr, NOT `grep -P`: on this platform grep -P refuses with "supports only unibyte and UTF-8
    # locales", exits non-zero, and the `if` then reads as CLEAN - a detector that errors into a
    # pass, which is the very class this check exists to catch. Proven in BOTH directions before
    # wiring: a planted NUL+SOH counts 2, a clean file 0, and a Hebrew UTF-8 document 0 (the
    # allowed set keeps tab/LF/CR and every byte >= 0200, so multi-byte text is never mistaken
    # for control data).
    _ctl_c=$(LC_ALL=C tr -d '\011\012\015\040-\176\200-\377' < "$_cf" 2>/dev/null | wc -c | tr -d ' ')
    case "$_ctl_c" in ''|*[!0-9]*) _ctl_c=0 ;; esac
    if [ "$_ctl_c" -gt 0 ]; then
      _ctl_bad="$_ctl_bad $(basename "$_cf")($_ctl_c)"
    fi
  done
  gf "canonical_docs_scanned_for_control_bytes: $_ctl_n"
  gf "canonical_docs_with_control_bytes: $(printf '%s' "${_ctl_bad:-none}" | sed 's/^ //')"
  CUR_SCRIPT="docs/context/*.md (control bytes)"
  if [ "$_ctl_n" -eq 0 ]; then
    _bad "canonical documents carry no control bytes" "scanned NO files at all under $PROJECT/docs/context — that is not a clean result"
  elif [ -n "$_ctl_bad" ]; then
    _bad "canonical documents carry no control bytes" \
         "control byte(s) found in:$_ctl_bad — grep will call the file binary and every extraction over it short-reads while grep -c still counts"
  else
    _ok "all $_ctl_n canonical document(s) are free of control bytes"
  fi

  # --- a version-bearing line must carry exactly ONE version literal -------------------------
  # WHY (2026-09-13). sync-governance.sh Steps 4a-4d rewrite an ANCHORED LEADING TOKEN with sed:
  # `**Project version:** v1.2.3` and `Project version: **v1.2.3**`. The expression terminates at
  # that token, so it structurally CANNOT reach a second version literal later on the same line.
  # Measured: PLAN.md line 10 read "**Project version:** v1.4.206 - `version.json` reads **1.4.205**"
  # and MEMORY.md's twin had a body frozen at a v1.4.194 measurement while its header had been
  # rewritten twelve times. A prior TEXT-ONLY repair (fd4364f, "release consistency") re-drifted
  # inside one day, which is why this is a check that FAILS and not another warning: the prose must
  # carry one maintained literal and no unmaintained ones, or the hook will contradict it again at
  # the next release. The fix when this goes red is to DELETE the extra literal, never to hand-edit
  # it to today's value - a literal no mechanism maintains is the same defect with a later date.
  local _vl_file _vl_line _vl_n _vl_checked=0
  for _vl_file in "$PROJECT/Plans/PLAN.md" "$PROJECT/docs/context/MEMORY.md"; do
    [ -f "$_vl_file" ] || continue
    _vl_line=$(grep -m1 -E '(\*\*)?Project version:' "$_vl_file" 2>/dev/null)
    [ -n "$_vl_line" ] || continue
    _vl_checked=$((_vl_checked+1))
    _vl_n=$(printf '%s' "$_vl_line" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | sort -u | wc -l | tr -d ' ')
    CUR_SCRIPT="${_vl_file#$PROJECT/}"
    if [ "$_vl_n" = "1" ]; then
      _ok "${_vl_file#$PROJECT/} Project-version line carries exactly one version literal (the one the hook maintains)"
    else
      _bad "${_vl_file#$PROJECT/} Project-version line carries exactly one version literal" \
           "found $_vl_n distinct version literals on that line: $(printf '%s' "$_vl_line" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | sort -u | tr '\n' ' ')- sync-governance.sh maintains only the leading token, so every other literal on this line is frozen and will contradict it"
    fi
  done
  CUR_SCRIPT="Project-version lines"
  # The Project-version line is what sync-governance.sh maintains FROM version.json; a project with
  # no version.json has no such line to maintain (N/A). With version.json, finding none is a FAIL.
  if [ "$_vl_checked" -eq 0 ] && [ ! -f "$PROJECT/version.json" ]; then
    _na "Project-version lines" "this project has no version.json, so no Project-version line is maintained"
  elif [ "$_vl_checked" -eq 0 ]; then
    _bad "Project-version lines were found to check" "scanned 2 file(s) and found NO Project-version line - an empty input set is never a pass"
  fi

  # --- release identity: version.json vs the tag on HEAD -------------------------------------
  local vj tag
  vj=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$PROJECT/version.json" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/')
  tag=$("$REAL_GIT" -C "$PROJECT" describe --tags --exact-match HEAD 2>/dev/null)
  gf "version_json: ${vj:-<none>}"
  gf "git_tag_on_head: ${tag:-<none — HEAD is not a released commit>}"
  CUR_SCRIPT="version.json"
  if [ -z "$tag" ]; then
    _ok "version.json v${vj:-?}: HEAD carries no tag (unreleased work in progress — not a mismatch)"
  elif [ "v$vj" = "$tag" ] || [ "$vj" = "$tag" ]; then
    _ok "version.json ($vj) matches the tag on HEAD ($tag)"
  else
    _bad "version.json matches the tag on HEAD" "version.json says $vj, HEAD is tagged $tag"
  fi

  # --- write the generated block ------------------------------------------------------------
  if [ "${GOV_SELFTEST_NO_WRITE:-0}" = "1" ]; then
    printf '\n  (GOV_SELFTEST_NO_WRITE=1 — %s not written)\n' "$GEN_FACTS"
    return
  fi
  local B='<!-- BEGIN GENERATED: governance-selftest -->'
  local E='<!-- END GENERATED -->'
  mkdir -p "$(dirname "$GEN_FACTS")" 2>/dev/null
  if [ ! -f "$GEN_FACTS" ] || ! grep -qF "$B" "$GEN_FACTS" 2>/dev/null; then
    {
      [ -f "$GEN_FACTS" ] && cat "$GEN_FACTS"
      printf '# Generated Facts — machine-owned\n\n'
      printf 'Everything between the markers below is RECOMPUTED by\n'
      printf '`~/.claude/hooks/governance/governance-selftest.sh` on every run. Do not hand-edit it:\n'
      printf 'the next run overwrites it. If a value here disagrees with prose in another document,\n'
      printf 'the value here was measured and the prose was not.\n\n'
      printf '%s\n' "$B"
      cat "$BLOCK"
      printf '%s\n' "$E"
    } > "$GEN_FACTS.selftest.tmp" && mv -f "$GEN_FACTS.selftest.tmp" "$GEN_FACTS"
  else
    awk -v b="$B" -v e="$E" -v blk="$BLOCK" '
      $0 == b { print; while ((getline l < blk) > 0) print l; close(blk); skip=1; next }
      $0 == e { print; skip=0; next }
      skip != 1 { print }
    ' "$GEN_FACTS" > "$GEN_FACTS.selftest.tmp" && mv -f "$GEN_FACTS.selftest.tmp" "$GEN_FACTS"
  fi
  printf '\n  recomputed facts written to: %s\n' "$GEN_FACTS"
}

# ── Main ─────────────────────────────────────────────────────────────────────────────────────
printf 'Context Governance SELFTEST — execution-based\n'
printf '  hooks:    %s\n' "$HOOKS_ROOT"
printf '  project:  %s\n' "$PROJECT"
printf '  sandbox:  %s (HOME is redirected here for every hook run)\n' "$SBX"
printf '  mutation: %s\n' "$([ "$DO_MUTATION" = 1 ] && echo on || echo off)"

# ── .result: a DIRECT run invalidates it, it never writes a verdict ──────────────────────────
# Fixed 2026-09-14 (raised as an open problem by a downstream project). `~/.claude/logs/governance-selftest.result` is
# the artifact a reader treats AS the verdict, and only selftest-advisory-stop.sh used to write it.
# So a manual run left the previous evening's `verdict=GREEN` sitting on disk next to a fresh red
# log — measured: a run finishing pass=239 fail=3 beside a .result reading pass=242 fail=0, while
# GENERATED-FACTS.md HAD been refreshed by that same run. One invocation, two artifacts, and the
# one shaped like a verdict was the wrong one. A manual run is what you do right after changing
# something, which is exactly when a stale green is most convincing.
#
# The fix is deliberately asymmetric: a direct run INVALIDATES, it does not certify. Writing
# `verdict=UNKNOWN` can never accidentally report a pass, whereas writing a real verdict from here
# could — a direct run may be scoped (--no-mutation, a different GOV_SELFTEST_PROJECT) and its
# counts are not comparable to the hook's. The observed summary is still recorded, as data under a
# name no reader mistakes for a verdict. Ownership stays with the hook.
#
# Invalidation happens BEFORE the suite runs, on purpose: if this run crashes half way, .result is
# UNKNOWN rather than a stale GREEN. Failing toward "I do not know" is the whole point.
_gov_tree_id() {   # three identity lines; answers "is this verdict even about the current tree?"
  local hf ph pd
  hf=$(find "$HOOKS_ROOT" -type f \( -name '*.sh' -o -name '*.js' -o -name '*.py' -o -name '*.ps1' \) 2>/dev/null \
       | LC_ALL=C sort | xargs cat 2>/dev/null | sha256sum 2>/dev/null | cut -c1-12)
  [ -n "$hf" ] || hf=unknown
  if [ -n "${PROJECT:-}" ] && [ -d "$PROJECT/.git" ]; then
    ph=$("$REAL_GIT" -C "$PROJECT" rev-parse --short HEAD 2>/dev/null); [ -n "$ph" ] || ph=none
    if [ -n "$("$REAL_GIT" -C "$PROJECT" status --porcelain 2>/dev/null)" ]; then pd=yes; else pd=no; fi
  else ph=none; pd=unknown; fi
  printf 'hooks_fingerprint=%s\nproject_head=%s\nproject_dirty=%s\n' "$hf" "$ph" "$pd"
}
_gov_write_result() {   # $1 = state word, $2 = summary line
  local rf="$HOME/.claude/logs/governance-selftest.result" tmp
  [ -n "${GOV_SELFTEST_SBX:-}" ] && return 0    # a sandboxed run must never touch the real file
  mkdir -p "$(dirname "$rf")" 2>/dev/null
  tmp="$rf.tmp.$$"
  {
    printf 'verdict=UNKNOWN\n'
    printf 'reason=%s\n' "$1"
    printf 'written_by=governance-selftest.sh (direct run — invalidates, does not certify)\n'
    printf 'finished=%s\n' "$(date +%s)"
    printf 'project=%s\n' "${PROJECT:-<none>}"
    _gov_tree_id
    printf 'direct_run_summary=%s\n' "$2"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$rf" 2>/dev/null
}
_gov_write_result "a direct run started; any previous verdict is void" "(run in progress)"

part_a
[ -n "$ONLY" ] || part_b

# ── Live invariant: does the real governance.log account for every protected-file decision? ────
# Not a sandboxed case - this reads the ACTUAL machine-wide log, which is production history, not
# something this run can control or reset. Reported as data, the same way Part (b) reports doc
# drift: a human decides what a mismatch means, this tool only refuses to stay quiet about one.
# This is the exact check that would have caught the 2026-09-14 fail-open gap on day one instead
# of 16 invocations (and an unknown number of months) later.
_real_log="$CHOME/logs/governance.log"
if [ -z "$ONLY" ] && [ -f "$_real_log" ]; then
  _lp=$(grep -c 'protected target' "$_real_log" 2>/dev/null || echo 0)
  _la=$(grep -cE 'ALLOW: (token valid|success-token gate off)' "$_real_log" 2>/dev/null || echo 0)
  _lb=$(grep -cE 'BLOCK:' "$_real_log" 2>/dev/null || echo 0)
  _lgap=$((_lp - _la - _lb))
  if [ "$_lgap" -ne 0 ]; then
    printf '\n[live invariant] %s: protected-target=%s allow=%s block=%s gap=%s  <-- NOT ZERO: some protected-file invocations never reached a decision\n' \
      "$_real_log" "$_lp" "$_la" "$_lb" "$_lgap"
  else
    printf '\n[live invariant] %s: protected-target=%s allow=%s block=%s  (balanced)\n' \
      "$_real_log" "$_lp" "$_la" "$_lb"
  fi
fi

printf '\n============================================================\n'
if [ -n "$FAIL_LOG" ]; then
  printf 'FAILURES\n%s\n\n' "$FAIL_LOG"
fi
if [ -n "$UNCOV_LOG" ]; then
  printf 'UNCOVERED (executed nowhere — NOT green)\n%s\n\n' "$UNCOV_LOG"
fi
if [ "${USERHOOK_N:-0}" -gt 0 ]; then
  printf 'USER HOOKS registered on this machine but not part of the framework (%s; not counted, not tested here):%s\n\n' "$USERHOOK_N" "$USERHOOK_LOG"
fi
[ -n "$ONLY" ] && printf 'SCOPED (--only=%s) - a partial check, NOT a verdict on the framework\n' "$ONLY"
printf '[governance-selftest] pass=%s fail=%s uncovered=%s\n' "$PASS" "$FAIL" "$UNCOV"

# A DIRECT RUN OF THIS SUITE INVALIDATES ~/.claude/logs/governance-selftest.result — it does not
# write a verdict there. See the long note beside `_gov_write_result` above for why the asymmetry
# is deliberate. The line printed just above, and the log, are this run's real output; .result now
# says UNKNOWN and carries the tree fingerprint, so the next reader can see that the last real
# verdict (owned by selftest-advisory-stop.sh) is older than the tree it claimed to describe.
_gov_write_result "last run was direct, not the Stop hook; no verdict is claimed" \
  "[governance-selftest] pass=$PASS fail=$FAIL uncovered=$UNCOV"

if [ "$FAIL" -gt 0 ] || [ "$UNCOV" -gt 0 ]; then exit 1; fi
exit 0
