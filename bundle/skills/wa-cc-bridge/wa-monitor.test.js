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
// Every legacy parseChunk test predates the operator allowlist and was written to exercise
// SOURCE filtering, so they route through a wrapper that supplies a valid operator. The
// allowlist itself is covered by its own tests below.
const OPERATORS = lib.loadOperators({ operators: [{ name: 'Operator One', phone: '+972500000000' }] });
const parseAs = (text, sources = SOURCES, selfIds) => lib.parseChunk(text, sources, selfIds, OPERATORS);
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
  const { events, remainder } = parseAs(line(GROUP, 'תבדוק משהו'), SOURCES);
  assert.strictEqual(events.length, 1);
  assert.strictEqual(events[0].source, 'Ops-Group');
  assert.strictEqual(events[0].chatId, GROUP);
  assert.strictEqual(events[0].sender, '+972500000000');
  assert.strictEqual(events[0].text, 'תבדוק משהו');
  assert.strictEqual(remainder, '');
});

test('parseChunk: foreign chatId dropped', () => {
  const { events } = parseAs(line('999999@g.us', 'hi'), SOURCES);
  assert.strictEqual(events.length, 0);
});

test('parseChunk: [CC] self message dropped, incl. RTL-mark prefix', () => {
  const both = line(GROUP, '[CC] תשובה שלנו') + line(GROUP, '‏[CC] עוד אחת');
  assert.strictEqual(parseAs(both, SOURCES).events.length, 0);
});

test('parseChunk: partial line kept as remainder, no event', () => {
  const partial = `[message-hook] Received: channel=whatsapp chatId=${GROUP} senderId=+1 text=half`;
  const r = parseAs(partial, SOURCES);
  assert.strictEqual(r.events.length, 0);
  assert.strictEqual(r.remainder, partial);
});

test('parseChunk: sticker-only messages are dropped', () => {
  assert.strictEqual(parseAs(line(GROUP, '<media:sticker>'), SOURCES).events.length, 0);
});

test('parseChunk: message tagging a FOREIGN number is dropped (owner rule)', () => {
  const selfIds = ['972509999999', '100000000000001'];
  const foreign = parseAs(line(GROUP, '@100000000000002 אתה פה?'), SOURCES, selfIds);
  assert.strictEqual(foreign.events.length, 0);
});

test('parseChunk: message tagging OUR number is kept', () => {
  const selfIds = ['972509999999', '100000000000001'];
  const own = parseAs(line(GROUP, '@100000000000001 תבדוק משהו'), SOURCES, selfIds);
  assert.strictEqual(own.events.length, 1);
});

test('parseChunk: no selfIds configured keeps mention messages (fail-open)', () => {
  const r = parseAs(line(GROUP, '@100000000000002 שאלה'), SOURCES);
  assert.strictEqual(r.events.length, 1);
});

test('parseChunk: requireKeyword gates messages', () => {
  const kw = [{ jid: GROUP, type: 'group', name: 'G', requireKeyword: true }];
  assert.strictEqual(parseAs(line(GROUP, 'סתם הודעה'), kw).events.length, 0);
  assert.strictEqual(parseAs(line(GROUP, '@cc תעשה משהו'), kw).events.length, 1);
});

test('ymd formats with zero padding', () => {
  assert.strictEqual(lib.ymd(new Date(2026, 0, 5)), '20260105');
});

test('resolveSources: project cwd match wins over global', () => {
  const cfg = { ccAgentGroup: '222', projects: { 'c:\\dev\\proj-a': { jid: '333@g.us', name: 'A' } } };
  const s = lib.resolveSources(cfg, 'C:\\dev\\proj-a\\sub\\dir');
  assert.deepStrictEqual(s, [{ jid: '333@g.us', type: 'group', name: 'A', requireKeyword: false }]);
});

test('resolveSources: non-matching cwd falls back to global sources', () => {
  const cfg = { ccAgentGroup: '222', projects: { 'c:\\dev\\proj-a': { jid: '333@g.us' } } };
  const s = lib.resolveSources(cfg, 'C:\\other\\place');
  assert.strictEqual(s[0].jid, '222@g.us');
});

test('resolveSources: slash direction and case are normalized', () => {
  const cfg = { projects: { 'c:/dev/Proj-A': { jid: '333@g.us' } }, ccAgentGroup: '222' };
  assert.strictEqual(lib.resolveSources(cfg, 'C:\\DEV\\PROJ-A')[0].jid, '333@g.us');
});

test('resolveSources: prefix match requires a path boundary', () => {
  const cfg = { projects: { 'c:/dev/proj': { jid: '333@g.us' } }, ccAgentGroup: '222' };
  assert.strictEqual(lib.resolveSources(cfg, 'c:/dev/proj-other')[0].jid, '222@g.us');
});

// ---------- runner integration ----------
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
  // The fixture must name an operator: the bridge authorizes per PERSON, so a config with
  // only a group would (correctly) drop every line these tests feed it.
  fs.writeFileSync(cfgPath, JSON.stringify({
    sources: [{ jid: GROUP, type: 'group', name: 'Ops-Group' }],
    operators: [{ name: 'Test Operator', phone: '+972500000000' }],
  }));
  return {
    dir, logPath,
    env: {
      ...process.env,
      OPENCLAW_HOME: dir,
      WA_BRIDGE_CONFIG: cfgPath,
      WA_MONITOR_LOCK: path.join(dir, 'monitor.lock'),
      WA_BRIDGE_OFF: path.join(dir, 'off'),
      WA_MONITOR_STATE: path.join(dir, 'read-state.json'),
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

test('runner: <media:audio> event is transcribed via the configured transcriber', async () => {
  const t = mkTmpEnv();
  const mediaDir = path.join(t.dir, 'media-in');
  fs.mkdirSync(mediaDir, { recursive: true });
  const fakeT = path.join(t.dir, 'fake-transcribe.js');
  fs.writeFileSync(fakeT, "process.stdout.write('תמלול בדיקה');");
  const env = { ...t.env, WA_MEDIA_DIR: mediaDir, WA_TRANSCRIBE_PYTHON: process.execPath, WA_TRANSCRIBE_SCRIPT: fakeT };
  const { child, events } = startMonitor(env);
  try {
    await wait(400);
    fs.writeFileSync(path.join(mediaDir, 'note.ogg'), 'x');
    fs.appendFileSync(t.logPath, line(GROUP, '<media:audio>'));
    await wait(1200);
    assert.strictEqual(events.length, 1);
    assert.strictEqual(events[0].text, '[voice] תמלול בדיקה');
    assert.strictEqual(events[0].media, 'note.ogg');
  } finally { child.kill(); }
});

test('runner: resumes from persisted offset - messages during downtime are NOT lost', async () => {
  const t = mkTmpEnv();
  const statePath = path.join(t.dir, 'read-state.json');
  const env1 = { ...t.env, WA_MONITOR_STATE: statePath };
  const a = startMonitor(env1);
  try {
    await wait(400);
    fs.appendFileSync(t.logPath, line(GROUP, 'הודעה ראשונה'));
    await wait(600);
    assert.strictEqual(a.events.length, 1);
  } finally { a.child.kill(); }
  await wait(200);
  fs.rmSync(env1.WA_MONITOR_LOCK, { force: true }); // restart procedure clears the lock
  // downtime: a message arrives while no watcher is running
  fs.appendFileSync(t.logPath, line(GROUP, 'הודעה בזמן השבתה'));
  // restart WITHOUT from-start: must resume from the persisted offset, not EOF
  const env2 = { ...env1 };
  delete env2.WA_MONITOR_FROM_START;
  const b = startMonitor(env2);
  try {
    await wait(800);
    assert.strictEqual(b.events.length, 1, 'downtime message recovered');
    assert.strictEqual(b.events[0].text, 'הודעה בזמן השבתה');
  } finally { b.child.kill(); }
});

// ---------- auto-ack ----------
function ackEnv(t) {
  const gwDir = path.join(t.dir, 'gateway-logs');
  fs.mkdirSync(gwDir, { recursive: true });
  const d = new Date();
  const stamp = String(d.getFullYear()) + String(d.getMonth() + 1).padStart(2, '0') + String(d.getDate()).padStart(2, '0');
  const gwLog = path.join(gwDir, 'gateway-' + stamp + '.log');
  fs.writeFileSync(gwLog, '');
  const ackRecord = path.join(t.dir, 'ack-record.txt');
  const fakeSend = path.join(t.dir, 'fake-send.js');
  fs.writeFileSync(fakeSend, `
    const fs = require('fs');
    fs.writeFileSync(${JSON.stringify(ackRecord)}, JSON.stringify({ argv: process.argv.slice(2), group: process.env.CC_AGENT_GROUP }));
  `);
  return {
    gwLog, ackRecord,
    env: { ...t.env, WA_GATEWAY_LOG_DIR: gwDir, WA_ACK_SEND_SCRIPT: fakeSend, WA_ACK_DELAY_MS: '400' },
  };
}

test('auto-ack: fires when no outbound reply within the window', async () => {
  const t = mkTmpEnv();
  const a = ackEnv(t);
  const { child } = startMonitor(a.env);
  try {
    await wait(400);
    fs.appendFileSync(t.logPath, line(GROUP, 'משימה חדשה'));
    await wait(1500);
    assert.ok(fs.existsSync(a.ackRecord), 'ack was sent');
    const rec = JSON.parse(fs.readFileSync(a.ackRecord, 'utf8'));
    assert.strictEqual(rec.group, GROUP.replace('@g.us', ''));
    assert.ok(rec.argv[0].startsWith('[CC]'));
  } finally { child.kill(); }
});

test('auto-ack: suppressed when an outbound reply happened in the window', async () => {
  const t = mkTmpEnv();
  const a = ackEnv(t);
  const { child } = startMonitor(a.env);
  try {
    await wait(400);
    fs.appendFileSync(t.logPath, line(GROUP, 'שאלה מהירה'));
    await wait(150);
    fs.appendFileSync(a.gwLog, `2026-01-01T00:00:00.000Z [whatsapp] Sending message -> ${GROUP}\n`);
    await wait(1200);
    assert.strictEqual(fs.existsSync(a.ackRecord), false, 'no ack after a real reply');
  } finally { child.kill(); }
});

test('auto-ack: daemon does NOT ack while deferring to a live session', async () => {
  const t = mkTmpEnv();
  const a = ackEnv(t);
  fs.writeFileSync(t.env.WA_MONITOR_LOCK, JSON.stringify({ pid: process.pid /* live: lockFresh now requires a living owner */, mode: 'session', heartbeat: new Date().toISOString() }));
  const calls = path.join(t.dir, 'calls.txt');
  const env = { ...daemonEnv(t, calls), WA_GATEWAY_LOG_DIR: path.dirname(a.gwLog), WA_ACK_SEND_SCRIPT: a.env.WA_ACK_SEND_SCRIPT, WA_ACK_DELAY_MS: '300' };
  const child = spawn(process.execPath, [path.join(__dirname, 'wa-monitor.js'), '--daemon'], { env });
  try {
    await wait(400);
    fs.appendFileSync(t.logPath, line(GROUP, 'הודעה שהסשן מטפל בה'));
    await wait(1200);
    assert.strictEqual(fs.existsSync(a.ackRecord), false, 'deferring daemon must not ack');
  } finally { child.kill(); }
});

// ---------- daemon mode ----------
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
    WA_DAEMON_CLAUDE_CMD: process.execPath,
    WA_DAEMON_CLAUDE_ARGS: JSON.stringify([fake]),
    WA_DAEMON_STATE: path.join(t.dir, 'daemon-state.json'),
    WA_DAEMON_LOG: path.join(t.dir, 'daemon.log'),
  };
}

test('daemon: fresh session lock defers (no spawn)', async () => {
  const t = mkTmpEnv();
  fs.writeFileSync(t.env.WA_MONITOR_LOCK, JSON.stringify({ pid: process.pid /* live: lockFresh now requires a living owner */, mode: 'session', heartbeat: new Date().toISOString() }));
  const calls = path.join(t.dir, 'calls.txt');
  const env = daemonEnv(t, calls);
  const child = spawn(process.execPath, [path.join(__dirname, 'wa-monitor.js'), '--daemon'], { env });
  try {
    await wait(400);
    fs.appendFileSync(t.logPath, line(GROUP, 'הודעה בזמן שסשן פתוח'));
    await wait(800);
    assert.strictEqual(fs.existsSync(calls), false);
    const dlog = fs.readFileSync(env.WA_DAEMON_LOG, 'utf8');
    assert.ok(dlog.includes('defer-to-session'));
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

test('latestLogName: picks lexically-greatest matching file, ignores foreign names', () => {
  const names = ['admin-20260720.log', 'admin-20260722.log', 'admin-20260721.log', 'gateway-20260723.log', 'notes.txt'];
  assert.strictEqual(lib.latestLogName(names, 'admin-'), 'admin-20260722.log');
  assert.strictEqual(lib.latestLogName(names, 'gateway-'), 'gateway-20260723.log');
  assert.strictEqual(lib.latestLogName([], 'admin-'), null);
  assert.strictEqual(lib.latestLogName(['x.log'], 'admin-'), null);
});

// Regression for the 2026-07-22 00:5x incident: after HOST-local midnight the gateway
// is still writing YESTERDAY's file (it rotates ~03:30 IL). The watcher must tail the
// latest EXISTING file, not a host-date-derived name that does not exist yet.
test('runner: midnight window - still tails yesterday-named file after local midnight', async () => {
  const t = mkTmpEnv();
  const y = new Date(Date.now() - 24 * 60 * 60 * 1000);
  const ystamp = String(y.getFullYear()) + String(y.getMonth() + 1).padStart(2, '0') + String(y.getDate()).padStart(2, '0');
  const ypath = path.join(t.dir, 'admin-logs', 'admin-' + ystamp + '.log');
  fs.unlinkSync(t.logPath); // remove the today-named file: only yesterday's exists
  fs.writeFileSync(ypath, '');
  const { child, events } = startMonitor(t.env);
  try {
    await wait(400);
    fs.appendFileSync(ypath, line(GROUP, 'הודעה אחרי חצות'));
    await wait(800);
    assert.strictEqual(events.length, 1);
    assert.strictEqual(events[0].text, 'הודעה אחרי חצות');
  } finally { child.kill(); }
});

// Owner rule 2026-07-22 (double-check): a message flushed to the OLD daily file inside
// the rotation window must still be emitted - the watcher drains the old tail first.
test('runner: rotation drain - late write to old file is not lost when new file appears', async () => {
  const t = mkTmpEnv();
  const { child, events } = startMonitor(t.env);
  try {
    await wait(400);
    fs.appendFileSync(t.logPath, line(GROUP, 'הודעה ראשונה'));
    await wait(600);
    const tm = new Date(Date.now() + 24 * 60 * 60 * 1000);
    const stamp = String(tm.getFullYear()) + String(tm.getMonth() + 1).padStart(2, '0') + String(tm.getDate()).padStart(2, '0');
    fs.appendFileSync(t.logPath, line(GROUP, 'זנב ישן'));
    fs.writeFileSync(path.join(t.dir, 'admin-logs', 'admin-' + stamp + '.log'), line(GROUP, 'קובץ חדש'));
    await wait(800);
    assert.deepStrictEqual(events.map((e) => e.text), ['הודעה ראשונה', 'זנב ישן', 'קובץ חדש']);
  } finally { child.kill(); }
});

test('runner: restart across rotation drains saved old file from offset, new file from 0', async () => {
  const t = mkTmpEnv();
  const msg1 = line(GROUP, 'כבר עובד');
  fs.writeFileSync(t.logPath, msg1 + line(GROUP, 'פוספס בריסטארט'));
  const tm = new Date(Date.now() + 24 * 60 * 60 * 1000);
  const stamp = String(tm.getFullYear()) + String(tm.getMonth() + 1).padStart(2, '0') + String(tm.getDate()).padStart(2, '0');
  fs.writeFileSync(path.join(t.dir, 'admin-logs', 'admin-' + stamp + '.log'), line(GROUP, 'אחרי רוטציה'));
  fs.writeFileSync(t.env.WA_MONITOR_STATE, JSON.stringify({
    d: path.basename(t.logPath), offset: Buffer.byteLength(msg1), savedAt: new Date().toISOString(),
  }));
  const { child, events } = startMonitor(t.env);
  try {
    await wait(900);
    assert.deepStrictEqual(events.map((e) => e.text), ['פוספס בריסטארט', 'אחרי רוטציה']);
  } finally { child.kill(); }
});

// ---------- ack-by-reaction (owner request 2026-07-22) ----------
const lineWithId = (chat, text, msgId, senderJid) =>
  `[message-hook] Received: channel=whatsapp chatId=${chat} senderId=+972500000000 msgId=${msgId} senderJid=${senderJid} text=${text}\n`;

test('parseChunk: msgId + senderJid parsed into the event; "-" means absent; old format intact', () => {
  const withId = parseAs(lineWithId(GROUP, 'עם מזהה', 'ABCDEF123', '972500000000@s.whatsapp.net'), SOURCES);
  assert.strictEqual(withId.events.length, 1);
  assert.strictEqual(withId.events[0].msgId, 'ABCDEF123');
  assert.strictEqual(withId.events[0].senderJid, '972500000000@s.whatsapp.net');
  assert.strictEqual(withId.events[0].text, 'עם מזהה');
  const dashes = parseAs(lineWithId(GROUP, 'בלי מזהה', '-', '-'), SOURCES);
  assert.strictEqual(dashes.events.length, 1);
  assert.strictEqual('msgId' in dashes.events[0], false);
  const old = parseAs(line(GROUP, 'פורמט ישן'), SOURCES);
  assert.strictEqual(old.events.length, 1);
  assert.strictEqual('msgId' in old.events[0], false);
});

test('ack: msgId event sends an emoji REACTION via the gateway, no text ack', async () => {
  const http = require('node:http');
  const t = mkTmpEnv();
  const a = ackEnv(t);
  const calls = [];
  const srv = http.createServer((req, res) => {
    let b = '';
    req.on('data', (c) => b += c);
    req.on('end', () => { calls.push({ url: req.url, body: JSON.parse(b), auth: req.headers.authorization }); res.end('{"ok":true}'); });
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const env = { ...a.env, WA_GATEWAY_PORT: String(srv.address().port), WA_GATEWAY_TOKEN: 'tok-test' };
  const { child } = startMonitor(env);
  try {
    await wait(400);
    fs.appendFileSync(t.logPath, lineWithId(GROUP, 'תגיב בריאקציה', 'MSG42', '972500000000@s.whatsapp.net'));
    await wait(1200);
    assert.strictEqual(calls.length, 1);
    assert.strictEqual(calls[0].url, '/tools/invoke');
    assert.strictEqual(calls[0].auth, 'Bearer tok-test');
    assert.deepStrictEqual(calls[0].body, {
      tool: 'message', action: 'react',
      args: { target: GROUP, messageId: 'MSG42', emoji: '👍', fromMe: false, participant: '972500000000@s.whatsapp.net' },
    });
    assert.strictEqual(fs.existsSync(a.ackRecord), false, 'no text ack when reaction succeeded');
  } finally { child.kill(); srv.close(); }
});

test('ack: reaction failure falls back to the delayed text ack', async () => {
  const t = mkTmpEnv();
  const a = ackEnv(t);
  // port with nothing listening -> connection refused -> fallback
  const env = { ...a.env, WA_GATEWAY_PORT: '59999', WA_GATEWAY_TOKEN: 'tok-test' };
  const { child } = startMonitor(env);
  try {
    await wait(400);
    fs.appendFileSync(t.logPath, lineWithId(GROUP, 'ריאקציה תיכשל', 'MSG43', '-'));
    await wait(1500);
    assert.ok(fs.existsSync(a.ackRecord), 'text ack sent after reaction failure');
  } finally { child.kill(); }
});

// ---------- WhatsApp Reply (quote) context (owner request 2026-07-22) ----------
const lineFull = (chat, text, msgId, senderJid, quotedId, quoted) =>
  `[message-hook] Received: channel=whatsapp chatId=${chat} senderId=+972500000000 msgId=${msgId} senderJid=${senderJid} quotedId=${quotedId} quoted=${quoted} text=${text}\n`;

test('parseChunk: quotedId + urlencoded quoted body decoded into the event', () => {
  const q = encodeURIComponent('ההודעה המקורית על S1');
  const r = parseAs(lineFull(GROUP, 'תגובה בהמשך', 'M1', '972500000000@s.whatsapp.net', 'Q77', q), SOURCES);
  assert.strictEqual(r.events.length, 1);
  assert.strictEqual(r.events[0].quotedId, 'Q77');
  assert.strictEqual(r.events[0].quotedText, 'ההודעה המקורית על S1');
  assert.strictEqual(r.events[0].msgId, 'M1');
  const noQuote = parseAs(lineFull(GROUP, 'בלי ציטוט', 'M2', '-', '-', '-'), SOURCES);
  assert.strictEqual('quotedId' in noQuote.events[0], false);
  assert.strictEqual('quotedText' in noQuote.events[0], false);
});

// ---------- inbound image resolution (owner request 2026-07-23) ----------
test('newestMatching: picks the newest file of the kind within the window', () => {
  const files = [
    { name: 'old.jpg', mtimeMs: 1000 },
    { name: 'new.jpg', mtimeMs: 5000 },
    { name: 'newer.png', mtimeMs: 9000 },
    { name: 'voice.ogg', mtimeMs: 9999 },
  ];
  assert.strictEqual(lib.newestMatching(files, lib.MEDIA_EXT.image, 0), 'newer.png');
  assert.strictEqual(lib.newestMatching(files, lib.MEDIA_EXT.audio, 0), 'voice.ogg');
});

test('newestMatching: excludes files older than sinceMs', () => {
  const files = [{ name: 'stale.jpg', mtimeMs: 1000 }, { name: 'fresh.jpg', mtimeMs: 8000 }];
  assert.strictEqual(lib.newestMatching(files, lib.MEDIA_EXT.image, 5000), 'fresh.jpg');
  assert.strictEqual(lib.newestMatching(files, lib.MEDIA_EXT.image, 9000), null);
});

test('newestMatching: no match returns null', () => {
  assert.strictEqual(lib.newestMatching([{ name: 'doc.pdf', mtimeMs: 9 }], lib.MEDIA_EXT.image, 0), null);
  assert.strictEqual(lib.newestMatching([], lib.MEDIA_EXT.image, 0), null);
});

test('MEDIA_EXT.image matches common formats, not audio/docs', () => {
  for (const ok of ['a.jpg', 'a.jpeg', 'a.png', 'a.webp', 'a.gif', 'A.PNG']) assert.ok(lib.MEDIA_EXT.image.test(ok), ok);
  for (const no of ['a.ogg', 'a.mp3', 'a.xlsx', 'a.md', 'a.pdf']) assert.ok(!lib.MEDIA_EXT.image.test(no), no);
});

// ── latestSessionId: the daemon resumes the CHRONOLOGICALLY NEWEST session ──────────────────
// Owner-diagnosed incident 2026-07-26: the daemon persisted ONE sessionId and --resumed it
// forever, so it lived in a private context silo and answered "what is still open" from days-old
// state, listing four items that had already been finished.
test('latestSessionId: picks the newest transcript, not the first or the stored one', () => {
  const files = [
    { name: 'old.jsonl', mtimeMs: 100 },
    { name: 'newest.jsonl', mtimeMs: 300 },
    { name: 'middle.jsonl', mtimeMs: 200 },
  ];
  assert.strictEqual(lib.latestSessionId(files, 400, 1000), 'newest');
});

test('latestSessionId: strips only the .jsonl suffix (uuids keep their dashes)', () => {
  const id = '00000000-0000-4000-8000-000000000001';
  assert.strictEqual(lib.latestSessionId([{ name: `${id}.jsonl`, mtimeMs: 1 }], 2, 1000), id);
});

test('latestSessionId: ignores non-transcript files', () => {
  assert.strictEqual(lib.latestSessionId([{ name: 'notes.txt', mtimeMs: 999 }], 1000, 1e9), null);
  assert.strictEqual(
    lib.latestSessionId([{ name: 'notes.txt', mtimeMs: 999 }, { name: 'a.jsonl', mtimeMs: 1 }], 1000, 1e9),
    'a',
  );
});

test('latestSessionId: refuses a transcript older than maxAge (start fresh, not ancient)', () => {
  const files = [{ name: 'ancient.jsonl', mtimeMs: 0 }];
  assert.strictEqual(lib.latestSessionId(files, 10_000, 5_000), null);
  assert.strictEqual(lib.latestSessionId(files, 10_000, 50_000), 'ancient');
  // No maxAge given -> no age filtering at all.
  assert.strictEqual(lib.latestSessionId(files, 10_000, undefined), 'ancient');
});

test('latestSessionId: empty/junk input yields null instead of throwing', () => {
  assert.strictEqual(lib.latestSessionId([], 1, 1), null);
  assert.strictEqual(lib.latestSessionId(undefined, 1, 1), null);
  assert.strictEqual(lib.latestSessionId([null, { name: 5 }, {}], 1, 1e9), null);
});

test('latestSessionId: a fresher interactive session beats the daemon own older one', () => {
  // The exact shape of the incident: the daemon's own transcript is older than the interactive
  // session that did the real work, so the interactive one must win.
  const files = [
    { name: 'daemon-silo.jsonl', mtimeMs: 1_000 },
    { name: 'interactive-latest.jsonl', mtimeMs: 9_000 },
  ];
  assert.strictEqual(lib.latestSessionId(files, 9_500, 1e9), 'interactive-latest');
});

// --- operator allowlist (owner ruling 2026-07-27) -----------------------------
// "You are not supposed to work by groups, only by operators." Until this landed, the
// bridge authorized on group jid alone, so anyone added to the chat could drive the
// agent. Membership is a social act; production access is not.
const OPS = lib.loadOperators({ operators: [
  { name: 'Operator One', phone: '+972500000000', lid: '100000000000001' },
  { name: 'Operator Two', phone: '+1 (555) 010-0000' },
] });
const from = (sender, senderJid) =>
  `[message-hook] Received: channel=whatsapp chatId=${GROUP} senderId=${sender} msgId=M1 senderJid=${senderJid || '-'} text=שלום\n`;

test('operator allowlist: a NON-operator in an allowlisted group is dropped', () => {
  const r = lib.parseChunk(from('+972500000999'), SOURCES, undefined, OPS);
  assert.strictEqual(r.events.length, 0, 'group membership must not authorize');
});

test('operator allowlist: an operator in the same group is delivered', () => {
  const r = lib.parseChunk(from('+972500000000'), SOURCES, undefined, OPS);
  assert.strictEqual(r.events.length, 1);
});

test('operator allowlist: the lid form authorizes when the phone is absent', () => {
  const r = lib.parseChunk(from('-', '100000000000001@lid'), SOURCES, undefined, OPS);
  assert.strictEqual(r.events.length, 1);
});

test('operator allowlist: config formatting does not matter, digits do', () => {
  // Operator Two was supplied as '+15550100000'; punctuation and spacing must not decide access.
  assert.strictEqual(lib.isOperator('+15550100000', undefined, OPS), true);
  assert.strictEqual(lib.isOperator('15550100000@s.whatsapp.net', undefined, OPS), true);
});

test('operator allowlist: an EMPTY allowlist authorizes nobody (deny-by-default)', () => {
  assert.strictEqual(lib.parseChunk(from('+972500000000'), SOURCES, undefined, new Set()).events.length, 0);
  assert.strictEqual(lib.parseChunk(from('+972500000000'), SOURCES, undefined, undefined).events.length, 0);
});

test('operator allowlist: a partial number is not a match', () => {
  assert.strictEqual(lib.isOperator('+97250000', undefined, OPS), false);
  assert.strictEqual(lib.isOperator('9725000000001', undefined, OPS), false);
});
