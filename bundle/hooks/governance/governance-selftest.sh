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
  [ "$HAVE_TIMEOUT" = 1 ] && runner=(timeout 60 bash "$script" ${extra[@]+"${extra[@]}"})
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
    no-local-compute.sh)        echo case_no_local_compute ;;
    deny-git-bypass.sh)         echo case_deny_git_bypass ;;
    pr-watch-guard.sh)          echo case_pr_watch_guard ;;
    cross-session-guard.sh)     echo case_cross_session_guard ;;
    render-gate.sh)             echo case_render_gate ;;
    render-rules-read.sh)       echo case_render_rules_read ;;
    *) echo "" ;;
  esac
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
      enumerate-before-claiming.sh) echo "TOOL: operator-invoked, not a hook — enumerates the machine's scheduled tasks / startup / run keys and flags entries whose target is missing; covered by case_enumerate_before_claiming" ;;
      enumerate-tasks.ps1)         echo "TOOL: the PowerShell half of enumerate-before-claiming.sh — a separate file on purpose, because escapes do not survive being embedded (gotcha #359)" ;;
      pr-watch.sh)                 echo "TOOL: the PR watcher the session arms through the Monitor tool (pr-follow-through skill) - not a hook; pr-watch-guard.sh hands the session its exact command, and 'pr-watch.sh --selftest' runs its offline must-fire/must-not-fire controls (v1.4.0)" ;;
      pii-gate-parse.py)           echo "invoked-by:pii-gate-pretooluse.sh" ;;
      wa-send.js)                  echo "invoked-by:_common.sh" ;;
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
  if [ "$_vl_checked" -eq 0 ]; then
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
part_b

# ── Live invariant: does the real governance.log account for every protected-file decision? ────
# Not a sandboxed case - this reads the ACTUAL machine-wide log, which is production history, not
# something this run can control or reset. Reported as data, the same way Part (b) reports doc
# drift: a human decides what a mismatch means, this tool only refuses to stay quiet about one.
# This is the exact check that would have caught the 2026-09-14 fail-open gap on day one instead
# of 16 invocations (and an unknown number of months) later.
_real_log="$CHOME/logs/governance.log"
if [ -f "$_real_log" ]; then
  _lp=$(grep -c 'protected target' "$_real_log" 2>/dev/null || echo 0)
  _la=$(grep -c 'ALLOW: token valid' "$_real_log" 2>/dev/null || echo 0)
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
