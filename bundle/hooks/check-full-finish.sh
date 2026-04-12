#!/bin/bash
# Hook: Remind Claude Code to run /full-finish before stopping
# Triggered on "Stop" event — blocks stop if uncommitted code changes exist.

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

# Check for STAGED changes in code files (indicates current session made changes)
STAGED_CHANGES=$(git diff --cached --name-only -- '*.js' '*.ts' '*.json' '*.ps1' '*.sh' '*.bat' '*.yml' '*.iss' 2>/dev/null)

if [ -n "$STAGED_CHANGES" ]; then
  echo "Staged code changes detected. Run /full-finish before stopping." >&2
  exit 2  # Block stop — sends Claude back to work
fi

exit 0  # No staged code changes — allow stop
