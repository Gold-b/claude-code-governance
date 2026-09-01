#!/usr/bin/env bash
# test-close-report.sh — prove close-report.sh can only say what is in a file.
#
# THE CLAIM UNDER TEST. close-report.sh exists because a closing summary is the LAST action of a
# turn: anything identified while writing it has no tool call after it and can only become prose.
# The cure is inversion — generate the summary FROM the canonical files — and its whole value
# rests on ONE property:
#
#     a claim that is not in a canonical file has no channel into the report.
#
# A property is not proven by a report that happens to look right. It is proven by a CONTROL THAT
# MUST FAIL, run in the same invocation as the positive case (gotcha #351 / B22: without one,
# "clean" and "the check never ran" are the same output — measured three times in one hour, once
# by a `grep -lFi` that aborted with SIGABRT on this very shell and printed MISSING fifteen times).
#
# So sections 3-5 below are a matched pair applied to ONE token:
#   3. the token sits in a file the report does not read  -> it MUST NOT render
#   4. the token is moved into a canonical file           -> it MUST render
#   5. every count the report states is re-derived after a mutation -> it MUST change
# Test 4 is what makes test 3 mean anything: it proves the absence in 3 was a decision and not a
# dead harness. Test 5 is what stops the whole suite from passing against a report that prints a
# constant.
#
# Usage: bash ~/.claude/hooks/governance/tests/test-close-report.sh [--keep]
# Exit:  0 all green · 1 something failed.  Touches NOTHING outside its sandbox (HOME included).
set +e
umask 077

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
SUT="$HOOKS/close-report.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n'  "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; fail=$((fail+1)); }

if [ ! -f "$SUT" ]; then echo "close-report.sh not found at $SUT"; exit 1; fi

# Sandbox NOT under /tmp or */temp/*: several governance hooks deliberately skip those paths, so a
# sandbox there would make this suite vacuous in exactly the way it exists to prevent.
SBX="$HOME/.gov-selftest/close-report-$$"
SHOME="$SBX/home"
PROJ="$SBX/proj"
OUTSIDE="$SBX/proj/scratch"
mkdir -p "$SHOME/.claude/logs" "$PROJ/docs/context" "$PROJ/Plans" "$PROJ/MDs" "$OUTSIDE" 2>/dev/null
cleanup() { [ "$KEEP" = 1 ] && { echo "sandbox kept: $SBX"; return; }; rm -rf "$SBX" 2>/dev/null; }
trap cleanup EXIT

# The one token this suite is built around. Distinctive enough that a match cannot be a coincidence.
TOKEN="UNRECORDED-CLAIM-ZQX7"

# ── Fixture: a governed project with a known, deliberately small record ──────────────────────
printf '# Sandbox project\n\n## Canonical Working Copy\n\n- %s\n' "$PROJ" > "$PROJ/CLAUDE.md"
printf -- '---\ntype: manifest\n---\n\n- **canonical_working_copy = `%s`**\n' "$PROJ" > "$PROJ/docs/context/CONTEXT-MANIFEST.md"
printf 'SOURCE\n' > "$PROJ/.governance-role"
# Pretty-printed on purpose: a line-1 read returns "{" and the report used to print `version.json={`.
printf '{\n  "version": "9.9.9",\n  "channel": "stable"\n}\n' > "$PROJ/version.json"

cat > "$PROJ/docs/context/HANDOFF.md" <<'EOF'
---
status: active
type: pointer
points_to: ../../MDs/HANDOFF-sandbox.md
created_at: 2026-01-01
superseded_by: ~
consumed_items:
  - "SANDBOX-POINTER-ENTRY: the newest recorded session entry."
---
# Handoff (Canonical Pointer)
> This file is a pointer, not the source.
EOF

cat > "$PROJ/MDs/HANDOFF-sandbox.md" <<'EOF'
---
status: active
created_at: 2026-01-02
supersedes: MDs/HANDOFF-old.md
---
# Session Handoff — sandbox

## TL;DR

SANDBOX-TLDR-LINE recorded in the handoff.

## Next
EOF

printf '# PLAN\n\n> **Project version:** v9.9.9 — SANDBOX-PLAN-VERSION\n\n## Milestone Log\n\n| 2026-01-02 | SANDBOX-MILESTONE-ROW |\n' > "$PROJ/Plans/PLAN.md"
printf '# MEMORY\n\n## Active Summary\n\n- **2026-01-02 — SANDBOX-MEMORY-ENTRY.**\n' > "$PROJ/docs/context/MEMORY.md"
printf -- '---\ntotal_entries: 2\n---\n\n# Gotchas\n\n### 1. first\n\n### 2. second\n' > "$PROJ/docs/context/GOTCHAS.md"

# THE CONTROL, planted where a report must never look: a scratch note inside the project. This is
# the shape of the real failure — a thing the session decided and wrote down somewhere that is not
# the record.
printf 'note to self: %s — decided during the write-up, never filed.\n' "$TOKEN" > "$OUTSIDE/notes.md"

git -C "$PROJ" init -q 2>/dev/null
git -C "$PROJ" config user.email "you@example.com" 2>/dev/null
git -C "$PROJ" config user.name  "Operator One" 2>/dev/null
git -C "$PROJ" add -A 2>/dev/null
git -C "$PROJ" commit -qm "sandbox baseline" 2>/dev/null

run_report() {   # -> $OUT (report text), $RC
  OUT="$(env HOME="$SHOME" USERPROFILE="$SHOME" GOV_NOTIFY=0 GOV_WHATSAPP=0 \
        bash "$SUT" --project "$PROJ" "$@" 2>&1 </dev/null)"
  RC=$?
}

has()  { case "$OUT" in *"$1"*) ok "$2" ;; *) bad "$2" "expected the report to contain [$1]" ;; esac; }
hasnt(){ case "$OUT" in *"$1"*) bad "$2" "the report contains [$1] and MUST NOT" ;; *) ok "$2" ;; esac; }

echo "=== 1. the report renders, and renders what IS in the files ==="
run_report
[ "$RC" = 0 ] && ok "exit 0" || bad "exit 0" "rc=$RC"
has "SANDBOX-TLDR-LINE"       "handoff TL;DR is read out of the handoff"
has "SANDBOX-POINTER-ENTRY"   "the pointer's newest consumed_items entry is read"
has "SANDBOX-PLAN-VERSION"    "PLAN.md version line is read"
has "SANDBOX-MILESTONE-ROW"   "PLAN.md newest milestone row is read"
has "SANDBOX-MEMORY-ENTRY"    "MEMORY.md newest dated entry is read"
has "version.json=9.9.9"      "version comes from the JSON value, not line 1 ('{')"
has "active handoff files"    "the active-handoff count is stated"

echo
echo "=== 2. no crash noise (the count_lines / integer-expression class) ==="
hasnt "integer expression expected" "no 'integer expression expected' anywhere"
hasnt "command not found"           "no 'command not found' anywhere"
hasnt "unbound variable"            "no 'unbound variable' anywhere"

echo
echo "=== 3. NEGATIVE CONTROL — a claim that is not in the record cannot appear ==="
# Same token, three channels a summary could smuggle a claim through. All must be dead.
hasnt "$TOKEN" "a claim in a scratch file inside the project does NOT render"
OUT_ENV="$(env HOME="$SHOME" USERPROFILE="$SHOME" GOV_CLOSE_REPORT_NOTE="$TOKEN" CLAUDE_SUMMARY="$TOKEN" \
           bash "$SUT" --project "$PROJ" 2>&1 </dev/null)"
case "$OUT_ENV" in *"$TOKEN"*) bad "a claim passed in the ENVIRONMENT does NOT render" "the report echoed \$GOV_CLOSE_REPORT_NOTE" ;;
                   *) ok "a claim passed in the ENVIRONMENT does NOT render" ;; esac
OUT_STDIN="$(printf 'I will also add %s later.\n' "$TOKEN" | env HOME="$SHOME" USERPROFILE="$SHOME" \
             bash "$SUT" --project "$PROJ" 2>&1)"
case "$OUT_STDIN" in *"$TOKEN"*) bad "a claim fed on STDIN does NOT render" "the report echoed its stdin" ;;
                     *) ok "a claim fed on STDIN does NOT render" ;; esac

echo
echo "=== 4. THE PAIR — the same token, once it IS in a canonical file, MUST render ==="
# Without this, test 3 proves nothing: "absent" and "the harness never ran" print identically.
printf -- '- **2026-01-03 — %s is now filed in the record.**\n' "$TOKEN" >> "$PROJ/docs/context/MEMORY.md"
run_report
has "$TOKEN" "the same token renders once written into docs/context/MEMORY.md"
# ...and put the record back, so later assertions describe the fixture as declared.
printf '# MEMORY\n\n## Active Summary\n\n- **2026-01-02 — SANDBOX-MEMORY-ENTRY.**\n' > "$PROJ/docs/context/MEMORY.md"

echo
echo "=== 5. LOAD-BEARING — every stated count must move when the record moves ==="
run_report
case "$OUT" in *"pointers excluded): 1"*) ok "baseline: exactly 1 active handoff" ;;
               *) bad "baseline: exactly 1 active handoff" "$(printf '%s' "$OUT" | grep -m1 'pointers excluded')" ;; esac
cat > "$PROJ/MDs/HANDOFF-second.md" <<'EOF'
---
status: active
created_at: 2026-01-03
---
# Second handoff
EOF
run_report
case "$OUT" in *"pointers excluded): 2"*) ok "a second active handoff moves the count to 2" ;;
               *) bad "a second active handoff moves the count to 2" "count did not change — the report may be printing a constant" ;; esac
has "more than one active handoff" "and the dual-source-of-truth warning fires"
rm -f "$PROJ/MDs/HANDOFF-second.md"

# The pointer must NOT be counted as a second handoff: that false positive escalates every healthy
# close and is the exact bug the /context-governance dual-handoff check had.
run_report
case "$OUT" in *"pointers excluded): 1"*) ok "the pointer itself is not counted as a handoff" ;;
               *) bad "the pointer itself is not counted as a handoff" ;; esac

# total_entries drift must be caught, not restated.
has "total_entries declared 2, measured 2 — agree" "gotcha count agrees when it agrees"
sed -i 's/^total_entries: 2$/total_entries: 99/' "$PROJ/docs/context/GOTCHAS.md"
run_report
has "DISAGREE" "a declared count that disagrees with reality is flagged"
sed -i 's/^total_entries: 99$/total_entries: 2/' "$PROJ/docs/context/GOTCHAS.md"

echo
echo "=== 6. git state is measured, not assumed ==="
run_report
has "working tree clean" "a clean tree is reported clean"
has "NO UPSTREAM"        "a repo with no upstream says so instead of claiming 'pushed'"
printf 'dirty\n' > "$PROJ/uncommitted.txt"
run_report
has "DIRTY (1 path(s))"  "an uncommitted file makes the tree DIRTY"
has "uncommitted.txt"    "and the dirty path is named"
rm -f "$PROJ/uncommitted.txt"

echo
echo "=== 7. a missing record is REPORTED, never silently skipped ==="
mv "$PROJ/docs/context/MEMORY.md" "$PROJ/docs/context/MEMORY.hidden" 2>/dev/null
run_report
has "docs/context/MEMORY.md: ABSENT" "an absent canonical file is named as absent"
mv "$PROJ/docs/context/MEMORY.hidden" "$PROJ/docs/context/MEMORY.md" 2>/dev/null

echo
echo "=== 8. the report is PERSISTED, so it survives the turn that printed it ==="
OUTF="$SBX/report.md"
run_report --out "$OUTF"
if [ -s "$OUTF" ] && grep -q 'SANDBOX-TLDR-LINE' "$OUTF"; then ok "--out writes the same report to a file"
else bad "--out writes the same report to a file" "missing or empty: $OUTF"; fi

echo
echo "=== 9. it never blocks: a report is not a gate ==="
rm -rf "$PROJ/.git"
run_report
[ "$RC" = 0 ] && ok "a project with no git repo still exits 0" || bad "a project with no git repo still exits 0" "rc=$RC"
has "not a git repository" "and says the repo is missing rather than inventing a range"

echo
echo "============================================================"
printf '[test-close-report] pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -gt 0 ] && exit 1
exit 0
