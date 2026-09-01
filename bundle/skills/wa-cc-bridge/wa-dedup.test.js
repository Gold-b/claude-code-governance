'use strict';
const assert = require('node:assert');
const { test } = require('node:test');
const fs = require('fs');
const os = require('os');
const path = require('path');
const dedup = require('./wa-dedup.js');

function tmp() { return path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'dedup-')), 'answered.jsonl'); }
const NOW = 1_700_000_000_000;

test('first claim delivers, second identical claim is suppressed (double-answer impossible)', () => {
  const f = tmp();
  const ev = { msgId: 'ABC', chatId: 'g@g.us', sender: '+972', text: 'hi' };
  assert.strictEqual(dedup.claim(f, ev, NOW), true);
  assert.strictEqual(dedup.claim(f, ev, NOW + 1000), false);
  assert.strictEqual(dedup.claim(f, { ...ev }, NOW + 2000), false);   // same identity, different object
});

test('the SAME message re-read (admin log) with a re-stamped ts still dedups (msgId is the key)', () => {
  const f = tmp();
  assert.strictEqual(dedup.claim(f, { msgId: 'M1', text: 'a', ts: '2026-01-01T00:00:00Z' }, NOW), true);
  // parseChunk re-stamps ts at read time - a takeover re-read has a DIFFERENT ts but SAME msgId.
  assert.strictEqual(dedup.claim(f, { msgId: 'M1', text: 'a', ts: '2026-01-01T00:05:00Z' }, NOW + 3000), false);
});

test('no msgId (old log format) dedups on chatId+sender+text hash', () => {
  const f = tmp();
  const ev = { chatId: 'g@g.us', sender: '+972500', text: 'buy the dip' };
  assert.strictEqual(dedup.claim(f, ev, NOW), true);
  assert.strictEqual(dedup.claim(f, ev, NOW + 1000), false);
  // a DIFFERENT message from the same sender is delivered.
  assert.strictEqual(dedup.claim(f, { ...ev, text: 'sell' }, NOW + 2000), true);
});

test('a claim OUTSIDE the TTL is delivered again (the guard is a window, not forever)', () => {
  const f = tmp();
  const ev = { msgId: 'X' };
  assert.strictEqual(dedup.claim(f, ev, NOW, 1000), true);
  assert.strictEqual(dedup.claim(f, ev, NOW + 1500, 1000), true);   // 1.5s later, TTL 1s -> expired
});

test('two answerers on ONE message: exactly one wins (session + daemon handoff)', () => {
  const f = tmp();
  const ev = { msgId: 'HANDOFF', text: 'urgent' };
  const daemonWon = dedup.claim(f, ev, NOW);          // daemon answers during a gap
  const sessionWon = dedup.claim(f, ev, NOW + 500);   // session then resumes + tries to re-emit
  assert.strictEqual(daemonWon, true);
  assert.strictEqual(sessionWon, false);              // session suppresses -> no double answer
});

test('unkeyable event is NEVER suppressed (fail-open, a drop is worse than a dup)', () => {
  const f = tmp();
  assert.strictEqual(dedup.claim(f, {}, NOW), true);
  assert.strictEqual(dedup.claim(f, {}, NOW + 1), true);
  assert.strictEqual(dedup.claim(f, null, NOW), true);
});

test('a dedup-file read error fails OPEN (deliver), never swallows a message', () => {
  // point at a directory path so readFileSync/append throw -> claim must still return true
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dedup-dir-'));
  assert.strictEqual(dedup.claim(dir, { msgId: 'Z' }, NOW), true);
});

test('distinct msgIds do not collide', () => {
  const f = tmp();
  assert.strictEqual(dedup.claim(f, { msgId: 'A' }, NOW), true);
  assert.strictEqual(dedup.claim(f, { msgId: 'B' }, NOW), true);
  assert.strictEqual(dedup.claim(f, { msgId: 'A' }, NOW), false);
});

test('INVARIANT: the guard TTL must cover the session checkpoint-resume window (verify v3 #3)', () => {
  // A message re-read by a resumed checkpoint must still be within the guard's memory, or it
  // double-delivers. wa-session-inbox.js clamps its resume window to below this TTL; assert the
  // default resume window (15 min) is inside the TTL so the two constants cannot silently drift.
  assert.ok(dedup.DEFAULT_TTL_MS >= 15 * 60 * 1000, `dedup TTL ${dedup.DEFAULT_TTL_MS} < 15min resume window`);
});

test('seen() checks without recording; record() commits (the session split for write-then-record)', () => {
  const f = tmp();
  const ev = { msgId: 'SPLIT' };
  assert.strictEqual(dedup.seen(f, ev, NOW), false);   // checking does not record...
  assert.strictEqual(dedup.seen(f, ev, NOW), false);   // ...so a second check is still false
  dedup.record(f, ev, NOW);
  assert.strictEqual(dedup.seen(f, ev, NOW), true);     // now it is remembered
});
