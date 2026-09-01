'use strict';
/**
 * direct-read.test.js — the F1/F2 fix, end to end: with NO daemon feeding wa-inbox.jsonl, a live
 * session monitor must read the raw sources itself (the WhatsApp admin log AND the Slack inbox) and
 * emit both, exactly as the pre-split wa-monitor.js session mode did for WhatsApp. This is the
 * whole point of the fix - killing the daemon must not starve the live session.
 *
 * Spawns the real wa-session-inbox.js against temp files so the full imperative path (mode
 * selection -> admin-log tail + parse + operator filter -> slack tail) is exercised, not a stub.
 */
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const MON = path.join(__dirname, 'wa-session-inbox.js');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(pred, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (pred()) return true; await sleep(50); }
  return false;
}

(async () => {
  let pass = 0; let fail = 0;
  const it = async (name, fn) => {
    try { await fn(); pass++; console.log(`  PASS  ${name}`); }
    catch (e) { fail++; console.log(`  FAIL  ${name}\n        ${e.message}`); }
  };

  console.log('== direct mode: no daemon -> read the admin log + slack inbox directly ==');

  await it('a WhatsApp admin-log line AND a Slack inbox line both reach stdout; history is not replayed; non-operators are dropped', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-direct-'));
    const adminDir = path.join(dir, 'admin-logs');
    fs.mkdirSync(adminDir, { recursive: true });
    const adminLog = path.join(adminDir, 'admin-20260802.log');
    const slackInbox = path.join(dir, 'slack-inbox.jsonl');
    const presence = path.join(dir, 'presence.json');
    const inbox = path.join(dir, 'inbox.jsonl');           // relay source - must stay UNUSED here
    const directState = path.join(dir, 'direct-state.json');
    const cfgPath = path.join(dir, 'wa-bridge.json');

    fs.writeFileSync(cfgPath, JSON.stringify({
      projects: { 'c:/dev/testproj': { jid: '123@g.us', name: 'TestGroup' } },
      operators: [{ phone: '+972500000000' }],
    }));
    fs.writeFileSync(inbox, '');
    fs.writeFileSync(slackInbox, '');
    // Pre-existing history that must NOT be replayed (monitor starts at EOF).
    fs.writeFileSync(adminLog,
      '[message-hook] Received: channel=whatsapp chatId=123@g.us senderId=+972500000000 text=OLD history line\n');

    const child = spawn(process.execPath, [MON], {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: {
        ...process.env,
        WA_PRESENCE_PATH: presence,
        WA_INBOX_PATH: inbox,
        WA_SESSION_CWD: 'c:/dev/testproj',
        WA_BRIDGE_CONFIG: cfgPath,
        WA_INBOUND_LOG_DIR: adminDir,
        SLACK_INBOX_PATH: slackInbox,
        WA_SESSION_DIRECT_STATE: directState,
        WA_DEDUP_PATH: path.join(dir, 'answered.jsonl'),
        WA_MONITOR_LOCK: path.join(dir, 'nonexistent.lock'),   // no lock -> no daemon -> DIRECT
        WA_INBOX_POLL_MS: '120',
        WA_PRESENCE_BEAT_MS: '15000',
        WA_SESSION_OWNER_WATCH_MS: '0',
        WA_MONITOR_REGISTRY: path.join(dir, 'registry'),
      },
    });
    const lines = [];
    let err = '';
    child.stdout.on('data', (b) => { for (const l of String(b).split('\n')) if (l.trim()) lines.push(l.trim()); });
    child.stderr.on('data', (b) => { err += b; });

    try {
      // Wait until it owns presence AND has selected direct mode.
      await waitFor(() => { try { return !!JSON.parse(fs.readFileSync(presence, 'utf8')).pid; } catch { return false; } }, 8000);
      await waitFor(() => /source = direct/.test(err), 4000);

      // New WhatsApp message (operator) + a non-operator message + a self [CC] line.
      fs.appendFileSync(adminLog,
        '[message-hook] Received: channel=whatsapp chatId=123@g.us senderId=+972500000000 text=hello from whatsapp\n' +
        '[message-hook] Received: channel=whatsapp chatId=123@g.us senderId=+972599999999 text=stranger must be dropped\n' +
        '[message-hook] Received: channel=whatsapp chatId=123@g.us senderId=+972500000000 text=[CC] my own echo\n');
      // New Slack message (already-structured event line, as slack-monitor writes it).
      fs.appendFileSync(slackInbox,
        JSON.stringify({ source: 'Slack-Bridge', type: 'channel', chatId: 'C0X', sender: 'U0Y', text: 'hello from slack', ts: '2026-08-02T12:00:00.000Z' }) + '\n');

      await waitFor(() => lines.length >= 2, 5000);
      await sleep(500);   // settle: catch any wrongful extra emit

      const texts = lines.map((l) => { try { return JSON.parse(l).text; } catch { return l; } });
      assert.ok(texts.includes('hello from whatsapp'), `WhatsApp direct read missing. got: ${JSON.stringify(texts)}`);
      assert.ok(texts.includes('hello from slack'), `Slack direct read missing. got: ${JSON.stringify(texts)}`);
      assert.ok(!texts.includes('OLD history line'), 'replayed pre-start history (should start at EOF)');
      assert.ok(!texts.some((t) => /stranger/.test(t)), 'emitted a non-operator message');
      assert.ok(!texts.some((t) => /my own echo/.test(t)), 'emitted a self [CC] line');
      assert.strictEqual(lines.length, 2, `expected exactly 2 emits, got ${lines.length}: ${JSON.stringify(texts)}`);
    } finally {
      child.kill();
      await sleep(200);
      try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
    }
  });

  await it('stale-takeover in direct mode: the reclaiming monitor does NOT re-emit what the dead holder already answered, but DOES emit the unanswered window (verify #5/#9)', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-reclaim-'));
    const adminDir = path.join(dir, 'admin-logs');
    fs.mkdirSync(adminDir, { recursive: true });
    const adminLog = path.join(adminDir, 'admin-20260802.log');
    const slackInbox = path.join(dir, 'slack-inbox.jsonl');
    const presence = path.join(dir, 'presence.json');
    const cfgPath = path.join(dir, 'wa-bridge.json');
    const directState = path.join(dir, 'direct-state.json');
    fs.writeFileSync(cfgPath, JSON.stringify({
      projects: { 'c:/dev/testproj': { jid: '123@g.us', name: 'TestGroup' } },
      operators: [{ phone: '+972500000000' }],
    }));
    fs.writeFileSync(slackInbox, '');
    fs.writeFileSync(adminLog, '');
    const line = (t) => `[message-hook] Received: channel=whatsapp chatId=123@g.us senderId=+972500000000 text=${t}\n`;

    const start = () => {
      const c = spawn(process.execPath, [MON], {
        stdio: ['ignore', 'pipe', 'pipe'],
        env: {
          ...process.env,
          WA_PRESENCE_PATH: presence,
          WA_INBOX_PATH: path.join(dir, 'inbox.jsonl'),
          WA_SESSION_CWD: 'c:/dev/testproj',
          WA_BRIDGE_CONFIG: cfgPath,
          WA_INBOUND_LOG_DIR: adminDir,
          SLACK_INBOX_PATH: slackInbox,
          WA_SESSION_DIRECT_STATE: directState,   // SHARED: the reclaiming monitor resumes the checkpoint
          WA_DEDUP_PATH: path.join(dir, 'answered.jsonl'),   // SHARED guard across A and B
          WA_INBOX_POLL_MS: '120',
          WA_PRESENCE_BEAT_MS: '600',             // short so the stale claim is retaken quickly in-test
          WA_DIRECT_RESUME_MAX_AGE_MS: '600000',
          WA_SESSION_OWNER_WATCH_MS: '0',
          WA_MONITOR_REGISTRY: path.join(dir, 'registry'),
        },
      });
      const out = { lines: [], err: '' };
      c.stdout.on('data', (b) => { for (const l of String(b).split('\n')) if (l.trim()) out.lines.push(l.trim()); });
      c.stderr.on('data', (b) => { out.err += b; });
      return { c, out };
    };
    const texts = (o) => o.lines.map((l) => { try { return JSON.parse(l).text; } catch { return l; } });

    let a; let b;
    try {
      a = start();
      await waitFor(() => { try { return !!JSON.parse(fs.readFileSync(presence, 'utf8')).pid; } catch { return false; } }, 8000);
      await waitFor(() => /reading admin log/.test(a.out.err) || /source/.test(a.out.err), 4000);
      const aPid = JSON.parse(fs.readFileSync(presence, 'utf8')).pid;

      b = start();   // newer session takes the bridge (newest-wins)
      await waitFor(() => { try { return JSON.parse(fs.readFileSync(presence, 'utf8')).pid !== aPid; } catch { return false; } }, 8000);
      await sleep(400);   // let A notice it is standby

      // B (owner) answers M1; assert only B emitted it. B's saveDirectState commits past M1.
      const bPid = JSON.parse(fs.readFileSync(presence, 'utf8')).pid;
      fs.appendFileSync(adminLog, line('M1-answered-by-B'));
      await waitFor(() => texts(b.out).includes('M1-answered-by-B'), 4000);
      await sleep(300);
      assert.ok(texts(b.out).includes('M1-answered-by-B'), 'B did not emit M1');
      assert.ok(!texts(a.out).includes('M1-answered-by-B'), 'A (standby) wrongly emitted M1 - double answer');

      // B DIES HARD (no exit handler, presence left behind). claimPresence honours a fresh claim for
      // PRESENCE_FRESH_MS(60s), so to exercise the stale-reclaim path in-test we age B's presence
      // record. A must then reclaim, resume from B's committed checkpoint (past M1), NOT re-emit M1,
      // and emit M2 that arrives after.
      b.c.kill('SIGKILL');
      await sleep(200);
      fs.writeFileSync(presence, JSON.stringify({ pid: bPid, cwd: 'c:/dev/testproj', heartbeat: new Date(Date.now() - 120000).toISOString() }));
      await waitFor(() => /reclaimed the bridge/.test(a.out.err), 6000);
      fs.appendFileSync(adminLog, line('M2-after-B-died'));
      await waitFor(() => texts(a.out).includes('M2-after-B-died'), 6000);
      await sleep(400);

      assert.ok(texts(a.out).includes('M2-after-B-died'), 'A did not emit the unanswered-window message M2 (I2 drop)');
      assert.ok(!texts(a.out).includes('M1-answered-by-B'),
        `A re-emitted M1 that the dead holder already answered - DOUBLE ANSWER on reclaim: ${JSON.stringify(texts(a.out))}`);
    } finally {
      if (a) a.c.kill();
      if (b) b.c.kill();
      await sleep(200);
      try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
    }
  });

  await it('daemon handoff: a message the daemon already answered (recorded in the shared guard) is NOT re-emitted by a session that then reads it from the admin log (verify #3/#5)', async () => {
    const dedup = require('./wa-dedup.js');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-handoff-'));
    const adminDir = path.join(dir, 'admin-logs');
    fs.mkdirSync(adminDir, { recursive: true });
    const adminLog = path.join(adminDir, 'admin-20260802.log');
    const slackInbox = path.join(dir, 'slack-inbox.jsonl');
    const presence = path.join(dir, 'presence.json');
    const cfgPath = path.join(dir, 'wa-bridge.json');
    const dedupFile = path.join(dir, 'answered.jsonl');
    fs.writeFileSync(cfgPath, JSON.stringify({
      projects: { 'c:/dev/testproj': { jid: '123@g.us', name: 'TestGroup' } },
      operators: [{ phone: '+972500000000' }],
    }));
    fs.writeFileSync(slackInbox, '');
    fs.writeFileSync(adminLog, '');
    // Simulate the daemon having ANSWERED message D during the no-session gap: it records D's
    // identity in the shared guard (the same claim() the session's emitLine calls). parseChunk will
    // produce {chatId,sender,text} with no msgId, so key on that shape.
    dedup.claim(dedupFile, { chatId: '123@g.us', sender: '+972500000000', text: 'daemon already answered D' });

    const child = spawn(process.execPath, [MON], {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: {
        ...process.env,
        WA_PRESENCE_PATH: presence,
        WA_INBOX_PATH: path.join(dir, 'inbox.jsonl'),
        WA_SESSION_CWD: 'c:/dev/testproj',
        WA_BRIDGE_CONFIG: cfgPath,
        WA_INBOUND_LOG_DIR: adminDir,
        SLACK_INBOX_PATH: slackInbox,
        WA_SESSION_DIRECT_STATE: path.join(dir, 'direct.json'),
        WA_DEDUP_PATH: dedupFile,
        // Resume from BEHIND so the session actually re-reads D (as a real checkpoint resume would).
        WA_INBOX_POLL_MS: '120',
        WA_SESSION_OWNER_WATCH_MS: '0',
        WA_MONITOR_REGISTRY: path.join(dir, 'registry'),
        // start-at-EOF would skip D; force a resume by writing D BEFORE arm and a fresh checkpoint at 0
        WA_DIRECT_RESUME_MAX_AGE_MS: '600000',
      },
    });
    const lines = [];
    child.stdout.on('data', (b) => { for (const l of String(b).split('\n')) if (l.trim()) lines.push(l.trim()); });
    // Pre-write D and a checkpoint at offset 0 so the session resumes and re-reads D.
    fs.appendFileSync(adminLog,
      '[message-hook] Received: channel=whatsapp chatId=123@g.us senderId=+972500000000 text=daemon already answered D\n');
    fs.writeFileSync(path.join(dir, 'direct.json'), JSON.stringify({ waLogName: 'admin-20260802.log', waLogOffset: 0, slackOffset: 0, pid: 1, savedAt: new Date().toISOString() }));

    try {
      await waitFor(() => { try { return !!JSON.parse(fs.readFileSync(presence, 'utf8')).pid; } catch { return false; } }, 8000);
      // Now a NEW message N the daemon did NOT answer.
      await sleep(400);
      fs.appendFileSync(adminLog,
        '[message-hook] Received: channel=whatsapp chatId=123@g.us senderId=+972500000000 text=new message N\n');
      await waitFor(() => lines.some((l) => /new message N/.test(l)), 5000);
      await sleep(400);
      const texts = lines.map((l) => { try { return JSON.parse(l).text; } catch { return l; } });
      assert.ok(texts.includes('new message N'), 'the session dropped the genuinely-new message N');
      assert.ok(!texts.includes('daemon already answered D'),
        `session re-emitted D that the daemon already answered - DAEMON HANDOFF DOUBLE ANSWER: ${JSON.stringify(texts)}`);
    } finally {
      child.kill();
      await sleep(200);
      try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
    }
  });

  console.log(`\npass=${pass} fail=${fail}`);
  process.exit(fail === 0 ? 0 : 1);
})();
