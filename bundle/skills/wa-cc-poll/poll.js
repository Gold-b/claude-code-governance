#!/usr/bin/env node
'use strict';

/**
 * poll.js — WhatsApp-to-Claude-Code bridge poller.
 *
 * Monitors the Ops-Group WhatsApp GROUP for messages addressed to Claude Code.
 * Tracks byte offsets to avoid reprocessing. Outputs JSON on stdout (exit 0)
 * or exits silently (exit 1) when nothing new.
 *
 * CC keywords: @cc, קלוד, קלוד-קוד, claude-code, claude code
 * Source: the Ops-Group group ONLY (JID from ~/.claude/.wa-bridge.json; not DMs)
 * Ignores: messages with [CC] prefix (our own responses)
 */

const fs = require('fs');
const path = require('path');

const OPENCLAW_HOME = process.env.OPENCLAW_HOME
  || path.join(process.env.USERPROFILE || process.env.HOME || '.', '.openclaw');

const STATE_FILE = path.join(
  process.env.USERPROFILE || process.env.HOME,
  '.claude', 'wa-cc-poll-state.json'
);

// Ops-Group group JID — from env or the local-only bridge config (gitignored; never committed).
function loadBridgeConfig() {
  try {
    const home = process.env.USERPROFILE || process.env.HOME || '.';
    return JSON.parse(fs.readFileSync(path.join(home, '.claude', '.wa-bridge.json'), 'utf8'));
  } catch { return {}; }
}
const CC_AGENT_GROUP = process.env.CC_AGENT_GROUP || loadBridgeConfig().ccAgentGroup || '';
const CC_KEYWORDS = ['@cc', 'קלוד', 'קלוד-קוד', 'claude-code', 'claude code'];

const SHARED_SESSION_FILE = process.env.WA_SHARED_SESSION_FILE || path.join(
  process.env.USERPROFILE || process.env.HOME || '.', 'Long-Term Memory', 'ClaudeCodeSharedSession.md'
);

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return { logOffset: 0, logDate: '', sharedSessionSize: 0 };
  }
}

function saveState(state) {
  state.lastPoll = new Date().toISOString();
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2), 'utf8');
}

function todayLogPath() {
  const d = new Date();
  const ymd = String(d.getFullYear())
    + String(d.getMonth() + 1).padStart(2, '0')
    + String(d.getDate()).padStart(2, '0');
  return {
    filePath: path.join(OPENCLAW_HOME, 'admin-logs', `admin-${ymd}.log`),
    date: ymd
  };
}

function hasKeyword(text) {
  const lower = text.toLowerCase();
  return CC_KEYWORDS.some(kw => lower.includes(kw));
}

function stripKeyword(text) {
  let cleaned = text;
  for (const kw of ['@cc', 'קלוד-קוד', 'קלוד', 'claude-code', 'claude code']) {
    const re = new RegExp(kw.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
    cleaned = cleaned.replace(re, '');
  }
  return cleaned.replace(/^[\s,:\-]+/, '').trim();
}

function pollAdminLog(state) {
  const { filePath, date } = todayLogPath();
  let offset = (state.logDate === date) ? state.logOffset : 0;

  let size;
  try { size = fs.statSync(filePath).size; } catch { return { entries: [], newOffset: 0, date }; }
  if (size <= offset) return { entries: [], newOffset: offset, date };

  const bytesToRead = Math.min(size - offset, 65536);
  const buf = Buffer.alloc(bytesToRead);
  const fd = fs.openSync(filePath, 'r');
  fs.readSync(fd, buf, 0, bytesToRead, offset);
  fs.closeSync(fd);

  const text = buf.toString('utf8');
  const entries = [];

  for (const line of text.split('\n')) {
    if (!line.includes('message-hook') || !line.includes(CC_AGENT_GROUP)) continue;
    const m = line.match(/text=(.+)$/);
    if (!m) continue;
    const msgText = m[1].trim();
    if (msgText.startsWith('[CC]') || msgText.startsWith('\u200F[CC]')) continue;
    if (hasKeyword(msgText)) {
      entries.push({
        source: 'cc-agent-group',
        raw: msgText,
        instruction: stripKeyword(msgText),
        timestamp: new Date().toISOString()
      });
    }
  }

  return { entries, newOffset: size, date };
}

function pollSharedSession(state) {
  let size;
  try { size = fs.statSync(SHARED_SESSION_FILE).size; } catch { return { entries: [], newSize: state.sharedSessionSize || 0 }; }
  if (size <= (state.sharedSessionSize || 0) || size === 0) {
    return { entries: [], newSize: size };
  }

  const content = fs.readFileSync(SHARED_SESSION_FILE, 'utf8');
  const newContent = content.slice(state.sharedSessionSize || 0);
  const entries = [];

  for (const line of newContent.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (trimmed.startsWith('#') || trimmed.startsWith('>') || trimmed.startsWith('---')) continue;
    if (trimmed.startsWith('[CC]') || trimmed.startsWith('**CC**')) continue;
    if (trimmed.startsWith('### CC') || trimmed.startsWith('### USER')) continue;
    if (hasKeyword(trimmed)) {
      entries.push({
        source: 'shared-file',
        raw: trimmed,
        instruction: stripKeyword(trimmed),
        timestamp: new Date().toISOString()
      });
    }
  }

  return { entries, newSize: size };
}

// --- Main ---
const state = loadState();
const logResult = pollAdminLog(state);
const fileResult = pollSharedSession(state);

saveState({
  logOffset: logResult.newOffset,
  logDate: logResult.date,
  sharedSessionSize: fileResult.newSize
});

const all = [...logResult.entries, ...fileResult.entries];
if (all.length === 0) process.exit(1);

process.stdout.write(JSON.stringify(all, null, 2) + '\n');
process.exit(0);
