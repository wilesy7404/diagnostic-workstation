# Pinned offline catalog. Placeholder keys are rejected as approval.
# A newer GitHub release is downloaded only when this catalog already pins its tag and ZIP hash.

function Get-PinToken {
  param([Parameter(Mandatory = $true)][string]$PinPath)
  if (-not (Test-Path -LiteralPath $PinPath -PathType Leaf)) { throw 'catalog pin missing. Nothing was installed.' }
  $text = [System.IO.File]::ReadAllText($PinPath).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { throw 'catalog pin missing. Nothing was installed.' }
  return ($text -split '\s+')[0].ToLowerInvariant()
}

function Assert-PinnedCatalog {
  param([Parameter(Mandatory = $true)][string]$CatalogPath, [Parameter(Mandatory = $true)][string]$PinPath)
  $pin = Get-PinToken $PinPath
  $actual = Get-Sha256Hex $CatalogPath
  if ($actual -ne $pin) { throw 'catalog pin mismatch. Nothing was installed.' }
  return $actual
}

function Assert-PlaceholderKeys {
  param([Parameter(Mandatory = $true)][string]$KeysDirectory)
  foreach ($name in @('qa.pub', 'release.pub')) {
    $path = Join-Path -Path $KeysDirectory -ChildPath $name
    $key = Read-JsonFile $path
    if ([string]$key.status -ne 'placeholder') { throw 'only placeholder public keys are shipped. Nothing was installed.' }
    if (-not [string]::IsNullOrWhiteSpace([string]$key.publicKeyHex)) {
      throw 'a real public key is present but verification is not implemented. Nothing was installed.'
    }
    if ([string]$key.algorithm -ne 'ed25519') { throw 'unexpected key algorithm. Nothing was installed.' }
  }
}

function Assert-PlaceholderSignature {
  param([Parameter(Mandatory = $true)][string]$SignaturePath)
  if (-not (Test-Path -LiteralPath $SignaturePath -PathType Leaf)) {
    throw 'placeholder signature file missing. Nothing was installed.'
  }
  $text = [System.IO.File]::ReadAllText($SignaturePath)
  if ($text -notmatch '(?i)placeholder') { throw 'signature file is not the documented placeholder. Nothing was installed.' }
}

function Read-ApprovedCatalog {
  param(
    [Parameter(Mandatory = $true)][string]$CatalogPath,
    [Parameter(Mandatory = $true)][string]$PinPath,
    [Parameter(Mandatory = $true)][string]$KeysDirectory,
    [Parameter(Mandatory = $true)][string]$SignaturePath,
    [string]$TrustStatePath
  )
  $digest = Assert-PinnedCatalog $CatalogPath $PinPath
  Assert-PlaceholderKeys $KeysDirectory
  Assert-PlaceholderSignature $SignaturePath
  $catalog = Read-JsonFile $CatalogPath
  if ([string]$catalog.schema -ne 'diagnostic-workstation.catalog/v1') { throw 'unsupported catalog schema. Nothing was installed.' }
  if ([string]$catalog.repo -ne $script:MasterRepo) { throw 'catalog repository is not allow-listed. Nothing was installed.' }
  # Fail closed until real release keys exist. A file that claims to be signed is not treated as signed.
  if ([string]$catalog.signatureStatus -ne 'placeholder-untrusted') {
    throw 'catalog signatures cannot be verified with placeholder keys. Nothing was installed.'
  }
  $warning = $null
  try {
    $expires = [datetimeoffset]::Parse([string]$catalog.expiresUtc)
    if ($expires -lt [datetimeoffset]::UtcNow) {
      $warning = "Catalog dated $($catalog.issuedUtc); newer versions may exist"
    }
  } catch {
    throw 'catalog expiry is invalid. Nothing was installed.'
  }
  if ($TrustStatePath -and (Test-Path -LiteralPath $TrustStatePath -PathType Leaf)) {
    $state = Read-JsonFile $TrustStatePath
    if ([int]$catalog.catalogSerial -lt [int]$state.catalogSerial) {
      throw 'catalog serial is older than the last accepted catalog. Nothing was installed.'
    }
  }
  return [pscustomobject]@{
    Catalog = $catalog
    Digest = $digest
    Warning = $warning
  }
}

function Get-CatalogBrand {
  param([Parameter(Mandatory = $true)]$Catalog, [Parameter(Mandatory = $true)][string]$Brand)
  $allow = Get-BrandAllowEntry $Brand
  $found = $null
  foreach ($item in @($Catalog.brands)) {
    if ([string]$item.id -eq $Brand) { $found = $item; break }
  }
  if (-not $found) { throw "Catalog has no $Brand entry. Nothing was installed." }
  if ([string]$found.tagPrefix -ne $allow.TagPrefix) { throw 'catalog tag prefix does not match the allow map. Nothing was installed.' }
  if ([string]$found.install.root -ne $allow.Root) { throw 'catalog install root does not match the allow map. Nothing was installed.' }
  if ([string]$found.install.rootBase -ne 'LOCALAPPDATA') { throw 'catalog install rootBase is not LOCALAPPDATA. Nothing was installed.' }
  return $found
}

function Read-BrandReleaseFile {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Brand, $CatalogBrand)
  $release = Read-JsonFile $Path
  $allow = Get-BrandAllowEntry $Brand
  if ([string]$release.brand -ne $Brand) { throw 'brand release metadata does not match the selected brand. Nothing was installed.' }
  if ([string]$release.repo -ne $script:MasterRepo) { throw 'brand release repository is not allow-listed. Nothing was installed.' }
  if ([string]$release.tagPrefix -ne $allow.TagPrefix) { throw 'brand release tag prefix does not match the allow map. Nothing was installed.' }
  if ([string]$release.install.root -ne $allow.Root) { throw 'brand release install root does not match the allow map. Nothing was installed.' }
  $retired = @($release.retiredTagPrefixes)
  if ($retired -notcontains 'universal-v') { throw 'brand release metadata must retire universal-v. Nothing was installed.' }
  if ($CatalogBrand -and -not [string]::IsNullOrWhiteSpace([string]$release.packageSha256)) {
    $pins = @(Get-CatalogReleaseList $CatalogBrand | ForEach-Object { [string]$_.sha256 })
    if ($pins -notcontains [string]$release.packageSha256) {
      throw 'brand release packageSha256 is not pinned in the catalog. Nothing was installed.'
    }
  }
  return $release
}

function Get-CatalogReleaseList($CatalogBrand) {
  foreach ($release in @($CatalogBrand.releases)) {
    if ($null -eq $release) { continue }
    Write-Output $release -NoEnumerate
  }
}

function Select-ApprovedRelease {
  param($CatalogBrand, [Parameter(Mandatory = $true)][string]$Brand, [string]$Channel, [string]$Tag)
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'beta' }
  $chosen = @()
  foreach ($release in @(Get-CatalogReleaseList $CatalogBrand)) {
    $releaseTag = [string]$release.tag
    Assert-BrandTag $Brand $releaseTag
    if ($Tag -and $releaseTag -ne $Tag) { continue }
    if (-not $Tag -and [string]$release.channel -ne $Channel) { continue }
    $chosen += $release
  }
  if ($chosen.Count -eq 0) { throw "No approved $Brand release is pinned. Nothing was installed." }
  $sorted = @($chosen | Sort-Object -Property @{ Expression = { Get-ReleaseRank ([string]$_.version) }; Descending = $true })
  return $sorted[0]
}

function Write-TrustState {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][int]$Serial, [string]$Digest)
  $existing = 0
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $existing = [int](Read-JsonFile $Path).catalogSerial
  }
  if ($Serial -lt $existing) { throw 'refusing to store an older catalog serial' }
  $payload = [ordered]@{
    catalogSerial = $Serial
    catalogSha256 = $Digest
    updatedUtc = [datetimeoffset]::UtcNow.ToString('o')
  }
  Write-Utf8NoBom $Path (($payload | ConvertTo-Json -Compress) + "`n")
}
