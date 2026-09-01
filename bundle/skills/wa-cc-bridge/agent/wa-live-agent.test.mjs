/**
 * wa-live-agent.test.mjs — regression tests for the always-on agent's INBOUND path.
 *
 * WHY THIS FILE EXISTS (live outage 2026-07-27 00:39-00:56)
 * --------------------------------------------------------
 * The always-on agent shipped with an end-to-end harness that built a FAKE gateway-log dir and
 * fed it `[message-hook] Received:` lines. It passed. In production it never received a single
 * message: those lines are written to `~/.openclaw/admin-logs/admin-<date>.log`, while the agent
 * tailed `~/.openclaw/gateway-logs/gateway-<date>.log`, which carries only outbound/skip chatter
 * (`[message-hook] Received:` count over 8 days of real gateway logs: 0). The harness had put the
 * fixture wherever the code looked, so it proved the code agreed with itself and nothing else.
 * Because the agent also holds the shared bridge lock, the working v2 monitor could not run - a
 * total inbound outage that stayed silent because "no events" and "no messages" look identical.
 *
 * So these tests assert against the REAL production line format, and pin the inbound location to
 * ONE shared constant used by both consumers so the two can never drift apart again.
 */
import { test } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const lib = require('../wa-monitor-lib.js');

const JID = '120363000000000001@g.us';
const SOURCES = [{ jid: JID, type: 'group', name: 'Example-Bridge', requireKeyword: false }];
// Per-PERSON authorization (owner ruling 2026-07-27): the tailer drops anyone not listed,
// so a fixture that names only the group would (correctly) see nothing at all.
const OPS = new Set(['972500000000']);

/** A verbatim-shape line from ~/.openclaw/admin-logs/admin-20260726.log (2026-07-26). */
const received = (text) =>
  `[message-hook] Received: channel=whatsapp chatId=${JID} senderId=+972500000000`
  + ` msgId=3EB0EXAMPLE0000000000 senderJid=100000000000001@lid quotedId=- quoted=-`
  + ` text=${text}\n`;

/** Verbatim-shape lines from ~/.openclaw/gateway-logs/gateway-20260726.log for the same message. */
const GATEWAY_CHATTER =
  `2026-07-26T21:53:03.543Z Skipping group message ${JID} (not in allowlist)\n`
  + `2026-07-26T21:53:03.552Z [message-hook] Forwarding group message to admin: chatId=${JID}\n`
  + `2026-07-26T21:53:05.103Z [whatsapp] Sending message -> 0@s.whatsapp.net\n`;

let seq = 0;
function makeHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-live-agent-'));
  fs.mkdirSync(path.join(home, 'gateway-logs'), { recursive: true });
  fs.mkdirSync(path.join(home, 'admin-logs'), { recursive: true });
  return home;
}

/** Import the agent module fresh, with env pointing at an isolated fake OPENCLAW_HOME. */
async function loadAgent(home) {
  process.env.OPENCLAW_HOME = home;
  process.env.WA_LIVE_AGENT_STATE = path.join(home, 'state.json');
  process.env.WA_AGENT_POLL_MS = '25';
  process.env.WA_MONITOR_LOCK = path.join(home, 'lock.json');
  return import(`./wa-live-agent.mjs?case=${++seq}`);
}

function waitFor(predicate, timeoutMs = 4000) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const iv = setInterval(() => {
      let ok = false;
      try { ok = predicate(); } catch { ok = false; }
      if (ok) { clearInterval(iv); resolve(); }
      else if (Date.now() - started > timeoutMs) { clearInterval(iv); reject(new Error('timeout')); }
    }, 10);
  });
}


/** The context tests only need the pure turn builder - no fake gateway, no state dir. */
async function freshAgent() {
  return loadAgent(fs.mkdtempSync(path.join(os.tmpdir(), 'wa-ctx-')));
}
// ── the outage itself ────────────────────────────────────────────────────────────────────────
test('inbound tailer picks up a real admin-log line and ignores the gateway log', async () => {
  const home = makeHome();
  // Both files exist, exactly as in production. Only ONE of them carries the message.
  fs.writeFileSync(path.join(home, 'gateway-logs', 'gateway-20260726.log'), GATEWAY_CHATTER);
  fs.writeFileSync(path.join(home, 'admin-logs', 'admin-20260726.log'), '');

  const agent = await loadAgent(home);
  const seen = [];
  const timer = agent.startTailer(SOURCES, [], (ev) => seen.push(ev), OPS);
  try {
    // Append AFTER the tailer is watching: the real arrival order, and it proves the tailer
    // follows growth rather than only reading what was already on disk at boot.
    fs.appendFileSync(path.join(home, 'admin-logs', 'admin-20260726.log'), received('אילו 4 שאלות?'));
    await waitFor(() => seen.length > 0);
  } finally { clearInterval(timer); }

  assert.strictEqual(seen.length, 1, 'exactly one turn should be queued');
  assert.strictEqual(seen[0].text, 'אילו 4 שאלות?');
  assert.strictEqual(seen[0].chatId, JID);
});

test('gateway-log chatter alone never produces an event', async () => {
  const home = makeHome();
  fs.writeFileSync(path.join(home, 'admin-logs', 'admin-20260726.log'), '');
  const agent = await loadAgent(home);
  const seen = [];
  const timer = agent.startTailer(SOURCES, [], (ev) => seen.push(ev), OPS);
  try {
    fs.appendFileSync(path.join(home, 'gateway-logs', 'gateway-20260726.log'), GATEWAY_CHATTER);
    await new Promise((r) => setTimeout(r, 200));
  } finally { clearInterval(timer); }
  assert.strictEqual(seen.length, 0);
});

// ── one source of truth for WHERE inbound lives ──────────────────────────────────────────────
test('lib owns the inbound log location', () => {
  assert.deepStrictEqual(lib.INBOUND_LOG, { subdir: 'admin-logs', prefix: 'admin-' });
  assert.strictEqual(
    lib.inboundLogName(['gateway-20260726.log', 'admin-20260725.log', 'admin-20260726.log']),
    'admin-20260726.log',
  );
  assert.strictEqual(lib.inboundLogName(['gateway-20260726.log']), null);
});

test('both consumers resolve the inbound log through lib, not their own literal', () => {
  const files = [
    ['wa-live-agent.mjs', path.join(HERE, 'wa-live-agent.mjs')],
    ['wa-monitor.js', path.join(HERE, '..', 'wa-monitor.js')],
  ];
  for (const [name, p] of files) {
    const src = fs.readFileSync(p, 'utf8');
    // Strip comments so prose about the outage cannot satisfy or trip these assertions.
    const code = src.replace(/\/\*[\s\S]*?\*\//g, '').split('\n')
      .map((l) => l.replace(/(^|[^:])\/\/.*$/, '$1')).join('\n');
    assert.ok(/INBOUND_LOG/.test(code), `${name} must resolve the inbound dir via lib.INBOUND_LOG`);
    assert.ok(!/['"`]admin-logs['"`]/.test(code), `${name} must not hardcode the inbound dir`);
    assert.ok(!/['"`]admin-['"`]/.test(code), `${name} must not hardcode the inbound prefix`);
  }
});

// ── the guard that turns a silent outage into a visible one ──────────────────────────────────
test('hasInboundFormat distinguishes the real inbound line from gateway chatter', () => {
  assert.strictEqual(lib.hasInboundFormat(received('שלום')), true);
  assert.strictEqual(lib.hasInboundFormat(GATEWAY_CHATTER), false);
  assert.strictEqual(lib.hasInboundFormat(''), false);
});

test('boot self-check reports which file it will tail and whether that file is plausible', async () => {
  const home = makeHome();
  fs.writeFileSync(path.join(home, 'admin-logs', 'admin-20260726.log'), received('היי'));
  const healthy = (await loadAgent(home)).inboundHealth();
  assert.strictEqual(path.basename(healthy.file), 'admin-20260726.log');
  assert.strictEqual(healthy.ok, true);

  const empty = makeHome();
  fs.writeFileSync(path.join(empty, 'admin-logs', 'admin-20260726.log'), GATEWAY_CHATTER);
  const broken = (await loadAgent(empty)).inboundHealth();
  assert.strictEqual(broken.ok, false, 'a log with no parseable inbound line must not read as ok');
});

// ── who answers: the agent, or the session the owner is already talking to ───────────────────
test('routeEvent answers when no interactive session is present', async () => {
  const home = makeHome();
  process.env.WA_INBOX_PATH = path.join(home, 'inbox.jsonl');
  process.env.WA_PRESENCE_PATH = path.join(home, 'presence.json');
  fs.writeFileSync(path.join(home, 'admin-logs', 'admin-20260726.log'), received('היי'));

  const agent = await loadAgent(home);
  const r = agent.routeEvent({ text: 'היי', chatId: JID }, Date.now());
  assert.strictEqual(r.answer, true);
  // Recorded either way: the inbox is the audit trail of everything that arrived.
  const lines = fs.readFileSync(process.env.WA_INBOX_PATH, 'utf8').trim().split('\n');
  assert.strictEqual(JSON.parse(lines[0]).text, 'היי');
});

test('routeEvent yields to a live session for the same project, and still records the event', async () => {
  const home = makeHome();
  const cwd = process.cwd();
  process.env.WA_INBOX_PATH = path.join(home, 'inbox.jsonl');
  process.env.WA_PRESENCE_PATH = path.join(home, 'presence.json');
  // A LIVE pid. Since PR #157 round 2 the daemon also checks that the claim holder still exists,
  // so a made-up pid would make this fixture a DEAD session and the daemon would rightly answer.
  fs.writeFileSync(process.env.WA_PRESENCE_PATH,
    JSON.stringify({ pid: process.pid, cwd, heartbeat: new Date().toISOString() }));
  fs.writeFileSync(path.join(home, 'admin-logs', 'admin-20260726.log'), received('היי'));

  const agent = await loadAgent(home);
  const r = agent.routeEvent({ text: 'תיישם את זה', chatId: JID }, Date.now());
  assert.strictEqual(r.answer, false, 'a live session must own the turn - never two agents at once');
  assert.match(fs.readFileSync(process.env.WA_INBOX_PATH, 'utf8'), /תיישם את זה/);
});

test('routeEvent ANSWERS when the claim holder is fresh but DEAD', async () => {
  // The message used to fall between the two: presence stays fresh for 60s after a session
  // crashes, the daemon yielded to it, and the dead session answered nothing (PR #157 round 2).
  const home = makeHome();
  process.env.WA_INBOX_PATH = path.join(home, 'inbox.jsonl');
  process.env.WA_PRESENCE_PATH = path.join(home, 'presence.json');
  fs.writeFileSync(process.env.WA_PRESENCE_PATH, JSON.stringify({
    pid: 2147483646,                      // valid Number, cannot be a live pid
    cwd: process.cwd(),
    heartbeat: new Date().toISOString(),  // ...and perfectly fresh
  }));
  fs.writeFileSync(path.join(home, 'admin-logs', 'admin-20260726.log'), received('היי'));

  const agent = await loadAgent(home);
  const r = agent.routeEvent({ text: 'מישהו שם?', chatId: JID }, Date.now());
  assert.strictEqual(r.answer, true, 'the daemon stayed silent for a session that cannot answer');
});

test('routeEvent takes back over once the session presence goes stale', async () => {
  const home = makeHome();
  process.env.WA_INBOX_PATH = path.join(home, 'inbox.jsonl');
  process.env.WA_PRESENCE_PATH = path.join(home, 'presence.json');
  fs.writeFileSync(process.env.WA_PRESENCE_PATH, JSON.stringify({
    pid: 1, cwd: process.cwd(), heartbeat: new Date(Date.now() - 10 * 60_000).toISOString(),
  }));
  fs.writeFileSync(path.join(home, 'admin-logs', 'admin-20260726.log'), received('היי'));

  const agent = await loadAgent(home);
  assert.strictEqual(agent.routeEvent({ text: 'היי', chatId: JID }, Date.now()).answer, true);
});

test('inboundHealth is honest when the inbound dir does not exist at all', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-live-agent-nodir-'));
  const h = (await loadAgent(home)).inboundHealth();
  assert.strictEqual(h.file, null);
  assert.strictEqual(h.ok, false);
});

// ── the SECOND input channel (Slack), added 2026-07-27 ───────────────────────────────────────
// A teammate's messages sat unread for 35 minutes because the Slack monitor only ran inside a live
// session and nobody was holding one. The daemon now appends to an inbox file; these pin that
// the agent actually reads it, since a daemon writing to a file nothing tails is the same
// outage with extra steps.
test('slack tailer picks up a daemon-written event', async () => {
  const home = makeHome();
  const slackInbox = path.join(home, 'slack-inbox.jsonl');
  process.env.SLACK_INBOX_PATH = slackInbox;
  fs.writeFileSync(slackInbox, '');

  const agent = await loadAgent(home);
  const seen = [];
  const timer = agent.startSlackTailer((ev) => seen.push(ev));
  try {
    fs.appendFileSync(slackInbox, JSON.stringify({
      source: 'Slack-Bridge', type: 'channel', chatId: 'C00000000EXAMPLE',
      sender: 'U00000000EXAMPLE', text: 'decision on the reply-account question', msgId: '1785126601.0',
    }) + '\n');
    await waitFor(() => seen.length > 0);
  } finally { clearInterval(timer); }

  assert.strictEqual(seen.length, 1);
  assert.strictEqual(seen[0].source, 'Slack-Bridge');
  assert.strictEqual(seen[0].chatId, 'C00000000EXAMPLE');
  assert.match(seen[0].text, /reply-account/);
});

test('slack tailer starts at EOF - a restart never re-answers old messages', async () => {
  const home = makeHome();
  const slackInbox = path.join(home, 'slack-inbox.jsonl');
  process.env.SLACK_INBOX_PATH = slackInbox;
  // Pre-existing history: already handled by whoever was answering before this boot.
  fs.writeFileSync(slackInbox, JSON.stringify({ source: 'Slack-Bridge', text: 'old', chatId: 'C1' }) + '\n');

  const agent = await loadAgent(home);
  const seen = [];
  const timer = agent.startSlackTailer((ev) => seen.push(ev));
  try { await new Promise((r) => setTimeout(r, 200)); } finally { clearInterval(timer); }
  assert.strictEqual(seen.length, 0, 'history must not be replayed on boot');
});

test('one malformed line does not swallow the rest of the batch', async () => {
  const home = makeHome();
  const slackInbox = path.join(home, 'slack-inbox.jsonl');
  process.env.SLACK_INBOX_PATH = slackInbox;
  fs.writeFileSync(slackInbox, '');

  const agent = await loadAgent(home);
  const seen = [];
  const timer = agent.startSlackTailer((ev) => seen.push(ev));
  try {
    fs.appendFileSync(slackInbox,
      '{ this is not json\n' + JSON.stringify({ source: 'Slack-Bridge', text: 'survived', chatId: 'C1' }) + '\n');
    await waitFor(() => seen.length > 0);
  } finally { clearInterval(timer); }
  assert.strictEqual(seen.length, 1);
  assert.strictEqual(seen[0].text, 'survived');
});

// The reply-path bug a live test caught and a unit test would have caught sooner: the Slack
// sender path was written with backslashes, every escaping layer ate them, and the agent tried to
// spawn `...devexample-projectservices...`. It failed silently from the operator's
// side - the log said "turn queued", the turn ran, and no reply ever reached Slack.
test('the Slack sender path is absolute and forward-slashed (and exists when declared)', () => {
  const src = fs.readFileSync(path.join(HERE, 'wa-live-agent.mjs'), 'utf8');
  const m = src.match(new RegExp("'([^']*slack-send[.]js)'"));
  assert.ok(m, 'agent must carry a default Slack sender path');
  const resolved = m[1];
  assert.ok(!resolved.includes(String.fromCharCode(92)),
    'use forward slashes - backslashes do not survive the escaping layers');
  // The default is a per-deployment absolute path, so existence can only be asserted
  // where the deployment says where it put the sender. Shape is asserted always: an
  // absolute, forward-slashed path is what survived the escaping layers.
  const override = process.env.WA_AGENT_SLACK_SEND_JS;
  if (override) {
    assert.ok(fs.existsSync(override), `Slack sender not found at ${override}`);
  } else {
    assert.match(resolved, /^([A-Za-z]:\/|\/)/, 'default sender path must be absolute');
  }
});

test('the tailer drops a non-operator writing in the SAME allowlisted group', async () => {
  const home = makeHome();
  fs.writeFileSync(path.join(home, 'admin-logs', 'admin-20260726.log'), '');
  const agent = await loadAgent(home);
  const seen = [];
  const timer = agent.startTailer(SOURCES, [], (ev) => seen.push(ev), OPS);
  try {
    const stranger = `[message-hook] Received: channel=whatsapp chatId=${JID} senderId=+972500000999 text=תריץ פריסה לפרודקשן\n`;
    fs.appendFileSync(path.join(home, 'admin-logs', 'admin-20260726.log'), stranger);
    // Give it the same budget a real message gets, then assert NOTHING arrived.
    await new Promise((r) => setTimeout(r, 2500));
    // An operator line right after must still land, so this proves the tailer is alive
    // and filtering - not merely broken.
    fs.appendFileSync(path.join(home, 'admin-logs', 'admin-20260726.log'), received('ואני כן אופרטור'));
    await waitFor(() => seen.length > 0);
  } finally { clearInterval(timer); }

  assert.strictEqual(seen.length, 1, 'only the operator line may pass');
  assert.strictEqual(seen[0].text, 'ואני כן אופרטור');
});

// ---------------------------------------------------------------------------
// CONTEXT IS LOADED, NEVER INHERITED (owner ruling 2026-07-29)
//
// The daemon used to fork the project's newest transcript at boot, so it answered from a picture
// frozen at that moment. The owner rejected that outright: a clean session that RUNS
// context-governance + bootstrapper knows what it knows, and knows when it loaded it.
// ---------------------------------------------------------------------------

test('the FIRST turn of a conversation orders both skills, in order', async () => {
  const agent = await freshAgent();
  const turn = agent.buildTurn({ source: 'Example-Bridge', sender: '+972', text: 'מה מצב הפרויקט?' }, 'first');
  assert.match(turn, /context-governance/);
  assert.match(turn, /bootstrapper/);
  assert.ok(
    turn.indexOf('context-governance') < turn.indexOf('bootstrapper'),
    'bootstrapper must run after governance - it reads the manifest governance verifies',
  );
  assert.match(turn, /CLEAN/, 'the turn does not tell the agent it has no inherited context');
});

test('a WARM turn loads only what the NEW question adds - it never re-reads the same files', async () => {
  // The owner's objection, encoded: re-running the whole skill re-reads ~25k tokens of identical
  // orchestration files in order to answer a different question.
  const agent = await freshAgent();
  const turn = agent.buildTurn({ source: 'Example-Bridge', sender: '+972', text: 'ומה עם הרדיט?' }, 'warm');
  assert.match(turn, /do NOT re-run `context-governance`/);
  assert.match(turn, /ALREADY loaded/, 'the turn never says the state is already in context');
  assert.match(turn, /Selective Context Loading/, 'the per-question half must still happen');
  assert.match(turn, /have not already read/i, 'nothing stops it re-reading files it already has');
});

test('a STALE turn pays for a full reload - another session may have moved the repo', async () => {
  const agent = await freshAgent();
  const turn = agent.buildTurn({ source: 'Example-Bridge', sender: '+972', text: 'מה מצב?' }, 'stale');
  assert.match(turn, /context-governance/);
  assert.match(turn, /bootstrapper/);
  assert.match(turn, /may have\s+moved/i);
});

test('the question itself is IN every turn - the loading is scoped to IT, not to the last one', async () => {
  const agent = await freshAgent();
  for (const phase of ['first', 'warm', 'stale']) {
    const turn = agent.buildTurn({ source: 'Example-Bridge', sender: '+972', text: 'מה קורה עם טיקטוק?' }, phase);
    assert.match(turn, /מה קורה עם טיקטוק\?/, `the ${phase} turn dropped the question`);
    assert.match(turn, /question/i, `the ${phase} turn never mentions scoping to the question`);
  }
});

test('SLACK gets the identical mechanism, and is named as Slack', async () => {
  const agent = await freshAgent();
  const slack = agent.buildTurn({ source: 'Slack-Bridge', sender: 'U123', text: 'status?' }, 'first');
  assert.match(slack, /^Slack message from/, 'a Slack message was announced as WhatsApp');
  assert.match(slack, /context-governance/);
  assert.match(slack, /bootstrapper/);
  assert.doesNotMatch(slack, /verbatim as a WhatsApp/, 'it promises to reply on the wrong channel');
});

test('the resume/fork machinery is GONE, not merely unused', async () => {
  // A disabled code path that still compiles is an invitation to switch it back on.
  // Assert on CODE, not on text. Both earlier versions of this test matched the comment that
  // explains why the machinery is gone - so the only way to make them pass was to delete the
  // explanation. A guard that fires on its own documentation is aimed at the wrong thing.
  const raw = fs.readFileSync(path.join(HERE, 'wa-live-agent.mjs'), 'utf8');
  const code = raw.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');
  assert.match(raw, /owner ruling 2026-07-29/, 'the reason it is gone is no longer written down');
  assert.doesNotMatch(code, /forkSession/, 'the fork option is still in the code');
  assert.doesNotMatch(code, /\bresume\b/, 'the resume option is still in the code');
  assert.doesNotMatch(code, /latestSessionId/, 'the daemon still picks a transcript to continue');
  assert.doesNotMatch(code, /RESUME_MAX_AGE_MS/, 'the resume age window is still configured');
});

test('contextPhase: first -> warm -> stale, and a quiet stretch buys a full reload', async () => {
  const agent = await freshAgent();
  const HOUR = 60 * 60 * 1000;
  assert.strictEqual(agent.contextPhase(0, 1000, 2 * HOUR), 'first', 'nothing loaded yet is not warm');
  assert.strictEqual(agent.contextPhase(1000, 1000 + 60_000, 2 * HOUR), 'warm');
  assert.strictEqual(agent.contextPhase(1000, 1000 + 2 * HOUR, 2 * HOUR), 'stale', 'a stale conversation kept answering from an old picture');
  assert.strictEqual(agent.contextPhase(1000, 1000 + 2 * HOUR - 1, 2 * HOUR), 'warm', 'the boundary is exclusive');
});

// ── the split-brain of 2026-07-30/31 ─────────────────────────────────────────────────────────
// The owner reported "duplicate session activity" and had opened neither session: the daemon
// opened one because no presence claim existed, while he typed in another that never armed.
// These pin the detector that makes that state visible instead of silent.

test('projectsDirFor encodes a cwd the way Claude Code names its transcript directory', async () => {
  const agent = await freshAgent();
  const dir = agent.projectsDirFor('C:\\dev\\example-project', 'H');
  assert.strictEqual(path.basename(dir), 'C--dev-example-project');
  assert.match(dir.replace(/\\/g, '/'), /\/\.claude\/projects\//);
});

function transcriptDir(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-proj-'));
  const now = Date.now();
  for (const [name, ageMs] of Object.entries(files)) {
    const p = path.join(dir, name);
    fs.writeFileSync(p, '{}');
    fs.utimesSync(p, new Date(now - ageMs) / 1000, new Date(now - ageMs) / 1000);
  }
  return dir;
}

test('detectUnarmedSession: a recently written FOREIGN transcript is reported', async () => {
  const agent = await freshAgent();
  const dir = transcriptDir({ 'aaaa.jsonl': 5_000, 'self.jsonl': 1_000 });
  assert.strictEqual(
    agent.detectUnarmedSession({ projectsDir: dir, selfSessionId: 'self' }), 'aaaa',
  );
});

test('detectUnarmedSession: OUR OWN transcript is never the rogue one', async () => {
  const agent = await freshAgent();
  // Our session writes on every single turn, so without the exclusion this returns a false
  // positive on literally every message - the detector would be worse than useless.
  const dir = transcriptDir({ 'self.jsonl': 200 });
  assert.strictEqual(agent.detectUnarmedSession({ projectsDir: dir, selfSessionId: 'self' }), null);
});

test('detectUnarmedSession: an idle transcript is not a live session', async () => {
  const agent = await freshAgent();
  const dir = transcriptDir({ 'old.jsonl': 60 * 60_000 });
  assert.strictEqual(agent.detectUnarmedSession({ projectsDir: dir, selfSessionId: 'self' }), null);
});

test('detectUnarmedSession: the NEWEST foreign transcript wins, and non-jsonl is ignored', async () => {
  const agent = await freshAgent();
  const dir = transcriptDir({ 'older.jsonl': 90_000, 'newer.jsonl': 2_000, 'notes.txt': 1_000 });
  assert.strictEqual(agent.detectUnarmedSession({ projectsDir: dir, selfSessionId: 'self' }), 'newer');
});

test('detectUnarmedSession: a missing directory answers "nobody", never throws', async () => {
  const agent = await freshAgent();
  assert.strictEqual(
    agent.detectUnarmedSession({ projectsDir: path.join(os.tmpdir(), 'does-not-exist-' + Date.now()) }),
    null,
  );
});

test('buildTurn carries the split-brain warning ONLY when there is one', async () => {
  const agent = await freshAgent();
  const ev = { source: 'Slack-Bridge', sender: 'U1', text: 'render it', chatId: 'c' };
  const clean = agent.buildTurn(ev, 'warm');
  assert.doesNotMatch(clean, /ANOTHER LIVE SESSION/, 'the normal turn must not carry a scary warning');
  const warned = agent.buildTurn(ev, 'warm', 'abc-123');
  assert.match(warned, /ANOTHER LIVE SESSION \(abc-123\)/);
  assert.match(warned, /before you\s+edit any file/i, 'the warning has to say what to DO about it');
  assert.match(warned, /render it/, 'the owner message itself must still be there');
});
