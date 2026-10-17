# Places a verified brand tree into that brand's allow-listed root.
# Machine-local files are carried across. Winlogon, the shell, and Run startup are not touched.

function Assert-BrandNotRunning {
  param([Parameter(Mandatory = $true)][string]$Root)
  if (-not (Test-MasterHostWindows)) { throw 'Could not check running processes. Nothing was installed.' }
  $leaf = [regex]::Escape((Split-Path -Leaf $Root))
  try {
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
      $_.CommandLine -and
      $_.CommandLine -match $leaf -and
      $_.CommandLine -match 'Launcher\.ps1|Dock\.ps1|Watchdog\.ps1|WorkstationManager\.exe|WorkstationShell\.ps1'
    })
  } catch {
    throw 'Could not check running processes. Nothing was installed.'
  }
  if ($processes.Count -gt 0) { throw 'That brand is running. Nothing was installed.' }
}

function Assert-InstallSpace {
  param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][int64]$Bytes)
  if (-not (Test-MasterHostWindows)) { return }
  $parent = Split-Path -Parent $Root
  if (-not (Test-Path -LiteralPath $parent)) { return }
  $full = (Resolve-Path -LiteralPath $parent).Path
  $drive = [System.IO.Path]::GetPathRoot($full)
  $info = New-Object System.IO.DriveInfo($drive.Substring(0, 1))
  if ($info.AvailableFreeSpace -lt ($Bytes * 2)) { throw 'Not enough free space. Nothing was installed.' }
}

function Copy-PreservedTree {
  param([Parameter(Mandatory = $true)][string]$From, [Parameter(Mandatory = $true)][string]$To)
  if (-not (Test-Path -LiteralPath $From -PathType Container)) { return }
  foreach ($name in $script:MasterPreserveFiles) {
    $src = Join-Path -Path $From -ChildPath $name
    if (Test-Path -LiteralPath $src -PathType Leaf) {
      Copy-Item -LiteralPath $src -Destination (Join-Path -Path $To -ChildPath $name) -Force
    }
  }
  $logs = Join-Path -Path $From -ChildPath 'logs'
  if (Test-Path -LiteralPath $logs -PathType Container) {
    $destLogs = Join-Path -Path $To -ChildPath 'logs'
    Copy-Item -LiteralPath $logs -Destination $destLogs -Recurse -Force
  }
  Get-ChildItem -LiteralPath $From -Force | Where-Object {
    $_.Name -like 'ControlBackup-*' -or $_.Name -like 'Backup-*' -or $_.Name -like '*.backup-*'
  } | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path -Path $To -ChildPath $_.Name) -Recurse -Force
  }
}

function Read-InstalledMarker {
  param([Parameter(Mandatory = $true)][string]$Root)
  $path = Join-Path -Path $Root -ChildPath '.installed-bundle.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  return Read-JsonFile $path
}

function Write-InstalledMarker {
  param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)]$Marker)
  $path = Join-Path -Path $Root -ChildPath '.installed-bundle.json'
  Write-Utf8NoBom $path (($Marker | ConvertTo-Json -Depth 8) + "`n")
}

function Remove-OldPrevFolders {
  param([Parameter(Mandatory = $true)][string]$Parent, [Parameter(Mandatory = $true)][string]$Leaf)
  $pattern = '^' + [regex]::Escape($Leaf) + '\.prev-'
  $dirs = @(Get-ChildItem -LiteralPath $Parent -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern } | Sort-Object Name -Descending)
  for ($i = 2; $i -lt $dirs.Count; $i++) {
    Remove-Item -LiteralPath $dirs[$i].FullName -Recurse -Force
  }
}

function Repair-InterruptedInstall {
  param([Parameter(Mandatory = $true)][string]$ProgressPath)
  if (-not (Test-Path -LiteralPath $ProgressPath -PathType Leaf)) { return }
  $state = Read-JsonFile $ProgressPath
  $root = [string]$state.root
  $prev = [string]$state.prev
  if ([string]::IsNullOrWhiteSpace($root) -or [string]::IsNullOrWhiteSpace($prev)) {
    Remove-Item -LiteralPath $ProgressPath -Force
    throw 'Interrupted install record was incomplete. Nothing was installed.'
  }
  if ((Split-Path -Parent $root) -ne (Split-Path -Parent $prev)) {
    throw 'Interrupted install paths disagree. Nothing was installed.'
  }
  $marker = Join-Path -Path $root -ChildPath '.installed-bundle.json'
  $restored = $false
  if ((Test-Path -LiteralPath $prev -PathType Container) -and -not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    if (Test-Path -LiteralPath $root) {
      $failed = $root + '.failed-repair'
      if (Test-Path -LiteralPath $failed) { Remove-Item -LiteralPath $failed -Recurse -Force }
      Rename-Item -LiteralPath $root -NewName (Split-Path -Leaf $failed)
    }
    if (-not (Test-Path -LiteralPath $root)) {
      Rename-Item -LiteralPath $prev -NewName (Split-Path -Leaf $root)
    }
    $restored = $true
  } elseif ((Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $marker) -and -not (Test-Path -LiteralPath $prev)) {
    Remove-Item -LiteralPath $ProgressPath -Force
    throw 'Interrupted install left an unmarked root. Nothing was installed.'
  }
  Remove-Item -LiteralPath $ProgressPath -Force
  if ($restored) { throw 'Recovered an interrupted install. Previous files were restored. Nothing new was installed.' }
}

function Install-VerifiedTree {
  param(
    [Parameter(Mandatory = $true)][string]$Staging,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Brand,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$ZipSha256,
    [string]$ProgressPath,
    [switch]$AllowDowngrade
  )
  $allow = Get-BrandAllowEntry $Brand
  $parent = Split-Path -Parent $Root
  if ([string]::IsNullOrWhiteSpace($parent)) { throw 'Install root has no parent. Nothing was installed.' }
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $existing = $null
  if (Test-Path -LiteralPath $Root -PathType Container) { $existing = Read-InstalledMarker $Root }
  if ($existing -and [string]$existing.brand -and [string]$existing.brand -ne $Brand) {
    throw "Install root belongs to $($existing.brand). Nothing was installed."
  }
  if ($existing -and [string]$existing.version -and -not $AllowDowngrade) {
    if ((Get-ReleaseRank $Version) -lt (Get-ReleaseRank ([string]$existing.version))) {
      throw 'Refusing to install an older approved version. Nothing was installed.'
    }
  }
  $leaf = Split-Path -Leaf $Root
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  $prevLeaf = '{0}.prev-{1}' -f $leaf, $stamp
  $prev = Join-Path -Path $parent -ChildPath $prevLeaf
  $existed = Test-Path -LiteralPath $Root -PathType Container
  if ($ProgressPath) {
    $record = [ordered]@{ phase = 'swapping'; brand = $Brand; root = $Root; prev = $prev; tag = $Tag }
    Write-Utf8NoBom $ProgressPath (($record | ConvertTo-Json -Compress) + "`n")
  }
  if ($existed) { Copy-PreservedTree $Root $Staging }
  if ($existed) { Rename-Item -LiteralPath $Root -NewName $prevLeaf }
  try {
    Rename-Item -LiteralPath $Staging -NewName $leaf
    $marker = [ordered]@{
      schema = 'diagnostic-workstation.installed-bundle/v1'
      brand = $Brand
      tag = $Tag
      version = $Version
      zipSha256 = $ZipSha256
      installRoot = $allow.Root
      supervisor = $allow.Supervisor
      supervisorNote = $allow.SupervisorNote
      installedUtc = [datetimeoffset]::UtcNow.ToString('o')
      shellRegistration = 'not-changed'
    }
    Write-InstalledMarker $Root $marker
  } catch {
    $failedLeaf = '{0}.failed-{1}' -f $leaf, $stamp
    if (Test-Path -LiteralPath $Root) {
      if (Test-Path -LiteralPath (Join-Path $parent $failedLeaf)) { Remove-Item -LiteralPath (Join-Path $parent $failedLeaf) -Recurse -Force }
      Rename-Item -LiteralPath $Root -NewName $failedLeaf -ErrorAction SilentlyContinue
    }
    if ($existed -and (Test-Path -LiteralPath $prev -PathType Container) -and -not (Test-Path -LiteralPath $Root)) {
      Rename-Item -LiteralPath $prev -NewName $leaf
    }
    if ($ProgressPath -and (Test-Path -LiteralPath $ProgressPath)) { Remove-Item -LiteralPath $ProgressPath -Force }
    throw "Install failed and the previous folder was restored. $($_.Exception.Message)"
  }
  if ($ProgressPath -and (Test-Path -LiteralPath $ProgressPath)) { Remove-Item -LiteralPath $ProgressPath -Force }
  Remove-OldPrevFolders $parent $leaf
}

function Install-ApprovedBrand {
  param(
    [Parameter(Mandatory = $true)][string]$Brand,
    [ValidateSet('beta', 'stable')][string]$Channel = 'beta',
    [string]$Tag,
    [string]$Source,
    [switch]$OfflineOnly,
    [switch]$VerifyOnly,
    [switch]$AllowDowngrade,
    [switch]$AllowTestRoot,
    [switch]$AllowUncheckedProcesses,
    [switch]$ApplySecurity,
    [string]$InstallRoot,
    [string]$LogDirectory,
    [string]$InstallerData,
    [string]$RepoRoot,
    [string]$LocalAppData,
    [string]$Arch,
    [scriptblock]$Downloader,
    [scriptblock]$ToolRunner,
    [scriptblock]$StateReader,
    [scriptblock]$TamperReader,
    [scriptblock]$TamperPrompt,
    [scriptblock]$DefenderReader,
    [scriptblock]$DefenderSink
  )
  $allow = Get-BrandAllowEntry $Brand
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Find-MasterRepoRoot $PSScriptRoot }
  if ($AllowTestRoot) {
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { throw 'Test install root is required. Nothing was installed.' }
    $root = $InstallRoot
  } else {
    $root = Resolve-BrandInstallRoot $Brand $LocalAppData
    $expectedLeaf = $allow.Root
    if ((Split-Path -Leaf $root) -ne $expectedLeaf) { throw 'Install root does not match the allow map. Nothing was installed.' }
  }
  if ([string]::IsNullOrWhiteSpace($InstallerData)) {
    $base = $LocalAppData
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:LOCALAPPDATA }
    if ([string]::IsNullOrWhiteSpace($base)) { throw 'LOCALAPPDATA is not set. Nothing was installed.' }
    $InstallerData = Join-Path -Path $base -ChildPath 'DiagnosticWorkstation-Installer'
  }
  if ([string]::IsNullOrWhiteSpace($LogDirectory)) { $LogDirectory = Join-Path -Path $InstallerData -ChildPath 'logs' }
  New-Item -ItemType Directory -Force -Path $InstallerData, $LogDirectory | Out-Null
  $progress = Join-Path -Path $InstallerData -ChildPath 'install-in-progress.json'
  Repair-InterruptedInstall $progress

  $catalogPath = Join-MasterPath $RepoRoot @('catalog', 'catalog.json')
  $pinPath = Join-MasterPath $RepoRoot @('catalog', 'catalog.sha256')
  $keys = Join-MasterPath $RepoRoot @('keys')
  $signature = Join-MasterPath $RepoRoot @('catalog', 'catalog.json.release.sig')
  $trust = Join-Path -Path $InstallerData -ChildPath 'trust-state.json'
  $loaded = Read-ApprovedCatalog $catalogPath $pinPath $keys $signature $trust
  if ($loaded.Warning) {
    Add-MasterJournal $LogDirectory ([pscustomobject]@{ step = 'catalog-warning'; message = $loaded.Warning; brand = $Brand })
  }
  $catalogBrand = Get-CatalogBrand $loaded.Catalog $Brand
  $releaseMeta = Read-BrandReleaseFile (Join-MasterPath $RepoRoot @('brands', $Brand, 'release.json')) $Brand $catalogBrand
  $release = Select-ApprovedRelease $catalogBrand $Brand $Channel $Tag
  Add-MasterJournal $LogDirectory ([pscustomobject]@{
    step = 'release-selected'; brand = $Brand; tag = [string]$release.tag; version = [string]$release.version; channel = $Channel
  })

  $work = Join-Path -Path $InstallerData -ChildPath ('work-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $parent = Split-Path -Parent $root
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $staging = Join-Path -Path $parent -ChildPath ('.staging-{0}-{1}' -f $Brand, [guid]::NewGuid().ToString('n'))
  $payload = $null
  try {
    $payload = Receive-ApprovedPayload -Brand $Brand -Release $release -Source $Source -RepoRoot $RepoRoot -OfflineOnly:$OfflineOnly -WorkDirectory $work -Downloader $Downloader
    Add-MasterJournal $LogDirectory ([pscustomobject]@{ step = 'payload-acquired'; source = $payload.Source; brand = $Brand; tag = [string]$release.tag })
    $manifest = Open-VerifiedBundle -Brand $Brand -Release $release -ZipPath $payload.Zip -ManifestPath $payload.Manifest -Staging $staging
    Add-MasterJournal $LogDirectory ([pscustomobject]@{ step = 'payload-verified'; brand = $Brand; tag = [string]$release.tag; sha256 = [string]$release.sha256; bytes = [int64]$release.bytes })
    if ($VerifyOnly) {
      return [pscustomobject]@{
        brand = $Brand; tag = [string]$release.tag; version = [string]$release.version; source = $payload.Source
        catalogWarning = $loaded.Warning; installRoot = $root; installed = $false; verified = $true
        windowsUpdate = 'not-run'; defender = 'not-run'; tamper = 'not-checked'
        releaseFile = [string]$releaseMeta.brand
      }
    }
    Assert-InstallSpace $root ([int64]$release.bytes)
    if (-not $AllowUncheckedProcesses) { Assert-BrandNotRunning $root }
    Install-VerifiedTree -Staging $staging -Root $root -Brand $Brand -Tag ([string]$release.tag) -Version ([string]$release.version) -ZipSha256 ([string]$release.sha256) -ProgressPath $progress -AllowDowngrade:$AllowDowngrade
    Write-TrustState $trust ([int]$loaded.Catalog.catalogSerial) $loaded.Digest
    Add-MasterJournal $LogDirectory ([pscustomobject]@{ step = 'installed'; brand = $Brand; root = $root; tag = [string]$release.tag })
    $security = [pscustomobject]@{ windowsUpdate = 'not-run'; defender = 'not-run'; tamper = 'not-checked' }
    if ($ApplySecurity) {
      try {
        $security = Invoke-AutomaticSecurity -Brand $Brand -InstallerData $InstallerData -LogDirectory $LogDirectory -RepoRoot $RepoRoot -Arch $Arch -ToolRunner $ToolRunner -StateReader $StateReader -TamperReader $TamperReader -TamperPrompt $TamperPrompt -DefenderReader $DefenderReader -DefenderSink $DefenderSink
      } catch {
        Add-MasterJournal $LogDirectory ([pscustomobject]@{ step = 'security-failed'; brand = $Brand; message = $_.Exception.Message })
        $security = [pscustomobject]@{ windowsUpdate = 'failed'; defender = 'failed'; tamper = 'unknown' }
      }
    }
    return [pscustomobject]@{
      brand = $Brand; tag = [string]$release.tag; version = [string]$release.version; source = $payload.Source
      catalogWarning = $loaded.Warning; installRoot = $root; installed = $true; verified = $true
      windowsUpdate = $security.windowsUpdate; defender = $security.defender; tamper = $security.tamper
    }
  } catch {
    Add-MasterJournal $LogDirectory ([pscustomobject]@{ step = 'failed'; brand = $Brand; message = $_.Exception.Message })
    throw
  } finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
