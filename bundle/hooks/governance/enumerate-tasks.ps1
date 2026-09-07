# ============================================================================
# enumerate-tasks.ps1 — every Scheduled Task, with its target resolved.
#
# Called by enumerate-before-claiming.sh. It lives as its own .ps1 ON PURPOSE:
# the first version was PowerShell embedded inside a bash string, and the
# escaping was eaten on the way to disk -- the fourth time that happened in one
# session (see gotcha #359). Code that must survive being written should not
# contain escapes at all.
#
#   -OnlyBroken   print only tasks whose target file does not exist
# ============================================================================
param([switch]$OnlyBroken)

$ErrorActionPreference = 'SilentlyContinue'

$rows = Get-ScheduledTask | ForEach-Object {
    $t    = $_
    $info = $t | Get-ScheduledTaskInfo
    foreach ($a in $t.Actions) {
        $exe = $a.Execute
        $arg = $a.Arguments

        # Resolve the file the task will actually run. A task whose target is
        # gone is either already failing or about to -- that is the whole point
        # of this script, and it is the line a filtered search never shows you.
        $target = ''
        if ($arg -and $arg -match '([A-Za-z]:\\[^"]+?\.(ps1|bat|cmd|js|vbs|exe))') {
            $target = $Matches[1]
        }
        elseif ($exe -and $exe -match '^[A-Za-z]:\\') {
            $target = $exe
        }

        $exists = 'n/a'
        if ($target) { if (Test-Path $target) { $exists = 'ok' } else { $exists = 'MISSING' } }

        [PSCustomObject]@{
            Name   = $t.TaskName
            State  = $t.State
            RC     = $info.LastTaskResult
            Last   = $info.LastRunTime
            Target = $target
            Exists = $exists
        }
    }
}

if ($OnlyBroken) {
    $rows = $rows | Where-Object { $_.Exists -eq 'MISSING' }
} else {
    # Missing targets first: the finding should not be buried under 200 rows of
    # Windows' own healthy tasks.
    $rows = $rows | Sort-Object -Property @{ Expression = { if ($_.Exists -eq 'MISSING') { 0 } else { 1 } } }, Name
}

if (-not $rows) {
    '  none'
} else {
    $rows | ForEach-Object {
        '{0,-34} {1,-9} target={2,-8} rc={3,-12} {4}' -f $_.Name, $_.State, $_.Exists, $_.RC, $_.Target
    }
}
