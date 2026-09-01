'use strict';
/**
 * wa-enrich.test.js — media enrichment, shared by the monitor and the always-on agent.
 *
 * The bug these exist for: the agent shipped WITHOUT enrichment, so a voice note reached the
 * owner's session as the literal string `<media:audio>` and had to be transcribed by hand. The
 * text-passthrough and audio cases below are what make that regression visible.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { createEnricher } = require('./wa-enrich.js');

function makeHome(files = []) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-enrich-'));
  const media = path.join(home, 'media', 'inbound');
  fs.mkdirSync(media, { recursive: true });
  for (const name of files) fs.writeFileSync(path.join(media, name), 'x');
  return { home, media };
}

/** A stub "python" that just echoes a fixed transcript, so no real model is needed. */
function stubTranscriber(text) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-enrich-py-'));
  const script = path.join(dir, 'echo.js');
  fs.writeFileSync(script, `process.stdout.write(${JSON.stringify(text)});`);
  return { python: process.execPath, script };
}

test('plain text passes through untouched', async () => {
  const { home } = makeHome();
  const e = createEnricher({ openclawHome: home });
  const ev = { text: 'שלום' };
  assert.strictEqual((await e.enrich(ev)).text, 'שלום');
});

test('a voice note is transcribed and marked [voice]', async () => {
  const { home } = makeHome(['note.ogg']);
  const { python, script } = stubTranscriber('תן לי סטטוס');
  const e = createEnricher({ openclawHome: home, python, script });
  const ev = await e.enrich({ text: '<media:audio>' });
  assert.strictEqual(ev.text, '[voice] תן לי סטטוס');
  assert.strictEqual(ev.media, 'note.ogg');
});

test('a voice note with no resolvable file says so instead of leaving <media:audio>', async () => {
  const { home } = makeHome();
  const e = createEnricher({ openclawHome: home });
  const ev = await e.enrich({ text: '<media:audio>' });
  assert.match(ev.text, /transcription unavailable/);
  assert.ok(!ev.text.includes('<media:audio>'), 'the raw placeholder must never survive');
});

test('a failing transcriber degrades to the unavailable notice, never throws', async () => {
  const { home } = makeHome(['note.ogg']);
  const e = createEnricher({ openclawHome: home, python: process.execPath, script: '/nope/missing.js' });
  const ev = await e.enrich({ text: '<media:audio>' });
  assert.match(ev.text, /transcription unavailable/);
});

test('an image resolves to an absolute path the reader can open', async () => {
  const { home, media } = makeHome(['shot.png']);
  const e = createEnricher({ openclawHome: home });
  const ev = await e.enrich({ text: '<media:image>' });
  assert.strictEqual(ev.mediaPath, path.join(media, 'shot.png'));
  assert.match(ev.text, /Read tool/);
});

test('an image outside the lookback window is reported, not silently attached', async () => {
  const { home, media } = makeHome(['old.png']);
  const old = Date.now() - 60 * 60 * 1000;
  fs.utimesSync(path.join(media, 'old.png'), old / 1000, old / 1000);
  const e = createEnricher({ openclawHome: home, imageLookbackMs: 60_000 });
  const ev = await e.enrich({ text: '<media:image>' });
  assert.match(ev.text, /not found/);
  assert.strictEqual(ev.mediaPath, undefined);
});

test('a missing media dir never throws', async () => {
  const e = createEnricher({ openclawHome: path.join(os.tmpdir(), 'wa-enrich-nope-' + process.pid) });
  const ev = await e.enrich({ text: '<media:audio>' });
  assert.match(ev.text, /transcription unavailable/);
});
