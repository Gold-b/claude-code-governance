'use strict';

// wa-monitor-lib.js — pure parsing/filtering for the WA-CC bridge v2 watcher.
// Log line format (verified 2026-07-21):
// [message-hook] Received: channel=whatsapp chatId=<JID> senderId=<+phone> text=<msg>

const KEYWORDS = ['@cc', 'קלוד-קוד', 'קלוד', 'claude-code', 'claude code'];
// msgId/senderJid/quotedId/quoted are OPTIONAL (added 2026-07-22, owner requests):
// new admin lines (recent gateway builds) carry `msgId=<id> senderJid=<jid> quotedId=<id>
// quoted=<urlencoded-body>` before `text=`; '-' means absent. quoted enables
// WhatsApp-Reply context; msgId enables ack-by-reaction.
// Old-format lines (none of these fields) must keep parsing unchanged.
const LINE_RE = /\[message-hook\] Received: channel=whatsapp chatId=(\S+) senderId=(\S+)(?: msgId=(\S+) senderJid=(\S+))?(?: quotedId=(\S+) quoted=(\S+))? text=(.*)$/;

function normalizeJid(v) {
  const s = String(v || '');
  return s.includes('@') ? s : s + '@g.us';
}

function loadSources(cfg) {
  if (Array.isArray(cfg.sources) && cfg.sources.length) {
    return cfg.sources.map((s) => ({
      jid: normalizeJid(s.jid),
      type: s.type || 'group',
      name: s.name || String(s.jid),
      requireKeyword: !!s.requireKeyword,
    }));
  }
  if (cfg.ccAgentGroup) {
    return [{ jid: normalizeJid(cfg.ccAgentGroup), type: 'group', name: 'Ops-Group', requireKeyword: false }];
  }
  return [];
}

function stripBidi(s) {
  return s.replace(/^[‎‏‪-‮﻿\s]+/, '');
}

function isSelf(text) {
  return stripBidi(text).startsWith('[CC]');
}

function hasKeyword(text) {
  const lower = text.toLowerCase();
  return KEYWORDS.some((k) => lower.includes(k));
}

// Owner rule 2026-07-21: a message that @-tags a number/LID that is NOT ours is
// addressed to another group member - do not wake, do not ack, do not reply.
// Applied only when selfIds are configured (fail-open otherwise).
function isForeignMention(msg, selfIds) {
  if (!Array.isArray(selfIds) || !selfIds.length) return false;
  const mentions = msg.match(/@(\d{8,})/g);
  if (!mentions || !mentions.length) return false;
  return !mentions.some((m) => selfIds.includes(m.slice(1)));
}

/**
 * Digits-only identity for a WhatsApp sender. '+972500000000', '972500000000@s.whatsapp.net'
 * and '100000000000001@lid' all reduce to a bare digit string, so the config can be written
 * in whichever form the owner has at hand and still match what the gateway emits.
 */
function normalizeSenderId(v) {
  const s = String(v == null ? '' : v);
  const at = s.indexOf('@');
  return (at === -1 ? s : s.slice(0, at)).replace(/[^0-9]/g, '');
}

/** The operator allowlist as a Set of digit identities (phone AND lid, where known). */
function loadOperators(cfg) {
  const out = new Set();
  const list = cfg && Array.isArray(cfg.operators) ? cfg.operators : [];
  for (const o of list) {
    for (const key of [o && o.phone, o && o.lid, o && o.jid]) {
      const n = normalizeSenderId(key);
      if (n) out.add(n);
    }
  }
  return out;
}

/**
 * Is this sender an operator?
 *
 * Group membership is NOT authorization. Until 2026-07-27 this bridge authorized purely
 * by group jid, so ANYONE added to the group could drive the agent - the owner flagged it
 * the moment he saw it, and he was right: adding a person to a chat is a social act, not a
 * grant of production access.
 *
 * Deny-by-default. An absent or empty allowlist authorizes NOBODY, because the failure we
 * are guarding against is precisely a config that quietly lets everyone through.
 */
function isOperator(senderId, senderJid, operators) {
  if (!operators || operators.size === 0) return false;
  for (const cand of [senderId, senderJid]) {
    const n = normalizeSenderId(cand);
    if (n && operators.has(n)) return true;
  }
  return false;
}

function parseChunk(text, sources, selfIds, operators) {
  const nl = text.lastIndexOf('\n');
  if (nl === -1) return { events: [], remainder: text };
  const complete = text.slice(0, nl);
  const remainder = text.slice(nl + 1);
  const events = [];
  for (const rawLine of complete.split('\n')) {
    const m = rawLine.match(LINE_RE);
    if (!m) continue;
    const [, chatId, senderId, msgId, senderJid, quotedId, quoted, rawText] = m;
    const src = sources.find((s) => s.jid === chatId);
    if (!src) continue;
    // Who sent it, not merely where - see isOperator().
    if (!isOperator(senderId, senderJid, operators)) continue;
    const msg = rawText.trim();
    if (!msg || isSelf(msg)) continue;
    if (msg === '<media:sticker>') continue; // conversational sugar: no instruction, no wake, no ack
    if (isForeignMention(msg, selfIds)) continue; // addressed to another member, not to us
    if (src.requireKeyword && !hasKeyword(msg)) continue;
    const ev = {
      source: src.name,
      type: src.type,
      chatId,
      sender: senderId,
      text: msg,
      ts: new Date().toISOString(),
    };
    if (msgId && msgId !== '-') ev.msgId = msgId;
    if (senderJid && senderJid !== '-') ev.senderJid = senderJid;
    if (quotedId && quotedId !== '-') ev.quotedId = quotedId;
    if (quoted && quoted !== '-') {
      try { ev.quotedText = decodeURIComponent(quoted); } catch { ev.quotedText = quoted; }
    }
    events.push(ev);
  }
  return { events, remainder };
}

function normPath(p) {
  return String(p || '').replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase();
}

// Per-project scoping (owner directive 2026-07-21): a project dir mapped in cfg.projects
// gets its own dedicated group; everything else falls back to the global sources.
function resolveSources(cfg, cwd) {
  const c = normPath(cwd);
  const projects = cfg.projects || {};
  for (const key of Object.keys(projects)) {
    const k = normPath(key);
    if (k && (c === k || c.startsWith(k + '/'))) {
      const p = projects[key];
      return [{
        jid: normalizeJid(p.jid),
        type: p.type || 'group',
        name: p.name || String(p.jid),
        requireKeyword: !!p.requireKeyword,
      }];
    }
  }
  return loadSources(cfg);
}

function ymd(d) {
  return String(d.getFullYear())
    + String(d.getMonth() + 1).padStart(2, '0')
    + String(d.getDate()).padStart(2, '0');
}

// The gateway's daily log rolls on ITS OWN schedule (~03:30 IL rotation), not at
// host-local midnight. Computing today's filename from the host date left the watcher
// tailing a not-yet-existing file every night between local midnight and rotation
// (live incident 2026-07-22 00:5x: owner messages logged but never picked up).
// Pick the lexically-greatest existing name instead: date-stamped names sort
// chronologically, and a late flush to yesterday's file can never flip us back.
function latestLogName(names, prefix) {
  const matching = names.filter((f) => f.startsWith(prefix) && f.endsWith('.log')).sort();
  return matching.length ? matching[matching.length - 1] : null;
}

// THE inbound log location - one constant, both consumers (wa-monitor.js and the always-on
// agent). Incoming WhatsApp messages are written by the admin layer to
// `<OPENCLAW_HOME>/admin-logs/admin-<date>.log` as the `[message-hook] Received:` lines LINE_RE
// matches. They are NOT in `gateway-logs/gateway-<date>.log`: that file carries outbound sends
// and `Skipping group message ... (not in allowlist)` / `Forwarding group message to admin`
// notices with no message text at all (8 days of real gateway logs: 0 `Received:` lines).
// The always-on agent shipped tailing gateway-logs and therefore never saw a single message
// (silent outage 2026-07-27) - hence one shared constant instead of a literal per file.
const INBOUND_LOG = { subdir: 'admin-logs', prefix: 'admin-' };

/** Newest inbound log in a directory listing, or null when none is present. */
function inboundLogName(names) {
  return latestLogName(names, INBOUND_LOG.prefix);
}

/**
 * Does this text contain at least one line the inbound parser can actually read?
 * Used as a boot self-check: a resolved log with zero matches means the location or the
 * gateway's format moved again, which must be loud instead of looking like "no messages yet".
 */
function hasInboundFormat(text) {
  return String(text || '').split('\n').some((l) => LINE_RE.test(l));
}

// Media-extension matchers for inbound media resolution. The gateway downloads
// every inbound media file to MEDIA_DIR under a UUID name with no msgId mapping
// in the log, so the bridge resolves the file the message refers to by "newest
// of this type within a lookback window" (same heuristic that already works for
// audio). Images use a WIDER window than audio: the gateway can persist the
// download several minutes before the message-hook line lands (observed
// 2026-07-23: image on disk ~9 min before its hook line, e.g. during a bridge-off
// backlog), and images are not latency-critical the way a live voice reply is.
const MEDIA_EXT = {
  audio: /\.(ogg|opus|m4a|mp3|wav)$/i,
  image: /\.(jpg|jpeg|png|webp|gif|bmp)$/i,
};

// Pick the newest file matching `rx` whose mtime is >= sinceMs.
// `files` = [{ name, mtimeMs }]. Pure: the caller does the fs.stat reads.
// Returns the winning name, or null when nothing qualifies.
function newestMatching(files, rx, sinceMs) {
  let best = null;
  for (const f of files) {
    if (!rx.test(f.name)) continue;
    if (typeof sinceMs === 'number' && f.mtimeMs < sinceMs) continue;
    if (!best || f.mtimeMs > best.mtimeMs) best = f;
  }
  return best ? best.name : null;
}

/**
 * Pick the session transcript the daemon should RESUME: the chronologically newest one for the
 * project, or null when there is none (caller then starts a fresh session).
 *
 * WHY (owner-diagnosed incident 2026-07-26): the daemon used to persist ONE sessionId and
 * `--resume` it forever. That id was its OWN first headless turn, so the daemon lived in a
 * private context silo that never saw anything the interactive sessions did. Asked "what are the
 * five most urgent open items", it answered from days-old state and listed four things that had
 * since been finished. The owner's words: "instead of attaching to the chronologically LAST session you
 * attached to a random, older one".
 *
 * Resuming by mtime fixes both directions: consecutive daemon turns still chain (the daemon's own
 * transcript is the newest right after it runs), AND a real interactive session that ran more
 * recently is picked up instead of being ignored.
 *
 * SAFETY: this only ever runs when NO live session holds the monitor lock - a fresh session-mode
 * lock makes the daemon defer without spawning at all - so the transcript being resumed belongs to
 * a session that is not currently writing.
 *
 * `files` = [{ name, mtimeMs }] for the project dir (caller does the fs reads, this stays pure).
 * `maxAgeMs` (optional) refuses a transcript older than that, so the daemon starts clean rather
 * than resuming genuinely ancient context.
 */
function latestSessionId(files, nowMs, maxAgeMs) {
  let best = null;
  for (const f of files || []) {
    if (!f || typeof f.name !== 'string' || !f.name.endsWith('.jsonl')) continue;
    if (typeof maxAgeMs === 'number' && typeof nowMs === 'number' && nowMs - f.mtimeMs > maxAgeMs) continue;
    if (!best || f.mtimeMs > best.mtimeMs) best = f;
  }
  return best ? best.name.replace(/\.jsonl$/, '') : null;
}

module.exports = { KEYWORDS, normalizeJid, loadSources, resolveSources, normPath, stripBidi, isSelf, isForeignMention, hasKeyword, parseChunk, ymd, latestLogName, INBOUND_LOG, inboundLogName, hasInboundFormat, MEDIA_EXT, newestMatching, latestSessionId, normalizeSenderId, loadOperators, isOperator };
