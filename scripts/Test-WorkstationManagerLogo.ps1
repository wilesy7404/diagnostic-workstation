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

# The built exe must actually contain embeddedBrand=mercedes. Go ignores a
# missing or misspelled -X and leaves the variable empty. /report-brand writes
# that value and does not install.
if ($IsWindows -and $env:WORKSTATION_MANAGER_EXE) {
  $exe = $env:WORKSTATION_MANAGER_EXE
  $installRoot = Join-Path $env:LOCALAPPDATA 'DiagnosticWorkstation'
  $existed = Test-Path -LiteralPath $installRoot
  $report = Join-Path ([System.IO.Path]::GetTempPath()) ('wm-brand-' + [guid]::NewGuid().ToString() + '.txt')
  # The exe is linked -H windowsgui. The call operator does not wait for a GUI
  # subsystem process, and $LASTEXITCODE stays at the previous command's 0.
  $proc = Start-Process -FilePath $exe -ArgumentList @('/report-brand', $report) -Wait -PassThru -WindowStyle Hidden
  if ($proc.ExitCode -ne 0) { throw "report-brand exited $($proc.ExitCode)" }
  if (-not (Test-Path -LiteralPath $report)) { throw "report-brand wrote no file (exit $($proc.ExitCode))" }
  $got = (Get-Content -Raw -LiteralPath $report).Trim()
  Remove-Item -LiteralPath $report
  if ($got -ne 'mercedes') { throw "embeddedBrand is '$got', expected mercedes" }
  if ((Test-Path -LiteralPath $installRoot) -ne $existed) { throw 'report-brand created or removed the install directory' }
  Write-Host 'embeddedBrand=mercedes'
}
