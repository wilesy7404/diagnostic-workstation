# Report and brand selection for Setup.exe. This file defines functions only.
# It does not install software or change security settings.

function Get-SetupPackageRoot {
  param([string]$Start)
  $starts = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($Start)) {
    [void]$starts.Add($Start)
  } else {
    if (-not [string]::IsNullOrWhiteSpace([string]$ScriptRoot)) { [void]$starts.Add([string]$ScriptRoot) }
    try {
      $proc = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
      if ($proc -and $proc -notmatch '(?i)(^|[\\/])(powershell|pwsh)(\.exe)?$') {
        [void]$starts.Add((Split-Path -Parent $proc))
      }
    } catch { }
    if ($PSScriptRoot) { [void]$starts.Add($PSScriptRoot) }
  }
  foreach ($start in $starts) {
    $found = Find-SetupPackageRoot $start
    if ($found) { return $found }
  }
  return $null
}

function Find-SetupPackageRoot {
  param([Parameter(Mandatory = $true)][string]$Start)
  $dir = $Start
  for ($i = 0; $i -lt 8; $i++) {
    if ([string]::IsNullOrWhiteSpace($dir)) { break }
    $catalog = Join-Path -Path (Join-Path -Path $dir -ChildPath 'catalog') -ChildPath 'catalog.json'
    $installer = Join-Path -Path (Join-Path -Path (Join-Path -Path $dir -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'Install-Master.ps1'
    if ((Test-Path -LiteralPath $catalog -PathType Leaf) -and (Test-Path -LiteralPath $installer -PathType Leaf)) {
      return $dir
    }
    $parent = Split-Path -Parent $dir
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
    $dir = $parent
  }
  return $null
}

function Get-SetupPackageFiles {
  param([Parameter(Mandatory = $true)][string]$PackageRoot)
  $fullRoot = [System.IO.Path]::GetFullPath($PackageRoot)
  $prefix = $fullRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($file in [System.IO.Directory]::EnumerateFiles($fullRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
    $full = [System.IO.Path]::GetFullPath($file)
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    $rel = $full.Substring($prefix.Length).Replace('\', '/')
    if ($rel -eq '.git' -or $rel.StartsWith('.git/')) { continue }
    [void]$list.Add($rel)
  }
  $names = $list.ToArray()
  [Array]::Sort($names, [System.StringComparer]::Ordinal)
  return $names
}

function Get-SetupForwardParameters {
  param(
    [Parameter(Mandatory = $true)][string]$Brand,
    [string]$Channel = 'beta',
    [string]$Tag,
    [string]$Source,
    [switch]$OfflineOnly,
    [switch]$VerifyOnly,
    [switch]$AllowDowngrade
  )
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'beta' }
  $splat = @{ Brand = $Brand; Channel = $Channel }
  if (-not [string]::IsNullOrWhiteSpace($Tag)) { $splat['Tag'] = $Tag }
  if (-not [string]::IsNullOrWhiteSpace($Source)) {
    try { $splat['Source'] = [System.IO.Path]::GetFullPath($Source) }
    catch { throw 'The -Source path is not valid. Nothing was installed.' }
  }
  if ($OfflineOnly) { $splat['OfflineOnly'] = $true }
  if ($VerifyOnly) { $splat['VerifyOnly'] = $true }
  if ($AllowDowngrade) { $splat['AllowDowngrade'] = $true }
  return $splat
}

function Resolve-SetupBrandSelection {
  param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [Parameter(Mandatory = $true)][string]$Brand,
    [string]$Channel = 'beta',
    [string]$Tag
  )
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'beta' }
  $catalogDir = Join-Path -Path $PackageRoot -ChildPath 'catalog'
  $loaded = Read-ApprovedCatalog -CatalogPath (Join-Path -Path $catalogDir -ChildPath 'catalog.json') -PinPath (Join-Path -Path $catalogDir -ChildPath 'catalog.sha256') -KeysDirectory (Join-Path -Path $PackageRoot -ChildPath 'keys') -SignaturePath (Join-Path -Path $catalogDir -ChildPath 'catalog.json.release.sig')
  $entry = Get-CatalogBrand $loaded.Catalog $Brand
  $release = Select-ApprovedRelease -CatalogBrand $entry -Brand $Brand -Channel $Channel -Tag $Tag
  $allow = Get-BrandAllowEntry $Brand
  if ([string]::IsNullOrWhiteSpace([string]$allow.DisplayName)) {
    throw 'No brand was resolved. Pass -Brand mercedes or -Brand bmw. Nothing was installed.'
  }
  return [pscustomobject]@{
    Brand = $Brand
    DisplayName = [string]$allow.DisplayName
    Tag = [string]$release.tag
    Channel = [string]$release.channel
    CatalogSha256 = [string]$loaded.Digest
  }
}

function Read-SetupBrandPrompt {
  Write-Host 'Diagnostic Workstation setup'
  Write-Host 'Choose the brand to install.'
  $map = Get-BrandAllowMap
  foreach ($id in @($map.Keys | Sort-Object)) {
    $name = [string]$map[$id].DisplayName
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }
    Write-Host ('  {0}    {1}' -f $id, $name)
  }
  Write-Host 'Type mercedes or bmw. Leave the line blank to cancel.'
  try {
    $answer = Read-Host -Prompt 'Brand (mercedes or bmw)'
  } catch {
    return ''
  }
  if ($null -eq $answer) { return '' }
  return $answer.Trim().ToLowerInvariant()
}

function Test-SetupReportArgument {
  param([string]$Argument)
  if ([string]::IsNullOrWhiteSpace($Argument)) { return $false }
  return $Argument -match '^(?i)(/report|/whatif|-report|--report|--whatif)$'
}

function Add-SetupReportLines {
  param($Lines, [Parameter(Mandatory = $true)]$Resolved, [Parameter(Mandatory = $true)][string]$PackageRoot)
  [void]$Lines.Add(('Resolved brand: {0}' -f $Resolved.Brand))
  [void]$Lines.Add(('Resolved display name: {0}' -f $Resolved.DisplayName))
  [void]$Lines.Add(('Resolved tag: {0}' -f $Resolved.Tag))
  [void]$Lines.Add(('Resolved channel: {0}' -f $Resolved.Channel))
  [void]$Lines.Add(('Catalog SHA-256: {0}' -f $Resolved.CatalogSha256))
  $offlineZip = 'offline/{0}/workstation.zip' -f $Resolved.Tag
  $offlineManifest = 'offline/{0}/update-manifest.json' -f $Resolved.Tag
  [void]$Lines.Add(('Offline payload: {0}' -f $offlineZip))
  [void]$Lines.Add(('Offline payload: {0}' -f $offlineManifest))
  $zipPath = Join-Path -Path (Join-Path -Path (Join-Path -Path $PackageRoot -ChildPath 'offline') -ChildPath $Resolved.Tag) -ChildPath 'workstation.zip'
  $manifestPath = Join-Path -Path (Join-Path -Path (Join-Path -Path $PackageRoot -ChildPath 'offline') -ChildPath $Resolved.Tag) -ChildPath 'update-manifest.json'
  $present = (Test-Path -LiteralPath $zipPath -PathType Leaf) -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)
  if ($present) { [void]$Lines.Add('Offline payload present: yes') }
  else { [void]$Lines.Add('Offline payload present: no') }
}

function Get-SetupPlan {
  param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [string]$Brand,
    [string]$Channel = 'beta',
    [string]$Tag,
    [string]$Source,
    [switch]$OfflineOnly,
    [switch]$VerifyOnly,
    [switch]$AllowDowngrade,
    [switch]$WhatIf,
    [switch]$Report,
    [string[]]$Remaining,
    [switch]$NonInteractive
  )
  $lines = New-Object System.Collections.Generic.List[string]
  $report = [bool]($WhatIf -or $Report)
  foreach ($extra in @($Remaining)) {
    if (Test-SetupReportArgument ([string]$extra)) { $report = $true }
  }
  $brandText = ''
  if ($null -ne $Brand) { $brandText = $Brand.Trim().ToLowerInvariant() }
  if ($brandText -eq '/report' -or $brandText -eq '/whatif' -or $brandText -eq '--report' -or $brandText -eq '--whatif') {
    $report = $true
    $brandText = ''
  }
  if ([string]::IsNullOrWhiteSpace($brandText) -and -not $report -and -not $NonInteractive) {
    $brandText = Read-SetupBrandPrompt
  }
  if ([string]::IsNullOrWhiteSpace($brandText)) {
    [void]$lines.Add('No brand was resolved. Pass -Brand mercedes or -Brand bmw. Nothing was installed.')
    if ($report) {
      [void]$lines.Add('Package files:')
      foreach ($rel in @(Get-SetupPackageFiles $PackageRoot)) { [void]$lines.Add($rel) }
    }
    return [pscustomobject]@{ ExitCode = 1; Report = $report; Lines = @($lines.ToArray()); Installer = $null; Parameters = $null }
  }
  try {
    $null = Get-BrandAllowEntry $brandText
  } catch {
    [void]$lines.Add('No brand was resolved. Pass -Brand mercedes or -Brand bmw. Nothing was installed.')
    return [pscustomobject]@{ ExitCode = 1; Report = $report; Lines = @($lines.ToArray()); Installer = $null; Parameters = $null }
  }
  try {
    $resolved = Resolve-SetupBrandSelection -PackageRoot $PackageRoot -Brand $brandText -Channel $Channel -Tag $Tag
  } catch {
    [void]$lines.Add([string]$_.Exception.Message)
    return [pscustomobject]@{ ExitCode = 1; Report = $report; Lines = @($lines.ToArray()); Installer = $null; Parameters = $null }
  }
  Add-SetupReportLines $lines $resolved $PackageRoot
  $installer = Join-Path -Path (Join-Path -Path (Join-Path -Path $PackageRoot -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'Install-Master.ps1'
  $parameters = Get-SetupForwardParameters -Brand $resolved.Brand -Channel $Channel -Tag $Tag -Source $Source -OfflineOnly:$OfflineOnly -VerifyOnly:$VerifyOnly -AllowDowngrade:$AllowDowngrade
  if ($report) {
    [void]$lines.Add('Package files:')
    foreach ($rel in @(Get-SetupPackageFiles $PackageRoot)) { [void]$lines.Add($rel) }
    [void]$lines.Add('Report only. Nothing was installed.')
    return [pscustomobject]@{ ExitCode = 0; Report = $true; Lines = @($lines.ToArray()); Installer = $installer; Parameters = $parameters }
  }
  return [pscustomobject]@{ ExitCode = 0; Report = $false; Lines = @($lines.ToArray()); Installer = $installer; Parameters = $parameters }
}
