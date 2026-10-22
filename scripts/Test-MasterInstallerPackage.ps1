# Extract DiagnosticWorkstation-Setup.zip, check SHA256SUMS and the catalog pin, then run Setup.exe in report mode.
# Windows PowerShell 5.1. This does not install a brand.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ZipPath
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw "Missing $ZipPath" }

$env:MASTER_PACKAGE_LIBRARY = '1'
. (Join-Path -Path $PSScriptRoot -ChildPath 'Build-MasterInstallerPackage.ps1')
Remove-Item Env:MASTER_PACKAGE_LIBRARY

Import-ZipSupport
Assert-ReproducibleZip $ZipPath
$entryHash = Get-ZipEntrySha256 $ZipPath 'catalog/catalog.json'
if ($entryHash -ne $script:CatalogPin) { throw "zip catalog.json SHA-256 $entryHash does not match $($script:CatalogPin)" }

$extracted = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('dw-setup-verify-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $extracted | Out-Null
try {
  [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $extracted)
  Assert-PackageChecksums $extracted
  Assert-SameFileBytes (Join-PackageRelative $repo 'catalog/catalog.json') (Join-PackageRelative $extracted 'catalog/catalog.json')
  $exe = Join-Path -Path $extracted -ChildPath 'Setup.exe'
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Setup.exe is missing from the zip' }
  $head = [System.IO.File]::ReadAllBytes($exe)
  if ($head.Length -lt 2 -or $head[0] -ne 77 -or $head[1] -ne 90) { throw 'Setup.exe is not a Windows executable' }

  $mercedesRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'DiagnosticWorkstation'
  $bmwRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'BMW-Stealth-Launcher'
  $mercedesBefore = Test-Path -LiteralPath $mercedesRoot
  $bmwBefore = Test-Path -LiteralPath $bmwRoot

  function Invoke-SetupCaptured {
    param([Parameter(Mandatory = $true)][string]$File, [string[]]$ArgumentList)
    $lines = New-Object System.Collections.Generic.List[string]
    $previous = Get-Location
    Set-Location -LiteralPath ([System.IO.Path]::GetTempPath())
    try {
      & $File @ArgumentList 2>&1 | ForEach-Object { [void]$lines.Add([string]$_) }
      $code = $LASTEXITCODE
    } finally {
      Set-Location -LiteralPath $previous.Path
    }
    return [pscustomobject]@{ ExitCode = $code; Lines = @($lines.ToArray()) }
  }

  $report = Invoke-SetupCaptured -File $exe -ArgumentList @('-Brand', 'mercedes', '-WhatIf')
  Write-Output 'Setup.exe -Brand mercedes -WhatIf'
  foreach ($line in @($report.Lines)) { Write-Output $line }
  if ([int]$report.ExitCode -ne 0) { throw "Setup.exe -WhatIf exited $($report.ExitCode)" }
  $text = @($report.Lines) -join "`n"
  if ($text -notmatch 'Resolved brand: mercedes') { throw 'report did not print the resolved brand' }
  if ($text -notmatch 'Resolved display name: Mercedes-Benz') { throw 'report display name was blank' }
  if ($text -notmatch 'Resolved tag: mercedes-v0\.1\.3-beta\.4') { throw 'report did not resolve the Mercedes tag' }
  if ($text -notmatch '(?m)^catalog/catalog\.json$') { throw 'report file list omitted catalog/catalog.json' }
  if ($text -notmatch '(?m)^Setup\.exe$') { throw 'report file list omitted Setup.exe' }
  if ($text -notmatch 'Report only\. Nothing was installed\.') { throw 'report did not say that nothing was installed' }
  if ($text -match '(?m)^Install $') { throw 'report printed a blank Install prompt' }

  $bmw = Invoke-SetupCaptured -File $exe -ArgumentList @('-Brand', 'bmw', '/report')
  Write-Output 'Setup.exe -Brand bmw /report'
  foreach ($line in @($bmw.Lines)) { Write-Output $line }
  if ([int]$bmw.ExitCode -ne 0) { throw "Setup.exe /report exited $($bmw.ExitCode)" }
  $bmwText = @($bmw.Lines) -join "`n"
  if ($bmwText -notmatch 'Resolved brand: bmw') { throw '/report did not resolve bmw' }
  if ($bmwText -notmatch 'Resolved tag: bmw-v1\.0\.2-beta\.1') { throw '/report did not resolve the BMW tag' }

  $missing = Invoke-SetupCaptured -File $exe -ArgumentList @('-WhatIf')
  Write-Output 'Setup.exe -WhatIf'
  foreach ($line in @($missing.Lines)) { Write-Output $line }
  if ([int]$missing.ExitCode -eq 0) { throw 'Setup.exe -WhatIf without a brand exited 0' }
  if ((@($missing.Lines) -join "`n") -notmatch 'No brand was resolved') { throw 'missing brand did not print a clear error' }

  if ((Test-Path -LiteralPath $mercedesRoot) -ne $mercedesBefore) { throw 'report mode created or removed the Mercedes install folder' }
  if ((Test-Path -LiteralPath $bmwRoot) -ne $bmwBefore) { throw 'report mode created or removed the BMW install folder' }
} finally {
  if (Test-Path -LiteralPath $extracted) { Remove-Item -LiteralPath $extracted -Recurse -Force }
}

Write-Output 'PASS master installer package'
exit 0
