#!/usr/bin/env node
/**
 * wa-live-agent.mjs — the ALWAYS-ON WhatsApp agent (owner request, 2026-07-26).
 *
 * What it replaces and why
 * ------------------------
 * The v2 bridge daemon spawns `claude -p --resume <id>` per message: a fresh process each
 * time, which re-sends the whole transcript, pays a cold prompt cache, and exits — so nothing
 * is "alive" between messages. The owner's ask was explicit: an agent that runs continuously,
 * continues from where the last session stopped, and does NOT reload the whole context on
 * every message ("like VS keeps the session open in its window").
 *
 * This is that. ONE long-lived process holds ONE Claude Code session open via the Agent SDK's
 * streaming-input mode: `query()` is called once with an async-iterable prompt, and each
 * incoming WhatsApp message is pushed into that iterable as the next turn on the SAME session.
 * Context lives in the session for the process's lifetime, so it is neither rebuilt nor resent
 * per message, and the prompt prefix stays cache-stable across turns — which is the actual
 * cost saving the owner asked for.
 *
 * Context across restarts: NONE is inherited (owner ruling 2026-07-29, "the current method is
 * not acceptable to me"). It used to boot by forking the project's newest transcript, which made
 * every answer speak from a picture frozen at daemon-boot - authoritative-sounding and quietly
 * ageing. Each conversation now starts CLEAN and imports state deliberately: `context-governance`
 * once per conversation, `bootstrapper` on every turn scoped to the question just asked. Both
 * channels (WhatsApp and Slack) run through the same path.
 *
 * Relationship to the v2 daemon: this is ADDITIVE and not wired in. Both must never run at
 * once - they would both answer. This process takes the same `~/.claude/wa-monitor.lock` the
 * v2 monitor uses, so whichever starts first wins and the other exits 3. Switching over is an
 * owner decision (see SWITCHOVER in the skill doc), not something this file does implicitly.
 *
 * Safety: the agent replies through the SAME send.js the rest of the bridge uses, and its
 * tool surface is whatever the project's own settings allow — this file grants nothing extra.
 */
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { StringDecoder } from 'node:string_decoder';
import { fileURLToPath } from 'node:url';

import { query } from '@anthropic-ai/claude-agent-sdk';

const require = createRequire(import.meta.url);
const lib = require('../wa-monitor-lib.js');
const inbox = require('../wa-inbox.js');
const { createAcker } = require('../wa-ack.js');
const { createEnricher } = require('../wa-enrich.js');
const dedup = require('../wa-dedup.js');

const HOME = process.env.USERPROFILE || process.env.HOME || '.';
const OPENCLAW_HOME = process.env.OPENCLAW_HOME || path.join(HOME, '.openclaw');
// Inbound messages come from the admin log, NOT the gateway log - see lib.INBOUND_LOG for the
// full reason. Resolved through the shared constant so this file and wa-monitor.js cannot drift.
const IN_LOG_DIR = process.env.WA_INBOUND_LOG_DIR || path.join(OPENCLAW_HOME, lib.INBOUND_LOG.subdir);
const LOCK_PATH = process.env.WA_MONITOR_LOCK || path.join(HOME, '.claude', 'wa-monitor.lock');
const STATE_PATH = process.env.WA_LIVE_AGENT_STATE || path.join(HOME, '.claude', 'wa-live-agent-state.json');
// Overridable so an end-to-end test can point at a stub and exercise the whole path without
// actually messaging the owner.
const SEND_JS = process.env.WA_AGENT_SEND_JS || path.join(HOME, '.claude', 'skills', 'whatsapp', 'send.js');
const CWD = process.env.WA_AGENT_CWD || process.cwd();
const POLL_MS = Number(process.env.WA_AGENT_POLL_MS || 1000);
// Must exceed the longest blocking call in this process: sendWhatsApp() spawns SYNCHRONOUSLY
// for up to 120s, during which the 20s heartbeat cannot run. At 60s the lock went stale mid-
// send and a second bridge could take it - two agents answering, which is the one thing the
// lock exists to prevent (PR #157 round 2, P1).
const LOCK_FRESH_MS = Number(process.env.WA_AGENT_LOCK_FRESH_MS || 180_000);
const HEARTBEAT_MS = 20_000;
/** A transcript touched inside this window means that session is being worked in right now. */
const UNARMED_FRESH_MS = Number(process.env.WA_AGENT_UNARMED_FRESH_MS || 120_000);
/** After this long without a turn, the loaded project state is treated as possibly moved. */
const CONTEXT_STALE_MS = Number(process.env.WA_AGENT_CONTEXT_STALE_MS || 2 * 60 * 60 * 1000);

/**
 * How much context this turn has to load. Exported and pure so the rule is testable - the first
 * version lived inside main() as a closure, where no test could reach it and a mutation to it
 * changed nothing that any assertion could see.
 */
export function contextPhase(lastLoadMs, nowMs = Date.now(), staleMs = CONTEXT_STALE_MS) {
  if (!lastLoadMs) return 'first';
  return nowMs - lastLoadMs >= staleMs ? 'stale' : 'warm';
}
const INBOX_PATH = process.env.WA_INBOX_PATH || inbox.inboxPath(HOME);
// PER-PROJECT claim (2026-08-17). The agent yields to a live session ON ITS OWN PROJECT; reading a
// machine-wide file made it yield to a session working somewhere else entirely, so nobody answered.
const PRESENCE_PATH = process.env.WA_PRESENCE_PATH || inbox.presencePath(HOME, CWD);
/** Written by `slack-monitor.js --daemon`; read here so ONE agent serves both channels. */
const SLACK_INBOX_PATH = process.env.SLACK_INBOX_PATH
  || path.join(HOME, '.claude', 'slack-inbox.jsonl');
/** The shared already-answered guard - same file the session monitors use (see wa-dedup.js). */
const DEDUP_FILE = process.env.WA_DEDUP_PATH || dedup.dedupPath(HOME);

const enricher = createEnricher({ openclawHome: OPENCLAW_HOME, home: HOME, log: (m) => log(m) });

const acker = createAcker({
  openclawHome: OPENCLAW_HOME,
  sendScript: SEND_JS,
  delayMs: Number(process.env.WA_ACK_DELAY_MS || 10_000),
  log: (m) => log(m),
});

/**
 * Decide what to do with an inbound event. Exported so the routing rule is testable without a
 * live session, a gateway or the SDK.
 *
 * Always ack, always record in the inbox. Only ANSWERING is conditional: a live interactive
 * session for this project answers instead of us, so the owner never gets two agents working the
 * same instruction on the same repo.
 */
/**
 * Does the live session own the GROUP this message arrived in?
 *
 * Second, independent test beside the cwd string match. The 2026-07-29 double-answer bug was a
 * path-spelling mismatch (`c:/dev/x` vs `C:\dev\x`) that made a live session on the SAME repo
 * look foreign; normalising the separators fixes that instance, but the property the interlock
 * actually needs is "somebody live already owns this conversation". A message arrives in exactly
 * one group, `resolveSources` maps a project directory to exactly one group, so comparing those
 * two answers the real question and does not care how either path was spelled.
 */
export function presenceOwnsEventGroup(presence, ev, nowMs = Date.now(), cfg = readBridgeConfig()) {
  if (!presence || !presence.heartbeat || !presence.cwd || !ev || !ev.chatId) return false;
  const beat = new Date(presence.heartbeat).getTime();
  if (!Number.isFinite(beat) || nowMs - beat >= inbox.PRESENCE_FRESH_MS) return false;
  try {
    const [src] = lib.resolveSources(cfg, presence.cwd);
    return !!src && lib.normalizeJid(src.jid) === lib.normalizeJid(ev.chatId);
  } catch { return false; }
}

export function readBridgeConfig() {
  try { return JSON.parse(fs.readFileSync(path.join(HOME, '.claude', '.wa-bridge.json'), 'utf8')); }
  catch { return {}; }
}

/**
 * Claude Code stores a project's transcripts under a directory named after its cwd with every
 * separator and drive colon replaced by `-`. Exported so the encoding is asserted, not assumed.
 */
export function projectsDirFor(cwd, home = HOME) {
  return path.join(home, '.claude', 'projects', String(cwd || '').replace(/[:\\/]/g, '-'));
}

/**
 * "Is a Claude Code session live on this repo that never armed the bridge?"
 *
 * WHY (owner report 2026-07-31, "I did not open a second session"): presence is the daemon's ONLY
 * signal, and arming it is a sentence the SessionStart hook asks the model to act on - not code.
 * A session that opened and went straight to work left no claim, so the daemon answered in a
 * session of its own while the owner typed in another. Both edited the same file for hours.
 *
 * NOTE WHAT THIS DOES **NOT** DO: it does not yield. Yielding to a session that never armed would
 * hand the message to a process that is not reading the inbox - the owner would get silence, which
 * is strictly worse than two answers and violates the rule at the top of routeEvent. It detects
 * and reports; the fix for the cause is the UserPromptSubmit claim check
 * (`~/.claude/hooks/wa-bridge-claim-check.js`), which makes the session arm itself.
 *
 * Our OWN session writes into that same directory every turn, so `selfSessionId` must be excluded
 * or this returns a false positive on literally every message.
 */
export function detectUnarmedSession({
  projectsDir,
  selfSessionId = '',
  nowMs = Date.now(),
  freshMs = UNARMED_FRESH_MS,
  readdir = fs.readdirSync,
  stat = fs.statSync,
} = {}) {
  try {
    let newest = null;
    for (const f of readdir(projectsDir)) {
      if (!f.endsWith('.jsonl')) continue;
      const id = f.slice(0, -'.jsonl'.length);
      if (selfSessionId && id === selfSessionId) continue;
      const age = nowMs - stat(path.join(projectsDir, f)).mtimeMs;
      if (age < 0 || age >= freshMs) continue;
      if (!newest || age < newest.age) newest = { id, age };
    }
    return newest ? newest.id : null;
  } catch { return null; }
}

export function routeEvent(ev, nowMs = Date.now()) {
  // YIELDING REQUIRES THAT SOMEBODY CAN ACTUALLY READ IT (PR #157 round 3, P1). The session reads
  // the inbox FILE - so if the append failed (unwritable, full), staying silent means the message
  // reaches nobody at all. A failed append means we answer it ourselves.
  const recorded = inbox.appendEvent(INBOX_PATH, ev);
  if (!recorded) {
    return { answer: true, reason: 'inbox append FAILED - no session can read this event' };
  }
  const presence = inbox.readPresence(PRESENCE_PATH);
  const sameProject = inbox.sessionIsLive(presence, CWD, nowMs);
  // ...and the group interlock must not yield to a dead holder either.
  const ownsGroup = !sameProject && inbox.presenceHolderAlive(presence)
    && presenceOwnsEventGroup(presence, ev, nowMs);
  const live = sameProject || ownsGroup;
  return {
    answer: !live,
    reason: sameProject ? 'live session owns this turn'
      : ownsGroup ? 'live session owns this group'
        : 'no live session',
  };
}

const log = (m) => process.stdout.write(`[wa-live-agent] ${new Date().toISOString()} ${m}\n`);

// ── single-instance lock (shared with the v2 monitor so the two can never both answer) ──────
function readLock() {
  try { return JSON.parse(fs.readFileSync(LOCK_PATH, 'utf8')); } catch { return null; }
}
function pidAlive(pid) {
  if (!pid || pid === process.pid) return true;
  try { process.kill(pid, 0); return true; } catch (e) { return e && e.code === 'EPERM'; }
}
function lockHeld(l) {
  return !!(l && Date.now() - new Date(l.heartbeat).getTime() < LOCK_FRESH_MS && pidAlive(l.pid));
}
function writeLock(jid) {
  fs.writeFileSync(LOCK_PATH, JSON.stringify({
    pid: process.pid, mode: 'session', heartbeat: new Date().toISOString(), projectCwd: CWD, jid,
  }));
}

// ── which session to continue ───────────────────────────────────────────────────────────────
// NOTHING. The transcript-picking machinery that used to live here is DELETED, not disabled
// (owner ruling 2026-07-29). Resuming the project's newest transcript gave the daemon a context
// frozen at boot which then aged silently while sounding authoritative. A dead code path that
// still compiles is an invitation to switch it back on; the replacement is in buildTurn, where
// each turn loads what it needs through context-governance + bootstrapper.

// ── outbound ────────────────────────────────────────────────────────────────────────────────
const SLACK_SEND_JS = process.env.WA_AGENT_SLACK_SEND_JS
  || 'C:/dev/example-project/services/slack-cc-bridge/slack-send.js';

/**
 * Reply on the channel the message ARRIVED on. Two input channels now feed this one agent
 * (WhatsApp via the admin log, Slack via the daemon's inbox), so a single hard-coded sender
 * would answer a teammate's Slack message into the owner's WhatsApp group - visible to the wrong person and
 * invisible to the right one.
 *
 * Slack replies go to the PUBLIC channel, never in-thread: an in-thread answer forks the
 * conversation and the operator's follow-up is then missed by conversations.history (the
 * 2026-07-25 incident).
 */
function replyTo(pending, text) {
  if (!text || !text.trim()) return;
  if (pending && pending.source === 'Slack-Bridge' && pending.chatId) {
    const r = spawnSync(process.execPath, [SLACK_SEND_JS, pending.chatId, text],
      { cwd: CWD, encoding: 'utf8', timeout: 60_000 });
    if (r.status !== 0) log(`slack send failed (${r.status}): ${String(r.stderr || '').slice(0, 200)}`);
    return;
  }
  sendWhatsApp(text);
}

function sendWhatsApp(text) {
  if (!text || !text.trim()) return;
  const body = text.startsWith('[CC]') ? text : `[CC] ${text}`;
  // Must exceed send.js's own budget (3 attempts x 30s + 5.5s backoff ~= 95.5s), or the parent
  // kills the child mid-retry and the retry mechanism silently buys nothing on exactly the
  // slow-gateway failures it exists for (PR #157 review, P2).
  const r = spawnSync(process.execPath, [SEND_JS, body],
    { cwd: CWD, encoding: 'utf8', timeout: Number(process.env.WA_AGENT_SEND_TIMEOUT_MS || 120_000) });
  if (r.status !== 0) log(`send failed (${r.status}): ${String(r.stderr || '').slice(0, 200)}`);
}

// ── inbound: tail the gateway log, emit allowlisted events ──────────────────────────────────
function latestLog() {
  try { return lib.inboundLogName(fs.readdirSync(IN_LOG_DIR)); } catch { return null; }
}

/**
 * Boot self-check: which file will we tail, and does it actually contain lines the parser can
 * read? "No events" and "watching the wrong file" are indistinguishable at runtime - this is
 * what makes the difference visible instead of silent. Reads only the tail: these logs are MBs.
 */
export function inboundHealth() {
  const name = latestLog();
  if (!name) return { file: null, ok: false, reason: `no ${lib.INBOUND_LOG.prefix}*.log in ${IN_LOG_DIR}` };
  const file = path.join(IN_LOG_DIR, name);
  try {
    const size = fs.statSync(file).size;
    const from = Math.max(0, size - 512 * 1024);
    const buf = Buffer.alloc(size - from);
    const fd = fs.openSync(file, 'r');
    try { fs.readSync(fd, buf, 0, buf.length, from); } finally { fs.closeSync(fd); }
    const ok = lib.hasInboundFormat(buf.toString('utf8'));
    return { file, ok, reason: ok ? 'ok' : 'no parseable "[message-hook] Received:" line in the tail' };
  } catch (e) {
    return { file, ok: false, reason: e.message };
  }
}
function loadState() {
  try { return JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')); } catch { return {}; }
}
/**
 * MERGE, never replace (PR #157 round 3, P1).
 *
 * Two tailers keep their positions in this one file. The WhatsApp side wrote
 * `saveState({file, offset})` wholesale, which DELETED the `slackOffset` I had just added on any
 * WhatsApp batch - so the Slack checkpoint I reported as fixed survived only until the next
 * WhatsApp message. A shared file with per-writer keys has to be read-modify-write.
 */
function saveState(patch) {
  try {
    const cur = loadState();
    fs.writeFileSync(STATE_PATH, JSON.stringify({ ...cur, ...patch }));
  } catch { /* best effort */ }
}

/**
 * Tail the gateway log from the last processed byte and invoke `onEvent` per allowlisted
 * message. Offset is persisted so a restart resumes where it stopped instead of skipping to
 * EOF — the same guarantee the v2 monitor makes (an owner message was lost that way once).
 */
export function startTailer(sources, selfIds, onEvent, operators) {
  const state = loadState();
  let file = latestLog();
  let offset = state.file === file && Number.isFinite(state.offset) ? state.offset : null;
  let remainder = '';
  let decoder = new StringDecoder('utf8');

  if (file && offset === null) {
    // WE WERE DOWN ACROSS A ROTATION (PR #157 round 2, P1). The gateway opens a new log each day.
    // If the daemon stopped before the roll and started after it, the state names YESTERDAY's
    // file - and jumping to today's EOF silently discarded every message already in it.
    //   known state, different file -> start the new file at 0: none of it has been seen.
    //   no state at all             -> first ever run: start at EOF rather than replay history.
    if (state.file) {
      offset = 0;
      log(`inbound log rolled while we were down (${state.file} -> ${file}) - reading it from the start`);
    } else {
      try { offset = fs.statSync(path.join(IN_LOG_DIR, file)).size; } catch { offset = 0; }
    }
  }

  // Only one tick at a time: the checkpoint now waits for the handoff, so a tick can outlive
  // the poll interval. Overlapping ticks would read the same bytes twice.
  let busy = false;

  const tick = async () => {
    if (busy) return;
    busy = true;
    try {
      const current = latestLog();
      if (current && current !== file) { file = current; offset = 0; remainder = ''; decoder = new StringDecoder('utf8'); }
      if (!file) return;
      const full = path.join(IN_LOG_DIR, file);
      let size;
      try { size = fs.statSync(full).size; } catch { return; }
      if (size < offset) { offset = 0; remainder = ''; decoder = new StringDecoder('utf8'); } // rotated/truncated
      if (size === offset) return;
      let fd;
      let events = [];
      try {
        fd = fs.openSync(full, 'r');
        const buf = Buffer.alloc(size - offset);
        const read = fs.readSync(fd, buf, 0, buf.length, offset);
        offset += read;
        const chunk = remainder + decoder.write(buf.subarray(0, read));
        const parsed = lib.parseChunk(chunk, sources, selfIds, operators);
        events = parsed.events;
        remainder = parsed.remainder;
      } catch (e) {
        log(`tail error: ${e.message}`);
        return;
      } finally {
        if (fd !== undefined) try { fs.closeSync(fd); } catch { /* ignore */ }
      }

      // CHECKPOINT ONLY AFTER THE HANDOFF HAS ACTUALLY COMPLETED (PR #157 round 2, P1).
      // My first attempt merely moved `saveState` below the loop - but `onEvent` returns
      // immediately (it starts an enrich().then() chain), so the checkpoint still landed while
      // the work was in flight. It has to WAIT: an event is only "read" once somebody has taken
      // responsibility for answering it.
      try {
        await Promise.all(events.map((ev) => onEvent(ev)));
      } catch (e) {
        log(`handoff error: ${e && e.message}`);
      }
      saveState({ file, offset });
    } finally {
      busy = false;
    }
  };

  tick();
  return setInterval(tick, POLL_MS);
}

/**
 * Tail the Slack daemon's inbox (JSONL, one event per line) and hand each new event to the same
 * onEvent path the WhatsApp tailer uses.
 *
 * Slack is a SECOND input channel into this one agent rather than a second always-on agent,
 * because two agents on one project would answer over each other - the exact problem the
 * yield-to-session interlock exists to prevent. Starting at EOF is deliberate: on boot, messages
 * already handled by whoever was answering before must not be replayed and answered twice.
 */
export function startSlackTailer(onEvent) {
  // SLACK REMEMBERS WHERE IT STOPPED (PR #157 round 2, P1). WhatsApp has had a persisted offset
  // for months; Slack had none, so every restart jumped to EOF and whatever a teammate sent while the
  // daemon was down was skipped for good - and unlike WhatsApp there is no second reader to
  // catch it. Same state file, its own key.
  const state = loadState();
  let offset = Number.isFinite(state.slackOffset) ? state.slackOffset : null;
  if (offset === null) {
    // No checkpoint at all = first ever run: start at the end rather than replay the archive.
    try { offset = fs.statSync(SLACK_INBOX_PATH).size; } catch { offset = 0; }
  }
  let remainder = '';
  let busy = false;

  const saveSlack = () => {
    const s = loadState();
    saveState({ ...s, slackOffset: offset });
  };

  const tick = async () => {
    if (busy) return;
    busy = true;
    try {
      let size;
      try { size = fs.statSync(SLACK_INBOX_PATH).size; } catch { return; }
      if (size < offset) { offset = 0; remainder = ''; }   // rotated/truncated
      if (size === offset) return;
      let fd;
      const evs = [];
      try {
        fd = fs.openSync(SLACK_INBOX_PATH, 'r');
        const buf = Buffer.alloc(size - offset);
        const read = fs.readSync(fd, buf, 0, buf.length, offset);
        offset += read;
        const text = remainder + buf.subarray(0, read).toString('utf8');
        const nl = text.lastIndexOf('\n');
        if (nl === -1) { remainder = text; return; }
        remainder = text.slice(nl + 1);
        for (const line of text.slice(0, nl).split('\n')) {
          if (!line.trim()) continue;
          // One malformed line must not stop the rest of the batch.
          let ev;
          try { ev = JSON.parse(line); } catch { log(`slack inbox: unparseable line skipped`); continue; }
          evs.push(ev);
        }
      } catch (e) {
        log(`slack tail error: ${e.message}`);
        return;
      } finally {
        if (fd !== undefined) try { fs.closeSync(fd); } catch { /* ignore */ }
      }
      // Same rule as the WhatsApp tailer: the checkpoint waits for the handoff.
      try {
        await Promise.all(evs.map((ev) => onEvent(ev)));
      } catch (e) {
        log(`slack handoff error: ${e && e.message}`);
      }
      saveSlack();
    } finally {
      busy = false;
    }
  };

  tick();
  return setInterval(tick, POLL_MS);
}

// ── the turn queue feeding ONE session ──────────────────────────────────────────────────────
/**
 * An async iterable the SDK pulls from. Pushing a message makes it the next turn on the SAME
 * session; the generator parks on a promise while idle, so an idle agent costs nothing.
 */
function createTurnQueue() {
  const pending = [];
  let wake = null;
  return {
    push(text) {
      pending.push(text);
      if (wake) { const w = wake; wake = null; w(); }
    },
    depth: () => pending.length,
    async *[Symbol.asyncIterator]() {
      for (;;) {
        while (pending.length) {
          const content = pending.shift();
          yield { type: 'user', message: { role: 'user', content }, parent_tool_use_id: null, session_id: '' };
        }
        await new Promise((resolve) => { wake = resolve; });
      }
    },
  };
}

/** The instruction wrapper around each inbound WhatsApp message. */
/**
 * THE CONTEXT IS LOADED, NEVER INHERITED (owner ruling 2026-07-29: *"the current method is not
 * acceptable to me"*).
 *
 * The daemon used to boot by forking the project's newest transcript, so it answered out of
 * whatever a previous session happened to know at the moment the daemon started - a picture
 * that was already frozen, and got staler by the hour while looking authoritative. Now it starts
 * CLEAN and imports context deliberately, exactly as an interactive session does:
 *
 *   - `/context-governance` ONCE per conversation - the project-wide state (manifest, plan,
 *     handoff, open problems).
 *   - `/bootstrapper` on EVERY turn, scoped to THE QUESTION JUST ASKED - selective loading is
 *     per-question by definition, so a per-conversation run would scope every later answer to
 *     the first thing the owner happened to ask.
 *
 * Identical on both channels: WhatsApp and Slack events reach this same function.
 */
export function buildTurn(ev, phase = 'first', unarmedSessionId = '') {
  const channel = ev.source === 'Slack-Bridge' ? 'Slack' : 'WhatsApp';
  const quoted = ev.quotedText ? `\nThe sender is replying to an earlier message: "${ev.quotedText}"` : '';
  const FULL_LOAD = [
    '  1. Invoke the `context-governance` skill (lite) to verify and load the project state.',
    '  2. Invoke the `bootstrapper` skill, scoped to the question below, for the files that',
    '     question actually touches.',
    'Only then answer.',
  ];
  const preamble = {
    // A clean conversation knows nothing. Load everything, once.
    first: [
      'This conversation just started CLEAN - you have no inherited context and must not pretend',
      'otherwise. BEFORE answering:',
      ...FULL_LOAD,
    ],
    // The orchestration tier (manifest, plan, handoff, open problems) is ALREADY in this
    // conversation and has not changed. Re-running the whole skill would re-read ~25k tokens of
    // identical files to answer a different question - the owner called that out, correctly.
    // Only the per-question half is missing.
    warm: [
      'The project state (manifest, plan, handoff, open problems) is ALREADY loaded earlier in',
      'this conversation - do NOT re-run `context-governance` or re-read those files.',
      'BEFORE answering, load only what THIS question adds: the Selective Context Loading step of',
      'the `bootstrapper` skill - match the question against the manifest and open only the files',
      'it names that you have not already read. If it touches nothing new, answer directly.',
    ],
    // Long-lived conversation, and this project genuinely moves underneath one: another session
    // merges a PR, rewrites the handoff, changes prod. After a quiet stretch the loaded picture
    // is a claim about the past, so pay for a full reload rather than answer from it.
    stale: [
      'This conversation has been idle long enough that the project state you loaded may have',
      'moved (another session may have merged, deployed or rewritten the canonical docs).',
      'BEFORE answering, refresh it:',
      ...FULL_LOAD,
    ],
  }[phase] ?? [];
  // A split-brain is invisible from inside this conversation: nothing here can see the other
  // session. If the daemon spotted one, the turn has to carry it, or the agent will happily edit
  // files another live session is editing - which is exactly what happened on 2026-07-30/31.
  const splitBrain = unarmedSessionId ? [
    `WARNING - ANOTHER LIVE SESSION (${unarmedSessionId}) is working in this project right now and`,
    'did NOT arm the bridge, which is why this message came to you instead of to it. Before you',
    'edit any file, check whether it is being edited there (mtime, git status) and prefer additive,',
    'non-conflicting work. Say so in your reply so the owner knows two agents are on the same repo.',
    '',
  ] : [];
  return [
    `${channel} message from ${ev.source} (${ev.sender}): "${ev.text}"${quoted}`,
    '',
    ...splitBrain,
    ...preamble,
    '',
    'Then treat this as a normal user instruction in THIS session and act on it with your full',
    `workflow. Your final response text is delivered to the sender verbatim as a ${channel}`,
    'message, so write it as the reply itself: short, essence-only Hebrew, no code blocks, no',
    'logs, no markdown headings. Do NOT call send.js yourself - the bridge sends your final',
    'text for you, and calling it too would double-send.',
  ].join('\n');
}

const SYSTEM_APPEND = [
  'You are running as an always-on bridge agent for this project, serving BOTH WhatsApp and',
  'Slack. You start with NO inherited context: each conversation begins clean and loads what it',
  'needs through the context-governance and bootstrapper skills, as instructed per turn. Never',
  'answer about project state from memory of a previous session - load it.',
  'Your FINAL text each turn is sent verbatim to the sender on the channel the message arrived',
  'on - keep it short, in Hebrew, essence only, and never paste code or logs into it.',
].join(' ');

// ── main ────────────────────────────────────────────────────────────────────────────────────
async function main() {
  const cfgPath = path.join(HOME, '.claude', '.wa-bridge.json');
  let cfg = {};
  try { cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8')); } catch { /* defaults */ }
  const sources = lib.resolveSources ? lib.resolveSources(cfg, CWD) : lib.loadSources(cfg);
  if (!sources.length) { log('no sources configured - nothing to watch'); process.exit(2); }
  // The config key is `selfMentionIds` - the v2 monitor reads that one. Reading only the
  // never-present `selfIds`/`selfLids` left this EMPTY, which silently disabled the
  // foreign-mention filter: a message @-tagging a teammate woke the agent as if addressed to us
  // (live 2026-07-27). Fail-open on an empty list is correct; reading the wrong key is not.
  const selfIds = cfg.selfMentionIds || cfg.selfIds || cfg.selfLids || [];

  // Per-PERSON authorization (owner ruling 2026-07-27). Deny-by-default: an empty list
  // silences the agent instead of opening it, and says so - the whole point of this ruling
  // is that a permissive default is invisible until someone abuses it.
  const OPERATORS = lib.loadOperators(cfg);
  log(`operators authorized: ${OPERATORS.size}`);
  if (OPERATORS.size === 0) {
    log('NO OPERATORS CONFIGURED - every inbound message will be dropped. Add operators[] to .wa-bridge.json');
  }

  const existing = readLock();
  if (lockHeld(existing) && existing.pid !== process.pid) {
    process.stderr.write(`[wa-live-agent] another bridge holds the lock (pid ${existing.pid})\n`);
    process.exit(3);
  }
  writeLock(sources[0] && sources[0].jid);
  const beat = setInterval(() => writeLock(sources[0] && sources[0].jid), HEARTBEAT_MS);

  log(`cwd=${CWD}`);
  log(`watching ${sources.map((s) => `${s.name}<${s.jid}>`).join(', ')}`);
  // Say WHICH file we tail and whether it looks readable. The 2026-07-27 outage was invisible
  // for 17 minutes precisely because the boot log never named the inbound file.
  const health = inboundHealth();
  log(`inbound ${health.file || '(none)'} - ${health.ok ? 'ok' : 'UNREADABLE: ' + health.reason}`);
  if (!health.ok) {
    log('WARNING: nothing here matches the inbound line format - messages will be silently dropped');
    sendWhatsApp('שים לב: הגשר לא מוצא את קובץ ההודעות הנכון, ייתכן שלא אקבל הודעות. צריך לבדוק אותי.');
  }
  // Clean every boot (owner ruling 2026-07-29): context is LOADED per turn, never inherited.
  log('starting a CLEAN session - context comes from context-governance + bootstrapper');

  // WHEN the project state was last loaded into this conversation - not merely whether.
  //   `first` - nothing loaded yet: load everything.
  //   `warm`  - loaded recently: the orchestration tier is unchanged and already in context, so
  //             only the NEW question needs loading. Re-running the whole skill would re-read
  //             ~25k tokens of identical files to answer a different question (owner, correctly:
  //             "why run the same skill again after it already ran - that is entirely wasteful").
  //   `stale` - loaded long enough ago that another session may have merged, deployed or
  //             rewritten the canonical docs underneath us. That happens in this project, so a
  //             quiet stretch buys a full reload rather than an answer from an old picture.
  let lastLoadMs = 0;
  /**
   * OUR OWN session id, learned from the SDK stream. `detectUnarmedSession` scans the same
   * transcript directory this session writes to, so without this it would report itself as the
   * rogue session on every single message.
   */
  let ownSessionId = '';
  const loadPhase = () => contextPhase(lastLoadMs);
  const queue = createTurnQueue();
  /**
   * Where each queued turn's answer goes, in the SAME order the turns were queued.
   *
   * This used to be a single `pending` slot overwritten on every event (PR #157 review, P1):
   * a second message arriving while the first turn was still running replaced the destination,
   * so the FIRST answer was delivered to the SECOND message's channel and chat id - a Slack
   * question answered into the WhatsApp group, or one operator's answer sent to another.
   * One destination per turn, dequeued when its result arrives.
   */
  const destinations = [];
  const nextDestination = () => (destinations.length ? destinations.shift() : null);
  const handleEvent = (ev) => {
    // Ack FIRST, before any decision or work: silence while thinking is what the owner reported
    // as "the daemon isn't catching my messages" while the log showed the turn already queued.
    // WHATSAPP ONLY. The acker reacts through the WhatsApp gateway keyed on chatId; a Slack
    // channel id means the reaction call fails and its text-ack fallback would post into the
    // WhatsApp group about a message nobody there sent. On Slack the reply itself is the ack.
    if (ev.source !== 'Slack-Bridge') acker.ack(ev);
    // THEN enrich (a voice note has to be transcribed before anyone can act on it) and only then
    // route. Enrichment is async and can take seconds, which is exactly why the ack goes first.
    //
    // RETURN THE CHAIN (PR #157 round 3, P1). The tailer awaits this to decide when the event has
    // been taken responsibility for. Without the `return` it awaited `undefined` - so the
    // "checkpoint waits for the handoff" fix was a no-op TWICE: once when I only moved the
    // saveState line, and again when I awaited a promise nobody handed back.
    return enricher.enrich(ev).catch(() => ev).then(() => {
      const { answer, reason } = routeEvent(ev);
      if (!answer) { log(`-> yielded (${reason}): ${ev.text.slice(0, 60)}`); return; }
      // The shared already-answered guard is checked/recorded at DELIVERY time (just before we send
      // the reply), NOT here at enqueue: recording a claim before the SDK has actually answered
      // would turn any mid-turn SDK failure (auth expiry, network drop) into a permanent drop the
      // guard then suppresses recovery for (verify v3 #2/#4). A quick pre-check here only avoids
      // obviously-redundant work; the authoritative claim happens at reply time.
      if (dedup.seen(DEDUP_FILE, ev)) { log(`-> yielded (already answered by another): ${ev.text.slice(0, 60)}`); return; }
      // We are about to answer. Say out loud whether that is because nobody is there, or because
      // somebody IS there and never announced themselves - the second one used to look identical.
      const unarmed = detectUnarmedSession({
        projectsDir: projectsDirFor(CWD),
        selfSessionId: ownSessionId,
      });
      if (unarmed) {
        log(`WARNING split-brain: session ${unarmed} is live on this repo but never armed the `
          + 'bridge. Answering anyway - yielding to an unarmed session would drop the message.');
      }
      log(`-> turn queued (depth ${queue.depth() + 1}) [${ev.source}]: ${ev.text.slice(0, 70)}`);
      destinations.push(ev);
      queue.push(buildTurn(ev, loadPhase(), unarmed || ''));
      lastLoadMs = Date.now();
    });
  };

  startTailer(sources, selfIds, handleEvent, OPERATORS);
  startSlackTailer(handleEvent);
  log(`slack inbound ${SLACK_INBOX_PATH}`);

  const options = {
    cwd: CWD,
    // NO resume, NO forkSession (owner ruling 2026-07-29). Inheriting the newest transcript gave
    // every answer a context frozen at daemon-boot: it read as authoritative and quietly aged.
    // A clean session that RUNS context-governance + bootstrapper knows what it knows, and knows
    // when it was loaded. See buildTurn.
    permissionMode: process.env.WA_AGENT_PERMISSION_MODE || 'bypassPermissions',
    appendSystemPrompt: SYSTEM_APPEND,
    includePartialMessages: false,
  };

  for (;;) {
    try {
      log('session open - waiting for messages');
      for await (const msg of query({ prompt: queue, options })) {
        // Learn our own session id from the stream (every SDK message carries it) so the
        // split-brain detector can tell OUR transcript apart from a rogue one.
        if (msg.session_id && msg.session_id !== ownSessionId) ownSessionId = msg.session_id;
        if (msg.type === 'assistant') {
          const text = (msg.message?.content || [])
            .filter((b) => b.type === 'text').map((b) => b.text).join('').trim();
          if (text) log(`assistant: ${text.slice(0, 90).replace(/\s+/g, ' ')}`);
        } else if (msg.type === 'result') {
          const reply = typeof msg.result === 'string' ? msg.result.trim() : '';
          const cost = typeof msg.total_cost_usd === 'number' ? ` cost=$${msg.total_cost_usd.toFixed(4)}` : '';
          log(`turn done${cost}${msg.is_error ? ' (error)' : ''}`);
          // Per-turn token breakdown. Without this the only visible number is a dollar figure
          // with no explanation, which is exactly the question the owner asked on 2026-07-26.
          const u = (msg.usage || {});
          log(`usage in=${u.input_tokens ?? '?'} cacheWrite=${u.cache_creation_input_tokens ?? 0} cacheRead=${u.cache_read_input_tokens ?? 0} out=${u.output_tokens ?? '?'}`);
          // FIFO: this result belongs to the OLDEST unanswered turn, not to the newest event.
          const dest = nextDestination();
          if (msg.is_error) {
            // A generic error notice, not a real answer: do NOT claim, so a retry or a live session
            // can still answer it for real.
            replyTo(dest, 'נתקלתי בשגיאה בטיפול בהודעה. אני עדיין כאן - נסה שוב או תגיד לי מה לבדוק.');
          } else if (reply) {
            // Claim at the moment of a real, successful answer. If a live session already delivered
            // this message while our turn ran, the claim returns false and we suppress the double.
            if (dest && !dedup.claim(DEDUP_FILE, dest)) {
              log(`-> not sending (already answered by a live session): ${(dest.text || '').slice(0, 60)}`);
            } else {
              replyTo(dest, reply);
            }
          }
        }
      }
      // The next query() opens a CLEAN conversation with no context at all, so the phase must
      // go back to `first`. Leaving lastLoadMs set told the replacement session it was `warm`
      // and explicitly not to run governance - a fresh context that believes it is loaded
      // (PR #157 review, P1).
      lastLoadMs = 0;
      ownSessionId = '';   // the reopened query is a DIFFERENT session; the old id is not ours
      log('query iterator ended - reopening (context phase reset to first)');
    } catch (e) {
      log(`session error: ${e && e.message}`);
      lastLoadMs = 0;   // same reason: whatever reopens next starts with no context
      if (destinations.length) log(`dropping ${destinations.length} unanswered destination(s) after a session error`);
      destinations.length = 0;
      // Do not spin: a persistent failure (bad auth, missing binary) would otherwise loop hot.
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
}

process.on('SIGINT', () => { try { fs.unlinkSync(LOCK_PATH); } catch { /* ignore */ } process.exit(0); });
process.on('SIGTERM', () => { try { fs.unlinkSync(LOCK_PATH); } catch { /* ignore */ } process.exit(0); });

// Run the agent ONLY when executed directly. Importing this file (tests) must never start a
// live session against the owner's real WhatsApp group.
const invokedDirectly = process.argv[1]
  && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (invokedDirectly) main().catch((e) => { log(`fatal: ${e && e.stack}`); process.exit(1); });
