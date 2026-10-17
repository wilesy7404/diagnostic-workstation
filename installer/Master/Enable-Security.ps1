# Re-enable Windows Update (Wub /E) and Windows Defender, or re-apply the update block (Wub /D /P).
# Re-apply does not change Defender. Enable restores the Defender snapshot.
# Does not change Winlogon or the shell.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('mercedes', 'bmw')]
  [string]$Brand,
  [ValidateSet('enable', 'reapply')]
  [string]$Action = 'enable',
  [switch]$Library
)

$ErrorActionPreference = 'Stop'
$masterDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $masterDir 'lib/Common.ps1')
. (Join-Path $masterDir 'lib/Catalog.ps1')
. (Join-Path $masterDir 'lib/Bundle.ps1')
. (Join-Path $masterDir 'lib/Defender.ps1')
. (Join-Path $masterDir 'lib/Security.ps1')

if ($Library -or $env:MASTER_INSTALLER_LIBRARY -eq '1') { return }
if (-not (Test-MasterHostWindows)) { throw 'Security undo runs on Windows. Nothing was changed.' }
if (-not (Test-IsWindowsAdmin)) { throw 'Run this from an elevated PowerShell. Nothing was changed.' }

$parent = Split-Path -Parent $masterDir
$installerData = $null
$repo = $null
$toolMarker = Join-MasterPath $parent @('tools', 'security', 'wub', 'tool-manifest.json')
if (Test-Path -LiteralPath $toolMarker) { $installerData = $parent }
try { $repo = Find-MasterRepoRoot $masterDir } catch { $repo = $masterDir }
$result = Invoke-SecurityUndo -Brand $Brand -Action $Action -InstallerData $installerData -RepoRoot $repo
$result | Format-List | Out-String | Write-Output
if ([string]$result.windowsUpdate -eq 'failed') { exit 2 }
if ($Action -eq 'enable' -and [string]$result.defender -eq 'tamper-blocked') { exit 10 }
if ($Action -eq 'enable' -and [string]$result.defender -ne 'enabled') { exit 11 }
exit 0
