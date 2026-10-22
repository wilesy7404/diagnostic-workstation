# Download or load an approved brand bundle, then verify it before any install write.
# URL allow-list matches the Mercedes UpdateRunner rule: only this repo's release asset URL.

function Assert-GithubReleaseUrl {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$AssetName
  )
  if ($Repo -ne $script:MasterRepo) { throw 'Unexpected download URL' }
  if ($Url -match '[\s@]|\\|(\.\.)') { throw 'Unexpected download URL' }
  $clean = $Url
  $query = $clean.IndexOf('?')
  if ($query -ge 0) { $clean = $clean.Substring(0, $query) }
  $expected = "https://github.com/$Repo/releases/download/$Tag/$AssetName"
  if (-not $clean.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected download URL' }
}

function Get-ApprovedAssetUrl {
  param(
    [Parameter(Mandatory = $true)][string]$Brand,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$AssetName
  )
  if ($AssetName -ne 'workstation.zip' -and $AssetName -ne 'update-manifest.json') { throw 'Unexpected download URL' }
  Assert-BrandTag -Brand $Brand -Tag $Tag
  $url = "https://github.com/$($script:MasterRepo)/releases/download/$Tag/$AssetName"
  Assert-GithubReleaseUrl $url $script:MasterRepo $Tag $AssetName
  return $url
}

function Save-ApprovedDownload {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Destination,
    [scriptblock]$Downloader
  )
  $parent = Split-Path -Parent $Destination
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  if ($Downloader) {
    & $Downloader $Url $Destination
  } else {
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120
  }
  if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { throw "Download did not create $Destination" }
}

function Find-OfflinePayload {
  param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$Source,
    [string]$RepoRoot,
    [string]$AssetName,
    [string]$ManifestName
  )
  if ([string]::IsNullOrWhiteSpace($AssetName)) { $AssetName = 'workstation.zip' }
  if ([string]::IsNullOrWhiteSpace($ManifestName)) { $ManifestName = 'update-manifest.json' }
  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($Source)) {
    $candidates.Add($Source)
    $candidates.Add((Join-Path -Path $Source -ChildPath $Tag))
  }
  if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
    $candidates.Add((Join-MasterPath $RepoRoot @('offline', $Tag)))
  }
  foreach ($dir in $candidates) {
    if ([string]::IsNullOrWhiteSpace($dir)) { continue }
    $zip = Join-Path -Path $dir -ChildPath $AssetName
    $manifest = Join-Path -Path $dir -ChildPath $ManifestName
    if ((Test-Path -LiteralPath $zip -PathType Leaf) -and (Test-Path -LiteralPath $manifest -PathType Leaf)) {
      return [pscustomobject]@{ Directory = $dir; Zip = $zip; Manifest = $manifest }
    }
  }
  return $null
}

function Receive-ApprovedPayload {
  param(
    [Parameter(Mandatory = $true)][string]$Brand,
    [Parameter(Mandatory = $true)]$Release,
    [string]$Source,
    [string]$RepoRoot,
    [switch]$OfflineOnly,
    [string]$WorkDirectory,
    [scriptblock]$Downloader
  )
  $tag = [string]$Release.tag
  Assert-BrandTag $Brand $tag
  $asset = 'workstation.zip'
  if (-not [string]::IsNullOrWhiteSpace([string]$Release.asset)) { $asset = [string]$Release.asset }
  $manifestName = 'update-manifest.json'
  if (-not [string]::IsNullOrWhiteSpace([string]$Release.manifestAsset)) { $manifestName = [string]$Release.manifestAsset }
  if ($asset -ne 'workstation.zip' -or $manifestName -ne 'update-manifest.json') { throw 'Unexpected download URL' }

  $offline = Find-OfflinePayload $tag $Source $RepoRoot $asset $manifestName
  $onlineError = $null
  if (-not $OfflineOnly -and -not $Source) {
    $zipUrl = Get-ApprovedAssetUrl $Brand $tag $asset
    $manifestUrl = Get-ApprovedAssetUrl $Brand $tag $manifestName
    $temp = Join-Path -Path $WorkDirectory -ChildPath 'download'
    try {
      Save-ApprovedDownload $zipUrl (Join-Path $temp $asset) $Downloader
      Save-ApprovedDownload $manifestUrl (Join-Path $temp $manifestName) $Downloader
      return [pscustomobject]@{
        Source = 'online'
        Zip = (Join-Path $temp $asset)
        Manifest = (Join-Path $temp $manifestName)
        ZipUrl = $zipUrl
        ManifestUrl = $manifestUrl
      }
    } catch {
      $onlineError = $_.Exception.Message
      if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
  if (-not $offline) { $offline = Find-OfflinePayload $tag $Source $RepoRoot $asset $manifestName }
  if ($offline) {
    if ([string]::IsNullOrWhiteSpace($WorkDirectory)) { throw 'Work directory is required. Nothing was installed.' }
    $sealed = Join-Path -Path $WorkDirectory -ChildPath 'sealed-payload'
    if (-not (Test-Path -LiteralPath $sealed)) { New-Item -ItemType Directory -Force -Path $sealed | Out-Null }
    $sealedZip = Join-Path -Path $sealed -ChildPath $asset
    $sealedManifest = Join-Path -Path $sealed -ChildPath $manifestName
    $sealedZipBytes = [System.IO.File]::ReadAllBytes($offline.Zip)
    $sealedManifestBytes = [System.IO.File]::ReadAllBytes($offline.Manifest)
    [System.IO.File]::WriteAllBytes($sealedZip, $sealedZipBytes)
    [System.IO.File]::WriteAllBytes($sealedManifest, $sealedManifestBytes)
    return [pscustomobject]@{
      Source = 'offline'
      Zip = $sealedZip
      Manifest = $sealedManifest
      OnlineError = $onlineError
    }
  }
  if ($onlineError) { throw "Online download failed ($onlineError) and no offline payload was found. Nothing was installed." }
  throw 'No offline payload was found. Nothing was installed.'
}

function Assert-ManifestIdentity {
  param($Manifest, [Parameter(Mandatory = $true)][string]$Brand, [Parameter(Mandatory = $true)]$Release)
  if ([string]$Manifest.brand -ne $Brand) { throw 'Release manifest brand mismatch. Nothing was installed.' }
  if ([string]$Manifest.tag -ne [string]$Release.tag) { throw 'Release manifest tag mismatch. Nothing was installed.' }
  if ([string]$Manifest.version -ne [string]$Release.version) { throw 'Release manifest version mismatch. Nothing was installed.' }
  if ([string]$Manifest.asset -and [string]$Manifest.asset -ne 'workstation.zip') { throw 'Release manifest asset mismatch. Nothing was installed.' }
  if ([string]$Manifest.sha256 -ne [string]$Release.sha256) { throw 'Release manifest checksum does not match the catalog pin. Nothing was installed.' }
}

function Assert-ZipMembers {
  param($Zip, $Manifest)
  $expected = @{}
  foreach ($entry in @($Manifest.files)) {
    $relative = Assert-SafeRelativePath ([string]$entry.path)
    if ($expected.ContainsKey($relative)) { throw "Duplicate manifest path $relative" }
    if (Test-PreservedLeaf $relative) { throw "bundle must not contain machine-local file $relative. Nothing was installed." }
    if ($null -eq $entry.sha256 -or $null -eq $entry.bytes) { throw "Manifest entry incomplete: $relative" }
    $expected[$relative] = $true
  }
  if ($expected.Count -eq 0) { throw 'Manifest has no files. Nothing was installed.' }
  $actual = @{}
  foreach ($member in $Zip.Entries) {
    $name = [string]$member.FullName
    $trimmed = $name.Replace('\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
    $isDir = $name.EndsWith('/') -or $name.EndsWith('\')
    $safe = Assert-SafeRelativePath $trimmed
    if ($isDir) { continue }
    if ($actual.ContainsKey($safe)) { throw "Duplicate zip entry $safe" }
    $actual[$safe] = $member
  }
  foreach ($path in $expected.Keys) {
    if (-not $actual.ContainsKey($path)) { throw "Missing $path. Nothing was installed." }
  }
  foreach ($path in $actual.Keys) {
    if (-not $expected.ContainsKey($path)) { throw "Unexpected bundle file $path. Nothing was installed." }
  }
  return $actual
}

function Expand-ApprovedZip {
  param($Zip, $Members, [Parameter(Mandatory = $true)][string]$Destination)
  foreach ($path in $Members.Keys) {
    $out = Join-SafeRelativePath $Destination $path
    $parent = Split-Path -Parent $out
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $inputStream = $Members[$path].Open()
    $output = $null
    try {
      $output = [System.IO.File]::Create($out)
      $inputStream.CopyTo($output)
    } finally {
      if ($output) { $output.Dispose() }
      $inputStream.Dispose()
    }
  }
}

function Assert-ExpandedFiles {
  param([Parameter(Mandatory = $true)][string]$Destination, $Manifest)
  foreach ($entry in @($Manifest.files)) {
    $relative = Assert-SafeRelativePath ([string]$entry.path)
    $full = Join-SafeRelativePath $Destination $relative
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Missing $relative. Nothing was installed." }
    $item = Get-Item -LiteralPath $full
    if ([int64]$item.Length -ne [int64]$entry.bytes) { throw "Size mismatch $relative. Nothing was installed." }
    $hash = Get-Sha256Hex $full
    if ($hash -ne ([string]$entry.sha256).ToLowerInvariant()) { throw "Checksum mismatch $relative. Nothing was installed." }
    if ($relative -like '*.ps1') {
      $tokens = $null
      $errors = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
      if (@($errors).Count -gt 0) { throw "Invalid script $relative. Nothing was installed." }
    }
  }
}

function Read-PayloadSnapshot {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Label)
  try {
    return [System.IO.File]::ReadAllBytes($Path)
  } catch {
    throw "Missing $Label. Nothing was installed."
  }
}

function Get-PayloadSha256 {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $hash = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
  return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}

function ConvertFrom-PayloadJson {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes, [Parameter(Mandatory = $true)][string]$Label)
  $stream = New-Object System.IO.MemoryStream
  $reader = $null
  try {
    $stream.Write($Bytes, 0, $Bytes.Length)
    $stream.Position = 0
    $reader = New-Object System.IO.StreamReader($stream, $true)
    $text = $reader.ReadToEnd()
  } finally {
    if ($reader) { $reader.Dispose() } else { $stream.Dispose() }
  }
  if ([string]::IsNullOrWhiteSpace($text)) { throw "Empty JSON $Label" }
  return ($text | ConvertFrom-Json)
}

function Open-VerifiedBundle {
  param(
    [Parameter(Mandatory = $true)][string]$Brand,
    [Parameter(Mandatory = $true)]$Release,
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$Staging
  )
  if ([string]::IsNullOrWhiteSpace([string]$Release.manifestSha256)) {
    throw 'update-manifest.json SHA-256 is required. Nothing was installed.'
  }
  $manifestBytes = Read-PayloadSnapshot $ManifestPath 'update-manifest.json'
  $manifestHash = Get-PayloadSha256 $manifestBytes
  if ($manifestHash -ne ([string]$Release.manifestSha256).ToLowerInvariant()) {
    throw 'hash mismatch for update-manifest.json'
  }
  $manifest = ConvertFrom-PayloadJson $manifestBytes 'update-manifest.json'
  Assert-ManifestIdentity $manifest $Brand $Release
  $zipBytes = Read-PayloadSnapshot $ZipPath 'workstation.zip'
  if ([int64]$zipBytes.Length -ne [int64]$Release.bytes) { throw 'Package size mismatch. Nothing was installed.' }
  $zipHash = Get-PayloadSha256 $zipBytes
  if ($zipHash -ne ([string]$Release.sha256).ToLowerInvariant()) { throw 'hash mismatch for workstation.zip' }
  Import-ZipAssembly
  $zipStream = New-Object System.IO.MemoryStream
  $zip = $null
  try {
    $zipStream.Write($zipBytes, 0, $zipBytes.Length)
    $zipStream.Position = 0
    $zip = [System.IO.Compression.ZipArchive]::new($zipStream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
    $members = Assert-ZipMembers $zip $manifest
    if (Test-Path -LiteralPath $Staging) { Remove-Item -LiteralPath $Staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Staging | Out-Null
    try {
      Expand-ApprovedZip $zip $members $Staging
      Assert-ExpandedFiles $Staging $manifest
    } catch {
      if (Test-Path -LiteralPath $Staging) { Remove-Item -LiteralPath $Staging -Recurse -Force }
      throw
    }
  } finally {
    if ($zip) { $zip.Dispose() }
    $zipStream.Dispose()
  }
  return $manifest
}
