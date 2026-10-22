# Places a verified brand tree into that brand's allow-listed root.
# Machine-local files are carried across. Winlogon, the shell, and Run startup are not touched.

# WorkstationManager waits while <brand root>\install-in-progress.lock exists, then starts
# Launcher, Dock, and UpdateAgent. A clean exit of those scripts makes it open another
# powershell.exe. Watchdog.ps1 and WorkstationShell.ps1 do not read the lock; they are stopped
# for the duration of the swap. WorkstationManager.exe itself is left running so it can keep
# honoring the lock. This installer does not register a scheduled task and does not start the supervisor.
$script:BrandLoopSupervisorTokens = @(
  'Launcher.ps1',
  'Dock.ps1',
  'Watchdog.ps1',
  'WorkstationShell.ps1',
  'UpdateAgent.ps1',
  'SystemPanel.ps1',
  'Restart-Mercedes-Controls.ps1',
  'Restart-BMW-Controls.ps1'
)

function Get-BrandInstallLockPath {
  param([Parameter(Mandatory = $true)][string]$Root)
  return (Join-Path -Path $Root -ChildPath 'install-in-progress.lock')
}

function Test-SupervisorRelaunchBlocked {
  param([Parameter(Mandatory = $true)][string]$Root)
  return (Test-Path -LiteralPath (Get-BrandInstallLockPath $Root))
}

# A live lock is an owner PID that is still alive and matches the recorded process
# start time, or a live PID whose start time cannot be read while the nonce is present.
# A blank recorded start time cannot prove the PID was reused, so that lock follows age.
# Liveness is checked before age. A live owner older than the timeout is still live.
# A dead PID or a reused PID is stale. Age applies to a legacy lock with no owner PID
# and to a live PID whose recorded start time is missing.
$script:BrandInstallLockTimeout = [timespan]::FromHours(2)
$script:HarnessFailSwapToken = 'diagnostic-workstation-test-fail-swap'
$script:HarnessFailSwapArmed = $false
$script:BrandInstallLockFailWrite = $false

function Read-BrandInstallLockRecord([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    $text = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    if (-not $text.TrimStart().StartsWith('{')) { return $null }
    return ($text | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Test-LockTimestampMissing($Value) {
  if ($null -eq $Value) { return $true }
  if ($Value -is [datetime]) { return $false }
  if ($Value -is [datetimeoffset]) { return $false }
  return [string]::IsNullOrWhiteSpace([string]$Value)
}

function ConvertTo-LockUtcDateTime($Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
  if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
  $parsed = [datetime]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]$styles)
  return $parsed.ToUniversalTime()
}

function Get-BrandInstallLockAge($Record, [string]$Path) {
  $created = $null
  if ($Record -and -not (Test-LockTimestampMissing $Record.createdUtc)) {
    try {
      $utc = ConvertTo-LockUtcDateTime $Record.createdUtc
      if ($null -ne $utc) {
        $created = [datetimeoffset]::new([datetime]::SpecifyKind($utc, [System.DateTimeKind]::Utc))
      }
    } catch { $created = $null }
  }
  if (-not $created -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
    $created = [datetimeoffset](Get-Item -LiteralPath $Path).LastWriteTimeUtc
  }
  if (-not $created) { return [timespan]::MaxValue }
  return ([datetimeoffset]::UtcNow - $created)
}

function Test-ProcessIdAlive([int]$ProcessId) {
  if ($ProcessId -le 0) { return $false }
  $found = @(Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
  return ($found.Count -gt 0)
}

function Get-ProcessStartUtc([int]$ProcessId) {
  try {
    $proc = Get-Process -Id $ProcessId -ErrorAction Stop
    return $proc.StartTime.ToUniversalTime()
  } catch {
    return $null
  }
}

function Test-StartTimesMatch($ActualUtc, $Recorded) {
  if ($null -eq $ActualUtc) { return $false }
  if (Test-LockTimestampMissing $Recorded) { return $false }
  try { $parsed = ConvertTo-LockUtcDateTime $Recorded } catch { return $false }
  if ($null -eq $parsed) { return $false }
  $delta = ($ActualUtc - $parsed).TotalSeconds
  if ($delta -lt 0) { $delta = -$delta }
  return ($delta -lt 2)
}

function Get-BrandInstallLockState([string]$Path) {
  $absent = [pscustomobject]@{ Status = 'absent'; Reason = ''; Record = $null }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $absent }
  $record = Read-BrandInstallLockRecord $Path
  if ($record -and $record.ownerPid) {
    $ownerPid = 0
    try { $ownerPid = [int]$record.ownerPid } catch { $ownerPid = 0 }
    if ($ownerPid -gt 0) {
      $start = Get-ProcessStartUtc $ownerPid
      $recordedMissing = Test-LockTimestampMissing $record.ownerStartUtc
      $startMatches = $false
      if (-not $recordedMissing) { $startMatches = Test-StartTimesMatch $start $record.ownerStartUtc }
      $nonce = [string]$record.nonce
      $nonceMatches = (-not [string]::IsNullOrWhiteSpace($nonce)) -and ($nonce -ceq [string]$script:BrandInstallLockNonce)
      if (($ownerPid -eq $PID) -and ($nonceMatches -or $startMatches)) {
        return [pscustomobject]@{ Status = 'owned'; Reason = 'owner'; Record = $record }
      }
      $alive = Test-ProcessIdAlive $ownerPid
      if ($alive) {
        if ($startMatches) {
          return [pscustomobject]@{ Status = 'live'; Reason = 'start-time'; Record = $record }
        }
        if (($null -eq $start) -and (-not [string]::IsNullOrWhiteSpace($nonce))) {
          return [pscustomobject]@{ Status = 'live'; Reason = 'nonce'; Record = $record }
        }
        if (-not $recordedMissing) {
          return [pscustomobject]@{ Status = 'stale'; Reason = 'pid-reused'; Record = $record }
        }
      } else {
        return [pscustomobject]@{ Status = 'stale'; Reason = 'dead-pid'; Record = $record }
      }
    }
  }
  $age = Get-BrandInstallLockAge $record $Path
  if ($age -gt $script:BrandInstallLockTimeout) {
    return [pscustomobject]@{ Status = 'stale'; Reason = 'timeout'; Record = $record }
  }
  return [pscustomobject]@{ Status = 'live'; Reason = 'unverified'; Record = $record }
}

function Get-BrandInstallLockText([string]$Nonce) {
  $start = Get-ProcessStartUtc $PID
  $startText = ''
  if ($start) { $startText = ([datetimeoffset]$start).ToString('o') }
  $record = [ordered]@{
    schema = 'diagnostic-workstation.install-lock/v1'
    ownerPid = $PID
    ownerStartUtc = $startText
    nonce = $Nonce
    createdUtc = [datetimeoffset]::UtcNow.ToString('o')
  }
  return (($record | ConvertTo-Json -Compress) + "`n")
}

function New-BrandInstallLockFile([string]$Path, [string]$Nonce) {
  $utf8 = New-Object System.Text.UTF8Encoding $false
  $bytes = $utf8.GetBytes((Get-BrandInstallLockText $Nonce))
  $stream = $null
  $created = $false
  try {
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $created = $true
  } catch [System.IO.IOException] {
    if (Test-Path -LiteralPath $Path) { return $false }
    throw
  }
  $failed = $false
  $writeError = $null
  try {
    if ($script:BrandInstallLockFailWrite) { throw (New-Object System.IO.IOException 'lock write failed') }
    $stream.Write($bytes, 0, $bytes.Length)
  } catch {
    $failed = $true
    $writeError = $_
  } finally {
    if ($stream) { $stream.Dispose() }
  }
  if ($failed) {
    if ($created) {
      try { [System.IO.File]::Delete($Path) } catch { }
    }
    throw $writeError
  }
  return $true
}

function Move-BrandInstallLockAside([string]$Path) {
  $claim = $Path + '.reclaim-' + [guid]::NewGuid().ToString('n')
  try {
    [System.IO.File]::Move($Path, $claim)
  } catch {
    return $null
  }
  return $claim
}

function Restore-MovedLock([string]$Claim, [string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Claim)) { return }
  $attempt = 0
  while ($attempt -lt 3) {
    $attempt++
    if (-not (Test-Path -LiteralPath $Claim -PathType Leaf)) { return }
    try {
      [System.IO.File]::Move($Claim, $Path)
      return
    } catch {
      $length = -1
      try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
          $length = [int64](Get-Item -LiteralPath $Path).Length
        }
      } catch {
        $length = -1
      }
      if ($length -eq 0) {
        try { [System.IO.File]::Delete($Path) } catch { }
        continue
      }
      return
    }
  }
}

function Remove-StaleLockSidecars([string]$Path) {
  $directory = Split-Path -Parent $Path
  if ([string]::IsNullOrWhiteSpace($directory)) { return }
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return }
  $leaf = Split-Path -Leaf $Path
  $cutoff = [datetime]::UtcNow.Add(-$script:BrandInstallLockTimeout)
  $prefixes = @(
    ($leaf + '.reclaim-'),
    ($leaf + '.release-'),
    ($leaf + '.refresh-')
  )
  foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -File -ErrorAction SilentlyContinue)) {
    $matched = $false
    foreach ($prefix in $prefixes) {
      if ($item.Name.StartsWith($prefix, [System.StringComparison]::Ordinal)) { $matched = $true }
    }
    if (-not $matched) { continue }
    try {
      if ($item.LastWriteTimeUtc -lt $cutoff) {
        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
      }
    } catch { }
  }
}

function Update-OwnedBrandInstallLock([string]$Path, [string]$Nonce, [string]$ExpectedNonce) {
  $temp = $Path + '.refresh-' + [guid]::NewGuid().ToString('n')
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($temp, (Get-BrandInstallLockText $Nonce), $utf8)
  $again = Read-BrandInstallLockRecord $Path
  $current = ''
  if ($again) { $current = [string]$again.nonce }
  if ($current -cne $ExpectedNonce) {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    return $false
  }
  $backup = $Path + '.refresh-bak'
  try {
    [System.IO.File]::Replace($temp, $Path, $backup)
  } catch {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    return $false
  }
  if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
  $check = Read-BrandInstallLockRecord $Path
  return ($check -and ([string]$check.nonce -ceq $Nonce))
}

function Set-BrandInstallLock {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$LogDirectory
  )
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }
  $path = Get-BrandInstallLockPath $Root
  Remove-StaleLockSidecars $path
  $attempt = 0
  while ($attempt -lt 8) {
    $attempt++
    $state = Get-BrandInstallLockState $path
    if ($state.Status -eq 'live') {
      $owner = 'owner cannot be verified'
      if ($state.Record -and $state.Record.ownerPid) { $owner = 'process ' + [string]$state.Record.ownerPid }
      throw "Another install already holds install-in-progress.lock for this folder ($owner). Nothing was installed."
    }
    if ($state.Status -eq 'owned') {
      $nonce = ''
      $expected = ''
      if ($state.Record) { $expected = [string]$state.Record.nonce }
      if (-not [string]::IsNullOrWhiteSpace($expected)) { $nonce = $expected }
      else { $nonce = [guid]::NewGuid().ToString('n') }
      if (Update-OwnedBrandInstallLock $path $nonce $expected) {
        $script:BrandInstallLockNonce = $nonce
        return $path
      }
      continue
    }
    if ($state.Status -eq 'stale') {
      $before = ''
      try { $before = [System.IO.File]::ReadAllText($path) } catch { $before = '' }
      $claim = Move-BrandInstallLockAside $path
      if (-not $claim) { continue }
      $after = $null
      try { $after = [System.IO.File]::ReadAllText($claim) } catch { $after = $null }
      if ($null -eq $after -or $after -cne $before) {
        Restore-MovedLock $claim $path
        continue
      }
      Remove-Item -LiteralPath $claim -Force
      if (-not [string]::IsNullOrWhiteSpace($LogDirectory)) {
        $ownerPid = $null
        if ($state.Record) { $ownerPid = $state.Record.ownerPid }
        Add-MasterJournal $LogDirectory ([pscustomobject]@{
          step = 'install-lock-reclaimed'
          reason = [string]$state.Reason
          ownerPid = $ownerPid
          path = $path
        })
      }
    }
    $created = [guid]::NewGuid().ToString('n')
    if (New-BrandInstallLockFile $path $created) {
      $script:BrandInstallLockNonce = $created
      return $path
    }
  }
  throw 'Could not take install-in-progress.lock. Nothing was installed.'
}

function Test-HarnessFailSwapMarker {
  param([string]$InstallerData)
  if ([string]::IsNullOrWhiteSpace($InstallerData)) { return $false }
  $pointerPath = Join-Path -Path $InstallerData -ChildPath 'fail-swap.location'
  if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) { return $false }
  $markerPath = ([System.IO.File]::ReadAllText($pointerPath)).Trim()
  if ([string]::IsNullOrWhiteSpace($markerPath)) { return $false }
  if ((Split-Path -Leaf $markerPath) -cne 'fail-swap.marker') { return $false }
  if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }
  $markerFull = [System.IO.Path]::GetFullPath($markerPath)
  $dataFull = [System.IO.Path]::GetFullPath($InstallerData)
  if ($markerFull.StartsWith($dataFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  $token = ([System.IO.File]::ReadAllText($markerPath)).Trim()
  if ($token -cne $script:HarnessFailSwapToken) { return $false }
  return $true
}

function Set-HarnessFailSwapArmed {
  param(
    [switch]$Allow,
    [string]$InstallerData,
    [string]$LogDirectory
  )
  # Production installs, including Setup.exe, do not pass -Allow.
  # A user-level process cannot arm the swap failure by writing under LOCALAPPDATA.
  $script:HarnessFailSwapArmed = $false
  if (-not $Allow) { return }
  if (-not (Test-HarnessFailSwapMarker $InstallerData)) { return }
  $script:HarnessFailSwapArmed = $true
  if (-not [string]::IsNullOrWhiteSpace($LogDirectory)) {
    Add-MasterJournal $LogDirectory ([pscustomobject]@{
      step = 'harness-fail-swap-armed'
      marker = 'fail-swap.marker'
    })
  }
}

function Remove-BrandInstallLock {
  param([string]$Root)
  if ([string]::IsNullOrWhiteSpace($Root)) { return }
  $path = Get-BrandInstallLockPath $Root
  Remove-StaleLockSidecars $path
  $nonce = [string]$script:BrandInstallLockNonce
  if ([string]::IsNullOrWhiteSpace($nonce)) { return }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
  $record = Read-BrandInstallLockRecord $path
  if (-not $record -or [string]$record.nonce -cne $nonce) { return }
  $claim = $path + '.release-' + [guid]::NewGuid().ToString('n')
  try { [System.IO.File]::Move($path, $claim) } catch { return }
  $moved = Read-BrandInstallLockRecord $claim
  if ($moved -and [string]$moved.nonce -ceq $nonce) {
    Remove-Item -LiteralPath $claim -Force -ErrorAction SilentlyContinue
    return
  }
  Restore-MovedLock $claim $path
}

function Test-IsBrandSupervisorCommand {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$CommandLine,
    [int]$ProcessId
  )
  if ($ProcessId -eq $PID) { return $false }
  if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
  $norm = $CommandLine.Replace('/', '\')
  $rootNorm = $Root.Replace('/', '\').TrimEnd('\')
  if ($norm.IndexOf($rootNorm, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
  if ($norm -match 'Install-Master\.ps1|Enable-Security\.ps1|Uninstall-MasterBrand\.ps1') { return $false }
  foreach ($token in $script:BrandLoopSupervisorTokens) {
    if ($norm.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  }
  return $false
}

function Get-Win32ProcessCommandLines {
  if (-not (Test-MasterHostWindows)) { return @() }
  try {
    return @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
      [pscustomobject]@{ ProcessId = [int]$_.ProcessId; CommandLine = [string]$_.CommandLine }
    })
  } catch {
    throw 'Could not check running processes. Nothing was installed.'
  }
}

function Stop-BrandSupervisorProcesses {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [scriptblock]$ProcessQuery,
    [scriptblock]$ProcessStop
  )
  $rows = @()
  if ($ProcessQuery) { $rows = @(& $ProcessQuery) }
  elseif (Test-MasterHostWindows) { $rows = @(Get-Win32ProcessCommandLines) }
  else { return @() }
  $stopped = New-Object System.Collections.Generic.List[int]
  foreach ($row in @($rows)) {
    if (-not $row) { continue }
    $id = [int]$row.ProcessId
    if (-not (Test-IsBrandSupervisorCommand -Root $Root -CommandLine ([string]$row.CommandLine) -ProcessId $id)) { continue }
    if ($ProcessStop) { & $ProcessStop $id }
    else {
      if ($env:MASTER_INSTALLER_FORBID_TOOL_EXECUTION -eq '1') { throw 'stopping brand processes is forbidden in this session' }
      Stop-Process -Id $id -Force -ErrorAction Stop
    }
    $stopped.Add($id)
  }
  return @($stopped.ToArray())
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
  foreach ($name in @($script:MasterPreserveFiles + $script:MasterCarryExistingFiles)) {
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
  if ($restored) {
    if (Test-Path -LiteralPath $root -PathType Container) {
      $failedRepair = $root + '.failed-repair'
      if (Test-Path -LiteralPath $failedRepair) { Remove-Item -LiteralPath $failedRepair -Recurse -Force }
    }
    throw 'Recovered an interrupted install. Previous files were restored. Nothing new was installed.'
  }
}

function Assert-InstallTargetAllowed {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Brand,
    [Parameter(Mandatory = $true)][string]$Version,
    [switch]$AllowDowngrade
  )
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
  Assert-InstallTargetAllowed -Root $Root -Brand $Brand -Version $Version -AllowDowngrade:$AllowDowngrade
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
    # Library tests set the env var in-process. Install-Master.ps1 clears it before elevation.
    # HarnessFailSwapArmed is set only when -AllowHarnessFailSwap is passed. Production
    # installs, including Setup.exe, do not pass that switch, so a fail-swap.marker
    # pointer under LOCALAPPDATA cannot arm this throw.
    if (($env:DIAGNOSTIC_WORKSTATION_TEST_FAIL_SWAP -eq '1') -or $script:HarnessFailSwapArmed) {
      throw 'test-only failure during install swap'
    }
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
    [switch]$AllowHarnessFailSwap,
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
  Set-HarnessFailSwapArmed -Allow:$AllowHarnessFailSwap -InstallerData $InstallerData -LogDirectory $LogDirectory

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
  $lockHeld = $false
  $staging = $null
  $payload = $null
  try {
    # Refuse a foreign brand or a downgrade before any extract, staging directory, lock, or supervisor stop.
    Assert-InstallTargetAllowed -Root $root -Brand $Brand -Version ([string]$release.version) -AllowDowngrade:$AllowDowngrade
    Add-MasterJournal $LogDirectory ([pscustomobject]@{
      step = 'release-selected'; brand = $Brand; tag = [string]$release.tag; version = [string]$release.version; channel = $Channel
    })

    $parent = Split-Path -Parent $root
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $staging = Join-Path -Path $parent -ChildPath ('.staging-{0}-{1}' -f $Brand, [guid]::NewGuid().ToString('n'))
    $payload = Receive-ApprovedPayload -Brand $Brand -Release $release -Source $Source -RepoRoot $RepoRoot -OfflineOnly:$OfflineOnly -Downloader $Downloader
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
    # Re-check immediately before the lock. A foreign or older target still must not be locked or stopped.
    Assert-InstallTargetAllowed -Root $root -Brand $Brand -Version ([string]$release.version) -AllowDowngrade:$AllowDowngrade
    # Hold the lock before the rename. WorkstationManager will not start a new PowerShell
    # while it exists. The renamed previous folder takes this copy with it, so the new
    # root gets a fresh lock before Windows Update or Defender run.
    $heldLock = Set-BrandInstallLock -Root $root -LogDirectory $LogDirectory
    if (-not [string]::IsNullOrWhiteSpace([string]$heldLock)) { $lockHeld = $true }
    $stopped = @()
    if (-not $AllowUncheckedProcesses) { $stopped = @(Stop-BrandSupervisorProcesses -Root $root) }
    Add-MasterJournal $LogDirectory ([pscustomobject]@{ step = 'supervisor-held'; brand = $Brand; stopped = @($stopped) })
    Install-VerifiedTree -Staging $staging -Root $root -Brand $Brand -Tag ([string]$release.tag) -Version ([string]$release.version) -ZipSha256 ([string]$release.sha256) -ProgressPath $progress -AllowDowngrade:$AllowDowngrade
    $heldLock = Set-BrandInstallLock -Root $root -LogDirectory $LogDirectory
    if (-not [string]::IsNullOrWhiteSpace([string]$heldLock)) { $lockHeld = $true }
    if (-not $AllowUncheckedProcesses) { Stop-BrandSupervisorProcesses -Root $root | Out-Null }
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
    # Remove-BrandInstallLock deletes the file only when its nonce is the one this run created.
    if ($lockHeld) { Remove-BrandInstallLock $root }
    if ($staging -and (Test-Path -LiteralPath $staging)) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    if ($payload -and -not [string]::IsNullOrWhiteSpace([string]$payload.DownloadRoot) -and (Test-Path -LiteralPath ([string]$payload.DownloadRoot))) {
      Remove-Item -LiteralPath ([string]$payload.DownloadRoot) -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
