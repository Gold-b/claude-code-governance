#!/usr/bin/env bash
# governance-helpers-check.sh -- fail loudly when a hook calls a helper the _common.sh
# shipped BESIDE IT does not define.
# Created: 2026-08-22
#
# WHY THIS EXISTS
# The public governance repo shipped a _common.sh without gov_path_key while shipping a
# file-collision-guard.sh that calls it. A fresh install therefore got a guard that was
# present, registered in settings.json, and completely inert: KEY came back empty, the
# `[ -z "$KEY" ] && exit 0` fail-open fired on every single edit, and nothing anywhere
# said so. The hook was not broken in any way an operator could see. It just never did
# anything.
#
# That blast radius gets WIDER every time something moves into _common.sh -- which is
# exactly what the collision-guard extraction does. So the extraction ships with this.
#
# It is a static check: it reads files, runs nothing, and needs no session, no payload and
# no git repo. Point it at any directory that claims to be a set of governance hooks -- the
# live one, REMOTE's copy, the installer bundle, a clone of the public repo -- and it
# answers one question: can every hook in there actually do its job?
#
# Two independent checks, because either alone can be fooled:
#
#   1. DECLARED CONTRACT. Hooks that call gov_require_helpers name what they need. Those
#      names are verified against the sibling _common.sh. Precise, and it is the same list
#      the hook enforces at runtime, so the two cannot drift apart.
#   2. STATIC SWEEP. Every gov_* token used anywhere in a hook must be defined either in the
#      sibling _common.sh or in that hook itself. This catches the hook that forgot to
#      declare, which is the case check 1 cannot see.
#
# Usage:
#   governance-helpers-check.sh [dir]     default: the directory this script is in
# Exit: 0 = every hook can run. 1 = at least one hook would be inert. 2 = unusable input.

set +e
DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"

[ -d "$DIR" ]    || { echo "helpers-check: not a directory: $DIR" >&2; exit 2; }
COMMON="$DIR/_common.sh"
[ -f "$COMMON" ] || { echo "helpers-check: no _common.sh in $DIR" >&2; exit 2; }

# What does this _common.sh actually DEFINE? Function definitions only -- a variable, or a
# comment mentioning the name, is not a definition, and counting it as one is how a check
# like this ends up reporting a pass it never measured.
defined_in_common=$(
  grep -oE '^[[:space:]]*(function[[:space:]]+)?gov_[A-Za-z0-9_]+[[:space:]]*\(\)' "$COMMON" \
    | sed -E 's/^[[:space:]]*(function[[:space:]]+)?//; s/[[:space:]]*\(\)//' | sort -u
)
[ -n "$defined_in_common" ] || { echo "helpers-check: $COMMON defines no gov_* helpers at all -- wrong file?" >&2; exit 2; }

is_defined() {  # is_defined <name> <hook's own definitions>
  printf '%s\n' "$defined_in_common" | grep -qx "$1" && return 0
  printf '%s\n' "$2" | grep -qx "$1" && return 0
  return 1
}

problems=0
checked=0

for hook in "$DIR"/*.sh; do
  base=$(basename "$hook")
  case "$base" in
    _common.sh|governance-helpers-check.sh) continue ;;
  esac
  [ -f "$hook" ] || continue
  grep -q '_common\.sh' "$hook" || continue     # only hooks that load it are in the contract
  checked=$((checked+1))

  own=$(
    grep -oE '^[[:space:]]*(function[[:space:]]+)?gov_[A-Za-z0-9_]+[[:space:]]*\(\)' "$hook" \
      | sed -E 's/^[[:space:]]*(function[[:space:]]+)?//; s/[[:space:]]*\(\)//' | sort -u
  )

  # ---- check 1: the contract the hook declares for itself -------------------------------
  declared=$(
    sed -n '/gov_require_helpers/,/[^\\]$/p' "$hook" \
      | tr '\\' ' ' | grep -oE '\bgov_[a-z0-9_]+' | grep -v '^gov_require_helpers$' | sort -u
  )
  for fn in $declared; do
    if ! is_defined "$fn" "$own"; then
      echo "MISSING  $base declares it needs $fn -- not defined in $COMMON"
      problems=$((problems+1))
    fi
  done
  if [ -n "$declared" ] && ! is_defined "gov_require_helpers" "$own"; then
    echo "MISSING  $base calls gov_require_helpers -- not defined in $COMMON"
    problems=$((problems+1))
  fi

  # ---- check 2: everything it actually calls ---------------------------------------------
  # Whole-line comments are dropped first; a name discussed in prose is not a call. Trailing
  # comments are left alone deliberately: stripping them safely would mean parsing bash
  # (think ${v#pat} and $#), and a false positive here is cheap noise while a false negative
  # is the entire bug this file exists to prevent.
  used=$(sed '/^[[:space:]]*#/d' "$hook" | grep -oE '\bgov_[a-z0-9_]+' | sort -u)
  for fn in $used; do
    if ! is_defined "$fn" "$own"; then
      echo "MISSING  $base calls $fn -- not defined in $COMMON (and not defined locally)"
      problems=$((problems+1))
    fi
  done
done

echo
if [ "$problems" -eq 0 ]; then
  echo "helpers-check: OK -- $checked hooks in $DIR, every gov_* helper they call is defined in _common.sh"
  exit 0
fi
cat >&2 <<EOF
helpers-check: FAILED -- $problems missing helper(s) across $checked hooks in
  $DIR

Do not install this set. A hook whose helper is missing does not error: it takes its
fail-open path on every invocation and protects nothing, silently, forever. Ship
_common.sh and the hooks that depend on it in the SAME change, always.
EOF
exit 1
