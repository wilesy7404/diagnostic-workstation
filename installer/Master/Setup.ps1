# Setup.exe entry point. PS2EXE compiles this file.
# One run: the exe manifest asks for administrator approval, then this script
# runs the bundled Install-Master.ps1 and passes its parameters through.
# -WhatIf and /report print the resolved brand and the package file list.
# Windows PowerShell 5.1.
[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$Brand,
  [ValidateSet('beta', 'stable')]
  [string]$Channel = 'beta',
  [string]$Tag,
  [string]$Source,
  [switch]$OfflineOnly,
  [switch]$VerifyOnly,
  [switch]$AllowDowngrade,
  [switch]$WhatIf,
  [switch]$Report,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Remaining
)

$ErrorActionPreference = 'Stop'

function Find-SetupPlanPath {
  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace([string]$ScriptRoot)) {
    $fromExe = Join-Path -Path (Join-Path -Path (Join-Path -Path (Join-Path -Path ([string]$ScriptRoot) -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'lib') -ChildPath 'SetupPlan.ps1'
    [void]$candidates.Add($fromExe)
  }
  if ($PSScriptRoot) {
    [void]$candidates.Add((Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'lib') -ChildPath 'SetupPlan.ps1'))
  }
  try {
    $proc = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($proc -and $proc -notmatch '(?i)(^|[\\/])(powershell|pwsh)(\.exe)?$') {
      $dir = Split-Path -Parent $proc
      $fromProc = Join-Path -Path (Join-Path -Path (Join-Path -Path (Join-Path -Path $dir -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'lib') -ChildPath 'SetupPlan.ps1'
      [void]$candidates.Add($fromProc)
    }
  } catch { }
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }
  return $null
}

function Test-SetupShouldPrompt {
  if ($env:GITHUB_ACTIONS -eq 'true') { return $false }
  if ($env:CI -eq 'true') { return $false }
  try {
    if ([Console]::IsInputRedirected) { return $false }
  } catch {
    return $false
  }
  if (-not [Environment]::UserInteractive) { return $false }
  return $true
}

try {
  $planPath = Find-SetupPlanPath
  if (-not $planPath) {
    Write-Output 'Setup could not find the package root. Nothing was installed.'
    exit 1
  }
  . $planPath
  $packageRoot = Get-SetupPackageRoot
  if ([string]::IsNullOrWhiteSpace($packageRoot)) {
    Write-Output 'Setup could not find the package root. Nothing was installed.'
    exit 1
  }
  $lib = Join-Path -Path (Join-Path -Path (Join-Path -Path $packageRoot -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'lib'
  . (Join-Path -Path $lib -ChildPath 'Common.ps1')
  . (Join-Path -Path $lib -ChildPath 'Catalog.ps1')
  $plan = Get-SetupPlan -PackageRoot $packageRoot -Brand $Brand -Channel $Channel -Tag $Tag -Source $Source -OfflineOnly:$OfflineOnly -VerifyOnly:$VerifyOnly -AllowDowngrade:$AllowDowngrade -WhatIf:$WhatIf -Report:$Report -Remaining $Remaining -NonInteractive:(-not (Test-SetupShouldPrompt))
  foreach ($line in @($plan.Lines)) { Write-Output $line }
  if ($plan.Report -or [int]$plan.ExitCode -ne 0) { exit [int]$plan.ExitCode }
  if ([string]::IsNullOrWhiteSpace([string]$plan.Installer) -or -not (Test-Path -LiteralPath ([string]$plan.Installer) -PathType Leaf)) {
    Write-Output 'Install-Master.ps1 is missing from this package. Nothing was installed.'
    exit 1
  }
  $parameters = $plan.Parameters
  & ([string]$plan.Installer) @parameters
} catch {
  Write-Output ([string]$_.Exception.Message)
  exit 1
}
exit 0
