#!/usr/bin/env node
'use strict';
/**
 * wa-session-inbox.js — what an INTERACTIVE session arms so its owner's WhatsApp AND Slack messages
 * arrive as turns in the session the owner is already talking to.
 *
 * ONE READER, chosen by presence (owner decision 2026-08-02, after an adversarial review found the
 * earlier two-reader relay/direct design had 12 real defects - five of them double-answer).
 * ------------------------------------------------------------------------------------------------
 * WHY (owner reports 2026-07-27 -> 2026-07-31): the 2026-07-27 "one reader" refactor made this
 * monitor read ONLY `wa-inbox.jsonl`, a file that only the always-on daemon writes. Killing the
 * daemon starved BOTH channels while every health signal looked green.
 *
 * THE MODEL NOW:
 *   - While this session OWNS the bridge (fresh presence claim), it reads the RAW sources ITSELF -
 *     the WhatsApp admin log and the Slack daemon's inbox - and emits each new operator event to
 *     stdout. It never reads `wa-inbox.jsonl`. So it is self-sufficient: the daemon is an option,
 *     never a dependency, and a message can reach the live session with no daemon running at all.
 *   - The always-on daemon still reads the same raw sources, but its `routeEvent` YIELDS answering
 *     to a live session (fresh presence). So exactly one process ever ANSWERS: the session while it
 *     owns presence, the daemon when no session does. Both reading the raw files is harmless - only
 *     one emits to the owner. This is why there is no cross-process double-answer to guard: the
 *     session never consumes the daemon's inbox, so a daemon re-append can never reach the owner
 *     twice.
 *   - Presence is heartbeat-based and removed on exit, so a crash cannot mute the bridge and a
 *     newer session takes the bridge over (newest-wins). Only the OWNER emits; a STANDBY follows
 *     nothing and stays silent until it legitimately takes a stale claim back.
 *
 * Arm with:  node ~/.claude/skills/wa-cc-bridge/wa-session-inbox.js   (persistent Monitor)
 */
const fs = require('fs');
const path = require('path');
const inbox = require('./wa-inbox.js');
const sessionOwner = require('./session-owner.js');
const lib = require('./wa-monitor-lib.js');
const { createEnricher } = require('./wa-enrich.js');
const dedup = require('./wa-dedup.js');

const HOME = process.env.USERPROFILE || process.env.HOME || '.';
const CWD = process.env.WA_SESSION_CWD || process.cwd();
// PER-PROJECT claim (2026-08-17). Passing CWD is what lets a second project run its own bridge
// instead of being pushed into STANDBY by whichever session happened to start last on this machine.
const PRESENCE = process.env.WA_PRESENCE_PATH || inbox.presencePath(HOME, CWD);
const BEAT_MS = Number(process.env.WA_PRESENCE_BEAT_MS || 15_000);
const POLL_MS = Number(process.env.WA_INBOX_POLL_MS || 1000);
/** Exit after this long (used only by the self-test). */
const MAX_MS = Number(process.env.WA_SESSION_INBOX_MAX_MS || 0);
/** How often to ask whether the session that armed this monitor still exists. 0 disables. */
const WATCH_MS = Number(process.env.WA_SESSION_OWNER_WATCH_MS ?? 5_000);

// ─── RAW SOURCES ─────────────────────────────────────────────────────────────────────────────
const OPENCLAW_HOME = process.env.OPENCLAW_HOME || path.join(HOME, '.openclaw');
const SLACK_INBOX = process.env.SLACK_INBOX_PATH || path.join(HOME, '.claude', 'slack-inbox.jsonl');
const CONFIG_PATH = process.env.WA_BRIDGE_CONFIG || path.join(HOME, '.claude', '.wa-bridge.json');
const IN_LOG_DIR = process.env.WA_INBOUND_LOG_DIR || path.join(OPENCLAW_HOME, lib.INBOUND_LOG.subdir);
// Per-PROJECT checkpoint: newest-wins presence is global, so only one session answers at a time,
// but the read position into the shared admin log is meaningful only within a project's own group
// filter. Keying the checkpoint by cwd keeps two projects' offsets from clobbering each other, and
// lets a reclaiming same-project session resume EXACTLY where the dead holder committed.
const CWD_SLUG = String(CWD).replace(/[:\\/]+/g, '-').replace(/^-+|-+$/g, '').toLowerCase();
const DIRECT_STATE = process.env.WA_SESSION_DIRECT_STATE || path.join(HOME, '.claude', `wa-session-direct-${CWD_SLUG}.json`);
// The shared already-answered guard makes double-answer impossible regardless of offset timing, so
// the offsets below only need to never SKIP an un-emitted line (a re-read is de-duplicated here).
const DEDUP_FILE = process.env.WA_DEDUP_PATH || dedup.dedupPath(HOME);
// The instant a new message is delivered, drop an "eyes" reaction on it so the owner sees the agent
// received it and is on it (owner rule 2026-08-02). Fire-and-forget subprocess; never blocks.
const REACT_JS = process.env.WA_REACT_JS || path.join(__dirname, 'react.js');
const REACT_ENABLED = process.env.WA_REACT_ENABLED !== '0';
// Resume a checkpoint only if fresh. CLAMPED to below the dedup TTL (verify v3 #3): a checkpoint
// older than the guard's memory could re-read messages the daemon answered but the guard has since
// forgotten, re-delivering them. Keeping the window inside the TTL means every re-read is still
// covered by the guard - correctness, not just efficiency.
const DIRECT_RESUME_MAX_AGE_MS = Math.min(
  Number(process.env.WA_DIRECT_RESUME_MAX_AGE_MS || 15 * 60 * 1000),
  dedup.DEFAULT_TTL_MS - 60_000,
);

let bridgeCfg = {};
try { bridgeCfg = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')); } catch { /* defaults below */ }
// Same resolution the daemon uses, so the session reads exactly the group/operators the bridge is
// configured for - no drift between who the daemon answered and who the session now answers.
const SOURCES = lib.resolveSources(bridgeCfg, CWD);
const OPERATORS = lib.loadOperators(bridgeCfg);
const SELF_IDS = bridgeCfg.selfMentionIds || bridgeCfg.selfIds || bridgeCfg.selfLids || [];
// Voice/image resolution, shared module (fail-soft): a transcription failure emits the raw event
// rather than dropping it - matches the daemon and the old monitor.
const enricher = createEnricher({ openclawHome: OPENCLAW_HOME, home: HOME, log: (m) => process.stderr.write(`[wa-session-inbox] ${m}\n`) });

function size(p) { try { return fs.statSync(p).size; } catch { return 0; } }

// Reader state. `committed` is a NEWLINE-ALIGNED byte offset: reads always cut at the last '\n' in
// the region, so a partial trailing line and multibyte (Hebrew) UTF-8 chars are never split - the
// partial line is simply re-read next tick. `committed` is what gets persisted; resuming from it
// can only ever RE-read (which the dedup guard suppresses), never skip. `waBusy` blocks re-entry
// while an async enrichment is in flight.
let waLog = { name: null, committed: 0 };
let waBusy = false;
let slack = { committed: 0 };
let slackBusy = false;   // directReadSlack is async too (it enriches Slack voice/image)

/**
 * EXACTLY ONE ANSWERER (owner, 2026-07-29, with a screenshot of two replies to one message). The
 * first fresh presence claim owns the bridge; a newer session takes over (newest-wins); older
 * monitors stand by silently and take over only once a claim goes stale (a crashed session must
 * not mute the bridge for good).
 */
const REGISTRY_DIR = process.env.WA_MONITOR_REGISTRY || path.join(HOME, '.claude', 'wa-monitors');
const REGISTRY_FILE = path.join(REGISTRY_DIR, `${process.pid}.json`);
function registerMonitor(sessionPid) {
  try {
    fs.mkdirSync(REGISTRY_DIR, { recursive: true });
    fs.writeFileSync(REGISTRY_FILE, JSON.stringify({
      monitorPid: process.pid, sessionPid: sessionPid ?? null, cwd: CWD,
      startedAt: new Date().toISOString(),
    }));
  } catch { /* the bridge must not die over bookkeeping */ }
}
function unregisterMonitor() {
  try { fs.unlinkSync(REGISTRY_FILE); } catch { /* already gone */ }
}
/** Drop entries whose process is gone (a force-killed monitor never runs its exit handler). */
function pruneRegistry() {
  try {
    for (const name of fs.readdirSync(REGISTRY_DIR)) {
      if (!name.endsWith('.json')) continue;
      const pid = Number(name.slice(0, -5));
      if (!Number.isInteger(pid) || pid === process.pid) continue;
      let alive = true;
      try { process.kill(pid, 0); } catch (e) { alive = !(e && e.code === 'ESRCH'); }
      if (!alive) try { fs.unlinkSync(path.join(REGISTRY_DIR, name)); } catch { /* raced */ }
    }
  } catch { /* no registry yet */ }
}

// ─── raw readers ─────────────────────────────────────────────────────────────────────────────
// Deliver one event, unless the shared guard says another answerer already claimed it. The guard -
// not the offsets - is what guarantees no double-answer across takeovers, restarts and the daemon
// handoff; the offsets only avoid re-scanning the whole log.
function emitLine(ev) {
  if (!ev || typeof ev !== 'object') return;
  if (dedup.seen(DEDUP_FILE, ev)) return;   // already answered by another reader
  // Record only AFTER a successful write: if stdout is gone (EPIPE) the message was NOT delivered,
  // so leaving it unrecorded lets the next reader deliver it instead of the guard swallowing it
  // (verify v3 #7). A write failure means this monitor's session is dead; the stdout error handler
  // will shut it down.
  try { process.stdout.write(JSON.stringify(ev) + '\n'); } catch { return; }
  dedup.record(DEDUP_FILE, ev);
  fireReaction(ev);   // 👀 on the message itself, the moment it is delivered
}

function fireReaction(ev) {
  if (!REACT_ENABLED || !ev.chatId || !ev.msgId) return;   // old-format lines w/o msgId can't be reacted to
  try {
    require('child_process')
      .spawn(process.execPath, [REACT_JS, JSON.stringify(ev)], { detached: true, stdio: 'ignore' })
      .unref();
  } catch { /* fire-and-forget - a missing courtesy reaction must never disturb the reader */ }
}

// Resolve the admin log to tail. `ok:false` means readdirSync THREW (a transient fs glitch); an
// empty-but-readable dir returns name:null. Neither ever fabricates a host-date name, which at the
// host-midnight->gateway-rotation boundary could be lexically LOWER than the real file and wedge the
// forward-only rotation guard (verify finding #14).
function currentWaLog() {
  let names = null;
  try { names = fs.readdirSync(IN_LOG_DIR); } catch { return { name: null, path: null, ok: false }; }
  const name = lib.latestLogName(names, lib.INBOUND_LOG.prefix);
  if (!name) return { name: null, path: null, ok: true };   // readable but empty - wait for a real file
  return { name, path: path.join(IN_LOG_DIR, name), ok: true };
}

// Read [from, to) of a file into a Buffer. Byte-domain so nothing is decoded across a boundary.
function readRegion(p, from, to) {
  let fd;
  try {
    fd = fs.openSync(p, 'r');
    const buf = Buffer.alloc(to - from);
    const n = fs.readSync(fd, buf, 0, buf.length, from);
    return buf.subarray(0, n);
  } finally { if (fd !== undefined) try { fs.closeSync(fd); } catch { /* ignore */ } }
}

// Drain an admin-log file from st.committed. Reads the whole [committed, EOF] region, cuts at the
// LAST newline (so a partial final line and any multibyte char are never split - the tail is simply
// re-read next tick), enriches, emits, then advances committed to that newline boundary. Because
// committed only ever moves to a line boundary and only forward past emitted lines, a resume can
// re-read but never skip; the dedup guard suppresses the re-reads. Never throws.
async function drainWaFile(p, st) {
  const sz = size(p);
  if (sz < st.committed) st.committed = 0;   // truncated/rotated in place
  if (sz <= st.committed) return;
  let buf;
  try { buf = readRegion(p, st.committed, sz); } catch (e) { process.stderr.write(`[wa-session-inbox] wa read error: ${e.message}\n`); return; }
  const lastNL = buf.lastIndexOf(0x0A);
  if (lastNL === -1) return;   // no complete line yet
  const complete = buf.subarray(0, lastNL + 1).toString('utf8');
  const advance = lastNL + 1;
  const res = lib.parseChunk(complete, SOURCES, SELF_IDS, OPERATORS);   // complete ends in \n -> no remainder
  for (const ev of res.events) {
    let out = ev;
    try { out = await enricher.enrich(ev); } catch { out = ev; }   // fail-soft: emit raw on failure
    if (role === 'owner') emitLine(out);   // re-check role AFTER the (possibly long) enrichment
  }
  // Advance + persist only while still owner: a takeover mid-enrichment leaves committed where it
  // was, so the new owner re-reads (and the dedup guard suppresses anything already delivered).
  if (role === 'owner') { st.committed += advance; saveDirectState(); }
}

async function directReadWhatsApp() {
  if (waBusy) return;
  waBusy = true;
  try {
    const cur = currentWaLog();
    if (!cur.ok) {   // readdir failed transiently: never fabricate a name; re-drain what we have
      if (waLog.name) await drainWaFile(path.join(IN_LOG_DIR, waLog.name), waLog);
      return;
    }
    if (!cur.name) return;   // dir empty - nothing to tail yet
    if (!waLog.name) {
      waLog = { name: cur.name, committed: size(cur.path) };   // first sight of a real file: start at EOF
    } else if (cur.name > waLog.name) {
      // Forward rotation only (date-stamped names sort chronologically). Drain the old file's tail
      // before switching so a message flushed in the switch window is not lost.
      await drainWaFile(path.join(IN_LOG_DIR, waLog.name), waLog);
      waLog = { name: cur.name, committed: 0 };
    }
    await drainWaFile(waLog.name === cur.name ? cur.path : path.join(IN_LOG_DIR, waLog.name), waLog);
  } finally {
    waBusy = false;
  }
}

// Drain the Slack inbox the same byte-accurate way. Slack lines are complete JSON events already; a
// malformed line is skipped, never stops the batch. Slack events are ENRICHED too (the slack daemon
// downloads voice/image into the shared media dir precisely so this enricher transcribes them - the
// same path WhatsApp voice uses), so a Slack voice note arrives as text, not a raw '<media:audio>'.
async function directReadSlack() {
  if (slackBusy) return;
  slackBusy = true;
  try {
    const sz = size(SLACK_INBOX);
    if (sz < slack.committed) slack.committed = 0;
    if (sz <= slack.committed) return;
    let buf;
    try { buf = readRegion(SLACK_INBOX, slack.committed, sz); } catch (e) { process.stderr.write(`[wa-session-inbox] slack read error: ${e.message}\n`); return; }
    const lastNL = buf.lastIndexOf(0x0A);
    if (lastNL === -1) return;
    const complete = buf.subarray(0, lastNL + 1).toString('utf8');
    const advance = lastNL + 1;
    const events = [];
    for (const line of complete.split('\n')) {
      const t = line.trim();
      if (!t) continue;
      try { events.push(JSON.parse(t)); } catch { /* one malformed line must not stop the batch */ }
    }
    for (const ev of events) {
      let out = ev;
      try { out = await enricher.enrich(ev); } catch { out = ev; }   // fail-soft: emit raw on failure
      if (role === 'owner') emitLine(out);
    }
    if (role === 'owner') { slack.committed += advance; saveDirectState(); }
  } finally {
    slackBusy = false;
  }
}

// Persist the newline-aligned committed offsets (atomically: temp file + rename, so a crash during
// the write never leaves a truncated checkpoint a reclaimer would fail to parse - verify #12/#13).
function saveDirectState() {
  try {
    const tmp = DIRECT_STATE + '.tmp.' + process.pid;
    fs.writeFileSync(tmp, JSON.stringify({
      waLogName: waLog.name, waLogOffset: waLog.committed, slackOffset: slack.committed,
      pid: process.pid, savedAt: new Date().toISOString(),
    }));
    fs.renameSync(tmp, DIRECT_STATE);
  } catch { /* best effort - the bridge must not die over a checkpoint */ }
}

// Seed the raw offsets at STARTUP: resume a fresh per-project checkpoint (VS-reload / crashed-holder
// continuity) or start at the current EOF. Only ever used at process load - a standby->owner reclaim
// keeps its own in-memory committed (see the beat), which never advanced during standby. Resuming a
// slightly-behind position is always safe: the dedup guard suppresses any re-read.
function initRawState(startEofs) {
  try {
    const s = JSON.parse(fs.readFileSync(DIRECT_STATE, 'utf8'));
    if (s && s.savedAt && Date.now() - new Date(s.savedAt).getTime() < DIRECT_RESUME_MAX_AGE_MS) {
      if (s.waLogName) {
        const off = (typeof s.waLogOffset === 'number') ? s.waLogOffset : 0;
        const c = (s.waLogName === startEofs.waName) ? Math.min(off, startEofs.waSize) : off;
        waLog = { name: s.waLogName, committed: c };
      } else {
        waLog = { name: startEofs.waName, committed: startEofs.waSize };
      }
      slack = { committed: (typeof s.slackOffset === 'number') ? Math.min(s.slackOffset, startEofs.slackSize) : startEofs.slackSize };
      return true;
    }
  } catch { /* no checkpoint */ }
  waLog = { name: startEofs.waName, committed: startEofs.waSize };
  slack = { committed: startEofs.slackSize };
  return false;
}

function reseedRaw() {
  const cur = currentWaLog();
  return initRawState({
    waName: cur.ok ? cur.name : null,
    waSize: cur.ok && cur.name ? size(cur.path) : 0,
    slackSize: size(SLACK_INBOX),
  });
}

// ─── presence + startup ──────────────────────────────────────────────────────────────────────
const previous = inbox.readPresence(PRESENCE);
let role = inbox.claimPresence(PRESENCE, CWD, Date.now(), process.pid, { takeover: true });

// Capture start-of-process EOFs BEFORE the first poll, then seed the raw readers from them.
reseedRaw();
process.stderr.write(
  previous && previous.pid && previous.pid !== process.pid
    ? `[wa-session-inbox] OWNER - took the bridge over from pid ${previous.pid} (newest session leads); reading raw sources for ${CWD}\n`
    : `[wa-session-inbox] OWNER of the bridge for ${CWD}; reading admin log + slack inbox directly\n`,
);

const beat = setInterval(() => {
  // NOT a takeover: a heartbeat only refreshes a claim we still hold.
  const next = inbox.claimPresence(PRESENCE, CWD);
  if (next !== role) {
    // Reclaiming the bridge (a newer holder went stale or closed): just resume from OUR OWN frozen
    // committed offsets. A standby never advanced them, so they sit at or behind the true unanswered
    // window - resuming there re-reads whatever the departed holder answered, and the dedup guard
    // suppresses those, leaving exactly the unanswered window. No checkpoint reload, no age gate, no
    // cross-project offset confusion (verify findings #5/#9/#10 dissolve once dedup, not offsets,
    // guarantees no-double).
    role = next;
    process.stderr.write(
      role === 'standby'
        ? '[wa-session-inbox] STANDBY - a newer session took the bridge; staying silent\n'
        : '[wa-session-inbox] OWNER - reclaimed the bridge; resuming from our committed offset (dedup covers re-reads)\n',
    );
  }
}, BEAT_MS);

const poll = setInterval(() => {
  // ASK THE FILE, DO NOT TRUST THE CACHED ROLE: a monitor that had just been replaced went on
  // emitting for up to a heartbeat - both monitors answering, the defect this claim exists to end.
  if (role === 'owner') {
    const cur = inbox.readPresence(PRESENCE);
    if (cur && cur.pid !== undefined && cur.pid !== process.pid) {
      role = 'standby';
      process.stderr.write('[wa-session-inbox] STANDBY - a newer session took the bridge; staying silent\n');
    }
  }
  // Only the owner reads a source; a standby follows nothing and its offsets stay frozen so the
  // unanswered window survives for a legitimate stale-takeover.
  if (role !== 'owner') return;
  directReadWhatsApp();   // async + self-guarded; drains WhatsApp with enrichment
  directReadSlack();      // sync; drains the Slack inbox
}, POLL_MS);

/**
 * The session that armed this monitor. SessionEnd releases presence on a NORMAL close; a hard kill
 * runs no hook, and a monitor that outlives its session goes on claiming the owner's messages while
 * nothing answers. Unresolvable -> no watchdog (fail open): killing a live session's bridge is worse.
 */
const OWNER = WATCH_MS > 0 ? sessionOwner.resolveOwner() : null;
pruneRegistry();
registerMonitor(OWNER ? OWNER.pid : null);
process.stderr.write(
  OWNER
    ? `[wa-session-inbox] session owner pid=${OWNER.pid} (${OWNER.name}, via ${OWNER.source})\n`
    : '[wa-session-inbox] session owner UNRESOLVED - no liveness watchdog\n',
);

// `let`, assigned after: shutdown() closes over it, and a const in its temporal dead zone would
// turn any early exit into a ReferenceError instead of a clean release.
let watch = null;
watch = OWNER
  ? setInterval(() => {
      if (sessionOwner.isAlive(OWNER)) return;
      process.stderr.write(`[wa-session-inbox] session pid=${OWNER.pid} is gone - releasing\n`);
      shutdown(0);
    }, WATCH_MS)
  : null;

function shutdown(code) {
  clearInterval(beat);
  clearInterval(poll);
  if (watch) clearInterval(watch);
  unregisterMonitor();
  inbox.clearPresence(PRESENCE);
  process.exit(code || 0);
}
process.on('SIGINT', () => shutdown(0));
process.on('SIGTERM', () => shutdown(0));
process.on('exit', () => { unregisterMonitor(); inbox.clearPresence(PRESENCE); });
// Our reader is gone (EPIPE) - stop announcing a session that no longer listens.
process.stdout.on('error', () => shutdown(1));
if (MAX_MS) setTimeout(() => shutdown(0), MAX_MS).unref?.();
