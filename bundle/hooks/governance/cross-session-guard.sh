#!/usr/bin/env bash
# cross-session-guard.sh — PreToolUse(SendMessage): a report to another session must say what it
# MEASURED and what it did NOT CHECK.
#
# WHY (2026-09-14, measured over one incident between two sessions):
# Of three claims one session made to another, the receiver checked all three: one held, two did
# not, and one of the wrong ones left an entire project with no backup while a confident, detailed
# report said it was covered. In the other direction two errors were caught, one of them a
# recommendation that would have disabled the guard protecting against the corruption it was meant
# to fix. Neither session was a reliable source about its own work. What worked was that every
# claim could be separated into "I measured this" and "I am inferring this".
#
# /cross-session-protocol is the guidance. This is the control. Guidance is remembered or it is
# not; a control fires either way - that distinction is the whole point of this framework.
#
# TWO RULES, both deterministic, both tested in both directions in governance-selftest.sh:
#   1. A message carrying a protocol tag ([FYI] [ASK] [STOP] ...) MUST carry MEASURED: and
#      NOT CHECKED:. Any length. It declared itself a protocol message.
#   2. A message of >= 400 characters MUST carry them too, tagged or not. That length is where
#      reports, findings and recommendations live - the things a receiver acts on. Short
#      operational notes, and messages to in-process subagents, pass untouched: this hook fires on
#      every SendMessage and must not turn ordinary delegation into a permission prompt.
#
# Kill switch: GOV_XSESSION_GUARD=0

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0
[ "${GOV_XSESSION_GUARD:-1}" = "0" ] && exit 0

PAYLOAD=$(gov_hook_input)
[ -z "$PAYLOAD" ] && exit 0

TOOL=$(printf '%s' "$PAYLOAD" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//')
[ "$TOOL" = "SendMessage" ] || exit 0

# Extract the message body. python3 first; a parser-free fallback second. If BOTH fail we do not
# know what is being sent, and a guard that cannot read its input must say so rather than wave the
# call through (CONVENTIONS: fail loud, never open).
MSG=""
if command -v python3 >/dev/null 2>&1; then
  MSG=$(printf '%s' "$PAYLOAD" | timeout 5 python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print((d.get("tool_input", {}) or {}).get("message", "") or "")
except Exception:
    print("")
' 2>/dev/null)
fi
if [ -z "$MSG" ]; then
  MSG=$(printf '%s' "$PAYLOAD" | grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//')
  if [ -z "$MSG" ]; then
    case "$PAYLOAD" in
      *'"message"'*)
        gov_log "cross-session-guard" "MALFUNCTION: a message field is present but neither parser could read it"
        echo "[cross-session-guard] MALFUNCTION: could not read the message body. Refusing rather than guessing." >&2
        exit 1 ;;
      *) exit 0 ;;   # genuinely no message field - nothing to police
    esac
  fi
fi

LEN=${#MSG}
TAGGED=0
case "$MSG" in
  *"[FYI]"*|*"[ASK]"*|*"[PARTITION]"*|*"[HANDOFF]"*|*"[DONE]"*|*"[DECISION]"*|*"[STOP]"*|*"[SIGNAL-REQUEST]"*|*"[SIGNAL]"*|*"[CONFLICT]"*) TAGGED=1 ;;
esac

# Under the threshold and not claiming to be a protocol message: not this hook's business.
if [ "$TAGGED" = "0" ] && [ "$LEN" -lt 400 ]; then
  exit 0
fi

HAS_MEASURED=0; HAS_UNCHECKED=0
case "$MSG" in *"MEASURED:"*) HAS_MEASURED=1 ;; esac
case "$MSG" in *"NOT CHECKED:"*) HAS_UNCHECKED=1 ;; esac

if [ "$HAS_MEASURED" = "1" ] && [ "$HAS_UNCHECKED" = "1" ]; then
  gov_log "cross-session-guard" "ALLOW: contract present (len=$LEN tagged=$TAGGED)"
  exit 0
fi

MISSING=""
[ "$HAS_MEASURED" = "0" ]  && MISSING="$MISSING MEASURED:"
[ "$HAS_UNCHECKED" = "0" ] && MISSING="$MISSING 'NOT CHECKED:'"
WHY="it is $LEN characters long"
[ "$TAGGED" = "1" ] && WHY="it carries a protocol tag"

gov_log "cross-session-guard" "BLOCK: missing$MISSING (len=$LEN tagged=$TAGGED)"
cat >&2 <<ERRMSG
[cross-session-guard] BLOCKED: this message is missing$MISSING

It is being policed because $WHY — that is a report another session may act on.

Two sessions measured this the hard way: of three claims one made to the other, two were wrong,
and one wrong claim left a whole project unbacked while a confident report said otherwise. The
receiver cannot tell your evidence from your conclusion unless you separate them.

Add to the message body:
  MEASURED:    <fact> — <the command or source that produced it> — <when>
  NOT CHECKED: <what you did not verify>

Both are required even when the honest answer is "nothing" — write
  NOT CHECKED: nothing; every claim above was re-run just now
Full contract: /cross-session-protocol

Emergency bypass: GOV_XSESSION_GUARD=0
ERRMSG
exit 2
