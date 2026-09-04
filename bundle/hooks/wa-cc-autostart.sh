#!/usr/bin/env bash
# wa-cc-autostart.sh — WA-CC bridge v2 (Monitor-based).
# Registered on: SessionStart, Stop, PostCompact.
# Owner standing directive 2026-07-21: AUTO-ARM silently. No cron. No opt-in question.

set -euo pipefail

# ─── RETIRED 2026-08-20 (owner decision) ────────────────────────────────────────────────────────
# This hook existed to AUTO-ARM a local bridge monitor at SessionStart. The bridge moved to the remote host
# on 2026-08-19 and runs there as a systemd service, so an arm instruction is now actively harmful:
# a local monitor claims presence, the remote agent correctly yields to it, and the local reader
# cannot read - the owner's message reaches nobody (GOTCHAS #27, reproduced 2026-08-19).
#
# The owner asked for the CODE to be retired rather than for a written rule, because a written rule
# failed silently twice this week. The entry points themselves also refuse now
# (WA_ALLOW_LOCAL_MONITOR), so this is the second of two independent stops, not the only one.
# The body below is left intact and unreachable as the record of what it used to do.
exit 0
# ────────────────────────────────────────────────────────────────────────────────────────────────


HOME_DIR="${USERPROFILE:-$HOME}"

# Kill-switch: stay completely silent
if [ -f "${HOME_DIR}/.claude/wa-bridge-off" ]; then
  exit 0
fi

# NEVER emit arm instructions while the session is CLOSING (owner, 2026-07-28). This script
# is registered on SessionStart, Stop and PostCompact with one body, so on Stop it used to
# tell the model to arm a persistent Monitor at the exact moment the close was tearing that
# Monitor down - and a session that re-arms on its way out is the one that keeps stealing
# the next session's messages. Re-arming after a COMPACT is still correct, so only Stop is
# suppressed. Unknown/absent event -> behave as before (arm), because a silent bridge is
# worse than a redundant arm instruction.
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

if ! docker ps --format "{{.Names}}" 2>/dev/null | grep -q "goldb-admin"; then
  cat <<'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "[WA-CC Bridge v2] Gateway containers NOT running. Bridge inactive. To enable: start the gateway stack from your gateway checkout: docker compose up -d --remove-orphans."
  }
}
ENDJSON
  exit 0
fi

cat <<'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "[WA-CC Bridge v2] AUTO-ARM (standing owner directive 2026-07-21, no need to ask): SILENTLY arm a persistent Monitor running, FROM THE PROJECT DIRECTORY: cd <project> && WA_SESSION_CWD='<project>' node \"$USERPROFILE/.claude/skills/wa-cc-bridge/wa-session-inbox.js\"  (description: 'WhatsApp bridge: allowlisted incoming messages', persistent: true). Pass WA_SESSION_CWD explicitly or presence is scoped to the wrong project and the always-on agent will not yield. NEVER arm wa-monitor.js - the always-on WA-Live-Agent task owns ~/.claude/wa-monitor.lock, so a session monitor either exits 3 or wins the race and leaves the agent dead. NEVER use CronCreate for this bridge (v1 is retired). This session's presence is released deterministically at close by ~/.claude/hooks/wa-session-inbox-stop.sh - do NOT re-arm while closing. When a bridge event (JSON line) arrives: REPLY FIRST - send an immediate short ack/answer via send.js within seconds, BEFORE any verification or work (owner rule 2026-07-21); then treat .text as a normal user instruction in THIS session (mediator model - full normal workflow, governance, approvals) and follow up. Reply via: node ~/.claude/skills/whatsapp/send.js \"[CC] <reply>\" - Hebrew, SHORT, essence only, NO code blocks/logs, BiDi/RTL rules per the whatsapp skill. Full behavior: ~/.claude/skills/wa-cc-bridge/SKILL.md."
  }
}
ENDJSON
