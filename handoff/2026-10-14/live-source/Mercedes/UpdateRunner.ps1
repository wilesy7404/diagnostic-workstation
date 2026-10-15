# Downloads one Mercedes release, checks every file hash, then runs ApplyUpdate.ps1.
# Windows PowerShell 5.1. No universal tag prefix.
param(
  [string]$ZipUrl,
  [string]$ManifestUrl,
  [string]$Tag
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = $PSScriptRoot
$savedLibrary = $env:MERCEDES_UPDATER_LIBRARY
$env:MERCEDES_UPDATER_LIBRARY = '1'
. (Join-Path $root 'UpdateAgent.ps1')
if ([string]::IsNullOrEmpty($savedLibrary)) {
  Remove-Item Env:\MERCEDES_UPDATER_LIBRARY -ErrorAction SilentlyContinue
} else {
  $env:MERCEDES_UPDATER_LIBRARY = $savedLibrary
}

$status = Join-Path $root 'update-progress.json'

function Write-UpdateProgress([string]$stage, [string]$message, [int]$percent) {
  $payload = @{ state = $stage; message = $message; percent = $percent; checked = (Get-Date).ToString('o') }
  $tmp = "$status.$PID.tmp"
  Write-Utf8File $tmp ($payload | ConvertTo-Json -Compress)
  Move-Item -LiteralPath $tmp -Destination $status -Force
}

function Invoke-MercedesUpdate([string]$ZipUrl, [string]$ManifestUrl, [string]$Tag) {
  if ([string]::IsNullOrWhiteSpace($ZipUrl) -or [string]::IsNullOrWhiteSpace($ManifestUrl) -or [string]::IsNullOrWhiteSpace($Tag)) {
    throw 'ZipUrl, ManifestUrl, and Tag are required'
  }
  $settings = Resolve-MercedesUpdateSettings $root
  if (-not $settings.mercedesTags) { throw 'Mercedes updates require the mercedes-v prefix' }
  if ($Tag -notmatch $settings.pattern) { throw 'Invalid release version' }
  Test-GithubReleaseUrl $ZipUrl $settings.repo $Tag 'workstation.zip'
  Test-GithubReleaseUrl $ManifestUrl $settings.repo $Tag 'update-manifest.json'
  $stageName = 'Pending-' + ($Tag -replace '[^0-9A-Za-z.-]', '')
  $stage = Join-Path $root $stageName
  [void](New-Item -ItemType Directory -Force -Path $stage)
  $zip = Join-Path $stage 'workstation.zip'
  $manifestFile = Join-Path $stage 'update-manifest.json'
  Write-UpdateProgress 'downloading' 'Downloading update package' 10
  Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 120
  Write-UpdateProgress 'verifying' 'Checking the manifest' 40
  Invoke-WebRequest -Uri $ManifestUrl -OutFile $manifestFile -UseBasicParsing -TimeoutSec 30
  $manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-ManifestIdentity $manifest $Tag $settings.tagPrefix
  if ([string]::IsNullOrWhiteSpace([string]$manifest.sha256)) { throw 'Manifest checksum missing' }
  $zipItem = Get-Item -LiteralPath $zip
  if ($null -ne $manifest.bytes -and [int64]$zipItem.Length -ne [int64]$manifest.bytes) { throw 'Package size mismatch' }
  $zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($zipHash -ne ([string]$manifest.sha256).ToLowerInvariant()) { throw 'Package checksum mismatch' }
  Write-UpdateProgress 'verifying' 'Checking every file' 60
  $unpack = Join-Path $stage 'package'
  if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
  Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
  $verified = Test-ManifestPackage $unpack $manifestFile
  Assert-RequiredPackageFiles $verified
  Assert-ManifestIdentity $verified $Tag $settings.tagPrefix
  $bare = Get-BareVersion $Tag $settings.tagPrefix
  $versionPath = Join-RelativePath $unpack 'version.json'
  $packageVersion = [string](Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json).version
  if ($packageVersion -ne $bare) { throw 'Package version mismatch' }
  foreach ($entry in @($verified.files)) {
    $relative = Get-SafeRelativePath ([string]$entry.path)
    if ($relative -notlike '*.ps1') { continue }
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-RelativePath $unpack $relative), [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "Invalid script $relative" }
  }
  $worker = Join-Path $root 'ApplyUpdate.ps1'
  if (-not (Test-Path -LiteralPath $worker)) { throw 'Recovery installer missing' }
  Write-UpdateProgress 'installing' 'Installing. Home and the dock may restart.' 75
  $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $worker + '" -PackageDirectory "' + $unpack + '" -ManifestPath "' + $manifestFile + '" -Tag "' + $Tag + '"'
  $process = Start-Process -FilePath $ps -ArgumentList $arg -WindowStyle Hidden -PassThru
  if (-not $process.WaitForExit(180000)) { throw 'Installer did not finish within 3 minutes' }
  $process.Refresh()
  if ($process.ExitCode -ne 0) { throw 'Update worker failed and restored the previous install' }
  $installed = ''
  try { $installed = [string](Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch {}
  if ($installed -ne $bare) { throw 'Installed version does not match the release' }
  Write-UpdateProgress 'success' 'Update installed. Home and the dock were verified.' 100
}

if ($env:MERCEDES_UPDATER_LIBRARY -ne '1') {
  try {
    Invoke-MercedesUpdate -ZipUrl $ZipUrl -ManifestUrl $ManifestUrl -Tag $Tag
  } catch {
    if (Test-OfflineError $_) { Write-UpdateProgress 'error' 'Offline. Nothing was changed.' 0 }
    else { Write-UpdateProgress 'error' 'Update failed. The previous install was kept.' 0 }
    exit 1
  }
}
