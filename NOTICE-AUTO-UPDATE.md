# Automatic updates — full disclosure and terms

> **DRAFT — pending legal review (plan decision 29); not yet in force.**
> This text describes the automatic-update mechanism planned for version 2.0.0. Nothing in it
> applies until a release that ships the mechanism is tagged and you accept these terms.

This document tells you, in plain language, everything the automatic updater of the Context
Governance installer does on your machine, what it protects you from, what it does **not** protect
you from, and what you agree to by installing it. Read it before you type `I ACCEPT`.

`~` below means your home directory. `~/.claude` is the Claude Code configuration directory in it.

---

## 1. In one paragraph

Once installed, the framework keeps itself up to date. At the start of a Claude Code session it
checks whether a newer version has been published. If there is one, it downloads that release in
the background, checks that it was signed by the maintainer's release key and that every file is
exactly what the signed list says, and prepares it. At a later session start — and only when no
other Claude Code session of yours is active — it installs the prepared release, checks that the
result works, and puts everything back the way it was if it does not. You can turn this off at
any time, and you can undo any update.

---

## 2. What runs, and when

Everything starts from one hook that is already part of the framework: `pre-session.sh`, which
Claude Code runs at the start of every session (the `SessionStart` event).

1. **Version check (existing behaviour).** `pre-session.sh` compares the version you have
   installed (`~/.claude/.governance-version`) with the version published in the repository. The
   answer is cached for 12 hours; the network request runs detached in the background, so the
   session never waits for it.
2. **Background download.** When the cached answer says a newer version exists, `pre-session.sh`
   starts `gov-update.sh --fetch <version>` as a **detached background process**. It downloads,
   verifies and prepares the release (section 4). It prints nothing and changes nothing outside
   its own working folder (section 5). As part of that verification it runs the release's own
   self-checks, so the downloaded code — after its signature and checksums have been verified —
   executes on your machine in the background.
3. **Install (foreground).** At a later session start, if a verified release is waiting,
   `pre-session.sh` runs `gov-update.sh --apply-if-ready` in the foreground. It installs only when
   **all** of these hold:
   - the session was started fresh or resumed (not on `compact` or `clear`, which happen
     mid-task);
   - no other Claude Code session of yours has been active in the last 10 minutes (otherwise it
     waits and tells you so);
   - none of the installed framework files were modified by you since the last install
     (otherwise it refuses and names the files);
   - you have accepted the current version of these terms;
   - automatic updates are not switched off (section 8).

   The install normally takes seconds. It aborts on its own and restores the previous state if it
   runs past its time limit (50 seconds for the file changes, 20 more for the final check). When it finishes it prints one line saying which version was
   applied, where the backup is, and how to roll back.
4. **Nothing else.** No new scheduled task, service, cron entry or background daemon is added.
   Nothing runs when Claude Code is not running.

---

## 3. What is downloaded, and from where

- **The published version number**, from the repository's `master` branch:
  `https://raw.githubusercontent.com/Gold-b/claude-code-governance/master/bundle/VERSION`
  (existing behaviour, at most once per 12 hours).
- **The release itself**, only as a **tagged** archive — never the `master` branch:
  `https://github.com/Gold-b/claude-code-governance/archive/refs/tags/v<version>.tar.gz`
  GitHub may redirect this request to `codeload.github.com`. Only HTTPS is allowed, including on
  the redirect. Downloads larger than 20 MiB are refused.

No information about you, your projects or your machine is sent, beyond what any HTTPS request to
GitHub reveals (for example your IP address).

---

## 4. What is verified before anything is installed

A downloaded release is rejected, and that version is blocked from further automatic attempts,
unless **every** one of these checks passes:

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
   `node --check`.
8. **Self-checks.** The release's own scanner and helper self-tests run in a throw-away sandbox.

The prepared release is verified again (steps 2, 4, 5, 6) immediately before it is installed.

The release public key's fingerprint is:

```
SHA256:mm0V5Ieg0cSy6BDjSwOQ4boTjsWnNthw6j1/LqeKzy4
```

It is also printed in `README.md` (section "Release signing key"), by `install.sh` when it pins
the key, and by `gov-update.sh --status`. Compare them.

---

## 5. What is written, and where

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
  - `terms-accepted` — which version of these terms you accepted, when, and how;
  - `dl/` — downloaded archives;
  - `staged/` — one verified release waiting to be installed;
  - `READY`, `APPLYING`, `HALT-<version>`, `fetch-attempts-<version>`, `deferrals` — small status
    files (a release is ready; an install is in progress; a version is blocked; retry and deferral
    counters);
  - `lock.d/` — a lock so that only one process updates at a time.
- `~/.claude/backups/governance-update-<timestamp>/` — a complete backup of every file an update
  replaces or removes, taken **before** the first file is replaced.
- `~/.claude/logs/governance-update.log` — one line per decision the updater makes.
- The framework's own files, as listed in the signed release:
  - `~/.claude/hooks/` (the framework's hook scripts),
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

## 6. What is never touched

- `CLAUDE.md` — your global instructions file.
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
  not applied and the path is named.
- Anything outside `~/.claude`.

Automatic updates are verified on Windows (Git Bash). Linux and macOS have not been verified yet;
on a system without `ssh-keygen -Y` (OpenSSH 8.2 or later) nothing is ever installed automatically.

---

## 7. What this protects you from — and what it does not

**It protects you from:** a compromised GitHub account or repository, a stray or malicious push to
`master`, a tampered mirror or download, and a network attacker between you and GitHub. Without
the maintainer's private release key none of them can produce a release your machine will
install; the attempt is refused and that version is blocked. It also protects you from a
downgrade served as an upgrade, from a failed install (automatic rollback), and from silent
overwriting of files you changed yourself.

**It does NOT protect you from the following. Read these carefully.**

- **Compromise of the maintainer's machine.** The release signing key is kept on the maintainer's
  machine **without a passphrase**, so that releases can be signed without a human typing one.
  Anyone who can read that key file — malware on that machine, a stolen disk image, a backup that
  includes the key — can sign a release that **every installed copy applies automatically at its
  next session start**. The safeguards are how the key is kept, a limited validity period with
  rotation, and blocking a version after any failed check. They reduce the risk; they do not
  prevent it. This scheme protects against a compromise of GitHub or of the maintainer's GitHub
  account. It **does not** protect against a compromise of the maintainer's machine.
- **Trust on first install.** The key your machine trusts is taken from the copy of the
  repository you install from, the first time you install. If that copy was tampered with, your
  machine trusts the attacker's key. The fingerprint is published in `README.md`, printed by
  `install.sh` and by `gov-update.sh --status` so you can compare it — but all of these come from
  the same source. **There is no independent second channel for the fingerprint today.**
- **Being held back.** Someone who controls the repository's `master` branch can keep your machine
  on any signed version that is at least as new as yours, by not announcing newer ones. Your
  machine cannot detect this. `gov-update.sh --status` shows your installed version and when the
  last successful check happened, so a human can notice.
- **Manual installs are not signature-protected.** Updating by hand (`git pull` followed by
  `bash install.sh --force`) has never been protected by the release signature and still is not,
  beyond a consistency check. It is your deliberate act.
- **Your privileges.** The framework's hooks and scripts run with **your own user privileges**,
  with the same access to your files that you have. This was true before automatic updates and
  is unchanged; automatic updates mean that new code from each release runs with those privileges
  without you reviewing it first.
- **No remote revocation.** If the release key is stolen, the maintainer can publish a release
  signed only by a new key; machines that trust only the old key will refuse it and tell you to
  reinstall by hand. **There is no way to push a revocation to a machine whose only trust root is
  the stolen key.** Until you act, such a machine would accept releases signed with the stolen
  key.

---

## 8. How to switch it off

- **Advisory only (no automatic download or install):** set `GOV_AUTO_UPDATE=0` — either in your
  environment or as a line `GOV_AUTO_UPDATE=0` in `~/.claude/.governance-local.env`. You will
  still be told when a new version exists and can update by hand.
- **No update check at all:** set `GOVERNANCE_UPDATE_CHECK=0` in your environment.
- **Remove the framework:** `bash install.sh --uninstall` (from your copy of the repository). It
  backs up the files before removing them. It keeps `~/.claude/.governance-update/terms-accepted`
  as a record of what you accepted and removes the rest of `~/.claude/.governance-update/`.

---

## 9. How to undo an update, and how to see its state

- **Roll back the last update:**
  `bash ~/.claude/hooks/governance/gov-update.sh --rollback`
  (or name a specific folder under `~/.claude/backups/`).
- **See the state:**
  `bash ~/.claude/hooks/governance/gov-update.sh --status`
  — installed version, any release waiting, any blocked version, when the last check ran, the
  pinned key fingerprint and its expiry date, and which terms version you accepted.
- **Every decision is logged** in `~/.claude/logs/governance-update.log`.

---

## 10. Your acceptance, and the waiver

By installing this software and typing `I ACCEPT` (or passing `--accept-terms`, or setting
`GOV_ACCEPT_TERMS=1`), you confirm that:

1. You chose to install this software yourself.
2. You accept that it updates itself automatically, as described above, until you switch that off.
3. You have read section 7 and accept the supply-chain risks it describes, including the risk
   that a release signed with a stolen key is installed automatically on your machine.
4. You are responsible for reviewing the releases you run and for the security and maintenance of
   your own machine.
5. The maintainer accepts **no liability** for any loss or damage arising from the software, its
   automatic updates, or any release, to the fullest extent the law allows.

The software is provided **"AS IS"**, without warranty of any kind, under the terms of the MIT
License in `LICENSE`, whose warranty disclaimer and limitation of liability apply in full to the
automatic-update mechanism and to every release it installs.

If a future release changes these terms, the version number below goes up and automatic updates
stop until you accept the new version (`bash ~/.claude/hooks/governance/gov-update.sh
--accept-terms`, or re-running `install.sh`). Terms are never accepted on your behalf.

### The summary shown when you are asked to accept

`install.sh` and `gov-update.sh --accept-terms` print exactly the lines between the two markers
below, then ask you to type `I ACCEPT`. It is a summary; the sections above are the terms.

<!-- terms-summary:begin -->
 1. This software installs hooks and skills that run with YOUR user privileges.
 2. It updates ITSELF: newer releases are downloaded from GitHub and installed at session start.
 3. Each release is checked against a signing key held by the maintainer before it is installed.
 4. That key is kept WITHOUT a passphrase; if the maintainer's machine is compromised, a malicious
    release could install itself on your machine automatically.
 5. The key is trusted from the copy you are installing now; there is no independent way to check it.
 6. Only framework files under ~/.claude and the framework's own hook entries in settings.json
    change (section 6 defines "own"); CLAUDE.md, your local env file and your other settings are
    never touched.
 7. Every update is backed up and can be undone: gov-update.sh --rollback
 8. Turn automatic updates off at any time: GOV_AUTO_UPDATE=0 (or uninstall with --uninstall).
 9. You are responsible for reviewing releases and for your own machine.
10. The maintainer accepts no liability for any loss or damage, to the extent the law allows.
<!-- terms-summary:end -->

Terms version: 1
