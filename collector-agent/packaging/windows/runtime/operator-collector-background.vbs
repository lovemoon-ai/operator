Option Explicit

Dim base, command, quote, shell
base = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
quote = Chr(34)
command = "cmd.exe /d /c " & quote & quote & base & "\python.exe" & quote & _
    " -m operator_collector run >> " & quote & base & "\agent.log" & quote & " 2>&1" & quote
Set shell = CreateObject("WScript.Shell")
shell.Run command, 0, False
