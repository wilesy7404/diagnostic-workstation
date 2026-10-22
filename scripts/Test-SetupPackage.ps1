# Layout and brand-report checks for the master installer package. No network and no PS2EXE.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

$env:MASTER_PACKAGE_LIBRARY = '1'
. (Join-Path -Path $PSScriptRoot -ChildPath 'Build-MasterInstallerPackage.ps1')
Remove-Item Env:MASTER_PACKAGE_LIBRARY

. (Join-Path -Path (Join-Path -Path (Join-Path -Path $repo -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'lib/Common.ps1')
. (Join-Path -Path (Join-Path -Path (Join-Path -Path $repo -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'lib/Catalog.ps1')
. (Join-Path -Path (Join-Path -Path (Join-Path -Path $repo -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'lib/SetupPlan.ps1')

$temp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('setup-package-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
  $out = Join-Path -Path $temp -ChildPath 'out'
  $zip = Invoke-MasterPackageBuild -OutputDirectory $out -SkipExeCompile
  Assert-True (Test-Path -LiteralPath $zip -PathType Leaf) 'package zip was not written'
  $side = $zip + '.sha256'
  Assert-True (Test-Path -LiteralPath $side -PathType Leaf) 'zip sidecar was not written'
  $sideText = [System.IO.File]::ReadAllText($side).Trim()
  $zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert-True ($sideText.StartsWith($zipHash + '  ')) 'zip sidecar does not match the zip bytes'
  Assert-ReproducibleZip $zip
  $entryHash = Get-ZipEntrySha256 $zip 'catalog/catalog.json'
  Assert-True ($entryHash -eq 'c514717b22c24b68c2a445e08f02131e1f9fd62d600bcf292f88f8a4e1597aba') 'catalog.json inside the zip does not match the pin'

  $extracted = Join-Path -Path $temp -ChildPath 'extracted'
  New-Item -ItemType Directory -Force -Path $extracted | Out-Null
  Import-ZipSupport
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $extracted)
  Assert-PackageChecksums $extracted
  foreach ($rel in @(
    'catalog/catalog.json',
    'catalog/catalog.sha256',
    'catalog/catalog.json.release.sig',
    'tools/security/wub/Wub_x64.exe',
    'tools/security/wub/Wub.exe',
    'tools/security/wub/Wub.ini',
    'tools/security/wub/tool-manifest.json'
  )) {
    Assert-SameFileBytes (Join-PackageRelative $repo $rel) (Join-PackageRelative $extracted $rel)
  }
  $files = @(Get-PackageRelativeFiles $extracted)
  foreach ($required in @(
    'Setup.exe',
    'README-INSTALL.txt',
    'SHA256SUMS.txt',
    'installer/Master/Install-Master.ps1',
    'installer/Master/Enable-Security.ps1',
    'installer/Master/Uninstall-MasterBrand.ps1',
    'installer/Master/lib/Defender.ps1',
    'installer/Master/lib/Security.ps1',
    'installer/Master/lib/SetupPlan.ps1',
    'brands/mercedes/release.json',
    'brands/bmw/release.json',
    'keys/qa.pub',
    'keys/release.pub'
  )) {
    $found = $false
    foreach ($item in $files) { if ($item -eq $required) { $found = $true; break } }
    Assert-True $found "package is missing $required"
  }
  foreach ($item in $files) {
    Assert-True (-not ($item -match '(?i)workstation\.zip$')) "package contains a brand zip: $item"
    Assert-True (-not ($item -match '(?i)dControl\.exe$')) "package contains dControl.exe: $item"
    Assert-True ($item -ne 'brands/mercedes/profile.json') 'package contains a brand profile'
  }

  $root = Get-SetupPackageRoot -Start (Join-Path -Path (Join-Path -Path $extracted -ChildPath 'installer') -ChildPath 'Master')
  Assert-True ($root -eq [System.IO.Path]::GetFullPath($extracted) -or $root -eq $extracted) 'package root was not the extracted folder'

  $mercedes = Get-SetupPlan -PackageRoot $extracted -Brand 'mercedes' -Channel 'beta' -Report
  Assert-True ([int]$mercedes.ExitCode -eq 0) 'mercedes report failed'
  Assert-True ([bool]$mercedes.Report) 'mercedes report was not report mode'
  $mercedesText = @($mercedes.Lines) -join "`n"
  Assert-True ($mercedesText.Contains('Resolved brand: mercedes')) 'mercedes report did not resolve the brand'
  Assert-True ($mercedesText.Contains('Resolved display name: Mercedes-Benz')) 'mercedes display name was blank'
  Assert-True ($mercedesText.Contains('Resolved tag: mercedes-v0.1.3-beta.4')) 'mercedes tag was not the catalog pin'
  Assert-True ($mercedesText.Contains('Offline payload: offline/mercedes-v0.1.3-beta.4/workstation.zip')) 'offline zip path was not reported'
  Assert-True ($mercedesText.Contains('Offline payload: offline/mercedes-v0.1.3-beta.4/update-manifest.json')) 'offline manifest path was not reported'
  Assert-True ($mercedesText.Contains('Offline payload present: no')) 'offline payload was unexpectedly present'
  Assert-True ($mercedesText.Contains('catalog/catalog.json')) 'file list omitted catalog.json'
  Assert-True ($mercedesText.Contains('Setup.exe')) 'file list omitted Setup.exe'
  Assert-True ($mercedesText.Contains('Report only. Nothing was installed.')) 'report claimed it would install'
  Assert-True (-not $mercedesText.Contains('Install ')) 'report used a blank Install prompt'

  $whatIf = Get-SetupPlan -PackageRoot $extracted -Brand 'bmw' -WhatIf
  $whatIfText = @($whatIf.Lines) -join "`n"
  Assert-True ([int]$whatIf.ExitCode -eq 0 -and $whatIfText.Contains('Resolved brand: bmw')) 'bmw -WhatIf did not resolve the brand'
  Assert-True ($whatIfText.Contains('Resolved tag: bmw-v1.0.2-beta.1')) 'bmw tag was not the catalog pin'
  Assert-True ($whatIfText.Contains('Resolved display name: BMW')) 'bmw display name was blank'

  $slash = Get-SetupPlan -PackageRoot $extracted -Brand 'mercedes' -Remaining @('/report')
  Assert-True ([bool]$slash.Report -and [int]$slash.ExitCode -eq 0) '/report was not report mode'

  $missing = Get-SetupPlan -PackageRoot $extracted -Report -NonInteractive
  $missingText = @($missing.Lines) -join "`n"
  Assert-True ([int]$missing.ExitCode -eq 1) 'missing brand was accepted'
  Assert-True ($missingText.Contains('No brand was resolved. Pass -Brand mercedes or -Brand bmw. Nothing was installed.')) 'missing brand error was unclear'
  Assert-True ($missingText.Contains('catalog/catalog.json')) 'missing-brand report omitted the file list'

  $unknown = Get-SetupPlan -PackageRoot $extracted -Brand 'ford' -Report -NonInteractive
  Assert-True ([int]$unknown.ExitCode -eq 1) 'unknown brand was accepted'
  Assert-True ((@($unknown.Lines) -join "`n").Contains('No brand was resolved')) 'unknown brand error was unclear'

  $forward = Get-SetupForwardParameters -Brand 'mercedes' -Channel 'beta' -Tag 'mercedes-v0.1.3-beta.4' -OfflineOnly -VerifyOnly
  Assert-True ($forward.Brand -eq 'mercedes' -and $forward.Channel -eq 'beta' -and $forward.Tag -eq 'mercedes-v0.1.3-beta.4') 'forwarded parameters dropped the brand'
  Assert-True ($forward.OfflineOnly -eq $true -and $forward.VerifyOnly -eq $true) 'forwarded switches were dropped'
  Assert-True (-not $forward.ContainsKey('AllowDowngrade')) 'an unset switch was forwarded'

  $readme = [System.IO.File]::ReadAllText((Join-Path -Path $extracted -ChildPath 'README-INSTALL.txt'))
  Assert-True ($readme.Contains('offline\<tag>\workstation.zip')) 'README does not document the offline zip'
  Assert-True ($readme.Contains('update-manifest.json')) 'README does not document the offline manifest'
  Assert-True ($readme.Contains('ECDSA P-256')) 'README does not say signing comes later'
  Assert-True ($readme.Contains('unsigned')) 'README does not say the package is unsigned'
  Assert-True ($readme.Contains('SHA256SUMS.txt')) 'README does not mention SHA256SUMS.txt'
  Assert-True ($readme.Contains('-WhatIf')) 'README does not document report mode'
  Assert-True ($readme.Contains('does not stop the WinDefend or MDCoreSvc')) 'README does not say those services stay running'

  $setupText = [System.IO.File]::ReadAllText((Join-Path -Path (Join-Path -Path (Join-Path -Path $repo -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'Setup.ps1'))
  $planText = [System.IO.File]::ReadAllText((Join-Path -Path (Join-Path -Path (Join-Path -Path (Join-Path -Path $repo -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'lib') -ChildPath 'SetupPlan.ps1'))
  Assert-True ($setupText.Contains('Install-Master.ps1')) 'Setup.ps1 does not run Install-Master.ps1'
  Assert-True ($setupText.Contains('exit')) 'Setup.ps1 does not pass an exit code'
  Assert-True (-not $setupText.Contains('Start-Process')) 'Setup.ps1 starts a separate process'
  Assert-True (-not $setupText.Contains('Out-File')) 'Setup.ps1 uses Out-File'
  Assert-True (-not $planText.Contains('Start-Process')) 'SetupPlan.ps1 starts a separate process'
  Assert-True (-not $planText.Contains('Out-File')) 'SetupPlan.ps1 uses Out-File'
  Assert-True ($planText.Contains('Brand (mercedes or bmw)')) 'brand prompt is missing'
  Assert-True (-not $setupText.Contains('Install ')) 'Setup.ps1 contains a blank Install prompt'
  Assert-True (-not $planText.Contains('Install ')) 'SetupPlan.ps1 contains a blank Install prompt'

  $main = [System.IO.File]::ReadAllText((Join-Path -Path (Join-Path -Path $repo -ChildPath 'manager') -ChildPath 'main.go'))
  Assert-True (-not $main.Contains('"Install "+b.DisplayName')) 'WorkstationManager still concatenates a blank Install title'
  Assert-True ($main.Contains('installPromptTitle')) 'WorkstationManager does not use the resolved-brand title'
  Assert-True ($main.Contains('unresolvedBrandTitle')) 'WorkstationManager has no unresolved-brand title'
  Assert-True ($main.Contains('unresolvedBrandMessage')) 'WorkstationManager has no unresolved-brand message'

  $buildText = [System.IO.File]::ReadAllText((Join-Path -Path $PSScriptRoot -ChildPath 'Build-MasterInstallerPackage.ps1'))
  Assert-True ($buildText.Contains('Invoke-WebRequest')) 'build does not download with Invoke-WebRequest'
  Assert-True ($buildText.Contains('-OutFile')) 'build does not use Invoke-WebRequest -OutFile'
  Assert-True ($buildText.Contains('692124163d0e71262d76e2f2b2588e1661df28a8f0cf3b1725e47a957afce39f')) 'PS2EXE nupkg pin is missing'
  Assert-True ($buildText.Contains("1.0.18")) 'PS2EXE version pin is missing'
  Assert-True (-not $buildText.Contains('Out-File')) 'build uses Out-File'

  $workflow = [System.IO.File]::ReadAllText((Join-Path -Path (Join-Path -Path $repo -ChildPath '.github/workflows') -ChildPath 'master-installer-package.yml'))
  Assert-True ($workflow.Contains('workflow_dispatch')) 'package workflow is not workflow_dispatch'
  Assert-True ($workflow.Contains('windows-latest')) 'package workflow is not windows-latest'
  Assert-True ($workflow.Contains('692124163d0e71262d76e2f2b2588e1661df28a8f0cf3b1725e47a957afce39f')) 'workflow does not pin the nupkg SHA-256'
  Assert-True ($workflow.Contains('1.0.18')) 'workflow does not pin the PS2EXE version'
  Assert-True ($workflow.Contains('DiagnosticWorkstation-Setup.zip')) 'workflow does not upload the zip'
} finally {
  if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

Write-Output 'PASS setup package layout'
exit 0
