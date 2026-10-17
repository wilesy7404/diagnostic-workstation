# Master installer checks. No network, no Windows Update change, no Defender change, no install onto a real profile.
$ErrorActionPreference = 'Stop'
$env:MASTER_INSTALLER_FORBID_TOOL_EXECUTION = '1'
$repo = Split-Path -Parent $PSScriptRoot
$lib = Join-Path $repo 'installer/Master/lib'
. (Join-Path $lib 'Common.ps1')
. (Join-Path $lib 'Catalog.ps1')
. (Join-Path $lib 'Bundle.ps1')
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
  $banned = @('Set-MpPreference', 'Add-MpPreference', 'DisableRealtimeMonitoring', 'DisableAntiSpyware', 'CurrentVersion\Winlogon')
  $sources = @(Get-ChildItem -Path (Join-Path $repo 'installer/Master') -Filter '*.ps1' -Recurse)
  $blob = ($sources | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
  foreach ($word in $banned) {
    Assert-True (-not ($blob.Contains($word))) "installer source contains $word"
  }
  $entry = [System.IO.File]::ReadAllText((Join-Path $repo 'installer/Master/Install-Master.ps1'))
  Assert-True ($entry.Contains('-ApplySecurity:(-not $VerifyOnly)')) 'entry does not apply security after install'
  Assert-True (-not ($entry.Contains('dControl.exe'))) 'entry names dControl.exe'
  Assert-True (-not ($entry.Contains('Probe-DefenderControlCli.ps1'))) 'entry calls the Defender probe'

  $mercedesRoot = Resolve-BrandInstallRoot 'mercedes' (Join-Path $temp 'local-mercedes')
  $bmwRoot = Resolve-BrandInstallRoot 'bmw' (Join-Path $temp 'local-bmw')
  Assert-True ((Split-Path -Leaf $mercedesRoot) -eq 'DiagnosticWorkstation') 'Mercedes root changed'
  Assert-True ((Split-Path -Leaf $bmwRoot) -eq 'BMW-Stealth-Launcher') 'BMW root changed'
  Assert-Throws { Get-BrandAllowEntry 'ford' } 'not approved'
  Assert-Throws { Assert-BrandTag 'mercedes' 'universal-v1.0.0' } 'universal-v tags are retired'
  Assert-Throws { Assert-BrandTag 'bmw' 'v1.0.1-beta.5' } 'bare v tags are retired'
  Assert-BrandTag 'mercedes' 'mercedes-v0.1.3-beta.2'

  $goodUrl = 'https://github.com/wilesy7404/diagnostic-workstation/releases/download/mercedes-v0.1.3-beta.2/workstation.zip'
  Assert-GithubReleaseUrl $goodUrl 'wilesy7404/diagnostic-workstation' 'mercedes-v0.1.3-beta.2' 'workstation.zip'
  Assert-Throws { Assert-GithubReleaseUrl 'https://example.com/workstation.zip' 'wilesy7404/diagnostic-workstation' 'mercedes-v0.1.3-beta.2' 'workstation.zip' } 'Unexpected download URL'
  Assert-Throws { Get-ApprovedAssetUrl 'mercedes' 'mercedes-v0.1.3-beta.2' 'payload.exe' } 'Unexpected download URL'

  $pin = Get-PinToken (Join-Path $repo 'catalog/catalog.sha256')
  $catalogHash = Get-Sha256Hex (Join-Path $repo 'catalog/catalog.json')
  Assert-True ($pin -eq $catalogHash) 'catalog pin does not match catalog.json'
  Assert-Throws {
    Install-ApprovedBrand -Brand 'mercedes' -AllowTestRoot -InstallRoot (Join-Path $temp 'unused-root') -InstallerData (Join-Path $temp 'unused-data') -LogDirectory (Join-Path $temp 'unused-logs') -RepoRoot $repo -AllowUncheckedProcesses -OfflineOnly
  } 'No approved'

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

  $global:MasterTestCalls = New-Object System.Collections.Generic.List[object]
  $global:MasterStateReads = 0
  $runner = {
    param($Exe, $ArgumentList)
    $joined = @($ArgumentList) -join ' '
    $global:MasterTestCalls.Add([pscustomobject]@{ exe = [string]$Exe; arguments = $joined })
    if ((Split-Path -Leaf ([string]$Exe)) -eq 'dControl.exe') { throw 'dControl was started' }
    return 0
  }
  $stateReader = {
    $global:MasterStateReads++
    if ($global:MasterStateReads -eq 1) { return @{ name = 'wuauserv'; status = 'Running'; startMode = 'Auto' } }
    return @{ name = 'wuauserv'; status = 'Stopped'; startMode = 'Disabled' }
  }
  $global:MasterPromptRan = $false
  $prompt = { param($Message) $global:MasterPromptRan = $true; return $true }

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
  $result = Install-ApprovedBrand -Brand 'mercedes' -Channel 'beta' -AllowTestRoot -InstallRoot $installRoot -InstallerData $data -LogDirectory $logs -RepoRoot $fixture -AllowUncheckedProcesses -ApplySecurity -Arch 'x64' -Downloader $downloader -ToolRunner $runner -StateReader $stateReader -TamperPrompt $prompt
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
  Assert-True ($marker.shellRegistration -eq 'not-changed') 'marker recorded a shell change'
  Assert-True ($result.windowsUpdate -eq 'disabled') 'Windows Update tool was not recorded'
  Assert-True ($result.defender -eq 'blocked-cli-unverified') 'Defender was not left blocked'
  Assert-True (-not $global:MasterPromptRan) 'Tamper prompt ran while Defender is blocked'
  $wubCalls = @($global:MasterTestCalls | Where-Object { $_.exe -match 'Wub_x64.exe' -and $_.arguments -eq '/D /P' })
  Assert-True ($wubCalls.Count -eq 1) 'Wub_x64.exe /D /P was not the disable command'
  Assert-True (@($global:MasterTestCalls | Where-Object { $_.exe -match 'dControl' }).Count -eq 0) 'dControl was invoked'
  $journal = [System.IO.File]::ReadAllText((Join-Path $logs 'install-journal.log'))
  Assert-True ($journal.Contains('windows-update-pre')) 'pre-state was not logged'
  Assert-True ($journal.Contains('windows-update-post')) 'post-state was not logged'
  Assert-True ($journal.Contains('Feature Updates may reset')) 'feature-update note missing'
  Assert-True ($journal.Contains('defender-blocked')) 'defender block was not logged'
  $shortcuts = Read-JsonFile (Join-Path $data 'shortcuts-mercedes.json')
  $shortcutBlob = $shortcuts | ConvertTo-Json -Depth 6
  Assert-True ($shortcutBlob.Contains('Re-enable Windows Update and Defender')) 're-enable shortcut missing'
  Assert-True ($shortcutBlob.Contains('-Action enable')) 'enable action missing'
  Assert-True ($shortcutBlob.Contains('-Action reapply')) 'reapply action missing'
  Assert-True ($shortcutBlob.Contains('Uninstall-MasterBrand.ps1')) 'uninstall hook missing'

  $global:MasterTestCalls.Clear()
  $undo = Invoke-SecurityUndo -Brand 'mercedes' -Action 'enable' -InstallerData $data -RepoRoot $fixture -LogDirectory $logs -Arch 'x64' -ToolRunner $runner -StateReader $stateReader
  Assert-True ($undo.windowsUpdate -eq 'enabled') 'undo did not request enable'
  Assert-True ($undo.defender -eq 'blocked-cli-unverified') 'undo changed Defender'
  $enableCalls = @($global:MasterTestCalls | Where-Object { $_.arguments -eq '/E' -and $_.exe -match 'Wub_x64.exe' })
  Assert-True ($enableCalls.Count -eq 1) 'Wub /E was not the undo command'
  $global:MasterTestCalls.Clear()
  $reapply = Invoke-SecurityUndo -Brand 'mercedes' -Action 'reapply' -InstallerData $data -RepoRoot $fixture -LogDirectory $logs -Arch 'x86' -ToolRunner $runner -StateReader $stateReader
  Assert-True ($reapply.windowsUpdate -eq 'disabled') 'reapply did not request disable'
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
    Open-VerifiedBundle -Brand 'mercedes' -Release ([pscustomobject]@{ tag = 'mercedes-v1.2.3-beta.1'; version = '1.2.3-beta.1'; sha256 = $localObject.sha256; bytes = $localObject.bytes }) -ZipPath $localZip -ManifestPath $localManifest -Staging (Join-Path $temp 'local-stage')
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

  $tools = Join-Path $repo 'tools/security'
  $wub64 = Select-WubExecutable (Get-SecurityManifest $tools 'wub') 'x64'
  $wub32 = Select-WubExecutable (Get-SecurityManifest $tools 'wub') 'x86'
  Assert-True ($wub64.EndsWith('Wub_x64.exe')) '64-bit tool was not selected'
  Assert-True ($wub32.EndsWith('Wub.exe')) '32-bit tool was not selected'
  $defenderManifest = Read-JsonFile (Join-Path $tools 'dcontrol/tool-manifest.json')
  Assert-True ($defenderManifest.status -eq 'blocked-cli-unverified') 'Defender slot is not blocked'
  Assert-True (-not $defenderManifest.cliVerifiedOnWindows) 'Defender CLI is marked verified'
  $defenderArgs = @($defenderManifest.disableArgs | Where-Object { $_ })
  Assert-True ($defenderArgs.Count -eq 0) 'Defender disable arguments are pinned'
  $global:MasterTestCalls.Clear()
  $blocked = Invoke-DefenderDisable -ToolsRoot $tools -LogDirectory $logs -ToolRunner $runner -TamperPrompt $prompt
  Assert-True ($blocked.status -eq 'blocked-cli-unverified') 'shipped Defender slot ran'
  Assert-True ($global:MasterTestCalls.Count -eq 0) 'a tool started for the blocked Defender slot'

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

  $fakeRoot = Join-Path $temp 'fake-tools'
  $fakeDir = Join-Path $fakeRoot 'dcontrol'
  New-Item -ItemType Directory -Force -Path $fakeDir | Out-Null
  $fakeBytes = [Text.Encoding]::UTF8.GetBytes('not-a-real-tool')
  [System.IO.File]::WriteAllBytes((Join-Path $fakeDir 'fake-tool.exe'), $fakeBytes)
  $fakeManifest = [ordered]@{
    schema = 'diagnostic-workstation.approved-tool/v1'
    tool = 'dcontrol'
    status = 'wired'
    cliVerifiedOnWindows = $true
    disableArgs = @('-from-manifest')
    enableArgs = @('-enable-from-manifest')
    binaries = @([ordered]@{ name = 'fake-tool.exe'; sha256 = (Get-BytesSha256 $fakeBytes); bytes = $fakeBytes.Length })
    sidecars = @()
    blockedReason = 'test'
  }
  Write-Utf8NoBom (Join-Path $fakeDir 'tool-manifest.json') (($fakeManifest | ConvertTo-Json -Depth 6) + "`n")
  $global:MasterTestCalls.Clear()
  $tamperReads = @{ n = 0 }
  $stillOn = Invoke-DefenderDisable -ToolsRoot $fakeRoot -LogDirectory $logs -ToolRunner $runner -TamperReader {
    $tamperReads.n++
    return @{ tamper = 'on'; realtime = 'true' }
  } -TamperPrompt { param($Message) return $true }
  Assert-True ($stillOn.status -eq 'tamper-blocked') 'Tamper Protection did not block Defender'
  Assert-True ($global:MasterTestCalls.Count -eq 0) 'Defender tool ran while Tamper Protection stayed on'
  $global:MasterTestCalls.Clear()
  $tamperReads.n = 0
  $turnedOff = Invoke-DefenderDisable -ToolsRoot $fakeRoot -LogDirectory $logs -ToolRunner $runner -TamperReader {
    $tamperReads.n++
    if ($tamperReads.n -eq 1) { return @{ tamper = 'on' } }
    return @{ tamper = 'off' }
  } -TamperPrompt { param($Message) return $true }
  Assert-True ($turnedOff.status -eq 'disabled') 'verified manifest did not run after Tamper Protection was off'
  Assert-True ($global:MasterTestCalls[0].arguments -eq '-from-manifest') 'verified Defender path did not use manifest arguments'
  Assert-True ($global:MasterTestCalls[0].exe -match 'fake-tool.exe') 'verified path started a different executable'

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

  Assert-Throws { & (Join-Path $repo 'installer/Master/Probe-DefenderControlCli.ps1') } 'Refusing to start dControl'
  Write-Output 'Master installer checks passed.'
} catch {
  Write-Output $_.Exception.Message
  if ($_.ScriptStackTrace) { Write-Output $_.ScriptStackTrace }
  exit 1
} finally {
  Remove-Item Env:\MASTER_INSTALLER_FORBID_TOOL_EXECUTION -ErrorAction SilentlyContinue
  if (Test-Path $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
