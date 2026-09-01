#!/usr/bin/env bash
# render-gate.sh - PreToolUse(Bash|PowerShell) gate.
#
# BLOCKS any render command until the project's canonical render-rules file has been READ
# in this session, and CONSUMES that read so the next render requires a fresh one.
#
# WHY (owner directive, 2026-07-27): "so that something this serious never happens again -
# require reading the canonical render/video-production file BEFORE EVERY RENDER you do."
#
# What went wrong without it: two separate failures in one session, both already documented
# in the file I had not re-read.
#   * The five trained avatar looks are not in the generic /v2/avatars catalogue; the file
#     says to use the CLI (`heygen avatar looks list`), where the owner's chosen look was
#     sitting in plain sight. I queried the wrong surface and reported it as missing.
#   * The same file warns IN WRITING that catbox intermittently stores a 0-byte file and
#     that the bytes must be verified before sending a link. I sent two dead links - one to
#     the CEO - and only found out when the owner clicked.
# Loading the file once at SessionStart is not enough: a long session drifts far from what
# it read hours earlier. The gate is per-render, not per-session, because that is the unit
# where the cost lands.
#
# HOW THE TOKEN WORKS: reading the file stamps a marker (render-rules-read.sh, PostToolUse
# on Read). This gate requires the marker, then DELETES it. One read buys exactly one
# render - which is what "before every render" means.
#
# Kill switch: GOVERNANCE_HOOKS=0
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }
gov_disabled && exit 0

INPUT=""
INPUT=$(gov_hook_input)
[ -z "$INPUT" ] && exit 0

CMD=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print((d.get('tool_input') or {}).get('command', ''))
except Exception:
    print('')
" 2>/dev/null)
[ -z "$CMD" ] && exit 0

# A render command is one that RUNS a renderer - not one that merely MENTIONS it. The first
# real use of this gate blocked a `git commit` whose message described the gate itself,
# because the words "heygen video create" appeared inside the heredoc. A gate that fires on
# unrelated work gets switched off, and then it protects nothing, so two narrowings:
#
#   1. git is never a render. Commit messages, docs and PR bodies quote these commands
#      constantly and none of them bill or produce a frame.
#   2. Heredoc bodies are stripped before matching, so prose inside <<'EOF' ... EOF cannot
#      trigger it either.
FIRSTWORD=$(printf '%s' "$CMD" | sed 's/^[[:space:]]*//' | awk '{print $1}' | sed 's#.*/##')
case "$FIRSTWORD" in
  git|gh) gov_log "render-gate" "vcs command - not a render"; exit 0;;
esac

# Strip everything that is DATA rather than command: heredoc bodies and quoted spans.
#
# Narrowing to git alone was not enough - the very next command it false-blocked was a
# `node -e '...'` whose STRING LITERAL mentioned the render commands. The distinction that
# actually holds is invocation vs mention: a real render names its binary unquoted
# (`node .../remotion-cli.js render`), while a mention lives inside quotes or a heredoc.
SCAN=$(printf '%s' "$CMD" | awk '
  /<<[-]?['"'"'"]?[A-Za-z_]+['"'"'"]?/ { inhd=1; next }
  inhd && /^[A-Za-z_]+[[:space:]]*$/   { inhd=0; next }
  inhd                                  { next }
  { print }
' | sed "s/'[^']*'/ /g; s/\"[^\"]*\"/ /g")

# Introspection is not production. `--request-schema`, `--help` and friends name the render
# subcommand but neither bill nor emit a frame, and blocking them just teaches people to
# reach for the kill switch.
printf '%s' "$SCAN" | grep -qE '(^|[[:space:]])--(request-schema|schema|help|dry-run|version)([[:space:]]|$)|(^|[[:space:]])-h([[:space:]]|$)' && {
  gov_log "render-gate" "introspection flag - not a render"; exit 0; }

# Commands that COST something or produce a deliverable.
RENDER_RE='remotion-cli(\.js)?[^|;]*\b(render|still)\b|heygen[^|;]*\bvideo[[:space:]]+create\b|heygen[^|;]*\bvoice[[:space:]]+speech[[:space:]]+create\b|renderMediaOnLambda|heygen\.exe[^|;]*video'
printf '%s' "$SCAN" | grep -qE "$RENDER_RE" || exit 0

PROJECT_ROOT="$(gov_find_project_root 2>/dev/null)"
[ -z "$PROJECT_ROOT" ] && PROJECT_ROOT="$PWD"
RULES="$PROJECT_ROOT/Read_Before_Every_Render.md"
# No such file in this project -> nothing to enforce.
[ -f "$RULES" ] || { gov_log "render-gate" "no Read_Before_Every_Render.md - skip"; exit 0; }

MARKER="${GOV_RENDER_READ_MARKER:-$HOME/.claude/logs/.gov-render-rules-read}"
if [ ! -f "$MARKER" ]; then
  gov_log "render-gate" "BLOCKED - render attempted without reading the render rules"
  printf "[render-gate] BLOCKED - read Read_Before_Every_Render.md before rendering.\n" >&2
  cat <<ENDMSG

[RENDER-GATE] This command renders or bills, and the canonical render rules have not been
read in this session (or the previous read was already spent on an earlier render).

  READ THIS FIRST:  $RULES

Then run the command again. Reading it stamps a token; this gate spends the token, so each
render requires its own read. That is the owner's instruction of 2026-07-27, after two
failures in one session that the file already documented: the avatar looks live behind the
CLI (not the generic /v2/avatars catalogue), and catbox silently stores 0-byte files so
uploaded bytes must be verified before a link is sent.

Do not work around this by editing the marker. The point is the reading, not the file.

Override (user only): GOVERNANCE_HOOKS=0

ENDMSG
  exit 2
fi

# Spend the token: one read, one render.
AGE=$(( $(date +%s) - $(stat -c %Y "$MARKER" 2>/dev/null || echo 0) ))
rm -f "$MARKER" 2>/dev/null
gov_log "render-gate" "allowed - rules read ${AGE}s ago, token consumed"
exit 0
