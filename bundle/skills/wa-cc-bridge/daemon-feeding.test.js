'use strict';
/**
 * daemon-feeding.test.js — the predicate that decides whether the always-on daemon is alive and
 * feeding wa-inbox.jsonl, or dead so the session must read the raw sources itself (F1/F2 fix).
 *
 * WHY THIS EXISTS (owner report 2026-07-31 -> 08-02): the 2026-07-27 "one reader" split made the
 * interactive session a reader of a file only the daemon writes. Killing the daemon silently
 * starved BOTH channels. `daemonIsFeeding` is the switch: true -> relay (read the daemon's inbox),
 * false -> direct (read the admin log + slack inbox ourselves). It must be pure and testable.
 */
const assert = require('node:assert');
const { test } = require('node:test');
const { daemonIsFeeding, DAEMON_LOCK_FRESH_MS } = require('./wa-inbox.js');

const NOW = 1_700_000_000_000;
const aliveKill = () => true;                 // pid 0-signal succeeds -> process exists
const deadKill = () => { const e = new Error('no such process'); e.code = 'ESRCH'; throw e; };
const epermKill = () => { const e = new Error('denied'); e.code = 'EPERM'; throw e; };
const iso = (ms) => new Date(ms).toISOString();

test('no lock at all -> not feeding (direct mode)', () => {
  assert.strictEqual(daemonIsFeeding(null, 999, NOW, aliveKill), false);
});

test('fresh lock held by a LIVE foreign pid -> feeding (relay mode)', () => {
  const lock = { pid: 28860, heartbeat: iso(NOW - 5_000) };
  assert.strictEqual(daemonIsFeeding(lock, 999, NOW, aliveKill), true);
});

test('fresh lock but the holder pid is DEAD (ESRCH) -> not feeding (direct mode)', () => {
  // The exact just-killed-daemon case: lock file still on disk, pid gone.
  const lock = { pid: 28860, heartbeat: iso(NOW - 5_000) };
  assert.strictEqual(daemonIsFeeding(lock, 999, NOW, deadKill), false);
});

test('live pid but STALE heartbeat (wedged daemon) -> not feeding (direct mode)', () => {
  const lock = { pid: 28860, heartbeat: iso(NOW - (DAEMON_LOCK_FRESH_MS + 1_000)) };
  assert.strictEqual(daemonIsFeeding(lock, 999, NOW, aliveKill), false);
});

test('the lock is OUR OWN monitor pid -> not feeding (we are not the daemon)', () => {
  const lock = { pid: 999, heartbeat: iso(NOW - 1_000) };
  assert.strictEqual(daemonIsFeeding(lock, 999, NOW, aliveKill), false);
});

test('EPERM (cannot signal, but process exists) counts as alive -> feeding', () => {
  const lock = { pid: 28860, heartbeat: iso(NOW - 1_000) };
  assert.strictEqual(daemonIsFeeding(lock, 999, NOW, epermKill), true);
});

test('malformed heartbeat -> not feeding (fail to direct, never starve)', () => {
  const lock = { pid: 28860, heartbeat: 'not-a-date' };
  assert.strictEqual(daemonIsFeeding(lock, 999, NOW, aliveKill), false);
});

test('lock without a pid -> not feeding (cannot prove a live writer)', () => {
  const lock = { heartbeat: iso(NOW - 1_000) };
  assert.strictEqual(daemonIsFeeding(lock, 999, NOW, aliveKill), false);
});
