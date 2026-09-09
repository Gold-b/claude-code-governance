# Context Governance Installer for Claude Code

Portable installer that sets up the full Context Governance architecture at the user level (`~/.claude/`).

## Prerequisites

**To install and run the framework you need only the first row.** Everything below it is optional
and buys you one specific feature; nothing else degrades when it is absent. The installer refuses
to run without `node` and says so; the rest is listed here so you can decide before you start
rather than discover it from a hook at an awkward moment.

| You need | For what | If it is missing |
|---|---|---|
| `bash`, `git`, `node` | the framework itself: every hook is bash, 17 hooks shell out to `git`, and `install.sh` merges your `settings.json` with `node` | **install.sh exits.** On Windows use the Git Bash that ships with Git for Windows |
| `python` (3.x, on `PATH`) | the JSON payload parsing inside the guards | They fall back to a parser-free extraction; if that also fails they print `MALFUNCTION` and exit 1 rather than passing your write through unchecked. Working but noisy — install python |
| `gh`, authenticated (`gh auth login`) | the `pr-follow-through` skill and its PR watcher | The watcher exits with a message. Nothing else notices |
| A Slack connector on claude.ai | Slack notifications from a **cloud routine** you create | Routines run; they just cannot post |
| A GitHub connector on claude.ai | a **cloud routine** acting on repos you do not own | See "GitHub from a cloud routine" below — this one has a real trap in it |

### Secrets and machine-local values — set these up BEFORE your first session

This framework publishes: a `PostToolUse` hook mirrors every edit under `~/.claude/hooks/governance/`
and `~/.claude/skills/` into the installer bundle, and a `Stop` hook can push that bundle to a public
repository. **So no tracked file may ever contain a real value.** Three files exist to hold yours,
all at the `~/.claude` root, which the sync cannot reach by construction:

| File | Holds | Created by |
|---|---|---|
| `~/.claude/.governance-local.env` | your governance repo path, your commit identity, any API key or token a hook needs | you — copy the `.example` the installer drops beside it |
| `~/.claude/.pii-names` | names, client names, group names and codenames the scanner must catch | installer creates it empty; **an empty file means the name scan passes everything** |
| a skill's own `config.local.json` | per-skill real values (repos, reviewers, channel ids) | you, when a skill asks for one |

`.pii-names` deserves a sentence of its own. A shape-matching scanner cannot detect a name — a
group name or a client codename scores zero and the scan prints `PASS`. That is how two real leaks
reached a published repo. Fill this file on day one with every name that must never ship, and treat
`PASS` as "clean of what I modelled", never as "clean".

### GitHub from a cloud routine (the trap)

Connecting GitHub in the claude.ai connector list authorises the **Claude GitHub App on your own
account**. A cloud routine can then reach repositories the app is installed on — typically yours,
not a client organisation's. Declaring a foreign repository as a routine source is refused with
`HTTP 403 You don't have access to a repository this routine uses`, and there is no `gh` CLI in the
routine sandbox to work around it.

To reach a repository in an organisation you do not administer, add GitHub's remote MCP server as a
**custom connector** instead: `https://api.githubcopilot.com/mcp/`, Authentication = **None**, and one
Additional request header `Authorization: Bearer <your token>`. GitHub's server does not support
dynamic client registration, so a token is the documented path for third-party hosts — the OAuth
client fields on that dialog are the wrong road. Use a fine-grained token limited to the one
repository. The alternative, if you can get it, is for that organisation to install the Claude
GitHub App.

One more thing worth knowing before you look for it: **a custom connector does not appear in the
connector list a session sees.** To recover its id, create a disabled routine with no
`mcp_connections` — the API attaches every connector on the account and returns their ids.

## Quick Install

```bash
bash ~/.claude/governance-installer/install.sh
```

## Options

| Flag | Effect |
|---|---|
| `--core-only` | Install only the 10 core governance skills (skip the 5 extended toolkit skills) |
| `--force` | Overwrite existing files without prompting |
| `--dry-run` | Preview what would be installed (no changes) |
| `--no-claude-md` | Skip CLAUDE.md — keep your existing user instructions |
| `--uninstall` | Remove all governance files (backs up before removal) |

## What Gets Installed

### Hooks (20 scripts, all registered in `~/.claude/settings.json`)

Generated from `bundle/settings-hooks.json`, which is the source of truth. `check-full-finish.sh`
is registered on two events and `pr-watch-guard.sh` on three, so the table has 23 rows over 20
distinct scripts.

| Event | Script | Purpose |
|---|---|---|
| SessionStart | `canonical-cwd-check.sh` | Refuses a session opened on a stale or duplicate checkout |
| SessionStart | `pre-session.sh` | Detects governance, triggers the briefing, reports a published framework update |
| SessionStart | `pr-watch-guard.sh` | If the repo has open PRs of yours and no live watcher: one context line with the exact `pr-watch.sh` command to arm (v1.4.0) |
| UserPromptSubmit | `pre-task.sh` | Governance lite check per message |
| UserPromptSubmit | `plan-gate.sh` | Requires an approved plan before implementation work |
| UserPromptSubmit | `parallel-import.sh` | Detects pasted output from another session |
| PreToolUse (Edit/Write) | `governance-guard.sh` | Blocks protected-doc edits without a success token |
| PreToolUse (Edit/Write) | `pre-write.sh` | Impact map before file changes |
| PreToolUse (Edit/Write) | `pii-gate-pretooluse.sh` | Refuses a write that would put a real value into a publishable file |
| PreToolUse (Edit/Write) | `file-collision-guard.sh` | Blocks a write over a file another session claimed |
| PreToolUse (Bash, PowerShell) | `deny-git-bypass.sh` | Blocks a hook-bypass flag (`--no-verify`, `-c core.hooksPath=`, `HUSKY=0`, `GOVERNANCE_HOOKS=0`, `NO_LOCAL_COMPUTE=0`) on `git push` / `commit` / `merge` / `gh pr create` / `merge`; warns when `.githooks/` ships but `core.hooksPath` is unset. Owner override: `DENY_GIT_BYPASS=0` (v1.3.2) |
| PreToolUse (Bash) | `no-local-compute.sh` | In projects with a `.remote-compute` marker: project scripts run on the remote server, not the PC (v1.1.7) |
| PostToolUse (Bash, PowerShell) | `pr-watch-guard.sh` | After `gh pr …` / `git push`: asks the session (JSON `decision: block`) to arm the PR watcher when open PRs of yours have none; cool-down while it arms. Kill switch `GOV_PR_WATCH=0` (v1.4.0) |
| PostToolUse (Edit/Write) | `post-milestone.sh` | State update after milestones |
| PostToolUse (Edit/Write) | `sync-governance-copies.sh` | Mirrors a governance edit to the other copies; **the private-to-public crossing**, and gated as one |
| PostToolUse (Edit/Write) | `file-collision-record.sh` | Records this session's view of a file it just wrote |
| TaskCompleted | `check-full-finish.sh` | Warns about uncommitted changes |
| TaskCompleted | `pre-done.sh` | Verification-gate checklist before a task counts as done |
| TaskCompleted | `check-docs-updated.sh` | Warns when code changed and the docs did not |
| Stop | `end-session.sh` | Session-end handoff, and the gated push of the framework bundle |
| Stop | `close-completeness.sh` | Integrity warnings a closing summary cannot produce for itself |
| Stop | `close-report.sh` | Generates the closing summary **from the canonical files**, so an unrecorded claim cannot appear in it |
| Stop | `selftest-advisory-stop.sh` | Reports that the framework is unverified since the last selftest |
| Stop | `pr-watch-guard.sh` | Holds the stop ONCE per repo+session when open PRs of yours have no live watcher, so it gets armed before the session goes idle; the next stop passes (v1.4.0) |

Not registered on any event, and named on every selftest run so the decision cannot go quiet:
`render-gate.sh`, `render-rules-read.sh`, `gov-notify.ps1`. Helpers called by other hooks
(`_common.sh`, `check-no-pii.sh`, `pii-gate-parse.py`, `commit-task-success.sh`,
`file-collision-ack.sh`, `governance-helpers-check.sh`, `governance-selftest.sh`,
`sync-governance.sh`) are installed but are not themselves hook entry points.
`pr-watch.sh` (v1.4.0) is a tool, not a hook: the session arms it through the Monitor tool and
it prints one line per PR change (comment, review, +1, CI, merge) for the caller's own open PRs on
one repo, fast-forwards the clone on merge, and exits when none remain. `pr-watch.sh --selftest`
runs its offline controls. The flow that uses both is the `pr-follow-through` skill; every real
value it needs (repos, reviewers, channels) lives in `~/.claude/pr-follow-through/config.local.json`,
never in the skill — `config.example.json` ships placeholders only.

### Core Skills (10)
- **bootstrapper** — Loads relevant project context for session briefing
- **context-governance** — Audits context file hygiene (lite + full modes)
- **evidence-debugger** — Root-cause analysis with confidence grading
- **impact-safe-executor** — Pre-write impact map, scope enforcement
- **init-governance** — One-time project scaffold for governance structure
- **live-state-orchestrator** — Keeps PLAN/MEMORY/HANDOFF in sync
- **parallel-session-merge** — Reconciles multi-agent parallel work
- **pre-close-check** — Parallel-session + drift scan; MANDATORY before any handoff write
- **pr-to-git** — Review-gate PR loop. Core, not extended, because `bundle/docs/` installs unconditionally and `NEXT-SESSION-HANDOVER.md`'s default Definition of Done names it: a doc that ships in core may only mandate skills that ship in core.
- **pr-follow-through** — Drives your own open PRs to merge: relays each response, reminds the reviewer on a sane cadence, never self-merges a repo you do not own. Core for the same reason as `pr-to-git`, one step stronger: `pr-watch-guard.sh` is registered **unconditionally** in `settings-hooks.json`, and the text it hands the session names this skill. A hook that ships to everyone may only point at a skill that ships to everyone — otherwise the guard fires on a machine where the flow it names does not exist. It shipped in `bundle/skills/` at v1.4.0 while being in neither list, which is exactly the ship-but-never-install gap described below; caught by measuring the bundle against the two lists rather than trusting either.

### Extended Skills (5, skipped with `--core-only`)
- **plan-and-execute** — Multi-agent planning pipeline
- **qa-sec** — QA + Security audit suite
- **multi-agents** — Orchestrated agent teams
- **full-finish** — Universal post-task release pipeline
- **enable-remote-code** — Remote control for Claude Code sessions

### Docs (3 documents in `~/.claude/docs/`)
- **GOVERNANCE-AGENT-GUIDE.md** — Structured guide for LLM implementation
- **GOVERNANCE-HUMAN-GUIDE.md** — Human-readable governance reference
- **NEXT-SESSION-HANDOVER.md** — Goal-scoped continuation protocol: the `/goal` + `/loop` templates, the context-limit exception, and the rules that keep an autonomous loop from overriding a governance stop. It is the *renderer spec*; the rendered prompt lands in each project's `docs/context/NEXT-SESSION-PROMPT.md`, rewritten or deleted at every close.

### Configuration
- **CLAUDE.md** — User-level instructions (session protocol, security, governance rules)
- **settings.json** — Hook registrations merged into existing settings

## Portability

To install on another machine:
1. Copy the entire `~/.claude/governance-installer/` directory
2. Run `bash ~/.claude/governance-installer/install.sh`

All paths use `~/` notation — works on Windows (Git Bash/MSYS2), macOS, and Linux.

## Versions & updates

The installed version is stamped at `~/.claude/.governance-version`; the published one is
`bundle/VERSION` on `master`. At session start, `pre-session.sh` compares them and prints
`[GOVERNANCE UPDATE]` when a newer version exists.

A machine with no usable marker is told so too — otherwise the machines most in need of the
advisory (the ones predating versioning) would be the only ones never to get it.

It **advises, never installs** — `install.sh` replaces the very hooks and skills that are running
at that moment, so the update is always a deliberate action:

```bash
cd /path/to/claude-code-governance && git pull
bash install.sh --force        # backs up first
bash verify.sh
```

The network call is detached and only refreshes a 12-hour cache, so what a session prints is the
result of a previous run and nothing waits on the network. The check itself costs a measured
**+77 ms / +106 ms** on Windows/MSYS2 (two interleaved A/B runs, n=12 each; under 40 ms on
Linux/macOS, where forks are cheaper). Offline machines back off a full TTL rather than retrying
every session. `GOVERNANCE_UPDATE_CHECK=0` removes the cost entirely.

The marker is a **claim**, so `install.sh` only writes it when the claim is true. Three outcomes:

| Outcome | Marker |
|---|---|
| Every step succeeded | Stamped with the bundle's version |
| A step failed | **Left exactly as it was.** The failure may be unrelated to the files on disk, and deleting a valid marker turns a working machine into one that reports "no usable version marker" at every session start |
| The bundle carried no `VERSION` | **Removed — after being backed up** to `~/.claude/backups/governance-<timestamp>/`. This run really did overwrite hooks, skills and docs with content of unknown provenance, so a marker from an earlier install now describes files that are no longer there |

A placeholder is never written: the reader would reject it as not-a-version and advise re-running
the installer, which would write the placeholder again — a loop with no exit. Any run that did not
fully succeed exits non-zero and does not say "ready". `--dry-run` previews all of it, exit code
included. See Agent Guide §20.

## Kill Switch

Disable all governance hooks without uninstalling:
```bash
export GOVERNANCE_HOOKS=0
```

Silence only the update advisory (hooks keep working):
```bash
export GOVERNANCE_UPDATE_CHECK=0
```

## Uninstall

```bash
bash ~/.claude/governance-installer/install.sh --uninstall
```
Backs up all files before removal. CLAUDE.md is NOT removed (manual decision).

## Testing the hooks (sandbox, never touches your real ~/.claude)

```bash
bash bundle/hooks/governance/tests/test-session-state.sh
bash bundle/hooks/governance/tests/test-update-advisory.sh
bash bundle/hooks/governance/tests/test-payload-root.sh
```

## Rolling out an update to a client machine

```bash
git pull
bash install.sh --force          # backs up ~/.claude/hooks, skills, docs first
bash bundle/hooks/governance/tests/test-session-state.sh
bash bundle/hooks/governance/tests/test-update-advisory.sh
bash verify.sh
```

## Placeholder convention (read this before you commit)

**This repository is PUBLIC.** The rule is not "scrub secrets before pushing" — it is that the
real values are never in a tracked file in the first place:

> **A tracked file carries a placeholder or an env lookup. The real value lives in a
> machine-local, gitignored config, and never appears in a tracked file.**

Machine-local config files (`.governance-local.env`, `.governance-mirrors`, `.wa-bridge.json`,
`.pii-names`) are the designated homes for real values. They are listed in `.gitignore`, so they
cannot be staged by accident. Anything that must vary per machine belongs there, or behind an
environment variable — never inlined into a script, doc, test or fixture.

### Use exactly these placeholders

Docs, tests and fixtures must use the spellings below. They are not arbitrary: `check-no-pii.sh`
recognises each one as a placeholder and stays green, so anything *else* of the same shape is
reported as a real value. Inventing a new "obviously fake" spelling will trip the gate.

| Kind | Placeholder |
|---|---|
| Person, named | `Operator One` |
| Person, referred to generically | `the operator` / `the owner` |
| Phone, Israeli | `972500000000` |
| Phone, US / NANP | `15550100000` |
| WhatsApp group JID | `120363000000000000@g.us` |
| WhatsApp user JID | `972500000000@s.whatsapp.net` |
| WhatsApp LID | `100000000000001` |
| WhatsApp message id | `3EB0EXAMPLE0000000000` |
| IPv4, public | `203.0.113.10` (RFC 5737 documentation range) |
| Home directory | `C:\Users\<user>` / `/c/Users/<user>` / `~/.claude` |
| Project / checkout path | `C:\dev\example-project` / `/opt/example-project` |
| Repository reference | `<SOURCE_REPO>` |
| Email address | `you@example.com` |
| Slack channel / user / team id | `C0EXAMPLE01` / `U0EXAMPLE01` / `T0EXAMPLE01` |
| Slack workspace host | `example.slack.com` |
| Google Drive / Sheets file id | `1EXAMPLE_FILE_ID` / `1EXAMPLE_SHEET_ID_00000000000000000000000` |
| Tunnel hostname | `example.ngrok.io` / `placeholder.trycloudflare.com` |
| Token / secret | `ghp_EXAMPLE0000000000000000000000000000` |

Private IPs (`127.0.0.1`, `10.0.0.5`, `192.168.1.10`, `172.17.0.1`) and Windows system paths are
not identities and need no placeholder.

### The gate

`bundle/hooks/governance/check-no-pii.sh` enforces all of the above. It matches **shapes**, not a
denylist of known-bad strings, because a denylist always lags reality — the 2026-08-18 sweep found
a third party's phone number and a real WhatsApp message id that nobody had thought to list.

```bash
bash bundle/hooks/governance/check-no-pii.sh --selftest              # prove the rules both ways
bash bundle/hooks/governance/check-no-pii.sh --list-rules            # rule table + remedy for each
bash bundle/hooks/governance/check-no-pii.sh --tree bundle           # scan before you push
bash bundle/hooks/governance/check-no-pii.sh path/to/file            # scan one file
```

Exit `0` is clean, exit `2` means a tracked file carries a real value. **When it fires, fix the
data, not the scanner.** Move the real value into `~/.claude/.governance-local.env` and leave a
placeholder or an env lookup behind. A genuine, reviewed exception can be marked inline with a
`pii-allow` marker — these are counted and reported, never silent.

Two rules (`NAME_DENY`, and the project-noun denylist) read from a machine-local `~/.claude/.pii-names`
and **ship empty on purpose**: putting real names and project nouns into a tracked scanner would
re-create the exact leak it exists to prevent. With no list present the structural name rules
(`NAME_ATTRIB`, `NAME_FIELD`) still run, and the skip is reported rather than hidden.

### Enable the git gates in a fresh clone (one command)

The scanner above is only a gate if something *runs* it. Two git hooks do, and they live in the
tracked `.githooks/` directory rather than `.git/hooks/` — `.git/hooks/` does not survive a clone,
so a hook placed only there protects the one machine that already knows about the problem.

```bash
git config core.hooksPath .githooks      # run once per clone
```

| Hook | When | What it scans |
|---|---|---|
| `.githooks/pre-commit` | every `git commit` | the **staged blobs** (`git show :path`), added/modified only |
| `.githooks/pre-push` | every `git push` | the files in the pushed range, as they exist at the pushed tip |

Both scan **only the files in that commit or push**, never the tree. Measured on Windows/Git Bash:
1 file 13.5 s, 3 files 31.9 s, 6 files 13.9 s — process spawn dominates, so a typical commit costs
**~15-35 s** almost regardless of file count. A tree-wide scan at the commit boundary would be
turned off within a week, and a control that gets turned off is how controls die. `pre-push` is the
backstop for anything that reached history some other way: `--no-verify`, a commit made before
`core.hooksPath` was set, a merge, a cherry-pick, or a rebase that replayed an old blob.

When a hit is found the commit is refused, the offending `file:line`, the rule name and the
remedy are printed, and nothing is written. Fix the data, not the scanner.

**If `check-no-pii.sh` cannot be found, the hooks BLOCK and name every path they looked for.**
They fall back from `~/.claude/hooks/governance/check-no-pii.sh` (the installed copy) to
`bundle/hooks/governance/check-no-pii.sh` (this repo's own copy, so a fresh clone on a machine
that has never run `install.sh` is still gated), and only then refuse. They never pass silently
for want of a scanner — that is the failure mode this whole directory exists to prevent.

If the scanner is present but *errors* or times out, the hooks WARN LOUDLY and allow: that is the
gate itself being broken, not evidence about your content, and a broken gate must not block all
work. The warning tells you to run the scan by hand before publishing.

**Kill switches** (both loud — the skip is printed, never silent):

```bash
GOV_GIT_PII_GATE=0 git commit ...   # skip the PII gate only
git commit --no-verify              # skip every hook (git's own switch)
```

**Tunables:** `GOV_PII_SCANNER` (explicit scanner path), `GOV_PII_TIMEOUT` (default 300 s for the
whole scan), `GOV_PII_MAX_FILES` (default 40 — above it you get a "this will take a while"
warning; the scan is never truncated, because a partial scan reported as a pass is a lie).

### The installer verifies by executing, not by listing

`install.sh` runs `check-no-pii.sh --selftest` against the copy it just installed (~80 s) before it
stamps the version marker. If the selftest fails, the install is reported as FAILED, the version is
**not** stamped, the exit code is 1, and the message names the backup directory this run created so
you can put the previous files back.

This exists because `verify.sh` is an existence check: 18 `[ -f ]` file tests and 5 settings
lookups. On 2026-08-30 it reported **30 passed** over a tree whose PII scanner had been silently
neutered — a file that is present and wrong looks exactly like a file that is present and right.

```bash
bash install.sh                 # verifies by default (~80 s)
bash install.sh --deep-verify   # also runs governance-selftest.sh (~2 min more)
bash install.sh --no-verify     # skip it; still exits 0, but is reported UNVERIFIED twice
```

`--no-verify` deliberately does **not** fail the run. A kill switch that fails the build is a nag,
not a switch — the gate is the default path being armed, not the impossibility of opting out. What
it does not get is silence: the summary prints `Verified: NOT CHECKED`.

*Known limit, stated rather than papered over:* the selftest proves the installed scanner **works**.
It does not prove it is the **newest** one — a stale bundle whose selftest still passes installs and
verifies clean. Freshness is the version marker's job, not this gate's.

## Changelog

- **2026-09-09 (v1.4.0) — PR follow-through: your own open PRs are watched until they merge, by a
  tool the session cannot forget to arm.** Three pieces, all generic. `pr-watch.sh` polls `gh` for
  the caller's open PRs on one repo and prints one line per change (comment, review, +1, CI rollup,
  merge state, merged/closed); on merge it fast-forwards the clone's base branch; it exits when no
  open PR remains, and `--selftest` runs its offline controls (a reviewer comment, an approval, a +1
  and a merge must fire; the caller's own comment and identical snapshots must not). `pr-watch-guard.sh`
  is the hook that keeps it armed: after any `gh pr …` / `git push`, at session start, and once at
  stop, it checks for a live heartbeat for this repo+session and otherwise hands the session the
  exact Monitor command (JSON `decision: block`, with a cool-down so it does not repeat while the
  watcher starts). The `pr-follow-through` skill is the flow around them — owned repos defer the
  merge to `/pr-to-git`; repos you do not own get a reviewer reminder cadence (Slack + PR mention,
  working hours, batched, state kept in a hidden block in the PR body shared with an optional cloud
  routine) and are never self-merged. **Placeholders only:** the skill ships `config.example.json`;
  every real repo, reviewer and channel lives in `~/.claude/pr-follow-through/config.local.json`,
  outside every repo. Selftest case with both directions; the hook's two `gh` calls have selftest
  seams honoured only under `GOV_SELFTEST_SBX`.
  Shipped in the same version: a **Prerequisites** section at the top of this README, because none
  of this was written where a new user would look — the installer's one hard dependency (`node`),
  the guards' preference for `python`, which features need `gh` or a claude.ai connector, and above
  all the three machine-local files that must hold your real values before the first session, since
  a `PostToolUse` hook mirrors this tree into a bundle a `Stop` hook can push publicly. It also
  records the GitHub-from-a-cloud-routine trap measured the same day: connecting GitHub on claude.ai
  authorises the app on *your* account, a foreign repository declared as a routine source is refused
  with `HTTP 403`, the sandbox has no `gh`, and the way through is a custom connector to GitHub's
  remote MCP server with a bearer header — its server offers no dynamic client registration, so the
  OAuth-client fields on that dialog are the wrong road. Plus the detail that costs an hour on its
  own: a custom connector is invisible to the connector list a session sees, and its id is recovered
  by creating a disabled routine with no `mcp_connections`.
  **Fixed before release, and worth naming because the framework is built to catch exactly it:**
  `pr-follow-through` shipped in `bundle/skills/` while appearing in neither `CORE_SKILLS` nor
  `EXTENDED_SKILLS`, so `install.sh` would never have installed it — the same ship-but-never-install
  gap as the five skills removed on 2026-09-07, and invisible on the machine that built it because
  the skill was already in `~/.claude/skills`. Found by measuring `bundle/skills/` against the two
  lists instead of trusting either. It is now core (10 core + 5 extended = 15), for the reason given
  in the Core Skills list above. The lesson generalises: **a bundle is not a manifest.** Presence in
  the bundle proves only that a file was copied; whether anyone receives it is a different fact, in
  a different file, and it needs its own measurement.
- **2026-09-09 (v1.3.3) — the two Bash-tool guards no longer switch themselves off in silence when `python` is absent.**
  Both `deny-git-bypass.sh` and `no-local-compute.sh` read the tool payload with a one-line
  `python -c`. With no `python` on PATH that yields an empty command, and the very next line exited 0:
  the guard was OFF, for that user, for every command, with no message. **Measured, not
  inferred:** rc=0 on a python-less PATH against a bypass, rc=2 with python. Same class as the B1
  incident (parser missing means gate open). Fixed the way `pii-gate-pretooluse.sh` already handles
  it: a python-free fallback that extracts the command from the JSON (no backslashes in the
  pattern, on purpose - gotcha #359), and if that yields nothing, a **loud `MALFUNCTION` on
  stderr and exit 1** - advisory-open, never silent, and never exit 2 (blocking every shell command
  on a python-less machine is how a hook gets disabled). Eight direct assertions green across both
  hooks and all three tiers, including the fallback still blocking the bypass without python.
  Found while answering "will it work for every user with certainty" - the answer was no until
  this landed.

- **2026-09-07 (v1.3.2) — a guard that existed for weeks and ran nowhere is now shipped, registered and tested.**
  `deny-git-bypass.sh` was written after Fable review #3 to stop `git push --no-verify`,
  `-c core.hooksPath=`, `HUSKY=0`, and the policed env tokens `GOVERNANCE_HOOKS=0` /
  `NO_LOCAL_COMPUTE=0` from skipping the committed pre-commit / pre-push scans — and it sat in the
  live tree **registered in no `settings.json` and absent from the bundle**, so it never ran for
  anyone. A parallel session found it on 2026-09-09; every claim verified before acting. It is now in
  the bundle, registered under `PreToolUse` with its own `Bash|PowerShell` matcher (`no-local-compute`
  is Bash-only, which is the gap this guard closes), covered by a selftest case asserting both
  directions plus the flag-without-a-git-action case, and **it deliberately does not honour
  `GOVERNANCE_HOOKS=0` as a disable** — that token is one of the bypasses it polices. Owner override:
  `DENY_GIT_BYPASS=0`. Added at the same time: a **warning, never a block**, when a repo ships
  `.githooks/` but `core.hooksPath` is not set — the fresh-clone case, where no flag is needed to
  skip the scans because they are simply not wired. Nine direct cases plus the advisory in both
  states, all green. **Stated limit:** it is a regex over the whole command string, so a
  command that merely *mentions* a policed token beside an action verb (an `echo`, a `printf`
  building a fixture) is blocked too - it stopped its own author's test command within minutes
  of going live. Safe direction, loud, override named; kept that way rather than parsing shell.

- **2026-09-07 (v1.3.1) — `no-local-compute.sh` states the limit it hit within an hour of being armed.**
  The marker search starts at the shell's CURRENT directory, and PreToolUse sees that directory
  **before** any `cd` inside the command itself. So `cd /unmarked/project && ./build.sh`, issued
  from a marked project, is judged as still being inside the marked one and is blocked. It fails
  in the safe direction — a false block, never a false allow — and it is loud, so it is now a
  **stated limit in the file** rather than a bug papered over: guessing which `cd` in an arbitrary
  shell command wins is exactly the parsing that makes a gate unreliable, and an unreliable gate
  gets switched off. Move the shell first, in its own call, then run the command.

- **2026-09-07 (v1.3.0) — a negative claim now has a tool behind it, because a filtered search proved nothing.**
  Asked whether a retired tree was safe to delete, a session filtered the machine's Scheduled Tasks
  for one project name, found three, and reported that no vector remained. **Five more existed** —
  one carrying the project's *pre-rebranding* name, so no filter for the current name could ever
  have matched it, and it had been **failing every morning for months** against a script a
  rebranding commit had renamed. The same session asserted "nothing can recreate these" without
  ever searching for scripts that *create* tasks; there were six, and one registered six task names
  by itself. Asked to extract those names by hand it found five of the six — the new tool found all
  six on its first run.
  **`enumerate-before-claiming.sh`** (read-only, operator-invoked) refuses to filter: it lists every
  scheduled task, startup entry and Run key, resolves each target and marks it `ok` / `MISSING` with
  the missing ones first. `--broken` shows only the entries whose target is gone — the line that
  surfaces a job failing in silence. `--creators <dir>` answers *"can it come back?"* by naming the
  scripts that register tasks and the names each registers, and says
  `<name built dynamically — READ THE FILE>` rather than printing nothing, because silence was the
  original bug. Its PowerShell half is a **separate `.ps1` on purpose**: escapes did not survive
  being embedded and written, for the fourth time in one session (#359). Covered by a selftest case
  asserting **both** directions — a tree that registers a task is named, a tree that does not
  reports `none` — since asserting only the first would pass a tool that reports everything.
  Rule written into `GOVERNANCE-AGENT-GUIDE.md` §21 and `CLAUDE.md.template`, so new projects
  inherit it.

- **2026-09-07 (v1.2.3) — the close now notes protected documents that were changed outside the guard.**
  `governance-guard.sh` is registered on `Edit|Write|MultiEdit|NotebookEdit` and not on `Bash`, so a
  protected document rewritten with `python`, `sed` or a heredoc never meets the success-token
  requirement. `close-completeness.sh` now says so once, at `Stop`. **It is built to be
  conservative, because the failure mode to avoid here is a false alarm, not a miss** — a noisy
  check gets switched off, and this framework has lost controls that way before. It warns and never
  blocks (a blocking close-gate is what caused the 2026-09-06 deadlock); with no session-start
  marker it checks nothing and says so, rather than guessing a window; it subtracts anything the
  PostToolUse change log recorded, so an edit that did pass a guarded tool is never reported; and
  the message names `git pull`, a rebase and a parallel session as ordinary explanations, because
  they produce the same signal. It is a note for the human, not an accusation. Four cases proven:
  silent with no marker, silent with no change, names a shell-written edit, silent again once that
  same file is recorded in the change log. Selftest `pass=157 fail=0 uncovered=0`.

- **2026-09-07 (v1.2.2) — the copy diff now runs at every session close, because a Bash-written edit syncs nowhere.**
  `sync-governance-copies.sh` is registered on `Edit|Write|MultiEdit|NotebookEdit` and **not on
  `Bash`**. A session that edits a governance file with `python`, `sed` or a heredoc therefore
  triggers no sync at all: the edit never reaches the installer bundle, never enters the push
  queue, and is silently lost at the next `install.sh --force`. That — not a leak — is the real
  cost of the gap; `end-session.sh` scans the STAGED SET before pushing and the repo's own
  `pre-commit`/`pre-push` gates scan too, so nothing reaches GitHub unscanned however it was
  written. `close-completeness.sh` now diffs the live hooks against the bundle at every `Stop` and
  names any file that diverged. It **warns without blocking**, because which side is right is a
  human decision. One diff, measured at 2.4 s — deliberately not a PII scan after every shell
  command, which would cost hundreds of runs a session, and *a slow gate gets switched off*.
  Proven in both directions with a planted divergence; it caught two real ones while being written.

- **2026-09-07 (v1.2.1) — the v1.1.7 governance-plumbing exemption never worked, and only a test found it.**
  `no-local-compute.sh` ends its exemption pattern with a word boundary. The two characters were
  consumed when the file was written on 2026-09-06 and landed as a **single 0x08 backspace byte**,
  so the alternation could never match and the hook kept blocking the governance scripts the
  exemption was added to permit — the owner-approved fix was inert from the day it shipped. It was
  found because this release gave the hook its first test case: it was the selftest's only
  UNCOVERED hook, and a registered hook with no case is not green, it is unverified. Four cases now
  cover it (block project compute · allow it unmarked · allow `ssh` · allow governance plumbing).
  **The same escape-eating bit three times in one session** — a lost `sed` capture group, a
  swallowed `tr` argument, and this byte — including the first attempt to repair this very line,
  which replaced the byte with itself. Build such literals from character codes and verify by
  executing, never by reading. Selftest `pass=157 fail=0 uncovered=0`.

- **2026-09-07 (v1.2.0) — the copy-parity check is now an assertion, and publishing asks first.**
  Three things closed. **(1)** `governance-selftest.sh` now asserts that every hook the installer
  bundle carries is byte-identical to the live copy, and goes RED when they diverge. This is the
  only check that catches an identity with no shape - it is what found the leaked group name on
  2026-09-01, gotcha #350 recommended asserting it here, and until now it was a thing a human had
  to remember to run. An absent root or zero shared files is a FAILURE, not a pass: a comparison
  with nothing to compare is not agreement. It found a real divergence on its first run.
  **(2)** The end-of-session push to the PUBLIC repo now requires `GOV_PUBLISH=1`. The flag it used
  to trust is seeded automatically by *any* governance edit, so it only ever meant "something
  changed", never "publish this" - and twice, unreviewed content reached GitHub down that path
  (#347, #358). Without the variable the session ends normally, the queue is **preserved** and its
  files are named. The pipe is kept and simply asks first; this is not the "kill the auto-push"
  proposal that was correctly rejected on 2026-09-01. **(3)** The hooks table is regenerated from
  `bundle/settings-hooks.json`: 18 registered scripts, up from a 9-row table under a heading that
  claimed 11. Seven active hooks had never been documented at all.

- **2026-09-07 — a project's own `.claude/docs/` could publish itself, and the sync now says so.**
  Every branch of `sync-governance-copies.sh` rebuilds its source from `$HOME` except one: the
  docs branch copied **the edited file itself** into the publishable bundle. So a
  `.claude/docs/*.md` inside ANY project checkout would have crossed into the public artifact. It
  now requires the `$HOME` copy explicitly, proven in both directions with a planted project file.
  The comparison needed a path normaliser, because the hook payload gives `C:/Users/<user>/...` while
  every `$HOME`-built path is `/c/Users/<user>/...` and a raw compare would have refused every legitimate
  edit. That normaliser is written in pure shell with **no sed backreference and no backslash
  literal**: the first version lost its escaped capture group in transit and failed in the
  looks-correct direction, silently dropping the drive letter so that the HOME path compared as
  foreign. Editing a project's governance (`docs/context/`, `Plans/`, `MDs/`, its `CLAUDE.md`) was
  never in scope - none of it lives under `.claude/`.

- **2026-09-07 — the private-to-public pipe is closed by construction, not by detection.**
  Five skills shipped in `bundle/skills/` that `install.sh` never installed - `wa-cc-bridge`,
  `wa-cc-poll`, `whatsapp`, `whatsapp-checkpoints`, `end-session`. They are machine- and
  deployment-specific tooling carrying group names, server addresses, operator phones and client
  names, and `sync-governance-copies.sh` copied them into the bundle on every edit. That is the
  pipe, and every leak this repo has had came down it. They are removed, and a **never-distribute
  block sits at the private->public crossing itself** - deleting the directories is not enough,
  because `_bundle_copy` does `mkdir -p` and the next edit recreates the path. Proven in both
  directions: a `wa-cc-bridge` edit is refused and leaves no bundle directory, a `bootstrapper`
  edit still syncs. `bundle/skills/` held exactly the 14 skills the installer installed at the time
  of this entry — 15 as of v1.4.0, when `pr-follow-through` joined core (see that entry; the count
  is left as it stood rather than rewritten, because a changelog records what was true then).
  Overridable with `GOV_NEVER_DISTRIBUTE_SKILLS`. The class this closes is the one no scanner can
  close: an identity with no shape (a group name, a client name) is invisible to every rule, so the
  fix is to stop the file carrying it from reaching the public artifact at all.

- **2026-09-07 — a real WhatsApp group name is gone from the bundle, sanitised at the SOURCE.**
  The name was an identity with no shape: not phone-, path- or token-shaped, so the 20-rule
  scanner scored it 0 and it survived four sanitisation rounds and five certifications (gotcha
  #350). It is replaced by the `Ops-Group` placeholder `check-no-pii.sh` already uses, in **all
  three copies at once** — live, installer bundle, repo — because the sync direction is
  live -> installer -> repo, so a repo cleaned while its upstream stays dirty is clean only until
  the next edit. Verified safe before the swap: the group JID is read from a gitignored local
  config rather than from this label, and nothing branches on the value (the only equality tests
  in the bridge are on `Slack-Bridge`). `wa-monitor.test.js` passes 50/50; the two failing suites
  fail identically with the old and the new label, so they are pre-existing. The same commit syncs
  `no-local-compute.sh`, whose live copy carried a governance-plumbing exemption the bundle lacked,
  and drops an owner first-name reference from its comment — a name the denylist deliberately
  excludes, since a two-letter name matched case-insensitively fires on every English "or".

- **2026-08-25 — the framework can now tell a machine it is out of date, and a next-session
  handover has a fixed name.** Three PRs. **#4** added `bundle/docs/NEXT-SESSION-HANDOVER.md`, the
  renderer spec for a goal-scoped continuation prompt (`/goal` + `/loop`, the context-limit
  exception, and the rule that `/loop` suppresses status-report stops **only** — never a governance
  safety stop). **#5** made `docs/context/NEXT-SESSION-PROMPT.md` canonical: every governed project
  already kept such a file, under three names in three locations, because `init-governance` never
  scaffolded one. **#6** added `bundle/VERSION`, an install-time marker at
  `~/.claude/.governance-version`, and a SessionStart advisory that reports a published update —
  **advising, never installing**, because `install.sh` replaces the hooks and skills that are
  running at that moment. §19 (public-repository hygiene) was also finally written; three files had
  referenced it for months without it existing.
  **Seven review rounds, 33 findings — and five of the seven found defects introduced by the
  previous round's fixes.** Four of those were tests that could not fail: a timing threshold above
  the timeout it measured, a cleanup routine gated out of ever running, a fixture whose `printf`
  collapsed twelve inputs into one, and an agreement check that became a tautology after a
  refactor. Two "verified" claims were measured wrong — `$?` read from a `tail` in a pipe, and a
  494 ms per-session regression dismissed as noise from a single unpaired sample.
  **None of the serious findings was a crash.** They were plausible wrong answers: a newline-less
  version file reading as empty so an up-to-date machine nagged forever; two readers disagreeing
  about what "the version in the file" is, one of them concatenating a two-line file into a token
  that *passed* validation; a partially failed install deleting a valid marker unbacked; a preview
  printing the opposite of the real run; and a network-fetched value validated with a glob, so
  arbitrary text after `1.9.9` was echoed into the agent's context. Details and the reusable
  lessons: `PARALLEL-SESSION-NOTES/2026-08-25-goal-scoped-continuation-review-notes.md`.

- **2026-08-18 — the last four hooks are wired, and the "hanging" test was two of my own defects.**
  `plan-gate.sh` and `parallel-import.sh` (UserPromptSubmit, advisory) and `pre-done.sh`
  (TaskCompleted, **blocking**) are now registered, alongside `canonical-cwd-check.sh` and
  `sync-governance-copies.sh` from earlier. Nothing in the framework runs unregistered any more.
  **`pre-done.sh` genuinely blocks** — exit 2 when a session has tracked changes and no fresh
  success token — and it now sees far more changes than it ever did, because the `$PWD` fix stopped
  discarding them. Expect it to fire.
  `hooks/wa-bridge-claim-check.test.js` was reported as hanging with no output. It was not hanging:
  `fs.cpSync` cloned the ENTIRE skill directory per test, which by then included `agent/node_modules`
  and a `.bak-*` backup someone had left inside it — hundreds of megabytes for a three-file fixture.
  It took 33s and then failed at file level with no test output, which reads as "hung" rather than
  "too slow". Second defect in the same file: the fixture still wrote the retired machine-wide
  presence filename while the hook had moved to per-project claims, so it asserted against a state
  production can no longer produce. Both fixed — the copy is filtered, the fixture uses
  `presencePath(home, cwd)` — and the suite is 11/11 in 10s. Backups were also moved out of
  `~/.claude/skills/`: anything that walks or copies a skill directory picks them up.
  **Lesson worth keeping:** "hangs with no output" was neither a hang nor an outage, and the tool
  that mattered was `--test-reporter=spec`, which showed a file-level failure where plain output
  showed nothing at all.

- **2026-08-18 — PRIVATE DATA REMOVED FROM THE WHOLE BUNDLE, not just the incident note.** Sweeping
  the repository after sanitising one note turned up far more than project names: **two real
  people's personal phone numbers**, a real WhatsApp group JID, real Slack channel and user IDs, a
  WhatsApp LID, and a contributor's name in a fixture — across 18 files, in a PUBLIC repository. All
  replaced with placeholders matching the fixture convention already in use (`972500000000`).
  Three were **functional defaults**, and each needed a decision rather than a substitution:
  `remind-teammate.js` hardcoded a person's number as its recipient fallback — it now requires
  `TEAMMATE_WA_JID` and exits 2 with a clear message, because a placeholder number would either
  fail silently or reach whoever really owns it (the file, that variable and the script's log
  prefix all still carried the teammate's own first name until **2026-09-01**, when they were
  renamed — a filename is published exactly as widely as a line of code, so the name was the leak
  and the mechanism was fine); `wa-live-agent.mjs` and `react.js` defaulted to one machine's
  checkout path, now environment-only. The mirror roots in `sync-governance-copies.sh`
  became configuration (`~/.claude/.governance-mirrors`, machine-local, never shipped) instead of
  two hardcoded private paths — which also makes the hook usable by anyone else for the first time.
  **Two test failures were caused by the cleanup and both were worth having:** `spawn` raises ENOENT
  when its `cwd` does not exist, so renaming a project path broke a suite in a way that presented as
  a missing node binary — fixed properly, the test now creates its own temp directory instead of
  depending on the author's directory layout. The second asserted the agent must carry a default
  Slack sender path; that was the old contract, but it guarded a REAL property — a 2026-07-25
  incident where Slack replies were dropped **silently** because the path did not resolve. Deleting
  the assertion would have thrown that away, so the property was preserved in a new form: an unset
  or missing sender is logged loudly and the reply refused, never spawned with an empty path.
  Verified after cleanup: 10 bridge suites (143 assertions) and 3 governance suites (43) all green,
  plus a syntax check of every modified shell and JS file.
  **Still open, stated rather than glossed:** `hooks/wa-bridge-claim-check.test.js` hangs with no
  output; the hook it covers exits 0 cleanly when driven directly, so the fault appears to be in
  that test harness — but both files were touched here, so it is not attributed.
  **None of this removes anything from history.** The repository is public: treat previously pushed
  values as disclosed, and rotate anything that was a credential.

- **2026-08-18 — this repo is PUBLIC; the incident note is sanitised and the rule is written down
  (Agent Guide §19).** A handoff note filed here by a session working in a private project carried
  that project's name (in the filename and throughout the body), absolute local paths including the
  machine's user directory, session UUIDs, and commit hashes from a private repository. The intent
  was right — the framework belongs to no project, so a note about the framework belongs here — but
  it was written **about the session** rather than **about the framework**. Rewritten generically
  (Project A/B, Session 1/2, `~/.claude/…` paths), keeping every technical finding, and renamed.
  §19 states the rule, lists what must never be committed, and gives a pre-push grep.
  **Note that a rewrite does not remove anything from history, and the repo is public** — treat
  previously pushed content as disclosed and rotate anything that was a credential.
  **The same leak exists in ~17 other files** (hardcoded mirror paths in `sync-governance-copies.sh`,
  test fixtures, `skills/full-finish`); that is a separate job, since the hardcoded paths need to
  become configuration rather than a find-and-replace.
  Also shipped: `canonical-cwd-check.sh` (SessionStart) and `sync-governance-copies.sh`
  (PostToolUse) added to `bundle/settings-hooks.json`, so a fresh install actually wires them —
  `canonical-cwd-check.sh` had never been registered anywhere despite project docs describing it as
  an active guard.
- **2026-08-17 — the `$PWD` pattern is gone from all seven hooks.** The remaining four
  (`canonical-cwd-check.sh`, `plan-gate.sh`, `parallel-import.sh`, `pre-done.sh`) now resolve the
  project from the payload as well. `canonical-cwd-check.sh` needed its own treatment: it is
  deliberately **standalone** — kill switch only, no `_common.sh` — so that it still works when the
  rest of the framework does not, and that property was worth preserving, so it extracts the
  payload `cwd` inline instead of gaining a dependency. It is also the one hook where drift is
  worse than a lost record: it asks *"is this session sitting on the canonical copy?"*, so judging
  the wrong directory either cries wolf or — far worse — stays **silent while the session really is
  on a stale duplicate**, which is the failure that already cost this toolchain a corrupted
  cloud-synced `.git` once. Tests 9-11 pin all three of its signals: no false alarm from outside the
  project, the wrong-copy warning still fires, and the tombstone is found via the session's
  directory. Suite now 11/11; `test-session-state.sh` unchanged at 23/23.
  **Four of these seven still run nowhere** — see the entry below. Anchoring them is what makes
  wiring them a one-line decision later instead of a fix-then-wire project.
- **2026-08-17 — `pre-session.sh` / `pre-task.sh` anchored too, and an audit of which hooks are
  actually wired.** Same `$PWD` defect as §18, in the two hooks that gate the *start* of everything:
  from a directory holding a `CLAUDE.md` but no manifest — the exact shape of `~/.claude` —
  `pre-session.sh` announced *"Ungoverned project detected. Run `/init-governance` NOW"* about a
  fully governed repo, and `pre-task.sh` skipped enforcement outright. Both now call the new
  `gov_prime_payload`, which reads stdin **once**, exports the cache so subshells stop re-reading a
  drained stream (`gov_state_file` was consuming the payload inside `$( )`, leaving every later
  read empty), and resolves `GOV_PROJECT_ROOT`. Tests 6-8 in `tests/test-payload-root.sh`, incl. the
  negative control that an ungoverned directory is still called ungoverned.
  **The audit is the bigger finding:** of the seven hooks carrying this pattern, only
  `pre-session.sh` and `pre-task.sh` are registered on any event at all. `canonical-cwd-check.sh`,
  `plan-gate.sh`, `parallel-import.sh` and `pre-done.sh` **run nowhere** — every `settings.json`
  mention of them is a permissions-allowlist line, and `pre-done.sh` appears in `post-milestone.sh`
  only inside a comment. `canonical-cwd-check.sh` is the guard against working on a stale duplicate
  copy, and project docs describe it as enforcing that invariant at SessionStart; it does not.
  Wiring them is a behaviour change, not a bug fix, so it is left as an explicit decision.
- **2026-08-17 — `sync-governance-copies.sh` mirrors, it never RESURRECTS; and it is finally wired.**
  The script was written to keep the 4 copies of the governance code in step, but it **was never
  registered as a hook** — the only mention of it in `settings.json` was a permissions allowlist
  line. It had therefore never run once, which is why the mirrors drift. Before wiring it up, two
  `mkdir -p` calls had to go: the skills targets (and the client-repo hooks target) created the
  destination when it was absent, so editing any user-level skill would have **re-created shadow
  copies that had been deliberately deleted** — on 2026-08-17 three of them (`wa-cc-bridge`,
  `whatsapp`, `wa-cc-poll`) were removed from two repos precisely because a project-level
  `.claude/skills/<x>` shadows the user-level original, and two had already drifted. A deletion is a
  decision; an auto-sync that silently undoes it is the defect class this framework exists to catch.
  Now: refresh a mirror that exists, leave a removed one removed. The gate is the individual skill's
  directory, not the `skills/` root, so an existing root cannot smuggle in a new shadow copy.
  Register it on `PostToolUse` (`Edit|Write|MultiEdit|NotebookEdit`) alongside `post-milestone.sh`.
- **2026-08-17 — hooks judge the project of the EDIT, not their own `$PWD` (Agent Guide §18).**
  Writes made while a session's shell stood outside the project root were **silently dropped** from
  the session change log. Two independent `$PWD` dependencies in `post-milestone.sh`: a relative
  `[ ! -f "docs/context/CONTEXT-MANIFEST.md" ]` test, and `gov_role_guard SOURCE` →
  `gov_detect_role` → `gov_find_project_root`, whose upward walk finds the **user-level**
  `~/.claude/CLAUDE.md`, calls it "the project", sees no `.git` beside it and reports `DEPLOYMENT`.
  Running a test suite out of `~/.claude/skills/<x>` was enough to trigger both. Visible symptom was
  a false BLOCK at close ("HANDOFF.md was not refreshed" when it had been); the dangerous direction
  is the inverse — the same omission under-counts `SESSION_WRITES`, and `end-session.sh` only fires
  at `>= 3`, so **a session could close with no handoff and the gate would stay quiet**. New
  `gov_payload_root <payload>` + `gov_is_governed <root>` in `_common.sh` resolve the project from
  the hook payload (`cwd` → `file_path` → `$PWD` walk, with a regex fallback when strict JSON
  parsing fails), and `gov_detect_role` now honours `GOV_PROJECT_ROOT`. Regression test:
  `tests/test-payload-root.sh` (5 checks, incl. a negative control that an ungoverned edit is still
  skipped). **Still carrying the same pattern and NOT changed here:** `parallel-import.sh:17`,
  `plan-gate.sh:24`, `pre-done.sh:19`, `pre-session.sh:183,186`, `pre-task.sh:33,39`,
  `canonical-cwd-check.sh:56` — each gates a different lifecycle stage and needs its own test
  before being touched.
- **2026-08-16 — session-scoped state (Agent Guide §17).** Per-session state dirs
  (`~/.claude/logs/sessions/<sid>/`), crash-vs-parallel detection at SessionStart, `GOV_DRY_RUN=1`
  for every state-mutating hook, `_common.sh` primes the stdin payload once (`gov_hook_input`),
  `sync-governance-copies.sh` mirrors `docs/*.md`, `end-session.sh` pulls (`--rebase`) before pushing
  and stages only the queued files, drift advisory live-vs-bundle, sandbox test harness (23 checks).
- **2026-08-15 — parallel-session awareness (Agent Guide §16).** Detection signals + git rules
  when two Claude sessions share one working tree; `pre-session.sh` 3-way union.
