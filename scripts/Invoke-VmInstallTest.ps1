# Hosted VM install test for the master installer. Windows PowerShell 5.1.
# Runs Install-Master.ps1 -Source <offline> -OfflineOnly and records PASS, FAIL, NOT PROVEN, or NOT RUN.
# NOT PROVEN and NOT RUN do not fail the job. Any FAIL does.
# A brand with no catalog pin is NOT RUN. It is tested once a release is pinned.
# main pins mercedes-v0.1.3-beta.4 and bmw-v1.0.2-beta.1, so both brands run when their artifact run ids are supplied.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$RepoRoot,
  [Parameter(Mandatory = $true)][string]$ReportDir,
  [string]$CatalogRef = '',
  [string]$MercedesRunId = '',
  [string]$BmwRunId = ''
)

$ErrorActionPreference = 'Stop'
# The workflow commit is the harness checkout. catalog_ref is the catalog checkout.
# Copy this commit's installer onto the catalog checkout so the run uses the harness
# installer and the catalog_ref catalog together. A single-checkout run is unchanged.
$script:HarnessRepo = Split-Path -Parent $PSScriptRoot
$harnessMaster = Join-Path $script:HarnessRepo 'installer\Master'
$catalogMaster = Join-Path $RepoRoot 'installer\Master'
if ((Test-Path -LiteralPath $harnessMaster) -and (Test-Path -LiteralPath (Join-Path $harnessMaster 'Install-Master.ps1'))) {
  $harnessFull = [System.IO.Path]::GetFullPath($harnessMaster)
  $catalogFull = [System.IO.Path]::GetFullPath($catalogMaster)
  if ($harnessFull -ne $catalogFull) {
    if (Test-Path -LiteralPath $catalogMaster) { Remove-Item -LiteralPath $catalogMaster -Recurse -Force }
    $catalogParent = Split-Path -Parent $catalogMaster
    if (-not (Test-Path -LiteralPath $catalogParent)) { New-Item -ItemType Directory -Force -Path $catalogParent | Out-Null }
    Copy-Item -LiteralPath $harnessMaster -Destination $catalogMaster -Recurse -Force
  }
}
if ($PSVersionTable.PSVersion.Major -ne 5) {
  throw 'Invoke-VmInstallTest.ps1 must run on Windows PowerShell 5.1 (powershell.exe), not pwsh.'
}
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
  throw 'Invoke-VmInstallTest.ps1 must run in an STA thread. Start it with powershell.exe -STA.'
}

$script:Results = @()
$script:InstallerData = Join-Path $env:LOCALAPPDATA 'DiagnosticWorkstation-Installer'
$script:JournalPath = Join-Path $script:InstallerData 'logs\install-journal.log'
$script:PowershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:InstallTimeoutMs = 600000

. (Join-Path $RepoRoot 'installer\Master\lib\Common.ps1')
. (Join-Path $RepoRoot 'installer\Master\lib\Catalog.ps1')
. (Join-Path $RepoRoot 'installer\Master\lib\Defender.ps1')

function Add-Check([string]$Brand, [string]$Id, [string]$Status, [string]$Detail) {
  $script:Results += [pscustomobject]@{
    Brand = $Brand
    Id = $Id
    Status = $Status
    Detail = $Detail
  }
  Write-Output ("{0} {1} {2}: {3}" -f $Status, $Brand, $Id, $Detail)
}

function Get-CombinedStatus($Parts) {
  foreach ($part in @($Parts)) {
    if ($part.Status -eq 'FAIL') { return 'FAIL' }
  }
  foreach ($part in @($Parts)) {
    if ($part.Status -eq 'NOT PROVEN') { return 'NOT PROVEN' }
  }
  return 'PASS'
}

function Format-PartDetail($Parts) {
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($part in @($Parts)) {
    $lines.Add(('{0}: {1}' -f $part.Status, $part.Detail))
  }
  return ($lines -join ' ')
}

function Add-CombinedCheck([string]$Brand, [string]$Id, $Parts) {
  Add-Check $Brand $Id (Get-CombinedStatus $Parts) (Format-PartDetail $Parts)
}

function New-Part([string]$Status, [string]$Detail) {
  return [pscustomobject]@{ Status = $Status; Detail = $Detail }
}

function Format-PsArg([string]$Text) {
  if ($Text -match '[\s"]') { return '"' + ($Text.Replace('"', '\"')) + '"' }
  return $Text
}

function Get-HexSha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Join-Rel([string]$Root, [string]$Relative) {
  $path = $Root
  foreach ($part in ($Relative -split '/')) {
    if (-not [string]::IsNullOrWhiteSpace($part)) { $path = Join-Path $path $part }
  }
  return $path
}

function Test-SameHash([string]$LeftPath, [string]$RightPath) {
  if (-not (Test-Path -LiteralPath $LeftPath) -or -not (Test-Path -LiteralPath $RightPath)) { return $false }
  return (Get-HexSha256 $LeftPath) -eq (Get-HexSha256 $RightPath)
}

function Read-ZipEntryBytes([string]$ZipPath, [string]$EntryName) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    $entry = $zip.GetEntry($EntryName)
    if (-not $entry) { throw "zip is missing $EntryName" }
    $stream = $entry.Open()
    try {
      $memory = New-Object System.IO.MemoryStream
      $stream.CopyTo($memory)
      return $memory.ToArray()
    } finally { $stream.Dispose() }
  } finally { $zip.Dispose() }
}

function Get-JournalCount {
  if (-not (Test-Path -LiteralPath $script:JournalPath)) { return 0 }
  return @([System.IO.File]::ReadAllLines($script:JournalPath)).Count
}

function Read-NewJournal([int]$StartCount) {
  $events = @()
  if (-not (Test-Path -LiteralPath $script:JournalPath)) { return $events }
  $lines = @([System.IO.File]::ReadAllLines($script:JournalPath))
  for ($i = $StartCount; $i -lt $lines.Count; $i++) {
    if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
    try { $events += ($lines[$i] | ConvertFrom-Json) } catch { }
  }
  return $events
}

function Clear-BrandTree([string]$Root) {
  $parent = Split-Path -Parent $Root
  $leaf = Split-Path -Leaf $Root
  if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
  if (-not (Test-Path -LiteralPath $parent)) { return }
  Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -like ($leaf + '.prev-*') -or $_.Name -like ($leaf + '.failed-*') -or $_.Name -like '.staging-*'
  } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-TreeFingerprint([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return 'MISSING' }
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName)) {
    $relative = $file.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
    $lines.Add(($relative + '=' + (Get-HexSha256 $file.FullName))) | Out-Null
  }
  return (($lines.ToArray()) -join "`n")
}

function Get-InstallResidue([string]$Root) {
  $parent = Split-Path -Parent $Root
  $leaf = Split-Path -Leaf $Root
  if (-not (Test-Path -LiteralPath $parent)) { return '' }
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($item in @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
    if ($item.Name -like ($leaf + '.prev-*') -or $item.Name -like ($leaf + '.failed-*') -or $item.Name -like '.staging-*') {
      $names.Add($item.Name) | Out-Null
    }
  }
  return (($names.ToArray()) -join "`n")
}

function Get-SiblingBrandFingerprint([string]$BrandId) {
  $other = 'bmw'
  if ($BrandId -eq 'bmw') { $other = 'mercedes' }
  return (Get-TreeFingerprint (Resolve-BrandInstallRoot $other))
}

function Get-StartupSnapshot {
  $lines = New-Object System.Collections.Generic.List[string]
  $paths = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon',
    'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'
  )
  $skip = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
  foreach ($path in $paths) {
    if (-not (Test-Path -LiteralPath $path)) {
      $lines.Add($path + '|MISSING')
      continue
    }
    $item = Get-ItemProperty -LiteralPath $path
    foreach ($prop in $item.PSObject.Properties) {
      if ($skip -contains $prop.Name) { continue }
      $lines.Add(('{0}|{1}|{2}' -f $path, $prop.Name, [string]$prop.Value))
    }
  }
  return ((@($lines) | Sort-Object) -join "`n")
}

function Get-PolicyImage($Plan) {
  $rows = @()
  foreach ($item in @($Plan.Policies)) {
    $exists = $false
    $value = $null
    $readable = $true
    try {
      $property = Get-ItemProperty -Path $item.Path -Name $item.Name -ErrorAction Stop
      $exists = $true
      $value = $property.($item.Name)
    } catch {
      $message = $_.Exception.Message
      if ($message -match '(?i)does not exist|cannot find path|cannot find property') {
        $exists = $false
        $readable = $true
      } else {
        $readable = $false
      }
    }
    $rows += [pscustomobject]@{ Path = [string]$item.Path; Name = [string]$item.Name; Exists = $exists; Value = $value; Readable = $readable }
  }
  return $rows
}

function Get-ServiceImage {
  $rows = @()
  foreach ($name in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')) {
    try {
      $service = Get-Service -Name $name -ErrorAction Stop
      $rows += [pscustomobject]@{ Name = $name; Status = [string]$service.Status; Readable = $true }
    } catch {
      $rows += [pscustomobject]@{ Name = $name; Status = 'unreadable'; Readable = $false }
    }
  }
  return $rows
}

function Test-DefenderPreferenceReadable {
  try {
    $null = Get-Command Get-MpPreference -ErrorAction Stop
    $null = Get-MpPreference -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

function Get-PreferenceImage($Plan) {
  $image = @{}
  $pref = $null
  try { $pref = Get-MpPreference -ErrorAction Stop } catch { return $null }
  foreach ($item in @($Plan.Preferences)) {
    $value = $null
    $present = $false
    if ($pref -and ($pref.PSObject.Properties.Name -contains $item.Name)) {
      $present = $true
      $value = $pref.($item.Name)
    }
    $image[$item.Name] = [pscustomobject]@{ Present = $present; Value = $value; ExpectedDisable = $item.Disable }
  }
  return $image
}

function Test-PreferenceMatch($Actual, $Expected) {
  if ($null -eq $Actual -or $null -eq $Expected) { return $false }
  if ($Expected -is [bool] -or $Actual -is [bool]) {
    try { return ([bool]$Actual) -eq ([bool]$Expected) } catch { return $false }
  }
  try { return ([int]$Actual) -eq ([int]$Expected) } catch { return $false }
}

function Format-PolicyImage($Rows) {
  $bits = @()
  foreach ($row in @($Rows)) {
    if (-not $row.Readable) { $bits += ($row.Name + '=unreadable') }
    elseif (-not $row.Exists) { $bits += ($row.Name + '=absent') }
    else { $bits += ('{0}={1}' -f $row.Name, $row.Value) }
  }
  return ($bits -join ', ')
}

function Test-PolicyImageEqual($Left, $Right) {
  if (@($Left).Count -ne @($Right).Count) { return $false }
  for ($i = 0; $i -lt @($Left).Count; $i++) {
    if (-not $Left[$i].Readable -or -not $Right[$i].Readable) { return $false }
    if ([bool]$Left[$i].Exists -ne [bool]$Right[$i].Exists) { return $false }
    if ($Left[$i].Exists) {
      try {
        if ([int]$Left[$i].Value -ne [int]$Right[$i].Value) { return $false }
      } catch { return $false }
    }
  }
  return $true
}

function Invoke-NativePowerShell {
  param([string]$File, [string[]]$Arguments, [string]$LogStem, [int]$TimeoutMs)
  $pieces = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Format-PsArg $File))
  foreach ($arg in @($Arguments)) { $pieces += (Format-PsArg ([string]$arg)) }
  $stdout = $LogStem + '.stdout.txt'
  $stderr = $LogStem + '.stderr.txt'
  foreach ($path in @($stdout, $stderr)) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:PowershellExe
  $psi.Arguments = ($pieces -join ' ')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  [void]$process.Start()
  $outTask = $process.StandardOutput.ReadToEndAsync()
  $errTask = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit($TimeoutMs)) {
    try { $process.Kill() } catch { }
    [System.IO.File]::WriteAllText($stdout, 'TIMED OUT')
    return -1
  }
  $process.WaitForExit()
  [System.IO.File]::WriteAllText($stdout, $outTask.Result)
  [System.IO.File]::WriteAllText($stderr, $errTask.Result)
  return [int]$process.ExitCode
}

function Read-InstallerOutput([string]$LogStem) {
  $text = ''
  foreach ($suffix in @('.stdout.txt', '.stderr.txt')) {
    $path = $LogStem + $suffix
    if (Test-Path -LiteralPath $path) { $text = $text + [System.IO.File]::ReadAllText($path) }
  }
  return (($text -replace '\s+', ' ').Trim())
}

function Invoke-BrandInstall([string]$BrandId, [string]$TagName, [string]$SourcePath, [string]$LogStem) {
  $installArgs = @('-Brand', $BrandId, '-Channel', 'beta', '-Tag', $TagName, '-Source', $SourcePath, '-OfflineOnly')
  $code = Invoke-NativePowerShell -File (Join-Path $RepoRoot 'installer\Master\Install-Master.ps1') -Arguments $installArgs -LogStem $LogStem -TimeoutMs $script:InstallTimeoutMs
  return [pscustomobject]@{ Code = $code; Text = (Read-InstallerOutput $LogStem) }
}

function Remove-InstallProgress {
  $progressPath = Join-Path $script:InstallerData 'install-in-progress.json'
  if (Test-Path -LiteralPath $progressPath) { Remove-Item -LiteralPath $progressPath -Force }
}

function Add-UnpinnedTagCheck([string]$BrandId, [string]$TagPrefix, [string]$SourcePath, [string]$Root) {
  Remove-InstallProgress
  Clear-BrandTree $Root
  $rejectedTag = $TagPrefix + '9.9.9'
  $logStem = Join-Path $ReportDir ($BrandId + '-unpinned-tag')
  $result = Invoke-BrandInstall $BrandId $rejectedTag $SourcePath $logStem
  $rootExists = Test-Path -LiteralPath $Root
  $residue = Get-InstallResidue $Root
  $expected = 'No approved'
  if ($result.Code -eq 0 -or $result.Code -eq -1 -or $rootExists -or $result.Text -notmatch $expected -or -not [string]::IsNullOrEmpty($residue)) {
    Add-Check $BrandId 'unpinned-tag' 'FAIL' ("tag {0} exit {1} rootExists={2} residue='{3}'. expected '{4}'. {5}" -f $rejectedTag, $result.Code, $rootExists, $residue, $expected, $result.Text)
  } else {
    Add-Check $BrandId 'unpinned-tag' 'PASS' ("unpinned tag {0} was rejected with '{1}' and exit {2}, the brand folder was not created, and no .staging-* leftover was present" -f $rejectedTag, $expected, $result.Code)
  }
  Remove-InstallProgress
  Clear-BrandTree $Root
}

function Add-WrongTargetCheck([string]$BrandId, [string]$TagName, [string]$SourcePath, [string]$Root) {
  Remove-InstallProgress
  Clear-BrandTree $Root
  $foreign = 'mercedes'
  if ($BrandId -eq 'mercedes') { $foreign = 'bmw' }
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $markerPath = Join-Path $Root '.installed-bundle.json'
  $markerText = '{"schema":"diagnostic-workstation.installed-bundle/v1","brand":"' + $foreign + '","tag":"foreign","version":"0.0.0"}' + "`n"
  [System.IO.File]::WriteAllText($markerPath, $markerText)
  [System.IO.File]::WriteAllText((Join-Path $Root 'Launcher.ps1'), "Write-Output 'foreign-live'`n")
  $lockPath = Join-Path $Root 'install-in-progress.lock'
  [System.IO.File]::WriteAllText($lockPath, "other-run lock`n")
  $beforeLock = Get-HexSha256 $lockPath
  $beforeTree = Get-TreeFingerprint $Root
  $beforeResidue = Get-InstallResidue $Root
  $beforeSibling = Get-SiblingBrandFingerprint $BrandId
  $logStem = Join-Path $ReportDir ($BrandId + '-wrong-target')
  $result = Invoke-BrandInstall $BrandId $TagName $SourcePath $logStem
  $afterTree = Get-TreeFingerprint $Root
  $afterResidue = Get-InstallResidue $Root
  $afterSibling = Get-SiblingBrandFingerprint $BrandId
  $stillForeign = $false
  if (Test-Path -LiteralPath $markerPath) {
    $stillForeign = [string](Read-JsonFile $markerPath).brand -eq $foreign
  }
  $lockSame = $false
  if (Test-Path -LiteralPath $lockPath) { $lockSame = (Get-HexSha256 $lockPath) -ceq $beforeLock }
  $unchanged = ($beforeTree -ceq $afterTree) -and ($beforeResidue -ceq $afterResidue) -and ($beforeSibling -ceq $afterSibling)
  $noStaging = [string]::IsNullOrEmpty($afterResidue)
  $expected = 'belongs to'
  if ($result.Code -eq 0 -or $result.Code -eq -1 -or $result.Text -notmatch $expected -or -not $stillForeign -or -not $lockSame -or -not $unchanged -or -not $noStaging) {
    Add-Check $BrandId 'wrong-target' 'FAIL' ("foreign {0} marker exit {1} stillForeign={2} lockSame={3} unchanged={4} residue='{5}'. expected '{6}'. {7}" -f $foreign, $result.Code, $stillForeign, $lockSame, $unchanged, $afterResidue, $expected, $result.Text)
  } else {
    Add-Check $BrandId 'wrong-target' 'PASS' ("install into a {0} folder was rejected with '{1}' and exit {2}. The foreign tree and its pre-existing install-in-progress.lock stayed byte-identical, and no .staging-* leftover was present" -f $foreign, $expected, $result.Code)
  }
  Remove-InstallProgress
  Clear-BrandTree $Root
}

function Write-HarnessLockFile([string]$Path, [int]$OwnerPid, [string]$OwnerStartUtc, [string]$Nonce, [string]$CreatedUtc) {
  $record = [ordered]@{
    schema = 'diagnostic-workstation.install-lock/v1'
    ownerPid = $OwnerPid
    ownerStartUtc = $OwnerStartUtc
    nonce = $Nonce
    createdUtc = $CreatedUtc
  }
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, (($record | ConvertTo-Json -Compress) + "`n"), $utf8)
}

function Write-SameBrandTree([string]$Root, [string]$BrandId, [string]$TagName, [string]$Version) {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $utf8 = New-Object System.Text.UTF8Encoding $false
  $markerText = '{"schema":"diagnostic-workstation.installed-bundle/v1","brand":"' + $BrandId + '","tag":"' + $TagName + '","version":"' + $Version + '"}' + "`n"
  [System.IO.File]::WriteAllText((Join-Path $Root '.installed-bundle.json'), $markerText, $utf8)
  [System.IO.File]::WriteAllText((Join-Path $Root 'Launcher.ps1'), "Write-Output 'held-tree'`n", $utf8)
}

function Add-LiveLockCheck([string]$BrandId, [string]$TagName, [string]$Version, [string]$SourcePath, [string]$Root) {
  Remove-InstallProgress
  Clear-BrandTree $Root
  $owner = $null
  try {
    Write-SameBrandTree $Root $BrandId $TagName $Version
    $owner = Start-Process -FilePath $script:PowershellExe -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-Command', 'Start-Sleep -Seconds 3600') -WindowStyle Hidden -PassThru
    if ($null -eq $owner) { throw 'live lock owner did not start' }
    $startText = ''
    try { $startText = $owner.StartTime.ToUniversalTime().ToString('o') } catch { $startText = '' }
    $lockPath = Join-Path $Root 'install-in-progress.lock'
    Write-HarnessLockFile $lockPath ([int]$owner.Id) $startText ('ab' * 16) ([datetimeoffset]::UtcNow.ToString('o'))
    $beforeLock = Get-HexSha256 $lockPath
    $beforeTree = Get-TreeFingerprint $Root
    $logStem = Join-Path $ReportDir ($BrandId + '-live-lock')
    $result = Invoke-BrandInstall $BrandId $TagName $SourcePath $logStem
    $afterTree = Get-TreeFingerprint $Root
    $residue = Get-InstallResidue $Root
    $lockSame = $false
    if (Test-Path -LiteralPath $lockPath) { $lockSame = (Get-HexSha256 $lockPath) -ceq $beforeLock }
    $unchanged = ($beforeTree -ceq $afterTree) -and ($beforeTree -ne 'MISSING')
    $clean = [string]::IsNullOrEmpty($residue)
    $expected = 'already holds install-in-progress.lock'
    if ($result.Code -eq 0 -or $result.Code -eq -1 -or $result.Text -notmatch $expected -or -not $lockSame -or -not $unchanged -or -not $clean) {
      Add-Check $BrandId 'live-lock' 'FAIL' ("live lock exit {0} lockSame={1} unchanged={2} residue='{3}'. expected '{4}'. {5}" -f $result.Code, $lockSame, $unchanged, $residue, $expected, $result.Text)
    } else {
      Add-Check $BrandId 'live-lock' 'PASS' ("a same-brand install refused a live install-in-progress.lock with '{0}' and exit {1}. The tree and lock stayed byte-identical, and no residue was left." -f $expected, $result.Code)
    }
  } catch {
    Add-Check $BrandId 'live-lock' 'FAIL' $_.Exception.Message
  } finally {
    if ($owner -and -not $owner.HasExited) {
      try { Stop-Process -Id $owner.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    Remove-InstallProgress
    Clear-BrandTree $Root
  }
}

function Add-StaleLockCheck([string]$BrandId, [string]$TagName, [string]$SourcePath, [string]$Root) {
  Remove-InstallProgress
  Clear-BrandTree $Root
  try {
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Join-Path $Root 'Launcher.ps1'), "Write-Output 'stale-tree'`n", $utf8)
    $lockPath = Join-Path $Root 'install-in-progress.lock'
    Write-HarnessLockFile $lockPath 2147483646 '2020-01-01T00:00:00.0000000Z' ('ef' * 16) ([datetimeoffset]::UtcNow.ToString('o'))
    $journalAt = Get-JournalCount
    $logStem = Join-Path $ReportDir ($BrandId + '-stale-lock')
    $result = Invoke-BrandInstall $BrandId $TagName $SourcePath $logStem
    $events = @(Read-NewJournal $journalAt)
    $reclaimed = $false
    foreach ($event in $events) {
      if ([string]$event.step -eq 'install-lock-reclaimed' -and [string]$event.reason -eq 'dead-pid') { $reclaimed = $true }
    }
    $staleGone = -not (Test-Path -LiteralPath $lockPath)
    if ($result.Code -eq -1 -or -not $reclaimed -or -not $staleGone) {
      Add-Check $BrandId 'stale-lock' 'FAIL' ("stale lock exit {0} reclaimed={1} lockGone={2}. expected journal install-lock-reclaimed reason dead-pid." -f $result.Code, $reclaimed, $staleGone)
    } else {
      Add-Check $BrandId 'stale-lock' 'PASS' ("a dead-pid install-in-progress.lock was reclaimed (journal install-lock-reclaimed reason dead-pid) and the stale lock was not left in place. exit {0}" -f $result.Code)
    }
  } catch {
    Add-Check $BrandId 'stale-lock' 'FAIL' $_.Exception.Message
  } finally {
    Remove-InstallProgress
    Clear-BrandTree $Root
  }
}

function Remove-FailSwapArm {
  $pointer = Join-Path $script:InstallerData 'fail-swap.location'
  $marker = Join-Path $ReportDir 'fail-swap.marker'
  if (Test-Path -LiteralPath $pointer) { Remove-Item -LiteralPath $pointer -Force }
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
}

function Add-InInstallFailureCheck([string]$BrandId, [string]$TagName, [string]$SourcePath, [string]$Root) {
  $installedMarker = Join-Path $Root '.installed-bundle.json'
  if (-not (Test-Path -LiteralPath $installedMarker)) {
    Add-Check $BrandId 'in-install-failure' 'FAIL' 'fresh install has no marker, so the in-install failure was not run'
    Remove-FailSwapArm
    return
  }
  try {
    $beforeTree = Get-TreeFingerprint $Root
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $arm = Join-Path $ReportDir 'fail-swap.marker'
    [System.IO.File]::WriteAllText($arm, "diagnostic-workstation-test-fail-swap`n", $utf8)
    $pointer = Join-Path $script:InstallerData 'fail-swap.location'
    [System.IO.File]::WriteAllText($pointer, ($arm + "`n"), $utf8)
    $logStem = Join-Path $ReportDir ($BrandId + '-in-install-failure')
    $result = Invoke-BrandInstall $BrandId $TagName $SourcePath $logStem
    $afterTree = Get-TreeFingerprint $Root
    $residue = Get-InstallResidue $Root
    $lockPath = Join-Path $Root 'install-in-progress.lock'
    $lockReleased = -not (Test-Path -LiteralPath $lockPath)
    $sameTree = ($beforeTree -ceq $afterTree) -and ($beforeTree -ne 'MISSING')
    $clean = [string]::IsNullOrEmpty($residue)
    $expectedRestore = 'previous folder was restored'
    $expectedCause = 'test-only failure during install swap'
    if ($result.Code -eq 0 -or $result.Code -eq -1 -or $result.Text -notmatch $expectedRestore -or $result.Text -notmatch $expectedCause -or -not $sameTree -or -not $clean -or -not $lockReleased) {
      Add-Check $BrandId 'in-install-failure' 'FAIL' ("in-install failure exit {0} sameTree={1} residue='{2}' lockReleased={3}. expected '{4}'. {5}" -f $result.Code, $sameTree, $residue, $lockReleased, $expectedRestore, $result.Text)
    } else {
      Add-Check $BrandId 'in-install-failure' 'PASS' ("an armed fail-swap.marker failed the swap, restored the previous tree byte for byte, left no residue, and released install-in-progress.lock. exit {0}" -f $result.Code)
    }
  } catch {
    Add-Check $BrandId 'in-install-failure' 'FAIL' $_.Exception.Message
  } finally {
    Remove-FailSwapArm
    Remove-InstallProgress
  }
}

function Get-DisableAntiSpywareImage {
  $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
  $name = 'DisableAntiSpyware'
  try {
    $property = Get-ItemProperty -Path $path -Name $name -ErrorAction Stop
    return [pscustomobject]@{ Readable = $true; Exists = $true; Value = $property.$name }
  } catch {
    $message = $_.Exception.Message
    if ($message -match '(?i)does not exist|cannot find path|cannot find property') {
      return [pscustomobject]@{ Readable = $true; Exists = $false; Value = $null }
    }
    return [pscustomobject]@{ Readable = $false; Exists = $false; Value = $null }
  }
}

function Add-ExtraFilesCheck([string]$BrandId, [string]$Root, $Manifest) {
  $expected = @{}
  foreach ($entry in @($Manifest.files)) {
    $relative = ([string]$entry.path).Replace('\', '/').Trim('/')
    if (-not [string]::IsNullOrWhiteSpace($relative)) { $expected[$relative] = $true }
  }
  $expected['.installed-bundle.json'] = $true
  $extras = New-Object System.Collections.Generic.List[string]
  $missing = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path -LiteralPath $Root)) {
    Add-Check $BrandId 'extra-files' 'FAIL' 'brand root is missing, so the installed tree cannot match the manifest'
    return
  }
  $seen = @{}
  $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force)
  foreach ($file in $files) {
    $relative = $file.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
    $seen[$relative] = $true
    if (-not $expected.ContainsKey($relative)) { $extras.Add($relative) | Out-Null }
  }
  foreach ($relative in @($expected.Keys)) {
    if (-not $seen.ContainsKey($relative)) { $missing.Add($relative) | Out-Null }
  }
  if ($extras.Count -eq 0 -and $missing.Count -eq 0) {
    Add-Check $BrandId 'extra-files' 'PASS' ("installed tree matches the manifest exactly, plus .installed-bundle.json ({0} files)" -f $expected.Count)
  } else {
    Add-Check $BrandId 'extra-files' 'FAIL' ("extra: {0}; missing: {1}" -f ($extras -join ', '), ($missing -join ', '))
  }
}

function Add-InterruptedSwapCheck([string]$BrandId, [string]$TagName, [string]$SourcePath, [string]$Root) {
  $markerPath = Join-Path $Root '.installed-bundle.json'
  if (-not (Test-Path -LiteralPath $markerPath)) {
    Add-Check $BrandId 'interrupted-swap' 'FAIL' 'fresh install has no marker, so interrupted-swap recovery was not run'
    return
  }
  $beforeTree = Get-TreeFingerprint $Root
  $parent = Split-Path -Parent $Root
  $leaf = Split-Path -Leaf $Root
  $prev = Join-Path $parent ($leaf + '.prev-vm-rollback')
  if (Test-Path -LiteralPath $prev) { Remove-Item -LiteralPath $prev -Recurse -Force }
  Rename-Item -LiteralPath $Root -NewName ($leaf + '.prev-vm-rollback')
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $Root 'partial.txt'), 'partial')
  $progressPath = Join-Path $script:InstallerData 'install-in-progress.json'
  $record = [pscustomobject]@{ phase = 'swapping'; brand = $BrandId; root = $Root; prev = $prev; tag = $TagName }
  [System.IO.File]::WriteAllText($progressPath, (($record | ConvertTo-Json -Compress) + "`n"))
  $logStem = Join-Path $ReportDir ($BrandId + '-interrupted-swap')
  $result = Invoke-BrandInstall $BrandId $TagName $SourcePath $logStem
  $afterTree = Get-TreeFingerprint $Root
  $residue = Get-InstallResidue $Root
  $sameTree = ($beforeTree -ceq $afterTree) -and ($beforeTree -ne 'MISSING')
  $clean = [string]::IsNullOrEmpty($residue)
  $expected = 'restored'
  if ($result.Code -eq 0 -or $result.Code -eq -1 -or $result.Text -notmatch $expected -or -not $sameTree -or -not $clean) {
    Add-Check $BrandId 'interrupted-swap' 'FAIL' ("interrupted-swap recovery exit {0} sameTree={1} residue='{2}'. expected '{3}'. {4}" -f $result.Code, $sameTree, $residue, $expected, $result.Text)
  } else {
    Add-Check $BrandId 'interrupted-swap' 'PASS' ("an interrupted swap restored the previous tree byte for byte with exit {0}, including every file hash, and left no .prev-*, .failed-*, or .staging-* residue" -f $result.Code)
  }
  Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -like ($leaf + '.failed-*') -or $_.Name -like ($leaf + '.prev-*') -or $_.Name -like '.staging-*'
  } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

function Add-DowngradeCheck([string]$BrandId, [string]$InstalledTag, [string]$InstalledVersion, [string]$SourcePath, [string]$Root, $Releases) {
  $markerPath = Join-Path $Root '.installed-bundle.json'
  if (-not (Test-Path -LiteralPath $markerPath)) {
    Add-Check $BrandId 'downgrade' 'NOT RUN' 'the pinned install did not create a marker, so an older version was not attempted'
    return
  }
  $older = @()
  foreach ($candidate in @($Releases)) {
    if (-not $candidate) { continue }
    $candidateTag = [string]$candidate.tag
    $candidateVersion = [string]$candidate.version
    if ([string]::IsNullOrWhiteSpace($candidateTag) -or $candidateTag -eq $InstalledTag) { continue }
    try {
      if ((Get-ReleaseRank $candidateVersion) -ge (Get-ReleaseRank $InstalledVersion)) { continue }
    } catch { continue }
    $older += $candidate
  }
  $chosen = $null
  if ($older.Count -gt 0) {
    $orderedOlder = @($older | Sort-Object -Property @{ Expression = { Get-ReleaseRank ([string]$_.version) }; Descending = $true })
    foreach ($candidate in $orderedOlder) {
      $candidateDir = Join-Path $SourcePath ([string]$candidate.tag)
      $zipCandidate = Join-Path $candidateDir 'workstation.zip'
      $manifestCandidate = Join-Path $candidateDir 'update-manifest.json'
      if ((Test-Path -LiteralPath $zipCandidate) -and (Test-Path -LiteralPath $manifestCandidate)) {
        $chosen = $candidate
        break
      }
    }
    if (-not $chosen) {
      $tags = @()
      foreach ($candidate in $orderedOlder) { $tags += [string]$candidate.tag }
      Add-Check $BrandId 'downgrade' 'NOT RUN' ("older approved pin {0} is in the catalog but its bundle artifact was not staged, so the downgrade refusal was not attempted" -f ($tags -join ', '))
      return
    }
  }
  if (-not $chosen) {
    $historical = @()
    $lockPath = Join-Path $RepoRoot 'releases\versions.lock.json'
    if (Test-Path -LiteralPath $lockPath) {
      $lock = Read-JsonFile $lockPath
      foreach ($entry in @($lock.entries)) {
        if (-not $entry) { continue }
        if ([string]$entry.brand -ne $BrandId) { continue }
        $version = [string]$entry.version
        if ([string]::IsNullOrWhiteSpace($version)) { continue }
        try {
          if ((Get-ReleaseRank $version) -ge (Get-ReleaseRank $InstalledVersion)) { continue }
        } catch { continue }
        $label = [string]$entry.tag
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $version }
        $historical += $label
        if ($historical.Count -ge 3) { break }
      }
    }
    $detail = "catalog pins only $InstalledTag. No older approved release is pinned, and no older bundle artifact was staged, so the downgrade refusal was not attempted."
    if ($historical.Count -gt 0) {
      $detail = "catalog pins only $InstalledTag. No older approved release is pinned. Historical older rows ($($historical -join ', ')) are not approved pins and no older bundle artifact was staged, so the downgrade refusal was not attempted."
    }
    Add-Check $BrandId 'downgrade' 'NOT RUN' $detail
    return
  }
  $beforeTree = Get-TreeFingerprint $Root
  $beforeResidue = Get-InstallResidue $Root
  $logStem = Join-Path $ReportDir ($BrandId + '-downgrade')
  $result = Invoke-BrandInstall $BrandId ([string]$chosen.tag) $SourcePath $logStem
  $afterTree = Get-TreeFingerprint $Root
  $afterResidue = Get-InstallResidue $Root
  $sameTree = ($beforeTree -ceq $afterTree) -and ($beforeTree -ne 'MISSING')
  $sameResidue = ($beforeResidue -ceq $afterResidue)
  $expected = 'Refusing to install an older approved version'
  if ($result.Code -eq 0 -or $result.Code -eq -1 -or $result.Text -notmatch $expected -or -not $sameTree -or -not $sameResidue) {
    Add-Check $BrandId 'downgrade' 'FAIL' ("tag {0} exit {1} sameTree={2} residueSame={3}. expected '{4}'. {5}" -f ([string]$chosen.tag), $result.Code, $sameTree, $sameResidue, $expected, $result.Text)
  } else {
    Add-Check $BrandId 'downgrade' 'PASS' ("older pin {0} was refused with '{1}', and the installed tree was unchanged" -f ([string]$chosen.tag), $expected)
  }
}

function Get-ExpectedInstallExit($State) {
  if ([string]$State.windowsUpdate -ne 'disabled') { return 2 }
  if ([string]$State.defender -eq 'tamper-blocked') { return 10 }
  if ([string]$State.defender -ne 'disabled') { return 11 }
  return 0
}

function Get-SecurityState([string]$Brand) {
  $path = Join-Path $script:InstallerData ('security-state-{0}.json' -f $Brand)
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  return Read-JsonFile $path
}

function Remove-SecurityState([string]$Brand) {
  $path = Join-Path $script:InstallerData ('security-state-{0}.json' -f $Brand)
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Get-PinnedRelease($Catalog, [string]$Brand, [string]$Tag) {
  foreach ($item in @($Catalog.brands)) {
    if ([string]$item.id -ne $Brand) { continue }
    foreach ($release in @($item.releases)) {
      if ($release -and [string]$release.tag -eq $Tag) { return $release }
    }
    return $null
  }
  return $null
}

function Get-CatalogBrand($Catalog, [string]$Brand) {
  foreach ($item in @($Catalog.brands)) {
    if ([string]$item.id -eq $Brand) { return $item }
  }
  return $null
}

function Get-BrandReleases($Catalog, [string]$Brand) {
  foreach ($item in @($Catalog.brands)) {
    if ([string]$item.id -ne $Brand) { continue }
    foreach ($release in @($item.releases)) {
      if ($release -and -not [string]::IsNullOrWhiteSpace([string]$release.tag)) {
        Write-Output $release -NoEnumerate
      }
    }
    return
  }
}

function Get-PlaceholderValue([string]$Token, [string]$Expression, [string]$Accent, [string]$AccentSoft) {
  $color = [regex]::Match([string]$Expression, '[''"](?<color>#[0-9A-Fa-f]{8}|#[0-9A-Fa-f]{6}|#[0-9A-Fa-f]{3})[''"]')
  if ($color.Success) { return [string]$color.Groups['color'].Value }
  if ([string]::IsNullOrWhiteSpace($Accent)) { $Accent = '#BBC7D0' }
  if ([string]::IsNullOrWhiteSpace($AccentSoft)) { $AccentSoft = '#E6ECEF' }
  if ($Token -match '(?i)ACCENT_SOFT') { return $AccentSoft }
  if ($Token -match '(?i)ACCENT') { return $Accent }
  if ($Token -match '(?i)BRUSH|COLOR|FOREGROUND|BACKGROUND') { return $Accent }
  return 'Placeholder'
}

function Get-HereStringVariable([string]$Text, $Token) {
  $start = [int]$Token.Extent.StartOffset
  if ($start -le 0) { return $null }
  $from = $start - 240
  if ($from -lt 0) { $from = 0 }
  $prefix = $Text.Substring($from, $start - $from)
  $match = [regex]::Match($prefix, '(?s)(?:\[[A-Za-z][A-Za-z0-9\.]*\]\s*)?\$(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*$')
  if (-not $match.Success) { return $null }
  return [string]$match.Groups['name'].Value
}

function Get-PreparedXaml([string]$Path, [string]$Accent, [string]$AccentSoft) {
  $text = [System.IO.File]::ReadAllText($Path)
  $tokens = $null
  $parseErrors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
  $prepared = @()
  foreach ($token in @($tokens)) {
    $kind = [string]$token.Kind
    if ($kind -ne 'HereStringLiteral' -and $kind -ne 'HereStringExpandable') { continue }
    $raw = [string]$token.Text
    if ($raw -notmatch 'schemas\.microsoft\.com/winfx/2006/xaml/presentation') { continue }
    $varName = Get-HereStringVariable $text $token
    if ([string]::IsNullOrWhiteSpace($varName)) { continue }
    $lines = @([regex]::Split($raw, "\r?\n"))
    if ($lines.Count -lt 3) { continue }
    $inner = New-Object System.Collections.Generic.List[string]
    for ($n = 1; $n -lt ($lines.Count - 1); $n++) { $inner.Add($lines[$n]) | Out-Null }
    $end = [int]$token.Extent.EndOffset
    if ($end -lt 0 -or $end -ge $text.Length) { continue }
    $rest = $text.Substring($end)
    $loadAt = -1
    $cursor = 0
    $needle = 'XamlReader\]::(?:Load|Parse)\('
    while ($cursor -lt $rest.Length) {
      $found = [regex]::Match($rest.Substring($cursor), $needle)
      if (-not $found.Success) { break }
      $at = $cursor + $found.Index
      $take = 500
      if (($rest.Length - $at) -lt $take) { $take = $rest.Length - $at }
      $window = $rest.Substring($at, $take)
      if ($window -match ('\$' + [regex]::Escape($varName) + '\b')) {
        $loadAt = $at
        break
      }
      $cursor = $at + $found.Length
    }
    if ($loadAt -lt 0) { continue }
    $region = $rest.Substring(0, $loadAt)
    $subs = @()
    $seen = @{}
    $receiver = '\$' + [regex]::Escape($varName) + '\.Replace\('
    foreach ($line in @([regex]::Split($region, "\r?\n"))) {
      if ($line -notmatch $receiver) { continue }
      $replaceCalls = [regex]::Matches($line, '\.Replace\(\s*([''"])(?<name>[^''"]+)\1\s*,\s*(?<expr>[^)]*)\)')
      foreach ($call in @($replaceCalls)) {
        $tokenName = [string]$call.Groups['name'].Value
        if ([string]::IsNullOrWhiteSpace($tokenName)) { continue }
        if ($seen.ContainsKey($tokenName)) { continue }
        $seen[$tokenName] = $true
        $subs += [pscustomobject]@{
          Token = $tokenName
          Value = (Get-PlaceholderValue $tokenName ([string]$call.Groups['expr'].Value) $Accent $AccentSoft)
        }
      }
    }
    $ordered = @($subs | Sort-Object -Property @{ Expression = { $_.Token.Length }; Descending = $true })
    $snippet = ($inner -join "`n")
    foreach ($sub in $ordered) {
      $snippet = $snippet.Replace([string]$sub.Token, [string]$sub.Value)
    }
    $prepared += [pscustomobject]@{ Snippet = $snippet; Substitutions = $ordered }
  }
  return $prepared
}

function Invoke-BundlePublishGate([string]$Brand, [string]$ZipPath) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  $parseProblems = New-Object System.Collections.Generic.List[string]
  $scriptCount = 0
  $xamlCount = 0
  $xamlFiles = New-Object System.Collections.Generic.List[string]
  $xamlNotes = New-Object System.Collections.Generic.List[string]
  $xamlProblems = New-Object System.Collections.Generic.List[string]
  $apartment = [string][System.Threading.Thread]::CurrentThread.ApartmentState
  $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('vm-bundle-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
  $accent = '#BBC7D0'
  $accentSoft = '#E6ECEF'
  try {
    $profileBytes = Read-ZipEntryBytes $ZipPath 'profile.json'
    $profileText = [System.Text.Encoding]::UTF8.GetString($profileBytes)
    if ($profileText.Length -gt 0 -and [int][char]$profileText[0] -eq 0xFEFF) { $profileText = $profileText.Substring(1) }
    $profile = $profileText | ConvertFrom-Json
    if ($profile.accent) { $accent = [string]$profile.accent }
    if ($profile.accentSoft) { $accentSoft = [string]$profile.accentSoft }
  } catch { }
  try {
    foreach ($entry in @($zip.Entries)) {
      $name = [string]$entry.FullName
      if ($name -notlike '*.ps1') { continue }
      if ($name.EndsWith('/')) { continue }
      $scriptCount++
      $temp = Join-Path $tempDir ([guid]::NewGuid().ToString('n') + '.ps1')
      $stream = $entry.Open()
      try {
        $file = [System.IO.File]::Create($temp)
        try { $stream.CopyTo($file) } finally { $file.Dispose() }
      } finally { $stream.Dispose() }
      $tokens = $null
      $errors = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile($temp, [ref]$tokens, [ref]$errors)
      if (@($errors).Count -gt 0) {
        $parseProblems.Add(('{0}: {1}' -f $name, [string]@($errors)[0].Message)) | Out-Null
      }
      $prepared = @(Get-PreparedXaml $temp $accent $accentSoft)
      if ($prepared.Count -gt 0) { $xamlFiles.Add($name) | Out-Null }
      $noteParts = @()
      $noteSeen = @{}
      foreach ($item in $prepared) {
        foreach ($sub in @($item.Substitutions)) {
          $label = ([string]$sub.Token) + '=' + ([string]$sub.Value)
          if ($noteSeen.ContainsKey($label)) { continue }
          $noteSeen[$label] = $true
          $noteParts += $label
        }
        $xamlCount++
        try {
          Add-Type -AssemblyName PresentationFramework
          $ui = [System.Windows.Markup.XamlReader]::Parse([string]$item.Snippet)
          if ($null -eq $ui) { throw 'XamlReader.Parse returned null' }
        } catch {
          $xamlProblems.Add(('{0}: {1}' -f $name, $_.Exception.Message)) | Out-Null
        }
      }
      if ($prepared.Count -gt 0) {
        if ($noteParts.Count -eq 0) {
          $xamlNotes.Add(('{0}: no runtime .Replace placeholders' -f $name)) | Out-Null
        } else {
          $xamlNotes.Add(('{0}: substituted {1}' -f $name, ($noteParts -join ', '))) | Out-Null
        }
      }
    }
  } finally {
    $zip.Dispose()
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
  }
  if ($scriptCount -eq 0) {
    Add-Check $Brand 'ps1-parse' 'FAIL' 'the bundle zip has no .ps1 files to parse with Windows PowerShell 5.1'
  } elseif ($parseProblems.Count -gt 0) {
    Add-Check $Brand 'ps1-parse' 'FAIL' ("Windows PowerShell 5.1 parse failed: {0}" -f ($parseProblems -join '; '))
  } else {
    Add-Check $Brand 'ps1-parse' 'PASS' ("Windows PowerShell 5.1 parsed {0} .ps1 files in the bundle zip" -f $scriptCount)
  }
  if ($apartment -ne 'STA') {
    Add-Check $Brand 'xaml' 'FAIL' ("XamlReader requires STA. Current apartment is {0}." -f $apartment)
  } elseif ($xamlCount -eq 0) {
    Add-Check $Brand 'xaml' 'FAIL' 'no .ps1 file in the bundle contains a WPF presentation here-string'
  } elseif ($xamlProblems.Count -gt 0) {
    Add-Check $Brand 'xaml' 'FAIL' ("XamlReader.Parse failed without showing a window: {0}. {1}" -f (($xamlProblems -join '; '), ($xamlNotes -join '; ')))
  } else {
    Add-Check $Brand 'xaml' 'PASS' ("STA XamlReader.Parse loaded {0} WPF here-strings from {1}. {2}. No window was shown." -f $xamlCount, ($xamlFiles -join ', '), ($xamlNotes -join '; '))
  }
}

function Add-DpiCheck {
  Add-Check 'host' 'dpi-awareness' 'NOT PROVEN' 'DPI awareness is not asserted. This harness does not start the launcher process, so a reading from the harness process, including awareness 0, is not evidence.'
  Add-Check 'host' 'dpi-multimonitor' 'NOT PROVEN' 'DPI and multi-monitor layout are not proven on a headless hosted runner. This run does not change session scaling.'
}

function Write-VmInstallReport {
  $reportPath = Join-Path $ReportDir 'vm-install-test-report.md'
  try {
    $failCount = 0
    $passCount = 0
    $unprovenCount = 0
    $notRunCount = 0
    foreach ($row in $script:Results) {
      if ($row.Status -eq 'FAIL') { $failCount++ }
      elseif ($row.Status -eq 'PASS') { $passCount++ }
      elseif ($row.Status -eq 'NOT PROVEN') { $unprovenCount++ }
      elseif ($row.Status -eq 'NOT RUN') { $notRunCount++ }
    }
    $resultWord = 'PASS'
    if ($failCount -gt 0 -or $script:HarnessFault) { $resultWord = 'FAIL' }
    elseif ($notRunCount -gt 0 -or $unprovenCount -gt 0) {
      $resultWord = "PASS with gaps ($notRunCount NOT RUN, $unprovenCount NOT PROVEN)"
    }
    $lines = @()
    $lines += '# VM install test report'
    $lines += ''
    $lines += ('Result: {0}' -f $resultWord)
    $lines += ('PASS {0}, FAIL {1}, NOT PROVEN {2}, NOT RUN {3}' -f @($passCount, $failCount, $unprovenCount, $notRunCount))
    $lines += ('Windows PowerShell {0}' -f $PSVersionTable.PSVersion.ToString())
    $lines += ('Computer: {0}' -f $env:COMPUTERNAME)
    $lines += ('Catalog ref: {0}' -f $CatalogRef)
    $lines += ('Mercedes artifact run: {0}' -f $MercedesRunId)
    $lines += ('BMW artifact run: {0}' -f $BmwRunId)
    $lines += ''
    $lines += 'NOT PROVEN is not a pass. NOT RUN means that brand has no catalog pin, or an older bundle artifact was not staged. A hosted runner cannot show reboot or logon startup, Tamper Protection, or interactive UI. DPI awareness is NOT PROVEN because the launcher process is not started. Defender and Windows Update end state are NOT PROVEN when the runner image does not expose them. DisableAntiSpyware is not written and is not a pass. Downgrade is NOT RUN when the catalog has no older approved pin or that pin has no staged bundle.'
    $lines += ''
    $lines += '## Checks'
    $lines += ''
    foreach ($row in $script:Results) {
      $lines += ('- {0} {1} {2}: {3}' -f @($row.Status, $row.Brand, $row.Id, $row.Detail))
      $lines += ''
    }
    if ($script:HarnessFault) {
      $lines += ('Harness fault: {0}' -f $script:HarnessFault)
      $lines += ''
    }
    $text = ($lines -join "`r`n") + "`r`n"
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($reportPath, $text, $utf8)
  } catch {
    $fallback = "VM install test report`r`n`r`nThe report writer failed: " + $_.Exception.Message + "`r`n"
    [System.IO.File]::WriteAllText($reportPath, $fallback)
  }
}

$plan = Get-DefenderControlPlan
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$transcript = Join-Path $ReportDir 'transcript.txt'
try { Start-Transcript -LiteralPath $transcript -Force | Out-Null } catch { }

$script:HarnessFault = $null
try {

Add-Check 'host' 'reboot-logon' 'NOT PROVEN' 'A hosted runner does not reboot or start a new logon session, so startup-at-logon is not proven. Registry before and after the install is a separate check.'
Add-Check 'host' 'tamper-protection' 'NOT PROVEN' 'Tamper Protection behavior is not proven. Hosted runner images usually have it off or unmanaged, and an interactive Tamper Protection prompt cannot be answered here.'
Add-Check 'host' 'interactive-ui' 'NOT PROVEN' 'Interactive desktop UI is not proven. This run does not open the launcher, dock, or shell.'
Add-DpiCheck

$catalogPath = Join-Path $RepoRoot 'catalog\catalog.json'
$pinPath = Join-Path $RepoRoot 'catalog\catalog.sha256'
$offlineParent = Join-Path $RepoRoot 'offline'
$catalog = $null
$catalogPin = ''
$catalogActual = ''
$catalogReady = $false
try {
  $catalogPin = ((Get-Content -LiteralPath $pinPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
  $catalogActual = Get-HexSha256 $catalogPath
  $catalog = Read-JsonFile $catalogPath
  $catalogReady = $true
} catch {
  Add-Check 'host' 'catalog' 'FAIL' $_.Exception.Message
}

$brands = @(
  [pscustomobject]@{ Id = 'mercedes'; RunId = $MercedesRunId },
  [pscustomobject]@{ Id = 'bmw'; RunId = $BmwRunId }
)

if ($catalogReady) {
foreach ($brand in $brands) {
  $id = [string]$brand.Id
  $releases = @(Get-BrandReleases $catalog $id)
  if ($releases.Count -eq 0) {
    Add-Check $id 'pin' 'NOT RUN' 'No approved release is pinned. This brand is skipped until a catalog pin exists.'
    Add-Check $id 'downgrade' 'NOT RUN' 'No approved release is pinned, so an older version was not attempted.'
    continue
  }
  $ranked = @($releases | Sort-Object -Property @{ Expression = { Get-ReleaseRank ([string]$_.version) }; Descending = $true })
  $release = $ranked[0]
  $tag = [string]$release.tag
  $pinnedVersion = [string]$release.version
  $root = Resolve-BrandInstallRoot $id
  $payload = Join-Path $offlineParent $tag
  $zipPath = Join-Path $payload 'workstation.zip'
  $manifestPath = Join-Path $payload 'update-manifest.json'
  $logStem = Join-Path $ReportDir ($id + '-install')
  try {
    $catalogBrand = Get-CatalogBrand $catalog $id
    $pinOk = ($catalogPin -eq $catalogActual)
    $a = @()
    if ($pinOk) {
      $a += New-Part 'PASS' ("catalog.sha256 matches catalog.json ({0})" -f $catalogActual)
    } else {
      $a += New-Part 'FAIL' ("catalog.sha256 {0} does not match catalog.json {1}" -f $catalogPin, $catalogActual)
    }
    if (-not (Test-Path -LiteralPath $zipPath) -or -not (Test-Path -LiteralPath $manifestPath)) {
      $a += New-Part 'FAIL' ("offline payload missing at {0}" -f $payload)
      Add-CombinedCheck $id 'a' $a
      Add-Check $id 'b' 'FAIL' 'Skipped. The offline payload is missing.'
      Add-Check $id 'c' 'FAIL' 'Skipped. The offline payload is missing.'
      Add-Check $id 'd' 'FAIL' 'Skipped. The offline payload is missing.'
      Add-Check $id 'e' 'FAIL' 'Skipped. The offline payload is missing.'
      Add-Check $id 'f' 'FAIL' 'Skipped. The offline payload is missing.'
      Add-Check $id 'g' 'FAIL' 'Skipped. The offline payload is missing.'
      Add-Check $id 'downgrade' 'NOT RUN' 'the pinned payload is missing, so an older version was not attempted'
      continue
    }
    $zipHash = Get-HexSha256 $zipPath
    $zipBytes = (Get-Item -LiteralPath $zipPath).Length
    $manifestHash = Get-HexSha256 $manifestPath
    $manifest = Read-JsonFile $manifestPath
    $pinMatch = ($zipHash -eq ([string]$release.sha256).ToLowerInvariant() -and [int64]$zipBytes -eq [int64]$release.bytes -and $manifestHash -eq ([string]$release.manifestSha256).ToLowerInvariant() -and [string]$manifest.sha256 -eq $zipHash)
    if ($pinMatch) {
      $a += New-Part 'PASS' ("run {0} zip {1} ({2} bytes) and manifest {3} match the catalog pin for {4}" -f $brand.RunId, $zipHash, $zipBytes, $manifestHash, $tag)
      Invoke-BundlePublishGate $id $zipPath
      $tagPrefix = ''
      if ($catalogBrand) { $tagPrefix = [string]$catalogBrand.tagPrefix }
      Add-UnpinnedTagCheck $id $tagPrefix $offlineParent $root
      Add-WrongTargetCheck $id $tag $offlineParent $root
      Add-LiveLockCheck $id $tag $pinnedVersion $offlineParent $root
      Add-StaleLockCheck $id $tag $offlineParent $root
    } else {
      $a += New-Part 'FAIL' ("downloaded artifact does not match the catalog pin. zip={0} bytes={1} manifest={2} manifest.sha256={3}" -f $zipHash, $zipBytes, $manifestHash, [string]$manifest.sha256)
      Add-Check $id 'ps1-parse' 'FAIL' 'Skipped because the downloaded zip does not match the catalog pin.'
      Add-Check $id 'xaml' 'FAIL' 'Skipped because the downloaded zip does not match the catalog pin.'
      Add-Check $id 'unpinned-tag' 'FAIL' 'Skipped because the downloaded zip does not match the catalog pin.'
      Add-Check $id 'wrong-target' 'FAIL' 'Skipped because the downloaded zip does not match the catalog pin.'
      Add-Check $id 'live-lock' 'FAIL' 'Skipped because the downloaded zip does not match the catalog pin.'
      Add-Check $id 'stale-lock' 'FAIL' 'Skipped because the downloaded zip does not match the catalog pin.'
    }

    $startupBefore = Get-StartupSnapshot
    $policyBefore = Get-PolicyImage $plan
    $prefsReadableBefore = Test-DefenderPreferenceReadable
    $prefBefore = $null
    if ($prefsReadableBefore) { $prefBefore = Get-PreferenceImage $plan }

    Clear-BrandTree $root
    $tamperDir = Join-Path $ReportDir ($id + '-tampered')
    New-Item -ItemType Directory -Force -Path $tamperDir | Out-Null
    $tamperZip = Join-Path $tamperDir 'workstation.zip'
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $tamperDir 'update-manifest.json') -Force
    $tamperBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $tamperBytes[$tamperBytes.Length - 1] = [byte](($tamperBytes[$tamperBytes.Length - 1] + 1) % 256)
    [System.IO.File]::WriteAllBytes($tamperZip, $tamperBytes)
    Remove-SecurityState $id
    $tamperCode = Invoke-NativePowerShell -File (Join-Path $RepoRoot 'installer\Master\Install-Master.ps1') -Arguments @('-Brand', $id, '-Channel', 'beta', '-Tag', $tag, '-Source', $tamperDir, '-OfflineOnly') -LogStem (Join-Path $ReportDir ($id + '-tamper')) -TimeoutMs $script:InstallTimeoutMs
    $tamperErr = ''
    $tamperErrPath = Join-Path $ReportDir ($id + '-tamper.stderr.txt')
    $tamperOutPath = Join-Path $ReportDir ($id + '-tamper.stdout.txt')
    if (Test-Path -LiteralPath $tamperErrPath) { $tamperErr = [System.IO.File]::ReadAllText($tamperErrPath) }
    if (Test-Path -LiteralPath $tamperOutPath) { $tamperErr = $tamperErr + [System.IO.File]::ReadAllText($tamperOutPath) }
    $rootAfterTamper = Test-Path -LiteralPath $root
    if ($tamperCode -eq 0 -or $rootAfterTamper) {
      Add-Check $id 'b' 'FAIL' ("tampered zip was not rejected. exit={0} rootExists={1}" -f $tamperCode, $rootAfterTamper)
    } elseif ($tamperCode -eq -1) {
      Add-Check $id 'b' 'FAIL' 'tampered install timed out. Interactive UI is not proven, and the negative test did not finish.'
    } elseif ($tamperErr -notmatch 'hash mismatch') {
      Add-Check $id 'b' 'FAIL' ("tampered install exit {0} did not report a hash mismatch. expected 'hash mismatch'. {1}" -f $tamperCode, ($tamperErr -replace '\s+', ' ').Trim())
    } else {
      Add-Check $id 'b' 'PASS' ("one flipped zip byte was rejected with 'hash mismatch' and exit {0}, and the brand folder was not created" -f $tamperCode)
    }
    Clear-BrandTree $root

    Remove-SecurityState $id
    $journalAt = Get-JournalCount
    $installArgs = @('-Brand', $id, '-Channel', 'beta', '-Tag', $tag, '-Source', $offlineParent, '-OfflineOnly')
    $installCode = Invoke-NativePowerShell -File (Join-Path $RepoRoot 'installer\Master\Install-Master.ps1') -Arguments $installArgs -LogStem $logStem -TimeoutMs $script:InstallTimeoutMs
    $installEvents = @(Read-NewJournal $journalAt)
    $security = Get-SecurityState $id
    if ($installCode -eq -1) {
      $a += New-Part 'FAIL' 'installer timed out'
    } elseif (-not $security) {
      $stdout = ''
      $stderr = ''
      if (Test-Path ($logStem + '.stdout.txt')) { $stdout = [System.IO.File]::ReadAllText($logStem + '.stdout.txt') }
      if (Test-Path ($logStem + '.stderr.txt')) { $stderr = [System.IO.File]::ReadAllText($logStem + '.stderr.txt') }
      $a += New-Part 'FAIL' ("installer exit {0} and no security-state file. {1}" -f $installCode, (($stderr + ' ' + $stdout) -replace '\s+', ' ').Trim())
    } else {
      $expected = Get-ExpectedInstallExit $security
      if ($installCode -eq $expected) {
        $a += New-Part 'PASS' ("installer exit {0} matches windowsUpdate={1} defender={2}" -f $installCode, $security.windowsUpdate, $security.defender)
      } else {
        $a += New-Part 'FAIL' ("installer exit {0} expected {1} for windowsUpdate={2} defender={3}" -f $installCode, $expected, $security.windowsUpdate, $security.defender)
      }
    }

    $fileProblems = @()
    if (Test-Path -LiteralPath $root) {
      foreach ($entry in @($manifest.files)) {
        $relative = [string]$entry.path
        $full = Join-Rel $root $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $fileProblems += "missing $relative"; continue }
        $hash = Get-HexSha256 $full
        $size = (Get-Item -LiteralPath $full).Length
        if ($hash -ne ([string]$entry.sha256).ToLowerInvariant()) { $fileProblems += "hash $relative" }
        if ([int64]$size -ne [int64]$entry.bytes) { $fileProblems += "size $relative" }
      }
    } else {
      $fileProblems += 'brand root missing'
    }
    if ($fileProblems.Count -eq 0) {
      $a += New-Part 'PASS' ("{0} installed files match the manifest hashes" -f @($manifest.files).Count)
    } else {
      $a += New-Part 'FAIL' ("installed files do not match the manifest: {0}" -f ($fileProblems -join ', '))
    }
    Add-CombinedCheck $id 'a' $a
    Add-ExtraFilesCheck $id $root $manifest
    Add-DowngradeCheck $id $tag $pinnedVersion $offlineParent $root $releases

    $c = @()
    $bundleProfilePath = Join-Path $ReportDir ($id + '-bundle-profile.json')
    [System.IO.File]::WriteAllBytes($bundleProfilePath, (Read-ZipEntryBytes $zipPath 'profile.json'))
    $installedProfile = Join-Path $root 'profile.json'
    if (Test-SameHash $installedProfile $bundleProfilePath) {
      $c += New-Part 'PASS' 'fresh install profile.json matches the bundle default byte for byte'
    } else {
      $c += New-Part 'FAIL' 'fresh install did not land the bundle profile.json'
    }
    if (Test-Path -LiteralPath (Join-Path $root 'apps.json')) {
      $c += New-Part 'FAIL' 'fresh install created apps.json'
    } else {
      $c += New-Part 'PASS' 'fresh install has no apps.json'
    }

    $d = @()
    $versionPath = Join-Path $root 'version.json'
    if (Test-Path -LiteralPath $versionPath) {
      $versionText = [System.IO.File]::ReadAllText($versionPath).Trim()
      $versionValue = [string](($versionText | ConvertFrom-Json).version)
      if ($versionValue -eq $pinnedVersion -and $versionText -eq ('{"version":"' + $pinnedVersion + '"}')) {
        $d += New-Part 'PASS' ("version.json is {0}" -f $versionText)
      } else {
        $d += New-Part 'FAIL' ("version.json is {0}" -f $versionText)
      }
    } else {
      $d += New-Part 'FAIL' 'version.json is missing'
    }
    Add-CombinedCheck $id 'd' $d

    $e = @()
    $markerPath = Join-Path $root '.installed-bundle.json'
    $marker = $null
    if (Test-Path -LiteralPath $markerPath) { $marker = Read-JsonFile $markerPath }
    $exePath = Join-Path $root 'WorkstationManager.exe'
    $watchPath = Join-Path $root 'Watchdog.ps1'
    $note = ''
    if ($catalogBrand -and $catalogBrand.supervisor) { $note = [string]$catalogBrand.supervisor.note }
    if ($id -eq 'mercedes') {
      if (Test-Path -LiteralPath $exePath) { $e += New-Part 'PASS' 'WorkstationManager.exe is in the Mercedes install folder' }
      else { $e += New-Part 'FAIL' 'WorkstationManager.exe is missing from the Mercedes install folder' }
    } else {
      if (Test-Path -LiteralPath $exePath) { $e += New-Part 'FAIL' 'BMW install contains WorkstationManager.exe, which this bundle does not ship' }
      else { $e += New-Part 'PASS' 'BMW bundle has no WorkstationManager.exe' }
      $transitional = ''
      if ($catalogBrand -and $catalogBrand.supervisor) { $transitional = [string]$catalogBrand.supervisor.transitionalEntry }
      if ($transitional -eq 'Watchdog.ps1' -and (Test-Path -LiteralPath $watchPath)) {
        $e += New-Part 'PASS' 'catalog transitional entry Watchdog.ps1 is present in the BMW install folder'
      } else {
        $e += New-Part 'FAIL' ("BMW transitional entry is '{0}' and Watchdog.ps1 present={1}" -f $transitional, (Test-Path -LiteralPath $watchPath))
      }
    }
    if ($marker -and [string]$marker.shellRegistration -eq 'not-changed') {
      $e += New-Part 'PASS' 'installed marker shellRegistration is not-changed'
    } else {
      $e += New-Part 'FAIL' 'installed marker does not say shellRegistration not-changed'
    }
    $startupAfter = $null
    try { $startupAfter = Get-StartupSnapshot } catch { $startupAfter = $null }
    if ($null -eq $startupBefore -or $null -eq $startupAfter) {
      $e += New-Part 'NOT PROVEN' 'startup registry could not be read'
    } elseif ($startupBefore -ne $startupAfter) {
      $e += New-Part 'FAIL' 'Run or Winlogon registry changed during install'
    } elseif ($startupAfter -match '(?i)WorkstationManager') {
      $e += New-Part 'FAIL' 'WorkstationManager startup entry exists: yes'
    } else {
      $e += New-Part 'PASS' 'WorkstationManager startup entry exists: no. Run and Winlogon values were unchanged.'
    }
    if ($note) { $e += New-Part 'PASS' ("catalog supervisor note: {0}" -f $note) }
    Add-CombinedCheck $id 'e' $e
    if ($pinMatch) {
      Add-InterruptedSwapCheck $id $tag $offlineParent $root
      Add-InInstallFailureCheck $id $tag $offlineParent $root
    } else {
      Add-Check $id 'interrupted-swap' 'FAIL' 'Skipped because the downloaded zip does not match the catalog pin.'
      Add-Check $id 'in-install-failure' 'FAIL' 'Skipped because the downloaded zip does not match the catalog pin.'
    }

    $f = @()
    $wu = $null
    foreach ($event in @($installEvents)) {
      if ([string]$event.step -eq 'windows-update-post' -or [string]$event.step -eq 'windows-update-failed') { $wu = $event }
    }
    if ($wu -and $null -ne $wu.exitCode) {
      $f += New-Part 'PASS' ("Windows Update Blocker exit code recorded: {0}" -f $wu.exitCode)
    } elseif ($wu) {
      $f += New-Part 'PASS' ("Windows Update step recorded: {0}" -f [string]$wu.step)
    } else {
      $f += New-Part 'FAIL' 'Windows Update step wrote no journal record'
    }
    $servicesAfter = Get-ServiceImage
    $serviceText = (($servicesAfter | ForEach-Object { '{0}={1}' -f $_.Name, $_.Status }) -join ', ')
    $unreadableService = $false
    foreach ($row in @($servicesAfter)) { if (-not $row.Readable) { $unreadableService = $true } }
    if ($unreadableService) {
      $f += New-Part 'NOT PROVEN' ("WUB service state is not readable ({0})" -f $serviceText)
    } elseif ($security -and [string]$security.windowsUpdate -eq 'disabled') {
      $stopped = $true
      foreach ($row in @($servicesAfter)) { if ($row.Status -ne 'Stopped') { $stopped = $false } }
      if ($stopped) { $f += New-Part 'PASS' ("WUB services are Stopped ({0})" -f $serviceText) }
      else { $f += New-Part 'NOT PROVEN' ("WUB reported disabled but the hosted runner service state is {0}. That end state is not proven." -f $serviceText) }
    } else {
      $f += New-Part 'NOT PROVEN' ("Windows Update was not disabled on this runner ({0}). Service state {1} is not a proof of the shop-PC WUB result." -f $(if ($security) { [string]$security.windowsUpdate } else { 'no-security-state' }), $serviceText)
    }

    $defenderStatus = $(if ($security) { [string]$security.defender } else { 'absent' })
    $prefsNowReadable = Test-DefenderPreferenceReadable
    if (-not $prefsNowReadable) {
      $f += New-Part 'NOT PROVEN' ("Defender preferences are not readable on this runner (defender status {0}). This is not a pass." -f $defenderStatus)
    } else {
      $prefNow = Get-PreferenceImage $plan
      $missing = @()
      $mismatch = @()
      foreach ($name in @($prefNow.Keys)) {
        $row = $prefNow[$name]
        if (-not $row.Present) { $missing += $name; continue }
        if ($defenderStatus -eq 'disabled' -and -not (Test-PreferenceMatch $row.Value $row.ExpectedDisable)) {
          $mismatch += ('{0}={1}' -f $name, $row.Value)
        }
      }
      if ($missing.Count -gt 0) {
        $f += New-Part 'NOT PROVEN' ("Defender is missing preference properties on this image: {0}" -f ($missing -join ', '))
      } elseif ($defenderStatus -ne 'disabled') {
        $f += New-Part 'NOT PROVEN' ("Defender disable status is {0}. Preference values were readable but this runner did not prove a shop-PC disable." -f $defenderStatus)
      } elseif ($mismatch.Count -gt 0) {
        $f += New-Part 'FAIL' ("Set-MpPreference values do not match the disable plan: {0}" -f ($mismatch -join ', '))
      } else {
        $f += New-Part 'PASS' 'Set-MpPreference values match the disable plan'
      }
    }
    $policyAfter = Get-PolicyImage $plan
    $policyUnreadable = $false
    foreach ($row in @($policyAfter)) { if (-not $row.Readable) { $policyUnreadable = $true } }
    if ($policyUnreadable) {
      $f += New-Part 'NOT PROVEN' 'Defender policy DWORDs are not readable on this runner'
    } elseif ($defenderStatus -eq 'disabled') {
      $dwordBad = @()
      $spywareFailed = $false
      foreach ($row in @($policyAfter)) {
        if ($row.Name -eq 'DisableAntiSpyware') {
          if (-not $row.Exists -or [int]$row.Value -ne 1) { $spywareFailed = $true }
          continue
        }
        if (-not $row.Exists -or [int]$row.Value -ne 1) { $dwordBad += $row.Name }
      }
      $journalSpyware = $false
      foreach ($event in @($installEvents)) {
        if ([string]$event.step -ne 'defender-post') { continue }
        foreach ($command in @($event.commands)) {
          if ([string]$command.kind -eq 'Set-Policy' -and [string]$command.name -eq 'DisableAntiSpyware') { $journalSpyware = $true }
        }
      }
      if ($journalSpyware) {
        $spywareImage = Get-DisableAntiSpywareImage
        if (-not $spywareImage.Readable -or -not $spywareImage.Exists -or [int]$spywareImage.Value -ne 1) { $spywareFailed = $true }
      }
      if ($spywareFailed) {
        $f += New-Part 'FAIL' 'a skipped or failed DisableAntiSpyware write is not a pass'
      }
      $shown = @($policyAfter | Where-Object { $_.Name -ne 'DisableAntiSpyware' })
      if ($dwordBad.Count -gt 0) {
        $f += New-Part 'FAIL' ("policy DWORDs are not all 1: {0}" -f (Format-PolicyImage $shown))
      } elseif (-not $spywareFailed) {
        $f += New-Part 'PASS' ("policy DWORDs are 1 ({0}). DisableAntiSpyware is not written and is not part of this pass." -f (Format-PolicyImage $shown))
      }
    } elseif (Test-PolicyImageEqual $policyBefore $policyAfter) {
      $f += New-Part 'PASS' 'defender step did not leave new policy DWORDs'
    } else {
      $f += New-Part 'FAIL' ("defender status {0} but policy DWORDs changed: {1}" -f $defenderStatus, (Format-PolicyImage $policyAfter))
    }

    $utf8 = New-Object System.Text.UTF8Encoding $false
    $customProfileText = '{"id":"vm-test","displayName":"VM preserve check","marker":"preserve-me"}'
    $customAppsText = '{"apps":["vm-preserve-check"]}'
    $seedProfilePath = Join-Path $root 'profile.json'
    $seedAppsPath = Join-Path $root 'apps.json'
    $seedProfileHash = $null
    $seedAppsHash = $null
    $seeded = $false
    if (Test-Path -LiteralPath $root) {
      [System.IO.File]::WriteAllText($seedProfilePath, $customProfileText, $utf8)
      [System.IO.File]::WriteAllText($seedAppsPath, $customAppsText, $utf8)
      $seedProfileHash = Get-HexSha256 $seedProfilePath
      $seedAppsHash = Get-HexSha256 $seedAppsPath
      $seeded = $true
    }

    $enableScript = Join-Path $script:InstallerData 'Master\Enable-Security.ps1'
    $undoScript = Join-Path $script:InstallerData 'Master\Uninstall-MasterBrand.ps1'
    $enableCode = $null
    $undoCode = $null
    if (-not (Test-Path -LiteralPath $enableScript) -or -not (Test-Path -LiteralPath $undoScript)) {
      $f += New-Part 'FAIL' 'deployed Enable-Security.ps1 or Uninstall-MasterBrand.ps1 is missing from DiagnosticWorkstation-Installer'
    } else {
      $enableCode = Invoke-NativePowerShell -File $enableScript -Arguments @('-Brand', $id, '-Action', 'enable') -LogStem (Join-Path $ReportDir ($id + '-enable-security')) -TimeoutMs $script:InstallTimeoutMs
      $undoCode = Invoke-NativePowerShell -File $undoScript -Arguments @('-Brand', $id) -LogStem (Join-Path $ReportDir ($id + '-uninstall-master')) -TimeoutMs $script:InstallTimeoutMs
      if ($enableCode -eq -1 -or $undoCode -eq -1) {
        $f += New-Part 'FAIL' ("security round-trip timed out (enable {0}, uninstall {1}). Interactive Tamper Protection UI is not proven." -f $enableCode, $undoCode)
      } elseif ($enableCode -eq 1 -or $undoCode -eq 1) {
        $f += New-Part 'FAIL' ("security round-trip threw (enable {0}, uninstall {1})" -f $enableCode, $undoCode)
      } elseif ($enableCode -ne 0 -or $undoCode -ne 0) {
        $f += New-Part 'PASS' ("Enable-Security.ps1 exit {0}; Uninstall-MasterBrand.ps1 exit {1}" -f $enableCode, $undoCode)
        $f += New-Part 'NOT PROVEN' ("security round-trip did not exit 0 (enable {0}, uninstall {1}). Preference restore is not proven on this runner." -f $enableCode, $undoCode)
      } else {
        $f += New-Part 'PASS' 'Enable-Security.ps1 exit 0; Uninstall-MasterBrand.ps1 exit 0'
        $prefsAfterUndo = Test-DefenderPreferenceReadable
        if (-not $prefsReadableBefore -or -not $prefsAfterUndo -or $null -eq $prefBefore) {
          $f += New-Part 'NOT PROVEN' 'Defender preference restore is not proven because Get-MpPreference is not readable on this runner'
        } else {
          $prefUndo = Get-PreferenceImage $plan
          $restoreBad = @()
          foreach ($name in @($prefBefore.Keys)) {
            $beforeRow = $prefBefore[$name]
            $afterRow = $prefUndo[$name]
            if (-not $beforeRow.Present -and -not $afterRow.Present) { continue }
            if ($beforeRow.Present -ne $afterRow.Present -or -not (Test-PreferenceMatch $beforeRow.Value $afterRow.Value)) {
              $restoreBad += $name
            }
          }
          if ($restoreBad.Count -eq 0) { $f += New-Part 'PASS' 'Set-MpPreference values match the pre-install image' }
          else { $f += New-Part 'FAIL' ("Set-MpPreference values were not restored: {0}" -f ($restoreBad -join ', ')) }
        }
        $policyUndo = Get-PolicyImage $plan
        $undoUnreadable = $false
        foreach ($row in @($policyUndo)) { if (-not $row.Readable) { $undoUnreadable = $true } }
        foreach ($row in @($policyBefore)) { if (-not $row.Readable) { $undoUnreadable = $true } }
        if ($undoUnreadable) {
          $f += New-Part 'NOT PROVEN' 'policy DWORD restore is not readable on this runner'
        } elseif (Test-PolicyImageEqual $policyBefore $policyUndo) {
          $f += New-Part 'PASS' 'added policy DWORDs were removed or restored to the pre-install image'
        } else {
          $f += New-Part 'FAIL' ("policy DWORDs after undo are {0}" -f (Format-PolicyImage $policyUndo))
        }
      }
    }
    Add-CombinedCheck $id 'f' $f

    $g = @()
    if (-not $seeded) {
      $g += New-Part 'FAIL' 'machine-local files were not seeded because the fresh install did not create the brand folder'
      $c += New-Part 'FAIL' 'preserve check skipped because the fresh install did not create the brand folder'
    } elseif ($null -eq $undoCode) {
      $g += New-Part 'FAIL' 'Uninstall-MasterBrand.ps1 did not run, so the leave-files check has nothing to observe'
      $c += New-Part 'FAIL' 'preserve install skipped because the security undo did not run'
    } else {
      $profileStill = (Test-Path -LiteralPath $seedProfilePath) -and ((Get-HexSha256 $seedProfilePath) -eq $seedProfileHash)
      $appsStill = (Test-Path -LiteralPath $seedAppsPath) -and ((Get-HexSha256 $seedAppsPath) -eq $seedAppsHash)
      if ((Test-Path -LiteralPath $root) -and $profileStill -and $appsStill) {
        $g += New-Part 'PASS' 'Uninstall-MasterBrand.ps1 left the brand folder and the seeded profile.json and apps.json byte-identical'
      } else {
        $g += New-Part 'FAIL' 'Uninstall-MasterBrand.ps1 removed the brand folder or changed profile.json or apps.json'
      }
      Remove-SecurityState $id
      $preserveCode = Invoke-NativePowerShell -File (Join-Path $RepoRoot 'installer\Master\Install-Master.ps1') -Arguments $installArgs -LogStem (Join-Path $ReportDir ($id + '-preserve')) -TimeoutMs $script:InstallTimeoutMs
      $profileKept = (Test-Path -LiteralPath $seedProfilePath) -and ((Get-HexSha256 $seedProfilePath) -eq $seedProfileHash)
      $appsKept = (Test-Path -LiteralPath $seedAppsPath) -and ((Get-HexSha256 $seedAppsPath) -eq $seedAppsHash)
      if ($preserveCode -eq -1) {
        $c += New-Part 'FAIL' 'preserve install timed out'
      } elseif ($preserveCode -eq 1) {
        $c += New-Part 'FAIL' 'preserve install failed before writing the brand folder'
      } elseif ($profileKept -and $appsKept) {
        $c += New-Part 'PASS' 'pre-seeded profile.json and apps.json are byte-identical after install'
      } else {
        $c += New-Part 'FAIL' 'pre-seeded profile.json or apps.json changed during install'
      }
    }
    Add-CombinedCheck $id 'c' $c

    if ($id -eq 'mercedes') {
      $bundleUninstall = Join-Path $root 'Uninstall.ps1'
      if (-not (Test-Path -LiteralPath $bundleUninstall)) {
        $g += New-Part 'FAIL' 'Mercedes bundle Uninstall.ps1 is missing'
      } else {
        $removeCode = Invoke-NativePowerShell -File $bundleUninstall -Arguments @('-Quiet') -LogStem (Join-Path $ReportDir 'mercedes-bundle-uninstall') -TimeoutMs $script:InstallTimeoutMs
        $deadline = [datetime]::UtcNow.AddSeconds(20)
        while ((Test-Path -LiteralPath $root) -and ([datetime]::UtcNow -lt $deadline)) { Start-Sleep -Seconds 1 }
        $backupRoot = Join-Path $env:LOCALAPPDATA 'DiagnosticWorkstation-Backups'
        $backup = $null
        if (Test-Path -LiteralPath $backupRoot) {
          $backup = Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Uninstall-*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
        $backupProfileOk = $false
        $backupAppsOk = $false
        if ($backup) {
          $backupProfile = Join-Path $backup.FullName 'profile.json'
          $backupApps = Join-Path $backup.FullName 'apps.json'
          if (Test-Path -LiteralPath $backupProfile) { $backupProfileOk = (Get-HexSha256 $backupProfile) -eq $seedProfileHash }
          if (Test-Path -LiteralPath $backupApps) { $backupAppsOk = (Get-HexSha256 $backupApps) -eq $seedAppsHash }
        }
        if ($removeCode -eq -1) {
          $g += New-Part 'FAIL' 'Mercedes Uninstall.ps1 timed out'
        } elseif (Test-Path -LiteralPath $root) {
          $g += New-Part 'FAIL' ("Mercedes Uninstall.ps1 exit {0} left the brand folder in place" -f $removeCode)
        } elseif ($backupProfileOk -and $backupAppsOk) {
          $g += New-Part 'PASS' ("Mercedes Uninstall.ps1 removed the brand folder and backed up profile.json and apps.json to {0}" -f $backup.FullName)
        } else {
          $g += New-Part 'FAIL' 'Mercedes Uninstall.ps1 removed the folder but did not keep byte-identical profile.json and apps.json in the backup'
        }
      }
    } else {
      $bundleUninstall = Join-Path $root 'Uninstall.ps1'
      if (Test-Path -LiteralPath $bundleUninstall) {
        $g += New-Part 'FAIL' 'BMW bundle contains Uninstall.ps1, which this package does not ship'
      } elseif ((Test-Path -LiteralPath $root) -and (Test-Path -LiteralPath (Join-Path $root 'apps.json')) -and (Test-Path -LiteralPath (Join-Path $root 'profile.json'))) {
        $g += New-Part 'PASS' 'BMW has no bundled Uninstall.ps1. The brand folder, profile.json, and apps.json stay in place, which is what this package does.'
      } else {
        $g += New-Part 'FAIL' 'BMW brand folder or machine-local files are missing'
      }
    }
    Add-CombinedCheck $id 'g' $g
  } catch {
    Add-Check $id 'harness' 'FAIL' $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Output $_.ScriptStackTrace }
  }
}
}

$copied = Join-Path $ReportDir 'installer-logs'
try {
  $logDir = Join-Path $script:InstallerData 'logs'
  if (Test-Path -LiteralPath $logDir) {
    New-Item -ItemType Directory -Force -Path $copied | Out-Null
    Copy-Item -Path (Join-Path $logDir '*') -Destination $copied -Recurse -Force
  }
  foreach ($name in @('defender-pre-state.json', 'security-state-mercedes.json', 'security-state-bmw.json')) {
    $src = Join-Path $script:InstallerData $name
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $ReportDir $name) -Force }
  }
} catch {
  Add-Check 'host' 'log-copy' 'FAIL' $_.Exception.Message
}

} catch {
  $script:HarnessFault = [string]$_.Exception.Message
  try { Add-Check 'host' 'harness' 'FAIL' $script:HarnessFault } catch { }
} finally {
  Write-VmInstallReport
  try { Stop-Transcript | Out-Null } catch { }
}

$failCount = 0
foreach ($row in $script:Results) {
  if ($row.Status -eq 'FAIL') { $failCount++ }
}
if ($script:HarnessFault -or $failCount -gt 0) { exit 1 }
exit 0
