' wa-daemon-launcher.vbs - launch the WA-CC bridge daemon with NO console window.
' (node.exe is a console app; a Scheduled Task running it interactively pops a CMD
'  window - owner complaint 2026-07-21. wscript+Run(...,0) is fully invisible.)
Dim shell, nodeExe, script
Set shell = CreateObject("Wscript.Shell")
nodeExe = "C:\Program Files\nodejs\node.exe"
script = shell.ExpandEnvironmentStrings("%USERPROFILE%") & "\.claude\skills\wa-cc-bridge\wa-monitor.js"
' Wait=True keeps wscript alive as the task's process: Task Scheduler still sees the
' daemon as Running, kills the whole tree on Stop, and restart-on-fail still works.
shell.Run """" & nodeExe & """ """ & script & """ --daemon", 0, True
