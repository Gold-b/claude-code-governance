#!/usr/bin/env bash
# protected-list-consistency.test.sh — Open-Problem #101 F.18, updated for A.1.
#
# HISTORY. The set of "protected governance documents" lived in TWO places that drifted:
#   * governance-guard.sh  PROTECTED_PATTERNS                 — the list actually ENFORCED
#   * commit-task-success.sh "protected_files_allowed"        — an informational copy in the token
# The second had grown two entries the first never enforced ("memory/MEMORY.md", which the guard
# must NEVER protect, and "Plans/PLAN.md"). F.18 corrected the copy by hand and this test guarded
# the two lists against drifting apart again.
#
# A.1 removed the copies: the list lives once in _common.sh (GOV_PROTECTED_PATTERNS /
# gov_protected_patterns / gov_is_protected_doc), the guard DECIDES with it, and the token PRINTS
# it. So this test's job changed from "are the two lists equal?" to "has a second copy come back?"
# — which is the failure mode that produced F.18 in the first place.
#
# The behavioural end-to-end check (mint a token, compare its array to what the guard enforces)
# lives in tests/test-protected-doc-predicate.sh, which drives the real hook.
#
# Run: bash protected-list-consistency.test.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$DIR/_common.sh"
GG="$DIR/governance-guard.sh"
CT="$DIR/commit-task-success.sh"

for f in "$COMMON" "$GG" "$CT"; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done

python3 - "$COMMON" "$GG" "$CT" <<'PY'
import sys, re

common, gg, ct = sys.argv[1], sys.argv[2], sys.argv[3]
read = lambda p: open(p, encoding="utf-8").read()
ok = True

# ── 1. The single definition must exist and be non-empty ────────────────────
cs = read(common)
m = re.search(r'GOV_PROTECTED_PATTERNS="(.*?)"', cs, re.S)
if not m:
    print("  FAIL  _common.sh no longer defines GOV_PROTECTED_PATTERNS — the single list is gone")
    ok = False
    patterns = []
else:
    patterns = [p.strip() for p in m.group(1).split("\n") if p.strip()]
    if not patterns:
        print("  FAIL  GOV_PROTECTED_PATTERNS is empty — the guard would protect nothing")
        ok = False
    else:
        print(f"  PASS  one definition in _common.sh ({len(patterns)} entries): {sorted(patterns)}")

for helper in ("gov_protected_patterns", "gov_is_protected_doc"):
    if f"{helper}()" not in cs:
        print(f"  FAIL  _common.sh does not define {helper}")
        ok = False

# ── 2. No SECOND copy may come back ─────────────────────────────────────────
gs = read(gg)
if re.search(r'PROTECTED_PATTERNS=\(', gs):
    print("  FAIL  governance-guard.sh has re-inlined its own PROTECTED_PATTERNS array — that is the")
    print("        exact drift F.18 fixed. Use gov_is_protected_doc from _common.sh.")
    ok = False
elif "gov_is_protected_doc" not in gs:
    print("  FAIL  governance-guard.sh neither inlines a list NOR calls gov_is_protected_doc — it")
    print("        cannot be deciding anything")
    ok = False
else:
    print("  PASS  governance-guard.sh decides via the shared predicate")

ts = read(ct)
hardcoded = re.search(r'"protected_files_allowed"\s*:\s*\[\s*"', ts)
if hardcoded:
    print("  FAIL  commit-task-success.sh has re-inlined a literal protected_files_allowed list —")
    print("        it must be DERIVED from gov_protected_patterns so it cannot describe a different set")
    ok = False
elif "gov_protected_patterns" not in ts:
    print("  FAIL  commit-task-success.sh does not derive its list from gov_protected_patterns")
    ok = False
else:
    print("  PASS  commit-task-success.sh derives its advertised list from the same source")

# ── 3. The two entries F.18 removed must never come back ────────────────────
for bad in ("memory/MEMORY.md", "Plans/PLAN.md"):
    if bad in patterns:
        print(f"  FAIL  '{bad}' is back in the enforced list.")
        if bad == "memory/MEMORY.md":
            print("        User-level Claude auto-memory MUST stay writable on every session.")
        ok = False

sys.exit(0 if ok else 1)
PY
rc=$?
if [ $rc -eq 0 ]; then echo "PASS"; exit 0; else echo "FAILED"; exit 1; fi
