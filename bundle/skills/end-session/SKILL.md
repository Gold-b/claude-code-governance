---
name: end-session
description: "DEPRECATED — merged into /full-finish. Use /full-finish instead."
---

# /end-session — DEPRECATED

**This skill has been merged into `/full-finish` (Phase 3.1 — Documentation & Handoff Agent).**

Session handoff functionality (forensics, handoff document, memory extraction, WhatsApp notification) is now handled by the **Documentation & Handoff Agent** inside the `/full-finish` pipeline.

**Use `/full-finish` instead.** It runs the full release pipeline including session handoff.

If you ONLY need a session handoff without a release (no version bump, no EXE build, no GitHub release):
- Run **`/live-state-orchestrator`** — the canonical engine for the PLAN.md / MEMORY.md / OPEN-PROBLEMS.md / HANDOFF.md lifecycle (active → consumed → archived). This is the SAME engine the Stop hook (`end-session.sh`) enforces before it allows a session to end.
- Or run `/full-finish` — it will detect "docs only" changes and skip QA/Security phases automatically (Phase 1 routing table), and runs /live-state-orchestrator internally (Part D).
