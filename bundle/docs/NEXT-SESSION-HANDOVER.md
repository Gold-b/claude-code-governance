# Next-Session Handover — Goal-Scoped Continuation Protocol

> **Audience:** LLM agents (Claude Code, sub-agents, orchestrators).
> **Human companion doc:** `~/.claude/docs/GOVERNANCE-HUMAN-GUIDE.md`
> **Version:** 1.0 (2026-08-25)
> **Scope:** Universal — applies to ALL governed projects.
> **Authority:** This file is a **renderer spec**. It defines HOW a continuation prompt is produced. It is NOT a state record and NEVER holds project state.

---

## 0. What this file is — and what it is not

Three different things are involved. Keeping them apart is the whole design:

| | `docs/context/HANDOFF.md` | `docs/context/NEXT-SESSION-PROMPT.md` | This document |
|---|---|---|---|
| Kind | Per-project **state record** | Per-project **paste-ready prompt** | Global **renderer spec** |
| Owner | `/live-state-orchestrator` | `/live-state-orchestrator` Step 6.1 | The framework (read-only at runtime) |
| Holds project facts? | Yes — the single source | **Pointers only, never a copy** | **No, never** |
| Lifecycle | active/consumed/superseded/archived | rewritten or deleted at every close | none (versioned doc) |

**The canonical artifact is `docs/context/NEXT-SESSION-PROMPT.md`.** Fixed name, fixed location,
scaffolded by `/init-governance`, listed in `CONTEXT-MANIFEST.md`. Before the framework named it,
every project invented its own — three names across four projects (`NEXT-SESSION-PROMPT.md` in
`docs/context/`, the same name in `MDs/`, a dated `NEXT-SESSION-PROMPT-<date>.md` in `Plans/`, and
a `NEXT-SESSION-KICKOFF.md`) — which is exactly how a session fails to find the handover written
for it.

**Anti-duplication rule (hard):** the prompt **references** `HANDOFF.md`, `Plans/PLAN.md` and
`OPEN-PROBLEMS.md`; it does not restate them. It carries only the goal, the completion criteria,
pointers, blockers and the next action. Copying state into it recreates the drift this framework
exists to prevent — and this is not theoretical: a project's own manifest records its
next-session prompt going *16 days stale* while still describing infrastructure that had moved,
"the single most damaging thing a session could act on".

**Staleness rule (the price of a separate file):** it is **rewritten from scratch at every close,
or deleted**. Never appended to, never left to age. A prompt older than the handoff beside it is
worse than no prompt, because it reads as current. `/context-governance` flags it when its mtime
predates `HANDOFF.md`.

**It is not a second state record and does not touch the HANDOFF lifecycle.** There is still
exactly one `active` handoff; this file has no `status` frontmatter and no lifecycle of its own.

**One exception — chat-only, no write:** if persisting would break a close invariant that has
already been satisfied, emit the prompt in chat and say so in the report instead of writing it.
This is an explicit renderer mode, not an instruction to improvise: invoke
`/live-state-orchestrator` Step 6.1 with **`render-only`**, which produces exactly the same text
and skips only the file write. Never hand-write the prompt to work around the write — that would
fork the format the spec exists to keep single.
The concrete case is `/full-finish`: its Phase 9 hermetic close requires `HEAD == tag` and a clean
tree, and `NEXT-SESSION-PROMPT.md` is a tracked file — so writing it *after* the release tag turns a
passing hermetic close into a dirty tree. A prompt is worth having; it is not worth silently
invalidating the release gate that just passed. On the failure paths (Phase 9 already blocked, the
tree already dirty) there is no invariant left to protect, so the prompt IS persisted as normal.

**Why this spec is global and shared while the prompt is per-project (a common confusion worth
naming).** This file lives in `~/.claude/docs/` and is read by *every* project on the machine — that
is correct and safe **because it holds no project state**: it is a rendering template, like a skill
or a hook, not a brief. Run three projects in parallel and all three read this one spec, then each
writes its OWN `docs/context/NEXT-SESSION-PROMPT.md`; they never share prompt state and cannot
collide on it. The two files share the `NEXT-SESSION-` prefix but are different *kinds* of thing —
`-HANDOVER` is the global **how** (this spec), `-PROMPT` is the per-project **what** (the brief). If
a session ever reads next-session *state* from `~/.claude/`, that is a bug: state is always
per-project, always under the project's `docs/context/`. `/context-governance` Lite check 7b flags a
prompt that drifts out of that canonical location.

---

## 1. When to render a continuation prompt

Render it when **all** of these hold:

1. A goal was declared for the session (explicitly by the user, or recorded in `Plans/PLAN.md`), **and**
2. That goal's Definition of Done is **not** fully satisfied, **and**
3. The session is ending — context threshold reached, user stop, or an unresolvable blocker.

**Do NOT render it when:**

- The goal is complete and verified -> `/full-finish` output + `HANDOFF.md` are sufficient.
- The user explicitly said no continuation prompt is needed.
- No goal was ever scoped (an ad-hoc question/answer session).

**At a session CLOSE where no prompt is due, DELETE `docs/context/NEXT-SESSION-PROMPT.md` if it
exists** (and drop its `CONTEXT-MANIFEST.md` row to `ARCHIVED`). Leaving last session's prompt in
place is the staleness failure in its purest form: the next session opens a file describing a goal
that is already finished and treats it as its brief.

Two limits on that:

- **Deleting is a close action, never a mid-session one.** If the session is simply not ending,
  leave the file exactly as it is — condition 3 above already skips this step. A mid-session
  delete mutates tracked state inside a running pipeline and may destroy the correct handover for
  a session that ends unexpectedly minutes later.
- **`/full-finish` after the release tag does not delete either** — see §0. Removing a tracked file
  dirties a tree that just passed the hermetic close; it is reported instead.

An `ARCHIVED` manifest row means "this path is intentionally absent". `/context-governance` checks
existence for `ACTIVE` rows only, so a correctly closed project does not report as broken.

---

## 2. The `/goal` block — template

**The whole block below is a DEFAULT — Scope sentence included — used only when the goal has none
of its own.** Both halves matter. Rendering a recorded Definition of Done verbatim while still
emitting the stock Scope line ("Include all required implementation, integration, documentation,
review, merge, deployment, and verification work within this goal") expands the goal by the back
door: the criteria list is untouched, but the *work* the next session believes it owns has grown.
**A recorded goal's Scope is rendered as recorded**; the stock Scope sentence belongs only to a
goal composed from this template.

- **A Definition of Done was declared** — by the user, or recorded in `Plans/PLAN.md` / the active
  `HANDOFF.md`: render **that one, verbatim. Add nothing to it.** Not a "missing" review bullet,
  not a "missing" deployment bullet. A DoD that omits review or deployment omits them *on
  purpose*, and topping it up from the stock list hands the next session obligations the user
  never declared — so it decides "done" against a different goal than the one that was set. The
  same cuts the other way: never drop a criterion the user did state because it is absent below.
- **No Definition of Done was ever stated:** use the stock list. Where a bullet has no meaning in
  this project (no review gate, nothing to deploy), replace it with the project's real equivalent
  step — do not silently delete it, and do not leave an obligation the project cannot satisfy.

```markdown
/goal

## Goal

[The complete final outcome to be achieved — one paragraph, outcome-shaped, not task-shaped.]

## Scope

Complete all of the following:

1. [Task or deliverable]
2. [Task or deliverable]
3. [Task or deliverable]

Execution order: [Follow this order | Choose the most efficient order].

[DEFAULT GOALS ONLY — omit this sentence when rendering a recorded Scope:]
Include all required implementation, integration, documentation, review, merge, deployment,
and verification work within this goal.

## Definition of Done

The goal is complete only when:

* Every scoped item is fully implemented and integrated.
* Each item has passed its required checks and tests.
* All relevant regression tests pass with no unresolved failures.
* `/pr-to-git` has reviewed the completed work.
* All actionable review findings are resolved and the approved changes are merged.
* Deployment or release is completed in the target environment, when applicable.
* The final merged and deployed version has passed end-to-end testing.
* The deployment or release is verified in the target environment.
* Required documentation and handoff records are updated.

Partial implementation, an unverified deployment, pending review findings, or passing only
some tests does not constitute completion.
```

**Every DoD bullet is subject to the Verification Gate** (`GOVERNANCE-AGENT-GUIDE.md` §8):
each one needs external evidence (test output, build exit code, `docker logs`, HTTP probe,
file mtime + content). "Looks right" satisfies nothing.

---

## 3. The `/loop` block — template

```markdown
/loop

Do not end the session, return control, or provide a final response until the entire Goal and
Definition of Done are satisfied.

Continue working autonomously through the full cycle **that this goal's Scope and Definition of
Done actually call for** — by default: inspect, plan, implement, test, diagnose failures, fix,
review, merge, deploy, and verify. Drop the stages this goal does not include; a goal that
excludes deployment is not completed by deploying it. Maintain a todo list and continue with the
next incomplete item after every intermediate milestone. Do not stop after producing only a
plan, progress report, partial fix, or review.

Ask the user only when progress genuinely requires unavailable credentials, authorization, a
safety-critical confirmation, or a decision that cannot be inferred safely. Complete all
unblocked work before reporting such a blocker.
```

---

## 4. Governance precedence — what `/loop` does NOT override

`/loop` removes **status-report stops**. It does **not** remove **safety stops**. When the two
appear to conflict, governance wins, unconditionally:

| Governance rule | Effect inside a `/loop` |
|---|---|
| Stop-Report Protocol (§7) | **Still stops.** A contradiction between sources halts the loop; report + propose + wait. |
| Verification Gate (§8) | **Still blocks.** No DoD item may be ticked without external evidence. |
| Human-in-the-Loop | **Still asks.** Destructive, irreversible, or outward-facing actions need confirmation. |
| Node-role guard (SOURCE / DEPLOYMENT / FROZEN) | **Still blocks.** A `/loop` never converts a DEPLOYMENT or FROZEN node into a writable one. |
| `/full-finish` permission | **Still required.** The loop may not self-authorize a release. |
| File-collision guard | **Still blocks.** A parallel session's claim is not a status stop. |
| One active HANDOFF | **Still enforced.** The loop may not create a second active handoff. |

**A governance stop pauses the loop; it does not by itself end the session.** Most of the rows
above are *waits*: Stop-Report reports and waits for the user to choose, Human-in-the-Loop asks
and waits for a yes. If the answer arrives and the work can continue, **resume the loop and render
nothing** — ending the session there would hand over a mid-decision handoff describing a state
that stopped being true the moment the user answered. The session ends, and a continuation prompt
is rendered, only on §1's three conditions: context exhausted, the user stopped, or the blocker
cannot be resolved in this session (no answer available, or the answer is "not now").

When that does happen, a governance stop is a **legitimate loop exit**: record it under *Blockers*
and close — that is compliance, not failure.

---

## 5. Context-limit exception — template

`[CONTEXT_THRESHOLD]` default: **91%**. Lower it (e.g. 85%) when the remaining work needs large
file reads; never raise it above 93% — below roughly 7% headroom there is not enough room left
to write a correct handover.

```markdown
## Loop Exception — Context Limit

If context usage reaches [CONTEXT_THRESHOLD]:

1. Stop starting new implementation work.
2. Preserve the current state safely.
3. Update the project plan, documentation, and handoff records (/live-state-orchestrator).
4. Create a copy-ready prompt for the next session containing:

   * The original goal and completion criteria.
   * Completed work and verification evidence.
   * The exact current state.
   * Remaining todo items.
   * Failures, risks, blockers, and unresolved review findings.
   * Relevant files, branches, commits, deployments, and test results.
   * The precise next action.
   * This same /loop and context-limit exception.
5. End the session only after the continuation prompt is complete.

Reaching the context limit does not mean the goal is complete. The next session must resume
from the documented stopping point and continue until full completion.

Current context capacity: [OPTIONAL_REMAINING_CONTEXT_OR_TOKEN_ESTIMATE].
```

**Step 4 obeys the anti-duplication rule in §0.** "Completed work", "current state" and
"remaining todos" are rendered as **pointers plus one-line summaries** — the full record stays
in `HANDOFF.md`, `Plans/PLAN.md` and `docs/context/OPEN-PROBLEMS.md`.

**Step 3 before step 4, always.** The canonical files are written first; the prompt is rendered
from them. Rendering first and writing after is how the two drift apart.

---

## 6. Placeholders

| Placeholder | Fill with | Source |
|---|---|---|
| `[Task or deliverable]` | One scoped item, verb-first | user request / `Plans/PLAN.md` |
| Definition of Done | The goal's **recorded** criteria, verbatim; the §2 list only when none was stated | user request / `Plans/PLAN.md` / active `HANDOFF.md` |
| `Execution order` | `Follow this order` when items are dependent; `Choose the most efficient order` when independent | dependency analysis |
| `[CONTEXT_THRESHOLD]` | `91%` default | §5 |
| `[OPTIONAL_REMAINING_CONTEXT_OR_TOKEN_ESTIMATE]` | Measured remaining budget, or omit the line | harness |

Leaving a literal placeholder in a rendered prompt is a defect — it hands the next session a
blank where a decision belonged. Either fill it or delete the line.

---

## 7. Rendered example (shape only)

```markdown
/goal

## Goal
Ship the retry-budget fix end to end: merged on master, deployed to prod, verified live.

## Scope
1. Fix the unbounded retry in lib/queue.js.
2. Add regression coverage for the 429 path.
3. Release and verify in production.
Execution order: Follow this order.

## Definition of Done
[the goal's RECORDED Definition of Done, verbatim — the §2 bullets only if none was stated]

/loop
[the block from §3 — unmodified]

## Loop Exception — Context Limit
[the block from §5, threshold 91%]

## State pointers (do not restate — read these)
- Handoff: docs/context/HANDOFF.md        (status: active)
- Plan:    Plans/PLAN.md                  (SP-3, IN_PROGRESS)
- Open:    docs/context/OPEN-PROBLEMS.md  (#41 open)
- Branch:  fix/retry-budget @ 4c94156     (2 commits, unpushed)

## Verified so far
- Item 1 — DONE. Evidence: npm test 46/46 PASS.
- Item 2 — DONE. Evidence: new case fails on the pre-fix commit.

## Blockers
- Item 3 blocked: prod deploy needs owner approval; owner unreachable this session, so the
  Human-in-the-Loop wait became an exit rather than a pause (§4).

## Precise next action
Ask the owner to approve the prod deploy, then run /full-finish.
```

---

## 8. Related

- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §6 (HANDOFF lifecycle), §7 (Stop-Report), §8 (Verification Gate), §18 (index entry for this protocol)
- `/live-state-orchestrator` — writes the canonical files, then renders this prompt
- `/full-finish` — end-of-goal pipeline; renders this prompt only when the goal is still open
- `/pre-close-check` — runs before any handoff write
