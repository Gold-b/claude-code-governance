#!/usr/bin/env bash
# test-protected-doc-predicate.sh — #101 A.1
#
# The protected-doc predicate decides whether an Edit/Write is BLOCKED without a success token. It
# is the single most consequential rule in the governance hooks, and until this file it had ZERO
# coverage: the #102 collision battery never invokes governance-guard.sh at all.
#
# This suite is BEHAVIOURAL on both halves:
#   1. the predicate itself (gov_is_protected_doc), including the paths that must NOT be protected;
#   2. governance-guard.sh END TO END, driven with a real hook payload, asserting the exit code —
#      because a predicate that is right inside a guard that never calls it is worth nothing
#      (gotcha #309: test the ROUTE, not the helper).
#   3. the success token's advertised list is IDENTICAL to what the guard enforces — the drift F.18
#      corrected by hand and A.1 makes structurally impossible.
#
# Run: bash tests/test-protected-doc-predicate.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../_common.sh
. "$DIR/_common.sh"

PASS=0
FAIL=0
FAILED=""

ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; echo "FAIL: $1"; echo "      $2"; }

expect_protected() {
  local path="$1" want_pat="$2" out
  if out=$(gov_is_protected_doc "$path"); then
    if [ -n "$want_pat" ] && [ "$out" != "$want_pat" ]; then
      bad "protected: $path" "matched '$out', expected '$want_pat'"
    else
      ok "protected: $path (pattern '$out')"
    fi
  else
    bad "protected: $path" "predicate said NOT protected"
  fi
}

expect_not_protected() {
  local path="$1" out
  if out=$(gov_is_protected_doc "$path"); then
    bad "NOT protected: $path" "predicate matched '$out' — this file must stay writable"
  else
    ok "NOT protected: $path"
  fi
}

echo "── 1. the predicate ──────────────────────────────────────────────"

expect_protected "/c/repo/MDs/Open-Problems.md"            "MDs/Open-Problems.md"
expect_protected "/c/repo/MDs/HANDOFF-v1.2.4.md"         "MDs/HANDOFF-"
# NOTE (finding, not a regression): the pattern is the contiguous string "MDs/HANDOFF-", so an
# ARCHIVED handoff at MDs/archive/HANDOFF-*.md is NOT protected. That is the behaviour that has
# always shipped; A.1 extracted the rule without changing it. Widening it would protect a new
# file class across every hook at once, which is a governance decision for the owner, not a
# refactor. Pinned here so the current answer is explicit rather than assumed.
expect_not_protected "/c/repo/MDs/archive/HANDOFF-v1.2.3.md"
expect_protected "/c/repo/docs/context/GOTCHAS.md"         "docs/context/GOTCHAS.md"
expect_protected "/c/repo/docs/context/OPEN-PROBLEMS.md"   "docs/context/OPEN-PROBLEMS.md"
expect_protected "/c/repo/docs/context/HANDOFF.md"         "docs/context/HANDOFF.md"
expect_protected "/c/repo/docs/context/MEMORY.md"          "docs/context/MEMORY.md"

# Windows spellings are the same file.
expect_protected 'C:\repo\docs\context\GOTCHAS.md'         "docs/context/GOTCHAS.md"
expect_protected 'C:/repo/MDs/Open-Problems.md'            "MDs/Open-Problems.md"

echo "── 2. what must NOT be protected ─────────────────────────────────"

# The one that matters most: user-level Claude auto-memory MUST stay writable every session.
expect_not_protected "$HOME/.claude/projects/c--dev-example-project/memory/MEMORY.md"
expect_not_protected "$HOME/.claude/projects/c--dev-example-project/memory/project_x.md"
# Plans/PLAN.md was advertised by the token but never enforced by the guard.
expect_not_protected "/c/repo/Plans/PLAN.md"
expect_not_protected "/c/repo/admin/server.js"
expect_not_protected "/c/repo/README.md"
expect_not_protected "/c/repo/docs/context/CONVENTIONS.md"
expect_not_protected ""

echo "── 3. the guard, end to end ──────────────────────────────────────"

# A protected doc with NO token must be blocked (exit 2); an ordinary file must pass (exit 0).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# CODEX review (PR #3): run the whole end-to-end section under a TEMPORARY HOME.
# The earlier draft deleted the developer's live success token and kept the only backup inside
# $TMP, which the EXIT trap removes — an interrupt between the two lost the token outright. It also
# minted a real token against the real HOME, leaving a fictitious "success" in the PERMANENT audit
# history. Both hooks read $HOME at runtime, so a temporary HOME isolates them completely and the
# developer's state is never touched at all.
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/logs"
TOKEN="$HOME/.claude/logs/governance-success-token.json"

# A real SOURCE-role project root. gov_detect_role reads `.governance-role`, and for a path that
# does not exist it falls back to DEPLOYMENT — where the guard hard-blocks EVERY governance edit.
# Driving the guard at a synthetic path therefore proves the role gate and never reaches the token
# gate at all, which is the half this suite exists to cover.
# BUILD a SOURCE root instead of hunting for one. (CODEX round 3.)
#
# The previous version scanned the host for a usable project. On the author's machine it found one
# and reported 22/22; in a CLEAN CHECKOUT of this repository there is no root CLAUDE.md and no
# governed project root at all, so both end-to-end sections SKIPPED and the suite still exited 0 with 16
# passes. A suite that reports success while its consequential cases never ran is worse than one
# that fails — it is the same trap this file exists to catch elsewhere.
#
# So the root is CONSTRUCTED: CLAUDE.md (what gov_find_project_root looks for) and an explicit
# .governance-role of SOURCE. Nothing about the host matters any more, and there is no skip path —
# if the root cannot be built, that is a FAILURE.
SRC_ROOT="$TMP/srcroot"
mkdir -p "$SRC_ROOT/docs/context" "$SRC_ROOT/MDs" "$SRC_ROOT/admin" || true
printf '# Fixture project for the protected-doc predicate probe.\n' > "$SRC_ROOT/CLAUDE.md"
printf 'SOURCE\n' > "$SRC_ROOT/.governance-role"
if [ ! -f "$SRC_ROOT/CLAUDE.md" ] || [ ! -f "$SRC_ROOT/.governance-role" ]; then
  bad "fixture SOURCE root" "could not create $SRC_ROOT — the end-to-end cases cannot run"
  echo
  echo "$PASS passed, $FAIL failed"
  exit 1
fi

run_guard() {
  local file="$1"
  # Both the payload cwd AND the process's working directory point at the fixture root, so the
  # guard resolves the same project however it looks.
  ( cd "$SRC_ROOT" 2>/dev/null || exit 3
    printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"},"cwd":"%s"}' "$file" "$SRC_ROOT" \
      | bash "$DIR/governance-guard.sh" >/dev/null 2>&1 )
  echo $?
}

  rc=$(run_guard "$SRC_ROOT/docs/context/GOTCHAS.md")
  if [ "$rc" = "2" ]; then ok "guard BLOCKS a protected doc with no token (exit 2)"
  else bad "guard BLOCKS a protected doc with no token" "exit was $rc, expected 2"; fi

  rc=$(run_guard "$SRC_ROOT/admin/server.js")
  if [ "$rc" = "0" ]; then ok "guard ALLOWS an ordinary file (exit 0)"
  else bad "guard ALLOWS an ordinary file" "exit was $rc, expected 0"; fi

  rc=$(run_guard "$HOME/.claude/projects/c--dev-example-project/memory/MEMORY.md")
  if [ "$rc" = "0" ]; then ok "guard ALLOWS user-level auto-memory (must never be protected)"
  else bad "guard ALLOWS user-level auto-memory" "exit was $rc, expected 0"; fi

  # With a FRESH token the same protected write is allowed — the half that had no coverage.
  bash "$DIR/commit-task-success.sh" "protected-doc predicate probe" >/dev/null 2>&1
  rc=$(run_guard "$SRC_ROOT/docs/context/GOTCHAS.md")
  if [ "$rc" = "0" ]; then ok "guard ALLOWS a protected doc with a fresh token (exit 0)"
  else bad "guard ALLOWS a protected doc with a fresh token" "exit was $rc, expected 0"; fi

echo "── 4. the token cannot advertise a different list ────────────────"

if [ -f "$TOKEN" ]; then
  ADVERTISED=$(sed -n '/"protected_files_allowed": \[/,/\]/p' "$TOKEN" | tail -n +2 \
    | grep -oE '"[^"]+"' | tr -d '"' | sort)
  ENFORCED=$(gov_protected_patterns | sort)
  if [ "$ADVERTISED" = "$ENFORCED" ]; then
    ok "token list == enforced list"
  else
    bad "token list == enforced list" "$(printf 'advertised:\n%s\nenforced:\n%s' "$ADVERTISED" "$ENFORCED")"
  fi
  if grep -q '"protected_files_allowed_source": "_common.sh"' "$TOKEN"; then
    ok "token records where its list came from"
  else
    bad "token records where its list came from" "source marker missing or not _common.sh"
  fi
else
  bad "token written" "commit-task-success.sh produced no token file"
fi

# Nothing to restore: HOME was temporary, so the developer's token and audit history were
# never touched. The EXIT trap removes the whole directory.

echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then printf 'Failures:%b\n' "$FAILED"; exit 1; fi
exit 0
