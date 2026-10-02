#!/usr/bin/env bash
# test-hook-fixes-40.sh - the four fixes of OPEN-PROBLEMS #40 (2026-10-02), each in both directions, each with a
# negative control that runs the OLD snippet and shows the defect:
#   (1) gov_handoff_current  - end-session.sh Check 3: a docs/context/HANDOFF.md that IS the active handoff
#   (2) gov_indent_lines     - close-completeness.sh: `sed 's|^|<literal newline>   |'` is "unterminated `s' command"
#   (3) gov_count_entries    - GOTCHAS-count: ONE number ("0\n0" from `grep -c || echo 0`), `## #1 - x` headings counted
#   (4) gov_sed_inplace_if_changed - sync-governance.sh: no rewrite (mtime) when the expression matches nothing
# Sandboxed HOME. Usage: bash tests/test-hook-fixes-40.sh   (HOOKS=<dir> for another copy)
HOOKS="${HOOKS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
exec </dev/null
SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT
export HOME="$SBX/home"; mkdir -p "$HOME/.claude/logs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s  -- %s\n' "$1" "$2"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in [$(printf '%s' "$2" | head -c 200)]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "[$3] present in [$(printf '%s' "$2" | head -c 200)]" ;; *) ok "$1" ;; esac; }

# shellcheck disable=SC1091
. "$HOOKS/_common.sh" >/dev/null 2>&1
for fn in gov_handoff_current gov_indent_lines gov_count_entries gov_sed_inplace_if_changed; do
  type "$fn" >/dev/null 2>&1 && ok "helper defined: $fn" || bad "helper defined: $fn" "_common.sh does not define it"
done

echo "== 1. gov_handoff_current (end-session.sh Check 3)"
P="$SBX/proj"; mkdir -p "$P/docs/context"
H="$P/docs/context/HANDOFF.md"
hand() { printf '%s\n' "$@" > "$H"; }
hand '---' 'status: active' 'created_at: 2026-10-01' '---' '# Handoff v1.4.37' 'content'
gov_handoff_current "$P" 1.4.37; is "content-bearing active handoff naming the version -> current" "$?" "0"
hand '---' 'status: consumed' '---' '# Handoff v1.4.37'
gov_handoff_current "$P" 1.4.37; is "status: consumed -> not current" "$?" "1"
hand '---' 'status: active' 'points_to: MDs/HANDOFF-v1.4.37.md' '---' '# Handoff v1.4.37'
gov_handoff_current "$P" 1.4.37; is "a pointer (points_to:) is not the content -> not current here" "$?" "1"
hand '---' 'status: active' 'type: pointer' '---' '# Handoff v1.4.37'
gov_handoff_current "$P" 1.4.37; is "type: pointer -> not current here" "$?" "1"
hand '---' 'status: active' '---' '# Handoff v1.4.36 only'
gov_handoff_current "$P" 1.4.37; is "active but names another version -> not current" "$?" "1"
hand '---' 'status: active' '---' '# Handoff v1.4.370'
gov_handoff_current "$P" 1.4.37; is "v1.4.370 is not v1.4.37 (boundary) -> not current" "$?" "1"
hand '---' 'status: active' '---' '# Handoff v1.4.37.'
gov_handoff_current "$P" 1.4.37; is "a sentence-final dot after the version still counts" "$?" "0"
hand '---' 'status: active' '---' '# Handoff v1.4.37'
gov_handoff_current "$P" ""; is "an empty version -> not current" "$?" "1"
rm -f "$H"; gov_handoff_current "$P" 1.4.37; is "no HANDOFF.md -> not current" "$?" "1"
grep -n 'gov_handoff_current "$PROJECT_ROOT" "$VJ_VER"' "$HOOKS/end-session.sh" >/dev/null 2>&1 \
  && ok "end-session.sh Check 3 calls the helper with the project root and version" || bad "end-session.sh wiring" "no call found"
n1=$(grep -n 'gov_handoff_current "\$PROJECT_ROOT"' "$HOOKS/end-session.sh" | head -1 | cut -d: -f1)
n2=$(grep -n 'No handoff found for v' "$HOOKS/end-session.sh" | head -1 | cut -d: -f1)
[ -n "$n1" ] && [ -n "$n2" ] && [ "$n1" -lt "$n2" ] && ok "  ... and before the 'No handoff found' issue is added" || bad "wiring order" "call line [$n1] must come before the issue line [$n2]"

echo "== 2. gov_indent_lines (close-completeness.sh note)"
out=$(printf 'a\n\nb\n' | gov_indent_lines 2>&1)
is "each non-empty line becomes a newline + 8 blanks + the line (and no error text)" "$out" "$(printf '\n        a\n        b')"
is "an empty input prints nothing" "$(printf '' | gov_indent_lines 2>&1)" ""
old=$(printf 'a\nb\n' | sed 's|^|
   |' 2>&1)
has "negative control: the OLD sed with a literal newline in the replacement is an error" "$old" "unterminated"
grep -q "gov_indent_lines" "$HOOKS/close-completeness.sh" && ok "close-completeness.sh uses it" || bad "close-completeness.sh wiring" ""
n=$(grep -c "sed 's|^|$" "$HOOKS/close-completeness.sh"); is "close-completeness.sh no longer has the sed with a trailing literal newline" "${n:-0}" "0"

echo "== 3. gov_count_entries (GOTCHAS-count)"
G="$SBX/gotchas.md"
printf '%s\n' '# Gotchas' '1. **bare list item**' '### 7. heading' '## 36. heading' '## #1 - hash heading' '## #2 — dash heading' 'text 5. not an entry' '- 9. bullet' > "$G"
is "counts the five entry shapes (bare, ###, ##, ## #N -, ## #N em dash)" "$(gov_count_entries "$G")" "5"
printf 'nothing here\n' > "$SBX/none.md"
is "no match prints ONE number: 0" "$(gov_count_entries "$SBX/none.md")" "0"
is "a missing file prints 0" "$(gov_count_entries "$SBX/absent.md")" "0"
oldn=$(grep -cE '^(#{1,6} )?[0-9]+\.' "$SBX/none.md" 2>/dev/null || echo "0")
is "negative control: the OLD pattern + '|| echo 0' prints two lines on no match" "$(printf '%s' "$oldn" | wc -l | tr -d ' ')" "1"
olds=$(grep -cE '^(#{1,6} )?[0-9]+\.' "$G")
is "negative control: the OLD regex misses the '## #N' headings (3 of 5)" "$olds" "3"
grep -q 'gov_count_entries' "$HOOKS/close-completeness.sh" && grep -q 'gov_count_entries' "$HOOKS/sync-governance.sh" && ok "close-completeness.sh and sync-governance.sh use it" || bad "count wiring" ""
n=$(grep -cE "grep -cE .*\|\| echo" "$HOOKS/close-completeness.sh" "$HOOKS/sync-governance.sh" | awk -F: '{s+=$2} END{print s+0}')
is "no 'grep -cE ... || echo' left in those two hooks" "$n" "0"
re_cr=$(sed -n "s/^[[:space:]]*ENTRY_RE='\([^']*\)'.*/\1/p" "$HOOKS/close-report.sh" | head -1)
is "close-report.sh counts with the same shape as GOV_ENTRY_RE" "$re_cr" "$GOV_ENTRY_RE"

echo "== 4. gov_sed_inplace_if_changed (sync-governance.sh update_file)"
F="$SBX/doc.md"; printf 'version 1.0\nother\n' > "$F"; touch -d '2020-01-01 00:00:00' "$F"; m0=$(stat -c %Y "$F")
gov_sed_inplace_if_changed "$F" 's/zzz/y/'; rc=$?
is "no match: rc 1 (unchanged)" "$rc" "1"
is "no match: the mtime did NOT move" "$(stat -c %Y "$F")" "$m0"
is "no match: the content is the same" "$(cat "$F")" "$(printf 'version 1.0\nother')"
gov_sed_inplace_if_changed "$F" 's/1\.0/1.1/'; rc=$?
is "a match: rc 0 (changed)" "$rc" "0"
is "a match: the content changed" "$(head -1 "$F")" "version 1.1"
[ "$(stat -c %Y "$F")" != "$m0" ] && ok "a match: the mtime moved" || bad "a match: mtime" "unchanged"
cp "$F" "$SBX/keep.md"; gov_sed_inplace_if_changed "$F" 's/(/x/'; rc=$?
is "a bad expression: rc 1 and the file is intact" "$rc/$(cmp -s "$F" "$SBX/keep.md" && echo same || echo changed)" "1/same"
touch -d '2020-01-01 00:00:00' "$F"; m1=$(stat -c %Y "$F"); sed -i 's/zzz/y/' "$F"
[ "$(stat -c %Y "$F")" != "$m1" ] && ok "negative control: the OLD 'sed -i' with no match DOES move the mtime" || bad "negative control: sed -i mtime" "unchanged on this platform"
n=$(grep -c 'sed -i "$sed_expr" "$file"' "$HOOKS/sync-governance.sh"); is "sync-governance.sh no longer calls sed -i unconditionally" "${n:-0}" "0"
grep -q 'gov_sed_inplace_if_changed "$file" "$sed_expr"' "$HOOKS/sync-governance.sh" && ok "update_file uses the helper" || bad "update_file wiring" ""

echo
echo "hook-fixes-40 selftest: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
