#!/usr/bin/env bash
# governance-guard.sh — BLOCK edits to protected governance docs without a success token
# Created: 2026-04-12 (user feedback: "enforcement via hook, not LLM instruction")
#
# This hook fires on PreToolUse for Edit/Write/MultiEdit tools. It reads the
# tool input JSON from stdin, extracts the target file path, and checks if it
# is in the "protected" list. Protected files can only be edited when a fresh
# governance-success-token.json exists at ~/.claude/logs/.
#
# Without this guard, the LLM can "forget" the rule saved in feedback memory
# and write RESOLVED/FIXED markers to Open-Problems.md mid-session, creating
# context drift. With this guard, such writes are BLOCKED at infrastructure
# level — the tool call fails, forcing the LLM to acknowledge the rule.
#
# To authorize writes, the LLM must run:
#   bash .claude/hooks/governance/commit-task-success.sh "<task desc>"
# ONLY after the user has confirmed success. The script creates a 5-minute
# token that this guard reads.
#
# Fail-open policy: if the hook cannot determine the file path (stdin empty,
# JSON malformed, etc.), it exits 0 (allows) and logs a warning. This prevents
# the hook from accidentally blocking all edits due to a format mismatch.
# A future hardening pass can switch to fail-closed if the format stabilizes.

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0

# Read the full stdin payload (Claude Code hooks receive JSON via stdin).
# Use a timeout to avoid hanging on systems where stdin is not a pipe.
# Security: cap stdin to 64KB to prevent memory exhaustion
PAYLOAD=$(gov_hook_input)

if [ -z "$PAYLOAD" ]; then
  gov_log "governance-guard" "no stdin payload — allow (fail-open)"
  exit 0
fi

# Extract the target file path from the tool input.
# Claude Code hook payload structure: { "tool_name": "...", "tool_input": { "file_path": "..." } }
# Use Python for robust JSON parsing (no dependency on jq).
FILE_PATH=$(printf '%s' "$PAYLOAD" | timeout 5 python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input", {}) or {}
    fp = ti.get("file_path") or ti.get("path") or ""
    print(fp)
except Exception:
    print("")
' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  gov_log "governance-guard" "no file_path in payload — allow (fail-open)"
  exit 0
fi

# Security: sanitize file path — strip control chars, cap length, prevent prompt injection
FILE_PATH=$(printf '%s' "$FILE_PATH" | head -c 512 | tr -d '\n\r' | tr -cd '[:print:]')

# Normalize path separators — we match on substring so both Unix and Windows forms work.
NORMALIZED=$(printf '%s' "$FILE_PATH" | tr '\\' '/')

# ── bundle/ IS A PUBLISH TARGET, NOT AN EDIT SURFACE (5.6, 1.7.0) ─────────────────────────────
#
# THE ROOT CAUSE THIS CLOSES. The three copies of this framework are:
#     ~/.claude/{hooks,skills,docs,agents,CLAUDE.md}   LIVE     — the ONLY edit surface
#  -> ~/.claude/governance-installer/bundle/           STAGING  — mirrored by the sync hook
#  -> <GOV_REPO_PATH>/bundle/                          TARGET   — written only by a publish
# The publish does `cp -r <staging>/bundle/* <target>/bundle/`: one-way, no direction check,
# no delete. MEASURED 2026-09-18: 13 files differed and FIVE had the TARGET as the newer,
# better copy — someone had edited the clone directly across v1.5.x/v1.6.x. The next
# unattended publish would have clobbered all five silently.
#
# The TARGET-AHEAD gate in end-session.sh catches that at publish time. This catches it at the
# keystroke, which is where it is cheap to fix. Cost when this guard is WRONG: it blocks a
# deliberate clone edit — so there is a named kill switch, and the message says what to edit
# instead rather than only refusing.
#
# ORDER MATTERS: this runs BEFORE the protected-docs machinery and before the fail-closed
# trap, and it is gated on the path containing `/bundle/` so an ordinary edit pays NOTHING
# (no env sourcing, no extra fork) — the 2026-09-15 lesson about controls that cost time on
# every run applies to this file more than most.
case "$NORMALIZED" in
  */bundle/*)
    if [ "${GOV_BUNDLE_EDIT:-0}" = "1" ]; then
      [ "${GOV_BYPASS_QUIET:-0}" = "1" ] || echo "[governance] GOV_BUNDLE_EDIT=1 — writing DIRECTLY into a publish target. The sync hook will overwrite this from the live file, and a publish may clobber it. (GOV_BYPASS_QUIET=1 to mute)" >&2
      gov_log "governance-guard" "GOV_BUNDLE_EDIT=1 bypass: direct bundle write allowed at $NORMALIZED"
    else
      # Roots are CONFIGURATION, never hardcoded: this file ships in the public bundle, so a
      # baked checkout path would be both an identity leak and wrong on every other machine.
      _GG_ROOTS=""
      if [ -f "$HOME/.claude/.governance-local.env" ]; then
        _GG_REPO=$(grep -E '^[[:space:]]*GOV_REPO_PATH=' "$HOME/.claude/.governance-local.env" 2>/dev/null \
                   | tail -1 | sed -e 's/^[^=]*=//' -e 's/^["'"'"']//' -e 's/["'"'"']$//' -e 's/[[:space:]]*$//')
        [ -n "$_GG_REPO" ] && _GG_ROOTS="$_GG_REPO"
      fi
      if [ -f "$HOME/.claude/.governance-mirrors" ]; then
        _GG_ROOTS="$_GG_ROOTS
$(sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$HOME/.claude/.governance-mirrors" 2>/dev/null | grep -v '^$')"
      fi
      # Fold `C:/x` -> `/c/x` and lowercase BOTH sides before comparing. The payload gives a
      # Windows path (e.g. C:\dev\example-project\bundle\x) while a configured root may be
      # written in either form, and Windows paths are case-insensitive — a raw string compare
      # says "different" for the very write this guard exists to stop. Same fold as
      # sync-governance-copies.sh gov_norm_path(), for the same reason.
      _gg_fold() {
        _p=$(printf '%s' "$1" | tr '\\' '/' | tr '[:upper:]' '[:lower:]')
        case "$_p" in [a-z]:/*) _p="/${_p%%:*}/${_p#*:/}" ;; esac
        while [ "${_p%/}" != "$_p" ]; do _p="${_p%/}"; done
        printf '%s' "$_p"
      }
      _GG_TARGET=$(_gg_fold "$NORMALIZED")
      while IFS= read -r _gg_root; do
        [ -n "$_gg_root" ] || continue
        _gg_norm=$(_gg_fold "$_gg_root")
        [ -n "$_gg_norm" ] || continue
        case "$_GG_TARGET" in
          "$_gg_norm"/bundle/*)
            gov_log "governance-guard" "BLOCK: direct write into a publish target: $NORMALIZED"
            {
              echo "[GOVERNANCE] BLOCKED: bundle/ is a PUBLISH TARGET, not an edit surface."
              echo "  target : $FILE_PATH"
              echo "  root   : $_gg_norm"
              echo "  Edit the LIVE file under ~/.claude instead — the sync hook mirrors it into"
              echo "  ~/.claude/governance-installer/bundle/ (PII-gated), and a deliberate"
              echo "  GOV_PUBLISH=1 close copies that into the repo."
              echo "    hooks/governance/<f>  ->  ~/.claude/hooks/governance/<f>"
              echo "    skills/<s>/SKILL.md   ->  ~/.claude/skills/<s>/SKILL.md"
              echo "    docs/<d>.md           ->  ~/.claude/docs/<d>.md"
              echo "    agents/<a>.md         ->  ~/.claude/agents/<a>.md   (must be listed in bundle/DISTRIBUTED)"
              echo "    CLAUDE.md.template    ->  ~/.claude/CLAUDE.md       (rendered: content above the GOV-LOCAL-ONLY marker)"
              echo "  WHY: editing a clone's bundle/ is invisible to every drift check here, and the"
              echo "  publish copies staging OVER the clone — MEASURED 2026-09-18, five such clone-only"
              echo "  edits were one unattended close away from being silently overwritten."
              echo "  Deliberate exception (say so out loud): GOV_BUNDLE_EDIT=1"
            } >&2
            exit 2
            ;;
        esac
      done <<GGEOF
$_GG_ROOTS
GGEOF
    fi
    ;;
esac

# Protected file patterns — any Edit/Write to a path containing one of these
# is blocked unless a fresh success token exists.
#
# IMPORTANT: do NOT include "memory/MEMORY.md" patterns under .claude/projects/
# here. Those are user-level Claude auto-memory files (managed by Claude per
# user-level CLAUDE.md instructions — must be writable on every session).
# Project-level governance MEMORY.md (docs/context/MEMORY.md) IS listed below.
# The list itself now lives in _common.sh (gov_protected_patterns / gov_is_protected_doc) so the
# guard's decision and the success token's advertised list cannot describe different sets (#101 A.1).
IS_PROTECTED=0
MATCHED_PATTERN=""
if MATCHED_PATTERN=$(gov_is_protected_doc "$NORMALIZED"); then
  IS_PROTECTED=1
fi

if [ "$IS_PROTECTED" = "0" ]; then
  # Not a protected file — allow.
  exit 0
fi

gov_log "governance-guard" "protected target: $FILE_PATH (pattern: $MATCHED_PATTERN)"

# Fail-closed safety net (2026-09-14). Measured against the full history of governance.log:
# "protected target" was logged 2083 times, but only 2067 runs went on to log an explicit
# ALLOW or BLOCK - 16 writes to protected governance docs completed with no decision ever
# recorded. Two of the three reproduced cases got as far as logging the resolved role, then
# nothing - death or a hang between the role check and the token check (leading candidate:
# the python3 subprocess below, contended when several Claude Code sessions fire this hook
# at the same time - see the `timeout` added around it). From here on the only way out is an
# explicit decision: a crash, a hang killed by the harness's own hook timeout, or a future
# edit that adds an early return all now default to BLOCK instead of silently falling
# through to allow.
trap 'gov_log "governance-guard" "BLOCK: guard exited without an explicit decision (fail-closed)"; exit 2' EXIT TERM INT HUP

# Test-only seam for governance-selftest.sh (case_governance_guard): forces the unexpected
# exit above to prove the trap actually converts it into a BLOCK.
[ -n "${GOV_TEST_UNEXPECTED_EXIT:-}" ] && exit 17

# ── Self-imposed deadline: BUILT, MEASURED, AND DELIBERATELY NOT ON THE PATH (2026-09-15) ─────
# Read this before re-enabling it. The machinery below is correct and proven in both directions;
# it is unused because measuring it inverted the diagnosis that motivated it.
#
# The trap above is genuinely not enough: after it shipped, `fail-closed` appeared ZERO times in
# governance.log while the unaccounted count grew 16 -> 20. A SIGKILL at the hook's timeout runs no
# handler, so a guard that waits to be killed politely is relying on luck.
#
# The obvious answer was a shorter self-deadline. Then it was timed on the path it protects:
#   before      2-3s   |   with watchdog, idle   5.7 / 8.8 / 7.0s
#                      |   with watchdog, LOADED  25 / 43 / 43 / 46s
# The loaded row is the finding, and it rewrote the cause: nothing here HANGS. Under contention the
# hook simply takes tens of seconds - competing for the disk and for python3 startup - and a 10s
# budget killed it. A 6s deadline on top of that would refuse most legitimate writes whenever the
# machine is busy, trading a rare silent allow for a frequent false block. A control people cannot
# work with gets switched off, and then it protects nothing.
#
# The remedy was therefore a budget the hook can finish inside: settings-hooks.json registers 60s,
# not 10s. Keep this code: on a machine where bounding IS worth its cost, set GOV_GUARD_BUDGET and
# call gov_guard_run_bounded instead of gov_guard_decision_body below.
_GOV_BUDGET="${GOV_GUARD_BUDGET:-6}"

gov_guard_decide() {
  # Everything from the role gate to the token verdict. Returns the hook's exit code:
  #   0 = allow, 2 = block. Any other value is treated as "no decision" by the caller.
  gov_guard_decision_body
  return $?
}

# Run the decision in a child, watch it, and decide for it if it runs out of time.
gov_guard_run_bounded() {
  gov_guard_decide &
  _gd_child=$!
  # Poll at 200ms, not 1s. MEASURED: a 1-second granularity cost this hook 5.7-8.8s on the
  # protected path against 2-3s before the watchdog existed - i.e. the fix walked the guard right
  # up to the 10s timeout it exists to beat. A decision that finishes in 1.2s must cost 1.2s, not
  # round up to 2. `sleep` here accepts fractions; the tick counter keeps the budget in seconds.
  _gd_ticks=0
  _gd_max=$(( _GOV_BUDGET * 5 ))
  while kill -0 "$_gd_child" 2>/dev/null; do
    if [ "$_gd_ticks" -ge "$_gd_max" ]; then
      kill -9 "$_gd_child" 2>/dev/null
      wait "$_gd_child" 2>/dev/null
      gov_log "governance-guard" "BLOCK: no decision within ${_GOV_BUDGET}s (fail-closed; the guard timed itself out before the harness could)"
      cat >&2 <<ERRMSG
[governance-guard] BLOCKED: the guard could not reach a decision within ${_GOV_BUDGET} seconds.

Target file: $FILE_PATH

This is deliberate. The guard bounds itself BELOW the hook timeout so that a slow or hung check
becomes an explicit refusal instead of a silent allow - a process killed by the harness runs no
handler at all, so waiting to be killed would let the write through unrecorded.

Retry the edit. If this repeats, the machine is under heavy I/O or python3 is slow to start;
raise the budget with GOV_GUARD_BUDGET=<seconds> (keep it under the hook's registered timeout).
ERRMSG
      trap - EXIT TERM INT HUP
      exit 2
    fi
    sleep 0.2 2>/dev/null || sleep 1
    _gd_ticks=$((_gd_ticks + 1))
  done
  wait "$_gd_child" 2>/dev/null
  return $?
}

gov_guard_decision_body() {
# The child does not carry the fail-closed trap: the PARENT owns that verdict, and a trap firing
# in here as well would log a second, contradictory line for one invocation.
trap - EXIT TERM INT HUP

# Test-only seam: make the decision take longer than the budget, so the parent's deadline can be
# proven rather than assumed. Without it the budget path is unreachable in a test and would ship
# unverified - which is exactly how the first version of this fix logged `fail-closed` zero times
# in production while looking correct.
[ -n "${GOV_TEST_SLOW_DECISION:-}" ] && sleep "$GOV_TEST_SLOW_DECISION"

# Node-role gate (Framework v2.1): governance files on DEPLOYMENT/FROZEN are
# mirrors, not sources. Direct edits from Claude would be overwritten by
# UPDATE.bat anyway — and can cause governance drift in the interim window.
# Hard-block all protected-file edits when running on non-SOURCE.
#
# v2.1 (2026-05-20): detect role from TARGET FILE path first, falling back to
# CWD. This handles the legitimate case where Claude's CWD is LOCAL/DEPLOYMENT
# but the user explicitly asks for a REMOTE/SOURCE edit. Previously, the hook
# blocked these edits because it only checked CWD's role.
TARGET_DIR=$(dirname "$NORMALIZED")
TARGET_ROOT=""
search_dir="$TARGET_DIR"
for _depth in 1 2 3 4 5 6 7 8 9 10; do
  if [ -f "$search_dir/CLAUDE.md" ]; then
    TARGET_ROOT="$search_dir"
    break
  fi
  parent=$(dirname "$search_dir")
  if [ "$parent" = "$search_dir" ] || [ -z "$parent" ]; then
    break
  fi
  search_dir="$parent"
done

if [ -n "$TARGET_ROOT" ]; then
  ROLE_NOW=$(gov_detect_role "$TARGET_ROOT")
  gov_log "governance-guard" "role from target ($TARGET_ROOT): $ROLE_NOW"
else
  # Fallback: CWD-based detection (pre-v2.1 behavior)
  ROLE_NOW=$(gov_find_project_root)
  ROLE_NOW=$(gov_detect_role "$ROLE_NOW")
  gov_log "governance-guard" "role from CWD fallback: $ROLE_NOW"
fi
if [ "$ROLE_NOW" = "DEPLOYMENT" ] || [ "$ROLE_NOW" = "FROZEN" ]; then
  gov_log "governance-guard" "BLOCK: non-SOURCE role ($ROLE_NOW) — cannot edit governance"
  cat >&2 <<ERRMSG
[governance-guard] BLOCKED: cannot edit governance files on $ROLE_NOW node.

Target file: $FILE_PATH
Current node role: $ROLE_NOW

Governance files on $ROLE_NOW nodes are MIRRORS of SOURCE state. They are
updated exclusively by UPDATE.bat (zipball from GitHub) — never by Claude.

To make governance changes:
  1. Switch to the SOURCE node (typically C:\\the source repo\\)
  2. Edit there
  3. Release via /full-finish
  4. Run UPDATE.bat on this node to pull the new state

Kill switch (not recommended): GOV_ROLE_FRAMEWORK=0 disables role awareness.
ERRMSG
  trap - EXIT
  exit 2
fi

# Check for a fresh success token.
TOKEN_FILE="$HOME/.claude/logs/governance-success-token.json"
if [ ! -f "$TOKEN_FILE" ]; then
  gov_log "governance-guard" "BLOCK: no success token found at $TOKEN_FILE"
  cat >&2 <<ERRMSG
[governance-guard] BLOCKED: edit to protected governance doc requires a success token.

Target file: $FILE_PATH
Matched protected pattern: $MATCHED_PATTERN

To authorize this edit, FIRST confirm with the user that the task completed
successfully, THEN run:
  bash .claude/hooks/governance/commit-task-success.sh "<task description>"

The token is valid for 5 minutes. After it expires, you must re-confirm.

This guard exists because past sessions wrote premature "RESOLVED" markers
to docs for in-flight attempts, creating context drift. See user feedback
memory: feedback_auto_document_changes.md

To disable this guard for an emergency, set GOVERNANCE_HOOKS=0 in the
environment and retry the edit.
ERRMSG
  trap - EXIT
  exit 2
fi

# Verify token is still within TTL.
# Read the token file via cat + pipe to Python — avoids Git-Bash /c/... path
# issues that occur when Python tries to open the path directly on Windows.
NOW_EPOCH=$(date +%s)
EXPIRES_EPOCH=$(cat "$TOKEN_FILE" 2>/dev/null | timeout 5 python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(int(d.get("expires_at_epoch", 0)))
except Exception:
    print(0)
' 2>/dev/null)

if [ -z "$EXPIRES_EPOCH" ] || [ "$EXPIRES_EPOCH" = "0" ]; then
  gov_log "governance-guard" "BLOCK: token file exists but is unreadable or malformed"
  cat >&2 <<ERRMSG
[governance-guard] BLOCKED: success token is malformed.

Token file: $TOKEN_FILE
Re-issue by running:
  bash .claude/hooks/governance/commit-task-success.sh "<task description>"
ERRMSG
  trap - EXIT
  exit 2
fi

if [ "$NOW_EPOCH" -gt "$EXPIRES_EPOCH" ]; then
  gov_log "governance-guard" "BLOCK: token expired ($(($NOW_EPOCH - $EXPIRES_EPOCH))s ago)"
  cat >&2 <<ERRMSG
[governance-guard] BLOCKED: success token expired $(($NOW_EPOCH - $EXPIRES_EPOCH)) seconds ago.

Token file: $TOKEN_FILE
Re-confirm success with the user, then re-issue by running:
  bash .claude/hooks/governance/commit-task-success.sh "<task description>"
ERRMSG
  trap - EXIT
  exit 2
fi

# Token is valid — allow the write.
REMAINING=$(($EXPIRES_EPOCH - $NOW_EPOCH))
gov_log "governance-guard" "ALLOW: token valid, ${REMAINING}s remaining"
exit 0
}

# ── The only exit from here is an explicit decision ────────────────────────────────────────────
# WHY THE WATCHDOG IS NOT USED (measured 2026-09-15, and it inverted the conclusion).
#
# A self-imposed deadline was built here first: run the decision in a child, block if it does not
# answer within 6s, on the reasoning that SIGKILL at the harness's 10s timeout cannot be trapped.
# It worked - proven both ways, 8s hang against a 2s budget returned BLOCK with a valid token
# present. Then it was TIMED against the path it protects:
#
#   before the watchdog, in production : 2-3s
#   with the watchdog, idle machine    : 5.7 / 8.8 / 7.0s
#   with the watchdog, machine loaded  : 25 / 43 / 43 / 46s
#
# The last row is the finding. Under load this hook takes tens of seconds no matter what it does,
# because it is competing for the disk and for python3 startup - which also explains the original
# 16 unaccounted invocations far better than any code defect: they were not hangs, they were a hook
# starved past a 10s budget and killed. A 6s deadline on top of that would refuse most legitimate
# writes whenever the machine is busy. That trades a rare silent allow for a frequent false block,
# and a control people cannot work with gets switched off - which protects nothing at all.
#
# So the decision runs directly. The EXIT/TERM/INT/HUP trap above still converts any internal death
# into a BLOCK; the honest limit is that a SIGKILL runs no handler, and the fix for THAT is a
# budget the hook can actually finish inside - settings-hooks.json now registers 60s, not 10s.
# gov_guard_run_bounded is kept, unused, with GOV_GUARD_BUDGET, for a machine where bounding is
# worth its cost.
gov_guard_decision_body
_gov_rc=$?
trap - EXIT TERM INT HUP
case "$_gov_rc" in
  0|2) exit "$_gov_rc" ;;
  *)
    # The body neither allowed nor blocked. It cannot be trusted to have checked anything.
    gov_log "governance-guard" "BLOCK: decision body returned $_gov_rc, which is neither allow nor block (fail-closed)"
    echo "[governance-guard] BLOCKED: the guard's decision returned an unexpected status ($_gov_rc)." >&2
    exit 2 ;;
esac
