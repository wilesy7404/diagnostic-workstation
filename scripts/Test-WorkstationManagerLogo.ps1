# Mercedes WorkstationManager.exe may embed only branding/mercedes.png.
# No network, no install, no release.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

$pythonCmd = $null
foreach ($name in @('python3', 'python')) {
  $cmd = Get-Command $name -ErrorAction SilentlyContinue
  if ($cmd) { $pythonCmd = $cmd.Source; break }
}
if (-not $pythonCmd) { throw 'python3 is required to scan WorkstationManager.exe' }

& $pythonCmd (Join-Path $repo 'scripts/Test-WorkstationManagerLogo.py')
if ($LASTEXITCODE -ne 0) { throw 'WorkstationManager logo check failed' }
