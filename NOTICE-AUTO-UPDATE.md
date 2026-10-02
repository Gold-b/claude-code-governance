# Updates and other unattended steps — full disclosure and terms

> **DRAFT — not yet in force.** These terms apply from release 2.0.0. On the unreleased master
> branch the code already behaves as described here: this version has no automatic update, and
> push at session close is OFF unless you turn it on — except on a machine that has a file named
> `~/.claude/.governance-source`, where it is ON without asking (section 10.3).

This document tells you, in plain language, what the Context Governance framework does on your
machine without asking you each time — its version check, its push at session close and its other
unattended steps — and what its update path does when you run it yourself; what it protects you
from, what it does **not** protect you from, and the terms you accept: by installing it (section
10.1) and, separately, by turning push at session close on (section 10.3). Read it before you type
`I ACCEPT`.

This framework is independent. It is not affiliated with or endorsed by Anthropic; "Claude" and
"Claude Code" are Anthropic's trademarks.

`~` below means your home directory. `~/.claude` is the Claude Code configuration directory in it.

---

## 1. In one paragraph

This version of the framework does **not** update itself, and has no setting that makes it do so.
At the start of a Claude Code session it checks (at most every 12 hours) whether a newer version
has been published and, if so, tells you. You update by hand, by your own act: either `git pull` in
your clone and `bash install.sh --force`, or the signed path —
`bash ~/.claude/hooks/governance/gov-update.sh --fetch <version>` (downloads the tagged release,
checks the maintainer's signature and every file, prepares it) and then, with every Claude Code
session closed, `bash ~/.claude/hooks/governance/gov-update.sh --apply --force-live`. Apart from the
version check — a small text file with the published version number (section 3) — nothing is
downloaded, and nothing is installed, unless you run one of those. A release whose terms changed
prepares nothing before you accept them (section 10.4). You can roll back the last update
(section 9).

---

## 2. What runs, and when

One hook and one script you run yourself. `pre-session.sh`, which Claude Code runs at the start of
every session (the `SessionStart` event), checks for a new version (item 1) and restores an install
that was cut off (item 4). `gov-update.sh` is registered on no hook event; `pre-session.sh` calls it
with `--recover-detached` — the restore of an install that was cut off (item 4) — and with nothing
else; it downloads (`--fetch`) and installs (`--apply`) only when you run it. Apart from the
version check (item 1) and the restore of an install that was cut off (item 4), they download and
install nothing unless you run the commands in item 2 and 3 yourself.

1. **Version check (existing behaviour).** `pre-session.sh` compares the version you have
   installed (`~/.claude/.governance-version`) with the version published in the repository. The
   answer is cached for 12 hours; the network request runs detached in the background, so the
   session never waits for it.
2. **The signed manual update, when YOU run `--fetch`.**
   `bash ~/.claude/hooks/governance/gov-update.sh --fetch <version>` downloads, verifies and
   prepares that release (section 4), in your terminal. It changes nothing outside its own working
   folder (section 5); the next session start tells you that the release is ready. Every `--fetch`
   ends with one `[GOVERNANCE UPDATE]` line in your terminal that says what happened: the release
   was staged, held for its terms, or halted (with the reason); the request was refused, and why
   (an archive address that is not `https://`, the release source machine, not a version number,
   not newer than what you have installed, governance or the update check switched off); or no
   download was made, and why (the release is already staged, 10 attempts were already made, the
   last attempt was less than an hour ago, another update is running, the release tag was not
   found, a network failure). The limits named are the defaults. The same event is also written
   to `~/.claude/logs/governance-update.log`. As part of that
   verification it runs two of the release's own self-checks, so downloaded code — after its
   signature and checksums have been verified — runs on your machine, **with your user
   privileges**, in a temporary folder that stands in for your home folder. That folder is not a
   security sandbox. A release whose terms changed runs none of its code before you accept the new
   terms (section 10.4).
3. **Install, when YOU run `--apply`.** `bash ~/.claude/hooks/governance/gov-update.sh --apply`
   installs the release that `--fetch` prepared, in your terminal. It installs only when **all** of
   these hold:
   - no other Claude Code session of yours has been active in the last 10 minutes (otherwise it
     does not install and says so; a session counts as active for 10 minutes after its last
     activity, so once you have closed every session, add `--force-live`);
   - none of the installed framework files were modified by you since the last install
     (otherwise it refuses and names the files, at most five of them). Two exceptions: with no
     local-modification baseline on the machine it applies without that check once and says so;
     `GOV_UPDATE_OVERWRITE_LOCAL=1` overrides the check (the modified files go to the backup);
   - you have accepted the terms of that release (a release whose terms changed is never
     installed before you accept them; section 10.4).

   The install normally takes 20-40 seconds. It aborts on its own and restores the previous state
   if it runs past its time limit (10 minutes for the file changes, 20 seconds more for the final
   check — where the `timeout` command exists; on stock macOS the final check runs unbounded). Its
   result — which version was applied, where the backup is, how to roll back, or why nothing was
   installed — is printed in your terminal and written to the log. A refusal is printed too:
   another update process holding the lock, a halted version, the release source machine, a
   version already installed.
4. **An install that was cut off.** If the install is interrupted part-way (for example, the
   computer is shut down or the terminal is closed while `--apply` runs), the next session start
   begins restoring the backup in the background, and says so; nothing new is installed at that
   moment. The restore runs detached, with low priority, without four token variables in its
   environment (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`; every other
   variable of the session is passed on), and — where the system has the `timeout` command (Git
   Bash, Linux; not stock macOS) — is stopped after at most 10 minutes. Its result is **shown at
   the start of your next session**. An install that was cut off, or ran out of time, can be tried
   again by hand (`--apply`): three attempts in all, and after the third failed one that version is
   blocked until you clear it (section 9).
5. **Nothing else.** No new scheduled task, service, cron entry or background daemon is added.
   Nothing starts on its own while Claude Code is not running. The restore of item 4 keeps running
   after Claude Code has closed: usually under a minute, at most 10 minutes where `timeout` exists.

---

## 2a. What else the framework does without asking you each time

The steps below are carried out by Claude Code — an AI — following the framework's hooks and
skills, under your user account. An AI's behaviour is not fully predictable; the limits described
here are the framework's own checks, not guarantees.

**(a) Push at session close — OFF unless you turn it on (section 10.3, which also states the one
exception).**
Whether or not it is on, when a session in a governed project closes, the session commits the files
that session wrote to the current repository, under your git identity. When push at session close is
on, `close-push.sh` then pushes the current branch to its existing upstream of the same name — every
commit of that branch the upstream does not have yet, including commits you made yourself and never
pushed, not only the closing session's. It fetches first and pushes only a fast-forward: it never
forces, never rebases, never creates or deletes a branch, and never pushes tags or submodules. It
does not push — and says why — when the repository is public, when its visibility cannot be read
(any host other than `github.com`, or `gh` missing or failing), or when it is visible to a whole
organisation; when the pushed commit contains
a CI or deployment configuration file from the script's list; when the remote is a local repository
that runs receive hooks or updates its working tree on a push; when the remote has a separate push
URL or several URLs, or is a mirror;
when the branch has no upstream of the same name, was deleted on the remote, or is behind it; when
another close holds the lock; in the framework's own repository; and when the project's
`docs/context/CONTEXT-MANIFEST.md` says `close_push: off`. The owner of a repository can lift the
public, unknown-visibility, organisation, CI and local-hook holds for it by putting `close_push: on`
in the manifest on the remote. Before pushing, it scans the outgoing commits, their messages and
their file names for common secret formats and, when the remote is not known to be private, with the
framework's personal-data scanner; if a scan cannot run, nothing is pushed. For a `github.com`
remote it asks GitHub, with your `gh` login, whether the repository is public or private.

**What this does not protect you from.** The list of holds is not complete: a hosting service
connected through its own dashboard, with no file in the repository, can deploy on a push. The
secret scan recognises common token formats only — not passwords, personal data, client data or
other confidential content. The personal-data scanner recognises fixed shapes — some phone-number
formats, email addresses, IP addresses, home-folder and other file paths, chat, document and
WhatsApp ids, tunnel host names, common token formats and name attributions such as
`Author: <name>` — and the names you listed in `~/.claude/.pii-names` (none when that file is
empty). A name you did not list, client data and other confidential content can pass it. Everyone
who can access the remote — including collaborators on a private
repository — can see what was pushed. A push cannot be taken back once someone has fetched it.

Turn it off: `bash ~/.claude/hooks/governance/close-push.sh --disable`. On a machine that has the
file named in section 10.3, `--disable` alone does not turn it off: run it and also delete that
file — deleting the file alone turns push off only when no `y` is recorded under the current terms.
Pause it: `GOV_CLOSE_PUSH=0` (environment, or a line in `~/.claude/.governance-local.env`). One
project: `close_push: off`.

**(b) The session-start gate — on in governed projects.** `bootstrap-gate.sh` blocks file edits and
some outward shell commands — for example `git commit`, `git push`, `scp`, `rsync`, starting or
stopping services, WhatsApp sends — in a governed project (except on nodes marked as deployment or
frozen) until the `bootstrapper` skill has run in that session. If the gate itself fails, it lets the
action through and logs a warning. Off: `GOV_BOOTSTRAP_GATE=0`.

**(c) Updates to the framework's own context files — on in governed projects.** Sessions write the
framework's context files in your governed projects (`docs/context/`, `Plans/`, memory and handoff
files) without asking you. When two of those files contradict each other, the session decides by
evidence, then recency, then rank, and quotes the losing text in the file's change log. It changes
only status fields, frontmatter, manifest rows, change logs and superseded blocks — never a rule —
and it still asks you before anything destructive, a deployment, a change to live configuration, or
anything involving a secret. When push at session close is on, these files are part of what is
committed and pushed. Restore asking: `GOV_CANONICAL_AUTORESOLVE=0`.

**(d) Pull-request checks — when `gh` is installed and signed in.** A hook asks GitHub, with your
`gh` login, whether you have open pull requests in the current repository and, if you do, asks the
session to start a watcher for them. Reminders to reviewers — on Slack and on the pull request,
about every 3 hours in working hours, in your name — are sent only if you configured reviewers and
channels in `~/.claude/pr-follow-through/config.local.json`. Off: `GOV_PR_WATCH=0`.

**(e) Notifications — only if you run an OpenClaw WhatsApp gateway on this machine.** When a gateway
token and a phone number are configured (under `~/.openclaw/`, in `~/.claude/.wa-bridge.json`, or in
`WA_PHONE`), some hooks send short governance notices through that gateway, at `127.0.0.1`, to that
WhatsApp number. Without that configuration nothing is sent.

**(f) Publishing framework edits — only with `GOV_PUBLISH=1`.** For people who maintain a copy of
this framework: a session end can push edits of the framework's own files to the framework's
repository. Nothing is published without that setting.

---

## 3. What is sent over the network, and where

- **The version check — on every installation, unless you turn it off.** At most once every 12
  hours `pre-session.sh` downloads the published version number from the repository's `master`
  branch: `https://raw.githubusercontent.com/Gold-b/claude-code-governance/master/bundle/VERSION`.
  Off: `GOVERNANCE_UPDATE_CHECK=0`.
- **The release — only when you run `gov-update.sh --fetch <version>` yourself.** Only as a
  **tagged** archive, never the `master` branch:
  `https://github.com/Gold-b/claude-code-governance/archive/refs/tags/v<version>.tar.gz`
  GitHub may redirect this request to `codeload.github.com`. Only HTTPS is allowed, including on
  the redirect. Downloads larger than 20 MiB are refused.
- **Push at session close — only when it is on: you turned it on, or the machine has the file
  named in section 10.3.** `git fetch` and `git push` to your own
  remote, with your own credentials, carrying every commit of the current branch that the remote
  does not have yet — the closing session's commits and any earlier commit of yours on that branch
  that was never pushed; and, for a
  `github.com` remote, one question to GitHub, with your `gh` login, whether the repository is
  public or private (section 2a (a)).
- **Pull-request checks — only when `gh` is installed and signed in** (section 2a (d)).
- **Notifications — only when you run an OpenClaw WhatsApp gateway on this machine** (section 2a (e)).
- **Publishing framework edits — only with `GOV_PUBLISH=1`:** `git pull --rebase` and `git push` to
  the framework's repository (section 2a (f)).

**Nothing is sent to the maintainer.** The framework has no telemetry, analytics or crash reporting.
The requests above go to GitHub and to the remotes and services you use, which see what any such
request shows them — for example your IP address and, for a request made with your login, your
account. The framework's logs (`~/.claude/logs/`), its state (`~/.claude/.governance-update/`) and its
backups stay on your machine.

---

## 4. What is verified before anything is installed

A downloaded release is rejected, and that version is blocked from further attempts, unless
**every** one of these checks passes:

1. **Archive safety.** The archive has exactly one top folder; no entry is an absolute path or
   contains `../`.
2. **Signature.** The release carries a file list, `RELEASE-MANIFEST`, and its signature,
   `RELEASE-MANIFEST.sig`. The signature must verify, with `ssh-keygen -Y verify`, under the
   **release public key pinned on your machine** at `~/.claude/.governance-update/allowed_signers`,
   within that key's validity dates. There is no fallback to an unverified install: if your system
   cannot verify SSH signatures, the update is refused.
3. **Version.** The signed version must equal the version requested and be strictly newer than the
   one installed. Downgrades are refused.
4. **Every file's checksum.** The SHA-256 of every file in the archive must match the signed list.
5. **The exact file set.** The archive must contain exactly the files in the signed list — no
   file missing, no extra file anywhere.
6. **Install-map safety.** Every destination must be a relative path inside `~/.claude/hooks`,
   `~/.claude/skills`, `~/.claude/docs` or `~/.claude/agents`, with no `..`.
7. **Syntax checks.** Every shell script is checked with `bash -n` and every JavaScript file with
   `node --check` (when `node` is installed; without it the JavaScript check is skipped).
8. **Self-checks.** Two of the release's own self-tests run, only after checks 1-7 have passed, in a
   temporary folder that stands in for your home folder. They run with your user privileges; the
   temporary folder is **not** a security sandbox.

The prepared release is verified again (steps 2, 4, 5, 6) immediately before it is installed.

The release public key's fingerprint is:

```
SHA256:mm0V5Ieg0cSy6BDjSwOQ4boTjsWnNthw6j1/LqeKzy4
```

It is also printed in `README.md` (section "Release signing key"), by `install.sh` when it pins
the key, and by `gov-update.sh --status`. Compare them.

---

## 5. What the updater writes, and where

All locations are inside `~/.claude`:

- `~/.claude/.governance-update/` — the updater's own state:
  - `allowed_signers` — the pinned release public key(s);
  - `installed.manifest` — the signed file list of what is installed (or a marked-unsigned one
    after a manual install of an unreleased snapshot);
  - `installed.hashes` — the checksum of every installed file as written, used to detect your own
    local changes;
  - `settings-hooks.installed.json` — the hook template last applied, used to recognise which
    `settings.json` entries belong to the framework;
  - `install-mode` — full or core-only install;
  - `terms-accepted`, `close-push` — your two recorded choices: whether you accepted these terms,
    and turned push at session close on or off; each with the terms version, the date and time,
    how you made the choice, and checksums of this file and of the exact text you were shown
    (section 10.5);
  - `dl/` — downloaded archives;
  - `staged/` — one verified release waiting to be installed (or held until you accept its terms);
  - `READY`, `APPLYING`, `HALT-<version>`, `HELD-TERMS-<version>`, `fetch-attempts-<version>`,
    `deferrals` — small status files (a release is ready; an install is in progress; a version is
    blocked; a release waits for you to accept its terms; retry and deferral counters);
  - `REPORT` — the result of the last background restore (section 2, item 4), shown once at your
    next session start and then emptied (trimmed to its last 50 lines before each new one);
  - `retry-<version>` — how many times an install of that version was cut off or ran out of time;
  - `apply-slow` — how many installs in a row stopped, before changing anything, because the
    machine was too busy; `fetch-404-<version>` — how many times that version's tag was not found;
    `.no-baseline-noted` — that the one install without a local-modification baseline happened
    (section 2, item 3);
  - `restore.<pid>/`, `prep.<pid>/`, `gi-prep.<pid>/` — working folders of a restore and of an
    install in progress, removed when it ends;
  - `lock.d/` — a lock so that only one process updates at a time, and `lock.break.d/`, used for a
    moment while a lock left by a process that died is removed.
- `~/.claude/backups/governance-update-<timestamp>/` — a complete backup of every file an update
  replaces or removes, taken **before** the first file is replaced.
- `~/.claude/logs/governance-update.log` — one line per decision the updater makes.
- The framework's own files, as listed in the signed release:
  - `~/.claude/hooks/` (the framework's hook scripts, and `~/.claude/hooks/governance-terms/`: a copy
    of these terms and of their version number, put there by every install; the push-at-close check
    reads the version number from it),
  - `~/.claude/skills/` (the framework's skills),
  - `~/.claude/docs/` (the framework's guides),
  - `~/.claude/agents/` (the framework's agent definitions).
  Framework files that a new release no longer ships are deleted (after being backed up). No
  other file in these folders is touched.
- `~/.claude/settings.json` — **only the hook entries that belong to the framework** are replaced.
  Every other entry and setting is kept as it was, and the file is not rewritten at all when
  nothing changes.
- `~/.claude/.governance-version` — the installed version number.
- `~/.claude/governance-installer/` — refreshed with the new release, **only if that folder
  already exists** on your machine.

---

## 6. What the updater never touches

- `CLAUDE.md` — your global instructions file. (The installer creates it from a template only when
  you have none; nothing ever overwrites it.)
- `~/.claude/.governance-local.env` — your machine-local values. The updater only *reads* its
  on/off switches from it, line by line; it never executes it and never writes it.
- `~/.claude/.pii-names` — your machine-local name list.
- Your own entries in `~/.claude/settings.json` (permissions, environment, model, your own hooks,
  and every other setting that is not a framework hook entry). A hook entry counts as the
  framework's own — and is replaced by the release's version — when its command is one the
  framework itself registered (now or in the release installed before), or when its command points
  into `~/.claude/hooks/governance/` or at `~/.claude/hooks/check-full-finish.sh`. If you added a
  hook entry of your own that runs a script inside `~/.claude/hooks/governance/`, it is treated as
  the framework's and does not survive an update; put your own scripts elsewhere.
- Your own files anywhere, including your own hooks, skills, docs and agents. If a release adds a
  file at a path where you already have a file of your own with different content, the update is
  not applied and the path is named. Two exceptions: on a machine with no local-modification
  baseline (`installed.hashes`, section 5) this check is not made, once (section 2, item 3); and
  with `GOV_UPDATE_OVERWRITE_LOCAL=1` your file is replaced, after being backed up.
- Anything outside `~/.claude`. (The framework's other steps that act outside `~/.claude` — in your
  projects and on your remotes — are listed in section 2a.)

The signed update path is verified on Windows (Git Bash). Linux and macOS have not been verified
yet; on a system without `ssh-keygen -Y` (OpenSSH 8.2 or later) `--fetch` refuses and nothing is
installed. That a detached background process keeps running after Claude Code closes has been
verified on Windows with the terminal version of Claude Code; it has not yet been verified in the
VS Code extension, on Linux or on macOS. Where the restore of section 2 item 4 does not keep
running, nothing breaks: the next session start begins it again.

---

## 7. What this protects you from — and what it does not

**It protects you from:** a compromised GitHub account or repository, a stray or malicious push to
`master`, a tampered mirror or download, and a network attacker between you and GitHub. Without
the maintainer's private release key none of them can produce a release your machine will
install; the attempt is refused and that version is blocked. It also protects you from a
downgrade served as an upgrade, from a failed install (automatic rollback), and from silent
overwriting of files you changed yourself.

**It does NOT protect you from the following. Read these carefully.**

- **Compromise of the maintainer's release key or computer.** Releases are signed with a key kept on
  the maintainer's computer **without a passphrase**; any process running under the maintainer's
  account — including an AI-agent session — can read it. Someone who obtains that key can sign a
  release that your machine would accept **if you install it by hand**. This version installs
  nothing on its own, so a malicious signed release reaches your machine only through your own
  `--fetch`/`--apply` or `install.sh`. The safeguards are how the key is kept, a limited validity
  period with rotation, and blocking a version after any failed check. They reduce the risk; they
  do not remove it. This scheme protects against a compromise of GitHub or of the maintainer's
  GitHub account. It does not protect against a compromise of the maintainer's computer.
- **Trust on first install.** The key your machine trusts is taken from the copy of the
  repository you install from, the first time you install. If that copy was tampered with, your
  machine trusts the attacker's key. The fingerprint is published in `README.md`, printed by
  `install.sh` and by `gov-update.sh --status` so you can compare it — but all of these come from
  the same source. **There is no independent second channel for the fingerprint today.**
- **Being held back.** Someone who controls the repository's `master` branch can keep your machine
  on any signed version that is at least as new as yours, by not announcing newer ones. Your
  machine cannot detect this. `gov-update.sh --status` shows your installed version, when the
  version file was last requested, and whether that request failed (with the HTTP code) — so a
  human can notice.
- **Manual installs are not signature-protected.** Updating by hand (`git pull` followed by
  `bash install.sh --force`) has never been protected by the release signature and still is not,
  beyond a consistency check. It is your deliberate act.
- **Your privileges.** The framework's hooks and scripts run with **your own user privileges**,
  with the same access to your files that you have. This was true before 2.0.0 and is unchanged;
  an update you install runs the new code of that release with those privileges. If you want to
  review a release before it runs, read it before you run `--apply` (after `--fetch` it waits in
  `~/.claude/.governance-update/staged/`).
- **No remote revocation.** If the release key is stolen, the maintainer can publish a release
  signed only by a new key; machines that trust only the old key will refuse it: `--fetch` says
  the version is halted (reason `signature`) and points you to a fresh clone (`README.md`,
  "Release signing key"), and the next session start says so too. **There is no way to push a
  revocation to a machine whose only trust root is the stolen key.** Until you act, such a machine
  would accept releases signed with the stolen key. If the release key is ever suspected to be
  compromised, look for a notice at the top of `README.md` and in the repository's security
  advisories.

---

## 8. How to switch things off

- **Turn push at session close off:** `bash ~/.claude/hooks/governance/close-push.sh --disable`
  (on a machine that has the file `~/.claude/.governance-source`, run it and also delete that file —
  `--disable` alone does not turn it off there, and deleting the file alone turns it off only when
  no `y` is recorded under the current terms; section 10.3); pause it: `GOV_CLOSE_PUSH=0`
  (environment, or a line in `~/.claude/.governance-local.env`); for one project only:
  `close_push: off` in its `docs/context/CONTEXT-MANIFEST.md`.
- **No update check at all:** `GOVERNANCE_UPDATE_CHECK=0` in your environment.
- **The other steps of section 2a:** the session-start gate `GOV_BOOTSTRAP_GATE=0`; deciding
  context-file contradictions without asking `GOV_CANONICAL_AUTORESOLVE=0`; pull-request checks
  `GOV_PR_WATCH=0`; every framework hook at once `GOVERNANCE_HOOKS=0`.
- **The commit at session close has no switch of its own.** Whether or not push at session close
  is on, a close commits the files the session wrote (section 2a (a)); it is a step of the close
  skill, not a hook, so `GOVERNANCE_HOOKS=0` does not stop it either. The only way not to commit is
  not to run the session close.
- **Remove the framework:** `bash install.sh --uninstall` (from your copy of the repository). It
  backs up, then removes the whole `~/.claude/hooks/` and `~/.claude/docs/` directories — including
  any hook or document of your own you put there — the framework's skills, and, when `node` is
  installed, the ENTIRE `hooks` section of `~/.claude/settings.json`, including hook entries you
  added; restore those from the backup it names. Without `node` that section is left in place, and
  the uninstall does not say so: remove it by hand. It keeps your two records in
  `~/.claude/.governance-update/` (`terms-accepted`, `close-push`) and removes the rest of that
  folder. It does not remove `~/.claude/.governance-source` (section 10.3).

---

## 9. How to undo an update, and how to see its state

- **Roll back the last update:**
  `bash ~/.claude/hooks/governance/gov-update.sh --rollback`
  (or name a specific folder under `~/.claude/backups/`). This restores the framework's files and
  puts `~/.claude/settings.json` back as it was before that update — including any change you made
  to it since; the state just before the rollback is saved first, under `~/.claude/backups/`. It does
  not undo anything the release did while it was installed.
- **Unblock a version** that was blocked (after the third failed attempt, or a failed check):
  `bash ~/.claude/hooks/governance/gov-update.sh --clear-halt`
  — you can then fetch and install it again by hand.
- **See the state:**
  `bash ~/.claude/hooks/governance/gov-update.sh --status`
  — installed version, any release waiting, any blocked version, when the last check ran, the
  pinned key fingerprint and its expiry date, and which terms version you accepted.
- **Every decision is logged** in `~/.claude/logs/governance-update.log`.

---

## 10. The terms

### 10.1 Terms you accept by installing

You accept these terms by typing `I ACCEPT` when `install.sh` asks, or — for an installation without
a terminal — by passing `--accept-terms` or setting `GOV_ACCEPT_TERMS=1`. Passing the flag or setting
the variable means that you have read these terms and accept them. They are between you and the
maintainer: the person or people who publish releases of this repository, named as the copyright
holder in `LICENSE` ("the maintainer").

1. **Who accepts.** You accept these terms yourself, for yourself or for an organisation you are
   authorised to bind. An acceptance typed or passed by an AI agent is not your consent. The
   installer and `gov-update.sh --accept-terms` refuse to record an acceptance when they detect an
   AI-agent session (the environment markers Claude Code sets) — a re-install on a machine whose
   current terms are already accepted records no acceptance and is not refused — and turning push
   at session close on needs your own
   answer, `y`, typed in your own terminal — except on a machine that has the file named in
   section 10.3, where it is on without any answer. These are safeguards, not guarantees:
   anything that runs under your account can act as you, and what runs under your account is
   your responsibility (item 7). If other people use the machine you install on, telling them about
   these terms is your responsibility.
2. **What it is.** The software installs hooks, skills, agent definitions and its own hook entries
   in `settings.json`, which Claude Code runs with **your** user privileges. They can read and
   change what you can.
3. **The version check.** At most once every 12 hours the software asks GitHub whether a newer
   version exists (section 3). GitHub sees your IP address; nothing about you or your projects is
   sent to the maintainer or to anyone else. Off: `GOVERNANCE_UPDATE_CHECK=0`.
4. **Automatic updates are not part of this version.** Nothing in it downloads or installs a
   release without your own command. A release that adds automatic updates raises the terms
   version and asks you again (10.4), with a separate waiver.
5. **Push at session close is OFF** unless you turn it on under section 10.3 — or the machine has a
   file named `~/.claude/.governance-source`, which turns it ON without asking (section 10.3).
6. **Steps taken without asking you each time.** In a governed project the session-start gate
   blocks edits until the `bootstrapper` skill has run, and sessions update the framework's own
   context files (section 2a, with how to turn those off) and commit the files they wrote. The
   commit at session close has no switch of its own: the only way not to commit is not to run the
   session close (section 8). These steps are carried out by Claude Code, an AI, following the
   framework's instructions; an AI's behaviour is not fully predictable.
7. **Your responsibility.** You are responsible for your machine, your repositories and accounts,
   the data in them, and what Claude Code does under your account — including following the terms of
   Claude Code and of every service it connects to.
8. **Free, AS IS, no promises.** The software and every release of it are provided free of charge
   and "AS IS", without warranty of any kind, under the MIT License in `LICENSE`. The maintainer does
   not promise that it works, that it is secure or free of defects, or that it will be updated,
   fixed, supported or kept available.
9. **No liability, as far as the law allows.** To the fullest extent the law allows, the maintainer
   and the contributors are not liable for any loss or damage of any kind arising from or connected
   with the software, its installation, its push at session close or any release — including lost
   or corrupted data, lost work, lost profits, downtime and the cost of recovery — whether in
   contract, in tort (including negligence) or otherwise.
10. **A limit.** Where the law allows liability to be limited but not excluded, the total liability
    of the maintainer and the contributors to you, for all claims together, is USD 100.
11. **What these terms do not exclude.** Nothing in these terms excludes or limits liability for
    death or personal injury caused by negligence, for fraud, for wilful misconduct or gross
    negligence, or any other liability that the law does not allow to be excluded or limited —
    including rights you have as a consumer under the law of the country where you live that cannot
    be waived. These terms bind only you and the organisation you accept them for.
12. **Your MIT rights are unaffected.** These terms do not limit any right the MIT License gives you
    to use, copy, modify or distribute the software. They govern this installer, the manual update
    path and push at session close, and the disclaimers above.
13. **Law and courts.** These terms are governed by the law of the State of Israel, and the
    competent courts in Israel have jurisdiction — except where the law of your country gives you,
    as a consumer, the right to rely on its mandatory rules or to go to its own courts.
14. **If a part fails.** If a court finds part of these terms unenforceable, that part applies to
    the greatest extent the law allows, and the rest stays in force.

### 10.2 Automatic updates — not in this version

This version has no automatic update and no setting that turns one on. A release that adds one will
raise the terms version (10.4) and will ask you, in your own terminal, to accept a separate waiver
before anything is installed without your command.

### 10.3 Push at session close

Push at session close (section 2a (a)) is OFF unless you turn it on (with one exception, in the
next paragraph): by answering `y` when `install.sh` asks
`Turn push at session close ON now? [y/N]` in your terminal — the default is No, so pressing
Enter or any other answer leaves it off — or later with
`bash ~/.claude/hooks/governance/close-push.sh --enable`, run by you in your own terminal, which
asks the same question. There is no flag and no variable for it: on a machine without the file
described in the next paragraph, turning it on needs a terminal and your answer. An installation
without a terminal never turns it on (a `y` you recorded under the current terms stays). Answering `y` means that you have read section 2a (a) and this
section and accept them. By turning it on you accept that pushes are made without asking you each
time, that a push cannot be taken back once someone has fetched it, and that the holds described
in section 2a are not a guarantee. Items 7 to 14 of section 10.1 apply to it.
Turn it off at any time: `close-push.sh --disable` (where the file of the next paragraph exists,
run it and also delete that file); pause it: `GOV_CLOSE_PUSH=0`; for one project: `close_push: off`.

**The one exception: a file named `~/.claude/.governance-source`.** If that file exists on a
machine, push at session close is ON there: no question is asked and no record is needed, and a
recorded "no" — `n` at the question, `install.sh --no-close-push` or `close-push.sh --disable` —
does not turn it off. The file marks the machine on which the framework's releases are made. You
do not have to create it yourself for it to exist: `gov-release.sh`, the release tool that is
installed with the framework, creates it on every release run made from that machine's own
repository that gets as far as pushing the signed release tag — also a run whose final check then
fails — and again on each such run, even if you deleted it. The same name also makes
`gov-update.sh` refuse to download or install a release on that machine (section 2), and
`install.sh --uninstall` does not remove it. To check: `ls -l ~/.claude/.governance-source` (only a
regular file turns push on; a directory of that name does not). To return to the rule above,
delete the file (`rm ~/.claude/.governance-source`): your recorded choice applies again, and with
no record push is off. While the file exists, `GOV_CLOSE_PUSH=0` pauses push at session close and
every hold of section 2a (a) still applies. Any program that runs under your account — an AI agent
included — can create that file, as it can do anything else you can; the framework's guard
(`consent-guard.sh`) refuses only the command forms it recognises, so it is a safeguard,
not a guarantee (10.1 items 1 and 7).

### 10.4 When these terms change

The terms version below goes up when a release:
- changes these terms, the summary or the install questions;
- adds or widens an action outside `~/.claude` or outside your machine — for example a new network
  destination, a push, or a message posted or sent;
- turns any feature on by default; or
- sends any information about you or your projects to anyone, the maintainer included.

Such a release is not prepared or installed by `gov-update.sh` and none of its code runs on your
machine before you accept. On a machine without the file named in section 10.3, push at session
close goes back to off; where that file exists it stays on (10.3). To turn it on again: accept the
new terms (`bash ~/.claude/hooks/governance/gov-update.sh --accept-terms`, or `install.sh` again),
then run `bash ~/.claude/hooks/governance/close-push.sh --enable` in your own terminal and answer
`y` — accepting the terms alone does not turn it back on. The software
never accepts terms on your behalf; an AI agent's acceptance is not yours, and the scripts refuse
when they detect one (10.1 item 1).

### 10.5 The record of your choices

Your choices are recorded in `~/.claude/.governance-update/`: `terms-accepted` and `close-push`.
Each holds the terms version, the date and time, how you made the choice, the framework version,
and checksums (SHA-256, carriage returns removed) of this file and of the exact text you were
shown: for the terms, the summary below; for push at session close, the question exactly as it
was printed, including the file path on its "Full text" line and the `[y/N]` prompt — the record
holds the checksum, not the path. To check it, print the question again with the same path
(`consent-lib.sh`, function `gov_close_push_question`) and compare. When nothing was shown (for
example `close-push.sh --disable`), it is the checksum of empty text. `install.sh --uninstall` keeps
them as the record of your choices. Every released version of these terms remains available in the
repository's tagged releases.

### The summary shown when you are asked to accept

`install.sh` and `gov-update.sh --accept-terms` print exactly the lines between the two markers
below, then ask you to type `I ACCEPT`. It is a summary; the sections above are the terms.

<!-- terms-summary:begin -->
 1. You accept this yourself - not through an AI agent - for yourself or an organisation you
    may bind.
 2. It installs hooks and skills that Claude Code runs with YOUR user privileges.
 3. At most every 12 hours it asks GitHub whether a newer version exists; GitHub sees your IP
    address. Nothing about you or your projects is sent to the maintainer.
    Off: GOVERNANCE_UPDATE_CHECK=0
 4. AUTOMATIC UPDATES are not part of this version. You update by hand (section 1).
 5. PUSH AT SESSION CLOSE is OFF unless you turn it on (asked next, on a terminal: y/N,
    default No). A push cannot be taken back. Exception: where a file named
    ~/.claude/.governance-source exists (gov-release.sh creates it), it is ON (section 10.3).
 6. In a governed project, edits are blocked until the bootstrapper skill has run, and a
    session updates the framework's own context files and change logs, and commits the files
    it wrote, without asking you (section 2a).
 7. It installs or changes only framework files under ~/.claude and its own hook entries in
    settings.json; it creates CLAUDE.md only if you have none and never overwrites it.
    install.sh --uninstall removes the whole hooks folder and hooks section, backed up first
    (section 8).
 8. Each behaviour in section 8 can be turned off; the commit a session makes at close has no
    switch (section 8).
 9. You are responsible for your machine, your repositories and accounts, and what Claude Code
    does there.
10. Free, AS IS (MIT). No liability as far as the law allows; section 10.1 says what the law
    does not allow to be excluded (for example fraud, gross negligence, personal injury).
<!-- terms-summary:end -->

Terms version: 1
