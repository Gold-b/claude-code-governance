---
name: wa-cc
description: RETIRED ON THIS MACHINE (2026-08-20) - the WhatsApp/Slack bridge runs on a Linux host as a systemd service, NOT here. Do NOT arm any monitor from a coding session; the entry points refuse. Reference only: design, routing and the outbound send path.
---


> ## 🛑 RETIRED ON THIS MACHINE — ALL PROJECTS (owner decision, 2026-08-20)
> **This file is user-level, so this change is GLOBAL.** It applies to every project
> on this machine — not just the project that made it. If you are in a project
> whose canon does not mention this, you are still covered by it: that is why the notice lives here,
> in the one place every project reads.
>
> The bridge runs on **a Linux host** (`root@203.0.113.10`, `wa-live-agent.service` +
> `slack-cc-bridge.service`) since 2026-08-19. **A coding session must never arm a monitor here.**
>
> **Three independent layers, complementary rather than competing** — each catches what the others
> cannot:
> 1. **The rule, in writing** (this banner, and the "Do NOT arm" section below). Catches an agent that
>    reads before acting.
> 2. **The code refuses.** `wa-session-inbox.js` and `wa-monitor.js` exit 3 unless
>    `WA_ALLOW_LOCAL_MONITOR=1` is set deliberately, and `hooks/wa-cc-autostart.sh` is retired behind an
>    `exit 0` so it can no longer emit an arm instruction. Catches an agent that acts without reading —
>    which a written rule cannot, and which is why the owner asked for this layer.
> 3. **The sweeper stays.** `hooks/wa-session-inbox-stop.sh` remains registered ON PURPOSE. It KILLS
>    monitors, it never arms one, so if something does slip through it cleans up after it.
>
> **Why layer 2 exists at all:** a local monitor claims presence, the remote agent correctly yields to
> it, and a local reader that cannot read leaves the owner in silence — with no error on either side,
> because neither side is wrong (GOTCHAS #27, reproduced 2026-08-19). A written rule failed silently
> twice that same week.
>
> **Only a new session proves this.** `grep` proves the code is gone; it does not prove the behaviour
> is. On the next session start, confirm BOTH are empty: any `wa-session-inbox.js` process, and
> `~/.claude/wa-session-presence-*.json`.
>
> ```bash
> powershell -NoProfile -Command '@(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "node.exe" -and $_.CommandLine -match "wa-session-inbox" }).Count'
> ls ~/.claude/wa-session-presence-*.json 2>/dev/null | wc -l
> ```
>
> **Copy that form exactly. The earlier one returned `0` while a monitor was live** (found and fixed
> 2026-08-20 by mutation test - one inert `node` decoy: new form `1`, old form `0`, same machine, same
> second). Three traps, and each one alone produces a silent false all-clear:
> - **Single-quote it for bash.** Double-quoted, *bash* expands `$_` before PowerShell sees it and the
>   filter turns to garbage (measured: `$_` arrived as `unsetenv`).
> - **`.Count` is `0` for an errored pipeline as well as an empty one** - errors go to stderr, the `0`
>   goes to stdout, so "it broke" and "you are clean" look identical. This check is **fail-open**,
>   which is backwards for a safety gate: a missing check sends a human to look, a lying check does not.
> - **Filter on `$_.Name -eq "node.exe"`.** A bare `CommandLine -match` scan matches *the scanning
>   process itself* and returns `1` forever - a false positive that wastes a session hunting a ghost.
>
> This applies to every "is X running?" check on Windows, not just this one.
>
> **Outbound is unaffected:** `~/.claude/skills/whatsapp/send.js` still works and makes no claim.
> Everything below is kept as the design record and for the reply/routing rules.

# /wa-cc — WhatsApp ↔ Claude Code Bridge v2 (Monitor-based)

Event-driven bridge. A Node watcher (`wa-monitor.js`) follows the gateway admin log as an
OS background process (ZERO tokens at idle) and emits one JSON line per allowlisted
incoming message; a persistent harness Monitor turns each line into a session wake-up.
NO cron. v1 (60s CronCreate polling) is RETIRED — never re-create it.

**Language:** Hebrew for WhatsApp replies. English for code/paths.
**Security:** allowlisted sources ONLY (`~/.claude/.wa-bridge.json` `sources[]` — the
Ops-Group group + the operator's private chat). Never process any other chat.

## Activation (normally AUTOMATIC)

The SessionStart hook `wa-cc-autostart.sh` auto-arms the bridge silently (owner standing
directive 2026-07-21). Manual arming (only if the hook did not run):

1. Verify gateway: `docker ps --format "{{.Names}}" | grep <ADMIN_CONTAINER>`
2. Arm a persistent Monitor **from the project directory**:
   `cd /c/dev/<project> && node "$USERPROFILE/.claude/skills/wa-cc-bridge/wa-monitor.js"`
   description: `WhatsApp bridge: allowlisted incoming messages`, persistent: true.
   - **Use forward slashes / `$USERPROFILE`.** The Monitor tool passes the command through a
     shell that eats Windows backslashes (`C:\Users\...` became `Users<user>.claude...`).
   - **The cwd decides which WhatsApp group the bridge binds to.** `writeLock()` records
     `projectCwd` + the jid resolved from it, so arming from the wrong directory silently binds
     the WRONG group (hit live 2026-07-26). Verify after arming: the lock's `jid` must equal
     `node ~/.claude/skills/whatsapp/send.js --print-target`.
3. Exit code 3 = another session already holds the bridge (fresh `~/.claude/wa-monitor.lock`
   whose owner pid is ALIVE) — do not arm again. A lock left by a killed monitor is ignored
   automatically (the pid liveness check added 2026-07-26); it no longer blocks for 60s.

**ARM IT EARLY — this is the standing default (owner, 2026-07-26).** If the bridge is not armed
in the working session, the DAEMON answers instead, and it answers from whatever context it has.
That is exactly how the owner received a stale "top 5 open items" list in which four items were
already finished. The daemon now resumes the project's chronologically NEWEST session
(`lib.latestSessionId`) rather than one stored id, so its answers carry real context — but a live
session holding the lock is always better than the daemon standing in for it.

## ALWAYS-ON AGENT — ⚡ LIVE since 2026-07-27 (owner-approved switchover)

> **⚠️ RELOCATED 2026-08-19/20 — the agent no longer runs on the Windows box.**
> It runs on the Linux host as systemd unit **`wa-live-agent`** (`root@203.0.113.10`),
> as the unprivileged user `wabridge`, cwd `<PROJECT_ROOT>`, logs `<BRIDGE_ROOT>/logs/wa-live-agent.log`.
> The Windows scheduled tasks `WA-Live-Agent` and `WA-Tail` are **Disabled**;
> `WA-Gateway-Tunnel` stays RUNNING (outbound sends from sessions go through it).
> Everything below describes the agent's DESIGN, which is unchanged — only its host moved.
> Read "Do NOT arm `wa-session-inbox.js`" further down before arming anything in a session.
>
> **Do NOT arm `wa-monitor.js` in a session** either — the always-on agent holds the bridge
> lock, and a session monitor would lose the race (exit 3) or, worse, win it and leave the
> agent dead. The old `WA-CC-Bridge-Daemon` task remains stopped and disabled, not deleted.
> Verified at switchover: process alive, lock held, bound to the right group, and it resumed the
> live session's context (forked).

`agent/wa-live-agent.mjs` is the owner-requested always-on agent: **ONE long-lived process
holding ONE Claude Code session** (Agent SDK streaming-input mode), fed by the gateway log.
Each WhatsApp message becomes the next turn on the same session, so context is neither rebuilt
nor re-sent per message — the owner's ask, in his words: *"like VS keeps the session open in
its window"*. On boot it resumes the project's chronologically newest transcript, so a restart
continues the last real conversation.

**Verified end-to-end (isolated: fake gateway log, temp lock, stubbed sender — no real traffic,
no message to the owner):** 2 turns, **exactly one session opened**, and turn 2 correctly
recalled turn 1.

**Measured cost — and the trap that produced a wrong number first.** `total_cost_usd` on the
SDK's `result` message is **CUMULATIVE for the session, not the cost of that turn.** Reading it
as per-turn produced a "$0.53 per message" figure that was ~15x too high and was reported to the
owner before being checked. A 3-turn probe settles it:

| turn | `total_cost_usd` | delta (real marginal) | cacheWrite | cacheRead |
|---|---|---|---|---|
| 1 | $0.2993 | $0.2993 | 28,724 | 23,876 |
| 2 | $0.3341 | **$0.0348** | 831 | 52,600 |
| 3 | $0.3612 | **$0.0271** | 26 | 53,431 |

So: **~$0.30 once to open a session** (writing the project context into cache) and **~$0.03 per
message after that**, with the context served from cache rather than resent — turn 3 wrote 26
tokens and read 53,431. Always subtract the previous turn's total to get a per-message figure.
Still **not A/B'd against the per-message daemon**, so do not quote a saving *versus it*; and
note the cache TTL is server-side, so a long-idle session goes cold and pays setup again.

**Operating it.** `agent/launcher.vbs` runs it hidden with cwd = the project (**the cwd picks
the WhatsApp group** — same rule as the v2 monitor) and redirects stdout/stderr to the log. It
resumes the project's newest transcript with **`forkSession: true`**, so it inherits the context
but writes its own file — without the fork it would append to a transcript a live session may
still be writing. Each fork becomes the newest transcript, so restarts chain correctly.
Env knobs: `WA_AGENT_CWD`, `WA_AGENT_PERMISSION_MODE`, `WA_AGENT_SEND_JS` (test stub),
`WA_AGENT_RESUME_MAX_AGE_MS`, `WA_AGENT_POLL_MS`, `WA_INBOUND_LOG_DIR`.

**⚠️ Where inbound actually comes from — `<OPENCLAW_HOME>/admin-logs/admin-<date>.log`, never
`gateway-logs/`.** Only the admin log carries the `[message-hook] Received: ... text=<msg>` lines
the parser matches; the gateway log has outbound sends plus `Skipping group message ... (not in
allowlist)` / `Forwarding group message to admin` notices that contain no message text (8 days of
real gateway logs: **0** `Received:` lines). Both consumers now resolve it through the single
`lib.INBOUND_LOG` constant — do not reintroduce a per-file literal.

**Live outage 2026-07-27 00:39–01:07 (root cause + why it stayed silent).** The always-on agent
shipped tailing `gateway-logs/gateway-*.log`, so it received **nothing** for its entire uptime
while the owner sent four messages, and because it also holds the shared lock the working v2
monitor could not run either. The e2e harness had passed by building its fixture in the same
wrong directory the code read — it proved the code agreed with itself. Two guards now exist:
`agent/wa-live-agent.test.mjs` asserts against the REAL production line format and pins the
location to the shared constant (mutation-proven: restoring the bug fails 2 tests, hardcoding the
literal fails a 3rd), and the agent logs `inbound <file> - ok|UNREADABLE` at boot, WhatsApping a
warning when the resolved log holds no parseable line. **Check that line first when it goes quiet.**

**One reader, one answerer (owner complaint 2026-07-27: "the new daemon method hurts our work").**
Two things were wrong and neither is fixed by reverting to the per-message daemon:

1. **No ack.** The v2 monitor 👍-reacted within milliseconds; the agent shipped without it, so a
   message that started real work produced silence for minutes and read as a dead bridge. The ack
   now lives in `wa-ack.js`, shared by both, and fires BEFORE any routing or work.
2. **Two agents on one repo.** The agent is a second context. When the owner messaged "implement
   the #145 opener" while a session was working the same repo, both started on it. So: an
   interactive session arms **`wa-session-inbox.js`** as a persistent Monitor, which announces
   presence (heartbeat) and streams inbox events into that session. The agent still reads the log
   (single reader, no lock race) and records every event to `~/.claude/wa-inbox.jsonl`, but while
   presence is fresh it **acks and yields** instead of answering. Stale presence (>60s, e.g. a
   crashed session) hands answering straight back — the bridge can never go permanently mute.

**Do NOT arm `wa-session-inbox.js` (changed 2026-08-19/20).**

The always-on agent now runs on the Linux host as `wa-live-agent.service`, where the
gateway is local. A session monitor on the Windows box is actively harmful there, because
it announces presence — which makes the remote agent **yield** — while being unable to read
the inbound log, since the gateway no longer runs on that machine.

That exact combination produced a silent outage on 2026-08-19: the owner's message reached
the remote agent, which logged `-> yielded (live session owns this turn)` and stepped aside
for a Windows session that had started the previous day, before the migration, and was still
tailing a dead local path. One participant saw the message and deferred; the one that took
the turn was deaf. Both behaved exactly as designed and the owner got silence.

**Sessions may still SEND** — `whatsapp/send.js` works from any project, routed through the
`WA-Gateway-Tunnel` scheduled task (a persistent SSH port-forward to the server's
gateway). That task must stay running: `wa-ack.js` hardcodes `127.0.0.1`, so no env override
replaces it. Sessions must simply not claim the answering turn.

**Where things live now:**
- agent: `<BRIDGE_ROOT>/skills/wa-cc-bridge/` on `root@203.0.113.10`, service `wa-live-agent`
- it runs as the unprivileged user `wabridge`, cwd `<PROJECT_ROOT>`, replies tagged `[CC][PROJECT]`
  (via `WA_AGENT_TAG`; unset keeps the historical bare `[CC]`)
- Slack feeder: `slack-cc-bridge.service` on the same host
- logs: `<BRIDGE_ROOT>/logs/wa-live-agent.log`

**To revert to a PC-resident bridge:** re-enable the `WA-Tail` scheduled task (the log
mirror) and `WA-Live-Agent`, stop `wa-live-agent.service` on the server, and restore this
section from git history in the project repo's plan document
(`docs/superpowers/plans/wa-bridge-to-linux-host.md`, Task 7).

> **The full design + defect record lives in the REPO** (owner instruction 2026-07-29 — this
> directory is not version-controlled or backed up):
> `c:\dev\example-project\docs\knowledge\wa-bridge-review-2026-07-29.md`.
> It carries the owner's policy rulings, all 26 CODEX findings across three rounds, and the five
> that are still open. Read it before changing routing, ownership or context loading.

**EXACTLY ONE ANSWERER — the presence file is a CLAIM, not a flag** (owner, 2026-07-29, with a
screenshot of two replies to one test message). Every armed monitor tails the same inbox from EOF,
so a second session opened in another VS Code tab answered alongside the first. The daemon was
innocent: its log shows `-> yielded` on all three test messages. Now `claimPresence()` decides WHO
answers, and the policy is **NEWEST WINS** (owner: *"the new session takes the bridge from the
current one and leads it"* — when he opens a session, that is where he is working):

- a monitor **seizes** the claim once, at startup (`{takeover: true}`), and logs
  `took the bridge over from pid N`;
- every later **heartbeat only refreshes a claim it still holds**. The asymmetry is the design:
  if heartbeats could seize too, two live monitors would trade the bridge every beat and answers
  would come from whichever one held it that second;
- the replaced monitor logs `STANDBY` and emits nothing — it stays running, so when the newer
  session closes or crashes its claim goes stale (>60s) and the older monitor takes the bridge
  back on its own. The bridge cannot end up mute.

`clearPresence()` is owner-scoped too: a standby session's close used to delete the live
holder's claim. Same session, same file: `sessionIsLive()` now normalises `\` vs `/` — the arming
line spells the project with forward slashes and the daemon's launcher with backslashes, so the
same directory compared unequal and the daemon would have answered alongside any live session.
Regression: `node ~/.claude/skills/wa-cc-bridge/double-answer.test.js` (18 assertions incl. a live
two-monitor case) + `bash double-answer.mutation.sh` (5 proven mutations).

**REPLY ON THE CHANNEL THE MESSAGE CAME FROM** (PR #157 review, P1). A yielded event reaches the
live session as raw JSON, and that JSON carries `source`. When it is `Slack-Bridge`, answer with
`node <project>/services/slack-cc-bridge/slack-send.js <chatId> "<text>"` — **not** `send.js`.
Answering everything through `send.js` posts a Slack question into the WhatsApp group: visible to
the wrong person and invisible to the right one. The daemon already routes by `source`; a live
session must do the same, because it is the one answering while it holds the bridge.

**Delivery is proven by a `messageId`, never by a status code.** `send.js` used to print
`res.statusCode` and exit 0 no matter what, and the always-on agent — which DOES check the exit
status — logged a lost message as a success. It now parses the body, requires a messageId, retries
a transient failure (a real 400 succeeded a minute later on the identical payload) and exits
non-zero when it truly could not deliver. `WA_GATEWAY_PORT`/`WA_GATEWAY_HOST` exist so a test can
point at a stand-in gateway: the real one owns 18789, and a test that could not bind it reached
production and messaged the owner.

**Releasing it at close is AUTOMATIC and NOT a step anyone has to remember** (owner, 2026-07-28,
reported as severe: *"the WA agent answered a message I sent after the session had supposedly
closed"*). A persistent Monitor is not torn down just because a session ended, so the presence
heartbeat stayed fresh and a dead session kept claiming every incoming message — the agent yielded
to nobody, and the bridge looked alive while nothing answered.

`~/.claude/hooks/wa-session-inbox-stop.sh` runs on **`SessionEnd`** — NOT on `Stop`. `Stop` fires
at the end of every assistant turn, so registering it there killed the bridge seconds into every
session while every one of its own tests passed (2026-07-29). What `SessionEnd` cannot cover — a
hard kill, where no hook runs at all — is covered inside the monitor by `session-owner.js`: it
resolves the nearest `claude.exe` ancestor once and exits when that process is gone. It
matches on the COMMAND LINE (`wa-session-inbox.js`), so the always-on daemon is never touched, and
it clears the presence file **only when the sweep actually reported nothing left** — an unanswered
query counts as unknown, not as zero. Regression test: `bash ~/.claude/hooks/wa-session-inbox-stop.test.sh`
(6 assertions, both directions).

`wa-cc-autostart.sh` is also silent on `Stop`/`SessionEnd`. It is registered on three events with
one body, so it used to emit "arm a persistent Monitor" at the exact moment the close was tearing
one down — and a session that re-arms on its way out is the one that steals the next session's
messages. Re-arming after a compact is still correct; only the closing events are suppressed.

**Media enrichment is SHARED (`wa-enrich.js`).** Inbound voice notes are transcribed and images
resolved to an absolute path before the event is routed. The always-on agent originally lacked
this - it carried over the log tailing but not the enrichment - so voice notes reached the owner's
session as the literal string `<media:audio>` with no words in them, and had to be transcribed by
hand (caught live 2026-07-27 when he asked "was the message I just sent transcribed"). Both
readers now call the same enricher; the ack still fires BEFORE enrichment, because transcription
can take seconds.

**Rollback:** `Stop-ScheduledTask WA-Live-Agent; Disable-ScheduledTask WA-Live-Agent;
Enable-ScheduledTask WA-CC-Bridge-Daemon; Start-ScheduledTask WA-CC-Bridge-Daemon` — then delete
the stale lock if either left one behind.

**Testing:** `node --test agent/wa-live-agent.test.mjs` (10), `node --test wa-inbox.test.js` (8),
`node --test wa-enrich.test.js` (7) and `node --test wa-monitor.test.js` (44) after any change — both run against fake `OPENCLAW_HOME` dirs, a temp lock + state and a
stubbed sender, so they never touch real traffic or message the owner. The agent suite covers the
inbound path end to end: a real-format line appended to a live `admin-*.log` must produce exactly
one event, and gateway-log chatter must produce none. A behavioural harness that only proves
"one session across turns" is not enough — that is what passed while production received nothing.

## When an event arrives (mediator model — owner rules 2026-07-21)

Each event is `{"source","type","chatId","sender","text","ts"}`.

**Media events** (owner rules): the watcher resolves the downloaded file from
`~/.openclaw/media/inbound` (newest of its kind within a lookback window - the
gateway saves media under a UUID with no msgId mapping in the log):
- **Voice** (`<media:audio>`) → auto-transcribed (faster-whisper); `.text` becomes
  `[voice] <transcript>` and `.media` = the filename.
- **Image** (`<media:image>`, owner request 2026-07-23) → `.text` becomes
  `[image] ... Read tool at: <absolute path>` and `.mediaPath` = that absolute path.
  **When you see an image event, OPEN it with the Read tool at `.mediaPath` to view
  the actual pixels, THEN act on it.** (Images are not captioned by the bridge; you
  see them yourself.) Image lookback is wider than audio (`WA_IMAGE_LOOKBACK_MS`,
  default 20 min) - the download can land minutes before the hook line.

1. **REPLY FIRST (owner rule 2026-07-21): before any verification or work, send an
   immediate short reply/ack via send.js — within seconds of the event.** Then do the
   work and send the substantive follow-up. Never leave a bridge message unanswered
   while investigating.
   **ATTENTIVE WINDOW (owner rule 2026-07-21): for 180 seconds after EVERY reply you
   send, incoming bridge events take priority over any ongoing work — answer them
   immediately, defer heavy steps.**
2. Treat `.text` as a normal user instruction in THIS session. Full normal workflow —
   planning, specs, approvals, QA, governance — exactly as if typed in the terminal.
3. Reply via `node ~/.claude/skills/whatsapp/send.js "[CC] <reply>"`:
   - SHORT, essence-only Hebrew. No code blocks, no logs, no markdown, no emojis.
   - Summarize session output; do not paste it.
   - Questions to the operator: one short message with numbered options; the answer arrives as
     the next bridge event.
3. The bridge keeps NO memory of its own (no shared-session file) — the session's
   regular memory is the only memory.

## Reconnection protocol (owner rule 2026-07-22)

After EVERY bridge disconnection (gateway/admin update, container restart, monitor
restart with a coverage gap), the FIRST message on reconnect must be:
`[CC] חזרתי מניתוק של X דקות (במידה ושלחת הודעה בזמן זה - אנא שלח אותה שוב)`
where X = minutes from disconnect start to listening restored. Also: before ANY
planned disconnect, announce it with a time estimate; if the window stretches
beyond the estimate (retry, failure), send an updated warning - never let an
announced 2-4min window silently become 10+.

## Deactivation

- This session: TaskStop on the Monitor.
- Everything (both layers, instantly): `touch ~/.claude/wa-bridge-off`
  (delete the file to re-enable).

## Components

| Component | Path |
|---|---|
| Watcher (session+daemon modes) | `~/.claude/skills/wa-cc-bridge/wa-monitor.js` |
| Parser lib + tests | `wa-monitor-lib.js`, `wa-monitor.test.js` (run: `node --test`) |
| Allowlist config (local-only) | `~/.claude/.wa-bridge.json` |
| Singleton lock | `~/.claude/wa-monitor.lock` |
| Kill-switch | `~/.claude/wa-bridge-off` |
| Auto-arm hook | `~/.claude/hooks/wa-cc-autostart.sh` |
| Spec / Plan | `SPEC-v2-monitor-bridge.md` / `PLAN-v2-monitor-bridge.md` |
| Legacy v1 (retired) | `~/.claude/skills/wa-cc-poll/poll.js` — do not use |
