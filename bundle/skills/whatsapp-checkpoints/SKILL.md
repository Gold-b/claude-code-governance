---
name: whatsapp-checkpoints
description: Use when a task/step/plan/process finishes, when the session pauses or stops or ends (PAUSE/STOP/END), when the user must answer a question or choose an option or make a decision, or when the session has halted and the agent is no longer active — proactively notify the user on WhatsApp and wait for the reply before continuing.
---

# WhatsApp Checkpoint Notifications

## Overview

Keep the user in the loop over WhatsApp at every meaningful checkpoint, then **wait for and act on the reply**. The user is often away from the screen — push status, blocking questions, and stalls to WhatsApp instead of letting them sit unseen in the terminal.

**Transport:** the `whatsapp` skill (`send.js` / `listen.js`).
**Do NOT use the `wa-cc` bridge** — that is the reverse direction (user-initiated tasks polled into Claude Code), not proactive agent updates.

**REQUIRED SUB-SKILL:** the `whatsapp` skill — read it for the exact send/listen commands and the BiDi/RTL rendering rules. Follow those rules verbatim.

## When to Send (fire on ANY of these)

1. A task / step / plan / process **finishes**.
2. The session **pauses, stops, or ends** (PAUSE / STOP / END).
3. You need the user to **answer a question, choose an option, or make a decision**.
4. The session **halted for any reason and the agent is no longer active**.

## How to Send

- Command: `node ~/.claude/skills/whatsapp/send.js "[CC] ..."` with `run_in_background: true`.
- **Hebrew, short, essential** — 1-3 sentences. State the outcome plus the single thing you need (if any). This is a *concise, substantive* update, not a log dump.
- **Strict BiDi/RTL:** pure-Hebrew lines only, English (paths/IDs/errors) on its own separate line, no emojis, no markdown. See the `whatsapp` skill.
- **One send per checkpoint** — combine sub-updates with `\n`, do not fire 3 messages for 3 items.

## After a Message That Needs a Reply — Wait, Monitor, Act

Triggers 2, 3, and 4 expect a reply. The user's standing rule: **wait for the reply and act on it.**

1. Listen (foreground): `node ~/.claude/skills/whatsapp/listen.js 120000`
   - exit 0 = reply on stdout → **act on it immediately**; the reply defines your next step.
   - exit 2 = timeout → re-listen (next cycle).
2. Keep a running **10-minute continuous-silence budget** (≈5 cycles of 120s). Any reply **resets** the budget.
3. **10-minute rule (hard stop):** if there is NO reply for 10 continuous minutes, **STOP monitoring immediately**. Do not keep polling. The user replies when back at the computer.

**Persistent variant** — when you must end the turn but still need to catch a reply: arm a 1-minute cron (`CronCreate cron='* * * * *'`) that checks for a new reply via `listen.js` / the wa-cc poll mechanism and re-invokes you when one arrives. **Auto-disarm after 10 minutes of silence** — `CronDelete` it the moment a reply arrives or the budget expires. Never leave a reply-watcher running past the 10-minute budget.

## After Monitoring Stops (10-minute silence)

- Pending item is a **required decision** → halt and leave it open. Do NOT guess on irreversible or outward-facing actions.
- Safe to proceed with a **default** → continue, and state what you assumed in the next checkpoint message.

## Quick Reference

| Event | Message shape | Then |
|---|---|---|
| Task / step / plan done | `[CC] הושלם\n<סיכום קצר>` | continue / await next |
| Question / decision | `[CC] שאלה: ...\nאפשרויות: ...` | listen.js → act on reply |
| Pause / stop / end | `[CC] עוצר\n<סיבה + מצב>` | listen.js, up to 10 min |
| Session idle / halted | `[CC] הסשן עצר\n<מצב נוכחי>` | cron-watch, up to 10 min |

## Common Mistakes

| Mistake | Fix |
|---|---|
| English / emojis / markdown in the message | Hebrew, plain text; follow the `whatsapp` skill's BiDi rules |
| Polling past 10 minutes of silence | Forbidden — stop immediately at the 10-min mark |
| Using the `wa-cc` bridge to send | Wrong direction — use the `whatsapp` skill's `send.js` |
| Asking only in the terminal, not on WhatsApp | The user may be away — push every decision to WhatsApp |
| Several messages for one checkpoint | Batch into one send with `\n` |
| Leaving a reply-watcher cron running | `CronDelete` on reply or at the 10-min budget |
