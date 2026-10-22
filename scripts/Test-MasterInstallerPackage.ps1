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
    foreach ($rel in @(Get-PackageRelativeFiles $Root)) {
      $full = Join-PackageRelative $Root $rel
      Set-Content -LiteralPath $full -Stream Zone.Identifier -Value @('[ZoneTransfer]', 'ZoneId=3') -Encoding Ascii
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

  function Write-SwapStub {
    param([Parameter(Mandatory = $true)][string]$Path)
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
      '$go = [string]$env:DW_SETUP_SWAP_GO',
      '$out = [string]$env:DW_SETUP_SWAP_PATH',
      'if ([string]::IsNullOrWhiteSpace($go) -or [string]::IsNullOrWhiteSpace($out)) { exit 13 }',
      '$deadline = (Get-Date).AddSeconds(45)',
      'while (-not (Test-Path -LiteralPath $go)) {',
      '  if ((Get-Date) -gt $deadline) { exit 12 }',
      '  Start-Sleep -Milliseconds 200',
      '}',
      '[System.IO.File]::WriteAllText($out, $PSScriptRoot)',
      'exit 0'
    )
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), $utf8)
  }

  function Write-SourceStub {
    param([Parameter(Mandatory = $true)][string]$Path)
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
      '$out = [string]$env:DW_SETUP_SOURCE_OUT',
      'if ([string]::IsNullOrWhiteSpace($out)) { exit 16 }',
      '[System.IO.File]::WriteAllText($out, [string]$Source)',
      'if (-not [System.IO.Path]::IsPathRooted([string]$Source)) { exit 14 }',
      '$marker = Join-Path -Path $Source -ChildPath ''marker.txt''',
      'if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { exit 15 }',
      'exit 0'
    )
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), $utf8)
  }

  function Write-RawBytes {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][byte[]]$Bytes)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
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
    $marked = Get-Content -LiteralPath (Join-PackageRelative $exit11Root 'installer/Master/Install-Master.ps1') -Stream Zone.Identifier -Raw
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
    $offlineOk = Join-Path -Path $caseRoot -ChildPath 'offline-ok'
    Copy-VerifiedTree $extracted $offlineOk
    $okTag = 'mercedes-v0.1.3-beta.4'
    Write-RawBytes (Join-PackageRelative $offlineOk ('offline/' + $okTag + '/workstation.zip')) ([byte[]](1, 2, 3, 4))
    Write-RawBytes (Join-PackageRelative $offlineOk ('offline/' + $okTag + '/update-manifest.json')) ([byte[]](123, 125, 10))
    Write-RawBytes (Join-Path -Path $offlineOk -ChildPath 'desktop.ini') ([byte[]](59, 10))
    Write-RawBytes (Join-PackageRelative $offlineOk 'brands/mercedes/Thumbs.db') ([byte[]](0, 1))
    Write-ZoneIdentifier $offlineOk
    $offlineBad = Join-Path -Path $caseRoot -ChildPath 'offline-bad'
    Copy-VerifiedTree $extracted $offlineBad
    Write-RawBytes (Join-PackageRelative $offlineBad 'offline/not-a-tag/workstation.zip') ([byte[]](9, 9, 9))
    Write-ZoneIdentifier $offlineBad
    $swapRoot = Join-Path -Path $caseRoot -ChildPath 'swap'
    Copy-VerifiedTree $extracted $swapRoot
    Write-SwapStub (Join-PackageRelative $swapRoot 'installer/Master/Install-Master.ps1')
    Update-StagedSetupExe -StageRoot $swapRoot -Nupkg $nupkg
    Write-RawBytes (Join-Path -Path $swapRoot -ChildPath 'desktop.ini') ([byte[]](59, 10))
    Write-ZoneIdentifier $swapRoot
    $sourceCase = Join-Path -Path $caseRoot -ChildPath 'source-case'
    $sourcePackage = Join-Path -Path $sourceCase -ChildPath 'package'
    Copy-VerifiedTree $extracted $sourcePackage
    Write-SourceStub (Join-PackageRelative $sourcePackage 'installer/Master/Install-Master.ps1')
    Update-StagedSetupExe -StageRoot $sourcePackage -Nupkg $nupkg
    Write-ZoneIdentifier $sourcePackage
    $sourcePayload = Join-Path -Path $sourceCase -ChildPath 'payload'
    Write-RawBytes (Join-Path -Path $sourcePayload -ChildPath 'marker.txt') ([byte[]](111, 107, 10))

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

    $offlinePass = Invoke-SetupCaptured -File (Join-Path -Path $offlineOk -ChildPath 'Setup.exe') -ArgumentList @('-Brand', 'mercedes', '-WhatIf')
    Write-Output 'Setup.exe offline payload'
    foreach ($line in @($offlinePass.Lines)) { Write-Output $line }
    if ([int]$offlinePass.ExitCode -ne 0) { throw ("approved offline payload was refused: {0}" -f ((@($offlinePass.Lines) -join ' | '))) }
    if ((@($offlinePass.Lines) -join "`n") -notmatch 'Resolved brand: mercedes') { throw 'approved offline payload did not resolve the brand' }

    $offlineRefuse = Invoke-SetupCaptured -File (Join-Path -Path $offlineBad -ChildPath 'Setup.exe') -ArgumentList @('-Brand', 'mercedes', '-WhatIf')
    Write-Output 'Setup.exe unapproved offline tag'
    foreach ($line in @($offlineRefuse.Lines)) { Write-Output $line }
    if ([int]$offlineRefuse.ExitCode -eq 0) { throw 'unapproved offline tag was accepted' }
    if ((@($offlineRefuse.Lines) -join "`n") -notmatch 'Unlisted extra file offline/not-a-tag/workstation\.zip') { throw 'unapproved offline tag was not refused' }

    $sourceOut = Join-Path -Path $caseRoot -ChildPath 'source-out.txt'
    $env:DW_SETUP_SOURCE_OUT = $sourceOut
    $sourceInfo = New-Object System.Diagnostics.ProcessStartInfo
    $sourceInfo.FileName = Join-Path -Path $sourcePackage -ChildPath 'Setup.exe'
    $sourceInfo.Arguments = '-Brand mercedes -Source payload'
    $sourceInfo.UseShellExecute = $false
    $sourceInfo.WorkingDirectory = $sourceCase
    $sourceProc = New-Object System.Diagnostics.Process
    $sourceProc.StartInfo = $sourceInfo
    [void]$sourceProc.Start()
    if (-not $sourceProc.WaitForExit(60000)) {
      try { $sourceProc.Kill() } catch { }
      throw 'relative -Source setup did not exit'
    }
    if ([int]$sourceProc.ExitCode -ne 0) { throw ("relative -Source returned {0}" -f $sourceProc.ExitCode) }
    if (-not (Test-Path -LiteralPath $sourceOut)) { throw 'relative -Source was not recorded' }
    $recordedSource = [System.IO.File]::ReadAllText($sourceOut).Trim()
    $expectedSource = [System.IO.Path]::GetFullPath($sourcePayload)
    if (-not $recordedSource.Equals($expectedSource, [System.StringComparison]::OrdinalIgnoreCase)) { throw "relative -Source resolved to $recordedSource" }
    Remove-Item Env:DW_SETUP_SOURCE_OUT -ErrorAction SilentlyContinue

    $swapGo = Join-Path -Path $caseRoot -ChildPath 'swap-go.txt'
    $swapPath = Join-Path -Path $caseRoot -ChildPath 'swap-path.txt'
    $env:DW_SETUP_SWAP_GO = $swapGo
    $env:DW_SETUP_SWAP_PATH = $swapPath
    $swapInfo = New-Object System.Diagnostics.ProcessStartInfo
    $swapInfo.FileName = Join-Path -Path $swapRoot -ChildPath 'Setup.exe'
    $swapInfo.Arguments = '-Brand mercedes'
    $swapInfo.UseShellExecute = $false
    $swapInfo.WorkingDirectory = $swapRoot
    $swapProc = New-Object System.Diagnostics.Process
    $swapProc.StartInfo = $swapInfo
    $started = Get-Date
    [void]$swapProc.Start()
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    $adminCopy = $null
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
      if ($swapProc.HasExited) { throw ("swap setup exited early {0}" -f $swapProc.ExitCode) }
      foreach ($dir in @(Get-ChildItem -LiteralPath $programData -Directory -Filter 'DiagnosticWorkstation-Setup-*' -ErrorAction SilentlyContinue)) {
        if ($dir.CreationTime -lt $started.AddSeconds(-2)) { continue }
        $stubPath = Join-Path -Path $dir.FullName -ChildPath 'installer\Master\Install-Master.ps1'
        if (-not (Test-Path -LiteralPath $stubPath)) { continue }
        $stubText = [System.IO.File]::ReadAllText($stubPath)
        if ($stubText.Contains('DW_SETUP_SWAP_GO')) { $adminCopy = $dir.FullName; break }
      }
      if ($adminCopy) { break }
      Start-Sleep -Milliseconds 200
    }
    if (-not $adminCopy) { throw 'admin work directory was not created' }
    $workAcl = [System.IO.Directory]::GetAccessControl($adminCopy)
    if (-not $workAcl.AreAccessRulesProtected) { throw 'admin work directory inherits access rules' }
    foreach ($ace in @($workAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
      $sid = [string]$ace.IdentityReference.Value
      if ($sid -ne 'S-1-5-32-544' -and $sid -ne 'S-1-5-18') { throw "admin work directory allows $sid" }
    }
    $ownerSid = [string]$workAcl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($ownerSid -ne 'S-1-5-32-544') { throw "admin work directory owner is $ownerSid" }
    Write-InstallerExitStub (Join-PackageRelative $swapRoot 'installer/Master/Install-Master.ps1') 11
    [System.IO.File]::WriteAllText($swapGo, "go`n")
    if (-not $swapProc.WaitForExit(20000)) { throw 'swap setup did not exit' }
    if ([int]$swapProc.ExitCode -ne 0) { throw ("post-verify swap changed the exit code to {0}" -f $swapProc.ExitCode) }
    if (-not (Test-Path -LiteralPath $swapPath)) { throw 'installer did not record its run path' }
    $ranFrom = [System.IO.File]::ReadAllText($swapPath).Trim()
    if (-not $ranFrom.StartsWith($adminCopy, [System.StringComparison]::OrdinalIgnoreCase)) { throw "installer ran from $ranFrom" }
    $sourcePrefix = [System.IO.Path]::GetFullPath($swapRoot)
    if ($ranFrom.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'installer ran from the user-writable folder' }
    $swapped = [System.IO.File]::ReadAllText((Join-PackageRelative $swapRoot 'installer/Master/Install-Master.ps1'))
    if ($swapped -notmatch 'exit 11') { throw 'source stub was not swapped' }
    if (Test-Path -LiteralPath $adminCopy) { throw 'admin work directory was left behind' }
    Remove-Item Env:DW_SETUP_SWAP_GO -ErrorAction SilentlyContinue
    Remove-Item Env:DW_SETUP_SWAP_PATH -ErrorAction SilentlyContinue
  } finally {
    if ($swapProc -and -not $swapProc.HasExited) {
      try { $swapProc.Kill() } catch { }
    }
    Remove-Item Env:DW_SETUP_SWAP_GO -ErrorAction SilentlyContinue
    Remove-Item Env:DW_SETUP_SWAP_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:DW_SETUP_SOURCE_OUT -ErrorAction SilentlyContinue
    if ($sourceProc -and -not $sourceProc.HasExited) {
      try { $sourceProc.Kill() } catch { }
    }
    if ($policySet) {
      foreach ($pair in @(
        @{ Scope = 'CurrentUser'; Value = $savedUser },
        @{ Scope = 'LocalMachine'; Value = $savedMachine }
      )) {
        try {
          Set-ExecutionPolicy -Scope $pair.Scope -ExecutionPolicy $pair.Value -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        } catch { }
      }
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
