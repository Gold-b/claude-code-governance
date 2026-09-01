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
#   bash ~/.claude/hooks/governance/governance-selftest.sh [--no-mutation] [--keep-sandbox]
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
for _a in "$@"; do
  case "$_a" in
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
_sub=""
for _a in "$@"; do case "$_a" in -*|-C) ;; *) _sub="$_a"; break ;; esac; done
_dir="$PWD"
_prev=""
for _a in "$@"; do [ "$_prev" = "-C" ] && { _dir="$_a"; break; }; _prev="$_a"; done
case "$_sub" in
  clone|push|pull|fetch|remote|submodule|am|request-pull|send-email)
    printf '%s DENIED-NETWORK git %s (cwd=%s)\n' "$(date +%s)" "$_sub" "$PWD" >> "$GOV_SELFTEST_SBX/git-violations.log"
    echo "selftest: network git subcommand '$_sub' denied" >&2
    exit 1 ;;
  init|add|commit|checkout|reset|stash|tag|merge|rebase|cherry-pick|revert|restore|switch|rm|mv|update-index|update-ref|gc|worktree|config|apply)
    case "$_dir" in
      "$GOV_SELFTEST_SBX"*) ;;
      *) printf '%s DENIED-OUTSIDE git %s (dir=%s)\n' "$(date +%s)" "$_sub" "$_dir" >> "$GOV_SELFTEST_SBX/git-violations.log"
         echo "selftest: mutating git '$_sub' outside the sandbox denied" >&2
         exit 1 ;;
    esac ;;
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

# ── Hook runner ──────────────────────────────────────────────────────────────────────────────
# $1 script, $2 cwd, $3 session id, $4 stdin payload
_run() {
  local script="$1" cwd="$2" sid="${3:-selftest-sid}" payload="$4"
  : > "$IO_OUT"; : > "$IO_ERR"
  local runner=(bash "$script")
  [ "$HAVE_TIMEOUT" = 1 ] && runner=(timeout 60 bash "$script")
  ( cd "$cwd" 2>/dev/null || exit 97
    printf '%s' "$payload" | env \
      HOME="$SBX_HOME" USERPROFILE="$SBX_HOME" \
      PATH="$SBX_BIN:$PATH" \
      GOV_SELFTEST_SBX="$SBX" GOV_SELFTEST_REAL_GIT="$REAL_GIT" \
      GOV_NOTIFY=0 GOV_WHATSAPP=0 GOVERNANCE_UPDATE_CHECK=0 \
      GOVERNANCE_HOOKS=1 GOV_ROLE_FRAMEWORK=1 GOV_COLLISION_GUARD=1 \
      GOV_SESSION_ID="$sid" GIT_TERMINAL_PROMPT=0 \
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
    *) echo "" ;;
  esac
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

  fx_token
  run_hook "$src" "sid-gg-1" "$(pl_pre "$src" sid-gg-1 "$prot")"
  expect_rc 2 "protected doc, no token: BLOCKED"
  expect_has "requires a success token" "protected doc: explains the token requirement"

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
  fx_token
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
  expect_has "full-finish" "staged code changes: names the required pipeline"
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

expand_cmd() {   # ~ -> $CHOME's parent; strip trailing args; echo "" when not a file
  local c="$1"
  case "$c" in "~/"*) c="$HOME/${c#\~/}" ;; esac
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

  # M1 — NOOP: the hook does nothing at all. Any assertion set a dead hook still satisfies is
  # vacuous, so this is the coverage test, not just a mutation test.
  { printf '%s\n' "$(head -1 "$real")"; printf 'exit 0  # selftest mutant: NOOP\n'; tail -n +2 "$real"; } > "$mutant"
  MUT=1; CASE_FAILS=0; CUR_SCRIPT="$mutant"; "$fn" >/dev/null 2>&1; MUT=0
  if [ "$CASE_FAILS" -eq 0 ]; then
    survivors=$((survivors+1))
    _bad "MUTATION[$base/NOOP] survived" "a hook that does NOTHING passes every assertion for it — the assertions are vacuous"
  else
    _ok "MUTATION[$base/NOOP] killed by $CASE_FAILS assertion(s)"
  fi

  # M2 — NOBLOCK: every `exit 2` becomes `exit 0`. Only meaningful for hooks that block.
  # The trailing-comment form matters: check-full-finish.sh writes `exit 2  # Block stop`, and a
  # `$`-anchored pattern left that mutant byte-identical to the original — which then "survived"
  # and accused a perfectly good assertion set of being vacuous. A mutation operator that fails
  # to mutate is a false alarm, not a finding.
  if grep -qE '^[[:space:]]*exit 2([[:space:]]|#|$)' "$real"; then
    sed -E 's/^([[:space:]]*)exit 2([[:space:]]*(#.*)?)$/\1exit 0\2/' "$real" > "$mutant"
    MUT=1; CASE_FAILS=0; CUR_SCRIPT="$mutant"; "$fn" >/dev/null 2>&1; MUT=0
    if [ "$CASE_FAILS" -eq 0 ]; then
      survivors=$((survivors+1))
      _bad "MUTATION[$base/NOBLOCK] survived" "neutralising every 'exit 2' changed nothing — the block is not actually asserted"
    else
      _ok "MUTATION[$base/NOBLOCK] killed by $CASE_FAILS assertion(s)"
    fi
  fi

  cp -f "$real" "$mutant" 2>/dev/null
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
      render-gate.sh)              echo "ORPHAN: registered in no event and called by nothing but its own sibling — task B11, register or delete (owner decision)" ;;
      render-rules-read.sh)        echo "ORPHAN: registered in no event and called by nothing but its own sibling — task B11, register or delete (owner decision)" ;;
      pii-gate-parse.py)           echo "invoked-by:pii-gate-pretooluse.sh" ;;
      wa-send.js)                  echo "invoked-by:_common.sh" ;;
      gov-notify.ps1)              echo "ORPHAN: nothing in the tree references it. install.sh carries a comment claiming _common.sh gov_notify() calls it to raise the Windows popup - grep says otherwise, and that comment is the only reason anyone would keep the file. Task B11, register/wire or delete (owner decision)" ;;
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
    _ok "$1: no claim found in $4 (nothing to contradict)"
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
  # The manifest states Open-Problems.md as "~409 lines" / "409 lines". Compare against the
  # measured value; a stale size claim is how a reader mis-budgets a selective context load.
  local op_claim
  op_claim=$(grep -oE 'Open-Problems\.md[^|]*—?[[:space:]]*~?[0-9]+ lines' "$PROJECT/docs/context/CONTEXT-MANIFEST.md" 2>/dev/null \
             | grep -oE '[0-9]+ lines' | head -1 | tr -dc '0-9')
  claim_check "MDs/Open-Problems.md line count" "${op_lines:-0}" "$op_claim" "docs/context/CONTEXT-MANIFEST.md"

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
    c=$(grep -oE 'getToolNames\(\)\.length` = [0-9]+' "$PROJECT/CLAUDE.md" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
    claim_check "God Mode tools (self-declaring claim)" "$gm_measured" "$c" "CLAUDE.md"
    c=$(grep -oE '[0-9]+ God Mode tools reference' "$PROJECT/CLAUDE.md" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    claim_check "God Mode tools (doc map)" "$gm_measured" "$c" "CLAUDE.md Documentation Map"
    c=$(grep -oE '[0-9]+ God Mode tools reference' "$PROJECT/docs/context/CONTEXT-MANIFEST.md" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
    claim_check "God Mode tools (manifest)" "$gm_measured" "$c" "docs/context/CONTEXT-MANIFEST.md"
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

part_a
part_b

printf '\n============================================================\n'
if [ -n "$FAIL_LOG" ]; then
  printf 'FAILURES\n%s\n\n' "$FAIL_LOG"
fi
if [ -n "$UNCOV_LOG" ]; then
  printf 'UNCOVERED (executed nowhere — NOT green)\n%s\n\n' "$UNCOV_LOG"
fi
printf '[governance-selftest] pass=%s fail=%s uncovered=%s\n' "$PASS" "$FAIL" "$UNCOV"

if [ "$FAIL" -gt 0 ] || [ "$UNCOV" -gt 0 ]; then exit 1; fi
exit 0
