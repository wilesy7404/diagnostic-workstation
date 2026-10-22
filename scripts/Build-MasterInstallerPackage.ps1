# Build DiagnosticWorkstation-Setup.zip.
# Windows PowerShell 5.1. Binary writes use ReadAllBytes/WriteAllBytes or Invoke-WebRequest -OutFile.
# -SkipExeCompile writes a stand-in Setup.exe so the layout can be checked without PS2EXE.
$ErrorActionPreference = 'Stop'

$script:Ps2ExeVersion = '1.0.18'
$script:Ps2ExeNupkgSha256 = '692124163d0e71262d76e2f2b2588e1661df28a8f0cf3b1725e47a957afce39f'
$script:CatalogPin = 'c514717b22c24b68c2a445e08f02131e1f9fd62d600bcf292f88f8a4e1597aba'
$script:EmbeddedSha256SumsToken = '__EMBEDDED_SHA256SUMS__'
$script:PackageTimestamp = [datetimeoffset]::new(2026, 1, 1, 0, 0, 0, [timespan]::Zero)

function Import-ZipSupport {
  if ('System.IO.Compression.ZipFile' -as [type]) { return }
  try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
  try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { }
  if (-not ('System.IO.Compression.ZipFile' -as [type])) { throw 'ZIP support is unavailable' }
}

function Join-PackageRelative {
  param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Relative)
  $rel = $Relative.Replace('\', '/')
  if ($rel -match '(^|/)\.\.(/|$)') { throw "unsafe package path $Relative" }
  $path = $Root
  foreach ($part in @($rel -split '/')) {
    if ([string]::IsNullOrWhiteSpace($part) -or $part -eq '.' -or $part -eq '..') { throw "unsafe package path $Relative" }
    $path = Join-Path -Path $path -ChildPath $part
  }
  return $path
}

function Copy-BinaryToPackage {
  param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
  $parent = Split-Path -Parent $Destination
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $bytes = [System.IO.File]::ReadAllBytes($Source)
  [System.IO.File]::WriteAllBytes($Destination, $bytes)
}

function Write-Utf8NoBomText {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Get-PackageRelativeFiles {
  param([Parameter(Mandatory = $true)][string]$Root)
  $fullRoot = [System.IO.Path]::GetFullPath($Root)
  $prefix = $fullRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($file in [System.IO.Directory]::EnumerateFiles($fullRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
    $full = [System.IO.Path]::GetFullPath($file)
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    [void]$list.Add($full.Substring($prefix.Length).Replace('\', '/'))
  }
  $names = $list.ToArray()
  [Array]::Sort($names, [System.StringComparer]::Ordinal)
  return @($names)
}

function Get-MasterPackageLayout {
  param([Parameter(Mandatory = $true)][string]$RepoRoot)
  $rels = New-Object System.Collections.Generic.List[string]
  foreach ($rel in @(
    'installer/Master/Install-Master.ps1',
    'installer/Master/Enable-Security.ps1',
    'installer/Master/Uninstall-MasterBrand.ps1',
    'catalog/catalog.json',
    'catalog/catalog.sha256',
    'catalog/catalog.json.release.sig',
    'keys/qa.pub',
    'keys/release.pub',
    'keys/README.md',
    'brands/bmw/release.json',
    'brands/mercedes/release.json'
  )) { [void]$rels.Add($rel) }
  $lib = Join-Path -Path (Join-Path -Path (Join-Path -Path $RepoRoot -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'lib'
  foreach ($file in [System.IO.Directory]::EnumerateFiles($lib, '*.ps1')) {
    [void]$rels.Add(('installer/Master/lib/{0}' -f [System.IO.Path]::GetFileName($file)))
  }
  $tools = [System.IO.Path]::GetFullPath((Join-Path -Path (Join-Path -Path $RepoRoot -ChildPath 'tools') -ChildPath 'security'))
  $dcontrol = Join-Path -Path $tools -ChildPath 'dcontrol'
  $dcontrolAllowed = @('ReadMe.txt', 'STATUS.md')
  if (Test-Path -LiteralPath $dcontrol) {
    $dcontrolPrefix = $dcontrol.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    foreach ($file in [System.IO.Directory]::EnumerateFiles($dcontrol, '*', [System.IO.SearchOption]::AllDirectories)) {
      $full = [System.IO.Path]::GetFullPath($file)
      if (-not $full.StartsWith($dcontrolPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
      $name = $full.Substring($dcontrolPrefix.Length).Replace('\', '/')
      $allowed = $false
      foreach ($entry in $dcontrolAllowed) {
        if ($name -ceq $entry) { $allowed = $true }
      }
      if (-not $allowed) { throw "tools/security/dcontrol/$name is not on the allow-list (ReadMe.txt, STATUS.md)" }
    }
  }
  $prefix = $tools.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
  foreach ($file in [System.IO.Directory]::EnumerateFiles($tools, '*', [System.IO.SearchOption]::AllDirectories)) {
    $full = [System.IO.Path]::GetFullPath($file)
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    [void]$rels.Add(('tools/security/{0}' -f $full.Substring($prefix.Length).Replace('\', '/')))
  }
  $names = $rels.ToArray()
  [Array]::Sort($names, [System.StringComparer]::Ordinal)
  foreach ($rel in $names) {
    if ($rel -match '(?i)(^|/)(workstation\.zip|dControl\.exe)$') { throw "refusing to package $rel" }
  }
  return @($names)
}

function Write-PackageChecksums {
  param([Parameter(Mandatory = $true)][string]$StageRoot)
  # Setup.exe embeds the SHA-256 of this file, so the file cannot list Setup.exe.
  $names = @(Get-PackageRelativeFiles $StageRoot | Where-Object { $_ -ne 'SHA256SUMS.txt' -and $_ -ne 'Setup.exe' })
  $builder = New-Object System.Text.StringBuilder
  foreach ($rel in $names) {
    $full = Join-PackageRelative $StageRoot $rel
    $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$builder.Append($hash)
    [void]$builder.Append('  ')
    [void]$builder.Append($rel)
    [void]$builder.Append("`n")
  }
  Write-Utf8NoBomText (Join-Path -Path $StageRoot -ChildPath 'SHA256SUMS.txt') ($builder.ToString())
}

function Assert-SameFileBytes {
  param([Parameter(Mandatory = $true)][string]$Left, [Parameter(Mandatory = $true)][string]$Right)
  $a = [System.IO.File]::ReadAllBytes($Left)
  $b = [System.IO.File]::ReadAllBytes($Right)
  if ($a.Length -ne $b.Length) { throw "byte length differs for $Left" }
  for ($i = 0; $i -lt $a.Length; $i++) {
    if ($a[$i] -ne $b[$i]) { throw "byte mismatch at $i for $Left" }
  }
}

function Assert-PackageChecksums {
  param([Parameter(Mandatory = $true)][string]$Root)
  $sumsPath = Join-Path -Path $Root -ChildPath 'SHA256SUMS.txt'
  $text = [System.IO.File]::ReadAllText($sumsPath)
  if ($text.Contains("`r")) { throw 'SHA256SUMS.txt contains CR' }
  $listed = @{}
  foreach ($line in @($text -split "`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "bad SHA256SUMS line: $line" }
    if ($listed.ContainsKey($Matches[2])) { throw "duplicate SHA256SUMS path $($Matches[2])" }
    $listed[$Matches[2]] = $Matches[1]
  }
  if ($listed.ContainsKey('SHA256SUMS.txt')) { throw 'SHA256SUMS.txt lists itself' }
  if ($listed.ContainsKey('Setup.exe')) { throw 'SHA256SUMS.txt lists Setup.exe' }
  $exePath = Join-Path -Path $Root -ChildPath 'Setup.exe'
  if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw 'Setup.exe is missing' }
  $actual = @(Get-PackageRelativeFiles $Root)
  foreach ($rel in $actual) {
    if ($rel -eq 'SHA256SUMS.txt' -or $rel -eq 'Setup.exe') { continue }
    if (-not $listed.ContainsKey($rel)) { throw "SHA256SUMS.txt is missing $rel" }
    $full = Join-PackageRelative $Root $rel
    $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $listed[$rel]) { throw "SHA-256 mismatch for $rel" }
  }
  foreach ($rel in @($listed.Keys)) {
    $found = $false
    foreach ($item in $actual) {
      if ($item -eq $rel) { $found = $true; break }
    }
    if (-not $found) { throw "SHA256SUMS.txt lists a missing file $rel" }
  }
  $catalog = Join-Path -Path (Join-Path -Path $Root -ChildPath 'catalog') -ChildPath 'catalog.json'
  $hash = (Get-FileHash -LiteralPath $catalog -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($hash -ne $script:CatalogPin) { throw "catalog.json SHA-256 $hash does not match $($script:CatalogPin)" }
}

function New-ReproducibleZip {
  param([Parameter(Mandatory = $true)][string]$SourceRoot, [Parameter(Mandatory = $true)][string]$ZipPath)
  Import-ZipSupport
  $names = @(Get-PackageRelativeFiles $SourceRoot)
  $zip = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($rel in $names) {
      $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
      $entry.LastWriteTime = $script:PackageTimestamp
      $full = Join-PackageRelative $SourceRoot $rel
      $bytes = [System.IO.File]::ReadAllBytes($full)
      $stream = $entry.Open()
      try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
  } finally { $zip.Dispose() }
}

function Assert-ReproducibleZip {
  param([Parameter(Mandatory = $true)][string]$ZipPath)
  Import-ZipSupport
  $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $zip.Entries) {
      if ($entry.FullName.Contains('\')) { throw "backslash in zip entry $($entry.FullName)" }
      if ($entry.FullName.EndsWith('/')) { throw "directory entry $($entry.FullName)" }
      [void]$names.Add($entry.FullName)
      $stamp = $entry.LastWriteTime
      if ($stamp.Year -ne 2026 -or $stamp.Month -ne 1 -or $stamp.Day -ne 1 -or $stamp.Hour -ne 0 -or $stamp.Minute -ne 0 -or $stamp.Second -ne 0) {
        throw "zip entry $($entry.FullName) timestamp is $stamp"
      }
    }
    $sorted = $names.ToArray()
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    for ($i = 0; $i -lt $sorted.Length; $i++) {
      if ($names[$i] -ne $sorted[$i]) { throw "zip entries are not sorted at $i ($($names[$i]))" }
    }
  } finally { $zip.Dispose() }
}

function Get-ZipEntrySha256 {
  param([Parameter(Mandatory = $true)][string]$ZipPath, [Parameter(Mandatory = $true)][string]$EntryName)
  Import-ZipSupport
  $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    $entry = $zip.GetEntry($EntryName)
    if (-not $entry) { throw "missing zip entry $EntryName" }
    $stream = $entry.Open()
    try {
      $sha = [System.Security.Cryptography.SHA256]::Create()
      try { $hash = $sha.ComputeHash($stream) } finally { $sha.Dispose() }
    } finally { $stream.Dispose() }
    return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
  } finally { $zip.Dispose() }
}

function Save-PinnedPs2ExeNupkg {
  param([Parameter(Mandatory = $true)][string]$Destination)
  if ($env:PS2EXE_VERSION -and $env:PS2EXE_VERSION -ne $script:Ps2ExeVersion) {
    throw "PS2EXE_VERSION is $($env:PS2EXE_VERSION); the pin is $($script:Ps2ExeVersion)"
  }
  if ($env:PS2EXE_NUPKG_SHA256) {
    $fromEnv = $env:PS2EXE_NUPKG_SHA256.Trim().ToLowerInvariant()
    if ($fromEnv -ne $script:Ps2ExeNupkgSha256) {
      throw "PS2EXE_NUPKG_SHA256 does not match the pin $($script:Ps2ExeNupkgSha256)"
    }
  }
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  # The gallery package API often answers 404. The CDN blob is the same nupkg; the hash pin below rejects a different file.
  $urls = @(
    ('https://cdn.powershellgallery.com/packages/ps2exe.' + $script:Ps2ExeVersion + '.nupkg'),
    ('https://www.powershellgallery.com/api/v2/package/ps2exe/' + $script:Ps2ExeVersion)
  )
  $parent = Split-Path -Parent $Destination
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $ProgressPreference = 'SilentlyContinue'
  $downloaded = $false
  $downloadError = $null
  for ($attempt = 1; $attempt -le 4; $attempt++) {
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
    foreach ($url in $urls) {
      try {
        Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing -Headers @{ 'User-Agent' = 'diagnostic-workstation' }
        $downloaded = $true
        break
      } catch {
        $downloadError = $_
      }
    }
    if ($downloaded) { break }
    if ($attempt -lt 4) { Start-Sleep -Seconds (2 * $attempt) }
  }
  if (-not $downloaded) { throw $downloadError }
  $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $script:Ps2ExeNupkgSha256) {
    Remove-Item -LiteralPath $Destination -Force
    throw "ps2exe $($script:Ps2ExeVersion) nupkg SHA-256 $actual does not match $($script:Ps2ExeNupkgSha256)"
  }
  Write-Host "Verified ps2exe $($script:Ps2ExeVersion) nupkg SHA-256 $actual"
}

function Invoke-PinnedPs2Exe {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$Nupkg,
    [Parameter(Mandatory = $true)][string]$OutputExe,
    [Parameter(Mandatory = $true)][string]$SumsSha256
  )
  if ($SumsSha256 -notmatch '^[0-9a-f]{64}$') { throw "embedded SHA256SUMS hash is not 64 lowercase hex" }
  Import-ZipSupport
  $toolDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('ps2exe-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $toolDir | Out-Null
  try {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Nupkg, $toolDir)
    Import-Module -Name (Join-Path -Path $toolDir -ChildPath 'ps2exe.psd1') -Force -ErrorAction Stop
    $sourceFile = Join-Path -Path (Join-Path -Path (Join-Path -Path $RepoRoot -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'Setup.ps1'
    $sourceText = [System.IO.File]::ReadAllText($sourceFile)
    $token = $script:EmbeddedSha256SumsToken
    if (-not $sourceText.Contains($token)) { throw 'Setup.ps1 is missing the SHA256SUMS embed token' }
    $generatedText = $sourceText.Replace($token, $SumsSha256)
    if ($generatedText.Contains($token)) { throw 'Setup.ps1 embed token was not replaced' }
    $inputFile = Join-Path -Path $toolDir -ChildPath 'Setup.generated.ps1'
    Write-Utf8NoBomText $inputFile $generatedText
    if (Test-Path -LiteralPath $OutputExe) { Remove-Item -LiteralPath $OutputExe -Force }
    $arguments = @{
      inputFile = $inputFile
      outputFile = $OutputExe
      requireAdmin = $true
      STA = $true
      lcid = 1033
      title = 'Diagnostic Workstation Setup'
      description = 'Installs one approved diagnostic workstation brand.'
      company = 'Diagnostic Workstation'
      product = 'Diagnostic Workstation Setup'
      copyright = 'Unsigned. ECDSA P-256 signing comes later.'
      version = '1.0.0.0'
    }
    Invoke-ps2exe @arguments
    if (-not (Test-Path -LiteralPath $OutputExe -PathType Leaf)) { throw 'PS2EXE did not write Setup.exe' }
    $config = $OutputExe + '.config'
    if (Test-Path -LiteralPath $config) { Remove-Item -LiteralPath $config -Force }
  } finally {
    Remove-Module ps2exe -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $toolDir) { Remove-Item -LiteralPath $toolDir -Recurse -Force }
  }
}

function Invoke-MasterPackageBuild {
  param([string]$OutputDirectory, [string]$NupkgPath, [switch]$SkipExeCompile)
  $repo = Split-Path -Parent $PSScriptRoot
  if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path -Path $repo -ChildPath 'dist' }
  if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null }
  $windows = ($env:OS -eq 'Windows_NT')
  if (-not $SkipExeCompile -and -not $windows) { throw 'PS2EXE runs on Windows. Pass -SkipExeCompile only for the layout test.' }
  $stage = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('dw-setup-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  $downloaded = $null
  try {
    foreach ($rel in @(Get-MasterPackageLayout $repo)) {
      Copy-BinaryToPackage (Join-PackageRelative $repo $rel) (Join-PackageRelative $stage $rel)
    }
    $readme = Join-Path -Path (Join-Path -Path $repo -ChildPath 'packaging') -ChildPath 'README-INSTALL.txt'
    Copy-BinaryToPackage $readme (Join-Path -Path $stage -ChildPath 'README-INSTALL.txt')
    $exe = Join-Path -Path $stage -ChildPath 'Setup.exe'
    if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }
    Write-PackageChecksums $stage
    $sumsPath = Join-Path -Path $stage -ChildPath 'SHA256SUMS.txt'
    $embedded = (Get-FileHash -LiteralPath $sumsPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($SkipExeCompile) {
      $note = [System.Text.Encoding]::ASCII.GetBytes("diagnostic-workstation-setup-stand-in`n")
      [System.IO.File]::WriteAllBytes($exe, $note)
    } else {
      $nupkg = $NupkgPath
      if ([string]::IsNullOrWhiteSpace($nupkg)) {
        $nupkg = Join-Path -Path $OutputDirectory -ChildPath 'ps2exe.nupkg'
        $downloaded = $nupkg
        Save-PinnedPs2ExeNupkg $nupkg
      } else {
        $actual = (Get-FileHash -LiteralPath $nupkg -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $script:Ps2ExeNupkgSha256) { throw "nupkg SHA-256 $actual does not match the pin" }
        Write-Host "Verified ps2exe $($script:Ps2ExeVersion) nupkg SHA-256 $actual"
      }
      Invoke-PinnedPs2Exe -RepoRoot $repo -Nupkg $nupkg -OutputExe $exe -SumsSha256 $embedded
      $head = [System.IO.File]::ReadAllBytes($exe)
      if ($head.Length -lt 2 -or $head[0] -ne 77 -or $head[1] -ne 90) { throw 'Setup.exe is not a Windows executable' }
    }
    Assert-PackageChecksums $stage
    $zipPath = Join-Path -Path $OutputDirectory -ChildPath 'DiagnosticWorkstation-Setup.zip'
    $side = $zipPath + '.sha256'
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    if (Test-Path -LiteralPath $side) { Remove-Item -LiteralPath $side -Force }
    New-ReproducibleZip -SourceRoot $stage -ZipPath $zipPath
    Assert-ReproducibleZip $zipPath
    $zipCatalog = Get-ZipEntrySha256 $zipPath 'catalog/catalog.json'
    if ($zipCatalog -ne $script:CatalogPin) { throw "zip catalog.json SHA-256 $zipCatalog does not match $($script:CatalogPin)" }
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8NoBomText $side (($zipHash + '  DiagnosticWorkstation-Setup.zip') + "`n")
    Write-Host 'PS2EXE output is not byte-reproducible. The CI artifact hash is the attested value.'
    Write-Host "PS2EXE version $($script:Ps2ExeVersion)"
    Write-Host "PS2EXE nupkg SHA-256 $($script:Ps2ExeNupkgSha256)"
    Write-Host "DiagnosticWorkstation-Setup.zip SHA-256 $zipHash"
    Write-Host "catalog.json SHA-256 $zipCatalog"
    Write-Host 'Package files:'
    foreach ($rel in @(Get-PackageRelativeFiles $stage)) { Write-Host $rel }
    return $zipPath
  } finally {
    if ($downloaded -and (Test-Path -LiteralPath $downloaded)) { Remove-Item -LiteralPath $downloaded -Force }
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
  }
}

function Update-StagedSetupExe {
  param(
    [Parameter(Mandatory = $true)][string]$StageRoot,
    [Parameter(Mandatory = $true)][string]$Nupkg
  )
  $repoRoot = Split-Path -Parent $PSScriptRoot
  $exe = Join-Path -Path $StageRoot -ChildPath 'Setup.exe'
  if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }
  Write-PackageChecksums $StageRoot
  $sumsPath = Join-Path -Path $StageRoot -ChildPath 'SHA256SUMS.txt'
  $embedded = (Get-FileHash -LiteralPath $sumsPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $actual = (Get-FileHash -LiteralPath $Nupkg -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $script:Ps2ExeNupkgSha256) { throw "nupkg SHA-256 $actual does not match the pin" }
  Invoke-PinnedPs2Exe -RepoRoot $repoRoot -Nupkg $Nupkg -OutputExe $exe -SumsSha256 $embedded
  $head = [System.IO.File]::ReadAllBytes($exe)
  if ($head.Length -lt 2 -or $head[0] -ne 77 -or $head[1] -ne 90) { throw 'Setup.exe is not a Windows executable' }
  Assert-PackageChecksums $StageRoot
}

if ($env:MASTER_PACKAGE_LIBRARY -eq '1') { return }

$skip = $false
$out = $null
$nupkgArg = $null
for ($i = 0; $i -lt $args.Count; $i++) {
  $arg = [string]$args[$i]
  if ($arg -eq '-SkipExeCompile') { $skip = $true; continue }
  if ($arg -eq '-OutputDirectory') {
    $i++
    if ($i -ge $args.Count) { throw '-OutputDirectory needs a path' }
    $out = [string]$args[$i]
    continue
  }
  if ($arg -eq '-NupkgPath') {
    $i++
    if ($i -ge $args.Count) { throw '-NupkgPath needs a path' }
    $nupkgArg = [string]$args[$i]
    continue
  }
  throw "Unknown argument $arg"
}
[void](Invoke-MasterPackageBuild -OutputDirectory $out -NupkgPath $nupkgArg -SkipExeCompile:$skip)
