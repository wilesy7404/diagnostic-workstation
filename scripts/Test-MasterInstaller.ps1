# Master installer checks. No network, no Windows Update change, no Defender change, no install onto a real profile.
$ErrorActionPreference = 'Stop'
$env:MASTER_INSTALLER_FORBID_TOOL_EXECUTION = '1'
$repo = Split-Path -Parent $PSScriptRoot
$lib = Join-Path $repo 'installer/Master/lib'
. (Join-Path $lib 'Common.ps1')
. (Join-Path $lib 'Catalog.ps1')
. (Join-Path $lib 'Bundle.ps1')
. (Join-Path $lib 'Defender.ps1')
. (Join-Path $lib 'Security.ps1')
. (Join-Path $lib 'Install.ps1')

$failures = New-Object System.Collections.Generic.List[string]
function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
  $threw = $false
  $message = ''
  try { & $Action } catch { $threw = $true; $message = $_.Exception.Message }
  if (-not $threw) { throw "expected failure matching $Pattern" }
  if ($message -notmatch $Pattern) { throw "message '$message' did not match $Pattern" }
}
function Test-LockNumber($Value) {
  return (
    $Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or
    $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or
    $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]
  )
}
function Assert-SameLockValue($Actual, $Expected, [string]$Label) {
  if ($null -eq $Expected -and $null -eq $Actual) { return }
  if ($null -eq $Expected -or $null -eq $Actual) {
    throw "$Label changed"
  }
  $actualNumber = Test-LockNumber $Actual
  $expectedNumber = Test-LockNumber $Expected
  $sameType = $false
  if ($actualNumber -or $expectedNumber) {
    $sameType = $actualNumber -and $expectedNumber
  } else {
    $sameType = $Actual.GetType() -eq $Expected.GetType()
  }
  if (-not $sameType) { throw "$Label type mismatch" }
  if (-not ($Actual -ceq $Expected)) { throw "$Label changed" }
}
function Assert-LockRowIdentities($Entries) {
  $rows = @($Entries)
  $seenIdentity = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
  $seenTag = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
  foreach ($row in $rows) {
    $identity = ([string]$row.brand) + "`n" + ([string]$row.version)
    if (-not $seenIdentity.Add($identity)) {
      throw "versions lock duplicate brand and version $($row.brand) $($row.version)"
    }
    if ($null -ne $row.tag) {
      $tag = [string]$row.tag
      if (-not $seenTag.Add($tag)) {
        throw "versions lock duplicate tag $tag"
      }
    }
  }
}
function Get-LockFieldKey($Row) {
  $names = @($Row.PSObject.Properties.Name)
  return ((@($names | Sort-Object)) -join "`n")
}
# A published:false row may become published:true and gain only these scalar fields.
# Hashes, version, tag, sourceCommit, workflowRunId, and every other existing field stay fixed.
$script:PublishRecordFieldNames = @(
  'releaseId',
  'publishedAt',
  'releaseTarget',
  'workstationZipAssetId',
  'updateManifestAssetId'
)
function Test-PublishRecordName([string]$Name) {
  foreach ($candidate in @($script:PublishRecordFieldNames)) {
    if ($candidate -ceq $Name) { return $true }
  }
  return $false
}
function Test-LockNameListed($Names, [string]$Name) {
  foreach ($candidate in @($Names)) {
    if ([string]$candidate -ceq $Name) { return $true }
  }
  return $false
}
function Assert-LockWholeNumber($Value, [string]$Label) {
  if (-not (Test-LockNumber $Value)) { throw "$Label type mismatch" }
  $asDecimal = [decimal]$Value
  if ($asDecimal -ne [decimal]::Truncate($asDecimal)) { throw "$Label type mismatch" }
  if ($asDecimal -le 0) { throw "$Label type mismatch" }
}
function Get-PublishTimestampUtc($Value) {
  # PowerShell 7 ConvertFrom-Json turns a Z timestamp into a UTC DateTime.
  # Windows PowerShell 5.1 leaves the same JSON value as a string.
  if ($Value -is [string]) {
    if ($Value -cnotmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z') { return $null }
    return [datetime]::ParseExact($Value, 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
  }
  if ($Value -is [datetime]) {
    if ($Value.Kind -ne [System.DateTimeKind]::Utc) { return $null }
    if ($Value.Millisecond -ne 0) { return $null }
    return $Value.ToUniversalTime()
  }
  return $null
}
function Test-PublishTimestampEqual($Actual, [string]$Expected) {
  $actualUtc = Get-PublishTimestampUtc $Actual
  $expectedUtc = Get-PublishTimestampUtc $Expected
  if ($null -eq $actualUtc -or $null -eq $expectedUtc) { return $false }
  return ($actualUtc -eq $expectedUtc)
}
function Assert-PublishRecordValues($Row, [int]$Index) {
  Assert-LockWholeNumber $Row.releaseId "versions.lock[$Index].releaseId"
  if ($null -eq (Get-PublishTimestampUtc $Row.publishedAt)) {
    throw "versions.lock[$Index].publishedAt type mismatch"
  }
  $target = $Row.releaseTarget
  if ($target -isnot [string] -or $target -cnotmatch '\A[0-9a-f]{40}\z') {
    throw "versions.lock[$Index].releaseTarget must be 40 lowercase hex characters"
  }
  Assert-LockWholeNumber $Row.workstationZipAssetId "versions.lock[$Index].workstationZipAssetId"
  Assert-LockWholeNumber $Row.updateManifestAssetId "versions.lock[$Index].updateManifestAssetId"
}
function Select-LockCoreRow($Row) {
  $copy = [ordered]@{}
  foreach ($prop in @($Row.PSObject.Properties)) {
    if (-not (Test-PublishRecordName ([string]$prop.Name))) {
      $copy[$prop.Name] = $prop.Value
    }
  }
  return [pscustomobject]$copy
}
function Copy-LockRow($Row) {
  $copy = [ordered]@{}
  foreach ($prop in @($Row.PSObject.Properties)) {
    $copy[$prop.Name] = $prop.Value
  }
  return [pscustomobject]$copy
}
function Add-LockPublishRecord($Row) {
  $copy = [ordered]@{}
  foreach ($prop in @($Row.PSObject.Properties)) {
    if ($prop.Name -ceq 'published') {
      $copy['published'] = $true
      $copy['releaseId'] = 416761964
      $copy['publishedAt'] = '2026-10-18T23:03:37Z'
      $copy['releaseTarget'] = ('e' * 40)
      $copy['workstationZipAssetId'] = 654691267
      $copy['updateManifestAssetId'] = 654691268
    } else {
      $copy[$prop.Name] = $prop.Value
    }
  }
  return [pscustomobject]$copy
}
function Assert-VersionsLockPrefix($ActualEntries, $ExpectedEntries) {
  $actual = @($ActualEntries)
  $expected = @($ExpectedEntries)
  if ($actual.Count -lt $expected.Count) {
    throw 'versions lock dropped or reordered an entry'
  }
  for ($i = 0; $i -lt $expected.Count; $i++) {
    $actualBrand = [string]$actual[$i].brand
    $expectedBrand = [string]$expected[$i].brand
    $actualVersion = [string]$actual[$i].version
    $expectedVersion = [string]$expected[$i].version
    if ($actualBrand -cne $expectedBrand -or $actualVersion -cne $expectedVersion) {
      throw "versions.lock[$i] was reordered or replaced"
    }
    $expectedNames = @($expected[$i].PSObject.Properties.Name)
    $actualNames = @($actual[$i].PSObject.Properties.Name)
    foreach ($name in $expectedNames) {
      if (-not (Test-LockNameListed $actualNames $name)) {
        throw "versions.lock[$i] fields changed"
      }
    }
    $extra = New-Object System.Collections.Generic.List[string]
    foreach ($name in $actualNames) {
      if (-not (Test-LockNameListed $expectedNames $name)) {
        $extra.Add([string]$name)
      }
    }
    $expectedPublished = $expected[$i].published
    $actualPublished = $actual[$i].published
    $publishTransition = $false
    if (($expectedPublished -is [bool]) -and ($expectedPublished -eq $false) -and ($actualPublished -is [bool]) -and ($actualPublished -eq $true)) {
      $publishTransition = $true
    }
    if ($extra.Count -gt 0) {
      if (-not $publishTransition) { throw "versions.lock[$i] fields changed" }
      if ($extra.Count -ne @($script:PublishRecordFieldNames).Count) {
        throw "versions.lock[$i] fields changed"
      }
      foreach ($name in @($extra)) {
        if (-not (Test-PublishRecordName $name)) { throw "versions.lock[$i] fields changed" }
      }
      foreach ($name in @($script:PublishRecordFieldNames)) {
        if (-not (Test-LockNameListed $extra $name)) { throw "versions.lock[$i] publish record is incomplete" }
      }
    } elseif ($publishTransition) {
      throw "versions.lock[$i] publish record is incomplete"
    }
    foreach ($field in $expectedNames) {
      if ($publishTransition -and ($field -ceq 'published')) { continue }
      Assert-SameLockValue $actual[$i].$field $expected[$i].$field "versions.lock[$i].$field"
    }
    if ($publishTransition) { Assert-PublishRecordValues $actual[$i] $i }
  }
}
function New-SampleLockRow($Brand, $Version, $Tag, $Published, $Voided, $ZipBytes) {
  return [pscustomobject]@{
    brand = $Brand
    version = $Version
    tag = $Tag
    contentDigest = ('a' * 64)
    zipSha256 = ('b' * 64)
    zipBytes = $ZipBytes
    manifestSha256 = ('c' * 64)
    manifestBytes = $null
    fileCount = $null
    sourceCommit = $null
    workflowRunId = $null
    historical = $false
    neverReMint = $true
    voided = $Voided
    published = $Published
    note = $null
  }
}
function Assert-NewLockRow($Row, [int]$Index, [string]$FieldKey) {
  $actualKey = Get-LockFieldKey $Row
  if ($actualKey -cne $FieldKey) { throw "versions.lock[$Index] fields changed" }
  foreach ($name in @('brand', 'version', 'tag')) {
    $value = $Row.$name
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
      throw "versions.lock[$Index].$name type mismatch"
    }
  }
  $prefix = $null
  if ($Row.brand -ceq 'bmw') { $prefix = 'bmw-v' }
  elseif ($Row.brand -ceq 'mercedes') { $prefix = 'mercedes-v' }
  else { throw "versions.lock[$Index] brand is not approved" }
  $expectedTag = $prefix + [string]$Row.version
  if ($Row.tag -cne $expectedTag) {
    throw "versions.lock[$Index] tag does not match $expectedTag"
  }
  foreach ($name in @('contentDigest', 'zipSha256', 'manifestSha256')) {
    $value = $Row.$name
    if ($value -isnot [string] -or $value.Length -ne 64 -or -not ($value -cmatch '\A[0-9a-f]{64}\z')) {
      throw "versions.lock[$Index].$name must be 64 lowercase hex characters"
    }
  }
  foreach ($name in @('sourceCommit', 'workflowRunId', 'note')) {
    $value = $Row.$name
    if ($null -ne $value -and $value -isnot [string]) {
      throw "versions.lock[$Index].$name type mismatch"
    }
  }
  foreach ($name in @('zipBytes', 'manifestBytes', 'fileCount')) {
    $value = $Row.$name
    if ($null -ne $value -and -not (Test-LockNumber $value)) {
      throw "versions.lock[$Index].$name type mismatch"
    }
  }
  foreach ($name in @('historical', 'neverReMint', 'voided', 'published')) {
    $value = $Row.$name
    if ($value -isnot [bool]) {
      throw "versions.lock[$Index].$name type mismatch"
    }
  }
}
function Convert-GitText($Output) {
  if ($null -eq $Output) { return '' }
  if ($Output -is [System.Array]) { return ($Output -join "`n") }
  return [string]$Output
}
function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $output = & git @GitArgs 2>$null
  $code = $LASTEXITCODE
  $ErrorActionPreference = $previous
  return [pscustomobject]@{ Code = $code; Output = $output }
}
function Get-VersionsLockFromGit([string]$BaseName) {
  $spec = "origin/${BaseName}:releases/versions.lock.json"
  $shown = Invoke-Git --no-pager show $spec
  if ($shown.Code -ne 0 -and $env:GITHUB_EVENT_NAME -eq 'pull_request') {
    Invoke-Git fetch --depth=1 origin "${BaseName}:refs/remotes/origin/${BaseName}" | Out-Null
    $shown = Invoke-Git --no-pager show $spec
  }
  if ($shown.Code -ne 0 -or [string]::IsNullOrWhiteSpace((Convert-GitText $shown.Output))) {
    if ($env:GITHUB_EVENT_NAME -eq 'pull_request') {
      throw "versions lock baseline missing: git show $spec failed"
    }
    return $null
  }
  return ((Convert-GitText $shown.Output) | ConvertFrom-Json)
}
function Get-BytesSha256([byte[]]$Bytes) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $hash = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
  return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}
function New-FixtureZip([string]$Path, $Files) {
  Import-ZipAssembly
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  if (Test-Path $Path) { Remove-Item $Path -Force }
  $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($name in @($Files.Keys)) {
      $entry = $zip.CreateEntry($name)
      $stream = $entry.Open()
      try {
        $bytes = $Files[$name]
        $stream.Write($bytes, 0, $bytes.Length)
      } finally { $stream.Dispose() }
    }
  } finally { $zip.Dispose() }
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('master-installer-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
  $banned = @('CurrentVersion\Winlogon', 'dControl.exe')
  $sources = @(Get-ChildItem -Path (Join-Path $repo 'installer/Master') -Filter '*.ps1' -Recurse)
  $blob = ($sources | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
  foreach ($word in $banned) {
    Assert-True (-not ($blob.Contains($word))) "installer source contains $word"
  }
  Assert-True ($blob.Contains('Set-MpPreference')) 'native Defender control is missing'
  Assert-True ($blob.Contains('DisableAntiSpyware')) 'Defender policy keys are missing'
  Assert-True ($blob.Contains('DisableOnAccessProtection')) 'on-access policy is missing'
  $plan = Get-DefenderControlPlan
  foreach ($name in @('DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableIOAVProtection', 'DisableScriptScanning', 'DisableBlockAtFirstSeen', 'DisableIntrusionPreventionSystem', 'DisableEmailScanning', 'DisableRemovableDriveScanning', 'DisableScanningMappedNetworkDrivesForFullScan', 'DisableArchiveScanning', 'PUAProtection', 'MAPSReporting', 'SubmitSamplesConsent')) {
    $found = @($plan.Preferences | Where-Object { $_.Name -eq $name })
    Assert-True ($found.Count -eq 1) "preference $name is missing from the Defender plan"
  }
  foreach ($name in @('DisableAntiVirus', 'DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableOnAccessProtection', 'DisableScanOnRealtimeEnable', 'DisableIOAVProtection', 'DisableScriptScanning')) {
    $found = @($plan.Policies | Where-Object { $_.Name -eq $name })
    Assert-True ($found.Count -eq 1) "policy $name is missing from the Defender plan"
  }
  Assert-True (@($plan.Policies | Where-Object { $_.Name -eq 'DisableAntiSpyware' }).Count -eq 0) 'DisableAntiSpyware is still written'
  Assert-True ($blob.Contains('Tamper Protection reverts the DWORD')) 'DisableAntiSpyware skip is not explained'
  Assert-True (($plan.Services -join ',') -eq 'WinDefend,WdNisSvc,MDCoreSvc') 'observed Defender service list changed'
  Assert-True (-not ($blob.Contains('Set-Service'))) 'installer still changes a Defender service'
  Assert-True (-not ($blob.Contains('Stop-Service'))) 'installer still stops a Defender service'
  Assert-True (-not ($blob.Contains('Start-Service'))) 'installer still starts a Defender service'
  Assert-True (-not ($blob.Contains('TrustedInstaller'))) 'TrustedInstaller fallback is still present'
  Assert-True (-not ($blob.Contains('CreateProcessWithTokenW'))) 'TrustedInstaller process launch is still present'
  $entry = [System.IO.File]::ReadAllText((Join-Path $repo 'installer/Master/Install-Master.ps1'))
  Assert-True ($entry.Contains('-ApplySecurity:(-not $VerifyOnly)')) 'entry does not apply security after install'
  Assert-True (-not ($entry.Contains('dControl.exe'))) 'entry names dControl.exe'
  Assert-True (-not ($entry.Contains('Probe-DefenderControlCli.ps1'))) 'entry calls the Defender probe'
  Assert-True (-not ($blob.Contains('Start-Process'))) 'installer starts an unwaited process'
  Assert-True ($blob.Contains('update-manifest.json SHA-256 is required')) 'manifest SHA-256 is optional'
  Assert-True (-not ($blob.Contains('sealed-payload'))) 'offline payload is copied under LOCALAPPDATA before hashing'
  Assert-True ($blob.Contains('Get-PayloadSha256')) 'bundle does not hash the in-memory payload bytes'
  Assert-True ($blob.Contains('Register-ScheduledTask')) 'Defender SYSTEM task is not registered'
  Assert-True ($blob.Contains('Unregister-ScheduledTask')) 'Defender SYSTEM task is not deleted'
  Assert-True (-not ($blob.Contains('schtasks'))) 'installer shells out to task scheduler'
  Assert-True (-not ($blob.Contains('New-ScheduledTaskTrigger'))) 'Defender task has a trigger'
  Assert-True (-not ($blob.Contains('AtStartup'))) 'Defender task starts at boot'
  Assert-True (-not ($blob.Contains('AtLogOn'))) 'Defender task starts at logon'
  foreach ($file in $sources) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and @($parseErrors).Count -gt 0) { throw "parse error in $($file.Name): $($parseErrors[0].Message)" }
    $joinCommands = @($ast.FindAll({
      param($node)
      return ($node -is [System.Management.Automation.Language.CommandAst]) -and ($node.GetCommandName() -eq 'Join-Path')
    }, $true))
    foreach ($command in $joinCommands) {
      $positional = 0
      $elements = @($command.CommandElements)
      for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
          if ($element.Argument) { continue }
          $follows = $index + 1
          if ($follows -lt $elements.Count -and -not ($elements[$follows] -is [System.Management.Automation.Language.CommandParameterAst])) { $index = $follows }
          continue
        }
        $positional++
      }
      if ($positional -gt 2) { throw "Join-Path in $($file.Name) has $positional positional arguments" }
    }
  }
  Assert-True ($blob.Contains('-ElevatedRelaunch')) 'elevation relaunch has no re-entry guard'
  Assert-True ($blob.Contains('install-in-progress.lock')) 'supervisor install lock is missing'
  Assert-True ($entry.Contains('-SkipElevation:$VerifyOnly')) 'verify-only still relaunches for elevation'

  $guardRoot = Join-Path $temp 'guard-root'
  New-Item -ItemType Directory -Path $guardRoot | Out-Null
  $relaunches = @{ n = 0 }
  foreach ($ignored in 1..4) {
    if (-not (Test-SupervisorRelaunchBlocked $guardRoot)) { $relaunches.n++ }
  }
  Assert-True ($relaunches.n -eq 4) 'supervisor guard fired before a lock existed'
  Set-BrandInstallLock $guardRoot | Out-Null
  foreach ($ignored in 1..4) {
    if (-not (Test-SupervisorRelaunchBlocked $guardRoot)) { $relaunches.n++ }
  }
  Assert-True ($relaunches.n -eq 4) 'supervisor relaunched while install-in-progress.lock was held'
  $ownedNonce = [string]$script:BrandInstallLockNonce
  $refreshed = Set-BrandInstallLock $guardRoot
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$refreshed)) 'owned lock was not refreshed'
  Assert-True ([string]$script:BrandInstallLockNonce -ceq $ownedNonce) 'owned refresh minted a new nonce'
  $script:BrandInstallLockNonce = ('00' * 16)
  Remove-BrandInstallLock $guardRoot
  Assert-True (Test-SupervisorRelaunchBlocked $guardRoot) 'a mismatched nonce deleted the install lock'
  $script:BrandInstallLockNonce = $ownedNonce
  Remove-BrandInstallLock $guardRoot
  Assert-True (-not (Test-SupervisorRelaunchBlocked $guardRoot)) 'supervisor lock was not removed'

  $liveRoot = Join-Path $temp 'live-lock-root'
  New-Item -ItemType Directory -Path $liveRoot | Out-Null
  $sleeper = $null
  if (Test-Path -LiteralPath '/bin/sleep') {
    $sleeper = Start-Process -FilePath '/bin/sleep' -ArgumentList '60' -PassThru
  }
  Assert-True ($null -ne $sleeper) 'lock test could not start a live owner process'
  $liveStart = $sleeper.StartTime.ToUniversalTime().ToString('o')
  $liveRecord = [ordered]@{
    schema = 'diagnostic-workstation.install-lock/v1'
    ownerPid = $sleeper.Id
    ownerStartUtc = $liveStart
    nonce = ('ab' * 16)
    createdUtc = [datetimeoffset]::UtcNow.ToString('o')
  }
  $liveLockPath = Join-Path $liveRoot 'install-in-progress.lock'
  Write-Utf8NoBom $liveLockPath (($liveRecord | ConvertTo-Json -Compress) + "`n")
  $liveBefore = [System.IO.File]::ReadAllBytes($liveLockPath)
  $liveLogs = Join-Path $temp 'live-lock-logs'
  Assert-Throws { Set-BrandInstallLock -Root $liveRoot -LogDirectory $liveLogs } 'already holds install-in-progress.lock'
  $liveAfter = [System.IO.File]::ReadAllBytes($liveLockPath)
  Assert-True ((Get-BytesSha256 $liveBefore) -eq (Get-BytesSha256 $liveAfter)) 'a live lock was rewritten'
  $agedRoot = Join-Path $temp 'aged-live-lock-root'
  New-Item -ItemType Directory -Path $agedRoot | Out-Null
  $agedRecord = [ordered]@{
    schema = 'diagnostic-workstation.install-lock/v1'
    ownerPid = $sleeper.Id
    ownerStartUtc = $liveStart
    nonce = ('cd' * 16)
    createdUtc = '2020-01-01T00:00:00.0000000Z'
  }
  $agedLockPath = Join-Path $agedRoot 'install-in-progress.lock'
  Write-Utf8NoBom $agedLockPath (($agedRecord | ConvertTo-Json -Compress) + "`n")
  $agedBefore = [System.IO.File]::ReadAllBytes($agedLockPath)
  $agedLogs = Join-Path $temp 'aged-live-lock-logs'
  Assert-Throws { Set-BrandInstallLock -Root $agedRoot -LogDirectory $agedLogs } 'already holds install-in-progress.lock'
  $agedAfter = [System.IO.File]::ReadAllBytes($agedLockPath)
  Assert-True ((Get-BytesSha256 $agedBefore) -eq (Get-BytesSha256 $agedAfter)) 'a live lock older than 2 hours was reclaimed'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $agedLogs 'install-journal.log'))) 'a live lock older than 2 hours wrote a reclaim journal'
  $reusedRoot = Join-Path $temp 'reused-lock-root'
  New-Item -ItemType Directory -Path $reusedRoot | Out-Null
  $reusedRecord = [ordered]@{
    schema = 'diagnostic-workstation.install-lock/v1'
    ownerPid = $sleeper.Id
    ownerStartUtc = '2019-01-01T00:00:00.0000000Z'
    nonce = ('12' * 16)
    createdUtc = [datetimeoffset]::UtcNow.ToString('o')
  }
  Write-Utf8NoBom (Join-Path $reusedRoot 'install-in-progress.lock') (($reusedRecord | ConvertTo-Json -Compress) + "`n")
  $reusedLogs = Join-Path $temp 'reused-lock-logs'
  $reusedHeld = Set-BrandInstallLock -Root $reusedRoot -LogDirectory $reusedLogs
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$reusedHeld)) 'a reused PID lock was not reclaimed'
  $reusedJournal = [System.IO.File]::ReadAllText((Join-Path $reusedLogs 'install-journal.log'))
  Assert-True ($reusedJournal.Contains('"step":"install-lock-reclaimed"') -and $reusedJournal.Contains('"reason":"pid-reused"')) 'reused PID reclaim was not logged'
  $timeoutRoot = Join-Path $temp 'timeout-lock-root'
  New-Item -ItemType Directory -Path $timeoutRoot | Out-Null
  $timeoutRecord = [ordered]@{
    schema = 'diagnostic-workstation.install-lock/v1'
    createdUtc = '2020-01-01T00:00:00.0000000Z'
  }
  Write-Utf8NoBom (Join-Path $timeoutRoot 'install-in-progress.lock') (($timeoutRecord | ConvertTo-Json -Compress) + "`n")
  $timeoutLogs = Join-Path $temp 'timeout-lock-logs'
  $timeoutHeld = Set-BrandInstallLock -Root $timeoutRoot -LogDirectory $timeoutLogs
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$timeoutHeld)) 'a timed-out lock with no PID was not reclaimed'
  $timeoutJournal = [System.IO.File]::ReadAllText((Join-Path $timeoutLogs 'install-journal.log'))
  Assert-True ($timeoutJournal.Contains('"step":"install-lock-reclaimed"') -and $timeoutJournal.Contains('"reason":"timeout"')) 'timeout reclaim was not logged'
  $deadRoot = Join-Path $temp 'dead-lock-root'
  New-Item -ItemType Directory -Path $deadRoot | Out-Null
  $deadRecord = [ordered]@{
    schema = 'diagnostic-workstation.install-lock/v1'
    ownerPid = 2147483646
    ownerStartUtc = '2020-01-01T00:00:00.0000000Z'
    nonce = ('ef' * 16)
    createdUtc = [datetimeoffset]::UtcNow.ToString('o')
  }
  Write-Utf8NoBom (Join-Path $deadRoot 'install-in-progress.lock') (($deadRecord | ConvertTo-Json -Compress) + "`n")
  $deadLogs = Join-Path $temp 'dead-lock-logs'
  $deadHeld = Set-BrandInstallLock -Root $deadRoot -LogDirectory $deadLogs
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$deadHeld)) 'a dead-pid lock was not reclaimed'
  $deadJournal = [System.IO.File]::ReadAllText((Join-Path $deadLogs 'install-journal.log'))
  Assert-True ($deadJournal.Contains('"step":"install-lock-reclaimed"') -and $deadJournal.Contains('"reason":"dead-pid"')) 'dead-pid reclaim was not logged'
  $blankRoot = Join-Path $temp 'blank-start-lock-root'
  New-Item -ItemType Directory -Path $blankRoot | Out-Null
  $blankRecord = [ordered]@{
    schema = 'diagnostic-workstation.install-lock/v1'
    ownerPid = $sleeper.Id
    ownerStartUtc = ''
    nonce = ('34' * 16)
    createdUtc = [datetimeoffset]::UtcNow.ToString('o')
  }
  $blankLockPath = Join-Path $blankRoot 'install-in-progress.lock'
  Write-Utf8NoBom $blankLockPath (($blankRecord | ConvertTo-Json -Compress) + "`n")
  $blankBefore = [System.IO.File]::ReadAllBytes($blankLockPath)
  $blankLogs = Join-Path $temp 'blank-start-lock-logs'
  Assert-Throws { Set-BrandInstallLock -Root $blankRoot -LogDirectory $blankLogs } 'already holds install-in-progress.lock'
  $blankAfter = [System.IO.File]::ReadAllBytes($blankLockPath)
  Assert-True ((Get-BytesSha256 $blankBefore) -eq (Get-BytesSha256 $blankAfter)) 'a live lock with a blank owner start was reclaimed'
  $blankOldRoot = Join-Path $temp 'blank-start-old-lock-root'
  New-Item -ItemType Directory -Path $blankOldRoot | Out-Null
  $blankOldRecord = [ordered]@{
    schema = 'diagnostic-workstation.install-lock/v1'
    ownerPid = $sleeper.Id
    ownerStartUtc = ''
    nonce = ('56' * 16)
    createdUtc = '2020-01-01T00:00:00.0000000Z'
  }
  Write-Utf8NoBom (Join-Path $blankOldRoot 'install-in-progress.lock') (($blankOldRecord | ConvertTo-Json -Compress) + "`n")
  $blankOldLogs = Join-Path $temp 'blank-start-old-lock-logs'
  $blankOldHeld = Set-BrandInstallLock -Root $blankOldRoot -LogDirectory $blankOldLogs
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$blankOldHeld)) 'an old lock with a blank owner start was not reclaimed'
  $blankOldJournal = [System.IO.File]::ReadAllText((Join-Path $blankOldLogs 'install-journal.log'))
  Assert-True ($blankOldJournal.Contains('"step":"install-lock-reclaimed"') -and $blankOldJournal.Contains('"reason":"timeout"')) 'blank owner start did not fall back to age'
  if ($sleeper -and -not $sleeper.HasExited) { Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue }

  $failWriteRoot = Join-Path $temp 'fail-write-lock-root'
  New-Item -ItemType Directory -Path $failWriteRoot | Out-Null
  $failWritePath = Join-Path $failWriteRoot 'install-in-progress.lock'
  $script:BrandInstallLockFailWrite = $true
  Assert-Throws { New-BrandInstallLockFile $failWritePath ('aa' * 16) } 'lock write failed'
  $script:BrandInstallLockFailWrite = $false
  Assert-True (-not (Test-Path -LiteralPath $failWritePath)) 'a failed lock write left an empty lock'
  $failWriteHeld = Set-BrandInstallLock $failWriteRoot
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$failWriteHeld)) 'install stayed blocked after a failed lock write'
  Remove-BrandInstallLock $failWriteRoot

  $restoreRoot = Join-Path $temp 'restore-lock-root'
  New-Item -ItemType Directory -Path $restoreRoot | Out-Null
  $restoreLock = Join-Path $restoreRoot 'install-in-progress.lock'
  $restoreClaim = $restoreLock + '.reclaim-empty'
  Write-Utf8NoBom $restoreClaim "claim-bytes`n"
  [System.IO.File]::WriteAllBytes($restoreLock, (New-Object byte[] 0))
  Restore-MovedLock $restoreClaim $restoreLock
  Assert-True (([System.IO.File]::ReadAllText($restoreLock)) -eq "claim-bytes`n") 'an empty lock blocked restore of the moved bytes'
  Assert-True (-not (Test-Path -LiteralPath $restoreClaim)) 'the claim remained after restore onto an empty lock'
  $keptClaim = $restoreLock + '.reclaim-kept'
  Write-Utf8NoBom $restoreLock 'winner-bytes'
  Write-Utf8NoBom $keptClaim 'stolen-bytes'
  Restore-MovedLock $keptClaim $restoreLock
  Assert-True (([System.IO.File]::ReadAllText($restoreLock)) -eq 'winner-bytes') 'restore replaced a non-empty lock'
  Assert-True (([System.IO.File]::ReadAllText($keptClaim)) -eq 'stolen-bytes') 'a blocked restore deleted the claim'

  $sweepRoot = Join-Path $temp 'sweep-lock-root'
  New-Item -ItemType Directory -Path $sweepRoot | Out-Null
  $sweepLock = Join-Path $sweepRoot 'install-in-progress.lock'
  $staleClaim = $sweepLock + '.reclaim-stale'
  $staleRefresh = $sweepLock + '.refresh-stale'
  $staleBak = $sweepLock + '.refresh-bak'
  $freshRelease = $sweepLock + '.release-fresh'
  Write-Utf8NoBom $staleClaim 'stale'
  Write-Utf8NoBom $staleRefresh 'stale-refresh'
  Write-Utf8NoBom $staleBak 'bak'
  Write-Utf8NoBom $freshRelease 'fresh'
  $staleStamp = [datetime]::UtcNow.AddHours(-3)
  (Get-Item -LiteralPath $staleClaim).LastWriteTimeUtc = $staleStamp
  (Get-Item -LiteralPath $staleRefresh).LastWriteTimeUtc = $staleStamp
  (Get-Item -LiteralPath $staleBak).LastWriteTimeUtc = $staleStamp
  $sweepHeld = Set-BrandInstallLock $sweepRoot
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$sweepHeld)) 'sidecar sweep blocked a new lock'
  Assert-True (-not (Test-Path -LiteralPath $staleClaim)) 'a stale reclaim file was left behind'
  Assert-True (-not (Test-Path -LiteralPath $staleRefresh)) 'a stale refresh file was left behind'
  Assert-True (-not (Test-Path -LiteralPath $staleBak)) 'a stale refresh backup was left behind'
  Assert-True (Test-Path -LiteralPath $freshRelease) 'a fresh release file was deleted'
  Remove-BrandInstallLock $sweepRoot

  $supervisorRoot = Join-Path $temp 'supervisor-root'
  $stoppedIds = New-Object System.Collections.Generic.List[int]
  $fakeProcesses = @(
    [pscustomobject]@{ ProcessId = 501; CommandLine = "powershell.exe -File `"$supervisorRoot\Launcher.ps1`"" }
    [pscustomobject]@{ ProcessId = $PID; CommandLine = "powershell.exe -File `"$supervisorRoot\Launcher.ps1`"" }
    [pscustomobject]@{ ProcessId = 502; CommandLine = "powershell.exe -WindowStyle Hidden -File `"$supervisorRoot\Watchdog.ps1`"" }
    [pscustomobject]@{ ProcessId = 503; CommandLine = "powershell.exe -File `"$supervisorRoot\Install-Master.ps1`" -Brand mercedes" }
    [pscustomobject]@{ ProcessId = 504; CommandLine = "powershell.exe -File `"$supervisorRoot\Enable-Security.ps1`" -Brand mercedes" }
    [pscustomobject]@{ ProcessId = 505; CommandLine = "`"$supervisorRoot\WorkstationManager.exe`" /supervise" }
    [pscustomobject]@{ ProcessId = 506; CommandLine = 'powershell.exe -File C:\OtherBrand\Launcher.ps1' }
  )
  $stopped = @(Stop-BrandSupervisorProcesses -Root $supervisorRoot -ProcessQuery { $fakeProcesses } -ProcessStop { param($Id) $stoppedIds.Add([int]$Id) })
  Assert-True (($stoppedIds -join ',') -eq '501,502') 'supervisor stop selected the wrong processes'
  Assert-True (($stopped -join ',') -eq '501,502') 'supervisor stop did not report the stopped ids'

  $elevationCalls = New-Object System.Collections.Generic.List[object]
  $elevationStarter = {
    param($Launch)
    $elevationCalls.Add($Launch)
    Assert-True ($Launch.verb -eq 'RunAs') 'elevation did not request RunAs'
    Assert-True ($Launch.windowStyle -eq 'Hidden') 'elevation relaunch is visible'
    Assert-True ($Launch.wait) 'elevation relaunch was not awaited'
    $joined = @($Launch.arguments) -join ' '
    Assert-True ($joined.Contains('-WindowStyle Hidden')) 'elevation command opens a window'
    Assert-True ($joined.Contains('-ElevatedRelaunch')) 'elevation command can relaunch again'
    Assert-True ($joined.Contains('-Brand mercedes')) 'elevation command dropped the brand'
    return 0
  }
  $continued = Invoke-MasterElevatedOnce -ScriptPath 'C:\installer\Install-Master.ps1' -ArgumentList @('-Brand', 'mercedes') -AdminTest { $true } -Starter $elevationStarter
  Assert-True ($continued.action -eq 'continue' -and $elevationCalls.Count -eq 0) 'already-elevated install relaunched'
  $relaunched = Invoke-MasterElevatedOnce -ScriptPath 'C:\installer\Install-Master.ps1' -ArgumentList @('-Brand', 'mercedes') -AdminTest { $false } -Starter $elevationStarter
  Assert-True ($relaunched.action -eq 'relaunched' -and $elevationCalls.Count -eq 1) 'non-elevated install did not relaunch once'
  Assert-Throws {
    Invoke-MasterElevatedOnce -ScriptPath 'C:\installer\Install-Master.ps1' -ArgumentList @('-Brand', 'mercedes') -AlreadyRelaunched -AdminTest { $false } -Starter $elevationStarter
  } 'already relaunched'
  Assert-True ($elevationCalls.Count -eq 1) 'elevation guard opened a second window'

  $mercedesRoot = Resolve-BrandInstallRoot 'mercedes' (Join-Path $temp 'local-mercedes')
  $bmwRoot = Resolve-BrandInstallRoot 'bmw' (Join-Path $temp 'local-bmw')
  Assert-True ((Split-Path -Leaf $mercedesRoot) -eq 'DiagnosticWorkstation') 'Mercedes root changed'
  Assert-True ((Split-Path -Leaf $bmwRoot) -eq 'BMW-Stealth-Launcher') 'BMW root changed'
  Assert-Throws { Get-BrandAllowEntry 'ford' } 'not approved'
  Assert-True ((Get-BrandAllowEntry 'mercedes').Supervisor -ceq 'WorkstationManager.exe') 'Mercedes supervisor changed'
  Assert-True ((Get-BrandAllowEntry 'bmw').Supervisor -ceq 'Watchdog.ps1') 'BMW supervisor is not Watchdog.ps1'
  Assert-Throws { Assert-BrandTag 'mercedes' 'universal-v1.0.0' } 'universal-v tags are retired'
  Assert-Throws { Assert-BrandTag 'bmw' 'v1.0.1-beta.5' } 'bare v tags are retired'
  Assert-BrandTag 'mercedes' 'mercedes-v0.1.3-beta.2'

  $goodUrl = 'https://github.com/wilesy7404/diagnostic-workstation/releases/download/mercedes-v0.1.3-beta.2/workstation.zip'
  Assert-GithubReleaseUrl $goodUrl 'wilesy7404/diagnostic-workstation' 'mercedes-v0.1.3-beta.2' 'workstation.zip'
  Assert-Throws { Assert-GithubReleaseUrl 'https://example.com/workstation.zip' 'wilesy7404/diagnostic-workstation' 'mercedes-v0.1.3-beta.2' 'workstation.zip' } 'Unexpected download URL'
  Assert-Throws { Get-ApprovedAssetUrl 'mercedes' 'mercedes-v0.1.3-beta.2' 'payload.exe' } 'Unexpected download URL'

  $pin = Get-PinToken (Join-Path $repo 'catalog/catalog.sha256')
  $catalogHash = Get-Sha256Hex (Join-Path $repo 'catalog/catalog.json')
  Assert-True ($pin -ceq 'c514717b22c24b68c2a445e08f02131e1f9fd62d600bcf292f88f8a4e1597aba') 'catalog.sha256 token changed'
  Assert-True ($pin -eq $catalogHash) 'catalog pin does not match catalog.json'
  $catalogBytes = [System.IO.File]::ReadAllBytes((Join-Path $repo 'catalog/catalog.json'))
  $catalogText = [System.Text.Encoding]::UTF8.GetString($catalogBytes)
  Assert-True ($catalogText -notmatch "`r") 'catalog.json contains CR'
  $crlfBytes = [System.Text.Encoding]::UTF8.GetBytes(($catalogText -replace "(?<!\r)`n", "`r`n"))
  Assert-True ((Get-BytesSha256 $crlfBytes) -ne $pin) 'CRLF catalog.json must not satisfy the pin'
  $attrText = (& git -C $repo check-attr text -- catalog/catalog.json catalog/catalog.sha256 catalog/catalog.json.release.sig releases/versions.lock.json tools/security/wub/tool-manifest.json tools/security/wub/Wub_x64.exe offline/mercedes-v0.1.3-beta.4/workstation.zip 2>&1 | Out-String)
  foreach ($attrPath in @('catalog/catalog.json', 'catalog/catalog.sha256', 'catalog/catalog.json.release.sig', 'releases/versions.lock.json', 'tools/security/wub/tool-manifest.json', 'tools/security/wub/Wub_x64.exe', 'offline/mercedes-v0.1.3-beta.4/workstation.zip')) {
    Assert-True ($attrText -match [regex]::Escape("${attrPath}: text: unset")) "$attrPath is not byte-exact"
  }
  $harnessText = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts/Invoke-VmInstallTest.ps1'))
  Assert-True ($harnessText -notmatch '@\(\$script:Results\)') 'VM report still wraps the results list in @()'
  Assert-True ($harnessText -match 'function Write-VmInstallReport') 'VM report is not written from a finally path'
  Assert-True ($harnessText -match 'finally \{') 'VM harness does not keep the report writer in finally'
  Assert-True ($harnessText -match 'Refusing to install an older approved version') 'downgrade check does not require the downgrade refusal'
  Assert-True ($harnessText -match '\$expected = ''No approved''') 'unpinned check does not name its expected rejection'
  Assert-True ($harnessText -match '\$expected = ''belongs to''') 'wrong-brand check does not name its expected rejection'
  Assert-True ($harnessText -match 'expected ''hash mismatch''') 'tamper check does not name its expected rejection'
  Assert-True ($harnessText -match 'PASS with gaps \(\$notRunCount NOT RUN, \$unprovenCount NOT PROVEN\)') 'VM report headline does not name gaps'
  Assert-True ($harnessText -match 'already holds install-in-progress.lock') 'live lock check does not name its refusal'
  Assert-True ($harnessText -match 'install-lock-reclaimed') 'stale lock check does not require the reclaim journal'
  Assert-True ($harnessText -match 'fail-swap.marker') 'in-install failure check does not arm the harness marker'
  Assert-True ($harnessText -match '-AllowHarnessFailSwap') 'in-install failure check does not pass the harness switch'
  Assert-True ($harnessText -match 'Harness SHA:') 'VM report does not record the harness SHA'
  Assert-True ($harnessText -match 'Catalog SHA:') 'VM report does not record the catalog SHA'
  Assert-True ($harnessText -match 'previous folder was restored') 'in-install failure check does not require the restored tree'
  . (Join-Path $repo 'scripts/VmInstallVerdict.ps1')
  $emptyPlan = [pscustomobject]@{ Policies = @([pscustomobject]@{ Name = 'DisableAntiVirus' }) }
  $absentVerdict = Get-DisableAntiSpywarePolicyVerdict $emptyPlan @()
  Assert-True ($absentVerdict.Status -eq 'PASS') 'absent DisableAntiSpyware was not a pass'
  $planFixture = [pscustomobject]@{ Policies = @([pscustomobject]@{ Name = 'DisableAntiSpyware'; Value = 1 }) }
  $planVerdict = Get-DisableAntiSpywarePolicyVerdict $planFixture @()
  Assert-True ($planVerdict.Status -eq 'FAIL') 'a plan DisableAntiSpyware row was a pass'
  $journalOne = @([pscustomobject]@{ step = 'defender-post'; commands = @([pscustomobject]@{ kind = 'Set-Policy'; name = 'DisableAntiSpyware'; value = 1 }) })
  $journalZero = @([pscustomobject]@{ step = 'defender-post'; commands = @([pscustomobject]@{ kind = 'Set-Policy'; name = 'DisableAntiSpyware'; value = 0 }) })
  Assert-True ((Get-DisableAntiSpywarePolicyVerdict $emptyPlan $journalOne).Status -eq 'FAIL') 'journal DisableAntiSpyware value 1 was a pass'
  Assert-True ((Get-DisableAntiSpywarePolicyVerdict $emptyPlan $journalZero).Status -eq 'FAIL') 'journal DisableAntiSpyware value 0 was a pass'
  $removeOnly = @([pscustomobject]@{ step = 'defender-post'; commands = @([pscustomobject]@{ kind = 'Remove-Policy'; name = 'DisableAntiSpyware' }) })
  Assert-True ((Get-DisableAntiSpywarePolicyVerdict $emptyPlan $removeOnly).Status -eq 'PASS') 'a Remove-Policy cleanup was treated as a Set-Policy'
  $otherStep = @([pscustomobject]@{ step = 'defender-failed'; commands = @([pscustomobject]@{ kind = 'Set-Policy'; name = 'DisableAntiSpyware'; value = 1 }) })
  Assert-True ((Get-DisableAntiSpywarePolicyVerdict $emptyPlan $otherStep).Status -eq 'PASS') 'a non-post Set-Policy was counted'
  Assert-True ((Get-CombinedStatus @([pscustomobject]@{ Status = 'PASS' }, [pscustomobject]@{ Status = 'NOT RUN' })) -eq 'NOT RUN') 'NOT RUN did not beat PASS'
  Assert-True ((Get-CombinedStatus @([pscustomobject]@{ Status = 'NOT RUN' }, [pscustomobject]@{ Status = 'FAIL' })) -eq 'FAIL') 'FAIL did not beat NOT RUN'
  Assert-True ((Get-CombinedStatus @([pscustomobject]@{ Status = 'NOT PROVEN' }, [pscustomobject]@{ Status = 'NOT RUN' })) -eq 'NOT PROVEN') 'NOT PROVEN did not beat NOT RUN'
  Assert-True ($entry.Contains('Restart required.')) 'install does not say restart required'
  $loadedCatalog = Read-ApprovedCatalog (Join-Path $repo 'catalog/catalog.json') (Join-Path $repo 'catalog/catalog.sha256') (Join-Path $repo 'keys') (Join-Path $repo 'catalog/catalog.json.release.sig')
  Assert-True ([int]$loadedCatalog.Catalog.catalogSerial -eq 3) 'catalog serial'
  Assert-True ([string]$loadedCatalog.Catalog.signatureStatus -eq 'placeholder-untrusted') 'catalog signature status'
  $mercedesBrand = Get-CatalogBrand $loadedCatalog.Catalog 'mercedes'
  $bmwBrand = Get-CatalogBrand $loadedCatalog.Catalog 'bmw'
  $mercedesReleases = @(Get-CatalogReleaseList $mercedesBrand)
  Assert-True ($mercedesReleases.Count -eq 1) 'mercedes catalog must pin beta.4 only'
  $mercedesPin = Select-ApprovedRelease $mercedesBrand 'mercedes' 'beta'
  Assert-True ([string]$mercedesPin.tag -eq 'mercedes-v0.1.3-beta.4' -and [string]$mercedesPin.version -eq '0.1.3-beta.4' -and [string]$mercedesPin.channel -eq 'beta') 'mercedes pin identity'
  Assert-True ([string]$mercedesPin.sha256 -eq 'ac8a82c0052cd1718cc050c5e28418efe5ed7afea104baaeb0940fcc612f661a' -and [int64]$mercedesPin.bytes -eq 1321743) 'mercedes zip pin'
  Assert-True ([string]$mercedesPin.manifestSha256 -eq '8c5d857933654bcbfa5bc84140c513d2c3d83863e2e3c0cf956c7471891abdc9' -and [int64]$mercedesPin.manifestBytes -eq 3338) 'mercedes manifest pin'
  Assert-True ([string]$mercedesPin.asset -eq 'workstation.zip' -and [string]$mercedesPin.manifestAsset -eq 'update-manifest.json') 'mercedes asset names'
  Assert-True ([string]$mercedesBrand.supervisor.note -notmatch 'Single supervisor for every brand') 'mercedes supervisor note still says it covers every brand'
  Assert-Throws { Select-ApprovedRelease ([pscustomobject]@{ releases = $null }) 'mercedes' 'beta' } 'No approved mercedes release is pinned'
  Assert-Throws { Select-ApprovedRelease ([pscustomobject]@{ releases = @() }) 'mercedes' 'beta' } 'No approved mercedes release is pinned'
  $bmwPin = Select-ApprovedRelease $bmwBrand 'bmw' 'beta'
  Assert-True ([string]$bmwPin.tag -eq 'bmw-v1.0.2-beta.1' -and [string]$bmwPin.version -eq '1.0.2-beta.1' -and [string]$bmwPin.channel -eq 'beta') 'bmw pin identity'
  Assert-True ([string]$bmwPin.sha256 -eq '77bf2e85b4192d0485d79e82a256a68494b673c99c67eb81f62f194e94c69978' -and [int64]$bmwPin.bytes -eq 48955) 'bmw zip pin'
  Assert-True ([string]$bmwPin.manifestSha256 -eq '82075f0f9751191eb3547fba2e05868ef656b6f567c5eeede5b62cd4c90d1136' -and [int64]$bmwPin.manifestBytes -eq 2554) 'bmw manifest pin'
  Assert-True ([string]$bmwPin.asset -eq 'workstation.zip' -and [string]$bmwPin.manifestAsset -eq 'update-manifest.json') 'bmw asset names'
  $pinnedTags = @(@($mercedesBrand.releases) + @($bmwBrand.releases) | ForEach-Object { [string]$_.tag })
  Assert-True ($pinnedTags -notcontains 'mercedes-v0.1.3-beta.1') 'beta.1 must stay unpinned'
  Assert-True ($pinnedTags -notcontains 'mercedes-v0.1.3-beta.2') 'beta.2 must stay unpinned'
  Assert-True ($pinnedTags -notcontains 'mercedes-v0.1.3-beta.3') 'voided beta.3 must stay unpinned'
  $unusedRoot = Join-Path $temp 'unused-root'
  Assert-Throws {
    Install-ApprovedBrand -Brand 'mercedes' -AllowTestRoot -InstallRoot $unusedRoot -InstallerData (Join-Path $temp 'unused-data') -LogDirectory (Join-Path $temp 'unused-logs') -RepoRoot $repo -AllowUncheckedProcesses -OfflineOnly
  } 'No offline payload was found'
  Assert-True (-not (Test-Path -LiteralPath $unusedRoot)) 'pinned mercedes catalog created an install root without a payload'

  $launcher = [System.Text.Encoding]::UTF8.GetBytes("Write-Output 'approved-launcher'`r`n")
  $version = [System.Text.Encoding]::UTF8.GetBytes('{"version":"1.2.3-beta.1"}')
  $files = @{ 'Launcher.ps1' = $launcher; 'version.json' = $version }
  $zipPath = Join-Path $temp 'workstation.zip'
  New-FixtureZip $zipPath $files
  $zipHash = Get-Sha256Hex $zipPath
  $zipBytes = (Get-Item $zipPath).Length
  $manifestObject = [ordered]@{
    schemaVersion = 1
    brand = 'mercedes'
    channel = 'beta'
    version = '1.2.3-beta.1'
    tag = 'mercedes-v1.2.3-beta.1'
    asset = 'workstation.zip'
    sha256 = $zipHash
    bytes = $zipBytes
    files = @(
      [ordered]@{ path = 'Launcher.ps1'; sha256 = (Get-BytesSha256 $launcher); bytes = $launcher.Length },
      [ordered]@{ path = 'version.json'; sha256 = (Get-BytesSha256 $version); bytes = $version.Length }
    )
  }
  $manifestPath = Join-Path $temp 'update-manifest.json'
  Write-Utf8NoBom $manifestPath (($manifestObject | ConvertTo-Json -Depth 6) + "`n")
  $manifestHash = Get-Sha256Hex $manifestPath
  $manifestBytes = (Get-Item $manifestPath).Length

  $fixture = Join-Path $temp 'fixture-repo'
  New-Item -ItemType Directory -Force -Path (Join-Path $fixture 'catalog'), (Join-Path $fixture 'keys'), (Join-Path $fixture 'brands/mercedes'), (Join-Path $fixture 'brands/bmw'), (Join-Path $fixture 'offline/mercedes-v1.2.3-beta.1') | Out-Null
  Copy-Item (Join-Path $repo 'keys/qa.pub') (Join-Path $fixture 'keys/qa.pub')
  Copy-Item (Join-Path $repo 'keys/release.pub') (Join-Path $fixture 'keys/release.pub')
  Copy-Item (Join-Path $repo 'catalog/catalog.json.release.sig') (Join-Path $fixture 'catalog/catalog.json.release.sig')
  Copy-Item -Path (Join-Path $repo 'tools') -Destination (Join-Path $fixture 'tools') -Recurse
  Copy-Item -Path (Join-Path $repo 'installer') -Destination (Join-Path $fixture 'installer') -Recurse
  foreach ($brand in @('mercedes', 'bmw')) {
    Copy-Item (Join-Path $repo "brands/$brand/release.json") (Join-Path $fixture "brands/$brand/release.json")
  }
  Copy-Item $zipPath (Join-Path $fixture 'offline/mercedes-v1.2.3-beta.1/workstation.zip')
  Copy-Item $manifestPath (Join-Path $fixture 'offline/mercedes-v1.2.3-beta.1/update-manifest.json')
  $catalogObject = [ordered]@{
    schema = 'diagnostic-workstation.catalog/v1'
    catalogSerial = 1
    issuedUtc = '2020-01-01T00:00:00Z'
    expiresUtc = '2020-02-01T00:00:00Z'
    signatureStatus = 'placeholder-untrusted'
    repo = 'wilesy7404/diagnostic-workstation'
    retiredTagPrefixes = @('universal-v', 'v')
    brands = @(
      [ordered]@{
        id = 'mercedes'
        tagPrefix = 'mercedes-v'
        install = [ordered]@{ root = 'DiagnosticWorkstation'; rootBase = 'LOCALAPPDATA' }
        releases = @(
          [ordered]@{
            tag = 'mercedes-v1.2.3-beta.1'
            version = '1.2.3-beta.1'
            channel = 'beta'
            sha256 = $zipHash
            bytes = $zipBytes
            manifestSha256 = $manifestHash
            manifestBytes = $manifestBytes
            asset = 'workstation.zip'
            manifestAsset = 'update-manifest.json'
          }
        )
      },
      [ordered]@{
        id = 'bmw'
        tagPrefix = 'bmw-v'
        install = [ordered]@{ root = 'BMW-Stealth-Launcher'; rootBase = 'LOCALAPPDATA' }
        releases = @()
      }
    )
  }
  $catalogFile = Join-Path $fixture 'catalog/catalog.json'
  Write-Utf8NoBom $catalogFile (($catalogObject | ConvertTo-Json -Depth 8) + "`n")
  $fixturePin = Get-Sha256Hex $catalogFile
  Write-Utf8NoBom (Join-Path $fixture 'catalog/catalog.sha256') ($fixturePin + "  catalog.json`n")
  $emptyBmwRoot = Join-Path $temp 'empty-bmw-root'
  Assert-Throws {
    Install-ApprovedBrand -Brand 'bmw' -AllowTestRoot -InstallRoot $emptyBmwRoot -InstallerData (Join-Path $temp 'empty-bmw-data') -LogDirectory (Join-Path $temp 'empty-bmw-logs') -RepoRoot $fixture -AllowUncheckedProcesses -OfflineOnly
  } 'No approved bmw release is pinned'
  Assert-True (-not (Test-Path -LiteralPath $emptyBmwRoot)) 'empty bmw catalog created an install root'

  $savedLock = ${function:Set-BrandInstallLock}
  $savedStop = ${function:Stop-BrandSupervisorProcesses}
  $script:TargetGuardCalls = New-Object System.Collections.Generic.List[string]
  ${function:Set-BrandInstallLock} = { param($Root) $script:TargetGuardCalls.Add('lock') | Out-Null; return $null }
  ${function:Stop-BrandSupervisorProcesses} = { param($Root, $ProcessQuery, $ProcessStop) $script:TargetGuardCalls.Add('stop') | Out-Null; return @() }
  try {
    Assert-True ((${function:Set-BrandInstallLock}.ToString()) -match 'TargetGuardCalls') 'lock override was not installed'
    $foreignApproved = Join-Path $temp 'foreign-approved'
    New-Item -ItemType Directory -Path $foreignApproved | Out-Null
    Write-Utf8NoBom (Join-Path $foreignApproved '.installed-bundle.json') '{"brand":"bmw","version":"1.0.0"}'
    Write-Utf8NoBom (Join-Path $foreignApproved 'Launcher.ps1') "Write-Output 'foreign-live'`n"
    $foreignLock = [System.Text.Encoding]::UTF8.GetBytes("other-run lock`n")
    [System.IO.File]::WriteAllBytes((Join-Path $foreignApproved 'install-in-progress.lock'), $foreignLock)
    Assert-Throws {
      Install-ApprovedBrand -Brand 'mercedes' -AllowTestRoot -InstallRoot $foreignApproved -InstallerData (Join-Path $temp 'foreign-approved-data') -LogDirectory (Join-Path $temp 'foreign-approved-logs') -RepoRoot $fixture -OfflineOnly
    } 'belongs to bmw'
    Assert-True ($script:TargetGuardCalls.Count -eq 0) ("wrong target reached {0}" -f ($script:TargetGuardCalls -join ','))
    $foreignLockAfter = [System.IO.File]::ReadAllBytes((Join-Path $foreignApproved 'install-in-progress.lock'))
    Assert-True ((Get-BytesSha256 $foreignLock) -eq (Get-BytesSha256 $foreignLockAfter) -and $foreignLock.Length -eq $foreignLockAfter.Length) 'wrong target changed a pre-existing lock'
    Assert-True (([System.IO.File]::ReadAllText((Join-Path $foreignApproved 'Launcher.ps1'))) -match 'foreign-live') 'wrong target changed the foreign tree'
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $foreignApproved) -Force | Where-Object { $_.Name -like '.staging-*' }).Count -eq 0) 'wrong target left a staging directory'
    $foreignJournal = Join-Path $temp 'foreign-approved-logs/install-journal.log'
    if (Test-Path -LiteralPath $foreignJournal) {
      $foreignJournalText = [System.IO.File]::ReadAllText($foreignJournal)
      Assert-True ($foreignJournalText -notmatch 'payload-acquired') 'wrong target extracted a payload'
    }
    $downgradeApproved = Join-Path $temp 'downgrade-approved'
    New-Item -ItemType Directory -Path $downgradeApproved | Out-Null
    Write-Utf8NoBom (Join-Path $downgradeApproved '.installed-bundle.json') '{"brand":"mercedes","version":"9.0.0"}'
    Write-Utf8NoBom (Join-Path $downgradeApproved 'Launcher.ps1') "Write-Output 'newer-live'`n"
    $downgradeLock = [System.Text.Encoding]::UTF8.GetBytes("other-run lock`n")
    [System.IO.File]::WriteAllBytes((Join-Path $downgradeApproved 'install-in-progress.lock'), $downgradeLock)
    $script:TargetGuardCalls.Clear()
    Assert-Throws {
      Install-ApprovedBrand -Brand 'mercedes' -AllowTestRoot -InstallRoot $downgradeApproved -InstallerData (Join-Path $temp 'downgrade-approved-data') -LogDirectory (Join-Path $temp 'downgrade-approved-logs') -RepoRoot $fixture -OfflineOnly
    } 'older approved version'
    Assert-True ($script:TargetGuardCalls.Count -eq 0) ("downgrade reached {0}" -f ($script:TargetGuardCalls -join ','))
    $downgradeLockAfter = [System.IO.File]::ReadAllBytes((Join-Path $downgradeApproved 'install-in-progress.lock'))
    Assert-True ((Get-BytesSha256 $downgradeLock) -eq (Get-BytesSha256 $downgradeLockAfter) -and $downgradeLock.Length -eq $downgradeLockAfter.Length) 'downgrade changed a pre-existing lock'
    Assert-True (([System.IO.File]::ReadAllText((Join-Path $downgradeApproved 'Launcher.ps1'))) -match 'newer-live') 'downgrade changed the installed tree'
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $downgradeApproved) -Force | Where-Object { $_.Name -like '.staging-*' }).Count -eq 0) 'downgrade left a staging directory'
    $downgradeJournal = Join-Path $temp 'downgrade-approved-logs/install-journal.log'
    if (Test-Path -LiteralPath $downgradeJournal) {
      $downgradeJournalText = [System.IO.File]::ReadAllText($downgradeJournal)
      Assert-True ($downgradeJournalText -notmatch 'payload-acquired') 'downgrade extracted a payload'
    }
  } finally {
    ${function:Set-BrandInstallLock} = $savedLock
    ${function:Stop-BrandSupervisorProcesses} = $savedStop
  }

  $global:MasterTestCalls = New-Object System.Collections.Generic.List[object]
  $global:MasterStateReads = 0
  $runner = {
    param($Exe, $ArgumentList)
    $joined = @($ArgumentList) -join ' '
    $global:MasterTestCalls.Add([pscustomobject]@{ exe = [string]$Exe; arguments = $joined })
    if ((Split-Path -Leaf ([string]$Exe)) -eq 'dControl.exe') { throw 'dControl was started' }
    if ($global:MasterRequireInstallLock -and -not (Test-SupervisorRelaunchBlocked $installRoot)) {
      throw 'Windows Update ran without the supervisor lock'
    }
    return 0
  }
  $stateReader = {
    $global:MasterStateReads++
    if ($global:MasterStateReads -eq 1) { return @{ name = 'wuauserv'; status = 'Running'; startMode = 'Auto' } }
    return @{ name = 'wuauserv'; status = 'Stopped'; startMode = 'Disabled' }
  }
  $global:MasterPromptRan = $false
  $prompt = { param($Message) $global:MasterPromptRan = $true; return $true }
  function New-TestDefenderState([string]$Tamper) {
    return [pscustomobject]@{
      tamper = $Tamper
      preferences = @{
        DisableRealtimeMonitoring = $false
        DisableBehaviorMonitoring = $false
        DisableIOAVProtection = $false
        DisableScriptScanning = $false
      }
      policies = @()
      services = @(
        [pscustomobject]@{ name = 'WinDefend'; present = $true; status = 'Running'; startMode = 'Automatic' }
        [pscustomobject]@{ name = 'WdNisSvc'; present = $true; status = 'Running'; startMode = 'Auto' }
        [pscustomobject]@{ name = 'MDCoreSvc'; present = $false; status = 'absent'; startMode = '' }
      )
    }
  }
  $global:MasterDefenderCommands = New-Object System.Collections.Generic.List[object]
  $defenderReader = { New-TestDefenderState 'off' }
  $global:MasterRequireInstallLock = $false
  $defenderSink = {
    param($Command)
    if ($global:MasterRequireInstallLock -and -not (Test-SupervisorRelaunchBlocked $installRoot)) {
      throw 'Defender ran without the supervisor lock'
    }
    $global:MasterDefenderCommands.Add($Command)
  }

  $installRoot = Join-Path $temp 'DiagnosticWorkstation'
  New-Item -ItemType Directory -Path $installRoot | Out-Null
  Write-Utf8NoBom (Join-Path $installRoot 'apps.json') '{"apps":["SECRET-APPS"]}'
  Write-Utf8NoBom (Join-Path $installRoot 'controls-pin.json') '{"pin":"SECRET-PIN"}'
  Write-Utf8NoBom (Join-Path $installRoot 'Launcher.ps1') "Write-Output 'old-launcher'`r`n"
  Write-Utf8NoBom (Join-Path $installRoot 'notes.txt') 'USER-NOTE'
  New-Item -ItemType Directory -Path (Join-Path $installRoot 'logs') | Out-Null
  Write-Utf8NoBom (Join-Path $installRoot 'logs/session.log') 'keep-log'
  $data = Join-Path $temp 'installer-data'
  $logs = Join-Path $data 'logs'
  $expectedZipUrl = 'https://github.com/wilesy7404/diagnostic-workstation/releases/download/mercedes-v1.2.3-beta.1/workstation.zip'
  $seenUrls = New-Object System.Collections.Generic.List[string]
  $downloader = {
    param($Url, $Destination)
    $seenUrls.Add([string]$Url)
    if ($Url -eq $expectedZipUrl) { Copy-Item $zipPath $Destination -Force; return }
    if ($Url -eq 'https://github.com/wilesy7404/diagnostic-workstation/releases/download/mercedes-v1.2.3-beta.1/update-manifest.json') {
      Copy-Item $manifestPath $Destination -Force
      return
    }
    throw "Unexpected download URL $Url"
  }
  $global:MasterRequireInstallLock = $true
  $result = Install-ApprovedBrand -Brand 'mercedes' -Channel 'beta' -AllowTestRoot -InstallRoot $installRoot -InstallerData $data -LogDirectory $logs -RepoRoot $fixture -AllowUncheckedProcesses -ApplySecurity -Arch 'x64' -Downloader $downloader -ToolRunner $runner -StateReader $stateReader -TamperPrompt $prompt -DefenderReader $defenderReader -DefenderSink $defenderSink
  $global:MasterRequireInstallLock = $false
  Assert-True ($result.installed) 'bundle was not installed'
  Assert-True ($result.source -eq 'online') 'online download was not used'
  Assert-True ($result.catalogWarning -match 'Catalog dated') 'expired offline catalog did not warn'
  Assert-True ($seenUrls -contains $expectedZipUrl) 'allow-listed zip URL was not requested'
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $installRoot 'apps.json'))) -eq '{"apps":["SECRET-APPS"]}') 'apps.json changed'
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $installRoot 'controls-pin.json'))) -eq '{"pin":"SECRET-PIN"}') 'controls-pin.json changed'
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $installRoot 'logs/session.log'))) -eq 'keep-log') 'logs were not preserved'
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $installRoot 'Launcher.ps1'))) -match 'approved-launcher') 'approved launcher was not installed'
  Assert-True (-not (Test-Path (Join-Path $installRoot 'notes.txt'))) 'user note stayed in the live root'
  $prev = @(Get-ChildItem $temp -Directory | Where-Object { $_.Name -like 'DiagnosticWorkstation.prev-*' })
  Assert-True ($prev.Count -eq 1) 'previous root was not kept'
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $prev[0].FullName 'notes.txt'))) -eq 'USER-NOTE') 'user note was not moved aside'
  $marker = Read-JsonFile (Join-Path $installRoot '.installed-bundle.json')
  Assert-True ($marker.brand -eq 'mercedes') 'marker brand mismatch'
  Assert-True ($marker.supervisor -ceq 'WorkstationManager.exe') 'Mercedes marker supervisor changed'
  Assert-True ($marker.shellRegistration -eq 'not-changed') 'marker recorded a shell change'
  Assert-True ($result.windowsUpdate -eq 'disabled') 'Windows Update tool was not recorded'
  Assert-True ($result.defender -eq 'disabled') 'Defender was not disabled'
  Assert-True (-not $global:MasterPromptRan) 'Tamper prompt ran while Tamper Protection was off'
  $wubCalls = @($global:MasterTestCalls | Where-Object { $_.exe -match 'Wub_x64.exe' -and $_.arguments -eq '/D /P' })
  Assert-True ($wubCalls.Count -eq 1) 'Wub_x64.exe /D /P was not the disable command'
  Assert-True (@($global:MasterTestCalls | Where-Object { $_.exe -match 'dControl' }).Count -eq 0) 'dControl was invoked'
  $journal = [System.IO.File]::ReadAllText((Join-Path $logs 'install-journal.log'))
  Assert-True ($journal.Contains('windows-update-pre')) 'pre-state was not logged'
  Assert-True ($journal.Contains('windows-update-post')) 'post-state was not logged'
  Assert-True ($journal.Contains('Feature Updates may reset')) 'feature-update note missing'
  Assert-True ($journal.Contains('defender-pre')) 'defender pre-state was not logged'
  Assert-True ($journal.Contains('defender-post')) 'defender post-state was not logged'
  $snapshot = Read-JsonFile (Join-Path $data 'defender-pre-state.json')
  Assert-True ($snapshot.schema -eq 'diagnostic-workstation.defender-snapshot/v1') 'defender snapshot was not saved'
  foreach ($item in @($plan.Preferences)) {
    $hit = @($global:MasterDefenderCommands | Where-Object { $_.kind -eq 'Set-MpPreference' -and $_.name -eq $item.Name })
    Assert-True ($hit.Count -eq 1) "disable did not set $($item.Name)"
    Assert-True ([string]$hit[0].value -eq [string]$item.Disable) "disable value for $($item.Name)"
  }
  $spyware = @($global:MasterDefenderCommands | Where-Object { $_.kind -eq 'Set-Policy' -and $_.name -eq 'DisableAntiSpyware' })
  Assert-True ($spyware.Count -eq 0) 'DisableAntiSpyware was written'
  $antivirus = @($global:MasterDefenderCommands | Where-Object { $_.kind -eq 'Set-Policy' -and $_.name -eq 'DisableAntiVirus' -and $_.path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' })
  Assert-True ($antivirus.Count -eq 1 -and [int]$antivirus[0].value -eq 1) 'DisableAntiVirus was not set'
  $onAccess = @($global:MasterDefenderCommands | Where-Object { $_.kind -eq 'Set-Policy' -and $_.name -eq 'DisableOnAccessProtection' })
  Assert-True ($onAccess.Count -eq 1 -and [int]$onAccess[0].value -eq 1) 'on-access policy was not set'
  Assert-True (@($global:MasterDefenderCommands | Where-Object { $_.kind -ne 'Set-MpPreference' -and $_.kind -ne 'Set-Policy' }).Count -eq 0) 'disable changed something other than preferences and policy'
  $legacyCommands = New-Object System.Collections.Generic.List[object]
  $legacyLogs = Join-Path $temp 'legacy-spyware-logs'
  New-Item -ItemType Directory -Force -Path $legacyLogs | Out-Null
  $legacyRegistry = {
    param($Path, $Name)
    if ($Path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -and $Name -eq 'DisableAntiSpyware') {
      return [pscustomobject]@{ DisableAntiSpyware = 1 }
    }
    throw "registry value not present: $Path $Name"
  }
  $legacyLive = Get-DefenderLiveState -RegistryReader $legacyRegistry
  $legacyObserved = @($legacyLive.policies | Where-Object { $_.name -eq 'DisableAntiSpyware' -and $_.path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' })
  Assert-True ($legacyObserved.Count -eq 1 -and [bool]$legacyObserved[0].exists -and [int]$legacyObserved[0].value -eq 1) 'live reader did not see DisableAntiSpyware'
  $legacySnap = Join-Path $temp 'legacy-spyware.json'
  $legacy = Invoke-DefenderControl -Action 'disable' -LogDirectory $legacyLogs -SnapshotPath $legacySnap -RegistryReader $legacyRegistry -CommandSink { param($Command) $legacyCommands.Add($Command) } -TamperPrompt { param($Message) return $false }
  Assert-True ($legacy.status -eq 'disabled') 'legacy DisableAntiSpyware cleanup did not finish disable'
  Assert-True (@($legacyCommands | Where-Object { $_.kind -eq 'Remove-Policy' -and $_.name -eq 'DisableAntiSpyware' }).Count -eq 1) 'legacy DisableAntiSpyware was not removed'
  Assert-True (@($legacyCommands | Where-Object { $_.kind -eq 'Set-Policy' -and $_.name -eq 'DisableAntiSpyware' }).Count -eq 0) 'legacy cleanup wrote DisableAntiSpyware'
  Assert-True (@($legacyCommands | Where-Object { $_.kind -eq 'Remove-Policy' -and $_.name -ne 'DisableAntiSpyware' }).Count -eq 0) 'legacy cleanup removed another policy'
  $legacyJournal = [System.IO.File]::ReadAllText((Join-Path $legacyLogs 'install-journal.log'))
  Assert-True ($legacyJournal.Contains('"step":"defender-legacy-disableantispyware"')) 'legacy DisableAntiSpyware cleanup was not journaled'
  Assert-True (Test-Path -LiteralPath (Join-Path $temp 'legacy-disableantispyware.removed')) 'legacy cleanup marker was not written'
  $legacyAgain = New-Object System.Collections.Generic.List[object]
  $legacyRepeat = Invoke-DefenderControl -Action 'disable' -LogDirectory $legacyLogs -SnapshotPath $legacySnap -RegistryReader $legacyRegistry -CommandSink { param($Command) $legacyAgain.Add($Command) } -TamperPrompt { param($Message) return $false }
  Assert-True ($legacyRepeat.status -eq 'disabled') 'second disable failed after the legacy cleanup'
  Assert-True (@($legacyAgain | Where-Object { $_.name -eq 'DisableAntiSpyware' }).Count -eq 0) 'legacy DisableAntiSpyware cleanup ran twice'
  Assert-True (@($global:MasterDefenderCommands | Where-Object { $_.name -eq 'WinDefend' -or $_.name -eq 'WdNisSvc' -or $_.name -eq 'MDCoreSvc' }).Count -eq 0) 'disable issued a Defender service command'
  $shortcuts = Read-JsonFile (Join-Path $data 'shortcuts-mercedes.json')
  $shortcutBlob = $shortcuts | ConvertTo-Json -Depth 6
  Assert-True ($shortcutBlob.Contains('Re-enable Windows Update and Defender')) 're-enable shortcut missing'
  Assert-True ($shortcutBlob.Contains('-Action enable')) 'enable action missing'
  Assert-True ($shortcutBlob.Contains('-Action reapply')) 'reapply action missing'
  Assert-True ($shortcutBlob.Contains('Uninstall-MasterBrand.ps1')) 'uninstall hook missing'
  Assert-True ($shortcutBlob.Contains('-WindowStyle Hidden')) 'security shortcuts open a visible PowerShell window'
  Assert-True (-not (Test-SupervisorRelaunchBlocked $installRoot)) 'supervisor lock was left on the brand root'
  Assert-True ($journal.Contains('supervisor-held')) 'supervisor hold was not logged'

  $global:MasterTestCalls.Clear()
  $global:MasterDefenderCommands.Clear()
  $undo = Invoke-SecurityUndo -Brand 'mercedes' -Action 'enable' -InstallerData $data -RepoRoot $fixture -LogDirectory $logs -Arch 'x64' -ToolRunner $runner -StateReader $stateReader -DefenderReader $defenderReader -DefenderSink $defenderSink -TamperPrompt $prompt
  Assert-True ($undo.windowsUpdate -eq 'enabled') 'undo did not request enable'
  Assert-True ($undo.defender -eq 'enabled') 'undo did not re-enable Defender'
  Assert-True (-not $global:MasterPromptRan) 'Tamper prompt ran during Defender undo'
  $restoredRealtime = @($global:MasterDefenderCommands | Where-Object { $_.kind -eq 'Set-MpPreference' -and $_.name -eq 'DisableRealtimeMonitoring' })
  Assert-True ($restoredRealtime.Count -eq 1 -and [string]$restoredRealtime[0].value -eq 'False') 'realtime monitoring was not restored'
  $maps = @($global:MasterDefenderCommands | Where-Object { $_.kind -eq 'Set-MpPreference' -and $_.name -eq 'MAPSReporting' })
  Assert-True ($maps.Count -eq 1 -and [string]$maps[0].value -eq '2') 'uncaptured MAPSReporting did not return to the default'
  $removedSpyware = @($global:MasterDefenderCommands | Where-Object { $_.kind -eq 'Remove-Policy' -and $_.name -eq 'DisableAntiSpyware' })
  Assert-True ($removedSpyware.Count -eq 0) 're-enable removed DisableAntiSpyware'
  $removedAntivirus = @($global:MasterDefenderCommands | Where-Object { $_.kind -eq 'Remove-Policy' -and $_.name -eq 'DisableAntiVirus' })
  Assert-True ($removedAntivirus.Count -eq 1) 'DisableAntiVirus policy was not removed'
  Assert-True (@($global:MasterDefenderCommands | Where-Object { $_.kind -ne 'Set-MpPreference' -and $_.kind -ne 'Remove-Policy' -and $_.kind -ne 'Set-Policy' }).Count -eq 0) 're-enable changed something other than preferences and policy'
  Assert-True (@($global:MasterDefenderCommands | Where-Object { $_.name -eq 'WinDefend' -or $_.name -eq 'WdNisSvc' -or $_.name -eq 'MDCoreSvc' }).Count -eq 0) 're-enable issued a Defender service command'
  $enableCalls = @($global:MasterTestCalls | Where-Object { $_.arguments -eq '/E' -and $_.exe -match 'Wub_x64.exe' })
  Assert-True ($enableCalls.Count -eq 1) 'Wub /E was not the undo command'
  $global:MasterTestCalls.Clear()
  $defenderCount = $global:MasterDefenderCommands.Count
  $reapply = Invoke-SecurityUndo -Brand 'mercedes' -Action 'reapply' -InstallerData $data -RepoRoot $fixture -LogDirectory $logs -Arch 'x86' -ToolRunner $runner -StateReader $stateReader -DefenderReader $defenderReader -DefenderSink $defenderSink -TamperPrompt $prompt
  Assert-True ($reapply.windowsUpdate -eq 'disabled') 'reapply did not request disable'
  Assert-True ($reapply.defender -eq 'not-run') 'reapply changed Defender'
  Assert-True ($global:MasterDefenderCommands.Count -eq $defenderCount) 'reapply issued Defender commands'
  $reapplyCalls = @($global:MasterTestCalls | Where-Object { $_.exe -match 'Wub.exe$' -and $_.arguments -eq '/D /P' })
  Assert-True ($reapplyCalls.Count -eq 1) '32-bit reapply did not use Wub.exe /D /P'

  $verifyRoot = Join-Path $temp 'verify-root'
  $global:MasterTestCalls.Clear()
  $verifiedOnly = Install-ApprovedBrand -Brand 'mercedes' -VerifyOnly -AllowTestRoot -InstallRoot $verifyRoot -InstallerData (Join-Path $temp 'verify-data') -LogDirectory (Join-Path $temp 'verify-logs') -RepoRoot $fixture -AllowUncheckedProcesses -Downloader $downloader -ToolRunner $runner
  Assert-True ($verifiedOnly.verified -and -not $verifiedOnly.installed) 'verify-only did not stop before install'
  Assert-True (-not (Test-Path $verifyRoot)) 'verify-only created the brand root'
  Assert-True ($global:MasterTestCalls.Count -eq 0) 'verify-only started a security tool'

  $offlineRoot = Join-Path $temp 'offline-root'
  $offlineData = Join-Path $temp 'offline-data'
  $global:MasterTestCalls.Clear()
  $failingDownloader = { param($Url, $Destination) throw 'network down' }
  $offlineResult = Install-ApprovedBrand -Brand 'mercedes' -AllowTestRoot -InstallRoot $offlineRoot -InstallerData $offlineData -LogDirectory (Join-Path $offlineData 'logs') -RepoRoot $fixture -AllowUncheckedProcesses -OfflineOnly:$false -Downloader $failingDownloader -ToolRunner $runner -StateReader $stateReader
  Assert-True ($offlineResult.source -eq 'offline') 'offline fallback was not used'
  Assert-True ($offlineResult.installed) 'offline install failed'
  Assert-True (Test-Path (Join-Path $offlineRoot 'Launcher.ps1')) 'offline payload missing'

  $badRoot = Join-Path $temp 'bad-root'
  New-Item -ItemType Directory -Path $badRoot | Out-Null
  Write-Utf8NoBom (Join-Path $badRoot 'Launcher.ps1') "Write-Output 'untouched'`n"
  $evilZip = Join-Path $temp 'evil.zip'
  New-FixtureZip $evilZip @{ 'Launcher.ps1' = $launcher; '../evil.ps1' = $launcher }
  $evilManifest = Join-Path $temp 'evil-manifest.json'
  $evilRelease = [pscustomobject]@{
    tag = 'mercedes-v1.2.3-beta.1'; version = '1.2.3-beta.1'; sha256 = (Get-Sha256Hex $evilZip); bytes = (Get-Item $evilZip).Length
  }
  Write-Utf8NoBom $evilManifest (([ordered]@{
    schemaVersion = 1; brand = 'mercedes'; version = '1.2.3-beta.1'; tag = 'mercedes-v1.2.3-beta.1'; asset = 'workstation.zip'
    sha256 = $evilRelease.sha256; bytes = $evilRelease.bytes
    files = @([ordered]@{ path = 'Launcher.ps1'; sha256 = (Get-BytesSha256 $launcher); bytes = $launcher.Length })
  } | ConvertTo-Json -Depth 6) + "`n")
  Assert-Throws {
    Open-VerifiedBundle -Brand 'mercedes' -Release $evilRelease -ZipPath $evilZip -ManifestPath $evilManifest -Staging (Join-Path $temp 'evil-missing-stage')
  } 'SHA-256 is required'
  $evilRelease = [pscustomobject]@{
    tag = $evilRelease.tag; version = $evilRelease.version; sha256 = $evilRelease.sha256; bytes = $evilRelease.bytes
    manifestSha256 = (Get-Sha256Hex $evilManifest)
  }
  Assert-Throws {
    Open-VerifiedBundle -Brand 'mercedes' -Release $evilRelease -ZipPath $evilZip -ManifestPath $evilManifest -Staging (Join-Path $temp 'evil-stage')
  } 'Unsafe path'
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $badRoot 'Launcher.ps1'))) -match 'untouched') 'failed verify wrote the install root'
  Assert-True (-not (Test-Path (Join-Path $temp 'evil-stage'))) 'rejected zip left a staging directory'

  $extraZip = Join-Path $temp 'extra.zip'
  New-FixtureZip $extraZip @{ 'Launcher.ps1' = $launcher; 'version.json' = $version; 'extra.txt' = [byte[]](65, 66) }
  $extraRelease = [pscustomobject]@{
    tag = 'mercedes-v1.2.3-beta.1'; version = '1.2.3-beta.1'; sha256 = (Get-Sha256Hex $extraZip); bytes = (Get-Item $extraZip).Length
  }
  $extraManifest = Join-Path $temp 'extra-manifest.json'
  Write-Utf8NoBom $extraManifest (([ordered]@{
    schemaVersion = 1; brand = 'mercedes'; version = '1.2.3-beta.1'; tag = 'mercedes-v1.2.3-beta.1'; asset = 'workstation.zip'
    sha256 = $extraRelease.sha256; bytes = $extraRelease.bytes
    files = @(
      [ordered]@{ path = 'Launcher.ps1'; sha256 = (Get-BytesSha256 $launcher); bytes = $launcher.Length },
      [ordered]@{ path = 'version.json'; sha256 = (Get-BytesSha256 $version); bytes = $version.Length }
    )
  } | ConvertTo-Json -Depth 6) + "`n")
  $extraRelease = [pscustomobject]@{
    tag = $extraRelease.tag; version = $extraRelease.version; sha256 = $extraRelease.sha256; bytes = $extraRelease.bytes
    manifestSha256 = (Get-Sha256Hex $extraManifest)
  }
  Assert-Throws {
    Open-VerifiedBundle -Brand 'mercedes' -Release $extraRelease -ZipPath $extraZip -ManifestPath $extraManifest -Staging (Join-Path $temp 'extra-stage')
  } 'Unexpected bundle file'

  $localZip = Join-Path $temp 'local.zip'
  $localLauncher = [System.Text.Encoding]::UTF8.GetBytes("Write-Output 'ok'`n")
  $localVersion = [System.Text.Encoding]::UTF8.GetBytes('{"version":"1.2.3-beta.1"}')
  New-FixtureZip $localZip @{ 'Launcher.ps1' = $localLauncher; 'version.json' = $localVersion; 'apps.json' = [Text.Encoding]::UTF8.GetBytes('{"apps":["from-package"]}') }
  $localManifest = Join-Path $temp 'local-manifest.json'
  $localObject = [ordered]@{
    schemaVersion = 1; brand = 'mercedes'; version = '1.2.3-beta.1'; tag = 'mercedes-v1.2.3-beta.1'; asset = 'workstation.zip'
    sha256 = (Get-Sha256Hex $localZip); bytes = (Get-Item $localZip).Length
    files = @(
      [ordered]@{ path = 'Launcher.ps1'; sha256 = (Get-BytesSha256 $localLauncher); bytes = $localLauncher.Length },
      [ordered]@{ path = 'version.json'; sha256 = (Get-BytesSha256 $localVersion); bytes = $localVersion.Length },
      [ordered]@{ path = 'apps.json'; sha256 = (Get-BytesSha256 ([Text.Encoding]::UTF8.GetBytes('{"apps":["from-package"]}'))); bytes = ([Text.Encoding]::UTF8.GetBytes('{"apps":["from-package"]}')).Length }
    )
  }
  Write-Utf8NoBom $localManifest (($localObject | ConvertTo-Json -Depth 6) + "`n")
  Assert-Throws {
    Open-VerifiedBundle -Brand 'mercedes' -Release ([pscustomobject]@{ tag = 'mercedes-v1.2.3-beta.1'; version = '1.2.3-beta.1'; sha256 = $localObject.sha256; bytes = $localObject.bytes; manifestSha256 = (Get-Sha256Hex $localManifest) }) -ZipPath $localZip -ManifestPath $localManifest -Staging (Join-Path $temp 'local-stage')
  } 'machine-local'

  $foreign = Join-Path $temp 'foreign-root'
  New-Item -ItemType Directory -Path $foreign | Out-Null
  Write-Utf8NoBom (Join-Path $foreign '.installed-bundle.json') '{"brand":"mercedes","version":"1.2.3-beta.1"}'
  Write-Utf8NoBom (Join-Path $foreign 'Launcher.ps1') "Write-Output 'mercedes-live'`n"
  $stageForeign = Join-Path $temp 'foreign-stage'
  New-Item -ItemType Directory -Path $stageForeign | Out-Null
  Write-Utf8NoBom (Join-Path $stageForeign 'Launcher.ps1') "Write-Output 'bmw'`n"
  Assert-Throws {
    Install-VerifiedTree -Staging $stageForeign -Root $foreign -Brand 'bmw' -Tag 'bmw-v1.0.2-beta.1' -Version '1.0.2-beta.1' -ZipSha256 ('a' * 64)
  } 'belongs to mercedes'
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $foreign 'Launcher.ps1'))) -match 'mercedes-live') 'foreign install changed the root'

  $current = Join-Path $temp 'current-root'
  New-Item -ItemType Directory -Path $current | Out-Null
  Write-Utf8NoBom (Join-Path $current '.installed-bundle.json') '{"brand":"mercedes","version":"9.0.0"}'
  $stageOld = Join-Path $temp 'old-stage'
  New-Item -ItemType Directory -Path $stageOld | Out-Null
  Write-Utf8NoBom (Join-Path $stageOld 'Launcher.ps1') "Write-Output 'older'`n"
  Assert-Throws {
    Install-VerifiedTree -Staging $stageOld -Root $current -Brand 'mercedes' -Tag 'mercedes-v1.2.3-beta.1' -Version '1.2.3-beta.1' -ZipSha256 ('b' * 64)
  } 'older approved version'

  $pruneParent = Join-Path $temp 'prune'
  New-Item -ItemType Directory -Path $pruneParent | Out-Null
  foreach ($name in @('DiagnosticWorkstation.prev-20200101', 'DiagnosticWorkstation.prev-20200102', 'DiagnosticWorkstation.prev-20200103')) {
    New-Item -ItemType Directory -Path (Join-Path $pruneParent $name) | Out-Null
  }
  Remove-OldPrevFolders $pruneParent 'DiagnosticWorkstation'
  Assert-True (-not (Test-Path (Join-Path $pruneParent 'DiagnosticWorkstation.prev-20200101'))) 'oldest previous root was kept'
  Assert-True (Test-Path (Join-Path $pruneParent 'DiagnosticWorkstation.prev-20200103')) 'newest previous root was removed'

  $repairRoot = Join-Path $temp 'repair-root'
  $repairPrev = Join-Path $temp 'repair-root.prev-test'
  New-Item -ItemType Directory -Path $repairRoot, $repairPrev | Out-Null
  Write-Utf8NoBom (Join-Path $repairPrev 'Launcher.ps1') "Write-Output 'restored'`n"
  $progress = Join-Path $temp 'install-in-progress.json'
  Write-Utf8NoBom $progress ((@{ root = $repairRoot; prev = $repairPrev } | ConvertTo-Json -Compress) + "`n")
  Assert-Throws { Repair-InterruptedInstall $progress } 'Recovered an interrupted install'
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $repairRoot 'Launcher.ps1'))) -match 'restored') 'interrupted install was not restored'
  Assert-True (-not (Test-Path ($repairRoot + '.failed-repair'))) 'interrupted install left a failed-repair folder'

  $swapRoot = Join-Path $temp 'swap-root'
  $swapStage = Join-Path $temp 'swap-stage'
  New-Item -ItemType Directory -Path $swapRoot, $swapStage | Out-Null
  Write-Utf8NoBom (Join-Path $swapRoot 'Launcher.ps1') "Write-Output 'before-swap'`n"
  Write-Utf8NoBom (Join-Path $swapRoot '.installed-bundle.json') '{"brand":"mercedes","version":"1.0.0"}'
  Write-Utf8NoBom (Join-Path $swapStage 'Launcher.ps1') "Write-Output 'after-swap'`n"
  $env:DIAGNOSTIC_WORKSTATION_TEST_FAIL_SWAP = '1'
  try {
    Assert-Throws {
      Install-VerifiedTree -Staging $swapStage -Root $swapRoot -Brand 'mercedes' -Tag 'mercedes-v1.2.3-beta.1' -Version '1.2.3-beta.1' -ZipSha256 ('f' * 64)
    } 'test-only failure during install swap'
  } finally {
    [Environment]::SetEnvironmentVariable('DIAGNOSTIC_WORKSTATION_TEST_FAIL_SWAP', $null, 'Process')
  }
  Assert-True ([string]::IsNullOrEmpty([string]$env:DIAGNOSTIC_WORKSTATION_TEST_FAIL_SWAP)) 'test swap hook stayed set'
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $swapRoot 'Launcher.ps1'))) -match 'before-swap') 'in-install failure did not restore Launcher.ps1'
  $swapParent = Split-Path -Parent $swapRoot
  $swapLeaf = Split-Path -Leaf $swapRoot
  $swapLeftovers = @(Get-ChildItem -LiteralPath $swapParent -Force | Where-Object { $_.Name -like ($swapLeaf + '.failed-*') -or $_.Name -like ($swapLeaf + '.prev-*') })
  Assert-True ($swapLeftovers.Count -eq 0) 'in-install failure left a prev or failed folder'
  $masterText = [System.IO.File]::ReadAllText((Join-Path $repo 'installer/Master/Install-Master.ps1'))
  $clearAt = $masterText.IndexOf("SetEnvironmentVariable('DIAGNOSTIC_WORKSTATION_TEST_FAIL_SWAP'")
  $enterAt = $masterText.IndexOf('Enter-MasterInstallerProcess')
  Assert-True (($clearAt -ge 0) -and ($enterAt -gt $clearAt)) 'production entry does not clear the test swap hook before elevation'
  Assert-True ($blob.Contains('fail-swap.marker')) 'swap failure marker is not required'
  Assert-True ($blob.Contains('diagnostic-workstation-test-fail-swap')) 'swap failure marker token is missing'
  $markerData = Join-Path $temp 'marker-data'
  $markerWork = Join-Path $temp 'marker-work'
  New-Item -ItemType Directory -Path $markerData, $markerWork | Out-Null
  Assert-True (-not (Test-HarnessFailSwapMarker $markerData)) 'missing swap marker was honored'
  $inside = Join-Path $markerData 'fail-swap.marker'
  Write-Utf8NoBom $inside 'diagnostic-workstation-test-fail-swap'
  Write-Utf8NoBom (Join-Path $markerData 'fail-swap.location') ($inside + "`n")
  Assert-True (-not (Test-HarnessFailSwapMarker $markerData)) 'a marker inside the installer data dir was honored'
  $outside = Join-Path $markerWork 'fail-swap.marker'
  Write-Utf8NoBom $outside 'diagnostic-workstation-test-fail-swap'
  Write-Utf8NoBom (Join-Path $markerData 'fail-swap.location') ($outside + "`n")
  Assert-True (Test-HarnessFailSwapMarker $markerData) 'harness work dir marker was not honored'
  Write-Utf8NoBom $outside 'not-the-token'
  Assert-True (-not (Test-HarnessFailSwapMarker $markerData)) 'a production file was honored as the swap marker'
  Write-Utf8NoBom $outside 'diagnostic-workstation-test-fail-swap'
  $markerLogs = Join-Path $temp 'marker-logs'
  $script:HarnessFailSwapArmed = $true
  Set-HarnessFailSwapArmed -InstallerData $markerData -LogDirectory $markerLogs
  Assert-True (-not $script:HarnessFailSwapArmed) 'fail-swap armed without the harness switch'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $markerLogs 'install-journal.log'))) 'an unswitched fail-swap pointer was journaled'
  Set-HarnessFailSwapArmed -Allow -InstallerData $markerData -LogDirectory $markerLogs
  Assert-True ($script:HarnessFailSwapArmed) 'harness switch did not arm fail-swap'
  $armedJournal = [System.IO.File]::ReadAllText((Join-Path $markerLogs 'install-journal.log'))
  Assert-True ($armedJournal.Contains('"step":"harness-fail-swap-armed"')) 'armed fail-swap was not journaled'
  $script:HarnessFailSwapArmed = $false

  $tools = Join-Path $repo 'tools/security'
  $wub64 = Select-WubExecutable (Get-SecurityManifest $tools 'wub') 'x64'
  $wub32 = Select-WubExecutable (Get-SecurityManifest $tools 'wub') 'x86'
  Assert-True ($wub64.EndsWith('Wub_x64.exe')) '64-bit tool was not selected'
  Assert-True ($wub32.EndsWith('Wub.exe')) '32-bit tool was not selected'
  Assert-True (-not (Test-Path (Join-Path $tools 'dcontrol/dControl.exe'))) 'the old Defender Control binary is still shipped'
  Assert-True (-not (Test-Path (Join-Path $tools 'dcontrol/dControl.ini'))) 'the old Defender Control sidecar is still shipped'
  Assert-True (-not (Test-Path (Join-Path $tools 'dcontrol/tool-manifest.json'))) 'the old Defender Control manifest is still shipped'
  Assert-True (Test-Path (Join-Path $tools 'dcontrol/ReadMe.txt')) 'vendor readme reference was removed'
  Assert-True (Test-Path (Join-Path $tools 'dcontrol/STATUS.md')) 'Defender reference status was removed'
  Assert-Throws { Invoke-DefenderLiveCommand ([pscustomobject]@{ kind = 'Set-MpPreference'; name = 'DisableRealtimeMonitoring'; value = $true }) } 'forbidden'

  $flip = Join-Path $temp 'flip-tools'
  New-Item -ItemType Directory -Force -Path (Join-Path $flip 'wub') | Out-Null
  Get-ChildItem -Path (Join-Path $tools 'wub') -Force | Copy-Item -Destination (Join-Path $flip 'wub') -Force
  $flipExe = Join-Path $flip 'wub/Wub_x64.exe'
  $bytes = [System.IO.File]::ReadAllBytes($flipExe)
  $bytes[$bytes.Length - 1] = [byte](($bytes[$bytes.Length - 1] + 1) % 255)
  [System.IO.File]::WriteAllBytes($flipExe, $bytes)
  $global:MasterTestCalls.Clear()
  Assert-Throws { Invoke-WindowsUpdateTool -ToolsRoot $flip -Action 'disable' -LogDirectory $logs -Arch 'x64' -ToolRunner $runner -StateReader $stateReader } 'hash mismatch'
  Assert-True ($global:MasterTestCalls.Count -eq 0) 'tampered WUB was executed'

  $defenderLogs = Join-Path $temp 'defender-direct-logs'
  New-Item -ItemType Directory -Force -Path $defenderLogs | Out-Null
  $directSnap = Join-Path $temp 'defender-direct.json'
  $directCommands = New-Object System.Collections.Generic.List[object]
  $directSink = { param($Command) $directCommands.Add($Command) }
  $tamperReads = @{ n = 0 }
  $declined = Invoke-DefenderControl -Action 'disable' -LogDirectory $defenderLogs -SnapshotPath $directSnap -ReadState {
    return (New-TestDefenderState 'on')
  } -CommandSink $directSink -TamperPrompt { param($Message) return $false }
  Assert-True ($declined.status -eq 'tamper-blocked') 'declined Tamper Protection prompt did not block Defender'
  Assert-True ($directCommands.Count -eq 0) 'Defender changed while Tamper Protection stayed on'
  Assert-True (-not (Test-Path $directSnap)) 'a declined prompt wrote a Defender snapshot'
  $tamperReads.n = 0
  $stillOn = Invoke-DefenderControl -Action 'disable' -LogDirectory $defenderLogs -SnapshotPath $directSnap -ReadState {
    $tamperReads.n++
    return (New-TestDefenderState 'on')
  } -CommandSink $directSink -TamperPrompt { param($Message) return $true }
  Assert-True ($stillOn.status -eq 'tamper-blocked') 'Tamper Protection that stayed on did not block Defender'
  Assert-True ($directCommands.Count -eq 0) 'Defender changed after Tamper Protection stayed on'
  $directCommands.Clear()
  $tamperReads.n = 0
  $turnedOff = Invoke-DefenderControl -Action 'disable' -LogDirectory $defenderLogs -SnapshotPath $directSnap -ReadState {
    $tamperReads.n++
    if ($tamperReads.n -eq 1) { return (New-TestDefenderState 'on') }
    return (New-TestDefenderState 'off')
  } -CommandSink $directSink -TamperPrompt { param($Message) return $true }
  Assert-True ($turnedOff.status -eq 'disabled') 'Defender did not disable after Tamper Protection was turned off'
  $afterPrompt = @($directCommands | Where-Object { $_.kind -eq 'Set-MpPreference' -and $_.name -eq 'DisableRealtimeMonitoring' })
  Assert-True ($afterPrompt.Count -eq 1 -and [string]$afterPrompt[0].value -eq 'True') 'realtime monitoring was not disabled after the prompt'
  $unknownPrompt = @{ ran = $false }
  $unknown = Invoke-DefenderControl -Action 'disable' -LogDirectory $defenderLogs -SnapshotPath (Join-Path $temp 'defender-unknown.json') -ReadState {
    return (New-TestDefenderState 'unknown')
  } -CommandSink { param($Command) } -TamperPrompt { param($Message) $unknownPrompt.ran = $true; return $true }
  Assert-True ($unknown.status -eq 'disabled') 'unknown Tamper Protection state did not continue'
  Assert-True (-not $unknownPrompt.ran) 'unknown Tamper Protection state prompted'
  $lateAttempts = @{ n = 0 }
  $latePrompt = @{ ran = $false }
  $late = Invoke-DefenderControl -Action 'disable' -LogDirectory $defenderLogs -SnapshotPath (Join-Path $temp 'defender-late.json') -ReadState {
    return (New-TestDefenderState 'off')
  } -CommandSink {
    param($Command)
    if ($Command.kind -eq 'Set-MpPreference' -and $Command.name -eq 'DisableRealtimeMonitoring' -and $lateAttempts.n -eq 0) {
      $lateAttempts.n++
      throw 'This operation is not allowed because Tamper Protection is enabled'
    }
  } -TamperPrompt { param($Message) $latePrompt.ran = $true; return $true }
  Assert-True ($late.status -eq 'disabled') 'a Tamper Protection command error did not retry'
  Assert-True ($latePrompt.ran) 'a Tamper Protection command error did not prompt'
  Assert-True ($lateAttempts.n -eq 1) 'the Tamper Protection retry did not run'
  $noSnap = Join-Path $temp 'defender-missing.json'
  $defaultCommands = New-Object System.Collections.Generic.List[object]
  $defaulted = Invoke-DefenderControl -Action 'enable' -LogDirectory $defenderLogs -SnapshotPath $noSnap -ReadState {
    return [pscustomobject]@{
      tamper = 'off'
      preferences = @{ DisableRealtimeMonitoring = $true; MAPSReporting = 0 }
      policies = @()
      services = @([pscustomobject]@{ name = 'WinDefend'; present = $true; status = 'Stopped'; startMode = 'Disabled' })
    }
  } -CommandSink { param($Command) $defaultCommands.Add($Command) } -TamperPrompt { param($Message) return $false }
  Assert-True ($defaulted.status -eq 'enabled') 'enable without a snapshot failed'
  $defaultRealtime = @($defaultCommands | Where-Object { $_.name -eq 'DisableRealtimeMonitoring' })
  Assert-True ([string]$defaultRealtime[0].value -eq 'False') 'missing snapshot did not restore realtime monitoring'
  $defaultMaps = @($defaultCommands | Where-Object { $_.name -eq 'MAPSReporting' })
  Assert-True ([string]$defaultMaps[0].value -eq '2') 'missing snapshot did not restore MAPSReporting'
  Assert-True (@($defaultCommands | Where-Object { $_.name -eq 'WinDefend' -or $_.kind -eq 'Set-Service' }).Count -eq 0) 'missing snapshot tried to change WinDefend'
  $rollback = New-Object System.Collections.Generic.List[object]
  $failed = Invoke-DefenderControl -Action 'disable' -LogDirectory $defenderLogs -SnapshotPath (Join-Path $temp 'defender-fail.json') -ReadState {
    return (New-TestDefenderState 'off')
  } -CommandSink {
    param($Command)
    $rollback.Add($Command)
    if ($Command.kind -eq 'Set-MpPreference' -and $Command.name -eq 'DisableEmailScanning' -and [string]$Command.value -eq 'True') { throw 'access denied' }
  } -TamperPrompt { param($Message) return $true }
  Assert-True ($failed.status -eq 'failed') 'a Defender apply error was ignored'
  Assert-True (@($rollback | Where-Object { $_.kind -eq 'Remove-Policy' -and $_.name -eq 'DisableAntiVirus' }).Count -ge 1) 'failed disable did not roll back policy'
  Assert-True (@($rollback | Where-Object { $_.kind -eq 'Remove-Policy' -and $_.name -eq 'DisableAntiSpyware' }).Count -eq 0) 'failed disable rolled back DisableAntiSpyware'

  Assert-True ((Get-DefenderCommandScope 'Set-Policy') -eq 'admin') 'policy writes left the admin process'
  Assert-True ((Get-DefenderCommandScope 'Remove-Policy') -eq 'admin') 'policy removal left the admin process'
  Assert-True ((Get-DefenderCommandScope 'Set-MpPreference') -eq 'system') 'Set-MpPreference stayed in the admin process'
  Assert-Throws { Get-DefenderCommandScope 'Set-Service' } 'Unsupported defender command'
  Assert-Throws {
    Register-DefenderSystemTask ([pscustomobject]@{ taskName = 'DiagnosticWorkstation-Defender-test'; userId = 'SYSTEM'; runLevel = 'Highest'; execute = 'powershell.exe'; argumentLine = '-NoProfile'; workingDirectory = $temp })
  } 'forbidden'

  $systemLogs = Join-Path $temp 'defender-system-logs'
  New-Item -ItemType Directory -Force -Path $systemLogs | Out-Null
  $systemSnap = Join-Path $temp 'defender-system.json'
  $systemAdmin = New-Object System.Collections.Generic.List[object]
  $systemHost = New-Object System.Collections.Generic.List[object]
  $systemTask = {
    param($Phase, $Spec)
    $systemHost.Add([pscustomobject]@{ phase = $Phase; spec = $Spec }) | Out-Null
    if ($Phase -eq 'wait') { return [pscustomobject]@{ ok = $true; error = $null } }
  }
  $systemDisabled = Invoke-DefenderControl -Action 'disable' -LogDirectory $systemLogs -SnapshotPath $systemSnap -ReadState {
    return (New-TestDefenderState 'off')
  } -CommandSink { param($Command) $systemAdmin.Add($Command) | Out-Null } -TaskHost $systemTask -TamperPrompt { param($Message) return $false }
  Assert-True ($systemDisabled.status -eq 'disabled') 'SYSTEM Defender disable did not report disabled'
  $systemRegisters = @($systemHost | Where-Object { $_.phase -eq 'register' })
  $systemDeletes = @($systemHost | Where-Object { $_.phase -eq 'delete' })
  Assert-True ($systemRegisters.Count -eq 1) 'disable did not use one SYSTEM batch for Set-MpPreference'
  Assert-True ($systemDeletes.Count -eq $systemRegisters.Count) 'a SYSTEM task was left registered'
  $preferenceBatch = @($systemRegisters[0].spec.commands)
  Assert-True ($preferenceBatch.Count -gt 0 -and @($preferenceBatch | Where-Object { $_.kind -ne 'Set-MpPreference' }).Count -eq 0) 'the SYSTEM batch was not only Set-MpPreference'
  Assert-True (@($systemAdmin | Where-Object { $_.kind -eq 'Set-Policy' -and $_.name -eq 'DisableAntiVirus' }).Count -eq 1) 'DisableAntiVirus was not written in the admin process'
  Assert-True (@($systemAdmin | Where-Object { $_.kind -eq 'Set-Policy' -and $_.name -eq 'DisableAntiSpyware' }).Count -eq 0) 'DisableAntiSpyware was written in the admin process'
  Assert-True (@($systemAdmin | Where-Object { $_.kind -eq 'Set-MpPreference' }).Count -eq 0) 'a SYSTEM command ran in the admin sink'
  Assert-True ($systemRegisters[0].spec.taskName.StartsWith('DiagnosticWorkstation-Defender-')) 'task name is not transient'
  Assert-True ($systemRegisters[0].spec.userId -eq 'SYSTEM') 'task principal is not SYSTEM'
  Assert-True ($systemRegisters[0].spec.runLevel -eq 'Highest') 'task run level is not highest'
  Assert-True ($systemRegisters[0].spec.argumentLine.Contains('-WindowStyle Hidden')) 'SYSTEM task can show a window'
  Assert-True ($systemRegisters[0].spec.argumentLine.Contains('-NonInteractive')) 'SYSTEM task is interactive'
  $systemJournal = [System.IO.File]::ReadAllText((Join-Path $systemLogs 'install-journal.log'))
  Assert-True ($systemJournal.Contains('"step":"defender-system-task"')) 'SYSTEM task was not journaled'
  Assert-True ($systemJournal.Contains('"deleted":true')) 'journal did not record task deletion'
  Assert-True ($systemJournal.Contains('"transient":true')) 'journal did not record the task as transient'
  $enableHost = New-Object System.Collections.Generic.List[object]
  $enableAdmin = New-Object System.Collections.Generic.List[object]
  $systemEnabled = Invoke-DefenderControl -Action 'enable' -LogDirectory $systemLogs -SnapshotPath $systemSnap -ReadState {
    return (New-TestDefenderState 'off')
  } -CommandSink { param($Command) $enableAdmin.Add($Command) | Out-Null } -TaskHost {
    param($Phase, $Spec)
    $enableHost.Add([pscustomobject]@{ phase = $Phase; spec = $Spec }) | Out-Null
    if ($Phase -eq 'wait') { return [pscustomobject]@{ ok = $true; error = $null } }
  } -TamperPrompt { param($Message) return $false }
  Assert-True ($systemEnabled.status -eq 'enabled') 'SYSTEM Defender re-enable did not report enabled'
  $enableRegisters = @($enableHost | Where-Object { $_.phase -eq 'register' })
  $enableDeletes = @($enableHost | Where-Object { $_.phase -eq 'delete' })
  Assert-True ($enableRegisters.Count -eq 1) 're-enable did not use one SYSTEM batch for Set-MpPreference'
  Assert-True ($enableDeletes.Count -eq $enableRegisters.Count) 're-enable left a SYSTEM task registered'
  Assert-True (@($enableRegisters[0].spec.commands | Where-Object { $_.kind -ne 'Set-MpPreference' }).Count -eq 0) 're-enable sent a non-preference command to SYSTEM'
  Assert-True (@($enableRegisters[0].spec.commands | Where-Object { $_.name -eq 'DisableRealtimeMonitoring' }).Count -eq 1) 're-enable did not restore realtime monitoring as SYSTEM'
  Assert-True (@($enableAdmin | Where-Object { $_.kind -eq 'Remove-Policy' -and $_.name -eq 'DisableAntiVirus' }).Count -eq 1) 're-enable did not remove policy in the admin process'
  Assert-True (@($enableAdmin | Where-Object { $_.kind -eq 'Remove-Policy' -and $_.name -eq 'DisableAntiSpyware' }).Count -eq 0) 're-enable removed DisableAntiSpyware'

  $deniedLogs = Join-Path $temp 'defender-denied-logs'
  New-Item -ItemType Directory -Force -Path $deniedLogs | Out-Null
  $deniedHost = New-Object System.Collections.Generic.List[object]
  $denied = Invoke-DefenderControl -Action 'disable' -LogDirectory $deniedLogs -SnapshotPath (Join-Path $temp 'defender-denied.json') -ReadState {
    return (New-TestDefenderState 'off')
  } -CommandSink { param($Command) } -TaskHost {
    param($Phase, $Spec)
    $deniedHost.Add([pscustomobject]@{ phase = $Phase; spec = $Spec }) | Out-Null
    if ($Phase -eq 'wait') { return [pscustomobject]@{ ok = $false; error = 'Access is denied' } }
  } -TamperPrompt { param($Message) return $false }
  Assert-True ($denied.status -eq 'failed') 'access denied from the SYSTEM task was ignored'
  $deniedRegisters = @($deniedHost | Where-Object { $_.phase -eq 'register' })
  $deniedDeletes = @($deniedHost | Where-Object { $_.phase -eq 'delete' })
  Assert-True ($deniedRegisters.Count -ge 2) 'access denied did not roll back through the SYSTEM task'
  Assert-True ($deniedDeletes.Count -eq $deniedRegisters.Count) 'access denied left a SYSTEM task registered'
  Assert-True (@($deniedRegisters | Where-Object { @($_.spec.commands | Where-Object { $_.kind -eq 'Set-MpPreference' }).Count -gt 0 }).Count -ge 2) 'rollback did not send Set-MpPreference to SYSTEM'
  $copyRoot = Join-Path $temp 'copy-master'
  Copy-MasterCommands $repo $copyRoot
  $copiedJob = Join-Path -Path (Join-Path -Path (Join-Path -Path $copyRoot -ChildPath 'Master') -ChildPath 'lib') -ChildPath 'Invoke-DefenderSystemJob.ps1'
  Assert-True (Test-Path -LiteralPath $copiedJob) 'the SYSTEM job script was not copied for re-enable'
  Assert-True (([System.IO.File]::ReadAllText($copiedJob)).Contains('Set-MpPreference')) 'the SYSTEM job does not apply preferences'

  $signed = Join-Path $temp 'signed-repo'
  New-Item -ItemType Directory -Force -Path (Join-Path $signed 'catalog'), (Join-Path $signed 'keys') | Out-Null
  Copy-Item (Join-Path $fixture 'keys/*') (Join-Path $signed 'keys') -Force
  $signedCatalog = '{"schema":"diagnostic-workstation.catalog/v1","catalogSerial":1,"issuedUtc":"2026-01-01T00:00:00Z","expiresUtc":"2027-01-01T00:00:00Z","signatureStatus":"release-signed","repo":"wilesy7404/diagnostic-workstation","brands":[]}'
  Write-Utf8NoBom (Join-Path $signed 'catalog/catalog.json') ($signedCatalog + "`n")
  Write-Utf8NoBom (Join-Path $signed 'catalog/catalog.sha256') ((Get-Sha256Hex (Join-Path $signed 'catalog/catalog.json')) + "  catalog.json`n")
  Copy-Item (Join-Path $repo 'catalog/catalog.json.release.sig') (Join-Path $signed 'catalog/catalog.json.release.sig')
  Assert-Throws { Read-ApprovedCatalog (Join-Path $signed 'catalog/catalog.json') (Join-Path $signed 'catalog/catalog.sha256') (Join-Path $signed 'keys') (Join-Path $signed 'catalog/catalog.json.release.sig') } 'cannot be verified'

  $trustRepo = Join-Path $temp 'trust-data'
  New-Item -ItemType Directory -Path $trustRepo | Out-Null
  Write-TrustState (Join-Path $trustRepo 'trust-state.json') 5 $fixturePin
  Assert-Throws {
    Read-ApprovedCatalog (Join-Path $fixture 'catalog/catalog.json') (Join-Path $fixture 'catalog/catalog.sha256') (Join-Path $fixture 'keys') (Join-Path $fixture 'catalog/catalog.json.release.sig') (Join-Path $trustRepo 'trust-state.json')
  } 'older than the last accepted catalog'

  Assert-True (-not (Test-Path (Join-Path $repo 'installer/Master/Probe-DefenderControlCli.ps1'))) 'the Defender Control probe is still present'

  Assert-True (-not (Test-PreservedLeaf 'profile.json')) 'profile.json was rejected as machine-local'
  Assert-True (Test-PreservedLeaf 'apps.json') 'apps.json is no longer machine-local'
  $profileLauncher = [System.Text.Encoding]::UTF8.GetBytes("Write-Output 'profile-launcher'`n")
  $profileVersion = [System.Text.Encoding]::UTF8.GetBytes('{"version":"1.2.3-beta.1"}')
  $bundleProfile = [System.Text.Encoding]::UTF8.GetBytes('{"id":"mercedes","displayName":"BundleDefault"}')
  $profileZip = Join-Path $temp 'profile-bundle.zip'
  New-FixtureZip $profileZip @{ 'Launcher.ps1' = $profileLauncher; 'version.json' = $profileVersion; 'profile.json' = $bundleProfile }
  $profileManifest = Join-Path $temp 'profile-manifest.json'
  $profileRelease = [pscustomobject]@{
    tag = 'mercedes-v1.2.3-beta.1'; version = '1.2.3-beta.1'; sha256 = (Get-Sha256Hex $profileZip); bytes = (Get-Item $profileZip).Length
  }
  $profileObject = [ordered]@{
    schemaVersion = 1; brand = 'mercedes'; version = '1.2.3-beta.1'; tag = 'mercedes-v1.2.3-beta.1'; asset = 'workstation.zip'
    sha256 = $profileRelease.sha256; bytes = $profileRelease.bytes
    files = @(
      [ordered]@{ path = 'Launcher.ps1'; sha256 = (Get-BytesSha256 $profileLauncher); bytes = $profileLauncher.Length },
      [ordered]@{ path = 'version.json'; sha256 = (Get-BytesSha256 $profileVersion); bytes = $profileVersion.Length },
      [ordered]@{ path = 'profile.json'; sha256 = (Get-BytesSha256 $bundleProfile); bytes = $bundleProfile.Length }
    )
  }
  Write-Utf8NoBom $profileManifest (($profileObject | ConvertTo-Json -Depth 6) + "`n")
  $profileRelease = [pscustomobject]@{
    tag = $profileRelease.tag; version = $profileRelease.version; sha256 = $profileRelease.sha256; bytes = $profileRelease.bytes
    manifestSha256 = (Get-Sha256Hex $profileManifest)
  }
  $profileStage = Join-Path $temp 'profile-stage'
  $opened = Open-VerifiedBundle -Brand 'mercedes' -Release $profileRelease -ZipPath $profileZip -ManifestPath $profileManifest -Staging $profileStage
  Assert-True ([string]$opened.brand -eq 'mercedes') 'profile bundle was rejected'
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $profileStage 'profile.json'))) -match 'BundleDefault') 'bundle profile was not expanded'

  $parent = Join-Path $temp 'profile-parent'
  New-Item -ItemType Directory -Path $parent | Out-Null
  $keptRoot = Join-Path $parent 'KeptProfile'
  New-Item -ItemType Directory -Path $keptRoot | Out-Null
  Write-Utf8NoBom (Join-Path $keptRoot 'profile.json') '{"id":"mercedes","displayName":"MachineLocal"}'
  $keptStage = Join-Path $parent 'kept-stage'
  New-Item -ItemType Directory -Path $keptStage | Out-Null
  Write-Utf8NoBom (Join-Path $keptStage 'profile.json') '{"id":"mercedes","displayName":"BundleDefault"}'
  Write-Utf8NoBom (Join-Path $keptStage 'Launcher.ps1') "Write-Output 'new'`n"
  Install-VerifiedTree -Staging $keptStage -Root $keptRoot -Brand 'mercedes' -Tag 'mercedes-v1.2.3-beta.1' -Version '1.2.3-beta.1' -ZipSha256 ('c' * 64)
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $keptRoot 'profile.json'))) -match 'MachineLocal') 'existing profile.json was overwritten'
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $keptRoot 'Launcher.ps1'))) -match 'new') 'launcher was not installed beside a kept profile'

  $freshRoot = Join-Path $parent 'FreshProfile'
  $freshStage = Join-Path $parent 'fresh-stage'
  New-Item -ItemType Directory -Path $freshStage | Out-Null
  Write-Utf8NoBom (Join-Path $freshStage 'profile.json') '{"id":"mercedes","displayName":"BundleDefault"}'
  Write-Utf8NoBom (Join-Path $freshStage 'Launcher.ps1') "Write-Output 'fresh'`n"
  Install-VerifiedTree -Staging $freshStage -Root $freshRoot -Brand 'mercedes' -Tag 'mercedes-v1.2.3-beta.1' -Version '1.2.3-beta.1' -ZipSha256 ('d' * 64)
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $freshRoot 'profile.json'))) -match 'BundleDefault') 'fresh install did not receive profile.json'

  $emptyRoot = Join-Path $parent 'EmptyProfile'
  New-Item -ItemType Directory -Path $emptyRoot | Out-Null
  Write-Utf8NoBom (Join-Path $emptyRoot 'Launcher.ps1') "Write-Output 'old'`n"
  $emptyStage = Join-Path $parent 'empty-stage'
  New-Item -ItemType Directory -Path $emptyStage | Out-Null
  Write-Utf8NoBom (Join-Path $emptyStage 'profile.json') '{"id":"bmw","displayName":"BundleDefault"}'
  Write-Utf8NoBom (Join-Path $emptyStage 'Launcher.ps1') "Write-Output 'replaced'`n"
  Install-VerifiedTree -Staging $emptyStage -Root $emptyRoot -Brand 'bmw' -Tag 'bmw-v1.0.2-beta.1' -Version '1.0.2-beta.1' -ZipSha256 ('e' * 64)
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $emptyRoot 'profile.json'))) -match 'BundleDefault') 'install without profile.json dropped the bundle default'
  $bmwMarker = Read-JsonFile (Join-Path $emptyRoot '.installed-bundle.json')
  Assert-True ($bmwMarker.supervisor -ceq 'Watchdog.ps1') 'BMW marker supervisor is not Watchdog.ps1'
  Assert-True ($bmwMarker.supervisorNote -ceq (Get-BrandAllowEntry 'bmw').SupervisorNote) 'BMW marker note does not match the allow map'

  # Case, field-set, reorder, and removal failures. An appended row stays allowed.
  $lockSample = @(
    [pscustomobject]@{ brand = 'bmw'; version = '1'; zipSha256 = 'abc'; note = $null },
    [pscustomobject]@{ brand = 'mercedes'; version = '2'; zipSha256 = 'def'; note = $null }
  )
  $lockCase = @(
    [pscustomobject]@{ brand = 'bmw'; version = '1'; zipSha256 = 'ABC'; note = $null },
    [pscustomobject]@{ brand = 'mercedes'; version = '2'; zipSha256 = 'def'; note = $null }
  )
  Assert-Throws { Assert-VersionsLockPrefix $lockCase $lockSample } 'zipSha256 changed'
  $lockAdded = @(
    [pscustomobject]@{ brand = 'bmw'; version = '1'; zipSha256 = 'abc'; note = $null; extra = 1 },
    [pscustomobject]@{ brand = 'mercedes'; version = '2'; zipSha256 = 'def'; note = $null }
  )
  Assert-Throws { Assert-VersionsLockPrefix $lockAdded $lockSample } 'fields changed'
  $lockRemovedField = @(
    [pscustomobject]@{ brand = 'bmw'; version = '1'; zipSha256 = 'abc' },
    [pscustomobject]@{ brand = 'mercedes'; version = '2'; zipSha256 = 'def'; note = $null }
  )
  Assert-Throws { Assert-VersionsLockPrefix $lockRemovedField $lockSample } 'fields changed'
  $lockReordered = @(
    [pscustomobject]@{ brand = 'mercedes'; version = '2'; zipSha256 = 'def'; note = $null },
    [pscustomobject]@{ brand = 'bmw'; version = '1'; zipSha256 = 'abc'; note = $null }
  )
  Assert-Throws { Assert-VersionsLockPrefix $lockReordered $lockSample } 'reordered or replaced'
  $lockDropped = @(
    [pscustomobject]@{ brand = 'bmw'; version = '1'; zipSha256 = 'abc'; note = $null }
  )
  Assert-Throws { Assert-VersionsLockPrefix $lockDropped $lockSample } 'dropped'
  $lockAppended = @(
    [pscustomobject]@{ brand = 'bmw'; version = '1'; zipSha256 = 'abc'; note = $null },
    [pscustomobject]@{ brand = 'mercedes'; version = '2'; zipSha256 = 'def'; note = $null },
    [pscustomobject]@{ brand = 'bmw'; version = '3'; zipSha256 = 'fff' }
  )
  Assert-VersionsLockPrefix $lockAppended $lockSample
  Assert-Throws {
    Assert-LockRowIdentities @(
      [pscustomobject]@{ brand = 'bmw'; version = '1'; tag = 'v1' },
      [pscustomobject]@{ brand = 'bmw'; version = '1'; tag = 'v2' }
    )
  } 'duplicate brand and version'
  Assert-Throws {
    Assert-LockRowIdentities @(
      [pscustomobject]@{ brand = 'bmw'; version = '1'; tag = 'v1' },
      [pscustomobject]@{ brand = 'mercedes'; version = '2'; tag = 'v1' }
    )
  } 'duplicate tag'
  Assert-LockRowIdentities @(
    [pscustomobject]@{ brand = 'bmw'; version = '1'; tag = $null },
    [pscustomobject]@{ brand = 'mercedes'; version = '2'; tag = $null }
  )
  $typedExpected = @([pscustomobject]@{ brand = 'bmw'; version = '1'; zipBytes = 48955; voided = $true })
  Assert-Throws {
    Assert-VersionsLockPrefix @([pscustomobject]@{ brand = 'bmw'; version = '1'; zipBytes = '48955'; voided = $true }) $typedExpected
  } 'zipBytes type mismatch'
  Assert-Throws {
    Assert-VersionsLockPrefix @([pscustomobject]@{ brand = 'bmw'; version = '1'; zipBytes = 48955; voided = 1 }) $typedExpected
  } 'voided type mismatch'
  $newKey = Get-LockFieldKey (New-SampleLockRow 'bmw' '1.0.3-beta.1' 'bmw-v1.0.3-beta.1' $false $false 10)
  Assert-NewLockRow (New-SampleLockRow 'bmw' '1.0.3-beta.1' 'bmw-v1.0.3-beta.1' $false $false 10) 0 $newKey
  Assert-NewLockRow (New-SampleLockRow 'mercedes' '0.1.3-beta.4' 'mercedes-v0.1.3-beta.4' $false $false 20) 1 $newKey
  Assert-Throws { Assert-NewLockRow (New-SampleLockRow 'bmw' '1.0.3-beta.1' 'bmw-v9.9.9' $false $false 10) 0 $newKey } 'tag does not match bmw-v1.0.3-beta.1'
  Assert-Throws { Assert-NewLockRow (New-SampleLockRow 'bmw' '1.0.3-beta.1' 'v1.0.3-beta.1' $false $false 10) 0 $newKey } 'tag does not match bmw-v'
  Assert-Throws { Assert-NewLockRow (New-SampleLockRow 'bmw' '1.0.3-beta.1' $null $false $false 10) 0 $newKey } 'tag type mismatch'
  Assert-Throws { Assert-NewLockRow (New-SampleLockRow 'mercedes' '0.1.3-beta.4' 'bmw-v0.1.3-beta.4' $false $false 20) 1 $newKey } 'tag does not match mercedes-v'
  Assert-Throws { Assert-NewLockRow (New-SampleLockRow 'bmw' '1.0.3-beta.1' 'bmw-v1.0.3-beta.1' 'yes' $false 10) 0 $newKey } 'published type mismatch'
  Assert-Throws { Assert-NewLockRow (New-SampleLockRow 'bmw' '1.0.3-beta.1' 'bmw-v1.0.3-beta.1' $null $false 10) 0 $newKey } 'published type mismatch'
  Assert-Throws { Assert-NewLockRow (New-SampleLockRow 'bmw' '1.0.3-beta.1' 'bmw-v1.0.3-beta.1' $false 1 10) 0 $newKey } 'voided type mismatch'
  Assert-Throws { Assert-NewLockRow (New-SampleLockRow 'bmw' '1.0.3-beta.1' 'bmw-v1.0.3-beta.1' $false $false '10') 0 $newKey } 'zipBytes type mismatch'
  foreach ($hashName in @('zipSha256', 'manifestSha256', 'contentDigest')) {
    $badHash = New-SampleLockRow 'bmw' '1.0.3-beta.1' 'bmw-v1.0.3-beta.1' $false $false 10
    $badHash.$hashName = 'zz'
    Assert-Throws { Assert-NewLockRow $badHash 0 $newKey } "$hashName must be 64 lowercase hex"
  }
  $newlineHash = New-SampleLockRow 'bmw' '1.0.3-beta.1' 'bmw-v1.0.3-beta.1' $false $false 10
  $newlineHash.zipSha256 = ('b' * 64) + "`n"
  Assert-Throws { Assert-NewLockRow $newlineHash 0 $newKey } 'zipSha256 must be 64 lowercase hex'
  $extraRow = New-SampleLockRow 'bmw' '1.0.3-beta.1' 'bmw-v1.0.3-beta.1' $false $false 10
  $extraRow | Add-Member -NotePropertyName extra -NotePropertyValue 1
  Assert-Throws { Assert-NewLockRow $extraRow 0 $newKey } 'fields changed'
  $missingRow = New-SampleLockRow 'bmw' '1.0.3-beta.1' 'bmw-v1.0.3-beta.1' $false $false 10
  $missingRow.PSObject.Properties.Remove('note')
  Assert-Throws { Assert-NewLockRow $missingRow 0 $newKey } 'fields changed'

  # published may flip only from false to true, and only together with the publish-record fields.
  # A hash edit on that same change is still rejected.
  $publishBase = New-SampleLockRow 'bmw' '1.0.2-beta.1' 'bmw-v1.0.2-beta.1' $false $false 48955
  $publishBase.sourceCommit = '7b6befdfcb3d501a8b2f29b240adcb58df897fc5'
  $publishBase.workflowRunId = '39087426283'
  $publishedRow = Add-LockPublishRecord $publishBase
  Assert-VersionsLockPrefix @($publishedRow) @($publishBase)
  $hashEdited = Copy-LockRow $publishedRow
  $hashEdited.zipSha256 = ('f' * 64)
  Assert-Throws { Assert-VersionsLockPrefix @($hashEdited) @($publishBase) } 'zipSha256 changed'
  $digestEdited = Copy-LockRow $publishedRow
  $digestEdited.contentDigest = ('9' * 64)
  Assert-Throws { Assert-VersionsLockPrefix @($digestEdited) @($publishBase) } 'contentDigest changed'
  $manifestEdited = Copy-LockRow $publishedRow
  $manifestEdited.manifestSha256 = ('8' * 64)
  Assert-Throws { Assert-VersionsLockPrefix @($manifestEdited) @($publishBase) } 'manifestSha256 changed'
  $commitEdited = Copy-LockRow $publishedRow
  $commitEdited.sourceCommit = ('a' * 40)
  Assert-Throws { Assert-VersionsLockPrefix @($commitEdited) @($publishBase) } 'sourceCommit changed'
  $runEdited = Copy-LockRow $publishedRow
  $runEdited.workflowRunId = '1'
  Assert-Throws { Assert-VersionsLockPrefix @($runEdited) @($publishBase) } 'workflowRunId changed'
  $tagEdited = Copy-LockRow $publishedRow
  $tagEdited.tag = 'bmw-v9.9.9'
  Assert-Throws { Assert-VersionsLockPrefix @($tagEdited) @($publishBase) } 'tag changed'
  $noteEdited = Copy-LockRow $publishedRow
  $noteEdited.note = 'changed'
  Assert-Throws { Assert-VersionsLockPrefix @($noteEdited) @($publishBase) } 'note changed'
  $lockedPublish = Copy-LockRow $publishedRow
  $undonePublish = Copy-LockRow $publishedRow
  $undonePublish.published = $false
  Assert-Throws { Assert-VersionsLockPrefix @($undonePublish) @($lockedPublish) } 'published changed'
  $hashAfterLock = Copy-LockRow $lockedPublish
  $hashAfterLock.zipSha256 = ('f' * 64)
  Assert-Throws { Assert-VersionsLockPrefix @($hashAfterLock) @($lockedPublish) } 'zipSha256 changed'
  $unknownPublish = Copy-LockRow $publishedRow
  $unknownPublish | Add-Member -NotePropertyName extra -NotePropertyValue 1
  Assert-Throws { Assert-VersionsLockPrefix @($unknownPublish) @($publishBase) } 'fields changed'
  $barePublish = Copy-LockRow $publishBase
  $barePublish.published = $true
  Assert-Throws { Assert-VersionsLockPrefix @($barePublish) @($publishBase) } 'publish record is incomplete'
  $nullPublishBase = Copy-LockRow $publishBase
  $nullPublishBase.published = $null
  Assert-Throws { Assert-VersionsLockPrefix @(Add-LockPublishRecord $nullPublishBase) @($nullPublishBase) } 'fields changed'
  $badTarget = Copy-LockRow $publishedRow
  $badTarget.releaseTarget = ('E' * 40)
  Assert-Throws { Assert-VersionsLockPrefix @($badTarget) @($publishBase) } 'releaseTarget must be 40 lowercase hex'

  # Existing rows are compared to the base branch. A pull request cannot edit that baseline.
  # The only in-place edit is published false to true, plus the publish-record fields.
  # Local runs that are not pull requests fall back to the copy below. New rows after the baseline
  # must use the brand prefix plus the version, such as bmw-v1.0.3-beta.1.
  # contentDigest, zipSha256, and manifestSha256 must be 64 lowercase hex characters.
  # The match is the whole string, so 64 hex characters plus a trailing newline is rejected.
  # Historical bare v tags stay inside the baseline and are exempt.
  $lock = Get-Content -LiteralPath (Join-Path $repo 'releases/versions.lock.json') -Raw | ConvertFrom-Json
  Assert-True ([string]$lock.schema -eq 'diagnostic-workstation.versions.lock/v1') 'versions lock schema'
  Assert-True ($lock.appendOnly -eq $true) 'versions lock must stay append-only'
  Assert-True ($lock.note -match 'not build provenance') 'versions lock note must say sourceCommit is not build provenance'
  $baseName = 'main'
  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_BASE_REF)) { $baseName = $env:GITHUB_BASE_REF }
  $baseLock = Get-VersionsLockFromGit $baseName
  $lockExpected = $null
  if ($baseLock) {
    $lockExpected = @($baseLock.entries)
  } else {
  $lockExpected = @(
    [pscustomobject]@{ brand = 'bmw'; version = '1.0.1-beta.5'; tag = 'v1.0.1-beta.5'; contentDigest = $null; zipSha256 = '20e0f50cb73b72c5d3ebdcfe5302ac0b111916d01d6f9900bd5bc548e3c11cc3'; zipBytes = 15770; manifestSha256 = 'ca0aaf2a7b9b703f2b6264787a9b07df3d83bcb77059df7a0732150e7ebbc620'; manifestBytes = 142; fileCount = 5; sourceCommit = 'b072d0ebf0102e8bc06312d598cc0637fb900ad3'; workflowRunId = $null; historical = $true; neverReMint = $true; voided = $false; published = $true; note = $null },
    [pscustomobject]@{ brand = 'mercedes'; version = '0.1.2-beta.1'; tag = $null; contentDigest = $null; zipSha256 = $null; zipBytes = $null; manifestSha256 = $null; manifestBytes = $null; fileCount = $null; sourceCommit = $null; workflowRunId = $null; historical = $true; neverReMint = $true; voided = $false; published = $null; note = 'hash not recorded; tag not recorded' },
    [pscustomobject]@{ brand = 'mercedes'; version = '0.1.3-beta.1'; tag = 'mercedes-v0.1.3-beta.1'; contentDigest = $null; zipSha256 = '17a3a1d81d613db216e4a9b939ee7dccac0b8b1c7a19133fc4b02d0d911e5db2'; zipBytes = 1507918; manifestSha256 = 'fc1a063d9a78eef292a78e99e9c292f53c209927d7e734a2b49355739a33250f'; manifestBytes = 4562; fileCount = 28; sourceCommit = 'c9204ac49ff4ffe1fd5943bccecc270b2c3f7337'; workflowRunId = $null; historical = $true; neverReMint = $true; voided = $false; published = $true; note = $null },
    [pscustomobject]@{ brand = 'mercedes'; version = '0.1.3-beta.2'; tag = 'mercedes-v0.1.3-beta.2'; contentDigest = $null; zipSha256 = 'be8fbfe5164ae8e511965d23f163644fb0166b6c7febffbc041d15e4a261d773'; zipBytes = 1509019; manifestSha256 = '60c975f309428d7569058357f610afa323cb5c50400bc3a5115f6a548f529b82'; manifestBytes = 4562; fileCount = 28; sourceCommit = '39311441216a1d60f42aaf9832f5c1fafe1405ec'; workflowRunId = $null; historical = $true; neverReMint = $true; voided = $false; published = $true; note = $null },
    [pscustomobject]@{ brand = 'mercedes'; version = '0.1.3-beta.3'; tag = 'mercedes-v0.1.3-beta.3'; contentDigest = 'af87858cc58bf0f66cd379ff88cdb07f9508b1e6490275a02cea9d483e58af67'; zipSha256 = '0d4ae7771c5e3d6a970f155f498cba3b5a37eb19933cdbf665ca93680202dd9a'; zipBytes = 1416210; manifestSha256 = 'fd9118ca903f620b4fcf7fcb12e0a827bd4d5357626460bc9b83b9d871c17528'; manifestBytes = 3338; fileCount = 20; sourceCommit = '7b6befdfcb3d501a8b2f29b240adcb58df897fc5'; workflowRunId = '39087424705'; historical = $true; neverReMint = $true; voided = $true; published = $false; note = 'Built from 7b6befdf as run 39087424705, never tagged or published. Voided because WorkstationManager.exe embedded all brand logos. To be superseded by a later build (planned 0.1.3-beta.4).' },
    [pscustomobject]@{ brand = 'bmw'; version = '1.0.2-beta.1'; tag = 'bmw-v1.0.2-beta.1'; contentDigest = 'e07829490aff1f4de7ae919fb9d2cd86f4ddc64ed684c5d1e14d1537753b5cd9'; zipSha256 = '77bf2e85b4192d0485d79e82a256a68494b673c99c67eb81f62f194e94c69978'; zipBytes = 48955; manifestSha256 = '82075f0f9751191eb3547fba2e05868ef656b6f567c5eeede5b62cd4c90d1136'; manifestBytes = 2554; fileCount = 15; sourceCommit = '7b6befdfcb3d501a8b2f29b240adcb58df897fc5'; workflowRunId = '39087426283'; historical = $false; neverReMint = $true; voided = $false; published = $false; note = $null },
    [pscustomobject]@{ brand = 'bmw'; version = '1.0.1-beta.1'; tag = 'v1.0.1-beta.1'; contentDigest = $null; zipSha256 = 'ba9ee12f23a9043196788d4fc7778971f86bc360dcee0a2e26cb20dc687d0eea'; zipBytes = 14323; manifestSha256 = '9cc8b683feed58593744b270824bb524ba823a423a2e50da7acacf4c1ef240de'; manifestBytes = 185; fileCount = 5; sourceCommit = '186efe7531a6019dff2ebec56823de367d780a52'; workflowRunId = $null; historical = $true; neverReMint = $true; voided = $false; published = $true; note = $null },
    [pscustomobject]@{ brand = 'bmw'; version = '1.0.1-beta.2'; tag = 'v1.0.1-beta.2'; contentDigest = $null; zipSha256 = 'd9ed100f4da72dfce1669ae5471134d3f24d59ee0854daf11209cd434892d2b2'; zipBytes = 14468; manifestSha256 = '720516f77ca3d6725f5296471b12c506558eb89910c4c8e1ad16ef5ff16d7379'; manifestBytes = 185; fileCount = 5; sourceCommit = '186efe7531a6019dff2ebec56823de367d780a52'; workflowRunId = $null; historical = $true; neverReMint = $true; voided = $false; published = $true; note = $null },
    [pscustomobject]@{ brand = 'bmw'; version = '1.0.1-beta.3'; tag = 'v1.0.1-beta.3'; contentDigest = $null; zipSha256 = '2dcb3d16abb73778c5983a579125d76ceba84694c7531768987be90a77673a15'; zipBytes = 14427; manifestSha256 = '7ca65fed48f9ef990c36eabbfb1b723f481b02b7825ffbbda2e8305c5afe06e8'; manifestBytes = 185; fileCount = 5; sourceCommit = '186efe7531a6019dff2ebec56823de367d780a52'; workflowRunId = $null; historical = $true; neverReMint = $true; voided = $false; published = $true; note = $null },
    [pscustomobject]@{ brand = 'bmw'; version = '1.0.1-beta.4'; tag = 'v1.0.1-beta.4'; contentDigest = $null; zipSha256 = '7e9ba028d09dabe49b68de72aa0c0daf1036c18ef107bac52bca3296df076186'; zipBytes = 14643; manifestSha256 = '68ab06ec6e99310ea652bb5d782f96514dd4b8269fdd44f2389f2571feefafd1'; manifestBytes = 141; fileCount = 5; sourceCommit = '2c0034759611f49cf1521aa3d8659c3d40ed628f'; workflowRunId = $null; historical = $true; neverReMint = $true; voided = $false; published = $true; note = $null },
    [pscustomobject]@{ brand = 'mercedes'; version = '0.1.3-beta.4'; tag = 'mercedes-v0.1.3-beta.4'; contentDigest = 'b43616e9f62b1c254115eab33bbce36eeaf410b60e1de723f3125d18a5267779'; zipSha256 = 'ac8a82c0052cd1718cc050c5e28418efe5ed7afea104baaeb0940fcc612f661a'; zipBytes = 1321743; manifestSha256 = '8c5d857933654bcbfa5bc84140c513d2c3d83863e2e3c0cf956c7471891abdc9'; manifestBytes = 3338; fileCount = 20; sourceCommit = '2b138bf07b0b083615a76a7c16da5e27f16b75e8'; workflowRunId = '39091982618'; historical = $false; neverReMint = $true; voided = $false; published = $false; note = 'Pinned in catalog serial 3 from Actions run 39091982618. Not tagged and not published.' }
  )
  }
  $lockEntries = @($lock.entries)
  Assert-VersionsLockPrefix $lockEntries $lockExpected
  Assert-LockRowIdentities $lockEntries
  $appendedFieldKey = Get-LockFieldKey $lockExpected[0]
  for ($i = $lockExpected.Count; $i -lt $lockEntries.Count; $i++) {
    Assert-NewLockRow $lockEntries[$i] $i $appendedFieldKey
  }
  $beta4Lock = $null
  $beta4Index = -1
  for ($beta4Index = 0; $beta4Index -lt $lockEntries.Count; $beta4Index++) {
    if ([string]$lockEntries[$beta4Index].brand -ceq 'mercedes' -and [string]$lockEntries[$beta4Index].version -ceq '0.1.3-beta.4') {
      $beta4Lock = $lockEntries[$beta4Index]
      break
    }
  }
  Assert-True ($null -ne $beta4Lock) 'mercedes beta.4 lock row is missing'
  Assert-NewLockRow (Select-LockCoreRow $beta4Lock) $beta4Index $appendedFieldKey
  Assert-PublishRecordValues $beta4Lock $beta4Index
  Assert-True ([string]$beta4Lock.tag -ceq 'mercedes-v0.1.3-beta.4' -and [string]$beta4Lock.workflowRunId -ceq '39091982618' -and [string]$beta4Lock.zipSha256 -ceq [string]$mercedesPin.sha256 -and [string]$beta4Lock.manifestSha256 -ceq [string]$mercedesPin.manifestSha256) 'mercedes beta.4 lock row does not match the catalog pin'
  Assert-True ($beta4Lock.published -ceq $true -and [int64]$beta4Lock.releaseId -eq 416761930 -and (Test-PublishTimestampEqual $beta4Lock.publishedAt '2026-10-18T23:03:34Z') -and [string]$beta4Lock.releaseTarget -ceq '2b138bf07b0b083615a76a7c16da5e27f16b75e8' -and [int64]$beta4Lock.workstationZipAssetId -eq 654691137 -and [int64]$beta4Lock.updateManifestAssetId -eq 654691138) 'mercedes beta.4 publish record is wrong'
  Assert-True ([string]$beta4Lock.sourceCommit -ceq '2b138bf07b0b083615a76a7c16da5e27f16b75e8' -and [string]$beta4Lock.note -ceq 'Pinned in catalog serial 3 from Actions run 39091982618. Not tagged and not published.') 'mercedes beta.4 identity fields were rewritten'
  Assert-True ($lockEntries[4].voided -ceq $true -and $lockEntries[4].published -ceq $false -and $lockEntries[4].historical -ceq $true) 'mercedes beta.3 lock row is not voided'
  Assert-True ($lockEntries[5].zipSha256 -ceq [string]$bmwPin.sha256 -and $lockEntries[5].manifestSha256 -ceq [string]$bmwPin.manifestSha256 -and [int64]$lockEntries[5].zipBytes -ceq [int64]$bmwPin.bytes -and [int64]$lockEntries[5].manifestBytes -ceq [int64]$bmwPin.manifestBytes) 'bmw lock does not match the catalog pin'
  Assert-PublishRecordValues $lockEntries[5] 5
  Assert-True ($lockEntries[5].published -ceq $true -and [string]$lockEntries[5].version -ceq '1.0.2-beta.1' -and [string]$lockEntries[5].tag -ceq 'bmw-v1.0.2-beta.1' -and [string]$lockEntries[5].sourceCommit -ceq '7b6befdfcb3d501a8b2f29b240adcb58df897fc5' -and [string]$lockEntries[5].workflowRunId -ceq '39087426283' -and [int64]$lockEntries[5].releaseId -eq 416761964 -and (Test-PublishTimestampEqual $lockEntries[5].publishedAt '2026-10-18T23:03:37Z') -and [string]$lockEntries[5].releaseTarget -ceq '7b6befdfcb3d501a8b2f29b240adcb58df897fc5' -and [int64]$lockEntries[5].workstationZipAssetId -eq 654691267 -and [int64]$lockEntries[5].updateManifestAssetId -eq 654691268 -and $null -eq $lockEntries[5].note) 'bmw publish record is wrong'

  Write-Output 'Master installer checks passed.'
} catch {
  Write-Output $_.Exception.Message
  if ($_.ScriptStackTrace) { Write-Output $_.ScriptStackTrace }
  exit 1
} finally {
  Remove-Item Env:\MASTER_INSTALLER_FORBID_TOOL_EXECUTION -ErrorAction SilentlyContinue
  if (Test-Path $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
