'use strict';
/**
 * wa-inbox.js — hand-off between the always-on agent and a live interactive session.
 *
 * THE PROBLEM (owner, 2026-07-27: "the new daemon method hurts our work")
 * ----------------------------------------------------------------------
 * The always-on agent is a SECOND agent with its own context. When the owner is already talking
 * to an interactive session and sends a WhatsApp message, both wake up: two agents, two contexts,
 * two sets of edits on one repo. It happened live - the owner sent "implement the #145 opener"
 * while a session was mid-work on the same repo, and the agent started implementing it in
 * parallel. Reverting to the per-message daemon does not fix this; that daemon spawned a separate
 * agent per message too.
 *
 * THE MODEL: one reader, one answerer.
 *   - The always-on agent stays the SINGLE reader of the admin log (no lock races, no double
 *     consumption) and appends every parsed event to the inbox file.
 *   - An interactive session announces itself by running `wa-session-inbox.js` as a persistent
 *     Monitor. That process IS the presence: it refreshes the presence file while it lives and
 *     removes it on exit, so presence can never outlive the session that owns it.
 *   - When presence is fresh the agent ACKS but does not answer - the message becomes a turn in
 *     the session the owner is already talking to, which is the one-agent-one-context behaviour
 *     the bridge was supposed to have. When it is stale (no session, or a dead monitor) the agent
 *     answers itself, exactly as before.
 *
 * Presence is heartbeat-based rather than a plain "file exists" flag: a session that crashes
 * cannot leave the bridge permanently mute.
 */
const fs = require('fs');
const path = require('path');

const PRESENCE_FRESH_MS = 60_000;
/**
 * How fresh the daemon's `wa-monitor.lock` heartbeat must be to count it as still feeding the
 * inbox. Matches the daemon's own `LOCK_FRESH_MS` (180s): the daemon spends up to 120s inside a
 * synchronous send during which it cannot heartbeat, and declaring it dead then would flip the
 * session into direct mode and double-read alongside a live daemon. The pid-liveness check below
 * is the fast path for a genuinely dead daemon; this window only guards the wedged-but-alive case.
 */
const DAEMON_LOCK_FRESH_MS = 180_000;

function inboxPath(home) { return path.join(home, '.claude', 'wa-inbox.jsonl'); }

/** Filename prefix for a per-project claim. The trailing `-` is what separates these from the
 *  retired machine-wide `wa-session-presence.json`, so an old file is never picked up as a claim. */
const PRESENCE_PREFIX = 'wa-session-presence-';

/**
 * One project -> one claim filename.
 *
 * Built on `normalizeProjectPath` ON PURPOSE, so the name a session claims under and the path
 * `sessionIsLive()` compares can never drift apart. Two rules for "same project" is how the
 * 2026-07-29 double-answer happened; there is only one rule here.
 */
function presenceSlug(cwd) {
  // The slug is validated AFTER substitution, not before. `'   '` and `'///'` normalise to a
  // truthy string but reduce to nothing, and every one of them would then share a single
  // `wa-session-presence-.json` - silently re-creating the shared claim this file exists to end.
  const slug = normalizeProjectPath(cwd).replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '');
  if (!slug) throw new Error(`presenceSlug: a real project path is required (per-project presence), got ${JSON.stringify(cwd)}`);
  return slug;
}

/**
 * Where THIS project's claim lives.
 *
 * PER PROJECT, NOT PER MACHINE (owner ruling 2026-08-17). One global file meant a session on
 * project A pushed project B's monitor into STANDBY, froze its offsets and left B's WhatsApp group
 * unanswered while every process looked healthy. "Exactly one answerer" is an invariant per
 * project - which is all newest-wins ever meant.
 *
 * `cwd` is REQUIRED and throws when absent. A silent fallback to the old global path is exactly
 * how one forgotten call site would restore the machine-wide claim, and it would do it quietly.
 */
function presencePath(home, cwd) {
  return path.join(home, '.claude', `${PRESENCE_PREFIX}${presenceSlug(cwd)}.json`);
}

/**
 * Every project claim on this machine, for health checks and diagnostics.
 *
 * `wa-bridge-claim-check.js` used to read ONE known path; with per-project files a single path
 * would report "no session armed" while two are live. Unreadable/!JSON files are skipped rather
 * than thrown on - a health check must never be the thing that dies.
 */
function listPresence(home) {
  const dir = path.join(home, '.claude');
  let names;
  try { names = fs.readdirSync(dir); } catch { return []; }
  const out = [];
  for (const name of names) {
    if (!name.startsWith(PRESENCE_PREFIX) || !name.endsWith('.json')) continue;
    const file = path.join(dir, name);
    const presence = readPresence(file);
    if (presence) out.push({ file, presence });
  }
  return out;
}

/**
 * Is the always-on daemon alive and feeding `wa-inbox.jsonl` right now?
 *
 * THE F1/F2 SWITCH (owner report 2026-07-31 -> fix 2026-08-02). The 2026-07-27 "one reader" split
 * made `wa-session-inbox.js` read only the inbox the daemon writes, so killing the daemon starved
 * BOTH channels while every health signal looked green. This predicate is how the session decides
 * which source to read: TRUE -> relay (the daemon merges WhatsApp+Slack into the inbox, read that);
 * FALSE -> direct (no live writer, so read the admin log and slack inbox ourselves).
 *
 * FAILS TO FALSE (direct) on every uncertainty: the failure we are ending is a starved reader, so
 * "I cannot prove a live daemon is writing" must send the session to read the raw sources, never
 * leave it waiting on a file nobody fills. TRUE is returned only for a fresh lock whose holder is a
 * live, foreign process. `kill(pid, 0)` throwing ESRCH is the one definite "gone"; EPERM/unknown
 * count as alive (mistaking a live daemon for dead would double-read, the worse error).
 */
function daemonIsFeeding(lock, myPid = process.pid, nowMs = Date.now(), kill = process.kill.bind(process)) {
  if (!lock || lock.pid === undefined || lock.pid === null) return false;
  if (lock.pid === myPid) return false;                       // our own leftover, not a daemon
  const beat = new Date(lock.heartbeat).getTime();
  if (!Number.isFinite(beat) || nowMs - beat >= DAEMON_LOCK_FRESH_MS) return false;
  try { kill(lock.pid, 0); return true; } catch (e) { return !(e && e.code === 'ESRCH'); }
}

/** Append one event as a JSON line. Best effort: the agent must never die on inbox I/O. */
function appendEvent(file, ev) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.appendFileSync(file, JSON.stringify(ev) + '\n');
    return true;
  } catch { return false; }
}

/**
 * Release every claim on this machine whose holder process is gone. Returns the files cleared.
 *
 * Called by the session-close hook. It sweeps ALL projects because bash cannot compute the slug
 * rule without duplicating it - and two spellings of "same project" is the defect class that
 * caused the 2026-07-29 double answer. The liveness test is `presenceHolderAlive`, which counts
 * UNKNOWN as alive: deleting a live session's claim hands that owner's conversation back to the
 * daemon while he is still talking to it, which is worse than a claim that lingers 60s.
 */
function releaseDeadClaims(home) {
  const cleared = [];
  for (const { file, presence } of listPresence(home)) {
    if (presenceHolderAlive(presence)) continue;
    try { fs.unlinkSync(file); cleared.push(file); } catch { /* another close won the race */ }
  }
  return cleared;
}

function readPresence(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

/** `pid`/`nowMs` are injectable so the claim rules can be tested with more than one "process". */
function writePresence(file, cwd, pid = process.pid, nowMs = Date.now()) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify({ pid, cwd, heartbeat: new Date(nowMs).toISOString() }));
    return true;
  } catch { return false; }
}

/**
 * Claim the bridge for THIS process, or stand by.
 *
 * WHY (owner, 2026-07-29, with a screenshot of two replies to one message): every armed monitor
 * tails the same inbox from EOF, so N live sessions answered N times. The daemon was innocent -
 * its log shows it yielding on all three test messages - and the second answer came from a
 * second VS Code session the owner had opened minutes earlier. Presence being a single file was
 * never enough on its own: it says "somebody is live", not "this one is the answerer".
 *
 * THE POLICY IS NEWEST-WINS (owner, 2026-07-29): *"the new session takes the bridge from the
 * current one and leads it."* When he opens a session, that is where he is working, so that is
 * where his messages belong. So:
 *
 *   - `takeover: true`  - used ONCE, when a monitor starts. It seizes the claim unconditionally.
 *   - `takeover: false` - every heartbeat after that. It refreshes OUR claim, and reports
 *     `standby` the moment someone newer holds a fresh one.
 *
 * The asymmetry is the whole design. If heartbeats could also seize, two live monitors would
 * steal the bridge from each other every beat and the owner would get answers from whichever one
 * happened to hold it that second.
 *
 * A stale claim (>PRESENCE_FRESH_MS, i.e. the newer session crashed or closed) is taken over by
 * a standing-by monitor, so the bridge comes back on its own rather than staying mute.
 *
 * @returns {'owner'|'standby'}
 */
function claimPresence(file, cwd, nowMs = Date.now(), pid = process.pid, opts = {}) {
  if (!opts.takeover) {
    const cur = readPresence(file);
    if (cur && cur.pid !== pid && cur.heartbeat) {
      const beat = new Date(cur.heartbeat).getTime();
      if (Number.isFinite(beat) && nowMs - beat < PRESENCE_FRESH_MS) return 'standby';
    }
  }
  return writePresence(file, cwd, pid, nowMs) ? 'owner' : 'standby';
}

/**
 * Release the claim - but ONLY when it is ours.
 *
 * A blanket unlink let a second session's close delete the first session's live claim, handing
 * the conversation back to the daemon while the owner was still talking to that session.
 */
function clearPresence(file, pid = process.pid) {
  try {
    const cur = readPresence(file);
    if (cur && cur.pid !== undefined && cur.pid !== pid) return false;
    fs.unlinkSync(file);
    return true;
  } catch { return false; }
}

/**
 * One project path, one spelling.
 *
 * THE 2026-07-29 DOUBLE-ANSWER BUG lived in the missing `\` -> `/` rule. The skill's own
 * arming line passes `WA_SESSION_CWD='c:/dev/example-project'` (forward slashes) while the agent's
 * launcher does `cd /d "C:\dev\example-project"` (backslashes). The old comparison lowercased and
 * stripped trailing slashes but kept the separators, so the two spellings of the SAME directory
 * never matched: every live session looked like "some other project" and the agent answered
 * alongside it. The owner got two replies to one message, from two agents, on the same repo -
 * which is precisely what the presence interlock exists to prevent.
 */
function normalizeProjectPath(p) {
  return String(p || '').replace(/[\\/]+/g, '/').replace(/\/+$/, '').toLowerCase();
}

/**
 * Is an interactive session live for `cwd` right now?
 *
 * Pure decision so it can be tested without clocks or processes. A presence record counts only
 * when its heartbeat is recent AND it belongs to the same project - a session open on another
 * project must not silence this project's bridge.
 */
/**
 * Is the process holding the claim actually running?
 *
 * A crashed session leaves a claim that stays "fresh" for a full minute. The daemon yielded to
 * it, the dead session obviously answered nothing, and the message fell between the two
 * (PR #157 round 2, P1). The pid is right there in the record, so ask.
 *
 * UNKNOWN COUNTS AS ALIVE. Only a definite ESRCH means gone: mistaking a live session for a
 * dead one brings back the double answer, which is the worse of the two failures.
 */
function presenceHolderAlive(presence, kill = process.kill.bind(process)) {
  if (!presence || presence.pid === undefined || presence.pid === null) return true;
  try { kill(presence.pid, 0); return true; } catch (e) { return !(e && e.code === 'ESRCH'); }
}

function sessionIsLive(presence, cwd, nowMs, freshMs = PRESENCE_FRESH_MS) {
  if (!presence || !presence.heartbeat) return false;
  const beat = new Date(presence.heartbeat).getTime();
  if (!Number.isFinite(beat) || nowMs - beat >= freshMs) return false;
  if (!presence.cwd || !cwd) return false;
  if (!presenceHolderAlive(presence)) return false;
  return normalizeProjectPath(presence.cwd) === normalizeProjectPath(cwd);
}

module.exports = {
  PRESENCE_FRESH_MS,
  DAEMON_LOCK_FRESH_MS,
  inboxPath,
  PRESENCE_PREFIX,
  presenceSlug,
  presencePath,
  listPresence,
  releaseDeadClaims,
  appendEvent,
  readPresence,
  writePresence,
  clearPresence,
  sessionIsLive,
  normalizeProjectPath,
  claimPresence,
  presenceHolderAlive,
  daemonIsFeeding,
};
