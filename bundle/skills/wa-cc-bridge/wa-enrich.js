'use strict';
/**
 * wa-enrich.js — turn a raw media event into something readable, shared by the v2 monitor and
 * the always-on agent.
 *
 * WHY IT IS SHARED (owner caught this live, 2026-07-27): the v2 monitor transcribed voice notes
 * before handing them on. The always-on agent, written the night before, carried over the log
 * tailing but NOT the enrichment, so the owner's voice messages arrived as the literal string
 * `<media:audio>` with no words in them. He noticed because he asked "was the message I just
 * sent transcribed, did it go through the pipe" - and it had not; both of his voice notes had
 * been transcribed by hand. Copying the logic into the agent would have set up the same drift
 * that caused the inbound-log outage the same night, so it lives in one place instead.
 *
 * Media resolution is a heuristic by necessity: the gateway downloads inbound media to MEDIA_DIR
 * under a UUID name with no msgId mapping in the log, so the file a message refers to is "newest
 * of this type within a lookback window".
 */
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const lib = require('./wa-monitor-lib.js');

/** Audio: tight window - a voice reply is latency-critical and arrives with its message. */
const AUDIO_LOOKBACK_MS = 3 * 60 * 1000;
/** Image: wider - the gateway can persist the download minutes before the hook line lands. */
const DEFAULT_IMAGE_LOOKBACK_MS = 20 * 60 * 1000;

function createEnricher(o = {}) {
  const HOME = o.home || process.env.USERPROFILE || process.env.HOME || '.';
  const OPENCLAW_HOME = o.openclawHome || path.join(HOME, '.openclaw');
  const MEDIA_DIR = o.mediaDir || process.env.WA_MEDIA_DIR || path.join(OPENCLAW_HOME, 'media', 'inbound');
  const PYTHON = o.python || process.env.WA_TRANSCRIBE_PYTHON || 'C:\\tmp\\cbx-venv\\Scripts\\python.exe';
  const SCRIPT = o.script || process.env.WA_TRANSCRIBE_SCRIPT || path.join(__dirname, 'transcribe.py');
  const IMAGE_LOOKBACK_MS = Number(o.imageLookbackMs || process.env.WA_IMAGE_LOOKBACK_MS || DEFAULT_IMAGE_LOOKBACK_MS);
  const log = o.log || (() => {});

  function newestMediaFile(kind, lookbackMs) {
    try {
      const rx = lib.MEDIA_EXT[kind];
      const files = fs.readdirSync(MEDIA_DIR)
        .map((name) => {
          try { return { name, mtimeMs: fs.statSync(path.join(MEDIA_DIR, name)).mtimeMs }; }
          catch { return null; }
        })
        .filter(Boolean);
      const name = lib.newestMatching(files, rx, Date.now() - lookbackMs);
      return name ? path.join(MEDIA_DIR, name) : null;
    } catch { return null; }
  }

  function transcribe(file) {
    return new Promise((resolve) => {
      execFile(PYTHON, [SCRIPT, file], { timeout: 180000, maxBuffer: 1024 * 1024, windowsHide: true },
        (err, stdout) => {
          if (err) { log(`transcribe failed: ${err.message}`); return resolve(null); }
          const t = String(stdout).trim();
          resolve(t || null);
        });
    });
  }

  return {
    /** Resolve media on the event IN PLACE and return it. Never throws. */
    async enrich(ev) {
      if (/^<media:audio/i.test(ev.text)) {
        const f = newestMediaFile('audio', AUDIO_LOOKBACK_MS);
        if (f) {
          const t = await transcribe(f);
          if (t) { ev.text = `[voice] ${t}`; ev.media = path.basename(f); return ev; }
        }
        ev.text = '[voice message - transcription unavailable]';
        return ev;
      }
      if (/^<media:image/i.test(ev.text)) {
        const f = newestMediaFile('image', IMAGE_LOOKBACK_MS);
        if (f) {
          // Absolute path so the reading session can just open it; we do NOT caption it here -
          // the model that consumes the event sees the actual pixels.
          ev.mediaPath = f;
          ev.media = path.basename(f);
          ev.text = `[image] The sender shared an image. Open it with the Read tool at: ${f}`;
        } else {
          ev.text = '[image received - the file was not found in the inbound media dir within the '
            + 'lookback window; ask the sender to resend]';
        }
        return ev;
      }
      return ev;
    },
  };
}

module.exports = { createEnricher, AUDIO_LOOKBACK_MS, DEFAULT_IMAGE_LOOKBACK_MS };
