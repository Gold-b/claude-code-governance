---
name: Enable-Remote-Code
description: Enable Remote Control so the current project's Claude Code sessions can be accessed from the Android/iOS app or any browser via claude.ai/code.
allowed-tools: [Bash(claude *)]
---

# Enable Remote Control for Current Project

You are enabling Remote Control so the user can connect to this Claude Code session from their phone (Android/iOS Claude app) or any browser at claude.ai/code.

**Execute the steps below in order.**

---

## Step 1 — Verify Authentication

Run the following to confirm the user is logged in:

```bash
claude auth status
```

If NOT authenticated, instruct the user to run `claude` and then `/login` to sign in via claude.ai before proceeding. **Do not continue until auth is confirmed.**

---

## Step 2 — Enable Remote Control for All Sessions (Project-Level)

Enable Remote Control as a persistent setting so every future session in this project automatically supports remote connections:

Use the `/config` command inside Claude Code to set **"Enable Remote Control for all sessions"** to `true`.

Since we are running inside Claude Code already, execute:

```
/remote-control
```

This will:
- Register this session with the Anthropic API
- Display a **session URL** and **QR code**
- Allow connections from claude.ai/code, the iOS app, and the Android app

---

## Step 3 — Present Connection Instructions to User

After Remote Control is active, present the user with the following (in Hebrew):

**איך להתחבר מהטלפון:**

1. פתח את אפליקציית Claude (אנדרואיד / iOS)
2. סרוק את קוד ה-QR שמוצג בטרמינל, או
3. פתח את claude.ai/code בדפדפן ומצא את הסשן ברשימה (סמל מחשב עם נקודה ירוקה = מחובר)

**שים לב:**
- הסשן רץ מקומית על המחשב שלך — שום דבר לא עובר לענן מעבר ל-API הרגיל
- אם המחשב נכנס לשינה או מתנתק מהרשת ליותר מ-10 דקות, הסשן ייסגר
- הטרמינל חייב להישאר פתוח כל עוד הסשן פעיל
- אפשר לשלוח הודעות גם מהטרמינל וגם מהטלפון/דפדפן — השיחה מסונכרנת

---

## Notes

- Remote Control uses outbound HTTPS only — no inbound ports are opened on the machine.
- Each Claude Code instance supports one remote session at a time.
- To start a named session from CLI: `claude remote-control --name "Project Name"`
- To show QR code in terminal: press **spacebar** while `claude remote-control` is running.
