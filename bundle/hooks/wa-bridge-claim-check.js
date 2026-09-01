#!/usr/bin/env node
'use strict';
/**
 * wa-bridge-claim-check.js — UserPromptSubmit guard: "is this session actually holding the bridge?"
 *
 * WHY THIS EXISTS (owner report 2026-07-31: "I did not open a second session")
 * ---------------------------------------------------------------------------
 * Arming the bridge was never code. `wa-cc-autostart.sh` PRINTS a sentence on SessionStart asking
 * the model to run the `Monitor` tool. Nothing enforced it, nothing verified it afterwards, and
 * nothing warned when it was missing. On 2026-07-30 a session opened, went straight to work and
 * never armed - so `~/.claude/wa-session-presence.json` did not exist, the always-on daemon read
 * "no file" as "no session", and answered in a session of its own. Two agents then edited the same
 * file for hours while the owner believed he was talking to the one on his screen.
 *
 * A VS Code window reload produces the same state by a different route: the monitor is a child of
 * the extension host, a reload kills it, and NO hook fires on a reload - so the claim silently
 * goes stale mid-session. SessionStart cannot cover that; only a per-prompt check can.
 *
 * WHY A CHECK AND NOT "JUST SPAWN IT FROM THE HOOK":
 *   The monitor has to be armed through the `Monitor` TOOL, because that is what streams its JSON
 *   lines back into the conversation as turns. A hook-spawned background process would hold the
 *   presence claim while delivering messages to nobody - a silent bridge that looks healthy, which
 *   is worse than the failure it replaces. So this hook re-emits the instruction; it never spawns.
 *
 * PREDICATE SHARING IS THE POINT: liveness is decided by `wa-inbox.js`'s own `sessionIsLive`, the
 * exact function the daemon calls. If the two ever disagreed, the hook would cheerfully report a
 * healthy bridge while the daemon answered in parallel - which is the bug itself.
 *
 * FAIL-SILENT BY CONSTRUCTION: every error path exits 0 with no output. This runs on EVERY user
 * prompt in EVERY project; it must never be able to break, slow or pollute a turn.
 */
const fs = require('fs');
const path = require('path');

const HOME = process.env.USERPROFILE || process.env.HOME || '.';
const CLAUDE_DIR = path.join(HOME, '.claude');
const SKILL_DIR = path.join(CLAUDE_DIR, 'skills', 'wa-cc-bridge');
/** Do not re-nag more often than this per project: a burst of prompts should cost one notice. */
const NAG_EVERY_MS = Number(process.env.WA_CLAIM_NAG_MS || 120_000);
const STAMP_PATH = process.env.WA_CLAIM_STAMP || path.join(CLAUDE_DIR, 'wa-bridge-claim-nag.json');

function readStdinJson() {
  try { return JSON.parse(fs.readFileSync(0, 'utf8')); } catch { return {}; }
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

/**
 * Only nag inside projects the bridge actually serves. Without this gate every session in every
 * unrelated project would be told to arm a bridge that has no group to talk to.
 *
 * Deliberately NOT `lib.resolveSources`: that one falls back to the config's global default group
 * when the cwd matches nothing, which is right for the daemon (it always needs somewhere to reply)
 * and wrong here - it made the first version of this hook answer "yes, served" for every directory
 * on the machine. Caught by the unrelated-project test, which is why that test exists.
 */
function bridgeServes(lib, cwd) {
  try {
    const cfg = readJson(path.join(CLAUDE_DIR, '.wa-bridge.json')) || {};
    const here = lib.normPath(cwd);
    return Object.keys(cfg.projects || {}).some((key) => {
      const k = lib.normPath(key);
      return k && (here === k || here.startsWith(k + '/'));
    });
  } catch { return false; }
}

function throttled(cwd, nowMs) {
  const stamps = readJson(STAMP_PATH) || {};
  const key = String(cwd).replace(/[\\/]+/g, '/').toLowerCase();
  const last = Number(stamps[key] || 0);
  if (nowMs - last < NAG_EVERY_MS) return true;
  stamps[key] = nowMs;
  try { fs.writeFileSync(STAMP_PATH, JSON.stringify(stamps)); } catch { /* nagging twice beats not nagging */ }
  return false;
}

function armInstruction(cwd) {
  const posix = String(cwd).replace(/\\/g, '/');
  return [
    '[WA-CC Bridge] THE BRIDGE IS UNCLAIMED BY THIS SESSION. No fresh presence claim exists for',
    `${posix}, so the always-on daemon believes no session is open and is answering the owner's`,
    'WhatsApp/Slack messages in a session of its own - while you work here. Two agents on one repo.',
    'FIRST ACTION THIS TURN, before answering: arm the bridge as a persistent Monitor from the',
    `project directory: cd "${posix}" && WA_SESSION_CWD='${posix}' node`,
    '"$USERPROFILE/.claude/skills/wa-cc-bridge/wa-session-inbox.js"  (description: \'WhatsApp bridge:',
    'allowlisted incoming messages\', persistent: true). Do it silently - no need to mention it -',
    'then continue with the user\'s request. If you are CLOSING the session, skip this.',
  ].join(' ');
}

function main() {
  if (fs.existsSync(path.join(CLAUDE_DIR, 'wa-bridge-off'))) return;

  const payload = readStdinJson();
  const cwd = payload.cwd || process.cwd();

  let inbox; let lib;
  try {
    inbox = require(path.join(SKILL_DIR, 'wa-inbox.js'));
    lib = require(path.join(SKILL_DIR, 'wa-monitor-lib.js'));
  } catch { return; }   // bridge not installed here - nothing to guard

  if (!bridgeServes(lib, cwd)) return;

  // PER-PROJECT claim (2026-08-17): ask for THIS project's file. Against the old machine-wide path
  // this check reported "armed" whenever any project held the bridge, so the one project that was
  // actually deaf never got its arm instruction.
  const presence = inbox.readPresence(inbox.presencePath(HOME, cwd));
  if (inbox.sessionIsLive(presence, cwd, Date.now())) return;   // claimed by us, the common case

  if (throttled(cwd, Date.now())) return;

  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'UserPromptSubmit',
      additionalContext: armInstruction(cwd),
    },
  }));
}

try { main(); } catch { /* fail silent, always */ }
process.exit(0);
