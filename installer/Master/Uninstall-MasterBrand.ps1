# Security undo hook. Re-enables Windows Update and Windows Defender, then removes the Start Menu entries this installer created.
# Brand files stay in place. Winlogon, the shell, and Run startup are not changed.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('mercedes', 'bmw')]
  [string]$Brand,
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
if (-not (Test-MasterHostWindows)) { throw 'Uninstall undo runs on Windows. Nothing was changed.' }
if (-not (Test-IsWindowsAdmin)) { throw 'Run this from an elevated PowerShell. Nothing was changed.' }

$parent = Split-Path -Parent $masterDir
$installerData = $null
$repo = $null
$toolMarker = Join-MasterPath $parent @('tools', 'security', 'wub', 'tool-manifest.json')
if (Test-Path -LiteralPath $toolMarker) { $installerData = $parent }
try { $repo = Find-MasterRepoRoot $masterDir } catch { $repo = $masterDir }

$result = Invoke-SecurityUndo -Brand $Brand -Action 'enable' -InstallerData $installerData -RepoRoot $repo
$recordName = 'shortcuts-{0}.json' -f $Brand
$recordPaths = @()
if ($installerData) { $recordPaths += (Join-Path $installerData $recordName) }
if ($repo) { $recordPaths += (Join-Path (Join-Path $repo 'DiagnosticWorkstation-Installer') $recordName) }
foreach ($recordPath in $recordPaths) {
  if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { continue }
  $entries = @(Read-JsonFile $recordPath)
  foreach ($entry in $entries) {
    if ($entry.lnk -and (Test-Path -LiteralPath ([string]$entry.lnk))) {
      Remove-Item -LiteralPath ([string]$entry.lnk) -Force
    }
  }
}
Write-Output 'Windows Update and Windows Defender re-enable were requested. Brand files were left in place. Shell startup was not changed.'
Write-Output ("Defender undo status: {0}" -f $result.defender)
if ([string]$result.windowsUpdate -ne 'enabled') { exit 2 }
if ([string]$result.defender -eq 'tamper-blocked') { exit 10 }
if ([string]$result.defender -ne 'enabled') { exit 11 }
exit 0
