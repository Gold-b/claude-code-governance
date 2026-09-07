#!/usr/bin/env bash
# ============================================================================
# enumerate-before-claiming.sh — list the WHOLE surface, then say what is broken.
#
# WHY THIS EXISTS (2026-09-07). A session was asked whether a retired tree was
# safe to delete. It answered by FILTERING: it searched the Scheduled Tasks for
# the string "GoldB", found three, handled them, and reported that no vector
# remained. Five more existed. One was named "OpenClaw_..." and so never matched
# the filter; it pointed at a script that a rebranding commit had renamed months
# earlier, and it had been failing at 03:00 every morning since. The same
# session also asserted "nothing can recreate these" without ever searching for
# scripts that create tasks. There were six.
#
# One mistake, made twice: FILTER BEFORE ENUMERATE, and ASSERT BEFORE MEASURE.
# A filtered query proves something about what matched. It can never support the
# sentence "there is nothing else".
#
# WHAT THIS DOES. It refuses to filter. It prints every Scheduled Task, every
# startup entry and every Run key, and for each resolves the target and says
# whether that target EXISTS. A task pointing at a missing file is the highest
# signal line in the output.
#
# READ-ONLY. It changes nothing. Removing a task needs elevation and is the
# owner's call.
#
#   enumerate-before-claiming.sh                  full inventory
#   enumerate-before-claiming.sh --broken         only missing targets
#   enumerate-before-claiming.sh --creators [dir] scripts that CREATE tasks
#
# The last mode answers the question that was got wrong: "can this come back?"
# It greps a tree for schtasks / Register-ScheduledTask and prints the task
# names each file registers, so a rebuild's blast radius is measured.
# ============================================================================
set -uo pipefail

MODE="${1:-all}"
SCAN_DIR="${2:-.}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Scripts that CREATE scheduled tasks ─────────────────────────────────────
if [ "$MODE" = "--creators" ]; then
  printf '== scripts that register Scheduled Tasks under %s ==\n' "$SCAN_DIR"
  found=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    found=1
    names=$(grep -ohE "(/TN|/tn|-TaskName)[[:space:]]+['\"]?[A-Za-z0-9_ .-]+" "$f" 2>/dev/null \
            | sed -E "s@^(/TN|/tn|-TaskName)[[:space:]]+['\"]?@@" | sort -u | tr '\n' '|')
    printf '  %s\n      registers: %s\n' "$f" "${names:-<name built dynamically - READ THE FILE>}"
  done < <(grep -rlE "schtasks|Register-ScheduledTask|New-ScheduledTask" \
             --include="*.ps1" --include="*.bat" --include="*.cmd" --include="*.vbs" \
             --include="*.js" --include="*.sh" --include="*.iss" \
             "$SCAN_DIR" 2>/dev/null | grep -v node_modules | grep -v "/.claude/hooks/governance/" | grep -v "enumerate-before-claiming")
  [ "$found" = "0" ] && printf '  none\n'
  printf '\nA dynamically built name is NOT "no task": open the file. That is how five were missed.\n'
  exit 0
fi

# ── Every scheduled task, with its target resolved ──────────────────────────
# The PowerShell lives in its own .ps1 rather than inline: escapes do not
# survive being written through several layers (gotcha #359, four times in one
# session). Code that must survive should contain no escapes at all.
if [ "$MODE" = "--broken" ]; then
  printf '== Scheduled Tasks whose TARGET IS MISSING ==\n'
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$HERE/enumerate-tasks.ps1" -OnlyBroken 2>/dev/null | tr -d '\r'
  exit 0
fi

printf '== Scheduled Tasks (ALL, unfiltered; missing targets first) ==\n'
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "$HERE/enumerate-tasks.ps1" 2>/dev/null | tr -d '\r'

printf '\n== Startup folders ==\n'
_any=0
for d in "${APPDATA:-}/Microsoft/Windows/Start Menu/Programs/Startup" \
         "${ALLUSERSPROFILE:-}/Microsoft/Windows/Start Menu/Programs/Startup"; do
  [ -d "$d" ] || continue
  while IFS= read -r e; do
    [ -n "$e" ] && { printf '  %s/%s\n' "$d" "$e"; _any=1; }
  done < <(ls -1 "$d" 2>/dev/null | grep -v '^desktop\.ini$')
done
[ "$_any" = "0" ] && printf '  (empty)\n'

printf '\n== Run keys ==\n'
powershell.exe -NoProfile -NonInteractive -Command "@('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run') | ForEach-Object { if (Test-Path \$_) { (Get-ItemProperty \$_).PSObject.Properties | Where-Object { \$_.Name -notmatch '^PS' } | ForEach-Object { '  ' + \$_.Name + ' = ' + \$_.Value } } }" 2>/dev/null | tr -d '\r' | head -20

printf '\nRule: a filtered search proves what MATCHED. It never proves "there is nothing else".\n'
