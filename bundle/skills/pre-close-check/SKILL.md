---
name: pre-close-check
description: Pre-close reality check — scans for parallel/recent session outputs before any session close, handoff write, or release. Prevents the "partial/wrong info at close" scenario by verifying git log, file mtimes, version consistency, and active handoff count BEFORE the close skill commits to state.
---

Base directory for this skill: `~/.claude/skills/pre-close-check`

# /pre-close-check — Parallel Session Reality Check

**Language:** Communicate in **Hebrew**. File content + code in **English**.

**Authority:** Mandatory pre-check before `/full-finish`, `/live-state-orchestrator` (handoff writes), `/plan-and-execute` completion, or any governance doc mutation that claims "session state X".

**Why this exists:** On 2026-04-17, a session closed with incomplete info — wrote `HANDOFF-v1.4.112-b.md` and marked it active, while a parallel session had ALREADY released `v1.4.113` with its own handoff. The close skill trusted in-session state, not filesystem reality. This skill prevents that class of error.

---

## When to invoke

- **Auto (mandatory):** invoked internally by `/full-finish`, `/live-state-orchestrator`, `/plan-and-execute` at their CLOSE/FINALIZE step BEFORE writing final state
- **Manual:** `/pre-close-check` when the user suspects parallel session activity or wants to verify state before proceeding

---

## Inputs

- `project_root` — detected from CWD or CLAUDE.md walk-up
- `declared_version` — what the current session believes the version is (optional; default reads version.json)
- `declared_handoff_path` — what the current session believes is the active handoff (optional)

---

## The 5 Checks

### Check 1 — Git log reality (last 60 minutes)
```bash
cd <project_root> && git log --since="60 minutes ago" --pretty=format:'%h|%ai|%s' | head -20
```
If commits exist that the current session did NOT produce → PARALLEL SESSION DETECTED.

Flag commits matching: `Build EXE`, `Bump version`, `Release v*`, `Full-finish`.

### Check 2 — Handoff mtime scan
```bash
find <project_root>/MDs -name "HANDOFF-*.md" -newer <session_start_marker> -printf '%T+ %p\n' 2>/dev/null
```
Any handoff modified AFTER this session's start time = suspected parallel work.

### Check 3 — Version consistency
Compare:
- `version.json` → `version` field
- `CLAUDE.md` → `v1.X.Y` in project overview line
- `docs/context/HANDOFF.md` → `points_to` target filename

All three MUST agree on the version. Mismatch = drift.

### Check 4 — Active handoff count
Count files in `MDs/HANDOFF-*.md` + `MDs/archive/HANDOFF-*.md` with frontmatter `status: active`.
```bash
grep -l "^status: active" <project_root>/MDs/HANDOFF-*.md <project_root>/MDs/archive/HANDOFF-*.md 2>/dev/null
```
Expected: exactly 1. More = drift. Zero = missing handoff.

### Check 5 — CONTEXT-MANIFEST sync
Verify `docs/context/CONTEXT-MANIFEST.md` table has the latest handoff marked `ACTIVE` and matches `docs/context/HANDOFF.md` pointer.

---

## Output

```
[pre-close-check]
- git activity (60m): <count> commits | last: <sha> <subject>
- recent handoff mtimes: <list, newest first>
- version consistency: <ok|DRIFT: version.json=X CLAUDE.md=Y HANDOFF→Z>
- active handoff count: <N expected 1>
- manifest sync: <ok|STALE: manifest says X, HANDOFF.md points to Y>
- verdict: <clean|PARALLEL_SESSION_DETECTED|DRIFT_DETECTED>
```

---

## Stop Conditions

If verdict is NOT `clean`:
1. **STOP** the calling skill immediately. Do NOT proceed with close/handoff/release.
2. Report findings to the user in Hebrew.
3. Ask: "נזהתה פעילות סשן מקבילי / drift. מה לעשות?"
   - Option A: Absorb parallel session state first (run `/parallel-session-merge`)
   - Option B: Override and proceed anyway (dangerous, require explicit "כן, אני יודע")
   - Option C: Abort close

4. Wait for user decision before continuing.

---

## Integration Points

Other skills MUST call this skill at their CLOSE step:

- **`/full-finish`:** BEFORE git commit + release tag creation
- **`/live-state-orchestrator`:** BEFORE writing the new HANDOFF.md or updating PLAN.md milestones
- **`/plan-and-execute`:** BEFORE Phase 3.3 (Governance State Update)
- **`/end-session`:** deprecated, but if called — run this first
- **`/parallel-session-merge`:** already does similar checks; skip if already running

---

## Reference

- Incident 2026-04-17: v1.4.112-b/v1.4.113 parallel close
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §3 (Source-of-Truth Hierarchy)
- `~/.claude/docs/GOVERNANCE-AGENT-GUIDE.md` §7 (Stop-Report Protocol)
