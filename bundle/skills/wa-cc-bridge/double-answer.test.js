'use strict';
/**
 * Proof for the 2026-07-29 DOUBLE-ANSWER bug and for send.js delivery verification.
 * Run: node ~/.claude/skills/wa-cc-bridge/double-answer.test.js
 *
 * THE BUG THE OWNER CAUGHT (screenshot, 17:10): one test message, two replies - one from the
 * live interactive session and one from the always-on agent. The interlock that exists to stop
 * exactly that compared the presence path to the agent's cwd with only a lowercase + trailing
 * slash normalisation, while the two writers spell the SAME directory differently:
 *
 *   the arming line in SKILL.md ->  WA_SESSION_CWD='c:/dev/example-project'
 *   the agent launcher          ->  cd /d "C:\dev\example-project"
 *
 * So every live session on this repo looked foreign to the agent and it answered alongside it.
 */
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const http = require('http');

const inbox = require('./wa-inbox.js');
const lib = require('./wa-monitor-lib.js');

let pass = 0;
let fail = 0;
function it(name, fn) {
  try { fn(); pass++; console.log(`  PASS  ${name}`); }
  catch (e) { fail++; console.log(`  FAIL  ${name}\n        ${e && e.message}`); }
}
async function itAsync(name, fn) {
  try { await fn(); pass++; console.log(`  PASS  ${name}`); }
  catch (e) { fail++; console.log(`  FAIL  ${name}\n        ${e && e.message}`); }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Wait until the presence file satisfies `pred`. Beats a fixed delay, which is a race. */
async function waitForClaim(file, pred, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    let rec = null;
    try { rec = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { rec = null; }
    if (pred(rec)) return rec;
    await sleep(50);
  }
  throw new Error(`claim condition not met within ${timeoutMs}ms`);
}
const NOW = 1_800_000_000_000;
// A LIVE pid: as of PR #157 round 2 a claim whose holder is gone is not live, so a fabricated
// pid would make every one of these fixtures read as a dead session.
const fresh = (cwd) => ({ pid: process.pid, cwd, heartbeat: new Date(NOW - 5_000).toISOString() });

console.log('== sessionIsLive: one directory, one answer, however it is spelled ==');

it('THE BUG: forward-slash presence vs backslash cwd is the SAME project', () => {
  const presence = fresh('c:/dev/example-project');
  assert.strictEqual(
    inbox.sessionIsLive(presence, 'C:\\dev\\example-project', NOW),
    true,
    'the agent still thinks a live session on this repo is somebody else - it will answer twice',
  );
});

it('and the mirror image: backslash presence vs forward-slash cwd', () => {
  const presence = fresh('C:\\dev\\example-project');
  assert.strictEqual(inbox.sessionIsLive(presence, 'c:/dev/example-project', NOW), true);
});

it('doubled and trailing separators do not change the answer', () => {
  assert.strictEqual(inbox.sessionIsLive(fresh('C:\\\\dev\\\\proj\\\\'), 'c:/dev/proj', NOW), true);
});

it('a DIFFERENT project still does not silence this one', () => {
  assert.strictEqual(inbox.sessionIsLive(fresh('c:/dev/other-repo'), 'C:\\dev\\proj', NOW), false);
  // a prefix is not a match: /dev/proj-two must not be silenced by /dev/proj
  assert.strictEqual(inbox.sessionIsLive(fresh('c:/dev/proj'), 'C:\\dev\\proj-two', NOW), false);
});

it('a stale heartbeat is not a live session, whatever the path says', () => {
  const stale = { pid: process.pid, cwd: 'c:/dev/proj', heartbeat: new Date(NOW - 61_000).toISOString() };
  assert.strictEqual(inbox.sessionIsLive(stale, 'C:\\dev\\proj', NOW), false);
});

it('missing/garbage presence is never live', () => {
  assert.strictEqual(inbox.sessionIsLive(null, 'c:/x', NOW), false);
  assert.strictEqual(inbox.sessionIsLive({ cwd: 'c:/x' }, 'c:/x', NOW), false);
  assert.strictEqual(inbox.sessionIsLive({ cwd: 'c:/x', heartbeat: 'nonsense' }, 'c:/x', NOW), false);
  assert.strictEqual(inbox.sessionIsLive(fresh('c:/x'), '', NOW), false);
});

console.log('== the group interlock: whoever owns the conversation answers it ==');

const CFG = {
  ccAgentGroup: '120363000000000000',
  projects: { 'c:\\dev\\example-project': { jid: '120363000000000001@g.us', name: 'Example-Bridge' } },
};

it('a project cwd maps to exactly one group (the mapping the interlock leans on)', () => {
  const [src] = lib.resolveSources(CFG, 'c:/dev/example-project');
  assert.strictEqual(lib.normalizeJid(src.jid), lib.normalizeJid('120363000000000001@g.us'));
});

it('an unmapped cwd falls back to the global group, and does NOT claim a project group', () => {
  const [src] = lib.resolveSources(CFG, 'c:/some/other/place');
  assert.notStrictEqual(lib.normalizeJid(src.jid), lib.normalizeJid('120363000000000001@g.us'));
});

console.log('== exactly one answerer: the presence CLAIM ==');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-claim-'));
const claimFile = path.join(tmpDir, 'presence.json');
const T = 1_800_000_000_000;

it('NEWEST WINS: a starting session takes the bridge from the current holder', () => {
  // Owner policy 2026-07-29: "the new session takes the bridge and leads it" - when he opens a
  // session, that is where he is working.
  fs.rmSync(claimFile, { force: true });
  assert.strictEqual(inbox.claimPresence(claimFile, 'c:/dev/proj', T, 111, { takeover: true }), 'owner');
  assert.strictEqual(inbox.claimPresence(claimFile, 'c:/dev/proj', T + 1000, 222, { takeover: true }), 'owner');
  assert.strictEqual(inbox.readPresence(claimFile).pid, 222);
});

it('a HEARTBEAT never seizes - otherwise two monitors trade the bridge every beat', () => {
  fs.rmSync(claimFile, { force: true });
  inbox.claimPresence(claimFile, 'c:/dev/proj', T, 222, { takeover: true });
  // 111 is still running and heartbeating; it must discover it lost and stay lost.
  assert.strictEqual(inbox.claimPresence(claimFile, 'c:/dev/proj', T + 1000, 111), 'standby');
  assert.strictEqual(inbox.claimPresence(claimFile, 'c:/dev/proj', T + 2000, 111), 'standby');
  assert.strictEqual(inbox.readPresence(claimFile).pid, 222, 'a heartbeat stole the bridge back');
  // ...and the holder keeps it on its own heartbeats
  assert.strictEqual(inbox.claimPresence(claimFile, 'c:/dev/proj', T + 3000, 222), 'owner');
});

it('a STALE claim is taken back - a session that dies must not mute the bridge forever', () => {
  // The standby's own heartbeat reclaims it, WITHOUT a takeover flag: this is the path back
  // when the newer session closes or crashes.
  fs.rmSync(claimFile, { force: true });
  inbox.claimPresence(claimFile, 'c:/dev/proj', T, 222, { takeover: true });
  assert.strictEqual(inbox.claimPresence(claimFile, 'c:/dev/proj', T + 61_000, 111), 'owner');
  assert.strictEqual(inbox.readPresence(claimFile).pid, 111);
});

it('a standby heartbeat does NOT overwrite the holder claim', () => {
  fs.rmSync(claimFile, { force: true });
  inbox.claimPresence(claimFile, 'c:/dev/proj', T, 111, { takeover: true });
  inbox.claimPresence(claimFile, 'c:/dev/other', T + 1000, 222);
  assert.strictEqual(inbox.readPresence(claimFile).pid, 111, 'a heartbeat stole the claim');
});

it('closing a STANDBY session does not release the holder claim', () => {
  // A blanket unlink handed the conversation back to the daemon while the owner session was
  // still talking - the second session's close deleted the first session's presence.
  fs.rmSync(claimFile, { force: true });
  inbox.claimPresence(claimFile, 'c:/dev/proj', T, 111, { takeover: true });
  assert.strictEqual(inbox.clearPresence(claimFile, 222), false);
  assert.ok(fs.existsSync(claimFile), 'a standby close deleted the live owner claim');
  assert.strictEqual(inbox.clearPresence(claimFile, 111), true);
  assert.ok(!fs.existsSync(claimFile));
});

console.log('== send.js: a status code is not a delivery ==');

const SEND = path.join(process.env.USERPROFILE || process.env.HOME, '.claude', 'skills', 'whatsapp', 'send.js');
const UNMAPPED_PROJECT = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-unmapped-'));
const SUCCESS_BODY = JSON.stringify({
  ok: true,
  result: {
    content: [{ type: 'text', text: JSON.stringify({ result: { messageId: '3EB0MIRROR' } }) }],
    details: { result: { runId: 'r1', messageId: '3EB0REAL', toJid: 'g@g.us' } },
  },
});

/**
 * A stand-in gateway on an EPHEMERAL port. Never 18789: the real gateway owns that port on this
 * machine, so binding it fails - and the one test that then ran without a fake server messaged
 * the owner for real. A test must not be able to reach production by accident.
 */
function withFakeGateway(script, run) {
  return new Promise((resolve, reject) => {
    let i = 0;
    const hits = [];
    const server = http.createServer((req, res) => {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        const step = script[Math.min(i, script.length - 1)];
        i++;
        hits.push({ body });
        res.writeHead(step.status, { 'Content-Type': 'application/json' });
        res.end(step.body);
      });
    });
    server.listen(0, '127.0.0.1', async () => {
      const { port } = server.address();
      try { const out = await run(port); resolve({ out, hits }); }
      catch (e) { reject(e); }
      finally { server.close(); }
    });
    server.on('error', reject);
  });
}

/**
 * ASYNC on purpose. `spawnSync` blocks THIS process's event loop, so the in-process fake gateway
 * could never answer the child it was serving: every send timed out, and one assertion
 * ("a failure exits non-zero") passed for that wrong reason - green, and proving nothing.
 *
 * `port` unset = point at a port nothing is listening on. Never at the real gateway.
 */
function runSend(text, port) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [SEND, text], {
      // A REAL directory, created here. send.js resolves its target from process.cwd(), so the
      // child needs an UNMAPPED project dir - but on Windows spawn() fails ENOENT when cwd does
      // not exist, and it blames the executable, not the cwd. A hardcoded path is a machine
      // dependency dressed as a fixture: it passes only where that directory happens to exist.
      // mkdtemp keeps the property the test needs (unmapped) and adds portability.
      cwd: UNMAPPED_PROJECT,
      env: {
        ...process.env,
        WA_SEND_ATTEMPTS: '3',
        WA_SEND_TIMEOUT_MS: '4000',
        WA_GATEWAY_HOST: '127.0.0.1',
        WA_GATEWAY_PORT: String(port ?? 1),
      },
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (c) => { stdout += c; });
    child.stderr.on('data', (c) => { stderr += c; });
    child.on('close', (status) => resolve({ status, stdout, stderr }));
  });
}

(async () => {
  await itAsync('a 200 with a messageId exits 0 and PRINTS the id, not a status code', async () => {
    const { out } = await withFakeGateway([{ status: 200, body: SUCCESS_BODY }], (port) => runSend('hello', port));
    assert.strictEqual(out.status, 0, `exit ${out.status}: ${out.stderr}`);
    assert.strictEqual(out.stdout.trim(), '3EB0REAL');
  });

  await itAsync('THE OWNER BUG: a transient 400 is retried and then succeeds', async () => {
    const { out, hits } = await withFakeGateway(
      [{ status: 400, body: '{"ok":false,"error":"transient"}' }, { status: 200, body: SUCCESS_BODY }],
      (port) => runSend('hello', port),
    );
    assert.strictEqual(out.status, 0, `a retryable failure ended the send: ${out.stderr}`);
    assert.ok(hits.length >= 2, `no retry happened (${hits.length} request)`);
  });

  await itAsync('a persistent failure EXITS NON-ZERO - the caller checks this', async () => {
    const { out } = await withFakeGateway([{ status: 400, body: '{"ok":false}' }], (port) => runSend('hello', port));
    assert.notStrictEqual(out.status, 0, 'a lost message reported success - the original defect');
    assert.match(out.stderr, /NOT DELIVERED/);
  });

  await itAsync('a 200 with NO messageId is a FAILURE, not a success', async () => {
    // The precise trap: the gateway can answer 200 while nothing was sent. Status alone lies.
    const { out } = await withFakeGateway([{ status: 200, body: '{"ok":true,"result":{}}' }], (port) => runSend('hello', port));
    assert.notStrictEqual(out.status, 0, 'a 200 without a messageId was treated as delivered');
    assert.match(out.stderr, /no messageId/, 'failed for the wrong reason (a timeout, not a missing id)');
  });

  await itAsync('an unreachable gateway exits non-zero rather than printing a number', async () => {
    const out = await runSend('hello');   // port 1: nothing is listening, and it is NOT the gateway
    assert.notStrictEqual(out.status, 0);
    assert.match(out.stderr, /NOT DELIVERED/);
  });

  console.log('== TWO live monitors, ONE answer (the case in the owner\'s screenshot) ==');

  await itAsync('the NEWER monitor leads: one raw admin-log event reaches exactly one of them', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-two-'));
    const presenceFile = path.join(dir, 'presence.json');
    // Since the one-reader fix (2026-08-02) a session reads the RAW admin log directly; there is no
    // relay/inbox path. So two live monitors both tail the admin log, and the presence interlock -
    // not the source - must ensure exactly one answers (the owner's screenshot scenario).
    const adminDir = path.join(dir, 'admin-logs');
    fs.mkdirSync(adminDir, { recursive: true });
    const adminLog = path.join(adminDir, 'admin-20260802.log');
    fs.writeFileSync(adminLog, '');
    const cfgPath = path.join(dir, 'wa-bridge.json');
    fs.writeFileSync(cfgPath, JSON.stringify({
      projects: { 'c:/dev/proj': { jid: '123@g.us', name: 'Proj' } },
      operators: [{ phone: '+972500000000' }],
    }));
    const MON = path.join(__dirname, 'wa-session-inbox.js');

    const start = () => {
      const c = spawn(process.execPath, [MON], {
        stdio: ['ignore', 'pipe', 'pipe'],
        env: {
          ...process.env,
          WA_PRESENCE_PATH: presenceFile,
          WA_SESSION_CWD: 'c:/dev/proj',
          WA_BRIDGE_CONFIG: cfgPath,
          WA_INBOUND_LOG_DIR: adminDir,
          SLACK_INBOX_PATH: path.join(dir, 'slack.jsonl'),
          WA_SESSION_DIRECT_STATE: path.join(dir, `direct-${Math.random().toString(36).slice(2)}.json`),
          // A LONG heartbeat on purpose. With a fast beat the replaced monitor notices in
          // milliseconds and the test cannot see the real window: in production the beat is 15s,
          // and the old code kept the cached `owner` role - and kept answering - for all of it.
          // 30s here means only the poll loop's own ownership recheck can keep A quiet.
          WA_PRESENCE_BEAT_MS: '30000',
          WA_INBOX_POLL_MS: '150',
          WA_SESSION_OWNER_WATCH_MS: '0',   // isolate the claim rule from the liveness watchdog
          WA_MONITOR_REGISTRY: path.join(dir, 'registry'),
        },
      });
      const out = { lines: [], err: '' };
      c.stdout.on('data', (b) => {
        for (const l of String(b).split('\n')) if (l.trim()) out.lines.push(l.trim());
      });
      c.stderr.on('data', (b) => { out.err += b; });
      return { c, out };
    };

    const a = start();
    await waitForClaim(presenceFile, (rec) => rec && rec.pid, 8000);   // A owns it
    const aPid = JSON.parse(fs.readFileSync(presenceFile, 'utf8')).pid;
    const b = start();
    // Wait for the takeover to actually land, then write immediately (keeps the event inside A's
    // 30s heartbeat window, forcing the poll loop's ownership recheck to be what keeps A quiet).
    await waitForClaim(presenceFile, (rec) => rec && rec.pid && rec.pid !== aPid, 8000);
    fs.appendFileSync(adminLog,
      '[message-hook] Received: channel=whatsapp chatId=123@g.us senderId=+972500000000 text=one message\n');
    await sleep(2000);

    a.c.kill(); b.c.kill();
    await sleep(300);

    const total = a.out.lines.length + b.out.lines.length;
    assert.strictEqual(
      total, 1,
      `${total} monitors answered one message (a=${a.out.lines.length} b=${b.out.lines.length}) - this is the owner's duplicate`,
    );
    // ...and it is the NEWER one that answers (owner policy: the new session leads).
    assert.strictEqual(b.out.lines.length, 1, 'the newer session did not take the bridge');
    assert.strictEqual(a.out.lines.length, 0, 'the older session kept answering after being replaced');
    assert.match(b.out.err, /took the bridge over from pid/, 'the takeover was not announced');
    assert.match(a.out.err, /STANDBY/, 'the replaced monitor never reported that it stood down');
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
  });

  console.log(`\npass=${pass} fail=${fail}`);
  process.exit(fail === 0 ? 0 : 1);
})();
