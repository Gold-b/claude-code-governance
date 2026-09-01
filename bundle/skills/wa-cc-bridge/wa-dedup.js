'use strict';
/**
 * wa-dedup.js — a shared "already answered" guard, the CORRECTNESS FOUNDATION of the bridge.
 *
 * WHY (owner reports through 2026-08-02; two adversarial reviews found 27 offset-choreography
 * defects between them). Coordinating "what has been answered" across multiple answerers - a live
 * session's monitor, a newer session that takes over, the same session after a VS reload, and the
 * always-on daemon - purely through file byte-offsets is a swamp: every takeover, restart and
 * handoff is a fresh double-answer or drop. This guard sidesteps all of it. Before ANY answerer
 * delivers a message it claim()s the message's identity here; a second answerer that sees the same
 * identity within the TTL skips it. Double-answer becomes impossible BY CONSTRUCTION, and the
 * offset logic drops to a mere efficiency concern - a re-read is de-duplicated, never re-delivered.
 *
 * Append-only JSONL: concurrent writers never corrupt each other (appendFileSync is atomic per
 * short line on the platforms we run), and there is no read-modify-write lost update. Pruned
 * opportunistically once it grows past a bound.
 *
 * FAIL-OPEN, ALWAYS: every error path returns "deliver it". A duplicate is recoverable; a message
 * the guard wrongly swallowed is the exact silent-drop failure the owner reported. The presence
 * interlock stays the PRIMARY one-answerer mechanism; this closes the residual takeover / restart /
 * daemon-handoff races the interlock cannot see.
 */
const fs = require('fs');
const path = require('path');

// Must exceed BOTH the daemon's longest enrichment (~180s) AND the session checkpoint-resume window
// (DIRECT_RESUME_MAX_AGE_MS, 15min): a session that resumes a checkpoint re-reads every message
// answered since it, and the guard must still remember those or the re-read double-delivers. So the
// TTL is set above the resume window with margin (verify v3 #3). wa-session-inbox.js additionally
// CLAMPS its resume window to this TTL, so the invariant holds even if either is overridden.
const DEFAULT_TTL_MS = 20 * 60 * 1000;
const PRUNE_BYTES = 256 * 1024;
const SEP = '  ';   // field separator unlikely to appear in message content

function dedupPath(home) { return path.join(home, '.claude', 'wa-answered.jsonl'); }

/**
 * Stable identity for a message. Prefer the platform msgId (WhatsApp admin-log msgId / Slack ts);
 * fall back to a compact non-crypto hash of chatId+sender+text so old-log-format events (no msgId)
 * still de-duplicate. The SAME message re-read from the admin log after a takeover, or seen by a
 * different answerer, resolves to the SAME key - which is the whole point.
 */
function eventKey(ev) {
  if (!ev || typeof ev !== 'object') return null;
  if (ev.msgId) return 'id:' + String(ev.msgId);
  const chatId = ev.chatId || '';
  const sender = ev.sender || '';
  const text = ev.text || '';
  if (chatId === '' && sender === '' && text === '') return null;   // nothing to key on
  const basis = chatId + SEP + sender + SEP + text;
  let h = 5381;
  for (let i = 0; i < basis.length; i++) { h = ((h << 5) + h + basis.charCodeAt(i)) | 0; }
  return 'h:' + (h >>> 0).toString(36) + ':' + basis.length;
}

/** Map of key -> timestamp for entries still inside the TTL. Never throws. */
function readRecent(file, nowMs, ttlMs) {
  const seen = new Map();
  let text = '';
  try { text = fs.readFileSync(file, 'utf8'); } catch { return seen; }
  for (const line of text.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    let r; try { r = JSON.parse(t); } catch { continue; }
    if (!r || !r.k || !Number.isFinite(r.t)) continue;
    if (nowMs - r.t >= ttlMs) continue;
    seen.set(r.k, r.t);
  }
  return seen;
}

function maybePrune(file, nowMs, ttlMs) {
  try {
    if (fs.statSync(file).size < PRUNE_BYTES) return;
    const seen = readRecent(file, nowMs, ttlMs);
    const tmp = file + '.tmp.' + process.pid;
    fs.writeFileSync(tmp, Array.from(seen.entries()).map(([k, t]) => JSON.stringify({ k, t })).join('\n') + '\n');
    fs.renameSync(tmp, file);
  } catch { /* best effort */ }
}

/** Has this message already been claimed within the TTL? Read-only. Fail-open (false = not seen). */
function seen(file, ev, nowMs = Date.now(), ttlMs = DEFAULT_TTL_MS) {
  const k = eventKey(ev);
  if (!k) return false;
  try { return readRecent(file, nowMs, ttlMs).has(k); } catch { return false; }
}

/** Record that this message has been delivered. Best-effort, never throws. */
function record(file, ev, nowMs = Date.now(), ttlMs = DEFAULT_TTL_MS) {
  const k = eventKey(ev);
  if (!k) return;
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.appendFileSync(file, JSON.stringify({ k, t: nowMs }) + '\n');
    maybePrune(file, nowMs, ttlMs);
  } catch { /* best effort */ }
}

/**
 * Claim a message for delivery in ONE step: TRUE if this caller should deliver it (first to see it)
 * and records the claim; FALSE if already claimed. Fail-open. Use this where the check and the
 * commit are the same instant (the daemon at reply time); use seen()+record() separately when
 * delivery can fail between them (the session records only after a successful stdout write).
 */
function claim(file, ev, nowMs = Date.now(), ttlMs = DEFAULT_TTL_MS) {
  const k = eventKey(ev);
  if (!k) return true;   // unkeyable -> deliver (a drop is worse than a rare dup)
  if (seen(file, ev, nowMs, ttlMs)) return false;
  record(file, ev, nowMs, ttlMs);
  return true;
}

module.exports = { dedupPath, eventKey, claim, seen, record, readRecent, DEFAULT_TTL_MS };
