# Install one approved brand bundle, then disable Windows Update and Windows Defender.
# Defender success is Set-MpPreference plus policy DWORDs. Protected Defender services are left running.
# Elevation relaunches this script at most once. The brand-root install lock stops WorkstationManager from opening another PowerShell.
# Policy writes stay in this process. Set-MpPreference runs as SYSTEM in a transient task that is deleted before this script exits.
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
  [switch]$ElevatedRelaunch,
  [switch]$AllowHarnessFailSwap
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

# Library tests set DIAGNOSTIC_WORKSTATION_TEST_FAIL_SWAP=1 to fail inside Install-VerifiedTree.
# Delete it before elevation. RunAs does not pass the variable to the elevated process.
# The fail-swap.marker pointer is read only when -AllowHarnessFailSwap is passed.
# Production installs, including Setup.exe, do not pass that switch.
[Environment]::SetEnvironmentVariable('DIAGNOSTIC_WORKSTATION_TEST_FAIL_SWAP', $null, 'Process')

if ([string]::IsNullOrWhiteSpace($Brand)) {
  throw 'Pass -Brand mercedes or -Brand bmw. Nothing was installed.'
}
if (-not (Test-MasterHostWindows)) {
  throw 'The master installer runs on Windows. Nothing was installed.'
}
Enter-MasterInstallerProcess -ScriptPath $MyInvocation.MyCommand.Path -Bound $PSBoundParameters -AlreadyRelaunched:$ElevatedRelaunch -SkipElevation:$VerifyOnly

$repo = Find-MasterRepoRoot $masterDir
$result = Install-ApprovedBrand -Brand $Brand -Channel $Channel -Tag $Tag -Source $Source -OfflineOnly:$OfflineOnly -VerifyOnly:$VerifyOnly -AllowDowngrade:$AllowDowngrade -ApplySecurity:(-not $VerifyOnly) -AllowHarnessFailSwap:$AllowHarnessFailSwap -RepoRoot $repo
$result | Format-List | Out-String | Write-Output
if ($result.installed) {
  # WorkstationManager.exe is left running so it keeps honoring the install lock.
  # The process image stays the previous exe until that process starts again.
  # Restarting it from this elevated installer would open the supervisor UI and
  # race the lock. The operator restarts it after the install finishes.
  Write-Output 'Restart required. The installer leaves the running supervisor in place so the install lock is honored. The new WorkstationManager.exe loads only after that process is restarted.'
}
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
