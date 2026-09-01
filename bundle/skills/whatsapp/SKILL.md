---
name: whatsapp
description: Two-way WhatsApp communication — send progress updates and receive user replies via Ops-Group group
---

# WhatsApp Two-Way Session Communication

Two-way WhatsApp communication with the user via the **Ops-Group** group.

**Language**: Hebrew, concise (1-3 sentences).

---

## Setup

- **Group JID**: configured locally in `~/.claude/.wa-bridge.json` (`ccAgentGroup`) — not hardcoded
- **Prefix**: `[CC]` on ALL your outgoing messages
- **User replies**: No prefix needed
- **Scripts**: `~/.claude/skills/whatsapp/send.js` and `listen.js`

---

## Sending Messages

```bash
node ~/.claude/skills/whatsapp/send.js "[CC] MESSAGE"
```

**ALWAYS use `run_in_background: true`** for progress updates — saves a full context round-trip.

### Batching — Combine Multiple Updates

Do NOT send 3 separate messages for 3 updates. Combine them into ONE send with `\n` separators:

```bash
node ~/.claude/skills/whatsapp/send.js "[CC] שלב 1 הושלם\nשלב 2 הושלם\nשלב 3 בביצוע"
```

**Rule: max 1 send call per major milestone.** Accumulate updates mentally and batch them.

---

## RTL/BiDi Rules (CRITICAL — WhatsApp Rendering)

WhatsApp renders mixed Hebrew+English text using BiDi algorithm. Mixing directions on the same line produces UNREADABLE garbage. Follow these rules strictly:

1. **Hebrew text MUST be right-aligned.** The send.js script auto-prepends U+200F (RTL Mark) to Hebrew lines, forcing right-alignment even when mixed characters are present.
2. **NEVER mix Hebrew and English on the same line.** Put English terms (function names, file names, error codes) on their own separate line.
3. **NO emojis** — emojis in mixed-direction text cause additional rendering chaos.
4. **NO markdown syntax** — no backticks, no `**bold**`, no `## headers`. The send.js script strips these automatically, but avoid them in the source message too.
5. **NO special characters mixed with text** — avoid `()`, `{}`, `[]`, `:` adjacent to Hebrew words. Use a dedicated line for technical details.
6. **Keep lines either FULLY Hebrew or FULLY English.** Never alternate within a single line.
7. **Use plain Hebrew** — short, clear sentences. Translate technical concepts to Hebrew where possible.

### BAD (causes BiDi chaos):
```
"[CC] מצאתי שגיאה: agentProcessing is not defined בנוד ai_response"
```

### GOOD (clean rendering):
```
"[CC] מצאתי שגיאה בתהליך\nשם השגיאה\nagentProcessing is not defined\nהשגיאה קורה בנוד של תגובת הבינה המלאכותית"
```

### Translation guide for common terms:
- flow → תהליך
- node → נוד / צומת
- trigger → טריגר
- agent → סוכן
- enrichment → העשרה
- error → שגיאה
- container → קונטיינר
- bug / fix → באג / תיקון
- KB (Knowledge Base) → בסיס ידע

---

## Receiving Replies

1. Send question (background): `node ~/.claude/skills/whatsapp/send.js "[CC] שאלה: ..."`
2. Listen (foreground, `timeout: 120000`):

```bash
node ~/.claude/skills/whatsapp/listen.js
```

Exit 0 = reply on stdout. Exit 2 = timeout → ask in Claude Code chat.

---

## When to Send (max 4 messages per session)

1. **Session start**: `"[CC] התחלתי לעבוד על הנושא"`
2. **Mid-session batch**: `"[CC] שלב 1 הושלם\nשלב 2 הושלם\nשלב 3 בביצוע"`
3. **Question** (if needed): `"[CC] שאלה: ..."`
4. **Task complete**: `"[CC] הושלם\nסיכום קצר כאן"`

---

## Rules

- **Max ~4 messages per session** — batch aggressively
- **ALWAYS `run_in_background: true`** for sends (saves full context round-trip)
- Questions: foreground listen, `timeout: 120000`
- Never send secrets. Hebrew only. 1-3 sentences per update.
- **STRICT BiDi compliance** — see RTL/BiDi Rules section above

---

## First Action

```bash
node ~/.claude/skills/whatsapp/send.js "[CC] עדכוני התקדמות פעילים. כדי לענות שלח הודעה בקבוצה."
```
