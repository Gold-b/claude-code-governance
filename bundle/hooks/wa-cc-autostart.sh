#!/usr/bin/env bash
# wa-cc-autostart.sh — WA-CC bridge v2 (Monitor-based).
# Registered on: SessionStart, Stop, PostCompact.
# Owner standing directive 2026-07-21: AUTO-ARM silently. No cron. No opt-in question.

set -euo pipefail

HOME_DIR="${USERPROFILE:-$HOME}"

# Kill-switch: stay completely silent
if [ -f "${HOME_DIR}/.claude/wa-bridge-off" ]; then
  exit 0
fi

# NEVER emit arm instructions while the session is CLOSING. This script is registered on
# SessionStart, Stop and PostCompact with ONE body, so on Stop it would tell the model to arm a
# persistent Monitor at the exact moment the close is tearing that Monitor down - and a session
# that re-arms on its way out is the one that steals the next session's messages. Re-arming after
# a COMPACT is still correct, so only Stop/SessionEnd are suppressed. An unknown or absent event
# behaves as before (arm), because a silent bridge is worse than a redundant arm instruction.
EVENT=""
if [ ! -t 0 ]; then
  EVENT=$(timeout 3 cat 2>/dev/null | python3 -c "
import sys, json
try: print((json.load(sys.stdin) or {}).get('hook_event_name',''))
except Exception: print('')
" 2>/dev/null) || EVENT=""
fi
if [ "$EVENT" = "Stop" ] || [ "$EVENT" = "SessionEnd" ]; then
  exit 0
fi

# The gateway container name is MACHINE-LOCAL. This hook ships in a PUBLIC bundle, where a
# real container name names a real deployment, so there is no baked default: set
# WA_GATEWAY_CONTAINER (e.g. in ~/.claude/.governance-local.env). Unset means "not
# configured", and the hook reports the bridge inactive rather than guessing a name --
# fail-closed, because a wrong guess would arm a bridge against somebody else's container.
WA_GATEWAY_CONTAINER="${WA_GATEWAY_CONTAINER:-}"
if [ -z "$WA_GATEWAY_CONTAINER" ]; then
  _WA_STACK_UP=0
elif docker ps --format "{{.Names}}" 2>/dev/null | grep -q "$WA_GATEWAY_CONTAINER"; then
  _WA_STACK_UP=1
else
  _WA_STACK_UP=0
fi
if [ "$_WA_STACK_UP" -eq 0 ]; then
  cat <<'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "[WA-CC Bridge v2] Gateway containers NOT running. Bridge inactive. To enable: set WA_GATEWAY_CONTAINER to your gateway container name, then start the stack from your own gateway checkout: docker compose up -d --remove-orphans."
  }
}
ENDJSON
  exit 0
fi

cat <<'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "[WA-CC Bridge v2] AUTO-ARM (standing owner directive 2026-07-21, no need to ask): SILENTLY arm a persistent Monitor running: node \"$USERPROFILE/.claude/skills/wa-cc-bridge/wa-monitor.js\"  (description: 'WhatsApp bridge: allowlisted incoming messages', persistent: true). If the process exits immediately with code 3, another session already holds the bridge - do NOT arm again, do NOT mention it. NEVER use CronCreate for this bridge (v1 is retired). When a bridge event (JSON line) arrives: REPLY FIRST - send an immediate short ack/answer via send.js within seconds, BEFORE any verification or work (owner rule 2026-07-21); then treat .text as a normal user instruction in THIS session (mediator model - full normal workflow, governance, approvals) and follow up. Reply via: node ~/.claude/skills/whatsapp/send.js \"[CC] <reply>\" - Hebrew, SHORT, essence only, NO code blocks/logs, BiDi/RTL rules per the whatsapp skill. Full behavior: ~/.claude/skills/wa-cc-bridge/SKILL.md."
  }
}
ENDJSON
