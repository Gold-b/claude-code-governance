#!/usr/bin/env bash
# pii-gate-pretooluse.sh — PreToolUse BLOCKING gate that runs check-no-pii.sh against the
# content a write is ABOUT to commit, for the files that can reach the public bundle.
#
# WHY A WRAPPER AND NOT check-no-pii.sh DIRECTLY
# ----------------------------------------------
# Three reasons, each of which would make a direct registration inert or hated:
#
#  1. TIMING. PreToolUse fires BEFORE the write lands. Pointing the scanner at
#     tool_input.file_path scans the OLD bytes — for a Write to a new file it scans a path
#     that does not exist yet, and check-no-pii.sh skip_file() returns "clean" for a missing
#     path. The gate would report PASS on every new leak ever created. So this wrapper
#     extracts the PENDING text (Write.content / Edit.new_string / MultiEdit.edits[].
#     new_string / NotebookEdit.new_source) and scans THAT.
#
#  2. SCOPE. Only files under ~/.claude/hooks/ and ~/.claude/skills/ are published by the
#     governance sync, so only those are gated. Scanning every file the user edits anywhere
#     would tax unrelated work for no security benefit, and a taxed gate gets removed.
#
#  3. COST. Measured on this machine 2026-09-01: check-no-pii.sh costs ~2.3 s of fixed
#     start-up plus ~10.4 s PER FILE — it spawns ~20 greps per file and process spawn here
#     costs ~0.5 s. (The task brief said ~2.5 s per file; that is optimistic by 5x. Measure,
#     do not assume.) 12.7 s on every hook edit is exactly the tax that gets a gate commented
#     out, so a cheap OVER-APPROXIMATING pre-filter runs first: one grep with the union of
#     the scanner RE_* regexes, read out of check-no-pii.sh at runtime rather than copied
#     here (a copy would rot silently). Union match => run the authoritative scanner.
#     No union match => nothing can possibly hit, allow. Measured: 0.2 s on a clean hook file.
#     The union is a SUPERSET of the rule set by construction, and if extraction yields
#     anything less than the full declared rule table the pre-filter is ABANDONED and the
#     full scanner runs. The fast path is taken only when it is provably safe.
#
# BASENAME IS PRESERVED into the scratch copy on purpose: check-no-pii.sh exempts the
# machine-local files (.governance-local.env, .governance-mirrors, .governance-pii-denylist,
# .pii-names, .wa-bridge.json) BY BASENAME, and those files hold real values legitimately.
# Verified empirically 2026-09-01: all five scan 0 files / rc=0 with a live-shaped IL mobile
# in them, while the same bytes in normal.md give rc=2.
#
# EXIT CODES (PreToolUse contract)
#   0  allowed          — out of scope, no pending text, or scanned clean
#   2  BLOCKED          — the pending content carries a real value; stderr goes to the agent
#   1  gate malfunction — NOT blocking, but stderr is surfaced. Chosen over a silent exit 0
#      deliberately: a broken gate must not brick the workflow, but it must also not pretend
#      to be a gate. Loud and open, never quiet and open.
#
# KILL SWITCHES
#   GOV_PII_GATE=0        disable just this gate
#   GOVERNANCE_HOOKS=0    disable the whole governance hook family
set +e
umask 077

[ "${GOV_PII_GATE:-1}" = "0" ] && exit 0
if [ "${GOVERNANCE_HOOKS:-1}" = "0" ]; then [ "${GOV_BYPASS_QUIET:-0}" = "1" ] || echo "[governance] GOVERNANCE_HOOKS=0 — bypassing pii-gate (PreToolUse PII block is OFF). (GOV_BYPASS_QUIET=1 to mute)" >&2; exit 0; fi

PAYLOAD="$(cat 2>/dev/null)"
[ -n "$PAYLOAD" ] || exit 0

# Zero-spawn scope pre-filter, deliberately the FIRST thing after reading stdin: every
# in-scope path contains ".claude", so if the whole payload does not, no file_path inside it
# can be in scope. This is the path taken by essentially every edit the user ever makes, so
# nothing that costs a subshell (dirname/pwd, command -v, mktemp) may run above this line.
# B9: also let repo-bundle writes through. The checkout dir "claude-code-governance" has NO
# ".claude" substring, so a write straight into its bundle/ used to fast-exit here, ungated.
# The slug is the PUBLIC repo name (not an identity), safe to bake in; the parser still decides
# scope by resolving GOV_REPO_PATH, so this only widens the over-approximating prefilter.
case "$PAYLOAD" in *.claude*|*claude-code-governance*) ;; *) exit 0 ;; esac

GOV_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
SCANNER="${GOV_PII_SCANNER:-$HOME/.claude/hooks/governance/check-no-pii.sh}"
# B10: announce a scanner override — a silent GOV_PII_SCANNER swap could disable this write gate.
[ -n "${GOV_PII_SCANNER:-}" ] && { [ "${GOV_BYPASS_QUIET:-0}" = "1" ] || echo "[governance] GOV_PII_SCANNER override active — PreToolUse PII gate is using $GOV_PII_SCANNER instead of the built-in check-no-pii.sh. (GOV_BYPASS_QUIET=1 to mute)" >&2; }
[ -f "$SCANNER" ] || SCANNER="$GOV_DIR/check-no-pii.sh"

PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done
if [ -z "$PY" ]; then
  echo "pii-gate: MALFUNCTION - no python on PATH, cannot read the pending write. Gate is OPEN." >&2
  exit 1
fi

TMPD="$(mktemp -d 2>/dev/null)" || TMPD=""
if [ -z "$TMPD" ] || [ ! -d "$TMPD" ]; then
  echo "pii-gate: MALFUNCTION - no writable temp dir. Gate is OPEN." >&2
  exit 1
fi
trap 'rm -rf "$TMPD" 2>/dev/null' EXIT

PARSER="$GOV_DIR/pii-gate-parse.py"
if [ ! -f "$PARSER" ]; then
  echo "pii-gate: MALFUNCTION - parser missing at $PARSER. Gate is OPEN." >&2
  exit 1
fi

# Parse + materialise the pending text. Prints the real target path on success; prints
# nothing (exit 0) when out of scope or when there is no pending text to judge.
PARSED="$(printf '%s' "$PAYLOAD" | "$PY" "$PARSER" "$TMPD" 2>"$TMPD/py.err")"
PYRC=$?

if [ "$PYRC" -ne 0 ]; then
  echo "pii-gate: MALFUNCTION - could not read the hook payload (rc=$PYRC): $(head -c 300 "$TMPD/py.err" 2>/dev/null). Gate is OPEN." >&2
  exit 1
fi
[ -n "$PARSED" ] || exit 0
TARGET="${PARSED%%	*}"
PENDING="${PARSED#*	}"
if [ -z "$TARGET" ] || [ -z "$PENDING" ] || [ "$TARGET" = "$PENDING" ] || [ ! -f "$PENDING" ]; then
  echo "pii-gate: MALFUNCTION - parser returned an unusable result. Gate is OPEN." >&2
  exit 1
fi

# ---- Over-approximating pre-filter -------------------------------------------------------
# Built from the scanner OWN regex table so it cannot drift away from it. Abandoned (=> full
# scan) on any doubt: missing scanner, fewer rules than the table declares, an empty capture,
# or a grep error. Doubt costs 12 s; a wrong fast path costs a leak.
run_full=1
if [ -f "$SCANNER" ]; then
  RULE_VARS="$(grep -oE "^RE_[A-Z0-9_]+=" "$SCANNER" 2>/dev/null | sed "s/=\$//")"
  N_VARS="$(printf '%s\n' "$RULE_VARS" | grep -c 'RE_')"
  eval "$(grep -E "^RE_[A-Z0-9_]+='" "$SCANNER" 2>/dev/null)" 2>/dev/null
  UNION=""; ok=1
  for v in $RULE_VARS; do
    eval "val=\${$v}"
    [ -n "$val" ] || { ok=0; break; }
    if [ -z "$UNION" ]; then UNION="$val"; else UNION="$UNION|$val"; fi
  done
  # RULES= declares 18 shape rules; the RE_ table must supply all of them or we do not trust it.
  [ "$N_VARS" -ge 18 ] || ok=0
  if [ "$ok" = "1" ] && [ -n "$UNION" ]; then
    # The two machine-local literal lists are part of the rule set (NAME_DENY, DENY). They
    # are compiled to an ESCAPED ALTERNATION and matched with -E, exactly as _compile_list()
    # in the scanner does -- NOT with `grep -iFf`, which SIGABRTs (rc 134) on this machine's
    # git-bash grep for the very name list in use. That crash was found while proving this
    # gate: it had been silently landing in the "no literal hit" branch, i.e. failing OPEN.
    # Hence the rc handling below: anything that is not a clean 0/1 counts as a candidate.
    PATF="$TMPD/.patterns"
    for lf in "${GOV_PII_NAMES:-$HOME/.claude/.pii-names}" \
              "${GOV_PII_DENYLIST:-$HOME/.claude/.governance-pii-denylist}"; do
      [ -f "$lf" ] && sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$lf" 2>/dev/null >> "$PATF"
    done
    lit_hit=0
    if [ -s "$PATF" ]; then
      LIT_ALT="$(sed -e 's/[][\.^$*+?(){}|\\]/\\&/g' "$PATF" 2>/dev/null | paste -sd'|' - 2>/dev/null)"
      if [ -n "$LIT_ALT" ]; then
        ( grep -qiE "\\b(${LIT_ALT})\\b" -- "$PENDING" ) 2>/dev/null
        case $? in
          1) lit_hit=0 ;;
          *) lit_hit=1 ;;   # 0 = hit, >1 = grep error -> assume hit, scan for real
        esac
      else
        lit_hit=1           # a non-empty list we failed to compile -> do not trust the fast path
      fi
    fi
    if [ "$lit_hit" = "0" ]; then
      ( grep -qE "$UNION" -- "$PENDING" ) 2>/dev/null
      case $? in
        1) run_full=0 ;;   # provably nothing to find
        *) run_full=1 ;;   # 0 = candidate, >1 = grep error -> let the scanner decide
      esac
    fi
  fi
fi

[ "$run_full" = "0" ] && exit 0

if [ ! -f "$SCANNER" ]; then
  echo "pii-gate: MALFUNCTION - scanner not found at $SCANNER. Gate is OPEN." >&2
  exit 1
fi

OUT="$(GOVERNANCE_HOOKS=1 bash "$SCANNER" "$PENDING" 2>&1)"
RC=$?
# Report against the file the human is actually writing, not the scratch copy.
# Bash substring replacement, NOT sed: TARGET is a Windows path, and sed reads a backslash on
# BOTH sides as an escape -- a backslash-U in a replacement is GNU sed uppercase-conversion,
# which mangled a real target path into an all-caps run the first time this gate fired live.
OUT="${OUT//"$PENDING"/"$TARGET"}"

if [ "$RC" = "2" ]; then
  {
    echo "BLOCKED by pii-gate: this write puts a real value into a file the governance sync PUBLISHES."
    echo "Target: $TARGET"
    echo "(line numbers are relative to the text this write introduces, not to the whole file)"
    echo
    printf '%s\n' "$OUT"
    echo
    echo "Fix the DATA, not the scanner: leave a placeholder or an env lookup in the tracked file and"
    echo "put the real value in a machine-local file (~/.claude/.governance-local.env,"
    echo "~/.claude/.pii-names, ~/.claude/.wa-bridge.json). One deliberate hit may carry"
    echo "  pii-allow: <reason>   on the same line."
    echo "Kill switch (last resort, and say so out loud): GOV_PII_GATE=0"
  } >&2
  exit 2
fi

if [ "$RC" != "0" ]; then
  echo "pii-gate: MALFUNCTION - scanner exited $RC (expected 0 or 2). Gate is OPEN. Output:" >&2
  printf '%s\n' "$OUT" | head -20 >&2
  exit 1
fi
exit 0
