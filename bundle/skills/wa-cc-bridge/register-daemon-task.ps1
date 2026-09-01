# register-daemon-task.ps1 - register the WA-CC bridge daemon as a logon Scheduled Task
# Launched via wscript VBS so NO console window ever appears (owner rule 2026-07-21).
$name = "WA-CC-Bridge-Daemon"
$vbs = "$env:USERPROFILE\.claude\skills\wa-cc-bridge\wa-daemon-launcher.vbs"
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbs`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit (New-TimeSpan -Days 3650) -StartWhenAvailable -Hidden
Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings
Start-ScheduledTask -TaskName $name
Get-ScheduledTask -TaskName $name | Format-List TaskName, State
