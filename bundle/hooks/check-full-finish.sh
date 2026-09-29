#!/bin/bash
# Hook: stop a session from ending with staged code changes that were never committed.
# Triggered on "Stop" (and TaskCompleted) — blocks the stop while staged code changes exist.
#
# 2026-09-29 (owner decision, HITL-removal board): the remedy is the close itself, not a release.
# /full-finish is a release pipeline with a version bump and its own pauses; sending every close
# there made an ordinary session end wait on a human. Now: commit the staged work (add + commit in
# ONE call, then verify). /full-finish only when this close IS a release.

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

# Check for STAGED changes in code files (indicates current session made changes)
STAGED_CHANGES=$(git diff --cached --name-only -- '*.js' '*.ts' '*.json' '*.ps1' '*.sh' '*.bat' '*.yml' '*.iss' 2>/dev/null)

if [ -n "$STAGED_CHANGES" ]; then
  echo "Staged code changes detected - commit them before stopping: git add -- <your paths> && git commit -m \"...\" -- <your paths>" >&2
  echo "in ONE call, then confirm with git show --stat HEAD. The close pushes it: bash ~/.claude/hooks/governance/close-push.sh" >&2
  echo "Run /full-finish only if this close is a release. Do not stop to ask anyone." >&2
  exit 2  # Block stop — sends Claude back to work
fi

exit 0  # No staged code changes — allow stop
