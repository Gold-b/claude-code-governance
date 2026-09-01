'use strict';
/**
 * presence-per-project.test.js — two projects, two bridges, one answerer EACH.
 *
 * THE DEFECT THIS CLOSES (owner report 2026-08-17). Presence was ONE global file,
 * `~/.claude/wa-session-presence.json`, and newest-wins ran across the whole machine. So a session
 * open on project A silenced the session open on project B: B's monitor seized nothing, logged
 * STANDBY and froze its offsets, and B's WhatsApp group went unanswered while every process looked
 * healthy. Observed live: a session on ANOTHER project held the claim while this project's session
 * sat deaf on its own group.
 *
 * The routing underneath was ALREADY per-project - `resolveSources(cfg, cwd)` gives each session
 * only its own group, the read checkpoint is keyed by cwd, and `sessionIsLive()` compares the
 * project path before yielding. The single global claim file was the one piece that was not.
 *
 * THE INVARIANT: "exactly one answerer" is per PROJECT, not per machine. That is what the owner's
 * newest-wins ruling always meant - when he opens a session, that is where HIS messages for THAT
 * project belong; it never meant a second project must go mute.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const inbox = require('./wa-inbox.js');

const PROJECT_A = 'C:\\dev\\example-project';
const PROJECT_B = 'c:\\example-project B\\example-project B';
const NOW = Date.parse('2026-08-17T13:00:00.000Z');

const tmpHome = () => fs.mkdtempSync(path.join(os.tmpdir(), 'wa-presence-'));

test('two projects resolve to two different presence files', () => {
  const home = tmpHome();
  assert.notStrictEqual(inbox.presencePath(home, PROJECT_A), inbox.presencePath(home, PROJECT_B));
});

test('one project spelled four ways resolves to ONE file', () => {
  // The arming line uses forward slashes, the launcher uses backslashes, and Windows is
  // case-insensitive. If these disagreed, one project would hold two claims and BOTH sessions
  // would answer - the exact double-answer the claim exists to prevent.
  const home = tmpHome();
  const canonical = inbox.presencePath(home, PROJECT_A);
  for (const spelling of [
    'c:/dev/example-project',
    'C:\\dev\\example-project\\',
    'c:\\dev\\example-project//',
  ]) {
    assert.strictEqual(inbox.presencePath(home, spelling), canonical, `spelling: ${spelling}`);
  }
});

test('a presence path without a project REFUSES rather than sharing the global file', () => {
  // Fail loud. A silent fallback to the old global path is how one forgotten call site would
  // quietly restore the machine-wide claim and re-mute the second project.
  const home = tmpHome();
  for (const missing of [undefined, null, '', '   ']) {
    assert.throws(() => inbox.presencePath(home, missing), /project/i, `cwd: ${JSON.stringify(missing)}`);
  }
});

test('the presence file name stays inside .claude and carries no separators', () => {
  const home = tmpHome();
  const p = inbox.presencePath(home, PROJECT_A);
  assert.strictEqual(path.dirname(p), path.join(home, '.claude'));
  const base = path.basename(p);
  assert.match(base, /^wa-session-presence-.+\.json$/);
  assert.ok(!/[\\/:]/.test(base.replace(/^wa-session-presence-/, '').replace(/\.json$/, '')),
    `slug must not contain path separators or a drive colon: ${base}`);
});

test('a live session on one project does NOT push the other project into standby', () => {
  // The end-to-end point of the change. Both monitors seize their own project's claim and both
  // stay 'owner' - independently, and across a heartbeat.
  //
  // TWO DISTINCT LIVE PIDS OR THIS TEST IS VACUOUS. With one pid it passes against the OLD global
  // file too: `claimPresence` refreshes a claim it already holds, so the second project silently
  // reusing the first project's file still returns 'owner'. Two pids is the production shape -
  // two monitor processes - and it is what makes the assertion fail before the fix.
  const home = tmpHome();
  const projectAPid = process.pid;
  const projectBPid = process.ppid;
  assert.notStrictEqual(projectAPid, projectBPid, 'fixture needs two different live pids');

  const projectAFile = inbox.presencePath(home, PROJECT_A);
  const projectBFile = inbox.presencePath(home, PROJECT_B);

  assert.strictEqual(inbox.claimPresence(projectAFile, PROJECT_A, NOW, projectAPid, { takeover: true }), 'owner');
  assert.strictEqual(inbox.claimPresence(projectBFile, PROJECT_B, NOW + 1000, projectBPid, { takeover: true }), 'owner');

  // Heartbeats refresh each claim without either one demoting the other.
  assert.strictEqual(inbox.claimPresence(projectAFile, PROJECT_A, NOW + 2000, projectAPid), 'owner');
  assert.strictEqual(inbox.claimPresence(projectBFile, PROJECT_B, NOW + 2000, projectBPid), 'owner');
});

test('newest-wins still applies WITHIN one project', () => {
  // The rule the owner actually ruled on is untouched: a newer session on the SAME project takes
  // the bridge, and the older one goes quiet.
  const home = tmpHome();
  const file = inbox.presencePath(home, PROJECT_A);
  const older = process.pid;
  const newer = process.ppid;

  assert.strictEqual(inbox.claimPresence(file, PROJECT_A, NOW, older, { takeover: true }), 'owner');
  assert.strictEqual(inbox.claimPresence(file, PROJECT_A, NOW + 1000, newer, { takeover: true }), 'owner');
  assert.strictEqual(inbox.claimPresence(file, PROJECT_A, NOW + 2000, older), 'standby');
});

test('every project presence file is discoverable for a health check', () => {
  // `wa-bridge-claim-check.js` used to read ONE known path. With per-project files it must be able
  // to enumerate them, or the health check reports "no session armed" while two are live.
  const home = tmpHome();
  inbox.claimPresence(inbox.presencePath(home, PROJECT_A), PROJECT_A, NOW, process.pid, { takeover: true });
  inbox.claimPresence(inbox.presencePath(home, PROJECT_B), PROJECT_B, NOW, process.pid, { takeover: true });

  const found = inbox.listPresence(home);
  assert.strictEqual(found.length, 2);
  const cwds = found.map((f) => inbox.normalizeProjectPath(f.presence.cwd)).sort();
  assert.deepStrictEqual(cwds, [inbox.normalizeProjectPath(PROJECT_B), inbox.normalizeProjectPath(PROJECT_A)].sort());
  for (const f of found) assert.strictEqual(typeof f.file, 'string');
});

test('listPresence on a home with no claims returns an empty list, not a throw', () => {
  assert.deepStrictEqual(inbox.listPresence(tmpHome()), []);
});

test('closing a session releases only claims whose holder is DEAD', () => {
  // The close hook used to clear ONE known path. With per-project files it must sweep them all -
  // but it must never delete a claim that a live session on another project still holds, which
  // would hand that owner's conversation back to the daemon mid-conversation.
  const home = tmpHome();
  const live = inbox.presencePath(home, PROJECT_A);
  const dead = inbox.presencePath(home, PROJECT_B);
  inbox.writePresence(live, PROJECT_A, process.pid);
  inbox.writePresence(dead, PROJECT_B, 0x7fffffff);   // a pid that cannot exist

  const released = inbox.releaseDeadClaims(home);

  assert.deepStrictEqual(released, [dead]);
  assert.strictEqual(inbox.readPresence(dead), null, 'the dead holder\'s claim must be gone');
  assert.ok(inbox.readPresence(live), 'a live session\'s claim must survive another session closing');
});

test('releasing claims is safe on a home that has none', () => {
  assert.deepStrictEqual(inbox.releaseDeadClaims(tmpHome()), []);
});
