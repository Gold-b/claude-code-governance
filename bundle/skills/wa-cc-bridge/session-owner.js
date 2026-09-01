'use strict';
/**
 * session-owner.js — "is the Claude Code session that armed me still alive?"
 *
 * WHY THIS EXISTS (2026-07-29):
 *   The session monitor is a PERSISTENT background process. Two failure modes have both
 *   actually happened:
 *
 *   1. The close hook was registered on `Stop`, which fires at the end of EVERY assistant
 *      turn - so the bridge died seconds after the session opened and the owner's messages
 *      never reached it. (Fixed by moving the hook to SessionEnd only.)
 *   2. Before that, nothing stopped the monitor at all: when a session ended, the monitor
 *      kept heartbeating presence and a DEAD session went on claiming every incoming
 *      message while the always-on agent politely yielded to nobody.
 *
 *   SessionEnd fixes (2) for a normal close. It cannot fix a hard kill - a closed terminal,
 *   a crashed host, Task Manager - because no hook runs then. This module is that backstop:
 *   the monitor learns WHICH process is its session, and exits when that process is gone.
 *
 * FAIL-OPEN BY CONSTRUCTION:
 *   Every "I could not tell" answer means ALIVE. A false negative kills the bridge of a
 *   session the owner is actively talking to; a false positive is bounded by the fact that
 *   the next real close clears it. Only a positive, answered "that process does not exist"
 *   stops the monitor.
 */
const { execFileSync } = require('child_process');

/** Nothing below this pid is a real Windows process we would ever watch. */
const MIN_PID = 1;
/** How deep to walk before giving up on finding the session process. */
const MAX_DEPTH = 12;
/** Re-confirm the owner is the SAME process (not a pid reused by Windows) this often. */
const DEFAULT_VERIFY_MS = 60_000;

function powershell(script, { timeoutMs = 15_000 } = {}) {
  return execFileSync(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
    { encoding: 'utf8', timeout: timeoutMs, stdio: ['ignore', 'pipe', 'ignore'] },
  );
}

/**
 * One PowerShell round-trip for the whole ancestor chain. Walking it with one call per
 * level cost ~8 process spawns at startup; this costs one.
 */
function chainScript(pid, depth) {
  return [
    "$ErrorActionPreference='SilentlyContinue'",
    `$id = ${pid}`,
    `for ($i = 0; $i -lt ${depth} -and $id -gt 0; $i++) {`,
    '  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id"',
    '  if (-not $p) { break }',
    "  $ct = ''",
    "  if ($p.CreationDate) { $ct = $p.CreationDate.ToUniversalTime().ToString('o') }",
    '  $cl = $p.CommandLine',
    "  if (-not $cl) { $cl = '' }",
    '  Write-Output ("{0}`t{1}`t{2}`t{3}`t{4}" -f $p.ProcessId, $p.Name, $p.ParentProcessId,'
      + ' $ct, ($cl -replace "`t", " " -replace "`r?`n", " "))',
    '  $id = $p.ParentProcessId',
    '}',
  ].join('\n');
}

/** Tab-separated `pid name ppid createdAt commandLine` lines -> entries, nearest first. */
function parseChain(text) {
  const out = [];
  for (const raw of String(text || '').split(/\r?\n/)) {
    if (!raw.trim()) continue;
    const [pid, name, ppid, createdAt, ...rest] = raw.split('\t');
    const id = Number(pid);
    if (!Number.isInteger(id) || id < MIN_PID) continue;
    out.push({
      pid: id,
      name: (name || '').trim(),
      ppid: Number(ppid) || 0,
      createdAt: (createdAt || '').trim(),
      commandLine: rest.join('\t').trim(),
    });
  }
  return out;
}

/**
 * The nearest ancestor that IS a Claude Code session.
 *
 * Matching is on the process NAME, never on a path. Every process in this chain - the
 * monitor itself and each intervening shell - carries `.claude` somewhere in its command
 * line, so a substring match on the command line selects the monitor's own bash wrapper
 * and the watchdog would then watch a process that always dies first.
 *
 * entries[0] is the monitor itself and is never eligible.
 */
function pickOwner(entries) {
  for (let i = 1; i < entries.length; i++) {
    const e = entries[i];
    const name = e.name.toLowerCase();
    if (name === 'claude.exe') return e;
    // A CLI install runs under node; its command line names the harness entry point.
    if (name === 'node.exe' && /[\\/](?:claude|claude-code)[\\/][^\s]*cli\.js/i.test(e.commandLine)) {
      return e;
    }
  }
  return null;
}

/**
 * Resolve the session process that owns this monitor.
 * @returns {{pid:number,name:string,createdAt:string,source:string}|null}
 */
function resolveOwner({ pid = process.pid, env = process.env, exec = powershell } = {}) {
  const override = Number(env.WA_SESSION_OWNER_PID);
  if (Number.isInteger(override) && override >= MIN_PID) {
    return { pid: override, name: 'override', createdAt: '', source: 'env' };
  }
  let text;
  try {
    text = exec(chainScript(pid, MAX_DEPTH));
  } catch {
    return null; // no PowerShell / query refused -> fail open, no watchdog
  }
  const owner = pickOwner(parseChain(text));
  return owner ? { ...owner, source: 'chain' } : null;
}

/** Cheap existence probe. Unknown (EPERM and friends) counts as alive. */
function pidExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e && e.code === 'ESRCH' ? false : true;
  }
}

/**
 * Is the owner still running AND still the same process?
 *
 * The identity half exists because Windows reuses pids. A monitor watching a recycled pid
 * would never notice its session died - the same "still looks alive" failure this whole
 * module exists to end - so the creation timestamp is re-checked periodically.
 *
 * @param {object} owner  from resolveOwner()
 * @param {object} [opts] {now, verifyMs, exec, state}
 */
function isAlive(owner, opts = {}) {
  if (!owner) return true; // nothing to watch -> never stop on this account
  if (!pidExists(owner.pid)) return false;
  if (!owner.createdAt) return true; // no identity baseline -> existence is all we have

  const state = opts.state || isAlive._state || (isAlive._state = {});
  const now = typeof opts.now === 'function' ? opts.now() : Date.now();
  const verifyMs = opts.verifyMs || DEFAULT_VERIFY_MS;
  if (state.checkedAt && now - state.checkedAt < verifyMs) return true;
  state.checkedAt = now;

  const exec = opts.exec || powershell;
  let text;
  try {
    text = exec(chainScript(owner.pid, 1));
  } catch {
    return true; // could not ask -> fail open
  }
  const [found] = parseChain(text);
  if (!found) return false;                       // answered: that pid is gone
  return found.createdAt === owner.createdAt;     // answered: same process or a recycled pid
}

module.exports = { parseChain, pickOwner, resolveOwner, isAlive, pidExists, chainScript };

// CLI: print the pid of the Claude session that owns THIS process (empty if unresolvable).
// The close hook runs as a child of the ending session, so this is how it learns which session
// is closing - and therefore which monitor is its own to stop (PR #157 review, P1).
if (require.main === module) {
  const owner = resolveOwner();
  if (owner) process.stdout.write(String(owner.pid));
}
