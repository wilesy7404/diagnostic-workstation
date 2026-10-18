# Applies one Set-MpPreference batch as SYSTEM. The parent scheduled task deletes itself after this file exits.
# Policy values are written by the elevated admin process and are not accepted here.
# Windows PowerShell 5.1. Join-Path uses -Path and -ChildPath only.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$CommandFile,
  [Parameter(Mandatory = $true)][string]$ResultFile
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path -Path $here -ChildPath 'Common.ps1')
. (Join-Path -Path $here -ChildPath 'Defender.ps1')

$outcome = $null
try {
  $data = Read-JsonFile $CommandFile
  $commands = @($data.commands | Where-Object { $_ })
  foreach ($command in $commands) {
    if ([string]$command.kind -ne 'Set-MpPreference') { throw "SYSTEM job refuses $($command.kind)" }
  }
  $ran = Invoke-DefenderCommands $commands $null
  $outcome = [pscustomobject]@{
    ok = [bool]$ran.ok
    error = $ran.error
    applied = @($ran.applied)
  }
} catch {
  $outcome = [pscustomobject]@{ ok = $false; error = $_.Exception.Message; applied = @() }
}

Write-Utf8NoBom $ResultFile (($outcome | ConvertTo-Json -Depth 8) + "`n")
if (-not $outcome.ok) { exit 1 }
exit 0
