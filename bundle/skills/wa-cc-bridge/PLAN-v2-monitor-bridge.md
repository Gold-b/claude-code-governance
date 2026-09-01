# WhatsApp-CC Bridge v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the token-burning 60s cron bridge with an event-driven, zero-idle-cost WhatsApp bridge: in-session Monitor (Phase 1) + 24/7 daemon fallback that opens a headless CC session when none is open (Phase 2).

**Architecture:** A single Node watcher script (`wa-monitor.js`) follows the gateway admin log as a background OS process (zero tokens). In session mode each allowlisted message is one stdout JSON line that wakes the live CC session via the harness Monitor tool. In daemon mode (Windows Scheduled Task) the same script defers to a live session via a heartbeat lock file, else spawns `claude -p` headless with resume continuity. Pure parsing lives in a lib module; the runner handles file offsets, midnight rollover, UTF-8 chunk boundaries, singleton lock, and kill-switch.

**Tech Stack:** Node (system node, no npm deps; built-in `node:test`, `string_decoder`), bash SessionStart hook, Claude Code Monitor tool, Windows Scheduled Task (PowerShell registration), Claude Code headless CLI (`claude -p --output-format json --resume`).

**Spec:** `C:\Users\<user>\.claude\skills\wa-cc-bridge\SPEC-v2-monitor-bridge.md` (v2.1, owner-approved 2026-07-21).

## Global Constraints

- All new runtime files live in `C:\Users\<user>\.claude\skills\wa-cc-bridge\` (user-level infra; NOT the project repo).
- `~/.claude` is NOT a git repo — there are no commit steps. Version safety = sync changed skill files into the installer mirror `C:\Users\<user>\.claude\governance-installer\bundle\skills\wa-cc-bridge\` (an auto-sync exists for new files — VERIFY after each task, `cp` manually if missing/stale).
- NO new npm dependencies. Tests use built-in `node --test`.
- Allowlist-only: a message is processed ONLY if its `chatId` exactly equals a configured source JID. DM allowlist = the operator's number only.
- Self-message filter: skip any text whose first non-BiDi-mark characters are `[CC]`.
- Kill-switch file `~/.claude/wa-bridge-off` silences BOTH layers within one poll tick.
- Exactly-once: session watcher holds `~/.claude/wa-monitor.lock` (heartbeat, 60s freshness); daemon defers while a session lock is fresh. Only ONE session monitor may run (second exits code 3).
- Zero model polling: the model is invoked only on a real allowlisted message. No cron anywhere.
- WA replies (behavioral rule carried in hook/SKILL text): short Hebrew, essence only, NO code blocks/logs, `[CC]` prefix, BiDi/RTL rules.
- Gateway log line format (verified 2026-07-21): `[message-hook] Received: channel=whatsapp chatId=<JID> senderId=<+phone> text=<msg>` in `~/.openclaw/admin-logs/admin-YYYYMMDD.log`. DM chatId format is UNVERIFIED — Task 3 captures it live before enabling the DM source.
- Config `~/.claude/.wa-bridge.json` is local-only/gitignored — never copy real JIDs into the bundle, docs, or any repo.

---

### Task 1: Parsing/filter library (`wa-monitor-lib.js`)

**Files:**
- Create: `C:\Users\<user>\.claude\skills\wa-cc-bridge\wa-monitor-lib.js`
- Test: `C:\Users\<user>\.claude\skills\wa-cc-bridge\wa-monitor.test.js` (lib section)

**Interfaces:**
- Produces: `loadSources(cfgObj) -> [{jid,type,name,requireKeyword}]`; `parseChunk(text, sources) -> {events:[{source,type,chatId,sender,text,ts}], remainder:string}`; `isSelf(text)->bool`; `hasKeyword(text)->bool`; `normalizeJid(v)->string`; `ymd(date)->'YYYYMMDD'`; `KEYWORDS` array. Consumed by Tasks 2 and 6.

- [ ] **Step 1: Write the failing tests**

```js
// wa-monitor.test.js
'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const lib = require('./wa-monitor-lib');

const GROUP = '111111111111111111@g.us';
const DM = '972500000000@s.whatsapp.net';
const SOURCES = [
  { jid: GROUP, type: 'group', name: 'Ops-Group', requireKeyword: false },
  { jid: DM, type: 'dm', name: 'Operator One', requireKeyword: false },
];
const line = (chat, text) =>
  `[message-hook] Received: channel=whatsapp chatId=${chat} senderId=+972500000000 text=${text}\n`;

test('loadSources: new sources[] format wins, jid normalized', () => {
  const s = lib.loadSources({ ccAgentGroup: '222', sources: [{ jid: '111111111111111111', name: 'G' }] });
  assert.deepStrictEqual(s, [{ jid: '111111111111111111@g.us', type: 'group', name: 'G', requireKeyword: false }]);
});

test('loadSources: legacy ccAgentGroup fallback', () => {
  const s = lib.loadSources({ ccAgentGroup: '222333' });
  assert.strictEqual(s.length, 1);
  assert.strictEqual(s[0].jid, '222333@g.us');
});

test('parseChunk: allowlisted group message becomes event', () => {
  const { events, remainder } = lib.parseChunk(line(GROUP, 'תבדוק משהו'), SOURCES);
  assert.strictEqual(events.length, 1);
  assert.strictEqual(events[0].source, 'Ops-Group');
  assert.strictEqual(events[0].chatId, GROUP);
  assert.strictEqual(events[0].sender, '+972500000000');
  assert.strictEqual(events[0].text, 'תבדוק משהו');
  assert.strictEqual(remainder, '');
});

test('parseChunk: foreign chatId dropped', () => {
  const { events } = lib.parseChunk(line('999999@g.us', 'hi'), SOURCES);
  assert.strictEqual(events.length, 0);
});

test('parseChunk: [CC] self message dropped, incl. RTL-mark prefix', () => {
  const both = line(GROUP, '[CC] תשובה שלנו') + line(GROUP, '‏[CC] עוד אחת');
  assert.strictEqual(lib.parseChunk(both, SOURCES).events.length, 0);
});

test('parseChunk: partial line kept as remainder, no event', () => {
  const partial = `[message-hook] Received: channel=whatsapp chatId=${GROUP} senderId=+1 text=half`;
  const r = lib.parseChunk(partial, SOURCES);
  assert.strictEqual(r.events.length, 0);
  assert.strictEqual(r.remainder, partial);
});

test('parseChunk: requireKeyword gates messages', () => {
  const kw = [{ jid: GROUP, type: 'group', name: 'G', requireKeyword: true }];
  assert.strictEqual(lib.parseChunk(line(GROUP, 'סתם הודעה'), kw).events.length, 0);
  assert.strictEqual(lib.parseChunk(line(GROUP, '@cc תעשה משהו'), kw).events.length, 1);
});

test('ymd formats with zero padding', () => {
  assert.strictEqual(lib.ymd(new Date(2026, 0, 5)), '20260105');
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /c/Users/<user>/.claude/skills/wa-cc-bridge && node --test wa-monitor.test.js`
Expected: FAIL — `Cannot find module './wa-monitor-lib'`

- [ ] **Step 3: Implement the lib**

```js
// wa-monitor-lib.js
'use strict';

const KEYWORDS = ['@cc', 'קלוד-קוד', 'קלוד', 'claude-code', 'claude code'];
const LINE_RE = /\[message-hook\] Received: channel=whatsapp chatId=(\S+) senderId=(\S+) text=(.*)$/;

function normalizeJid(v) {
  const s = String(v || '');
  return s.includes('@') ? s : s + '@g.us';
}

function loadSources(cfg) {
  if (Array.isArray(cfg.sources) && cfg.sources.length) {
    return cfg.sources.map((s) => ({
      jid: normalizeJid(s.jid),
      type: s.type || 'group',
      name: s.name || String(s.jid),
      requireKeyword: !!s.requireKeyword,
    }));
  }
  if (cfg.ccAgentGroup) {
    return [{ jid: normalizeJid(cfg.ccAgentGroup), type: 'group', name: 'Ops-Group', requireKeyword: false }];
  }
  return [];
}

function stripBidi(s) {
  return s.replace(/^[‎‏‪-‮﻿\s]+/, '');
}

function isSelf(text) {
  return stripBidi(text).startsWith('[CC]');
}

function hasKeyword(text) {
  const lower = text.toLowerCase();
  return KEYWORDS.some((k) => lower.includes(k));
}

function parseChunk(text, sources) {
  const nl = text.lastIndexOf('\n');
  if (nl === -1) return { events: [], remainder: text };
  const complete = text.slice(0, nl);
  const remainder = text.slice(nl + 1);
  const events = [];
  for (const rawLine of complete.split('\n')) {
    const m = rawLine.match(LINE_RE);
    if (!m) continue;
    const [, chatId, senderId, rawText] = m;
    const src = sources.find((s) => s.jid === chatId);
    if (!src) continue;
    const msg = rawText.trim();
    if (!msg || isSelf(msg)) continue;
    if (src.requireKeyword && !hasKeyword(msg)) continue;
    events.push({
      source: src.name, type: src.type, chatId,
      sender: senderId, text: msg, ts: new Date().toISOString(),
    });
  }
  return { events, remainder };
}

function ymd(d) {
  return String(d.getFullYear())
    + String(d.getMonth() + 1).padStart(2, '0')
    + String(d.getDate()).padStart(2, '0');
}

module.exports = { KEYWORDS, normalizeJid, loadSources, stripBidi, isSelf, hasKeyword, parseChunk, ymd };
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /c/Users/<user>/.claude/skills/wa-cc-bridge && node --test wa-monitor.test.js`
Expected: all tests PASS (8 pass, 0 fail)

- [ ] **Step 5: Bundle sync check**

Run: `ls -la /c/Users/<user>/.claude/governance-installer/bundle/skills/wa-cc-bridge/`
If `wa-monitor-lib.js` / `wa-monitor.test.js` missing or stale: `cp wa-monitor-lib.js wa-monitor.test.js /c/Users/<user>/.claude/governance-installer/bundle/skills/wa-cc-bridge/`

---

### Task 2: Watcher runner (`wa-monitor.js`) — session mode

**Files:**
- Create: `C:\Users\<user>\.claude\skills\wa-cc-bridge\wa-monitor.js`
- Test: `C:\Users\<user>\.claude\skills\wa-cc-bridge\wa-monitor.test.js` (integration section, appended)

**Interfaces:**
- Consumes: everything from `wa-monitor-lib.js` (Task 1 signatures).
- Produces: executable `node wa-monitor.js` (session mode). Env overrides: `OPENCLAW_HOME`, `WA_BRIDGE_CONFIG`, `WA_MONITOR_LOCK`, `WA_BRIDGE_OFF`, `WA_MONITOR_POLL_MS`, `WA_MONITOR_FROM_START=1`. stdout = one JSON line per event. Exit 3 = another live session monitor. Also exports nothing (script). `--daemon` flag reserved (implemented in Task 6; until then it must print `daemon mode not implemented` to stderr and exit 4). Task 6 modifies `handleEvent` and the `--daemon` branch.

- [ ] **Step 1: Append the failing integration tests**

```js
// appended to wa-monitor.test.js
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function mkTmpEnv() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-mon-'));
  fs.mkdirSync(path.join(dir, 'admin-logs'), { recursive: true });
  const d = new Date();
  const stamp = String(d.getFullYear()) + String(d.getMonth() + 1).padStart(2, '0') + String(d.getDate()).padStart(2, '0');
  const logPath = path.join(dir, 'admin-logs', 'admin-' + stamp + '.log');
  fs.writeFileSync(logPath, '');
  const cfgPath = path.join(dir, 'bridge.json');
  fs.writeFileSync(cfgPath, JSON.stringify({ sources: [{ jid: GROUP, type: 'group', name: 'Ops-Group' }] }));
  return {
    dir, logPath,
    env: {
      ...process.env,
      OPENCLAW_HOME: dir,
      WA_BRIDGE_CONFIG: cfgPath,
      WA_MONITOR_LOCK: path.join(dir, 'monitor.lock'),
      WA_BRIDGE_OFF: path.join(dir, 'off'),
      WA_MONITOR_POLL_MS: '100',
      WA_MONITOR_FROM_START: '1',
    },
  };
}

function startMonitor(env) {
  const child = spawn(process.execPath, [path.join(__dirname, 'wa-monitor.js')], { env });
  const events = [];
  let buf = '';
  child.stdout.on('data', (c) => {
    buf += c;
    let i;
    while ((i = buf.indexOf('\n')) !== -1) {
      const l = buf.slice(0, i); buf = buf.slice(i + 1);
      if (l.trim()) events.push(JSON.parse(l));
    }
  });
  return { child, events };
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

test('runner: emits event for appended allowlisted line, ignores [CC] and foreign', async () => {
  const t = mkTmpEnv();
  const { child, events } = startMonitor(t.env);
  try {
    await wait(400); // let it initialize past current EOF
    fs.appendFileSync(t.logPath, line(GROUP, 'בדיקה אחת'));
    fs.appendFileSync(t.logPath, line(GROUP, '[CC] תגובה שלנו'));
    fs.appendFileSync(t.logPath, line('999@g.us', 'זר'));
    await wait(800);
    assert.strictEqual(events.length, 1);
    assert.strictEqual(events[0].text, 'בדיקה אחת');
  } finally { child.kill(); }
});

test('runner: kill-switch file silences events', async () => {
  const t = mkTmpEnv();
  fs.writeFileSync(t.env.WA_BRIDGE_OFF, '');
  const { child, events } = startMonitor(t.env);
  try {
    await wait(400);
    fs.appendFileSync(t.logPath, line(GROUP, 'לא אמור להגיע'));
    await wait(800);
    assert.strictEqual(events.length, 0);
  } finally { child.kill(); }
});

test('runner: second session-mode instance exits code 3', async () => {
  const t = mkTmpEnv();
  const a = startMonitor(t.env);
  try {
    await wait(400); // first instance wrote the lock
    const code = await new Promise((resolve) => {
      const b = spawn(process.execPath, [path.join(__dirname, 'wa-monitor.js')], { env: t.env });
      b.on('exit', resolve);
    });
    assert.strictEqual(code, 3);
  } finally { a.child.kill(); }
});
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `cd /c/Users/<user>/.claude/skills/wa-cc-bridge && node --test wa-monitor.test.js`
Expected: lib tests PASS; 3 runner tests FAIL (`wa-monitor.js` missing)

- [ ] **Step 3: Implement the runner**

```js
#!/usr/bin/env node
// wa-monitor.js — event watcher for the WA-CC bridge v2.
// Session mode (default): stdout JSON line per allowlisted message (consumed by the harness Monitor tool).
// Daemon mode (--daemon): Task 6.
'use strict';

const fs = require('fs');
const path = require('path');
const { StringDecoder } = require('string_decoder');
const lib = require('./wa-monitor-lib');

const HOME = process.env.USERPROFILE || process.env.HOME;
const OPENCLAW_HOME = process.env.OPENCLAW_HOME || path.join(HOME, '.openclaw');
const CONFIG_PATH = process.env.WA_BRIDGE_CONFIG || path.join(HOME, '.claude', '.wa-bridge.json');
const LOCK_PATH = process.env.WA_MONITOR_LOCK || path.join(HOME, '.claude', 'wa-monitor.lock');
const OFF_PATH = process.env.WA_BRIDGE_OFF || path.join(HOME, '.claude', 'wa-bridge-off');
const POLL_MS = parseInt(process.env.WA_MONITOR_POLL_MS || '1000', 10);
const FROM_START = process.env.WA_MONITOR_FROM_START === '1';
const DAEMON = process.argv.includes('--daemon');
const LOCK_FRESH_MS = 60000;
const HEARTBEAT_MS = 15000;

if (DAEMON) {
  process.stderr.write('daemon mode not implemented\n');
  process.exit(4);
}

let sources;
try {
  sources = lib.loadSources(JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')));
} catch (e) {
  process.stderr.write('[wa-monitor] cannot read config ' + CONFIG_PATH + ': ' + e.message + '\n');
  process.exit(2);
}
if (!sources.length) {
  process.stderr.write('[wa-monitor] no sources configured\n');
  process.exit(2);
}

function readLock() { try { return JSON.parse(fs.readFileSync(LOCK_PATH, 'utf8')); } catch { return null; } }
function lockFresh(l) { return !!(l && Date.now() - new Date(l.heartbeat).getTime() < LOCK_FRESH_MS); }
function writeLock() {
  fs.writeFileSync(LOCK_PATH, JSON.stringify({ pid: process.pid, mode: 'session', heartbeat: new Date().toISOString() }));
}

const existing = readLock();
if (lockFresh(existing) && existing.pid !== process.pid) {
  process.stderr.write('[wa-monitor] another session monitor active (pid ' + existing.pid + ')\n');
  process.exit(3);
}
writeLock();
let lastBeat = Date.now();

let state = null;
let remainder = '';
let decoder = new StringDecoder('utf8');

function sizeOf(p) { try { return fs.statSync(p).size; } catch { return 0; } }
function todayLog() {
  const d = lib.ymd(new Date());
  return { d, p: path.join(OPENCLAW_HOME, 'admin-logs', 'admin-' + d + '.log') };
}

function handleEvent(ev) {
  process.stdout.write(JSON.stringify(ev) + '\n');
}

function tick() {
  try {
    if (fs.existsSync(OFF_PATH)) return;
    if (Date.now() - lastBeat > HEARTBEAT_MS) { writeLock(); lastBeat = Date.now(); }
    const t = todayLog();
    if (!state) {
      state = { d: t.d, offset: FROM_START ? 0 : sizeOf(t.p) };
    } else if (state.d !== t.d) {
      state = { d: t.d, offset: 0 };
      remainder = '';
      decoder = new StringDecoder('utf8');
    }
    let size = sizeOf(t.p);
    if (size < state.offset) { state.offset = 0; remainder = ''; decoder = new StringDecoder('utf8'); }
    while (size > state.offset) {
      const n = Math.min(size - state.offset, 65536);
      const buf = Buffer.alloc(n);
      const fd = fs.openSync(t.p, 'r');
      let read = 0;
      try { read = fs.readSync(fd, buf, 0, n, state.offset); } finally { fs.closeSync(fd); }
      if (read <= 0) break;
      state.offset += read;
      const chunk = decoder.write(buf.subarray(0, read));
      const res = lib.parseChunk(remainder + chunk, sources);
      remainder = res.remainder;
      for (const ev of res.events) handleEvent(ev);
      size = sizeOf(t.p);
    }
  } catch (e) {
    process.stderr.write('[wa-monitor] ' + e.message + '\n');
  }
}

process.on('exit', () => { try { const l = readLock(); if (l && l.pid === process.pid) fs.unlinkSync(LOCK_PATH); } catch {} });
setInterval(tick, POLL_MS);
tick();
```

- [ ] **Step 4: Run all tests to verify they pass**

Run: `cd /c/Users/<user>/.claude/skills/wa-cc-bridge && node --test wa-monitor.test.js`
Expected: ALL tests PASS (11 pass, 0 fail)

- [ ] **Step 5: Idle sanity vs the REAL log (read-only, 20s)**

Run: `cd /c/Users/<user>/.claude/skills/wa-cc-bridge && timeout 20 node wa-monitor.js; echo "exit=$?"`
Expected: no stdout events (nobody wrote to the group), no stderr errors, exit=124 (timeout). Lock file `~/.claude/wa-monitor.lock` created then removed on exit.

- [ ] **Step 6: Bundle sync check** — same as Task 1 Step 5, now including `wa-monitor.js`.

---

### Task 3: Config migration + live arming + Phase-1 E2E (group), DM capture

**Files:**
- Modify: `C:\Users\<user>\.claude\.wa-bridge.json`
- Uses: Monitor tool (harness), `~/.claude/skills/whatsapp/send.js`

**Interfaces:**
- Consumes: `wa-monitor.js` session mode (Task 2).
- Produces: live armed persistent Monitor; extended config with `sources[]` (+ DM source if verified). The exact Monitor arming call used here is the one Task 4's hook text instructs future sessions to run.

- [ ] **Step 1: Extend the config (preserve legacy fields)**

New `~/.claude/.wa-bridge.json` content (real group JID kept from the current file):

```json
{
  "_comment": "LOCAL-ONLY WhatsApp-bridge identifiers. Gitignored - never committed. Read by skills/wa-cc-bridge/wa-monitor.js (v2), legacy poll.js, hooks/governance/wa-send.js.",
  "ccAgentGroup": "120363000000000000",
  "phone": "972500000000",
  "sources": [
    { "jid": "120363000000000000@g.us", "type": "group", "name": "Ops-Group", "requireKeyword": false }
  ],
  "daemonCwd": "c:\\dev\\example-project"
}
```

- [ ] **Step 2: Verify the runner loads it**

Run: `cd /c/Users/<user>/.claude/skills/wa-cc-bridge && node -e "const l=require('./wa-monitor-lib');console.log(JSON.stringify(l.loadSources(require(process.env.USERPROFILE+'/.claude/.wa-bridge.json'))))"`
Expected: one source, jid `120363000000000000@g.us`.

- [ ] **Step 3: Arm the live Monitor (persistent)**

Use the Monitor tool:
- command: `node "%USERPROFILE%\.claude\skills\wa-cc-bridge\wa-monitor.js"` (in the harness use the absolute path `C:\Users\<user>\.claude\skills\wa-cc-bridge\wa-monitor.js`)
- description: `WhatsApp bridge: allowlisted incoming messages`
- persistent: `true`

Expected: monitor starts, no immediate events.

- [ ] **Step 4: E2E group round-trip with the owner**

Ask the operator (WhatsApp, via send.js) to send ANY message in the Ops-Group group (no @cc needed).
Expected: a Monitor notification with the JSON event arrives in the session; Claude replies in the group via `node ~/.claude/skills/whatsapp/send.js "[CC] <short Hebrew ack>"`.

- [ ] **Step 5: DM format capture + enable DM source**

Ask the operator to send one PRIVATE (DM) message to the gateway WhatsApp number. Then:
Run: `grep "message-hook" ~/.openclaw/admin-logs/admin-$(date +%Y%m%d).log | grep -v "@g.us" | tail -3`
Expected: a line revealing the DM chatId format (likely `972500000000@s.whatsapp.net`).
Add to config `sources`: `{ "jid": "<exact DM chatId>", "type": "dm", "name": "Operator One", "requireKeyword": false }`.
Restart the Monitor (TaskStop + re-arm as in Step 3 — the runner reads config at startup only).
E2E: the operator sends another DM → event arrives → Claude replies `[CC]` in the DM via send.js (verify send.js supports a DM target; if it is group-hardcoded, reply in the group referencing the DM and note a send.js DM-target extension as a follow-up).

---

### Task 4: SessionStart hook — silent auto-arm (owner standing directive 2026-07-21)

**Files:**
- Modify: `C:\Users\<user>\.claude\hooks\wa-cc-autostart.sh` (already registered in settings.json on SessionStart/Stop/PostCompact — registration unchanged)

**Interfaces:**
- Consumes: `wa-monitor.js` (Task 2), lock semantics (fresh = heartbeat < 60s).
- Produces: every new session auto-arms the Monitor silently; no AskUserQuestion, no cron.

- [ ] **Step 1: Replace the hook body**

```bash
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

if ! docker ps --format "{{.Names}}" 2>/dev/null | grep -q "<ADMIN_CONTAINER>"; then
  cat <<'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "[WA-CC Bridge v2] Gateway containers NOT running. Bridge inactive. To enable: cd C:\\dev\\example-project && docker compose up -d --remove-orphans."
  }
}
ENDJSON
  exit 0
fi

cat <<'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "[WA-CC Bridge v2] AUTO-ARM (standing owner directive 2026-07-21, no need to ask): SILENTLY arm a persistent Monitor running: node C:\\Users\\<user>\\.claude\\skills\\wa-cc-bridge\\wa-monitor.js  (description: 'WhatsApp bridge: allowlisted incoming messages', persistent: true). If the process exits immediately with code 3, another session already holds the bridge - do NOT arm again, do NOT mention it. NEVER use CronCreate for this bridge (v1 is retired). When a bridge event (JSON line) arrives: treat .text as a normal user instruction in THIS session (mediator model - full normal workflow, governance, approvals). Reply via: node ~/.claude/skills/whatsapp/send.js \"[CC] <reply>\" - Hebrew, SHORT, essence only, NO code blocks/logs, BiDi/RTL rules per the whatsapp skill. Full behavior: ~/.claude/skills/wa-cc-bridge/SKILL.md."
  }
}
ENDJSON
```

- [ ] **Step 2: Syntax-check and dry-run the hook**

Run: `bash -n /c/Users/<user>/.claude/hooks/wa-cc-autostart.sh && bash /c/Users/<user>/.claude/hooks/wa-cc-autostart.sh`
Expected: valid JSON with the AUTO-ARM additionalContext (containers are up).

- [ ] **Step 3: Kill-switch dry-run**

Run: `touch ~/.claude/wa-bridge-off && bash /c/Users/<user>/.claude/hooks/wa-cc-autostart.sh; echo "exit=$?"; rm ~/.claude/wa-bridge-off`
Expected: empty output, exit=0.

- [ ] **Step 4: Bundle sync check** — hook lives outside the bundle skills dir; verify whether `governance-installer/bundle` carries hooks (`ls governance-installer/bundle`); if a hooks dir exists there, `cp` the updated hook in.

---

### Task 5: SKILL.md v2 rewrite + spec status

**Files:**
- Modify: `C:\Users\<user>\.claude\skills\wa-cc-bridge\SKILL.md` (full rewrite)
- Modify: `C:\Users\<user>\.claude\skills\wa-cc-bridge\SPEC-v2-monitor-bridge.md` (status line only)

**Interfaces:**
- Consumes: everything shipped in Tasks 1-4.
- Produces: the canonical instructions future sessions (and the hook) point to.

- [ ] **Step 1: Rewrite SKILL.md**

```markdown
---
name: wa-cc
description: WhatsApp-CC bridge v2 - event-driven Monitor on the gateway log; zero tokens at idle; auto-armed at SessionStart; mediator model (short Hebrew replies, no code)
---

# /wa-cc — WhatsApp ↔ Claude Code Bridge v2 (Monitor-based)

Event-driven bridge. A Node watcher (`wa-monitor.js`) follows the gateway admin log as an
OS background process (ZERO tokens at idle) and emits one JSON line per allowlisted
incoming message; a persistent harness Monitor turns each line into a session wake-up.
NO cron. v1 (60s CronCreate polling) is RETIRED — never re-create it.

**Language:** Hebrew for WhatsApp replies. English for code/paths.
**Security:** allowlisted sources ONLY (`~/.claude/.wa-bridge.json` `sources[]` — the
Ops-Group group + the operator's private chat). Never process any other chat.

## Activation (normally AUTOMATIC)

The SessionStart hook `wa-cc-autostart.sh` auto-arms the bridge silently (owner standing
directive 2026-07-21). Manual arming (only if the hook did not run):

1. Verify gateway: `docker ps --format "{{.Names}}" | grep <ADMIN_CONTAINER>`
2. Arm a persistent Monitor with command:
   `node C:\Users\<user>\.claude\skills\wa-cc-bridge\wa-monitor.js`
   description: `WhatsApp bridge: allowlisted incoming messages`, persistent: true.
3. Exit code 3 = another session already holds the bridge (fresh
   `~/.claude/wa-monitor.lock`) — do not arm again.

## When an event arrives (mediator model — owner rules 2026-07-21)

Each event is `{"source","type","chatId","sender","text","ts"}`.

1. Treat `.text` as a normal user instruction in THIS session. Full normal workflow —
   planning, specs, approvals, QA, governance — exactly as if typed in the terminal.
2. Reply via `node ~/.claude/skills/whatsapp/send.js "[CC] <reply>"`:
   - SHORT, essence-only Hebrew. No code blocks, no logs, no markdown, no emojis.
   - Summarize session output; do not paste it.
   - Questions to the operator: one short message with numbered options; the answer arrives as
     the next bridge event.
3. The bridge keeps NO memory of its own (no shared-session file) — the session's
   regular memory is the only memory.

## Deactivation

- This session: TaskStop on the Monitor.
- Everything (both layers, instantly): `touch ~/.claude/wa-bridge-off`
  (delete the file to re-enable).

## Components

| Component | Path |
|---|---|
| Watcher (session+daemon modes) | `~/.claude/skills/wa-cc-bridge/wa-monitor.js` |
| Parser lib + tests | `wa-monitor-lib.js`, `wa-monitor.test.js` (run: `node --test`) |
| Allowlist config (local-only) | `~/.claude/.wa-bridge.json` |
| Singleton lock | `~/.claude/wa-monitor.lock` |
| Kill-switch | `~/.claude/wa-bridge-off` |
| Auto-arm hook | `~/.claude/hooks/wa-cc-autostart.sh` |
| Spec / Plan | `SPEC-v2-monitor-bridge.md` / `PLAN-v2-monitor-bridge.md` |
| Legacy v1 (retired) | `~/.claude/skills/wa-cc-poll/poll.js` — do not use |
```

- [ ] **Step 2: Flip the spec status**

In `SPEC-v2-monitor-bridge.md` change the Status line to:
`- **Status:** APPROVED (owner 2026-07-21) — Phase 1 implemented; Phase 2 per Tasks 6-7`

- [ ] **Step 3: Bundle sync check** — copy updated `SKILL.md` (and spec) into `governance-installer/bundle/skills/wa-cc-bridge/` if the auto-sync did not.

---

### Task 6: Daemon mode (`--daemon`) — defer-or-spawn

**Files:**
- Modify: `C:\Users\<user>\.claude\skills\wa-cc-bridge\wa-monitor.js` (replace the `--daemon` stub; extract `handleEvent`)
- Test: `C:\Users\<user>\.claude\skills\wa-cc-bridge\wa-monitor.test.js` (daemon section, appended)

**Interfaces:**
- Consumes: Task 2 runner internals; config field `daemonCwd`; lock semantics.
- Produces: `node wa-monitor.js --daemon` — on event: fresh session lock → skip; else spawn `claude -p` headless (serial queue), resume continuity via `~/.claude/wa-daemon-state.json` `{sessionId}`, log to `~/.claude/logs/wa-daemon.log`. Env override for tests: `WA_DAEMON_CLAUDE_CMD` (fake claude), `WA_DAEMON_STATE`, `WA_DAEMON_LOG`.

- [ ] **Step 1: Verify the headless CLI contract (before any code)**

Run: `claude --help 2>&1 | grep -E "print|resume|output-format" ; claude -p "Reply with the word ok only" --output-format json 2>&1 | head -c 400`
Expected: flags exist; JSON output contains `"session_id"` (note the exact field name and shape for Step 3). If the contract differs, adapt the daemon code below to the observed shape before writing it.

- [ ] **Step 2: Append the failing daemon tests**

```js
// appended to wa-monitor.test.js
test('daemon: fresh session lock defers (no spawn)', async () => {
  const t = mkTmpEnv();
  fs.writeFileSync(t.env.WA_MONITOR_LOCK, JSON.stringify({ pid: 99999, mode: 'session', heartbeat: new Date().toISOString() }));
  const calls = path.join(t.dir, 'calls.txt');
  const env = daemonEnv(t, calls);
  const child = spawn(process.execPath, [path.join(__dirname, 'wa-monitor.js'), '--daemon'], { env });
  try {
    await wait(400);
    fs.appendFileSync(t.logPath, line(GROUP, 'הודעה בזמן שסשן פתוח'));
    await wait(800);
    assert.strictEqual(fs.existsSync(calls), false);
  } finally { child.kill(); }
});

test('daemon: stale/no lock spawns claude with the message', async () => {
  const t = mkTmpEnv();
  const calls = path.join(t.dir, 'calls.txt');
  const env = daemonEnv(t, calls);
  const child = spawn(process.execPath, [path.join(__dirname, 'wa-monitor.js'), '--daemon'], { env });
  try {
    await wait(400);
    fs.appendFileSync(t.logPath, line(GROUP, 'אין סשן פתוח'));
    await wait(1200);
    assert.ok(fs.existsSync(calls), 'fake claude was invoked');
    const rec = fs.readFileSync(calls, 'utf8');
    assert.ok(rec.includes('אין סשן פתוח'));
    const st = JSON.parse(fs.readFileSync(env.WA_DAEMON_STATE, 'utf8'));
    assert.strictEqual(st.sessionId, 'sess-fake-1');
  } finally { child.kill(); }
});

function daemonEnv(t, callsFile) {
  // fake-claude.js records argv and prints a claude-like JSON result
  const fake = path.join(t.dir, 'fake-claude.js');
  fs.writeFileSync(fake, `
    const fs = require('fs');
    fs.appendFileSync(${JSON.stringify(callsFile)}, JSON.stringify(process.argv) + '\\n');
    process.stdout.write(JSON.stringify({ session_id: 'sess-fake-1', result: 'ok' }));
  `);
  return {
    ...t.env,
    WA_DAEMON_CLAUDE_CMD: process.execPath + ' ' + fake,
    WA_DAEMON_STATE: path.join(t.dir, 'daemon-state.json'),
    WA_DAEMON_LOG: path.join(t.dir, 'daemon.log'),
  };
}
```

- [ ] **Step 3: Run tests (new ones fail), then implement the daemon branch**

Replace the `--daemon` stub in `wa-monitor.js` with:

```js
// --- daemon support (replaces the stub; place after config load) ---
const STATE_PATH = process.env.WA_DAEMON_STATE || path.join(HOME, '.claude', 'wa-daemon-state.json');
const DLOG_PATH = process.env.WA_DAEMON_LOG || path.join(HOME, '.claude', 'logs', 'wa-daemon.log');
const CLAUDE_CMD = process.env.WA_DAEMON_CLAUDE_CMD || 'claude';
const DAEMON_CWD = (() => { try { return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')).daemonCwd || HOME; } catch { return HOME; } })();

function dlog(msg) {
  try {
    fs.mkdirSync(path.dirname(DLOG_PATH), { recursive: true });
    fs.appendFileSync(DLOG_PATH, new Date().toISOString() + ' ' + msg + '\n');
  } catch {}
}

let queue = Promise.resolve();
function daemonHandle(ev) {
  const l = readLock();
  if (lockFresh(l) && l.mode === 'session') { dlog('defer-to-session: ' + ev.text.slice(0, 60)); return; }
  queue = queue.then(() => spawnClaude(ev)).catch((e) => dlog('spawn-error: ' + e.message));
}

function spawnClaude(ev) {
  return new Promise((resolve) => {
    const { execFile } = require('child_process');
    let st = {}; try { st = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')); } catch {}
    const prompt =
      'WhatsApp bridge message from ' + ev.source + ' (' + ev.sender + '): "' + ev.text + '". ' +
      'Mediator model: execute as a normal user instruction with the full standard session workflow. ' +
      'Reply to the sender via: node ~/.claude/skills/whatsapp/send.js "[CC] <short Hebrew reply, essence only, no code>".';
    const parts = CLAUDE_CMD.split(' ');
    const args = [...parts.slice(1), '-p', prompt, '--output-format', 'json'];
    if (st.sessionId) args.push('--resume', st.sessionId);
    dlog('spawn: ' + ev.text.slice(0, 60));
    execFile(parts[0], args, { cwd: DAEMON_CWD, timeout: 15 * 60 * 1000, maxBuffer: 16 * 1024 * 1024 },
      (err, stdout) => {
        if (err) dlog('claude-exit-error: ' + err.message);
        try {
          const out = JSON.parse(stdout);
          if (out.session_id) fs.writeFileSync(STATE_PATH, JSON.stringify({ sessionId: out.session_id }));
          dlog('done: session=' + (out.session_id || '?'));
        } catch (e) { dlog('parse-error: ' + e.message + ' raw=' + String(stdout).slice(0, 200)); }
        resolve();
      });
  });
}
```

And route events by mode in `handleEvent`:

```js
function handleEvent(ev) {
  if (DAEMON) return daemonHandle(ev);
  process.stdout.write(JSON.stringify(ev) + '\n');
}
```

Remove the top-of-file `if (DAEMON) { ...exit(4); }` stub. Daemon mode must NOT take the session lock and must NOT exit on a fresh foreign lock (it always watches; the lock only gates spawning).

- [ ] **Step 4: Run all tests**

Run: `cd /c/Users/<user>/.claude/skills/wa-cc-bridge && node --test wa-monitor.test.js`
Expected: ALL tests PASS (13 pass, 0 fail)

- [ ] **Step 5: Bundle sync check** — recopy `wa-monitor.js` + test file.

---

### Task 7: 24/7 Scheduled Task + Phase-2 E2E

**Files:**
- Create: `C:\Users\<user>\.claude\skills\wa-cc-bridge\register-daemon-task.ps1`

**Interfaces:**
- Consumes: `wa-monitor.js --daemon` (Task 6).
- Produces: auto-starting, self-restarting daemon `WA-CC-Bridge-Daemon`.

- [ ] **Step 1: Write the registration script**

```powershell
# register-daemon-task.ps1 - register the WA-CC bridge daemon as a logon Scheduled Task
$name = "WA-CC-Bridge-Daemon"
$node = (Get-Command node).Source
$script = "$env:USERPROFILE\.claude\skills\wa-cc-bridge\wa-monitor.js"
$action = New-ScheduledTaskAction -Execute $node -Argument "`"$script`" --daemon"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit (New-TimeSpan -Days 3650) -StartWhenAvailable -Hidden
Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings
Start-ScheduledTask -TaskName $name
Get-ScheduledTask -TaskName $name | Format-List TaskName, State
```

- [ ] **Step 2: Register and verify**

Run (PowerShell): `& "$env:USERPROFILE\.claude\skills\wa-cc-bridge\register-daemon-task.ps1"`
Expected: `State: Running`. Then verify process: `Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {$_.CommandLine -like '*wa-monitor.js*--daemon*'} | Select-Object ProcessId` → one PID.

- [ ] **Step 3: E2E defer path (session open)**

With THIS session's Monitor armed: the operator sends a group message.
Expected: THIS session handles it; `~/.claude/logs/wa-daemon.log` shows `defer-to-session`.

- [ ] **Step 4: E2E spawn path (no session)**

TaskStop this session's Monitor (stale lock within 60s). The operator sends a group message.
Expected: `wa-daemon.log` shows `spawn:` then `done: session=<id>`; a `[CC]` reply arrives in the group from the spawned headless session (which ran the full SessionStart protocol via hooks). Re-arm this session's Monitor afterwards.

- [ ] **Step 5: Bundle sync check** — copy `register-daemon-task.ps1` into the bundle mirror.

---

### Task 8: Wrap — memory, docs, owner notification

**Files:**
- Create: `C:\Users\<user>\.claude\projects\c--dev-example-project\memory\wa-bridge-v2-monitor.md`
- Modify: `C:\Users\<user>\.claude\projects\c--dev-example-project\memory\MEMORY.md` (one index line)

**Interfaces:**
- Consumes: shipped Tasks 1-7.
- Produces: durable memory of the new architecture + the Phase-3 (external-sync retirement) marker.

- [ ] **Step 1: Write the memory file**

```markdown
---
name: wa-bridge-v2-monitor
description: WA bridge v2 LIVE - event-driven Monitor watcher (zero-token idle), auto-armed at SessionStart, 24/7 daemon fallback; v1 cron RETIRED; Phase 3 = external-sync retirement (owner-gated)
metadata:
  type: project
---

WhatsApp-CC bridge v2 (2026-07-21, owner-approved): `wa-monitor.js` watches the gateway
admin log as an OS process; session Monitor wakes Claude only on real allowlisted
messages (Ops-Group group + operator DM); daemon Scheduled Task spawns headless `claude -p`
(resume continuity) when no session is open. NEVER re-create the v1 60s cron (token
burn + session noise - the exact problem v2 fixed). Kill-switch: `~/.claude/wa-bridge-off`.
Mediator rules: WA replies SHORT Hebrew essence-only, no code. Spec/plan/skill:
`~/.claude/skills/wa-cc-bridge/`.

**Phase 3 (owner decision 2026-07-21, gated on v2 full success):** retire the external
sync architecture in the project repo (SYNC-PROTOCOL.md, ownership map, dual handoff
blocks) - the WA agent obsoletes their agent. Coordinate as a proper project-repo change
when the operator green-lights. [[external-parallel-agent]]
```

- [ ] **Step 2: Add the MEMORY.md index line** (top of list)

`- [WA bridge v2 Monitor LIVE + Phase-3 external-sync retirement gate (2026-07-21)](wa-bridge-v2-monitor.md) — event-driven watcher, zero-token idle, auto-arm hook, 24/7 daemon; v1 cron RETIRED; external-sync retirement owner-gated on v2 success.`

- [ ] **Step 3: Owner WA notification (checkpoint)**

Run: `node ~/.claude/skills/whatsapp/send.js "[CC] גשר v2 פעיל: מאזין מיידי בקבוצה ובפרטי, אפס בזבוז טוקנים, עובד גם בלי סשן פתוח. אפשר לכתוב לי כאן חופשי."`

---

## Self-Review (done at plan time)

- Spec coverage: §2 zero-token (T1-2), §3 allowlist+DM (T1,T3), §4 two layers+lock (T2,T6,T7), §5 mediator/no bridge memory (T4 hook text, T5 SKILL, T6 prompt), §6 reply style (T4,T5,T6), §7 auto-arm+kill-switch (T2,T4,T7), §8 QA 1-5 (T1-2 tests, T3 E2E, T7 E2E), §9 Phase 3 marker (T8). Gap intentionally deferred: send.js DM-target support — surfaced in T3 Step 5 as a conditional follow-up.
- Placeholders: none; all code inline.
- Type consistency: event shape `{source,type,chatId,sender,text,ts}` identical in T1 tests, T2 runner, T6 prompt; lock shape `{pid,mode,heartbeat}` identical in T2/T6/T7.
