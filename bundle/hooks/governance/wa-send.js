#!/usr/bin/env node
'use strict';

/**
 * wa-send.js — WhatsApp sender for governance hooks.
 *
 * STANDARD (memory-locked 2026-04-17): every WhatsApp message we generate uses
 *   node.js + UTF-8 + RTL mark + per-line right-alignment for Hebrew.
 *
 * Why node.js (not bash/curl):
 *   curl-via-Git-Bash mangles UTF-8 multi-byte sequences (head -c byte cutoff,
 *   tr/sed byte semantics). node http + Buffer 'utf8' is byte-exact.
 *
 * Why RTL mark (U+200F):
 *   WhatsApp renders Hebrew lines LTR by default unless prefixed with U+200F.
 *   Without it, English/punctuation inside a Hebrew line jumbles visually.
 *
 * Inputs:
 *   process.env.WA_MESSAGE   — message body (UTF-8). Newlines OK.
 *   process.env.WA_PHONE     — override phone (optional).
 *   process.env.WA_TIMEOUT_MS — override timeout (optional, default 5000).
 *   process.env.OPENCLAW_HOME — override openclaw home (optional).
 *
 * Behavior: fail-soft. Any error → exit 0 (never breaks the hook caller).
 */

const http = require('http');
const fs   = require('fs');
const path = require('path');

const OPENCLAW_HOME = process.env.OPENCLAW_HOME
  || path.join(process.env.USERPROFILE || process.env.HOME || '.', '.openclaw');

const TIMEOUT_MS = parseInt(process.env.WA_TIMEOUT_MS || '5000', 10);

function getToken() {
  try {
    const oc = JSON.parse(fs.readFileSync(path.join(OPENCLAW_HOME, 'openclaw.json'), 'utf8'));
    return oc.gateway?.auth?.password || '';
  } catch { return ''; }
}

function getPhone() {
  if (process.env.WA_PHONE) {
    return process.env.WA_PHONE.replace(/\D/g, '');
  }
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(OPENCLAW_HOME, 'admin', 'config.json'), 'utf8'));
    const list = cfg.personalNumbers || [];
    const first = list[0];
    const raw = first?.phone || first?.number || '';
    if (raw) return String(raw).replace(/\D/g, '');
  } catch { /* fall through */ }
  // Last resort: local-only bridge config (gitignored; never committed to the public repo).
  try {
    const home = process.env.USERPROFILE || process.env.HOME || '.';
    const b = JSON.parse(fs.readFileSync(path.join(home, '.claude', '.wa-bridge.json'), 'utf8'));
    if (b.phone) return String(b.phone).replace(/\D/g, '');
  } catch { /* fall through */ }
  return '';
}

let message = process.env.WA_MESSAGE || '';
if (!message) { process.exit(0); }

// WhatsApp hard cap is 4096 chars. Leave headroom for RTL marks (adds ~1 byte
// per Hebrew line) and our own "[GOVERNANCE]" prefix. Truncate at 3500 with a
// visible marker so the recipient knows content was cut.
const WA_MAX_CHARS = 3500;
if (message.length > WA_MAX_CHARS) {
  message = message.slice(0, WA_MAX_CHARS) + '\n…[נקצר]';
}

const token = getToken();
if (!token) { process.exit(0); }

const phone = getPhone();
if (!phone) { process.exit(0); }

// Apply RTL mark (U+200F) to every line that contains any Hebrew character.
// This forces WhatsApp to render the line right-to-left and aligns it to the
// right edge of the bubble — matching native Hebrew presentation.
const formatted = message.split('\n').map(line =>
  /[\u0590-\u05FF]/.test(line) ? '\u200F' + line : line
).join('\n');

const payload = Buffer.from(JSON.stringify({
  tool: 'message',
  action: 'send',
  args: { to: `${phone}@s.whatsapp.net`, message: formatted }
}), 'utf8');

const req = http.request({
  hostname: '127.0.0.1',
  port: 18789,
  path: '/tools/invoke',
  method: 'POST',
  headers: {
    'Content-Type': 'application/json; charset=utf-8',
    'Authorization': `Bearer ${token}`,
    'Content-Length': payload.length,
  },
  timeout: TIMEOUT_MS,
}, (res) => {
  res.on('data', () => {});
  res.on('end', () => process.exit(0));
});
req.on('error', () => process.exit(0));
req.on('timeout', () => { req.destroy(); process.exit(0); });
req.write(payload);
req.end();
