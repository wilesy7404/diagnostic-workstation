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

  function Copy-VerifiedTree {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }
    foreach ($rel in @(Get-PackageRelativeFiles $Source)) {
      Copy-BinaryToPackage (Join-PackageRelative $Source $rel) (Join-PackageRelative $Destination $rel)
    }
  }

  function Write-ZoneIdentifier {
    param([Parameter(Mandatory = $true)][string]$Root)
    $payload = "[ZoneTransfer]`r`nZoneId=3`r`n"
    foreach ($rel in @(Get-PackageRelativeFiles $Root)) {
      $full = Join-PackageRelative $Root $rel
      [System.IO.File]::WriteAllText(($full + ':Zone.Identifier'), $payload)
    }
  }

  function Write-InstallerExitStub {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][int]$Code)
    $lines = @(
      '[CmdletBinding()]',
      'param(',
      '  [string]$Brand,',
      '  [string]$Channel,',
      '  [string]$Tag,',
      '  [string]$Source,',
      '  [switch]$OfflineOnly,',
      '  [switch]$VerifyOnly,',
      '  [switch]$AllowDowngrade,',
      '  [switch]$Library,',
      '  [switch]$ElevatedRelaunch',
      ')',
      ('exit ' + $Code)
    )
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), $utf8)
  }

  $caseRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('dw-setup-cases-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
  $nupkg = Join-Path -Path $caseRoot -ChildPath 'ps2exe.nupkg'
  $savedMachine = Get-ExecutionPolicy -Scope LocalMachine
  $savedUser = Get-ExecutionPolicy -Scope CurrentUser
  $policySet = $false
  try {
    Save-PinnedPs2ExeNupkg $nupkg
    $exit11Root = Join-Path -Path $caseRoot -ChildPath 'exit11'
    Copy-VerifiedTree $extracted $exit11Root
    Write-InstallerExitStub (Join-PackageRelative $exit11Root 'installer/Master/Install-Master.ps1') 11
    Update-StagedSetupExe -StageRoot $exit11Root -Nupkg $nupkg
    Write-ZoneIdentifier $exit11Root
    $exit0Root = Join-Path -Path $caseRoot -ChildPath 'exit0'
    Copy-VerifiedTree $extracted $exit0Root
    Write-InstallerExitStub (Join-PackageRelative $exit0Root 'installer/Master/Install-Master.ps1') 0
    Update-StagedSetupExe -StageRoot $exit0Root -Nupkg $nupkg
    Write-ZoneIdentifier $exit0Root
    $marked = [System.IO.File]::ReadAllText(((Join-PackageRelative $exit11Root 'installer/Master/Install-Master.ps1') + ':Zone.Identifier'))
    if ($marked -notmatch 'ZoneId=3') { throw 'Zone.Identifier was not applied' }
    $tamperRoot = Join-Path -Path $caseRoot -ChildPath 'tamper'
    Copy-VerifiedTree $extracted $tamperRoot
    $readmePath = Join-Path -Path $tamperRoot -ChildPath 'README-INSTALL.txt'
    $readmeBytes = [System.IO.File]::ReadAllBytes($readmePath)
    $tamperedBytes = New-Object byte[] ($readmeBytes.Length + 1)
    [System.Array]::Copy($readmeBytes, $tamperedBytes, $readmeBytes.Length)
    $tamperedBytes[$readmeBytes.Length] = 88
    [System.IO.File]::WriteAllBytes($readmePath, $tamperedBytes)
    Write-ZoneIdentifier $tamperRoot

    Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy Restricted -Force
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Restricted -Force
    $policySet = $true
    if ([string](Get-ExecutionPolicy -Scope LocalMachine) -ne 'Restricted') { throw 'LocalMachine execution policy is not Restricted' }
    if ([string](Get-ExecutionPolicy -Scope CurrentUser) -ne 'Restricted') { throw 'CurrentUser execution policy is not Restricted' }

    $code11 = Invoke-SetupCaptured -File (Join-Path -Path $exit11Root -ChildPath 'Setup.exe') -ArgumentList @('-Brand', 'mercedes')
    Write-Output 'Setup.exe stub exit 11'
    foreach ($line in @($code11.Lines)) { Write-Output $line }
    if ([int]$code11.ExitCode -ne 11) { throw ("stub exit 11 returned {0}: {1}" -f $code11.ExitCode, ((@($code11.Lines) -join ' | '))) }

    $code0 = Invoke-SetupCaptured -File (Join-Path -Path $exit0Root -ChildPath 'Setup.exe') -ArgumentList @('-Brand', 'mercedes')
    Write-Output 'Setup.exe stub exit 0'
    foreach ($line in @($code0.Lines)) { Write-Output $line }
    if ([int]$code0.ExitCode -ne 0) { throw ("stub exit 0 returned {0}: {1}" -f $code0.ExitCode, ((@($code0.Lines) -join ' | '))) }

    $tampered = Invoke-SetupCaptured -File (Join-Path -Path $tamperRoot -ChildPath 'Setup.exe') -ArgumentList @('-Brand', 'mercedes', '-WhatIf')
    Write-Output 'Setup.exe tampered README-INSTALL.txt'
    foreach ($line in @($tampered.Lines)) { Write-Output $line }
    if ([int]$tampered.ExitCode -eq 0) { throw 'tampered package was accepted' }
    $tamperText = @($tampered.Lines) -join "`n"
    if ($tamperText -notmatch 'SHA-256 mismatch for README-INSTALL\.txt') { throw 'tampered package did not refuse the checksum' }
    if ($tamperText -notmatch 'Nothing was installed') { throw 'tampered package did not say nothing was installed' }
  } finally {
    if ($policySet) {
      Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy $savedMachine -Force
      Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy $savedUser -Force
    }
    if (Test-Path -LiteralPath $caseRoot) { Remove-Item -LiteralPath $caseRoot -Recurse -Force }
  }

  if ((Test-Path -LiteralPath $mercedesRoot) -ne $mercedesBefore) { throw 'report mode created or removed the Mercedes install folder' }
  if ((Test-Path -LiteralPath $bmwRoot) -ne $bmwBefore) { throw 'report mode created or removed the BMW install folder' }
} finally {
  if (Test-Path -LiteralPath $extracted) { Remove-Item -LiteralPath $extracted -Recurse -Force }
}

Write-Output 'PASS master installer package'
exit 0
