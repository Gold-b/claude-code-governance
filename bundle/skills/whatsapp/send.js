// send.js — Send WhatsApp message to Ops-Group group
// Usage: node send.js "message text"
// Handles \n as real newlines. Strips markdown/code syntax for clean WhatsApp rendering.
const http = require('http');
const fs = require('fs');
const path = require('path');

// Bridge identifiers + gateway token are LOCAL-ONLY — never hardcoded.
//   group JID: ~/.claude/.wa-bridge.json (ccAgentGroup) or CC_AGENT_GROUP env
//   token:     ~/.openclaw/openclaw.json (gateway.auth.password) or WA_GATEWAY_TOKEN env
const HOME = process.env.USERPROFILE || process.env.HOME || '.';
function loadBridge() {
  try { return JSON.parse(fs.readFileSync(path.join(HOME, '.claude', '.wa-bridge.json'), 'utf8')); }
  catch { return {}; }
}
function getToken() {
  try {
    const ocHome = process.env.OPENCLAW_HOME || path.join(HOME, '.openclaw');
    const oc = JSON.parse(fs.readFileSync(path.join(ocHome, 'openclaw.json'), 'utf8'));
    return (oc.gateway && oc.gateway.auth && oc.gateway.auth.password) || '';
  } catch { return ''; }
}
// Per-project routing (owner directive 2026-07-21): a project dir mapped in
// .wa-bridge.json "projects" sends to its own dedicated group; everything else
// falls back to the global ccAgentGroup. Env CC_AGENT_GROUP still overrides all.
function resolveTargetJid(cfg) {
  if (process.env.CC_AGENT_GROUP) return process.env.CC_AGENT_GROUP + '@g.us';
  const norm = (p) => String(p || '').replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase();
  const cwd = norm(process.cwd());
  const projects = cfg.projects || {};
  for (const key of Object.keys(projects)) {
    const k = norm(key);
    if (k && (cwd === k || cwd.startsWith(k + '/'))) {
      const j = String(projects[key].jid || '');
      return j.includes('@') ? j : j + '@g.us';
    }
  }
  // cwd is not a mapped project: if an ACTIVE bridge session holds the monitor lock,
  // route to ITS group - the caller is almost certainly that session with a shell
  // that wandered into a foreign directory (real incident 2026-07-21: replies from
  // another project directory landed in the general group instead of the project group).
  try {
    const lock = JSON.parse(fs.readFileSync(path.join(HOME, '.claude', 'wa-monitor.lock'), 'utf8'));
    const fresh = lock && lock.heartbeat && (Date.now() - new Date(lock.heartbeat).getTime() < 60000);
    if (fresh && lock.jid) return lock.jid;
  } catch { /* no active bridge session */ }
  return (cfg.ccAgentGroup || '') + '@g.us';
}
const GROUP_JID = resolveTargetJid(loadBridge());
const TOKEN = process.env.WA_GATEWAY_TOKEN || getToken();

if (process.argv.includes('--print-target')) { console.log(GROUP_JID); process.exit(0); }

let msg = process.argv.slice(2).join(' ');
if (!msg) { process.stderr.write('Usage: node send.js "message"\n'); process.exit(1); }
// Convert literal \n to real newlines
msg = msg.replace(/\\n/g, '\n');
// Strip markdown syntax that looks bad in WhatsApp (backticks, **, ##, etc.)
msg = msg.replace(/```[a-z]*\n?/g, '').replace(/`/g, '').replace(/\*\*/g, '').replace(/^#{1,3}\s+/gm, '');
// RTL alignment: prepend U+200F (Right-To-Left Mark) to lines containing Hebrew characters.
// This forces WhatsApp to right-align those lines even if they contain Latin chars or digits.
const HEB_RE = /[\u0590-\u05FF]/;
msg = msg.split('\n').map(line => (HEB_RE.test(line) && !line.startsWith('\u200F')) ? '\u200F' + line : line).join('\n');
const data = JSON.stringify({ tool: 'message', action: 'send', args: { to: GROUP_JID, message: msg } });

/**
 * DELIVERY IS PROVEN BY A messageId, NOT BY A STATUS CODE (owner, 2026-07-29).
 *
 * This script used to print `res.statusCode` and exit 0 no matter what. The gateway returned a
 * transient 400 - the identical payload got a 200 a minute later - and the message was simply
 * lost: the always-on agent shells out to this file and DOES check the exit status, so a silent
 * zero exit turned "the owner never got my answer" into a line that looked like success. Two
 * things follow, and both matter:
 *   1. Success = HTTP 2xx AND `ok !== false` AND a messageId in the body. Anything else fails.
 *   2. A failure is RETRIED, because the observed failure was transient.
 *
 * On a retry a duplicate is possible if the gateway accepted a send whose response we never
 * read. That is the deliberate trade: the owner missing an answer is the failure he reported;
 * seeing one twice is not.
 */
const ATTEMPTS = Number(process.env.WA_SEND_ATTEMPTS || 3);
const BACKOFF_MS = [0, 1500, 4000];

/** The gateway nests the send result twice, and also mirrors it as a JSON string in `content`. */
function extractMessageId(body) {
  let parsed;
  try { parsed = JSON.parse(body); } catch { return null; }
  if (parsed && parsed.ok === false) return null;
  // The structured field is the authority. The same id is also mirrored inside a JSON STRING in
  // `content[].text`, which key order reaches first - so a plain deep walk reads the copy and
  // would keep reporting success from the mirror if the real one ever disagreed.
  const direct = parsed?.result?.details?.result?.messageId;
  if (typeof direct === 'string' && direct.trim()) return direct;
  const seen = new Set();
  const walk = (node) => {
    if (!node || typeof node !== 'object' || seen.has(node)) return null;
    seen.add(node);
    for (const [k, v] of Object.entries(node)) {
      if (k === 'messageId' && typeof v === 'string' && v.trim()) return v;
      if (typeof v === 'string' && v.includes('messageId')) {
        try {
          const inner = walk(JSON.parse(v));   // the `content[].text` mirror
          if (inner) return inner;
        } catch { /* not JSON, keep looking */ }
      }
      if (typeof v === 'object') {
        const found = walk(v);
        if (found) return found;
      }
    }
    return null;
  };
  return walk(parsed);
}

function attempt() {
  return new Promise((resolve) => {
    const req = http.request({
      // Overridable so the delivery contract can be tested against a stand-in gateway: the real
      // one owns 18789 on this machine, and a test that cannot bind a port ends up either
      // proving nothing or messaging the owner for real (both happened while writing this).
      hostname: process.env.WA_GATEWAY_HOST || '127.0.0.1',
      port: Number(process.env.WA_GATEWAY_PORT || 18789),
      path: '/tools/invoke',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer ' + TOKEN,
        'Content-Length': Buffer.byteLength(data),
      },
      timeout: Number(process.env.WA_SEND_TIMEOUT_MS || 30_000),
    }, (res) => {
      let b = '';
      let settled = false;
      const finish = (r) => { if (!settled) { settled = true; resolve(r); } };
      res.on('data', (c) => { b += c; });
      res.on('end', () => {
        const id = extractMessageId(b);
        const ok = res.statusCode >= 200 && res.statusCode < 300 && !!id;
        finish({ ok, status: res.statusCode, id, body: b.slice(0, 400) });
      });
      // A gateway that sends headers and then resets reports the failure HERE, not on the
      // request - so without these the promise never settled, the retry loop stalled behind a
      // send that had already failed, and the message was lost with no error to show for it
      // (PR #157 round 2, P1).
      res.on('aborted', () => finish({ ok: false, status: res.statusCode || 0, id: null, body: 'response aborted' }));
      res.on('error', (e) => finish({ ok: false, status: res.statusCode || 0, id: null, body: `response error: ${e.message}` }));
    });
    req.on('timeout', () => { req.destroy(new Error('gateway timeout')); });
    req.on('error', (e) => resolve({ ok: false, status: 0, id: null, body: e.message }));
    req.write(data);
    req.end();
  });
}

(async () => {
  const failures = [];
  for (let i = 0; i < ATTEMPTS; i++) {
    if (BACKOFF_MS[i]) await new Promise((r) => setTimeout(r, BACKOFF_MS[i]));
    const r = await attempt();
    if (r.ok) {
      console.log(r.id);                       // the PROOF, not a status code
      process.exit(0);
    }
    failures.push(`attempt ${i + 1}: http=${r.status} ${r.id ? '' : 'no messageId '}${r.body}`);
    process.stderr.write(`[wa-send] ${failures[failures.length - 1]}\n`);
  }
  process.stderr.write(`[wa-send] NOT DELIVERED after ${ATTEMPTS} attempts to ${GROUP_JID}\n`);
  process.exit(1);
})();
