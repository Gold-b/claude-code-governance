#!/usr/bin/env bash
# bench-bootstrap-gate.sh - time bootstrap-gate.sh per call against the PreToolUse hooks it sits beside.
#
# CLAUDE.md "Measure a fix on the path it protects, under load": a gate that slows every Edit/Bash
# call gets switched off. Prints median / p95 in ms per case, idle and (with --load) with one CPU
# burner per logical CPU running in parallel.
#
# Usage: bash ~/.claude/hooks/governance/tests/bench-bootstrap-gate.sh [--load] [runs=31] [project-dir] [transcript]
#   project-dir: a governed SOURCE project (default: $CLAUDE_PROJECT_DIR)
#   transcript : a real session .jsonl, so the block path pays its fallback grep (default: none)
# Side effects: writes only under ~/.claude/logs/sessions/bench-bg-*/ and a bench log; both removed.
LOAD=0; [ "${1:-}" = "--load" ] && { LOAD=1; shift; }
N="${1:-31}"; PROJ="${2:-${CLAUDE_PROJECT_DIR:-$PWD}}"; TR="${3:-}"
G="$HOME/.claude/hooks/governance"
export GOVERNANCE_LOG="$HOME/.claude/logs/bench-bootstrap-gate.log"
export CLAUDE_PROJECT_DIR="$PROJ"
exec </dev/null
jesc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
P_PROJ="$(jesc "$PROJ")"; P_TR="$(jesc "$TR")"
pl() { printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s}' "$1" "$P_TR" "$P_PROJ" "$2" "$3"; }
SID_ON="bench-bg-on-$$"; SID_OFF="bench-bg-off-$$"
mkdir -p "$HOME/.claude/logs/sessions/$SID_ON"; : > "$HOME/.claude/logs/sessions/$SID_ON/.gov-bootstrapper-ran"
BURN=()
cleanup() { for p in "${BURN[@]}"; do kill "$p" 2>/dev/null; done
  rm -rf "$HOME/.claude/logs/sessions/$SID_ON" "$HOME/.claude/logs/sessions/$SID_OFF" "$GOVERNANCE_LOG"; }
trap cleanup EXIT
if [ "$LOAD" = 1 ]; then
  CPUS="${NUMBER_OF_PROCESSORS:-$(nproc 2>/dev/null || echo 4)}"
  for _ in $(seq 1 "$CPUS"); do ( while :; do :; done ) & BURN+=($!); done
  sleep 2
fi
EDIT_IN='{"file_path":"'"$P_PROJ"'/README.md","old_string":"a","new_string":"b"}'
GIT_IN='{"command":"git status","description":"x"}'

bench() {  # bench <label> <payload> <cmd...>
  local label="$1" p="$2"; shift 2; local t=() i s e rc
  for ((i = 0; i < N; i++)); do
    s=$EPOCHREALTIME; printf '%s' "$p" | "$@" >/dev/null 2>&1; rc=$?; e=$EPOCHREALTIME
    t+=( $(( (${e/./} - ${s/./}) / 1000 )) )
  done
  local sorted; sorted=$(printf '%s\n' "${t[@]}" | sort -n)
  local med p95; med=$(sed -n "$(( (N + 1) / 2 ))p" <<<"$sorted"); p95=$(sed -n "$(( (N * 95 + 99) / 100 ))p" <<<"$sorted")
  printf '  %-52s median %5s ms   p95 %5s ms   rc=%s\n' "$label" "$med" "$p95" "$rc"
}
echo "== bootstrap-gate bench: load=$LOAD runs=$N project=$PROJ transcript=${TR:-none}"
bench "baseline: empty bash (process spawn floor)"          "{}"                                   bash -c :
bench "GATE Bash 'git status' (read, allow)"               "$(pl "$SID_OFF" Bash "$GIT_IN")"      bash "$G/bootstrap-gate.sh"
bench "GATE Edit, marker present (allow)"                  "$(pl "$SID_ON" Edit "$EDIT_IN")"      bash "$G/bootstrap-gate.sh"
bench "GATE Edit, marker missing (BLOCK path)"             "$(pl "$SID_OFF" Edit "$EDIT_IN")"     bash "$G/bootstrap-gate.sh"
bench "GATE --mark Skill(context-governance) (no-op)"      "$(pl "$SID_OFF" Skill '{"skill":"context-governance"}')" bash "$G/bootstrap-gate.sh" --mark
bench "existing deny-git-bypass.sh (Bash)"                 "$(pl "$SID_OFF" Bash "$GIT_IN")"      bash "$G/deny-git-bypass.sh"
bench "existing render-gate.sh (Bash)"                     "$(pl "$SID_OFF" Bash "$GIT_IN")"      bash "$G/render-gate.sh"
bench "existing pre-write.sh (Edit)"                       "$(pl "$SID_OFF" Edit "$EDIT_IN")"     bash "$G/pre-write.sh"
