'use strict';
/**
 * wa-inbox.test.js — the yield-to-live-session rule.
 *
 * The rule decides whether the always-on agent answers a message or leaves it to the interactive
 * session the owner is already talking to. Getting it wrong in either direction is costly: too
 * eager and two agents edit the same repo from two contexts (what happened on 2026-07-27), too
 * shy and the owner's message is acked and then answered by nobody.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const inbox = require('./wa-inbox.js');

const CWD = 'C:\\dev\\example-project';
const NOW = Date.parse('2026-07-27T01:30:00.000Z');
// `pid` must be a pid that is REALLY alive. It used to be a literal `1`: once presence learned to
// check that its holder still exists (2026-07-29), that fixture started describing a DEAD session,
// and two assertions here went red while the code was correct. Two sibling fixtures were fixed in
// that pass and these were missed - found again 2026-07-31. A fixture has to describe a state that
// can actually occur in production.
const at = (msAgo) => ({ pid: process.pid, cwd: CWD, heartbeat: new Date(NOW - msAgo).toISOString() });

test('a fresh presence for this project means a session owns the turn', () => {
  assert.strictEqual(inbox.sessionIsLive(at(5_000), CWD, NOW), true);
});

test('a stale heartbeat hands answering back to the agent', () => {
  // The failsafe that matters: a session that crashed must not mute the bridge forever.
  assert.strictEqual(inbox.sessionIsLive(at(inbox.PRESENCE_FRESH_MS + 1), CWD, NOW), false);
  assert.strictEqual(inbox.sessionIsLive(at(10 * 60_000), CWD, NOW), false);
});

test('no presence file at all means the agent answers', () => {
  assert.strictEqual(inbox.sessionIsLive(null, CWD, NOW), false);
  assert.strictEqual(inbox.sessionIsLive({}, CWD, NOW), false);
  assert.strictEqual(inbox.sessionIsLive({ heartbeat: 'not-a-date', cwd: CWD }, CWD, NOW), false);
});

test('a session open on a DIFFERENT project does not silence this one', () => {
  const other = { pid: 1, cwd: 'C:\\dev\\some-other-repo', heartbeat: new Date(NOW).toISOString() };
  assert.strictEqual(inbox.sessionIsLive(other, CWD, NOW), false);
});

test('cwd comparison tolerates trailing separators and case (Windows paths)', () => {
  // Same invented-pid defect as `at()` above: a live pid, or this asserts on a dead session.
  const p = { pid: process.pid, cwd: 'c:\\dev\\Example-Project\\', heartbeat: new Date(NOW).toISOString() };
  assert.strictEqual(inbox.sessionIsLive(p, CWD, NOW), true);
});

test('presence round-trips through disk and clears on demand', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-inbox-'));
  const file = path.join(dir, '.claude', 'presence.json');
  assert.strictEqual(inbox.writePresence(file, CWD), true);
  const back = inbox.readPresence(file);
  assert.strictEqual(back.cwd, CWD);
  assert.strictEqual(back.pid, process.pid);
  assert.strictEqual(inbox.sessionIsLive(back, CWD, Date.now()), true);
  inbox.clearPresence(file);
  assert.strictEqual(inbox.readPresence(file), null);
  inbox.clearPresence(file); // clearing twice must not throw
});

test('events append as one JSON line each, creating the directory if needed', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-inbox-'));
  const file = path.join(dir, 'nested', 'inbox.jsonl');
  inbox.appendEvent(file, { text: 'שלום', chatId: 'x@g.us' });
  inbox.appendEvent(file, { text: 'עוד אחת', chatId: 'x@g.us' });
  const lines = fs.readFileSync(file, 'utf8').trim().split('\n');
  assert.strictEqual(lines.length, 2);
  assert.strictEqual(JSON.parse(lines[0]).text, 'שלום');
  assert.strictEqual(JSON.parse(lines[1]).text, 'עוד אחת');
});

test('inbox I/O failure is swallowed - the bridge must not die on it', () => {
  // A directory where the file should be: appendFileSync throws EISDIR.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-inbox-'));
  const asDir = path.join(dir, 'inbox.jsonl');
  fs.mkdirSync(asDir);
  assert.strictEqual(inbox.appendEvent(asDir, { text: 'x' }), false);
});
