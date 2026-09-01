'use strict';
/**
 * Proof for the session-liveness watchdog and for WHERE the close hook is registered.
 * Run: node ~/.claude/skills/wa-cc-bridge/session-owner.test.js
 *
 * The registration assertions are not decoration. The 2026-07-29 outage was not a bug in
 * any of this code - it was `wa-session-inbox-stop.sh` listed under `Stop`, which fires at
 * the end of EVERY assistant turn. The bridge died seconds into the session, the owner's
 * messages went to the always-on agent, and every piece of code here worked perfectly.
 * A behaviour that depends on a config entry is only as proven as that entry.
 */
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, execFileSync } = require('child_process');

const own = require('./session-owner.js');

const HOME = process.env.USERPROFILE || process.env.HOME || '.';
// Overridable so the mutation harness can point the registration assertions at a mutated
// COPY of settings.json instead of editing the real one out from under a live session.
const SETTINGS = process.env.WA_SETTINGS_PATH || path.join(HOME, '.claude', 'settings.json');
const MONITOR = path.join(__dirname, 'wa-session-inbox.js');

let pass = 0;
let fail = 0;
function it(name, fn) {
  try {
    fn();
    pass++;
    console.log(`  PASS  ${name}`);
  } catch (e) {
    fail++;
    console.log(`  FAIL  ${name}\n        ${e && e.message}`);
  }
}
async function itAsync(name, fn) {
  try {
    await fn();
    pass++;
    console.log(`  PASS  ${name}`);
  } catch (e) {
    fail++;
    console.log(`  FAIL  ${name}\n        ${e && e.message}`);
  }
}

// The chain below is a REAL capture from a Monitor-armed process on this machine
// (2026-07-29): node <- bash <- bash <- bash <- claude.exe <- Code.exe.
const REAL_CHAIN = [
  '39120\tnode.exe\t19692\t2026-07-29T12:30:01.0Z\t"C:\\Program Files\\nodejs\\node.exe" C:/Users/<user>/.claude/skills/wa-cc-bridge/wa-session-inbox.js',
  '19692\tbash.exe\t26712\t2026-07-29T12:30:00.0Z\t"C:\\Program Files\\Git\\usr\\bin\\bash.exe" -c -l cd /c/dev && node "C:\\Users\\<user>/.claude/skills/wa-cc-bridge/wa-session-inbox.js"',
  '26712\tbash.exe\t38776\t2026-07-29T12:29:59.0Z\t"C:\\Program Files\\Git\\usr\\bin\\bash.exe" -c -l ...',
  '38776\tbash.exe\t43272\t2026-07-29T12:29:58.0Z\t"C:\\Program Files\\Git\\bin\\bash.exe" -c -l ...',
  '43272\tclaude.exe\t23880\t2026-07-29T09:12:44.0Z\tc:\\Users\\<user>\\.vscode\\extensions\\anthropic.claude-code-2.1.220-win32-x64\\resources\\native-binary\\claude.exe --ide',
  '23880\tCode.exe\t25232\t2026-07-29T09:00:00.0Z\t"C:\\Users\\<user>\\AppData\\Local\\Programs\\Microsoft VS Code\\Code.exe" --type=utility',
].join('\n');

console.log('== parseChain ==');
it('parses pid/name/ppid/createdAt/commandLine and skips blank lines', () => {
  const e = own.parseChain(`${REAL_CHAIN}\n\n`);
  assert.strictEqual(e.length, 6);
  assert.strictEqual(e[0].pid, 39120);
  assert.strictEqual(e[0].name, 'node.exe');
  assert.strictEqual(e[0].ppid, 19692);
  assert.strictEqual(e[4].name, 'claude.exe');
  assert.ok(e[4].commandLine.includes('native-binary'));
});

it('drops rows whose pid is not a number (a PowerShell error line is not a process)', () => {
  assert.strictEqual(own.parseChain('Get-CimInstance : Access is denied.\n').length, 0);
});

console.log('== pickOwner ==');
it('picks the claude.exe session, not the monitor and not its bash wrappers', () => {
  const owner = own.pickOwner(own.parseChain(REAL_CHAIN));
  assert.ok(owner, 'no owner picked');
  assert.strictEqual(owner.pid, 43272);
  assert.strictEqual(owner.name, 'claude.exe');
});

it('MUTATION GUARD: a wrapper whose command line contains ".claude" is NOT the owner', () => {
  // Every process in the chain carries `.claude` in its path. A substring match on the
  // command line would select the monitor's own bash wrapper - which dies first, so the
  // watchdog would kill a live session's bridge on the next tick.
  const entries = own.parseChain(REAL_CHAIN);
  const owner = own.pickOwner(entries);
  assert.notStrictEqual(owner.pid, 19692);
  assert.ok(entries[1].commandLine.includes('.claude'), 'fixture no longer exercises the trap');
});

it('never picks itself even if the monitor process were named claude.exe', () => {
  const self = '111\tclaude.exe\t222\t2026-07-29T00:00:00.0Z\tself';
  const parent = '222\tclaude.exe\t333\t2026-07-29T00:00:00.0Z\tparent';
  const owner = own.pickOwner(own.parseChain(`${self}\n${parent}`));
  assert.strictEqual(owner.pid, 222);
});

it('matches a CLI install running under node (cli.js), not any node process', () => {
  const chain = [
    '1\tnode.exe\t2\tt\tmonitor',
    '2\tnode.exe\t3\tt\tnode C:\\Users\\U\\AppData\\npm\\node_modules\\claude-code\\cli.js',
  ].join('\n');
  assert.strictEqual(own.pickOwner(own.parseChain(chain)).pid, 2);
  const noise = ['1\tnode.exe\t2\tt\tmonitor', '2\tnode.exe\t3\tt\tnode server.js'].join('\n');
  assert.strictEqual(own.pickOwner(own.parseChain(noise)), null);
});

console.log('== resolveOwner ==');
it('honours WA_SESSION_OWNER_PID without touching PowerShell', () => {
  const o = own.resolveOwner({
    env: { WA_SESSION_OWNER_PID: '4242' },
    exec: () => { throw new Error('must not be called'); },
  });
  assert.strictEqual(o.pid, 4242);
  assert.strictEqual(o.source, 'env');
});

it('FAILS OPEN: an unavailable PowerShell yields no owner (and therefore no watchdog)', () => {
  const o = own.resolveOwner({ env: {}, exec: () => { throw new Error('not found'); } });
  assert.strictEqual(o, null);
});

console.log('== isAlive ==');
it('no owner -> always alive (never stop on an account we do not have)', () => {
  assert.strictEqual(own.isAlive(null), true);
});

it('a live pid is alive, a dead pid is not', () => {
  assert.strictEqual(own.isAlive({ pid: process.pid, createdAt: '' }, { state: {} }), true);
  // 0x7ffffffe: valid Number, cannot be a live Windows pid.
  assert.strictEqual(own.isAlive({ pid: 2147483646, createdAt: '' }, { state: {} }), false);
});

it('pid reuse is caught: same pid, different creation time -> dead', () => {
  const owner = { pid: process.pid, createdAt: '2020-01-01T00:00:00.0Z' };
  const alive = own.isAlive(owner, {
    state: {},
    exec: () => `${process.pid}\tnode.exe\t1\t2026-07-29T00:00:00.0Z\tsomething else`,
  });
  assert.strictEqual(alive, false);
});

it('same pid, same creation time -> alive', () => {
  const owner = { pid: process.pid, createdAt: '2026-07-29T00:00:00.0Z' };
  const alive = own.isAlive(owner, {
    state: {},
    exec: () => `${process.pid}\tnode.exe\t1\t2026-07-29T00:00:00.0Z\tthe same process`,
  });
  assert.strictEqual(alive, true);
});

it('FAILS OPEN: an identity check that cannot run reports alive', () => {
  const owner = { pid: process.pid, createdAt: '2026-07-29T00:00:00.0Z' };
  const alive = own.isAlive(owner, { state: {}, exec: () => { throw new Error('no ps'); } });
  assert.strictEqual(alive, true);
});

it('the identity re-check is throttled, not run every tick', () => {
  const owner = { pid: process.pid, createdAt: 'X' };
  const state = {};
  let calls = 0;
  const exec = () => { calls++; return `${process.pid}\tnode.exe\t1\tX\tp`; };
  const opts = { state, exec, verifyMs: 60_000, now: () => 1_000 };
  own.isAlive(owner, opts);
  own.isAlive(owner, opts);
  own.isAlive(owner, { ...opts, now: () => 5_000 });
  assert.strictEqual(calls, 1, `identity queried ${calls} times inside one window`);
  own.isAlive(owner, { ...opts, now: () => 70_000 });
  assert.strictEqual(calls, 2, 'identity never re-checked after the window elapsed');
});

console.log('== hook registration (settings.json) ==');
it('wa-session-inbox-stop.sh is NOT on Stop - Stop fires every turn, not at session end', () => {
  const j = JSON.parse(fs.readFileSync(SETTINGS, 'utf8'));
  const stop = (j.hooks.Stop || []).flatMap((g) => g.hooks || []).map((h) => h.command || '');
  assert.ok(
    !stop.some((c) => c.includes('wa-session-inbox-stop')),
    'the close hook is back on Stop: the bridge will die at the end of the first turn',
  );
});

it('wa-session-inbox-stop.sh IS on SessionEnd - the deterministic release must still exist', () => {
  const j = JSON.parse(fs.readFileSync(SETTINGS, 'utf8'));
  const end = (j.hooks.SessionEnd || []).flatMap((g) => g.hooks || []).map((h) => h.command || '');
  assert.ok(
    end.some((c) => c.includes('wa-session-inbox-stop')),
    'nothing releases presence on a normal close',
  );
});

// ---------------------------------------------------------------------------
// Live behaviour: a real monitor, a real owner process, a real kill.
// ---------------------------------------------------------------------------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(predicate, { timeoutMs = 25_000, stepMs = 250 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await sleep(stepMs);
  }
  return false;
}

(async () => {
  console.log('== live watchdog ==');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-watchdog-'));
  const presence = path.join(tmp, 'presence.json');
  const inboxPath = path.join(tmp, 'inbox.jsonl');
  fs.writeFileSync(inboxPath, '');
  const sleeperPath = path.join(tmp, 'sleeper.js');
  fs.writeFileSync(sleeperPath, 'setInterval(() => {}, 1000);\n');

  const owner = spawn(process.execPath, [sleeperPath], { stdio: 'ignore', detached: false });
  const monitor = spawn(process.execPath, [MONITOR], {
    stdio: ['ignore', 'pipe', 'pipe'],
    env: {
      ...process.env,
      WA_PRESENCE_PATH: presence,
      WA_INBOX_PATH: inboxPath,
      WA_SESSION_OWNER_PID: String(owner.pid),
      WA_SESSION_OWNER_WATCH_MS: '500',
      WA_PRESENCE_BEAT_MS: '300',
    },
  });
  let exited = false;
  monitor.on('exit', () => { exited = true; });
  monitor.stdout.resume();
  monitor.stderr.resume();

  await itAsync('the monitor announces presence while its session lives', async () => {
    assert.ok(await waitFor(() => fs.existsSync(presence), { timeoutMs: 10_000 }), 'no presence file');
    await sleep(1500);
    assert.strictEqual(exited, false, 'the monitor exited while its session was alive');
    assert.ok(fs.existsSync(presence), 'presence was released while the session was alive');
  });

  await itAsync('killing the session (no hook runs) stops the monitor and clears presence', async () => {
    try { process.kill(owner.pid); } catch { /* already gone */ }
    assert.ok(await waitFor(() => exited, { timeoutMs: 20_000 }), 'the monitor OUTLIVED its session');
    assert.ok(
      await waitFor(() => !fs.existsSync(presence), { timeoutMs: 5_000 }),
      'a dead session is still claiming the owner messages',
    );
  });

  try { monitor.kill(); } catch { /* ignore */ }
  try { process.kill(owner.pid); } catch { /* ignore */ }
  await sleep(300);
  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { /* ignore */ }

  console.log(`\npass=${pass} fail=${fail}`);
  process.exit(fail === 0 ? 0 : 1);
})();
