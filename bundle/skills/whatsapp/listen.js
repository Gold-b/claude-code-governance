// listen.js — Wait for user reply in Ops-Group WhatsApp group
// Usage: node listen.js [timeoutMs]  (default 90000)
// Exit 0 = reply on stdout, Exit 2 = timeout
const fs = require('fs');
const path = require('path');
function loadBridge(){ try { return JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE || process.env.HOME || '.', '.claude', '.wa-bridge.json'), 'utf8')); } catch { return {}; } }
const G = process.env.CC_AGENT_GROUP || loadBridge().ccAgentGroup || '';
const MAX = parseInt(process.argv[2] || '90000', 10);
const t0 = Date.now();
const lf = path.join(process.env.USERPROFILE || process.env.HOME, '.openclaw', 'admin-logs',
  'admin-' + new Date().toISOString().slice(0, 10).replace(/-/g, '') + '.log');
let pos = 0;
try { pos = fs.statSync(lf).size; } catch (_) {}
function poll() {
  if (Date.now() - t0 > MAX) { process.stderr.write('TIMEOUT\n'); process.exit(2); }
  try {
    const s = fs.statSync(lf).size;
    if (s > pos) {
      const n = Math.min(s - pos, 32768);
      const b = Buffer.alloc(n);
      const fd = fs.openSync(lf, 'r');
      fs.readSync(fd, b, 0, n, s - n);
      fs.closeSync(fd);
      pos = s;
      const d = b.toString('utf8');
      if (d.includes(G)) {
        for (const ln of d.split('\n').reverse()) {
          if (ln.includes('message-hook') && ln.includes(G) && !ln.includes('[CC]')) {
            const m = ln.match(/text=(.+)$/);
            if (m) { process.stdout.write(m[1].trim() + '\n'); process.exit(0); }
          }
        }
      }
    }
  } catch (_) {}
  setTimeout(poll, 5000);
}
poll();
