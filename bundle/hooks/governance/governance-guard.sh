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
FILE_PATH=$(printf '%s' "$PAYLOAD" | python3 -c '
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
  exit 2
fi

# Verify token is still within TTL.
# Read the token file via cat + pipe to Python — avoids Git-Bash /c/... path
# issues that occur when Python tries to open the path directly on Windows.
NOW_EPOCH=$(date +%s)
EXPIRES_EPOCH=$(cat "$TOKEN_FILE" 2>/dev/null | python3 -c '
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
  exit 2
fi

# Token is valid — allow the write.
REMAINING=$(($EXPIRES_EPOCH - $NOW_EPOCH))
gov_log "governance-guard" "ALLOW: token valid, ${REMAINING}s remaining"
exit 0
