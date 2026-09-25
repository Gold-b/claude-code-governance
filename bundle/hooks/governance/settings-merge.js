#!/usr/bin/env node
// settings-merge.js — governance-only merge of a hooks template into ~/.claude/settings.json.
//
// invoked-by:gov-update.sh (the auto-updater's apply step); install.sh calls it too, from 2.0.0.
//
// WHY (2.0.0). install.sh used to REPLACE `settings.hooks` wholesale with the template. That
// silently dropped every hook the user had registered themselves, on every manual install — and an
// auto-updater doing the same at every release would make it a fleet-wide, unattended data loss.
// Two paths with two merge behaviours would also drift, so both use this one file.
//
// OWNERSHIP. A hook entry is governance-owned when its `command`
//   (a) appears verbatim in the NEW template, or
//   (b) appears verbatim in the template LAST APPLIED on this machine (--installed) — this is how a
//       governance entry that a release removed or renamed, and the `echo '[MEMORY MAINTENANCE] …'`
//       Stop entry, are recognised and not left behind or duplicated, or
//   (c) contains `.claude/hooks/governance/` or `.claude/hooks/check-full-finish.sh`.
// Owned entries are removed and the new template's entries are put back; EVERY other entry, matcher
// group and top-level key (permissions, env, model, effortLevel, plugins…) is preserved.
//
// PLACEMENT. The i-th template group of an event goes into the i-th remaining existing group with
// the same matcher (so a user's own entries sitting beside governance entries keep their group);
// otherwise it is appended. Groups left empty are dropped. The result is a fixed point: merging the
// same template twice changes nothing, and an unchanged result is NOT rewritten (mtime kept).
//
// Usage:
//   node settings-merge.js --template <settings-hooks.json> --settings <settings.json>
//        [--installed <settings-hooks.installed.json>] [--set-effort-if-absent] [--check]
// Prints one line: `unchanged` | `merged` | (with --check) `would-merge`. Exit 0 on success.
// Exit 1 on any error — including a settings.json that exists but does not parse: starting from
// `{}` there would erase the user's whole configuration, which is what the old inline merge did.
'use strict';
const fs = require('fs');
const path = require('path');

function die(msg) {
  process.stderr.write('settings-merge: ' + msg + '\n');
  process.exit(1);
}

const args = process.argv.slice(2);
const opt = { template: '', settings: '', installed: '', effort: false, check: false };
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--template') opt.template = args[++i] || '';
  else if (a === '--settings') opt.settings = args[++i] || '';
  else if (a === '--installed') opt.installed = args[++i] || '';
  else if (a === '--set-effort-if-absent') opt.effort = true;
  else if (a === '--check') opt.check = true;
  else die('unknown argument: ' + a);
}
if (!opt.template || !opt.settings) die('--template and --settings are required');

// Only a file that DOES NOT EXIST may be treated as empty. Any other read error — a Windows
// EBUSY/EPERM/EACCES while an editor, antivirus or Claude Code itself holds settings.json — must
// stop the merge: reading it as `{}` would write back a file holding only the hooks, erasing
// permissions, env, model and the user's own hooks (MEASURED in review with an injected EBUSY).
function readJson(file, label, required) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (e) {
    if (required || !e || e.code !== 'ENOENT') die(label + ' not readable (' + ((e && e.code) || 'error') + '): ' + file);
    return null;
  }
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  try {
    return { json: JSON.parse(text), text };
  } catch (e) {
    die(label + ' is not valid JSON (' + e.message + '): ' + file);
  }
  return null;
}

const tpl = readJson(opt.template, 'template', true).json;
if (!tpl || typeof tpl.hooks !== 'object' || tpl.hooks === null) die('template has no "hooks" object');
const prev = opt.installed ? readJson(opt.installed, 'installed template', false) : null;
const cur = readJson(opt.settings, 'settings.json', false);
const settings = cur ? cur.json : {};
if (typeof settings !== 'object' || settings === null || Array.isArray(settings)) die('settings.json is not a JSON object');

function commandsOf(hooksObj) {
  const out = new Set();
  if (!hooksObj || typeof hooksObj !== 'object') return out;
  for (const groups of Object.values(hooksObj)) {
    if (!Array.isArray(groups)) continue;
    for (const g of groups) {
      for (const h of (g && Array.isArray(g.hooks) ? g.hooks : [])) {
        if (h && typeof h.command === 'string') out.add(h.command);
      }
    }
  }
  return out;
}
const owned = new Set([...commandsOf(tpl.hooks), ...commandsOf(prev && prev.json ? prev.json.hooks : null)]);
function isOwned(h) {
  if (!h || typeof h.command !== 'string') return false;
  if (owned.has(h.command)) return true;
  const c = h.command.replace(/\\/g, '/');
  return c.includes('.claude/hooks/governance/') || c.includes('.claude/hooks/check-full-finish.sh');
}
const sameMatcher = (a, b) => (a.matcher === undefined ? '' : a.matcher) === (b.matcher === undefined ? '' : b.matcher);
const clone = (x) => JSON.parse(JSON.stringify(x));

const curHooks = (settings.hooks && typeof settings.hooks === 'object') ? settings.hooks : {};
const events = [...Object.keys(curHooks)];
for (const e of Object.keys(tpl.hooks)) if (!events.includes(e)) events.push(e);

const merged = {};
for (const ev of events) {
  const groups = (Array.isArray(curHooks[ev]) ? curHooks[ev] : []).map((g) => {
    const copy = clone(g);
    copy.hooks = (Array.isArray(g.hooks) ? g.hooks : []).filter((h) => !isOwned(h));
    return copy;
  });
  const used = new Set();
  for (const tg of (Array.isArray(tpl.hooks[ev]) ? tpl.hooks[ev] : [])) {
    const idx = groups.findIndex((g, i) => !used.has(i) && sameMatcher(g, tg));
    if (idx >= 0) {
      groups[idx].hooks = groups[idx].hooks.concat(clone(tg.hooks || []));
      used.add(idx);
    } else {
      groups.push(clone(tg));
      used.add(groups.length - 1);
    }
  }
  const kept = groups.filter((g) => Array.isArray(g.hooks) && g.hooks.length > 0);
  if (kept.length) merged[ev] = kept;
}

const result = {};
let placed = false;
for (const k of Object.keys(settings)) {
  if (k === 'hooks') { result.hooks = merged; placed = true; } else result[k] = settings[k];
}
if (!placed) result.hooks = merged;
if (opt.effort && !result.effortLevel) result.effortLevel = tpl.effortLevel || 'max';

const out = JSON.stringify(result, null, 2) + '\n';
if (cur && cur.text.replace(/\r\n/g, '\n') === out) {
  process.stdout.write('unchanged\n');
  process.exit(0);
}
if (opt.check) {
  process.stdout.write('would-merge\n');
  process.exit(0);
}
const dir = path.dirname(path.resolve(opt.settings));
try { fs.mkdirSync(dir, { recursive: true }); } catch (e) { /* the write below reports it */ }
const tmp = path.join(dir, '.settings.json.gov-merge.' + process.pid);
try {
  fs.writeFileSync(tmp, out);
  // Keep the file's permission bits (a 600 settings.json must not come back 644).
  try { if (cur) fs.chmodSync(tmp, fs.statSync(path.resolve(opt.settings)).mode & 0o7777); } catch (e) { /* best effort */ }
  fs.renameSync(tmp, path.resolve(opt.settings));
} catch (e) {
  try { fs.unlinkSync(tmp); } catch (e2) { /* nothing to clean */ }
  die('could not write settings.json: ' + e.message);
}
process.stdout.write('merged\n');
