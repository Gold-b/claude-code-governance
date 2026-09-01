---
name: pr-to-git
description: Open a GitHub Pull Request for review by a responsible agent (e.g., CODEX), wait for its response (text comment or 👍 reaction), remind it after 6 minutes with an @mention, and merge on approval — or after a 4-minute grace if no response. Use when the user asks to "send via PR for review", "open a PR and wait for <agent>", or to ship a reviewed change through the responsible-agent gate.
---

# /pr-to-git — Push a PR, await responsible-agent review, merge

**Language:** communicate with the user in **Hebrew**; all git/PR content in **English**.

**Purpose.** Automate the "send the final work to GitHub as a Pull Request, let the responsible review agent (currently **CODEX**) respond, then merge" loop, with the exact timing rules below. The skill only PUSHES the PR and drives the wait/remind/merge logic — it does not implement the change itself.

---

## Parameters (resolve before running)
| Param | Default | Notes |
|---|---|---|
| `REVIEWER` | `codex` | OpenAI's Codex coding agent — GitHub user **`@codex`**. TRIGGER it by tagging `@codex` in the PR body (and in the reminder comment) — NOT via `--reviewer` (it's a bot, not an assignable collaborator-reviewer). Requires the user's ChatGPT account connected to GitHub (done). It responds to @mentions on PRs with reviews/comments. |
| `REVIEWER_IS_COLLABORATOR` | unknown | If true, add as a PR reviewer (`--reviewer`). If false, rely on @mention + the agent watching the repo. |
| `FALLBACK_REVIEWER` | `Opus 4.8 (thinking)` | The responsible agent to use if the primary (`CODEX`) is at its usage limit / cannot review. See "Fallback responsible agent" below. |
| `BASE` | `main` | Base branch to merge into. |
| `HEAD` | `pr/<slug>-<date>` | Feature branch holding the change. Create if not already on one. |
| `PR_TITLE` / `PR_BODY` | — | Title + body. Body should summarize the change and explicitly request the reviewer's approval (text or 👍). |
| `INITIAL_WAIT` | `360` sec (6 min) | Continuous wait before the reminder. |
| `GRACE_WAIT` | `240` sec (4 min) | Wait after the reminder before merging anyway. |
| `POLL_INTERVAL` | `~75` sec | How often to poll (stay under the 5-min cache window when actively polling). |
| `MERGE_METHOD` | `--squash` | Merge strategy (`--squash` / `--merge` / `--rebase`). |

Resolve `OWNER/REPO` from `gh repo view --json nameWithOwner`.

---

## Workflow

### Step 1 — Stage the change on a feature branch
1. Ensure the working tree holds the intended change (the caller has already produced it).
2. If currently on `BASE`, create and switch to `HEAD`: `git checkout -b <HEAD>`.
3. Commit (English message + the Co-Authored-By trailer the repo convention requires) and push: `git push -u origin <HEAD>`.
   - If the account enforces email privacy, use the GitHub noreply email (see the repo's gotcha) so the push isn't rejected.

### Step 2 — Open the PR
```
gh pr create --base <BASE> --head <HEAD> --title "<PR_TITLE>" --body "<PR_BODY>"
# add --reviewer <REVIEWER> ONLY if REVIEWER_IS_COLLABORATOR is true
```
Capture the PR number and URL (`gh pr view --json number,url`). Tell the user the PR URL and that the wait has started.

### Step 3 — Poll for the responsible agent's response (up to INITIAL_WAIT)
A **response** from the responsible agent is ANY of:
- An **approving review**: a review with state `APPROVED`.
- A **👍 reaction** (`+1` / THUMBS_UP) on the PR itself or on the PR body/a comment, authored by `REVIEWER` (or, if `REVIEWER` handle is unknown, by anyone who is not the PR author).
- A **text comment** authored by `REVIEWER` (or any non-author if the handle is unknown).

Poll every `POLL_INTERVAL` seconds, accumulating elapsed time up to `INITIAL_WAIT`:
```
# reviews + comments
gh pr view <n> --json reviews,comments,state,mergeStateStatus
# PR-level reactions (a PR is an issue):
gh api repos/<OWNER>/<REPO>/issues/<n>/reactions --jq '.[] | {by: .user.login, content}'
# reaction on a specific comment:
gh api repos/<OWNER>/<REPO>/issues/comments/<comment_id>/reactions --jq '.[] | {by: .user.login, content}'
```
Classify the first qualifying response:
- **Approval** = `APPROVED` review, OR a 👍 reaction, OR a text comment that is affirmative ("LGTM", "approved", "ok to merge", "👍", "ship it", Hebrew "מאשר"/"אפשר למזג"). → go to Step 5 (MERGE).
- **Change request** = a `CHANGES_REQUESTED` review, OR text that clearly asks for changes/raises blocking concerns. → go to Step 6 (STOP & surface).
- No qualifying response yet → keep polling.

Do NOT poll with blocking `sleep` in the foreground. Use the harness wait primitive (Monitor / a `run_in_background` poll loop, or ScheduleWakeup with a sub-`INITIAL_WAIT` delay) so the session stays responsive. Track elapsed time explicitly.

### Step 3b — MANDATORY: a claimed commit is not a landed commit

CODEX operates in two modes on this repo, and they behave differently:

- **Review mode** — reviews, inline comments, 👀/👍 reactions. It *recommends*; you apply. This works.
- **Task mode** — it edits files in its own cloud sandbox and reports *"Committed the changes as `<sha>`"*, sometimes adding that it invoked `make_pr`. **That sandbox has no git remote and an unauthenticated `gh`, so the commit never leaves it.**

Measured on a private source repo, 2026-08-25: **three** such reports in one session — `4e43345`, `366000f`, `8fc2a44`. **None existed.** On the third CODEX named the cause itself: no `make_pr` tool, no remote, `gh` unauthenticated.

**Whenever a reviewer's response claims a commit, a branch, or a follow-up PR, verify before believing it:**

```bash
git fetch -q origin
git cat-file -t <claimed-sha> 2>&1        # "fatal: Not a valid object name" => it does not exist
gh pr list --repo <OWNER/REPO> --state open --json number,headRefName
git ls-remote --heads origin | tail -5
```

If it is absent — the normal case — **re-apply the change yourself** and say so in the commit message and in the reply, so the next session does not inherit the false belief that it was already fixed. The reviewer's **summary is the deliverable**; its patches are not.

This matters beyond tidiness: had the first claimed commit been trusted, a data-loss correction would have been recorded as applied while the wrong text stayed in the merged document.

> **The real cure is upstream and is the owner's to apply:** the ChatGPT Codex cloud environment for this repo needs the repository connected with PR creation enabled (chatgpt.com/codex/cloud/settings). Until then, Step 3b is mitigation, not a fix.

### Step 4 — Reminder after 6 minutes of silence
If `INITIAL_WAIT` elapses with no qualifying response, post ONE reminder comment that @mentions the responsible agent:
```
gh pr comment <n> --body "@<REVIEWER> friendly reminder — this PR is awaiting your review (text or a 👍). Will merge after a short grace window if there's no response. Thanks!"
```
Then continue polling for up to `GRACE_WAIT` more seconds.

### Step 5 — Merge on approval (or after the grace window)
Merge when EITHER an approval arrived (any step) OR `GRACE_WAIT` elapsed after the reminder with still no response:
```
gh pr merge <n> <MERGE_METHOD> --delete-branch
```
- Confirm merge succeeded (`gh pr view <n> --json state` → `MERGED`).
- If merge is blocked (required checks failing, conflicts, branch protection), DO NOT force — STOP and surface the blocker to the user.
- Report to the user: what happened (approved-and-merged, 👍-and-merged, or timed-out-and-merged-per-policy) + the final state + the merge commit.

### Step 6 — On a change-request response
If the responsible agent's response requests changes (not an approval): STOP, do NOT merge, and surface the exact feedback to the user (and the caller) so the change can be revised and the PR updated. Re-running the wait loop resumes after the revision is pushed.

---

## Fallback responsible agent (Codex usage-limit → Opus 4.8 thinking)
The primary responsible agent is **CODEX**. If CODEX has reached its usage limit or otherwise cannot perform the review, the responsible-agent role escalates to **`FALLBACK_REVIEWER` = Opus 4.8 (thinking)**.

**Trigger — switch to the fallback when ANY holds:**
- CODEX posts a comment indicating it cannot review (text matching `usage limit` / `rate limit` / `quota` / `over limit` / `cannot review` / `unavailable`, in English or Hebrew equivalents).
- The CODEX integration errors out / is unreachable when the PR is opened.
- (Optional, operator-set) the user states CODEX is at its limit for this run.
> Note: a plain SILENCE timeout is NOT the fallback trigger — silence follows the §2 reminder→grace→merge path. The fallback is specifically for CODEX being UNABLE to review.

**Fallback action:** run an **Opus 4.8 reviewer with extended thinking** (the Agent tool with `model: opus` + high/`xhigh` effort) as the responsible agent: it reads the PR diff + the changed plan/docs, then posts its verdict AS A PR COMMENT (so the record lives on the PR), formatted as either an approval ("✅ Approved — …") or a change-request ("🔧 Changes requested — …"). Then apply the SAME response/merge logic: an approving Opus verdict (or 👍) → merge; a change-request → STOP & surface (Step 6). Because the fallback reviewer is one we drive, it should respond promptly (no 6+4-minute wait needed once it has run).

**Record which agent reviewed** (CODEX or the Opus fallback) in the merge report to the user.

## Timing rules (verbatim from the user's spec — section 2)
- Wait for the responsible agent's response after opening the PR.
- "Response" = (1) a text comment, or (2) a 👍 (Thumbs-Up) reaction.
- On approval of the PR by the responsible agent → MERGE is permitted.
- If NO response for **6 full continuous minutes** → remind the responsible agent with an `@`-mention comment, then wait **up to 4 more minutes**.
- If still no response by the end of the grace window → **MERGE anyway**.

## Guardrails
- Never force-merge over failing required checks or branch protection — surface instead.
- Never merge a PR whose only response is an explicit change-request.
- Only post ONE reminder (no spamming).
- Private repos: the responsible agent must be a collaborator to comment/react; if it cannot respond at all, the timeout→merge path applies (warn the user that no human/agent review was recorded).
- Respect the repo's commit-email privacy (noreply) and Co-Authored-By trailer conventions.
- Idempotent: if a PR for `HEAD`→`BASE` already exists, reuse it instead of creating a duplicate.
