# Install one approved brand bundle, then disable Windows Update and Windows Defender.
# Defender uses documented Set-MpPreference, policy, and service changes.
# Elevation relaunches this script at most once. The brand-root install lock stops WorkstationManager from opening another PowerShell.
# Defender policy writes stay in this process. Set-MpPreference and service changes run as SYSTEM in a transient task that is deleted before this script exits.
# This script does not change Winlogon, the shell, or Run startup.
# Windows PowerShell 5.1. Run it on a throwaway Windows VM, not on a live shop PC.
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
  [switch]$Library,
  [switch]$ElevatedRelaunch
)

$ErrorActionPreference = 'Stop'
$masterDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $masterDir 'lib/Common.ps1')
. (Join-Path $masterDir 'lib/Catalog.ps1')
. (Join-Path $masterDir 'lib/Bundle.ps1')
. (Join-Path $masterDir 'lib/Defender.ps1')
. (Join-Path $masterDir 'lib/Security.ps1')
. (Join-Path $masterDir 'lib/Install.ps1')

if ($Library -or $env:MASTER_INSTALLER_LIBRARY -eq '1') { return }

if ([string]::IsNullOrWhiteSpace($Brand)) {
  throw 'Pass -Brand mercedes or -Brand bmw. Nothing was installed.'
}
if (-not (Test-MasterHostWindows)) {
  throw 'The master installer runs on Windows. Nothing was installed.'
}
Enter-MasterInstallerProcess -ScriptPath $MyInvocation.MyCommand.Path -Bound $PSBoundParameters -AlreadyRelaunched:$ElevatedRelaunch -SkipElevation:$VerifyOnly

$repo = Find-MasterRepoRoot $masterDir
$result = Install-ApprovedBrand -Brand $Brand -Channel $Channel -Tag $Tag -Source $Source -OfflineOnly:$OfflineOnly -VerifyOnly:$VerifyOnly -AllowDowngrade:$AllowDowngrade -ApplySecurity:(-not $VerifyOnly) -RepoRoot $repo
$result | Format-List | Out-String | Write-Output
if ($VerifyOnly) { return }
if ([string]$result.windowsUpdate -ne 'disabled') {
  Write-Output 'Windows Update was not disabled. The brand files were left in place. Shell startup was not changed.'
  exit 2
}
if ([string]$result.defender -eq 'tamper-blocked') {
  Write-Output 'Tamper Protection stayed on. Windows Defender was not changed. Turn it off in Windows Security, then run this installer again.'
  exit 10
}
if ([string]$result.defender -ne 'disabled') {
  Write-Output 'Windows Defender was not disabled. The brand files were left in place. Shell startup was not changed.'
  exit 11
}
exit 0
