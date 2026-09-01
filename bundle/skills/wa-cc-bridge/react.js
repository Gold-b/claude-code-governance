#!/usr/bin/env node
'use strict';
/**
 * react.js — put an "eyes" reaction on an inbound message the instant it is received, so the owner
 * sees the agent got it and is on it (owner rule 2026-08-02). Handles BOTH channels from one event:
 *   - WhatsApp: gateway `message/react` (target=chatId, messageId=msgId), same endpoint send.js uses.
 *   - Slack:    reactions.add(channel=chatId, timestamp=msgId, name=eyes).
 *
 * Fire-and-forget by design: a reaction is a courtesy signal, never worth blocking or crashing the
 * reader over. Every failure path is silent. Invoked as: node react.js '<event-json>'.
 */
const fs = require('fs');
const path = require('path');
const http = require('http');

const HOME = process.env.USERPROFILE || process.env.HOME || '.';
const EMOJI = process.env.WA_REACT_EMOJI || '👀';
const SLACK_EMOJI_NAME = process.env.SLACK_REACT_NAME || 'eyes';

const LOG = process.env.WA_REACT_LOG || path.join(HOME, '.claude', 'logs', 'wa-react.log');
function rlog(m) { try { fs.mkdirSync(path.dirname(LOG), { recursive: true }); fs.appendFileSync(LOG, new Date().toISOString() + ' ' + m + '\n'); } catch { /* ignore */ } }

let ev = null;
try { ev = JSON.parse(process.argv[2] || ''); } catch { rlog('bad-json argv'); process.exit(0); }
if (!ev || !ev.chatId || !ev.msgId) { rlog('missing chatId/msgId: ' + JSON.stringify(ev).slice(0, 120)); process.exit(0); }
rlog(`react ${ev.source || '?'} chat=${ev.chatId} msg=${ev.msgId}`);

function reactWhatsApp() {
  let token = '';
  try {
    const oc = JSON.parse(fs.readFileSync(path.join(HOME, '.openclaw', 'openclaw.json'), 'utf8'));
    token = (oc.gateway && oc.gateway.auth && oc.gateway.auth.password) || '';
  } catch { /* no token -> the request just 401s, silently */ }
  token = process.env.WA_GATEWAY_TOKEN || token;
  // In a GROUP the reaction key MUST carry the participant (who sent the message being reacted to),
  // or WhatsApp silently drops it while the gateway still returns ok:true. wa-ack.js gets this right;
  // this file did not, which is why the API said "added" but no eyes appeared (owner caught it).
  const args = { target: ev.chatId, messageId: ev.msgId, emoji: EMOJI, fromMe: false };
  if (ev.senderJid) args.participant = ev.senderJid;
  const data = JSON.stringify({ tool: 'message', action: 'react', args });
  const req = http.request({
    hostname: process.env.WA_GATEWAY_HOST || '127.0.0.1',
    port: Number(process.env.WA_GATEWAY_PORT || 18789),
    path: '/tools/invoke', method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token, 'Content-Length': Buffer.byteLength(data) },
    timeout: 10_000,
  }, (res) => { let b = ''; res.on('data', (c) => { b += c; }); res.on('end', () => { rlog(`wa http ${res.statusCode}: ${b.slice(0, 120)}`); process.exit(0); }); });
  req.on('error', (e) => { rlog('wa error: ' + e.message); process.exit(0); });
  req.on('timeout', () => { req.destroy(); rlog('wa timeout'); process.exit(0); });
  req.end(data);
}

async function reactSlack() {
  let token = process.env.SLACK_BOT_TOKEN || '';
  if (!token) {
    for (const p of [
      process.env.SLACK_BRIDGE_CONFIG || '',
      path.join(HOME, '.claude', 'slack-bridge.config.json'),
    ]) {
      try { token = JSON.parse(fs.readFileSync(p, 'utf8')).botToken || ''; if (token) break; } catch { /* next */ }
    }
  }
  if (!token) process.exit(0);
  try {
    await fetch('https://slack.com/api/reactions.add', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=utf-8', Authorization: 'Bearer ' + token },
      body: JSON.stringify({ channel: ev.chatId, timestamp: ev.msgId, name: SLACK_EMOJI_NAME }),
    });
  } catch { /* silent */ }
  process.exit(0);
}

if (ev.source === 'Slack-Bridge' || /^C[A-Z0-9]/.test(String(ev.chatId))) reactSlack();
else reactWhatsApp();
setTimeout(() => process.exit(0), 12_000).unref();
