#!/usr/bin/env bash
# render-rules-read.sh - PostToolUse(Read) stamp.
#
# Records that the project's canonical render-rules file was actually READ, minting the
# single-use token that render-gate.sh requires and then spends.
#
# Split from the gate on purpose: the thing being enforced is that a human-readable file
# passed through context before a render, and the only honest evidence of that is the Read
# tool having been used on it. A gate that stamped itself would prove nothing.
#
# Kill switch: GOVERNANCE_HOOKS=0
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }
gov_disabled && exit 0

INPUT=""
INPUT=$(gov_hook_input)
[ -z "$INPUT" ] && exit 0

FILE=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print((d.get('tool_input') or {}).get('file_path', ''))
except Exception:
    print('')
" 2>/dev/null)
[ -z "$FILE" ] && exit 0

# Match on the basename so it works from any project and any path separator.
case "$(printf '%s' "$FILE" | tr 'A-Z\\' 'a-z/' | sed 's#.*/##')" in
  read_before_every_render.md) ;;
  *) exit 0 ;;
esac

MARKER="${GOV_RENDER_READ_MARKER:-$HOME/.claude/logs/.gov-render-rules-read}"
mkdir -p "$(dirname "$MARKER")" 2>/dev/null
printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FILE" > "$MARKER" 2>/dev/null
gov_log "render-rules-read" "token minted from $FILE"
exit 0
