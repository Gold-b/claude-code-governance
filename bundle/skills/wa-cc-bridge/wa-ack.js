'use strict';
/**
 * wa-ack.js — the immediate "I got it" acknowledgement, shared by the v2 monitor and the
 * always-on agent.
 *
 * WHY IT IS SHARED (owner complaint 2026-07-27 01:14)
 * --------------------------------------------------
 * The v2 monitor acked every inbound message within milliseconds (a 👍 reaction on the message
 * itself, or a delayed text ack when the log line carries no msgId). The always-on agent was
 * written without it, so a message that kicked off real work produced total silence until the
 * whole turn finished - minutes later. From the owner's side that is indistinguishable from the
 * bridge being dead, and he reported it as "the daemon still isn't catching my messages" while
 * the log showed it had queued the turn 90 seconds earlier. An ack is not a nicety here: it is
 * the only signal that separates "working" from "broken".
 *
 * Extracted rather than copied: the inbound-log outage the same night was caused by exactly this
 * kind of duplicated constant drifting between the two consumers.
 */
const fs = require('fs');
const path = require('path');
const http = require('http');
const { execFile } = require('child_process');

function sizeOf(p) { try { return fs.statSync(p).size; } catch { return 0; } }

/**
 * Build an acker.
 *
 * @param {object} o
 * @param {string} o.openclawHome   root that holds gateway-logs/ and openclaw.json
 * @param {string} o.sendScript     path to whatsapp/send.js (text-ack fallback)
 * @param {number} [o.delayMs]      text-ack delay; 0 disables acking entirely
 * @param {string} [o.text]         text-ack body
 * @param {string} [o.emoji]        reaction emoji
 * @param {number} [o.gatewayPort]  gateway HTTP port
 * @param {function} [o.log]        optional logger for failures
 */
function createAcker(o) {
  const OPENCLAW_HOME = o.openclawHome;
  const SEND_SCRIPT = o.sendScript;
  const DELAY_MS = o.delayMs === undefined ? 10000 : o.delayMs;
  const TEXT = o.text || '[CC] קיבלתי, מטפל.';
  const EMOJI = o.emoji || '👍';
  const PORT = o.gatewayPort || 18789;
  const log = o.log || (() => {});
  const GW_LOG_DIR = o.gatewayLogDir || path.join(OPENCLAW_HOME, 'gateway-logs');

  function token() {
    if (process.env.WA_GATEWAY_TOKEN) return process.env.WA_GATEWAY_TOKEN;
    try {
      const oc = JSON.parse(fs.readFileSync(path.join(OPENCLAW_HOME, 'openclaw.json'), 'utf8'));
      return (oc.gateway && oc.gateway.auth && oc.gateway.auth.password) || '';
    } catch { return ''; }
  }

  // The gateway log is the right file HERE: this reads OUTBOUND sends to decide whether a real
  // reply already went out. Inbound lives in admin-logs (lib.INBOUND_LOG) - different purpose.
  function gwLogPath() {
    try {
      const names = fs.readdirSync(GW_LOG_DIR).filter((f) => f.startsWith('gateway-') && f.endsWith('.log')).sort();
      if (names.length) return path.join(GW_LOG_DIR, names[names.length - 1]);
    } catch { /* fall through */ }
    const d = new Date();
    const ymd = String(d.getFullYear()) + String(d.getMonth() + 1).padStart(2, '0') + String(d.getDate()).padStart(2, '0');
    return path.join(GW_LOG_DIR, 'gateway-' + ymd + '.log');
  }

  function sendReaction(ev) {
    const args = { target: ev.chatId, messageId: ev.msgId, emoji: EMOJI, fromMe: false };
    if (ev.senderJid) args.participant = ev.senderJid;
    const data = JSON.stringify({ tool: 'message', action: 'react', args });
    const req = http.request({
      hostname: '127.0.0.1', port: PORT, path: '/tools/invoke', method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + token(),
        'Content-Length': Buffer.byteLength(data),
      },
      timeout: 15000,
    }, (res) => {
      res.resume();
      // Non-2xx: the reaction never reached the chat - fall back to the delayed text ack.
      if (res.statusCode < 200 || res.statusCode >= 300) {
        log(`ack reaction http ${res.statusCode} - falling back to text`);
        scheduleTextAck(ev);
      }
    });
    req.on('error', (e) => { log(`ack reaction failed: ${e.message}`); scheduleTextAck(ev); });
    req.on('timeout', () => { req.destroy(); });
    req.write(data); req.end();
  }

  function scheduleTextAck(ev) {
    const gp = gwLogPath();
    const startSize = sizeOf(gp);
    const timer = setTimeout(() => {
      try {
        const p = gwLogPath();
        const from = p === gp ? startSize : 0;
        const size = sizeOf(p);
        let replied = false;
        if (size > from) {
          const n = Math.min(size - from, 1024 * 1024);
          const buf = Buffer.alloc(n);
          const fd = fs.openSync(p, 'r');
          let read = 0;
          try { read = fs.readSync(fd, buf, 0, n, from); } finally { fs.closeSync(fd); }
          replied = buf.subarray(0, read).toString('utf8').includes('Sending message -> ' + ev.chatId);
        }
        if (!replied) {
          // Route the ack to the exact source chat (env override beats cwd/lock resolution).
          const env = { ...process.env, CC_AGENT_GROUP: String(ev.chatId).replace(/@g\.us$/, '') };
          execFile(process.execPath, [SEND_SCRIPT, TEXT], { env, timeout: 30000, windowsHide: true }, () => {});
        }
      } catch { /* best effort */ }
    }, DELAY_MS);
    if (timer.unref) timer.unref();
    return timer;
  }

  return {
    /** Ack an inbound event. Reaction when the log line gave us a msgId, delayed text otherwise. */
    ack(ev) {
      if (!DELAY_MS) return;
      if (ev.msgId) { sendReaction(ev); return; }
      scheduleTextAck(ev);
    },
    _gwLogPath: gwLogPath,
  };
}

module.exports = { createAcker };
