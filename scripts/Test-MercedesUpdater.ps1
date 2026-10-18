# Syntax and file-level checks for the Mercedes updater. No install, no network, no release.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'handoff/2026-10-14/live-source/Mercedes'
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True([bool]$condition, [string]$message) {
  if (-not $condition) { throw $message }
}

function Assert-Throws([scriptblock]$action, [string]$message) {
  $threw = $false
  try { & $action } catch { $threw = $true }
  if (-not $threw) { throw $message }
}

if ([string]::IsNullOrWhiteSpace($env:WINDIR) -or -not (Test-Path -LiteralPath $env:WINDIR)) { $env:WINDIR = '/tmp' }
$env:MERCEDES_UPDATER_LIBRARY = '1'
. (Join-Path $source 'ApplyUpdate.ps1')
Assert-True ($env:MERCEDES_UPDATER_LIBRARY -eq '1') 'library mode started the updater'

$pattern = Get-TagPattern 'mercedes-v'
Assert-True ('mercedes-v0.1.3-beta.1' -match $pattern) 'beta tag was rejected'
Assert-True ('mercedes-v0.1.3' -match $pattern) 'stable tag was rejected'
Assert-True (-not ('universal-v0.1.3-beta.1' -match $pattern)) 'universal tag was accepted'
Assert-True (-not ('v0.1.3-beta.1' -match $pattern)) 'bare v tag was accepted'
Assert-True (-not ('mercedes-v0.1.3-beta' -match $pattern)) 'incomplete beta tag was accepted'
Assert-True (-not ('mercedes-v0.1.3-beta.1' -match (Get-TagPattern 'universal-v'))) 'universal pattern matched a Mercedes tag'

$older = Get-VersionRank '0.1.2-beta.1' 'mercedes-v'
$same = Get-VersionRank 'mercedes-v0.1.2-beta.1' 'mercedes-v'
$newer = Get-VersionRank 'mercedes-v0.1.3-beta.1' 'mercedes-v'
$stable = Get-VersionRank 'mercedes-v0.1.3' 'mercedes-v'
Assert-True ($older -eq $same) 'installed version and tag did not rank equal'
Assert-True ($newer -gt $older) '0.1.3-beta.1 did not outrank 0.1.2-beta.1'
Assert-True ($stable -gt $newer) 'stable did not outrank its beta'
Assert-True ((Get-BareVersion 'mercedes-v0.1.3-beta.1' 'mercedes-v') -eq '0.1.3-beta.1') 'bare version mismatch'

try { throw (New-Object System.Net.WebException 'The remote name could not be resolved') } catch { $offline = $_ }
Assert-True (Test-OfflineError $offline) 'name resolution was not offline'
try { throw 'Package checksum mismatch' } catch { $online = $_ }
Assert-True (-not (Test-OfflineError $online)) 'checksum failure was treated as offline'

$goodUrl = 'https://github.com/wilesy7404/diagnostic-workstation/releases/download/mercedes-v0.1.3-beta.1/workstation.zip'
Test-GithubReleaseUrl $goodUrl 'wilesy7404/diagnostic-workstation' 'mercedes-v0.1.3-beta.1' 'workstation.zip'
Assert-Throws { Test-GithubReleaseUrl 'https://example.com/workstation.zip' 'wilesy7404/diagnostic-workstation' 'mercedes-v0.1.3-beta.1' 'workstation.zip' } 'foreign URL was accepted'
Assert-Throws { Test-GithubReleaseUrl ($goodUrl + '.evil') 'wilesy7404/diagnostic-workstation' 'mercedes-v0.1.3-beta.1' 'workstation.zip' } 'suffixed URL was accepted'

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('mb-upd-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $seeded = Resolve-MercedesUpdateSettings $tmp
  Assert-True ($seeded.tagPrefix -eq 'mercedes-v') 'missing settings were not seeded with mercedes-v'
  Assert-True ($seeded.mercedesTags) 'seeded settings were not used'
  $before = [System.IO.File]::ReadAllText((Join-Path $tmp 'update-settings.json'))
  $null = Resolve-MercedesUpdateSettings $tmp
  $after = [System.IO.File]::ReadAllText((Join-Path $tmp 'update-settings.json'))
  Assert-True ($before -eq $after) 'existing mercedes-v settings were rewritten'

  $legacyDir = Join-Path $tmp 'legacy'
  New-Item -ItemType Directory -Path $legacyDir | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $legacyDir 'update-settings.json'), (@'
{
  "channel": "beta",
  "source": "public-github-releases",
  "repo": "wilesy7404/diagnostic-workstation",
  "tagPrefix": "universal-v"
}
'@))
  $migrated = Resolve-MercedesUpdateSettings $legacyDir
  $legacyText = [System.IO.File]::ReadAllText((Join-Path $legacyDir 'update-settings.json'))
  Assert-True ($migrated.mercedesTags) 'universal-v was not migrated'
  Assert-True ($legacyText -match 'mercedes-v') 'migrated file is missing mercedes-v'
  Assert-True ($legacyText -notmatch 'universal-v') 'migrated file still contains universal-v'
  Assert-True ($legacyText -match 'wilesy7404/diagnostic-workstation') 'migration dropped the repository'
  Assert-True ($legacyText -match '"channel":\s*"beta"') 'migration dropped the channel'

  $foreignDir = Join-Path $tmp 'foreign'
  New-Item -ItemType Directory -Path $foreignDir | Out-Null
  $foreignBody = '{"channel":"beta","repo":"wilesy7404/diagnostic-workstation","tagPrefix":"bmw-v"}'
  [System.IO.File]::WriteAllText((Join-Path $foreignDir 'update-settings.json'), $foreignBody)
  $foreign = Resolve-MercedesUpdateSettings $foreignDir
  Assert-True (-not $foreign.mercedesTags) 'a non-Mercedes prefix was treated as Mercedes'
  Assert-True ($foreign.tagPrefix -eq 'bmw-v') 'a custom prefix was overwritten'
  Assert-True (([System.IO.File]::ReadAllText((Join-Path $foreignDir 'update-settings.json'))) -eq $foreignBody) 'custom settings file changed'

  Assert-Throws { Get-SafeRelativePath '../Launcher.ps1' } '.. path was accepted'
  Assert-Throws { Get-SafeRelativePath 'branding/../../Launcher.ps1' } 'nested .. path was accepted'
  Assert-Throws { Get-SafeRelativePath '/etc/passwd' } 'absolute path was accepted'

  $install = Join-Path $tmp 'install'
  $package = Join-Path $tmp 'package'
  $backup = Join-Path $tmp 'backup'
  New-Item -ItemType Directory -Path $install, $package | Out-Null
  function Write-Sample([string]$path, [string]$text) {
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($path, $text)
  }
  Write-Sample (Join-RelativePath $install 'Launcher.ps1') "Write-Output 'old'"
  Write-Sample (Join-RelativePath $install 'apps.json') '{"apps":[{"name":"USER"}]}'
  Write-Sample (Join-RelativePath $install 'controls-pin.json') '{"pin":"keep"}'
  Write-Sample (Join-RelativePath $install 'wallpaper.png') 'WALLPAPER'
  Write-Sample (Join-RelativePath $install 'profile.json') '{"displayName":"Mercedes-Benz","apps":[{"name":"Kept"}]}'
  Write-Sample (Join-RelativePath $package 'Launcher.ps1') "Write-Output 'new'"
  Write-Sample (Join-RelativePath $package 'apps.json') '{"apps":[{"name":"EVIL"}]}'
  Write-Sample (Join-RelativePath $package 'controls-pin.json') '{"pin":"EVIL"}'
  Write-Sample (Join-RelativePath $package 'wallpaper.png') 'EVIL'
  Write-Sample (Join-RelativePath $package 'profile.json') '{"displayName":"Other","apps":[{"name":"EVIL"}]}'
  Write-Sample (Join-RelativePath $package 'branding/mercedes.png') 'PNG'
  $entries = @()
  foreach ($relative in @('Launcher.ps1','apps.json','controls-pin.json','wallpaper.png','profile.json','branding/mercedes.png')) {
    $full = Join-RelativePath $package $relative
    $entries += [pscustomobject]@{
      path = $relative
      bytes = [int64](Get-Item -LiteralPath $full).Length
      sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
  $manifest = [pscustomobject]@{ files = $entries }
  $savedRoot = $root
  $root = $install
  Backup-ReplacedFiles $backup $manifest
  Copy-PackageFiles $package $manifest
  Assert-True (([System.IO.File]::ReadAllText((Join-RelativePath $install 'Launcher.ps1'))) -eq "Write-Output 'new'") 'Launcher was not updated'
  Assert-True (([System.IO.File]::ReadAllText((Join-RelativePath $install 'apps.json'))) -match 'USER') 'apps.json was overwritten'
  Assert-True (([System.IO.File]::ReadAllText((Join-RelativePath $install 'controls-pin.json'))) -match 'keep') 'PIN file was overwritten'
  Assert-True (([System.IO.File]::ReadAllText((Join-RelativePath $install 'wallpaper.png'))) -eq 'WALLPAPER') 'wallpaper file was overwritten'
  Assert-True (([System.IO.File]::ReadAllText((Join-RelativePath $install 'profile.json'))) -match 'Kept') 'profile apps were overwritten'
  Assert-True (([System.IO.File]::ReadAllText((Join-RelativePath $install 'branding/mercedes.png'))) -eq 'PNG') 'new package file was not copied'
  [System.IO.File]::WriteAllText((Join-RelativePath $install 'Launcher.ps1'), 'broken')
  Restore-InstallBackup $backup
  Assert-True (([System.IO.File]::ReadAllText((Join-RelativePath $install 'Launcher.ps1'))) -eq "Write-Output 'old'") 'rollback did not restore Launcher'
  Assert-True (-not (Test-Path -LiteralPath (Join-RelativePath $install 'branding/mercedes.png'))) 'rollback left a newly added file'
  Assert-True (([System.IO.File]::ReadAllText((Join-RelativePath $install 'apps.json'))) -match 'USER') 'rollback touched apps.json'
  $root = $savedRoot

  $plainInstall = Join-Path $tmp 'plain-install'
  $plainPackage = Join-Path $tmp 'plain-package'
  New-Item -ItemType Directory -Path $plainInstall, $plainPackage | Out-Null
  Write-Sample (Join-RelativePath $plainInstall 'profile.json') '{"displayName":"Mercedes-Benz","id":"mercedes"}'
  Write-Sample (Join-RelativePath $plainPackage 'profile.json') '{"displayName":"Mercedes-Benz","id":"mercedes","accent":"#C0C6CE"}'
  $root = $plainInstall
  Copy-ProfilePreservingApps (Join-RelativePath $plainPackage 'profile.json') (Join-RelativePath $plainInstall 'profile.json')
  Assert-True (([System.IO.File]::ReadAllText((Join-RelativePath $plainInstall 'profile.json'))) -match '#C0C6CE') 'profile without apps was not updated'

  $restoreRoot = Join-Path $tmp 'restore-root'
  $restoreBackup = Join-Path $tmp 'restore-backup'
  New-Item -ItemType Directory -Path $restoreRoot, $restoreBackup | Out-Null
  $savedLog = $log
  $root = $restoreRoot
  $log = Join-Path $restoreRoot 'update-install.log'
  Write-Sample (Join-RelativePath $restoreRoot 'Launcher.ps1') 'LIVE'
  Write-Sample (Join-RelativePath $restoreRoot 'WorkstationManager.exe') 'SAME'
  Write-Sample (Join-RelativePath $restoreBackup 'WorkstationManager.exe') 'SAME'
  Write-Sample (Join-RelativePath $restoreBackup 'Dock.ps1') 'RESTORED'
  $manager = Join-RelativePath $restoreRoot 'WorkstationManager.exe'
  $stamp = [datetime]::SpecifyKind([datetime]'2020-01-01T00:00:00', 'Utc')
  [System.IO.File]::SetLastWriteTimeUtc($manager, $stamp)
  Write-Utf8File (Join-Path $restoreBackup 'backup-map.txt') "existed`tmissing.ps1`nexisted`tWorkstationManager.exe`nexisted`tDock.ps1`n"
  $restoreErrors = @(Restore-InstallBackup $restoreBackup)
  Assert-True ($restoreErrors.Count -ge 1) 'a missing backup file did not report an error'
  Assert-True (([System.IO.File]::GetLastWriteTimeUtc($manager)).Year -eq 2020) 'matching WorkstationManager.exe was copied'
  Assert-True (([System.IO.File]::ReadAllText((Join-RelativePath $restoreRoot 'Dock.ps1'))) -eq 'RESTORED') 'restore stopped after the first file error'
  Assert-True (-not (Test-WindowReady 'Dock' 'Workstation Glass Dock')) 'missing dock process was treated as ready'
  Get-ProcessWindowTitles $PID | Out-Null
  $root = $savedRoot
  $log = $savedLog

  $bad = [pscustomobject]@{ files = @([pscustomobject]@{ path = 'Launcher.ps1'; bytes = $entries[0].bytes; sha256 = ('0' * 64) }) }
  $badPath = Join-Path $tmp 'bad-manifest.json'
  $bad | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $badPath -Encoding utf8
  Assert-Throws { Test-ManifestPackage $package $badPath } 'bad checksum was accepted'
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$agent = Get-Content -LiteralPath (Join-Path $source 'UpdateAgent.ps1') -Raw
$runner = Get-Content -LiteralPath (Join-Path $source 'UpdateRunner.ps1') -Raw
$apply = Get-Content -LiteralPath (Join-Path $source 'ApplyUpdate.ps1') -Raw
Assert-True ($agent -notmatch '\^universal-v') 'UpdateAgent still hardcodes a universal tag regex'
Assert-True ($runner -notmatch '\^universal-v') 'UpdateRunner still hardcodes a universal tag regex'
Assert-True ($apply -notmatch '\^universal-v') 'ApplyUpdate still hardcodes a universal tag regex'
Assert-True ($agent -match 'tagPrefix') 'UpdateAgent does not read tagPrefix'
Assert-True ($apply -match 'Start-WorkstationUi') 'rollback helper is missing'
Assert-True ($apply -notmatch 'MainWindowHandle') 'readiness still requires MainWindowHandle'
Assert-True ($apply -match 'EnumWindows') 'readiness does not enumerate windows by title'
Assert-True ($apply -match 'Get-WorkstationProcess') 'readiness does not check the script process'
Assert-True ($apply -match 'A running manager is stopped only when the backup bytes differ') 'restore can overwrite a running manager'
Assert-True ($apply -match 'Test-SameFileHash') 'restore does not skip identical files'
Assert-True ($agent -match 'while \(-not \$ownsMutex\)') 'update agent still exits when the mutex is busy'
Assert-True ($agent -match 'Start-Sleep -Seconds 30') 'update agent does not idle while another copy is running'
Assert-True ($agent -notmatch 'WaitOne\(0\)\) \{ exit 0 \}') 'update agent exits cleanly when the mutex is busy'
Assert-True ($apply -match "foreach \(\`$name in @\('Launcher', 'Dock'\)\)") 'rollback does not start both Launcher and Dock'
Assert-True ($apply -match 'Resume-LauncherAndDock \$homeTitle') 'failure path does not resume both windows'
$resume = [regex]::Match($apply, '(?sm)function Resume-LauncherAndDock.*?^\}')
Assert-True ($resume.Success -and $resume.Value -match 'Start-WorkstationUi') 'resume does not start the UI directly'
Assert-True ($agent -match '#0C121C' -and $agent -match '#C0C6CE') 'update dialog is missing the Home colors'
Assert-True ($agent -match 'AllowsTransparency="True"' -and $agent -match 'CornerRadius="14"' -and $agent -match '#2A3442' -and $agent -match '#1A2230' -and $agent -match '#8A96A6') 'update dialog is missing the Mercedes chrome'
Assert-True ($agent -match 'Software Update') 'update dialog title is missing'
Assert-True ($agent -notmatch '#FFFFFF' -and $agent -notmatch 'Brushes\]::White') 'update dialog still uses white'
$templates = [regex]::Matches($agent, '(?s)<ControlTemplate(\s[^>]*)?>')
Assert-True ($templates.Count -ge 4) 'update dialog is missing its templates'
foreach ($template in $templates) {
  Assert-True ($template.Value -match 'xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"') 'a ControlTemplate is missing xmlns:x'
}
Assert-True ((Get-ReleaseSummary "# Hello`r`n`nSecond") -eq 'Hello') 'release summary was not simplified'
Assert-True ((Get-ReleaseSummary '') -eq '') 'empty release notes were not skipped'

$launcher = Get-Content -LiteralPath (Join-Path $source 'Launcher.ps1') -Raw
Assert-True ($launcher -match '#C0C6CE') 'Launcher silver accent is missing'
Assert-True ($launcher -notmatch '#D0D5DB') 'Launcher still uses the retired admin silver'
Assert-True ($launcher -match 'DWMWA_WINDOW_CORNER_PREFERENCE') 'Admin dialog is missing the rounded-corner chrome'
Assert-True ($launcher -match 'BorderThickness="0"') 'Admin dialog still has an outer border'
Assert-True ($launcher -match 'No AllowsTransparency') 'Admin dialog does not record the opaque chrome'
Assert-True ($launcher -notmatch 'AllowsTransparency\s*=') 'Admin dialog sets AllowsTransparency'
Assert-True ($launcher -match 'Bold description text on home cards') 'Bold card description setting is missing'
Assert-True ($launcher -match 'offline.\{.s=.Offline') 'footer does not show offline'
Assert-True ($launcher -notmatch 'UNIVERSAL_BRAND_WORKSTATION') 'footer still uses the long brand status'
Assert-True ($launcher -match 'LAUNCHER SETTINGS') 'settings popup was removed'

$scripts = @(Get-ChildItem -LiteralPath $source -Filter '*.ps1' -File)
$scripts += Get-Item -LiteralPath (Join-Path $repo 'scripts/Test-MercedesUpdater.ps1')
$authored = @(
  'UpdateAgent.ps1','UpdateRunner.ps1','ApplyUpdate.ps1','Launcher.ps1','Test-MercedesUpdater.ps1'
)
foreach ($file in $scripts) {
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
  if (@($errors).Count -gt 0) { throw ($file.Name + ': ' + $errors[0].Message) }
  if ($authored -notcontains $file.Name) { continue }
  $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $nonAscii = $false
  foreach ($byte in $bytes) { if ($byte -gt 127) { $nonAscii = $true; break } }
  if ($nonAscii -and -not $hasBom) { throw ($file.Name + ' has non-ASCII text without a UTF-8 BOM') }
}

$workflow = Get-Content -LiteralPath (Join-Path $repo '.github/workflows/mercedes-release-bundle.yml') -Raw
Assert-True ($workflow -notmatch 'gh release') 'workflow publishes a release'
Assert-True ($workflow -notmatch 'contents:\s*write') 'workflow requests write permission'
Assert-True ($workflow -match 'workflow_dispatch') 'workflow is not manual'
Assert-True ($workflow -match "default:\s*'0\.1\.3-beta\.3'") 'workflow default is not 0.1.3-beta.3'
Assert-True ($workflow -notmatch 'inputs\.version \}\}"\s*=') 'workflow still hard-pins one version'

$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { throw 'python3 is required to build the bundle' }
& python3 (Join-Path $repo 'scripts/build-mercedes-bundle.py') '0.1.3-beta.3'
if ($LASTEXITCODE -ne 0) { throw 'bundle build failed' }
$dist = Join-Path $repo 'dist/mercedes-v0.1.3-beta.3'
$builtManifest = Get-Content -LiteralPath (Join-Path $dist 'update-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($builtManifest.tag -eq 'mercedes-v0.1.3-beta.3') 'bundle tag is wrong'
Assert-True ($builtManifest.version -eq '0.1.3-beta.3') 'bundle version is wrong'
Assert-True (@($builtManifest.files).Count -eq 20) 'bundle does not contain 20 files'
$logoNames = @($builtManifest.files | ForEach-Object { [string]$_.path } | Where-Object { $_ -like 'branding/*.png' })
Assert-True ($logoNames.Count -eq 1 -and $logoNames[0] -eq 'branding/mercedes.png') 'bundle did not ship only the Mercedes logo'
Assert-True (@($builtManifest.files | Where-Object { $_.path -eq 'profile.json' }).Count -eq 1) 'profile.json was not packaged'
$zipBytes = [System.IO.File]::ReadAllBytes((Join-Path $dist 'workstation.zip'))
Assert-True ([int64]$zipBytes.Length -eq [int64]$builtManifest.bytes) 'zip size does not match the manifest'
$zipHash = (Get-FileHash -LiteralPath (Join-Path $dist 'workstation.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-True ($zipHash -eq ([string]$builtManifest.sha256).ToLowerInvariant()) 'zip checksum does not match the manifest'
$extract = Join-Path ([System.IO.Path]::GetTempPath()) ('mb-zip-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $extract | Out-Null
try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $dist 'workstation.zip'), $extract)
  $verified = Test-ManifestPackage $extract (Join-Path $dist 'update-manifest.json')
  Assert-RequiredPackageFiles $verified
  Assert-ManifestIdentity $verified 'mercedes-v0.1.3-beta.3' 'mercedes-v'
  foreach ($name in @('apps.json','controls-pin.json','update-settings.json')) {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $extract $name))) "$name was packaged"
  }
  $packagedVersion = [System.IO.File]::ReadAllText((Join-Path $extract 'version.json'))
  Assert-True ($packagedVersion -eq '{"version":"0.1.3-beta.3"}') 'version.json is not the canonical beta.3 file'
  $bundleScripts = @(Get-ChildItem -LiteralPath $extract -Recurse -Filter '*.ps1' -File)
  Assert-True ($bundleScripts.Count -gt 0) 'bundle has no scripts'
  foreach ($file in $bundleScripts) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw ($file.Name + ' did not parse: ' + $errors[0].Message) }
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $nonAscii = $false
    foreach ($byte in $bytes) { if ($byte -gt 127) { $nonAscii = $true; break } }
    if ($nonAscii -and -not $hasBom) { throw ($file.Name + ' is non-ASCII without a UTF-8 BOM') }
  }
  foreach ($name in @('SystemPanel.ps1','WorkstationControls.ps1')) {
    $sourceBytes = [System.IO.File]::ReadAllBytes((Join-Path $source $name))
    $bundleBytes = [System.IO.File]::ReadAllBytes((Join-Path $extract $name))
    $sourceHasBom = ($sourceBytes.Length -ge 3 -and $sourceBytes[0] -eq 0xEF -and $sourceBytes[1] -eq 0xBB -and $sourceBytes[2] -eq 0xBF)
    Assert-True (-not $sourceHasBom) "$name source was rewritten with a BOM"
    Assert-True ($bundleBytes.Length -eq ($sourceBytes.Length + 3)) "$name bundle size is not the source plus a BOM"
    Assert-True ($bundleBytes[0] -eq 0xEF -and $bundleBytes[1] -eq 0xBB -and $bundleBytes[2] -eq 0xBF) "$name bundle is missing the UTF-8 BOM"
    for ($i = 0; $i -lt $sourceBytes.Length; $i++) {
      if ($bundleBytes[$i + 3] -ne $sourceBytes[$i]) { throw "$name changed a byte other than the prepended BOM" }
    }
  }
  Assert-True (Test-Path -LiteralPath (Join-Path $extract 'profile.json')) 'extracted bundle is missing profile.json'
  Assert-True (Test-Path -LiteralPath (Join-Path $extract 'branding/mercedes.png')) 'extracted bundle is missing the Mercedes logo'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $extract 'branding/bmw.png'))) 'extracted bundle contains the BMW logo'
} finally {
  Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
}

& python3 (Join-Path $repo 'scripts/build-mercedes-bundle.py') '0.1.3-beta.4'
if ($LASTEXITCODE -ne 0) { throw 'parameterized bundle build failed' }
$later = Join-Path $repo 'dist/mercedes-v0.1.3-beta.4'
$laterManifest = Get-Content -LiteralPath (Join-Path $later 'update-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($laterManifest.tag -eq 'mercedes-v0.1.3-beta.4') 'a later version still required a guard edit'
$sourceVersion = [System.IO.File]::ReadAllText((Join-Path $source 'version.json'))
Assert-True ($sourceVersion -eq '{"version":"0.1.3-beta.3"}') 'building another version rewrote source version.json'
Remove-Item -LiteralPath $later -Recurse -Force

Write-Output 'Mercedes updater checks passed'
