# Lessons & Failure Log - intake inbox

> This is an INBOX, not a second journal. The durable records already exist and outrank it:
> `docs/context/GOTCHAS.md` (bug-driven rules, append-only; 14 entries measured 2026-09-15) and
> `docs/context/MEMORY.md` ("Lessons Learned", "Repeated Pitfalls"). Both are write-protected by
> `governance-guard.sh` and need a success token - which is exactly why a correction made mid-task
> tends to be lost: the write is gated, the moment passes. Write it HERE at once, in the format
> below. At close, `/live-state-orchestrator` promotes each entry into GOTCHAS (a failure with a
> reproducible cause) or MEMORY (a pattern) and deletes it from "Pending". A pending entry that
> survives a close is an open finding, not a lesson.
>
> "Active Rules" is the ONLY block meant to be read in full at every session start. Keep it under
> 15 lines: one constraint per line plus a pointer to the entry that justifies it. The body of a
> rule lives in its source entry, never here. Loader wiring is proposal change F; until it is
> applied, the bootstrapper reads this block by instruction, not by hook - that is a prompt-level
> control and should be described as one.
>
> Created 2026-09-15 by the Boris Cherny harness audit (`docs/context/BORIS-HARNESS-PROPOSAL.md`).
> NOT gitignored yet (proposal change C): placeholders only until that lands.

## Rule Template
- **Pattern / Trigger:** where the mistake happened - what was being done, which file or command
- **Correction:** what the user or the verifier said, quoted
- **Enforced Constraint:** the rule that makes the repeat impossible - and WHO enforces it
  (a hook, a selftest case, a skill step), or an honest "prompt-level only"
- **Promoted to:** GOTCHAS #N / MEMORY section / hook + selftest case - filled at close

---

## Active Rules (read in full at session start)
- Measure counts; never restate them from an index - the index rots. (MEMORY "Repeated Pitfalls"; GOTCHAS frontmatter said `total_entries: 11` against 14 entries on 2026-09-15)
- A negative claim needs an enumeration of the whole surface, not a filtered search. (~/.claude/CLAUDE.md "Enumerate Before You Claim"; GOTCHAS #2)
- A green check without a positive control in the same run is not evidence. (CONVENTIONS "Verification"; MEMORY "Lessons Learned")
- A script with a live instance is read-only - edit a copy or wait. (GOTCHAS #14)
- A tracked file carries a placeholder or an env lookup, never a real value. (CLAUDE.md rule 1)
- A control has three states and only "registered" does anything; a remedy has the same three. (CLAUDE.md rule 2; GOTCHAS #10)
- A closing report describes the past only; anything found while summarising goes back to tools or into a file. (~/.claude/CLAUDE.md rule 6b; `close-report.sh`)

## Pending (promote at close, then delete)
<none>
