<#
.SYNOPSIS
  Teach Windows about .hb files: run one on double-click, edit it in VS Code.

.DESCRIPTION
  Writes a file association under HKCU\Software\Classes - per-user, so it needs
  no administrator, and -Unregister removes exactly what it added. Nothing here
  touches HKLM or the system-wide association.

  Two verbs, deliberately:

    open   (the double-click)  runs the program with hb, in a console that
                               pauses afterwards - a run whose output vanishes
                               with the window would tell you nothing.
    edit                       opens it in VS Code.

  A program started by double-click is handed no --dir, so it can read and
  write nothing at all (SPEC.md §9/§16). That is what makes "run on
  double-click" a safe default here rather than a reckless one: the worst a
  file you were sent can do is compute.

  PowerShell rather than the shell the rest of scripts/ is written in, because
  the registry is what this touches and there is no portable spelling for that.

.PARAMETER Binary
  The hb.exe to run. Defaults to the one in the repository root.

.PARAMETER Editor
  The editor for the `edit` verb. Defaults to VS Code where it is installed.

.PARAMETER Unregister
  Remove the association instead of adding it.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\register_hb_windows.ps1
  powershell -ExecutionPolicy Bypass -File scripts\register_hb_windows.ps1 -Unregister
#>

[CmdletBinding()]
param(
  [string]$Binary,
  [string]$Editor,
  [switch]$Unregister
)

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$progId = "HashedBuild.Program"
$classes = "HKCU:\Software\Classes"

function Find-Binary {
  if ($Binary) { return (Resolve-Path $Binary).Path }
  $candidate = Join-Path $repo "hb.exe"
  if (Test-Path $candidate) { return $candidate }
  throw "no hb.exe in $repo - build one first: odin build src -out:hb.exe"
}

function Find-Editor {
  if ($Editor) { return (Resolve-Path $Editor).Path }
  $candidates = @(
    "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
    "$env:ProgramFiles\Microsoft VS Code\Code.exe",
    "${env:ProgramFiles(x86)}\Microsoft VS Code\Code.exe"
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  return $null
}

# Explorer caches associations; without this the change shows up only after a
# restart, which looks like the script did nothing.
function Notify-Explorer {
  $signature = '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);'
  Add-Type -MemberDefinition $signature -Namespace HbWinApi -Name Shell -ErrorAction SilentlyContinue
  [HbWinApi.Shell]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero) # SHCNE_ASSOCCHANGED
}

if ($Unregister) {
  foreach ($key in @("$classes\$progId", "$classes\.hb")) {
    if (Test-Path $key) {
      Remove-Item $key -Recurse -Force
      Write-Host "removed $key"
    }
  }
  Notify-Explorer
  Write-Host "`n.hb is no longer registered."
  return
}

$hb = Find-Binary
$code = Find-Editor

New-Item -Path "$classes\.hb" -Force | Out-Null
Set-ItemProperty -Path "$classes\.hb" -Name "(default)" -Value $progId

New-Item -Path "$classes\$progId" -Force | Out-Null
Set-ItemProperty -Path "$classes\$progId" -Name "(default)" -Value "HashedBuild program"

# The default verb: what a double-click does.
Set-ItemProperty -Path "$classes\$progId" -Name "EditFlags" -Value 0x00010000 -Type DWord
New-Item -Path "$classes\$progId\shell" -Force | Out-Null
Set-ItemProperty -Path "$classes\$progId\shell" -Name "(default)" -Value "open"

# `& pause` so the value the program evaluated to is still on screen when it
# finishes. cmd strips the outermost quotes of /c's argument, which is why the
# whole thing is wrapped in one more pair.
New-Item -Path "$classes\$progId\shell\open\command" -Force | Out-Null
$runCommand = 'cmd.exe /c ""{0}" "%1" & pause"' -f $hb
Set-ItemProperty -Path "$classes\$progId\shell\open\command" -Name "(default)" -Value $runCommand
Set-ItemProperty -Path "$classes\$progId\shell\open" -Name "(default)" -Value "&Run"

if ($code) {
  New-Item -Path "$classes\$progId\shell\edit\command" -Force | Out-Null
  Set-ItemProperty -Path "$classes\$progId\shell\edit\command" -Name "(default)" -Value ('"{0}" "%1"' -f $code)
  Set-ItemProperty -Path "$classes\$progId\shell\edit" -Name "(default)" -Value "&Edit in VS Code"
  # Explorer draws the type's icon from here; VS Code's is better than none.
  New-Item -Path "$classes\$progId\DefaultIcon" -Force | Out-Null
  Set-ItemProperty -Path "$classes\$progId\DefaultIcon" -Name "(default)" -Value ('"{0}",0' -f $code)
}

Notify-Explorer

Write-Host "registered .hb -> $progId"
Write-Host "  double-click  $runCommand"
if ($code) {
  Write-Host "  right-click > Edit in VS Code"
} else {
  Write-Host "  (no VS Code found, so no edit verb - pass -Editor to name one)"
}
Write-Host "`nUndo with: powershell -ExecutionPolicy Bypass -File scripts\register_hb_windows.ps1 -Unregister"
