# Parallel sessions changing the framework at once — incident notes (2026-08-15)

> **Sanitised 2026-08-18.** The original of this note carried private project names, absolute local
> paths, session UUIDs and repository-internal detail, in a **public** repository. It has been
> rewritten to keep only what is reusable: how the framework broke, and what to do about it. The
> rule that should have prevented it is now Agent Guide §19 — read it before adding anything here.
>
> Projects are referred to as **Project A** (where the changes were authored), **Project B** and
> **Project C** (two other checkouts that carry mirrors of the framework). Sessions are numbered.

## What happened

Three Claude sessions were open across three different projects. The governance framework itself
lives at user level (`~/.claude/`), belongs to no project, and is mirrored into several checkouts —
so all three sessions were, without any of them intending it, editing one shared thing.

- **Session 1** (Project A) authored framework changes: parallel-session detection in
  `pre-session.sh`, plus matching sections in the agent guide and two skills.
- **Session 2** (Project A, earlier) made **no** framework changes — verified from its transcript,
  not assumed. Its only relevance is the incident that motivated the work: a `git add -u` on a
  working tree it shared with another session.
- **Session 3** (Project B) pushed an unrelated release; its Stop hook committed and pushed the
  bundle, which is how a third party's changes reached this repository at all.

## The failures this exposed

1. **Session state was global.** `.gov-session-changes`, `.gov-session-start`, `.gov-session-dirty`,
   the prompt counter and the bootstrap marker were single files shared across every concurrent
   session **and** across projects. A second session's SessionStart archived and deleted the first
   one's log, which then read as a **false CRASH RECOVERY**. *Fixed: state is keyed by session id.*
2. **No dry run.** Running any hook by hand mutated real state, so you could not inspect one
   without damaging the thing you were inspecting. *Fixed: `GOV_DRY_RUN=1`.*
3. **The auto-push swept files it did not own.** The close hook ran `git add bundle/` — despite a
   comment claiming it staged specific files only — so one session's Stop could commit another
   session's uncommitted work, and it pushed without pulling first. *Fixed: pull `--rebase` first,
   stage only the queued paths.*
4. **Five copies, one direction.** Mirrors were refreshed from the live copy but nothing reconciled
   repo → live, so a live hook silently regressed to an older version and no signal existed to
   notice. A later session found the mirroring hook had in fact **never been registered on any
   event**, which is why the copies drift at all. *Fixed 2026-08-17: the sync hook is wired, and it
   now refushes only mirrors that already exist rather than re-creating deleted ones.*
5. **A fix that existed in exactly one mirror was lost.** A small stdin guard survived only in one
   checkout's copy, uncommitted, and a sync overwrote it. Nothing in the framework could have
   flagged it: an untracked improvement inside a mirror has no owner and no history.

## The lesson that generalises

**Shared-but-unowned is the condition, not any single bug.** Every failure above comes from the same
place: code that several projects depend on, that lives in none of them, and that therefore nobody
reviews, backs up, or reconciles. The durable answers are ownership (one named owner per shared
component), a single source of truth (mirrors refresh from it, never the reverse), and making a
missing signal loud instead of silent.

## If you find yourself merging two sessions' framework edits

1. Park your own work under `bundle/` first — commit it, so no foreign `git add bundle/` can sweep
   it. Do not rely on a file being untracked to keep it safe.
2. Take clean appends (docs, skills) as-is; they rarely conflict.
3. For a hook edited on both sides, build the **union** by hand and copy it back to the live
   location, so the mirrors re-sync from a correct source rather than from either half.
4. `bash -n` everything, and run a hook by hand only with `GOV_DRY_RUN=1`, or from a scratch
   directory — several of them wipe or rewrite state under `~/.claude/logs/`.
