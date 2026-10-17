# Manual probe for a throwaway Windows VM. Install-Master.ps1 does not call this script.
# Defender Control v2.0 removed command-line parameters. Running this exe may open a window
# even for /? . It never passes /D, /E, or /G, and it never changes Defender settings.
[CmdletBinding()]
param(
  [switch]$IUnderstandThisMayOpenAWindow
)

$ErrorActionPreference = 'Stop'
$masterDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $masterDir 'lib/Common.ps1')
. (Join-Path $masterDir 'lib/Security.ps1')

if (-not $IUnderstandThisMayOpenAWindow) {
  throw 'Refusing to start dControl. On a throwaway Windows VM only, pass -IUnderstandThisMayOpenAWindow. Nothing was started.'
}
if (-not (Test-MasterHostWindows)) {
  throw 'Probe dControl on a throwaway Windows VM. Nothing was started.'
}

$tools = Find-SecurityToolsRoot $masterDir
$loaded = Get-SecurityManifest $tools 'dcontrol'
Assert-ManifestFiles $loaded
$exe = Join-Path $loaded.Directory 'dControl.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'dControl.exe is missing. Nothing was started.' }

$forbidden = @('/D', '/E', '/G', '/d', '/e', '/g')
$probeArgs = @('/?')
foreach ($token in $probeArgs) {
  if ($forbidden -contains $token) { throw 'Refusing a Defender disable switch. Nothing was started.' }
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = '/?'
$psi.WorkingDirectory = $loaded.Directory
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$process = [System.Diagnostics.Process]::Start($psi)
$finished = $process.WaitForExit(15000)
$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
if (-not $finished) {
  try { $process.Kill() } catch { }
  throw 'dControl /? did not exit. If a window opened, close it. Do not use the GUI to disable Defender from this installer.'
}
$report = Join-Path $loaded.Directory 'cli-probe.txt'
$body = @"
utc=$([datetimeoffset]::UtcNow.ToString('o'))
exit=$($process.ExitCode)
stdout:
$stdout
stderr:
$stderr
"@
Write-Utf8NoBom $report $body
Write-Output "Wrote $report. This probe does not disable Defender and does not mark the tool verified."
exit 0
