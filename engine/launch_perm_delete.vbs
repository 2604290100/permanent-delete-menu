' SPDX-License-Identifier: GPL-3.0-or-later
' Copyright (C) 2026 2604290100
' launch_perm_delete.vbs
' Hidden launcher for PermanentDelete.ps1 (context menu entry point).
'
' !!!! THIS FILE MUST STAY PURE ASCII !!!!
' wscript reads .vbs as ANSI (GBK on zh-CN). A UTF-8 Chinese comment gets
' mis-decoded, and a trailing multi-byte sequence can even swallow the next
' line break -- which once commented out the "maxLen = 28000" line below and
' silently broke this script. Keep every character in here 7-bit ASCII.
'
' Why this file exists:
'   * powershell.exe is a console app -> calling it directly flashes a black
'     console window. WScript.Shell.Run(..., 0, ...) hides that window for good.
'   * Arguments are re-quoted one by one. A path ending with a backslash
'     (e.g. "C:\dir\") would otherwise swallow the closing quote and corrupt
'     the following arguments, so a trailing backslash is doubled.
'   * If the resulting command line would exceed the ~32k limit (huge
'     multi-selection), the paths are written to a UTF-16 temp file and passed
'     with -ArgsFile instead of on the command line.
Option Explicit

Dim sh, fso, i, arg, cmd, psExe, scriptPath, argsFile, total, f, maxLen, envT
If WScript.Arguments.Count = 0 Then WScript.Quit 0

Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

psExe = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(psExe) Then psExe = "powershell.exe"

scriptPath = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\PermanentDelete.ps1"
If Not fso.FileExists(scriptPath) Then
  MsgBox "PermanentDelete.ps1 not found:" & vbCrLf & scriptPath, 16, "Permanent delete"
  WScript.Quit 1
End If

cmd = """" & psExe & """ -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File """ & scriptPath & """"

total = Len(cmd)
For i = 0 To WScript.Arguments.Count - 1
  total = total + Len(WScript.Arguments(i)) + 4
Next

' Command line budget (~32k). PERMDEL_ARGSFILE_THRESHOLD is a test-only override.
maxLen = 28000
envT = sh.Environment("PROCESS")("PERMDEL_ARGSFILE_THRESHOLD")
If IsNumeric(envT) Then
  If CLng(envT) > 0 Then maxLen = CLng(envT)
End If
' Safety net: whatever happens above, never end up with an empty/bogus budget.
If Not IsNumeric(maxLen) Then maxLen = 28000
If CLng(maxLen) < 1 Then maxLen = 28000

If total <= maxLen Then
  For i = 0 To WScript.Arguments.Count - 1
    arg = WScript.Arguments(i)
    If Len(arg) > 0 Then
      If Right(arg, 1) = "\" Then arg = arg & "\"
      cmd = cmd & " """ & arg & """"
    End If
  Next
Else
  ' Too long for a command line: hand the list over through a file.
  ' The name/extension/location matter: the PowerShell script only accepts
  ' %TEMP%\permdelete_args_*.pdl and never treats a user-selected file as one.
  argsFile = sh.ExpandEnvironmentStrings("%TEMP%") & "\permdelete_args_" & fso.GetTempName() & ".pdl"
  Set f = fso.CreateTextFile(argsFile, True, True)   ' unicode = True (UTF-16 LE)
  For i = 0 To WScript.Arguments.Count - 1
    arg = WScript.Arguments(i)
    If Len(arg) > 0 Then f.WriteLine arg
  Next
  f.Close
  cmd = cmd & " -ArgsFile """ & argsFile & """"
End If

On Error Resume Next
sh.Run cmd, 0, False
If Err.Number <> 0 Then
  MsgBox "Failed to start PowerShell:" & vbCrLf & Err.Description, 16, "Permanent delete"
  WScript.Quit 1
End If
WScript.Quit 0
