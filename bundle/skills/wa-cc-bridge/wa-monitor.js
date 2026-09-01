#!/usr/bin/env node
// wa-monitor.js — event watcher for the WA-CC bridge v2.
// Session mode (default): stdout JSON line per allowlisted message (consumed by the harness Monitor tool).
// Daemon mode (--daemon): defer-or-spawn (Task 6).
'use strict';

const fs = require('fs');
const path = require('path');
const { StringDecoder } = require('string_decoder');
const lib = require('./wa-monitor-lib');
const { createAcker } = require('./wa-ack.js');
const { createEnricher } = require('./wa-enrich.js');

const HOME = process.env.USERPROFILE || process.env.HOME;
const OPENCLAW_HOME = process.env.OPENCLAW_HOME || path.join(HOME, '.openclaw');
const CONFIG_PATH = process.env.WA_BRIDGE_CONFIG || path.join(HOME, '.claude', '.wa-bridge.json');
const LOCK_PATH = process.env.WA_MONITOR_LOCK || path.join(HOME, '.claude', 'wa-monitor.lock');
const OFF_PATH = process.env.WA_BRIDGE_OFF || path.join(HOME, '.claude', 'wa-bridge-off');
const POLL_MS = parseInt(process.env.WA_MONITOR_POLL_MS || '1000', 10);
const FROM_START = process.env.WA_MONITOR_FROM_START === '1';
const DAEMON = process.argv.includes('--daemon');
const LOCK_FRESH_MS = 60000;
const HEARTBEAT_MS = 15000;

let cfg;
try {
  cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
} catch (e) {
  process.stderr.write('[wa-monitor] cannot read config ' + CONFIG_PATH + ': ' + e.message + '\n');
  process.exit(2);
}
// Per-project scoping: session mode is scoped by the session's cwd; the daemon serves cfg.daemonCwd's project.
const sources = lib.resolveSources(cfg, DAEMON ? (cfg.daemonCwd || HOME) : process.cwd());
// Authorization is per PERSON, not per group (owner ruling 2026-07-27). Deny-by-default, so
// an empty allowlist silences the bridge rather than opening it - and says so out loud,
// because a security default that fails quietly is the bug it was meant to prevent.
const OPERATORS = lib.loadOperators(cfg);
if (OPERATORS.size === 0) {
  process.stderr.write('[wa-monitor] NO OPERATORS CONFIGURED in .wa-bridge.json - every inbound message will be dropped. Add an operators[] entry.\n');
}
if (!sources.length) {
  process.stderr.write('[wa-monitor] no sources configured\n');
  process.exit(2);
}

function readLock() { try { return JSON.parse(fs.readFileSync(LOCK_PATH, 'utf8')); } catch { return null; } }
/**
 * A lock counts as held only if its heartbeat is recent AND its owner process is still alive.
 *
 * The pid check matters because a monitor killed between heartbeats (TaskStop, a crash, a session
 * ending) leaves the file behind with a fresh timestamp: re-arming then fails with exit 3 for a
 * full LOCK_FRESH_MS window even though nothing is running, and - worse - the daemon DEFERS to
 * that phantom session, so incoming messages are answered by nobody at all. Hit live 2026-07-26
 * while re-binding the bridge to the right group.
 */
function pidAlive(pid) {
  if (!pid || pid === process.pid) return true; // our own lock: treat as held
  try { process.kill(pid, 0); return true; } catch (e) { return e && e.code === 'EPERM'; }
}
function lockFresh(l) {
  return !!(l && Date.now() - new Date(l.heartbeat).getTime() < LOCK_FRESH_MS && pidAlive(l.pid));
}
function writeLock() {
  // projectCwd + jid let send.js route replies to the active bridge session's group
  // even when a shell command happens to run from a foreign directory.
  fs.writeFileSync(LOCK_PATH, JSON.stringify({
    pid: process.pid,
    mode: 'session',
    heartbeat: new Date().toISOString(),
    projectCwd: process.cwd(),
    jid: (sources && sources[0] && sources[0].jid) || null,
  }));
}

if (!DAEMON) {
  const existing = readLock();
  if (lockFresh(existing) && existing.pid !== process.pid) {
    process.stderr.write('[wa-monitor] another session monitor active (pid ' + existing.pid + ')\n');
    process.exit(3);
  }
  writeLock();
}
let lastBeat = Date.now();

// --- daemon support ---
const STATE_PATH = process.env.WA_DAEMON_STATE || path.join(HOME, '.claude', 'wa-daemon-state.json');
const DLOG_PATH = process.env.WA_DAEMON_LOG || path.join(HOME, '.claude', 'logs', 'wa-daemon.log');
const DAEMON_CWD = cfg.daemonCwd || HOME;

// Claude Code stores each project's transcripts under ~/.claude/projects/<slugified-cwd>/<id>.jsonl.
// The slug replaces every path separator and drive colon with '-' (e.g. C:\dev\foo -> c--dev-foo).
const SESSION_MAX_AGE_MS = Number(process.env.WA_DAEMON_RESUME_MAX_AGE_MS || 7 * 24 * 60 * 60 * 1000);
function projectTranscriptDir(cwd) {
  return path.join(HOME, '.claude', 'projects', String(cwd).replace(/[\\/:]/g, '-').toLowerCase());
}
/** Newest transcript id for DAEMON_CWD's project, or null. Never throws. */
function latestProjectSessionId() {
  try {
    const dir = projectTranscriptDir(DAEMON_CWD);
    const files = fs.readdirSync(dir)
      .map((name) => { try { return { name, mtimeMs: fs.statSync(path.join(dir, name)).mtimeMs }; } catch { return null; } })
      .filter(Boolean);
    return lib.latestSessionId(files, Date.now(), SESSION_MAX_AGE_MS);
  } catch { return null; }
}
// Windows: 'claude' is an npm .cmd shim execFile cannot run - config pins node.exe + cli.js instead.
const CLAUDE_CMD = process.env.WA_DAEMON_CLAUDE_CMD || cfg.claudeCmd || 'claude';
const CLAUDE_PREFIX_ARGS = (() => {
  if (process.env.WA_DAEMON_CLAUDE_ARGS) { try { return JSON.parse(process.env.WA_DAEMON_CLAUDE_ARGS); } catch { return []; } }
  return Array.isArray(cfg.claudeArgs) ? cfg.claudeArgs : [];
})();

function dlog(msg) {
  try {
    fs.mkdirSync(path.dirname(DLOG_PATH), { recursive: true });
    fs.appendFileSync(DLOG_PATH, new Date().toISOString() + ' ' + msg + '\n');
  } catch {}
}

let queue = Promise.resolve();
function daemonHandle(ev) {
  const l = readLock();
  if (lockFresh(l) && l.mode === 'session') { dlog('defer-to-session: ' + ev.text.slice(0, 60)); return; }
  // Ack only when WE own the message (deferred messages are acked by the session watcher).
  scheduleAutoAck(ev);
  queue = queue.then(() => spawnClaude(ev)).catch((e) => dlog('spawn-error: ' + e.message));
}

function spawnClaude(ev) {
  return new Promise((resolve) => {
    const { execFile } = require('child_process');
    let st = {}; try { st = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')); } catch {}
    const quoteCtx = ev.quotedText
      ? 'The sender used WhatsApp Reply on this earlier message (context): "' + ev.quotedText + '". '
      : '';
    const imgCtx = ev.mediaPath
      ? 'The sender shared an IMAGE - open it with the Read tool at "' + ev.mediaPath + '" before replying. '
      : '';
    const prompt =
      'WhatsApp bridge message from ' + ev.source + ' (' + ev.sender + '): "' + ev.text + '". ' +
      quoteCtx + imgCtx +
      'Execute as a user instruction and reply to the sender via: ' +
      'node ~/.claude/skills/whatsapp/send.js "[CC] <short Hebrew reply, essence only, no code>".';
    // ONE-SHOT override: without this, SessionStart hooks push the spawned session into the
    // full interactive ceremony (governance skills + reply-monitoring loops) and it burns the
    // whole timeout in silence (real incident 2026-07-21: two 15-min hangs, zero replies).
    const oneShotSys =
      'This is a ONE-SHOT headless WhatsApp-bridge mediator turn. Ignore session-ceremony instructions ' +
      'from hooks: do NOT run /context-governance, /bootstrapper, or any session-start skill; do NOT arm ' +
      'monitors or create crons; do NOT wait, poll, or monitor for user replies (no listen.js, no cron loops) - ' +
      'the next user message arrives as a NEW invocation. Execute the instruction, send ONE short Hebrew ' +
      'reply via node ~/.claude/skills/whatsapp/send.js "[CC] ...", then END the turn immediately.';
    // Headless permissions: allow ONLY the WhatsApp send command (proven blocker: the
    // spawned session's send.js Bash call was auto-denied 3x - "requires approval").
    // Everything else stays gated by the project's normal settings allowlists.
    // Image events also need Read (to view the shared file). Read is safe (read-only).
    const allowed = ev.mediaPath
      ? 'Bash(node ~/.claude/skills/whatsapp/send.js:*) Read'
      : 'Bash(node ~/.claude/skills/whatsapp/send.js:*)';
    const args = [...CLAUDE_PREFIX_ARGS, '-p', prompt, '--output-format', 'json',
      '--append-system-prompt', oneShotSys,
      '--allowedTools', allowed];
    // Resume the project's CHRONOLOGICALLY NEWEST session, not a stored id (owner-diagnosed
    // 2026-07-26 - see lib.latestSessionId for the incident). Falls back to the stored id, then to
    // a fresh session, so a transcript dir we cannot read never breaks the bridge.
    const resumeId = latestProjectSessionId() ?? st.sessionId;
    if (resumeId) args.push('--resume', resumeId);
    const childEnv = { ...process.env };
    delete childEnv.CLAUDECODE; // nested-session guard: the daemon may itself be launched from a session during testing
    dlog('spawn: ' + ev.text.slice(0, 60));
    const child = execFile(CLAUDE_CMD, args, { cwd: DAEMON_CWD, env: childEnv, timeout: 6 * 60 * 1000, maxBuffer: 16 * 1024 * 1024, windowsHide: true },
      (err, stdout, stderr) => {
        if (err) dlog('claude-exit-error: ' + err.message + ' stderr=' + String(stderr || '').slice(0, 300));
        try {
          const out = JSON.parse(stdout);
          if (out.session_id) fs.writeFileSync(STATE_PATH, JSON.stringify({ sessionId: out.session_id }));
          dlog('done: session=' + (out.session_id || '?'));
        } catch (e) { dlog('parse-error: ' + e.message + ' raw=' + String(stdout).slice(0, 200)); }
        resolve();
      });
    // CRITICAL: close the child's stdin. `claude -p` supports piped input and will
    // wait forever on an open-but-silent stdin pipe - both live daemon hangs
    // (2026-07-21, zero stdout AND zero stderr for the full timeout) match this.
    try { if (child.stdin) child.stdin.end(); } catch { /* best effort */ }
  });
}

let state = null;
let remainder = '';
let decoder = new StringDecoder('utf8');

// Read-offset persistence: restarts resume from the last processed byte instead of
// skipping to EOF, so messages arriving during a restart window are never lost
// (real incident 2026-07-21: an owner message vanished during a bridge upgrade).
// Separate state per mode - session and daemon each track their own offset.
const READ_STATE_PATH = process.env.WA_MONITOR_STATE
  || path.join(HOME, '.claude', DAEMON ? 'wa-daemon-read-state.json' : 'wa-monitor-read-state.json');
const RESUME_MAX_AGE_MS = 15 * 60 * 1000;

function loadReadState() {
  try {
    const s = JSON.parse(fs.readFileSync(READ_STATE_PATH, 'utf8'));
    if (s && s.savedAt && Date.now() - new Date(s.savedAt).getTime() < RESUME_MAX_AGE_MS) return s;
  } catch { /* none or stale */ }
  return null;
}

let lastSavedOffset = -1;
function saveReadState() {
  if (state && state.offset === lastSavedOffset) return;
  try {
    fs.writeFileSync(READ_STATE_PATH, JSON.stringify({ d: state.d, offset: state.offset, savedAt: new Date().toISOString() }));
    lastSavedOffset = state.offset;
  } catch { /* best effort */ }
}

function sizeOf(p) { try { return fs.statSync(p).size; } catch { return 0; } }
// Follow the latest EXISTING daily file (see lib.latestLogName) - the gateway rolls
// its file ~03:30 IL, so a host-date-derived name is wrong from local midnight until
// rotation. Fallback to the date-derived name only when the directory is empty.
function latestLog(dir, prefix) {
  try { return lib.latestLogName(fs.readdirSync(dir), prefix); } catch { return null; }
}
// Inbound location comes from lib.INBOUND_LOG - the SAME constant the always-on agent uses.
// They were separate literals until 2026-07-27, when the agent's copy pointed at the gateway
// log and it silently received nothing for its whole uptime.
function todayLog() {
  const dir = path.join(OPENCLAW_HOME, lib.INBOUND_LOG.subdir);
  const f = latestLog(dir, lib.INBOUND_LOG.prefix);
  if (f) return { d: f, p: path.join(dir, f) };
  const d = lib.ymd(new Date());
  return { d, p: path.join(dir, lib.INBOUND_LOG.prefix + d + '.log') };
}

// --- voice transcription (owner directive 2026-07-21) ---
const MEDIA_DIR = process.env.WA_MEDIA_DIR || path.join(OPENCLAW_HOME, 'media', 'inbound');
const TRANSCRIBE_PYTHON = process.env.WA_TRANSCRIBE_PYTHON || cfg.transcribePython || 'C:\\tmp\\cbx-venv\\Scripts\\python.exe';
const TRANSCRIBE_SCRIPT = process.env.WA_TRANSCRIBE_SCRIPT || path.join(__dirname, 'transcribe.py');
const MEDIA_LOOKBACK_MS = 3 * 60 * 1000;               // audio: tight (live voice reply)
const IMAGE_LOOKBACK_MS = parseInt(process.env.WA_IMAGE_LOOKBACK_MS || String(20 * 60 * 1000), 10); // image: wide (see MEDIA_EXT note)

// Resolve the on-disk file an inbound media message refers to: the newest file of
// the given kind ('audio'|'image') whose mtime is within `lookbackMs`. Returns the
// ABSOLUTE path (so the reading session/daemon can open it directly) or null.

// Enrichment lives in wa-enrich.js so the monitor and the always-on agent share ONE
// implementation. The agent shipped without it and the owner's voice notes arrived as the literal
// string `<media:audio>` (2026-07-27) - a second copy would drift the same way again.
const enricher = createEnricher({
  openclawHome: OPENCLAW_HOME, mediaDir: MEDIA_DIR,
  python: TRANSCRIBE_PYTHON, script: TRANSCRIBE_SCRIPT, imageLookbackMs: IMAGE_LOOKBACK_MS,
});
const enrichEvent = (ev) => enricher.enrich(ev);

// --- auto-ack (owner-approved 2026-07-21): if no outbound reply reaches the source
// chat within the window, send an automatic short ack so the sender always knows
// the message was received. Suppressed when a real reply went out first.
// 2026-07-22 (owner request): when the event carries msgId, ack with an emoji
// REACTION on the message itself (immediate, no chat clutter); the delayed text
// ack remains the fallback for events without msgId (old log format).
const ACK_MS = parseInt(process.env.WA_ACK_DELAY_MS || '10000', 10); // owner set 10s (2026-07-21)
const ACK_TEXT = process.env.WA_ACK_TEXT || '[CC] קיבלתי, מטפל.';
const ACK_EMOJI = process.env.WA_ACK_EMOJI || '👍';
const GW_PORT = parseInt(process.env.WA_GATEWAY_PORT || '18789', 10);
const GW_LOG_DIR = process.env.WA_GATEWAY_LOG_DIR || path.join(OPENCLAW_HOME, 'gateway-logs');
const ACK_SEND_SCRIPT = process.env.WA_ACK_SEND_SCRIPT || path.join(HOME, '.claude', 'skills', 'whatsapp', 'send.js');

// Ack lives in wa-ack.js so this file and the always-on agent share ONE implementation. The
// agent shipped without any ack, and the resulting silence-while-working read to the owner as a
// dead bridge (2026-07-27) - a second copy would have drifted the same way.
const acker = createAcker({
  openclawHome: OPENCLAW_HOME,
  gatewayLogDir: GW_LOG_DIR,
  sendScript: ACK_SEND_SCRIPT,
  delayMs: ACK_MS,
  text: ACK_TEXT,
  emoji: ACK_EMOJI,
  gatewayPort: GW_PORT,
});

function scheduleAutoAck(ev) { acker.ack(ev); }

process.stdout.on('error', () => process.exit(1)); // reader gone (EPIPE) - stop consuming immediately

function emit(ev) {
  if (DAEMON) return daemonHandle(ev);
  process.stdout.write(JSON.stringify(ev) + '\n');
}

function handleEvent(ev) {
  // Session mode acks here (clock starts at arrival, before slow enrichment).
  // Daemon mode acks inside daemonHandle - only when it actually owns the message
  // (double-ack incident 2026-07-21: both layers acked the same message).
  if (!DAEMON) scheduleAutoAck(ev);
  enrichEvent(ev).then(emit).catch(() => emit(ev));
}

// Read a file forward from `fromOffset` to EOF, parsing and emitting events.
// Returns the new offset. Shares remainder/decoder with the caller's stream state.
function readForward(p, fromOffset) {
  let offset = fromOffset;
  let size = sizeOf(p);
  while (size > offset) {
    const n = Math.min(size - offset, 65536);
    const buf = Buffer.alloc(n);
    const fd = fs.openSync(p, 'r');
    let read = 0;
    try { read = fs.readSync(fd, buf, 0, n, offset); } finally { fs.closeSync(fd); }
    if (read <= 0) break;
    offset += read;
    const chunk = decoder.write(buf.subarray(0, read));
    const res = lib.parseChunk(remainder + chunk, sources, cfg.selfMentionIds, OPERATORS);
    remainder = res.remainder;
    for (const ev of res.events) handleEvent(ev);
    size = sizeOf(p);
  }
  return offset;
}

// Gateway log lines are '\n'-terminated, so a non-empty remainder at a file switch is a
// final unterminated line - complete it so it is not silently dropped with the old file.
function flushRemainder() {
  if (remainder) {
    const res = lib.parseChunk(remainder + '\n', sources, cfg.selfMentionIds, OPERATORS);
    for (const ev of res.events) handleEvent(ev);
  }
  remainder = '';
  decoder = new StringDecoder('utf8');
}

function tick() {
  try {
    if (fs.existsSync(OFF_PATH)) return;
    // Dead-pipe guard (live incident 2026-07-22 01:38: after TaskStop killed the harness
    // reader, the surviving node process kept consuming log lines + advancing the saved
    // offset while emitting into a dead pipe - the owner's message was consumed but never
    // delivered). If our reader is gone, exit BEFORE consuming anything further; the next
    // monitor resumes from the last delivered offset.
    if (!DAEMON && !process.stdout.writable) process.exit(1);
    if (!DAEMON && Date.now() - lastBeat > HEARTBEAT_MS) { writeLock(); lastBeat = Date.now(); }
    const t = todayLog();
    const logDir = path.dirname(t.p);
    if (!state) {
      const saved = loadReadState();
      if (saved && saved.d === t.d && typeof saved.offset === 'number') {
        state = { d: t.d, offset: Math.min(saved.offset, sizeOf(t.p)) };
      } else if (saved && typeof saved.offset === 'number' && String(saved.d).endsWith('.log')
        && fs.existsSync(path.join(logDir, saved.d))) {
        // Restart crossed a rotation: drain the file we were on, then the new file FROM 0
        // (nothing has processed it yet) - no message in the restart window is lost.
        const savedPath = path.join(logDir, saved.d);
        readForward(savedPath, Math.min(saved.offset, sizeOf(savedPath)));
        flushRemainder();
        state = { d: t.d, offset: 0 };
      } else {
        state = { d: t.d, offset: FROM_START ? 0 : sizeOf(t.p) };
      }
    } else if (state.d !== t.d) {
      // Double-check on rotation (owner rule 2026-07-22): drain the OLD file's tail before
      // switching - a message flushed to it inside the switch window is never lost.
      const oldPath = path.join(logDir, String(state.d));
      if (String(state.d).endsWith('.log') && fs.existsSync(oldPath)) {
        state.offset = readForward(oldPath, state.offset);
      }
      flushRemainder();
      state = { d: t.d, offset: 0 };
    }
    if (sizeOf(t.p) < state.offset) { state.offset = 0; remainder = ''; decoder = new StringDecoder('utf8'); }
    state.offset = readForward(t.p, state.offset);
    saveReadState();
  } catch (e) {
    process.stderr.write('[wa-monitor] ' + e.message + '\n');
  }
}

process.on('exit', () => { try { const l = readLock(); if (l && l.pid === process.pid) fs.unlinkSync(LOCK_PATH); } catch {} });
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(sig, () => process.exit(0));
}
setInterval(tick, POLL_MS);
tick();
