/**
 * remind-teammate.js — one-shot private WhatsApp reminder to a named teammate.
 *
 * EXAMPLE / TEMPLATE. The original was a single authorised DM about a review backlog; the
 * real recipient, wording and business detail were removed for the public bundle. Kept
 * because check-no-pii.sh cites it as the model for the pattern below: a script that needs a
 * personal identifier reads it from the ENVIRONMENT and refuses loudly when it is unset.
 *
 * RENAMED 2026-09-01: the file, the env var and the log prefix all carried a real teammate's
 * first name. A filename is published exactly as widely as a line of code, so the name was the
 * leak and the mechanism was fine; only the name changed. See the refusal message below for the
 * migration note anyone with the old variable exported will see.
 *
 * A one-shot DM must be individually authorised by the owner — the bridge's normal path is
 * group-only (send.js). Sends directly rather than through send.js for that reason.
 * Fails loudly into the log rather than silently: a reminder nobody sent is worse than an error.
 */
const fs = require('fs');
const http = require('http');
const path = require('path');

const HOME = process.env.USERPROFILE || process.env.HOME || '.';
// NO PERSONAL NUMBER IN CODE (2026-08-18). This file ships in a PUBLIC repository, so the
// recipient must come from the environment. Refusing loudly beats a placeholder default:
// a fake number would either fail silently or, worse, reach whoever really owns it.
const TEAMMATE_JID = process.env.TEAMMATE_WA_JID;
if (!TEAMMATE_JID) {
  console.error(
    'remind-teammate: set TEAMMATE_WA_JID (e.g. 9725XXXXXXXX@s.whatsapp.net) - no recipient is hardcoded.\n' +
    'RENAMED 2026-09-01 (BEHAVIOUR CHANGE): this file and this variable were previously named after a\n' +
    'real person, and that older <FIRSTNAME>_WA_JID variable is NO LONGER READ. If you still export it,\n' +
    'rename it to TEAMMATE_WA_JID - otherwise this reminder simply has no recipient. The old name is\n' +
    'deliberately not printed here: it is the exact identifier the rename removed from a public repo.'
  );
  process.exit(2);
}

function token() {
  try {
    const ocHome = process.env.OPENCLAW_HOME || path.join(HOME, '.openclaw');
    const oc = JSON.parse(fs.readFileSync(path.join(ocHome, 'openclaw.json'), 'utf8'));
    return (oc.gateway && oc.gateway.auth && oc.gateway.auth.password) || '';
  } catch { return ''; }
}

const LINES = [
  '[CC] בוקר טוב. תזכורת קצרה לפי בקשת הבעלים.',
  '',
  '<פירוט התזכורת כאן — קצר, מהות בלבד, בלי קוד ובלי לוגים>.',
];

const HEB = /[֐-׿]/;
const msg = LINES.map((l) => (HEB.test(l) && !l.startsWith('‏') ? '‏' + l : l)).join('\n');

const TOKEN = token();
if (!TOKEN) { console.error(`[remind-teammate] ${new Date().toISOString()} NO GATEWAY TOKEN - reminder NOT sent`); process.exit(2); }

const data = JSON.stringify({ tool: 'message', action: 'send', args: { to: TEAMMATE_JID, message: msg } });
const req = http.request(
  {
    hostname: '127.0.0.1', port: 18789, path: '/tools/invoke', method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}`, 'Content-Length': Buffer.byteLength(data) },
  },
  (res) => {
    let b = '';
    res.on('data', (c) => { b += c; });
    res.on('end', () => console.log(`[remind-teammate] ${new Date().toISOString()} status=${res.statusCode} ${b.slice(0, 200)}`));
  },
);
req.on('error', (e) => console.error(`[remind-teammate] ${new Date().toISOString()} SEND FAILED: ${e.message}`));
req.write(data);
req.end();
