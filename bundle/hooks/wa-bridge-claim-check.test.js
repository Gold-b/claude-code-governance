/**
 * wa-bridge-claim-check.test.js — the UserPromptSubmit bridge-claim guard.
 *
 * These run the REAL hook as a child process with a fake HOME, because the failure this guard
 * exists for was a hook that was registered but never actually produced its output. Asserting on
 * an imported function would prove the same nothing.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const HOOK = path.join(__dirname, 'wa-bridge-claim-check.js');
const REAL_SKILL = path.join(process.env.USERPROFILE || process.env.HOME, '.claude', 'skills', 'wa-cc-bridge');
const PROJECT = 'C:\\dev\\example-project';
const JID = '120363000000000000@g.us';

/** A fake HOME with the real skill modules linked in, so the predicate under test is the real one. */
function makeHome({ presence, bridgeOff = false, config = true } = {}) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-claim-'));
  const claude = path.join(home, '.claude');
  fs.mkdirSync(path.join(claude, 'skills'), { recursive: true });
  // FILTERED COPY. This used to clone the whole skill directory per test - which now includes
  // `agent/node_modules` and any `.bak-*` left beside it, so a 3-file fixture was copying hundreds
  // of megabytes. The suite took 33s and then failed at file level with no test output at all,
  // which reads as "hung", not as "too slow". Copy only what the hook actually loads.
  fs.cpSync(REAL_SKILL, path.join(claude, 'skills', 'wa-cc-bridge'), {
    recursive: true,
    filter: (src) => {
      const b = path.basename(src);
      return b !== 'node_modules' && !b.startsWith('.bak-');
    },
  });
  if (config) {
    // The REAL config shape: a `projects` map keyed by the project path. An earlier fixture
    // invented `{sources:[...]}`, which the gate does not read - it would have passed while
    // production behaved differently.
    fs.writeFileSync(path.join(claude, '.wa-bridge.json'), JSON.stringify({
      sources: [{ jid: JID }],
      projects: { 'c:\\dev\\example-project': { jid: JID, type: 'group' } },
    }));
  }
  // PER-PROJECT claim (2026-08-17). The hook asks for THIS project's file; a fixture writing the
  // retired machine-wide name would leave the hook seeing no claim at all and the test asserting
  // against a state production can no longer produce.
  if (presence) {
    const inbox = require(path.join(claude, 'skills', 'wa-cc-bridge', 'wa-inbox.js'));
    fs.writeFileSync(inbox.presencePath(home, presence.cwd || PROJECT), JSON.stringify(presence));
  }
  if (bridgeOff) fs.writeFileSync(path.join(claude, 'wa-bridge-off'), '');
  return home;
}

function run(home, payload, env = {}) {
  return execFileSync(process.execPath, [HOOK], {
    input: JSON.stringify(payload),
    encoding: 'utf8',
    env: { ...process.env, USERPROFILE: home, HOME: home, ...env },
  });
}

const fresh = (cwd = PROJECT, pid = process.pid) => ({ pid, cwd, heartbeat: new Date().toISOString() });

test('no presence file at all -> emits the arm instruction (the 2026-07-31 outage state)', () => {
  const out = run(makeHome(), { cwd: PROJECT, hook_event_name: 'UserPromptSubmit' });
  const j = JSON.parse(out);
  assert.equal(j.hookSpecificOutput.hookEventName, 'UserPromptSubmit');
  assert.match(j.hookSpecificOutput.additionalContext, /BRIDGE IS UNCLAIMED/);
  assert.match(j.hookSpecificOutput.additionalContext, /wa-session-inbox\.js/);
});

test('a fresh claim held by a LIVE pid for this cwd -> completely silent', () => {
  const out = run(makeHome({ presence: fresh() }), { cwd: PROJECT });
  assert.equal(out.trim(), '', 'the common case must produce no output at all');
});

test('a claim whose heartbeat is stale -> nags (a reload leaves exactly this)', () => {
  const stale = { pid: process.pid, cwd: PROJECT, heartbeat: new Date(Date.now() - 10 * 60_000).toISOString() };
  const out = run(makeHome({ presence: stale }), { cwd: PROJECT });
  assert.match(out, /BRIDGE IS UNCLAIMED/);
});

test('a fresh claim held by a DEAD pid -> nags', () => {
  // 0x7FFFFFFF is not a live Windows pid; presenceHolderAlive answers ESRCH -> dead.
  const out = run(makeHome({ presence: fresh(PROJECT, 0x7ffffffe) }), { cwd: PROJECT });
  assert.match(out, /BRIDGE IS UNCLAIMED/);
});

test('a fresh claim for a DIFFERENT project -> nags for this one', () => {
  const out = run(makeHome({ presence: fresh('C:\\dev\\some-other-repo') }), { cwd: PROJECT });
  assert.match(out, /BRIDGE IS UNCLAIMED/);
});

test('path spelling must not matter (the 2026-07-29 double-answer root cause)', () => {
  const out = run(makeHome({ presence: fresh('c:/dev/example-project') }), { cwd: PROJECT });
  assert.equal(out.trim(), '', 'c:/x and C:\\x are the same project');
});

test('a project the bridge does not serve -> silent, never nag unrelated repos', () => {
  const out = run(makeHome(), { cwd: 'C:\\dev\\unrelated-project' });
  assert.equal(out.trim(), '');
});

test('kill switch wa-bridge-off -> silent even with no claim', () => {
  const out = run(makeHome({ bridgeOff: true }), { cwd: PROJECT });
  assert.equal(out.trim(), '');
});

test('throttle: a burst of prompts costs ONE notice', () => {
  const home = makeHome();
  assert.match(run(home, { cwd: PROJECT }), /BRIDGE IS UNCLAIMED/);
  assert.equal(run(home, { cwd: PROJECT }).trim(), '', 'second prompt within the window is silent');
});

test('throttle expires -> it nags again (a bridge left unclaimed must keep saying so)', () => {
  const home = makeHome();
  assert.match(run(home, { cwd: PROJECT }, { WA_CLAIM_NAG_MS: '0' }), /BRIDGE IS UNCLAIMED/);
  assert.match(run(home, { cwd: PROJECT }, { WA_CLAIM_NAG_MS: '0' }), /BRIDGE IS UNCLAIMED/);
});

test('garbage on stdin and a corrupt presence file cannot break the prompt path', () => {
  const home = makeHome();
  fs.writeFileSync(path.join(home, '.claude', 'wa-session-presence.json'), '{not json');
  const out = execFileSync(process.execPath, [HOOK], {
    input: 'this is not json at all',
    encoding: 'utf8',
    env: { ...process.env, USERPROFILE: home, HOME: home },
  });
  assert.doesNotThrow(() => (out.trim() ? JSON.parse(out) : null));
});
