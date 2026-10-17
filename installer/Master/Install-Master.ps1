# Install one approved brand bundle, then disable Windows Update with Windows Update Blocker.
# Windows Defender is recorded as blocked until Defender Control has a verified silent command line.
# This script does not change Winlogon, the shell, or Run startup, and it does not open dControl.
# Windows PowerShell 5.1. Run it elevated on a throwaway Windows VM, not on a live shop PC.
[CmdletBinding()]
param(
  [ValidateSet('mercedes', 'bmw')]
  [string]$Brand,
  [ValidateSet('beta', 'stable')]
  [string]$Channel = 'beta',
  [string]$Tag,
  [string]$Source,
  [switch]$OfflineOnly,
  [switch]$VerifyOnly,
  [switch]$AllowDowngrade,
  [switch]$Library
)

$ErrorActionPreference = 'Stop'
$masterDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $masterDir 'lib/Common.ps1')
. (Join-Path $masterDir 'lib/Catalog.ps1')
. (Join-Path $masterDir 'lib/Bundle.ps1')
. (Join-Path $masterDir 'lib/Security.ps1')
. (Join-Path $masterDir 'lib/Install.ps1')

if ($Library -or $env:MASTER_INSTALLER_LIBRARY -eq '1') { return }

if ([string]::IsNullOrWhiteSpace($Brand)) {
  throw 'Pass -Brand mercedes or -Brand bmw. Nothing was installed.'
}
if (-not (Test-MasterHostWindows)) {
  throw 'The master installer runs on Windows. Nothing was installed.'
}
if (-not $VerifyOnly -and -not (Test-IsWindowsAdmin)) {
  throw 'Run the master installer from an elevated PowerShell. Nothing was installed.'
}

$repo = Find-MasterRepoRoot $masterDir
$result = Install-ApprovedBrand -Brand $Brand -Channel $Channel -Tag $Tag -Source $Source -OfflineOnly:$OfflineOnly -VerifyOnly:$VerifyOnly -AllowDowngrade:$AllowDowngrade -ApplySecurity:(-not $VerifyOnly) -RepoRoot $repo
$result | Format-List | Out-String | Write-Output
if ($VerifyOnly) { return }
if ([string]$result.windowsUpdate -ne 'disabled') {
  Write-Output 'Windows Update was not disabled. The brand files were left in place. Shell startup was not changed.'
  exit 2
}
if ([string]$result.defender -eq 'blocked-cli-unverified') {
  Write-Output 'DEFENDER BLOCKED: Defender Control v2.1 has no verified silent command line. Defender was not changed. No dControl window was opened.'
  exit 10
}
exit 0
