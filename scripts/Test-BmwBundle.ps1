# BMW bundle checks. No network, no release, no install onto a machine.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { throw 'python3 is required to build the BMW bundle' }

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

$workflow = Get-Content -LiteralPath (Join-Path $repo '.github/workflows/bmw-release-bundle.yml') -Raw
Assert-True ($workflow -notmatch 'gh release') 'BMW workflow publishes a release'
Assert-True ($workflow -notmatch 'contents:\s*write') 'BMW workflow requests write permission'
Assert-True ($workflow -match 'workflow_dispatch') 'BMW workflow is not manual'
Assert-True ($workflow -match "default:\s*'1\.0\.2-beta\.1'") 'BMW workflow default is not 1.0.2-beta.1'
Assert-True ($workflow -notmatch 'inputs\.version \}\}"\s*=') 'BMW workflow hard-pins one version'

$staging = Join-Path $repo 'bundles/bmw/staging'
$stagingLauncher = Join-Path $staging 'Launcher.ps1'
$stagingProfile = Join-Path $staging 'profile.json'
if (-not (Test-Path -LiteralPath $stagingLauncher) -or -not (Test-Path -LiteralPath $stagingProfile)) {
  throw 'bundles/bmw/staging is missing Launcher.ps1 or profile.json'
}
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('bmw-bundle-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
  $out = Join-Path $temp 'dist'
  & python3 (Join-Path $repo 'scripts/build-bmw-bundle.py') '1.0.2-beta.1' $staging $out
  if ($LASTEXITCODE -ne 0) { throw 'BMW bundle build failed' }
  $dist = Join-Path $out 'bmw-v1.0.2-beta.1'
  $manifest = Get-Content -LiteralPath (Join-Path $dist 'update-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-True ($manifest.brand -eq 'bmw') 'BMW manifest brand is wrong'
  Assert-True ($manifest.tag -eq 'bmw-v1.0.2-beta.1') 'BMW manifest tag is wrong'
  Assert-True ($manifest.version -eq '1.0.2-beta.1') 'BMW manifest version is wrong'
  Assert-True ($manifest.asset -eq 'workstation.zip') 'BMW manifest asset is wrong'
  Assert-True (@($manifest.files).Count -eq 15) 'BMW bundle does not contain 15 files'
  $names = @($manifest.files | ForEach-Object { [string]$_.path })
  foreach ($banned in @(
    'apps.json',
    'Launcher.before-shortcut-refresh-20261012-152554.ps1',
    'Launcher.before-updater-20261012-153610.ps1',
    'BUILD-MANIFEST.json',
    'TRANSFER-README.txt',
    'branding/mercedes.png'
  )) {
    Assert-True ($names -notcontains $banned) "$banned was packaged"
  }
  Assert-True ($names -contains 'profile.json') 'profile.json was not packaged'
  Assert-True ($names -contains 'Launcher.ps1') 'Launcher.ps1 was not packaged'
  Assert-True ($names -contains 'version.json') 'version.json was not packaged'
  Assert-True ($names -contains 'branding/bmw.png') 'BMW logo was not packaged'
  $logos = @($names | Where-Object { $_ -like 'branding/*.png' })
  Assert-True ($logos.Count -eq 1) 'BMW bundle shipped another brand logo'
  $zipPath = Join-Path $dist 'workstation.zip'
  $zipBytes = [System.IO.File]::ReadAllBytes($zipPath)
  Assert-True ([int64]$zipBytes.Length -eq [int64]$manifest.bytes) 'BMW zip size does not match the manifest'
  $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert-True ($zipHash -eq ([string]$manifest.sha256).ToLowerInvariant()) 'BMW zip checksum does not match the manifest'

  $extract = Join-Path $temp 'extract'
  New-Item -ItemType Directory -Path $extract | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extract)
  $versionText = [System.IO.File]::ReadAllText((Join-Path $extract 'version.json'))
  Assert-True ($versionText -eq '{"version":"1.0.2-beta.1"}') 'BMW version.json is not canonical'
  $agent = [System.IO.File]::ReadAllText((Join-Path $extract 'UpdateAgent.ps1'))
  $runner = [System.IO.File]::ReadAllText((Join-Path $extract 'UpdateRunner.ps1'))
  $retired = '^v\d+\.\d+\.\d+(-beta\.\d+)?$'
  $approved = '^bmw-v\d+\.\d+\.\d+(-beta\.\d+)?$'
  Assert-True ($agent.Contains($approved)) 'UpdateAgent does not look for bmw-v tags'
  Assert-True ($runner.Contains($approved)) 'UpdateRunner does not look for bmw-v tags'
  Assert-True (-not $agent.Contains($retired)) 'UpdateAgent still matches retired v* tags'
  Assert-True (-not $runner.Contains($retired)) 'UpdateRunner still matches retired v* tags'
  Assert-True (-not $runner.Contains('$Tag.Substring(1)')) 'UpdateRunner still strips a single v from the tag'
  foreach ($name in @('UpdateAgent.ps1','UpdateRunner.ps1','Launcher.ps1')) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $extract $name), [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw ($name + ' did not parse: ' + $errors[0].Message) }
  }
  $dock = [System.IO.File]::ReadAllBytes((Join-Path $extract 'Dock.ps1'))
  Assert-True ($dock.Length -ge 3 -and $dock[0] -eq 0xEF -and $dock[1] -eq 0xBB -and $dock[2] -eq 0xBF) 'Dock.ps1 lost the live-export UTF-8 BOM'
  $packedLauncher = (Get-FileHash -LiteralPath (Join-Path $extract 'Launcher.ps1') -Algorithm SHA256).Hash
  $packedProfile = (Get-FileHash -LiteralPath (Join-Path $extract 'profile.json') -Algorithm SHA256).Hash
  $wantLauncher = (Get-FileHash -LiteralPath $stagingLauncher -Algorithm SHA256).Hash
  $wantProfile = (Get-FileHash -LiteralPath $stagingProfile -Algorithm SHA256).Hash
  Assert-True ($packedLauncher -eq $wantLauncher) 'bundle Launcher.ps1 is not the staging file'
  Assert-True ($packedProfile -eq $wantProfile) 'bundle profile.json is not the staging file'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $extract 'apps.json'))) 'staging apps.json was packaged'

  & python3 (Join-Path $repo 'scripts/build-bmw-bundle.py') '1.0.2-beta.2' $staging (Join-Path $temp 'later')
  if ($LASTEXITCODE -ne 0) { throw 'parameterized BMW bundle build failed' }
  $laterManifest = Get-Content -LiteralPath (Join-Path $temp 'later/bmw-v1.0.2-beta.2/update-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-True ($laterManifest.tag -eq 'bmw-v1.0.2-beta.2') 'a later BMW version required a guard edit'

  & python3 (Join-Path $repo 'scripts/build-bmw-bundle.py') '1.0.2-beta.1'
  if ($LASTEXITCODE -ne 0) { throw 'default BMW bundle build failed' }
  $defaultZip = Join-Path $repo 'dist/bmw-v1.0.2-beta.1/workstation.zip'
  Assert-True (Test-Path -LiteralPath $defaultZip) 'default BMW build did not write workstation.zip'
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  $defaultOut = Join-Path $repo 'dist/bmw-v1.0.2-beta.1'
  if (Test-Path -LiteralPath $defaultOut) { Remove-Item -LiteralPath $defaultOut -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output 'BMW bundle checks passed'
