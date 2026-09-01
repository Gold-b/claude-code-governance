# Session record — continuation protocol + framework versioning (2026-08-25)

> Covers PRs #4, #5 and #6, merged the same day. Written to the rule in Agent Guide §19: this is a
> **public** repository, so no private project names, absolute local paths or session ids — only
> what is reusable.
>
> The changes themselves are documented where they belong (Agent Guide §18/§19/§20, the docs, the
> skills). What follows is what the review loop exposed, which is not visible from the diff.

## What shipped

**#4 — `bundle/docs/NEXT-SESSION-HANDOVER.md`.** The renderer spec for a goal-scoped continuation
prompt: `/goal` + `/loop` + a context-limit exception. Wired into both guides and four skills.

**#5 — `docs/context/NEXT-SESSION-PROMPT.md` made canonical.** #4 stored the rendered prompt inside
`HANDOFF.md`, reasoning that a separate file would be a second state record. Sound reasoning,
wrong conclusion — reached without looking at what projects using the framework already do. Every
governed project already kept one as its own file, under three different names in three different
locations, because `init-governance` never scaffolded it. The framework did not have this artifact
*wrong*; it did not have it **at all**.

**#6 — framework versioning + update advisory.** The framework had no version number. There was no
way for a machine to learn that a release had happened: every install was "whatever was in the
clone that day", and a fixed bug could sit unshipped indefinitely with nothing reporting it.
Also wrote **§19**, which three files had referenced for months without it existing.

## The number that matters

Seven review rounds, 33 findings, every one real.

**Five of the seven rounds found defects introduced by the previous round's fixes.**

That is the finding. Not "the original code was weak" — the original code was reviewed and
corrected each time, and each correction shipped its own defect. A fix is not lower-risk than the
code it fixes, and reviewing only the original leaves the more dangerous half unexamined.

## Four tests that could not fail

All four were written by the author, all four passed, all four proved nothing. They are listed
together because the individual causes look unrelated and the pattern does not.

1. **A threshold above the ceiling.** A timing assertion used 8000 ms to prove a network fetch was
   detached — while the fetch itself was capped at 3 s. Removing the `&` left it green. Replaced
   with a stub that sleeps 3 s and a 2500 ms bound: detached 1279 ms, synchronous 4408 ms.
2. **A precondition that was never true.** A cleanup routine lives *inside* a staleness gate; the
   test wrote a fresh cache file, so the gate stayed shut and the routine never ran. The test then
   asserted that two *other* files survived — never that the target was removed. Deleting the
   cleanup line entirely left the suite green.
3. **A fixture that collapsed every case into one.** `printf "%s"` wrote a literal `\n`, so twelve
   distinct role-detection inputs all became invalid and all returned the same fallback. The two
   functions under comparison "agreed" because both saw the same garbage.
4. **A comparison that became a tautology.** Once one function was refactored to delegate to the
   other, "these two agree" compared code with itself. Undoing the delegation left the suite green
   while reintroducing the bug the assertion existed to catch.

**The repair in each case was the same shape:** assert the *value*, not the *agreement*; assert the
*precondition* the assertion depends on; and watch the test go red before believing it.

## Two "verified" claims that were measured wrong

- **`$?` from the wrong process.** A dry-run was reported as "exits 0" after reading `$?` from the
  `tail` at the end of a pipe rather than from the script. The script was exiting non-zero and
  dying a third of the way through.
- **A real signal dismissed as noise.** A latency check was run n=1 per condition, unpaired: 1267 ms
  vs 1074 ms, written off as jitter. An interleaved A/B at n=10 found a **median 494 ms added to
  every session start**, in a hook that runs in every project, for a feature that matters once per
  release. The data was there; the reading was wrong.

Fixing that meant removing about ten subshell forks — on this platform a fork costs ~70 ms. The
first attempt at the last one **also failed and had to be measured to discover it**: truncating a
string after `read` changed nothing, because the cost *is* the read. `read -N 4096` on the same
1 MB input is 28 ms against 2620 ms.

## Silent-wrong beats loud-wrong, every time

Not one of the serious findings was a crash. The dangerous ones all produced a *plausible* result:

- A version file with no trailing newline read as empty, so a machine that was **exactly up to
  date** was told at every session start that it had no version marker.
- Two readers disagreed about what "the version in the file" is. One slurped the whole file and
  stripped whitespace, turning a two-line file into a single concatenated token — digits and dots,
  therefore **passing validation**. Corruption read as a plausible version.
- A partially failed install deleted a valid version marker without backing it up, turning a
  working machine into one that nagged forever — while a *different* failure path, the genuinely
  destructive one, was the only one the documentation did not mention.
- A preview mode printed the opposite of what the real run would do, exit code included.
- A network-fetched value was validated with a glob, so `1.9.9` followed by arbitrary text matched
  and was echoed into the agent's context at session start.

A crash gets fixed the day it happens. These do not announce themselves at all.

## For the next person touching this

- **Read the *fix* as adversarially as the bug.** Five of seven rounds needed it.
- **A green test is not evidence until you have seen it red.** Mutate it. If nothing turns red, the
  test is decoration.
- **Assert the precondition your assertion depends on.** A gate that never opened, a fixture that
  produced identical inputs, a threshold nothing could cross — all pass silently.
- **Two functions that answer the same question must share one implementation**, not two
  implementations kept in step by hope. Delegation beats duplication; where delegation is
  impossible, an *absolute* assertion on each side beats comparing them to each other.
- **Measure paired and interleaved, or do not claim a number.** And measure the fix, not just the
  bug.
- **Editing tooling can corrupt what you write.** JSON-decoded strings turn `\t` and `\n` into real
  control characters inside quotes; shell heredocs containing apostrophes can fail to parse. Both
  happened here. Prefer escape-free constructs in shipped code and verify the bytes.
