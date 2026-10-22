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

function Export-GitHeadBlob {
  param([Parameter(Mandatory = $true)][string]$Relative, [Parameter(Mandatory = $true)][string]$Destination)
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = 'git'
  $info.Arguments = '-c core.autocrlf=false cat-file -p HEAD:' + $Relative
  $info.WorkingDirectory = $repo
  $info.UseShellExecute = $false
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.CreateNoWindow = $true
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $info
  [void]$proc.Start()
  $parent = Split-Path -Parent $Destination
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $stream = [System.IO.File]::Create($Destination)
  try { $proc.StandardOutput.BaseStream.CopyTo($stream) } finally { $stream.Dispose() }
  $errorText = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  if ($proc.ExitCode -ne 0) { throw "git cat-file HEAD:$Relative failed: $errorText" }
}

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
  foreach ($rel in @(
    'keys/qa.pub',
    'keys/release.pub',
    'keys/README.md',
    'brands/bmw/release.json',
    'brands/mercedes/release.json'
  )) {
    $blob = Join-Path -Path $temp -ChildPath ('blob-' + ($rel.Replace('/', '-')))
    Export-GitHeadBlob $rel $blob
    Assert-SameFileBytes $blob (Join-PackageRelative $extracted $rel)
  }
  $sumsText = [System.IO.File]::ReadAllText((Join-Path -Path $extracted -ChildPath 'SHA256SUMS.txt'))
  Assert-True (-not $sumsText.Contains('Setup.exe')) 'SHA256SUMS.txt lists Setup.exe'
  $files = @(Get-PackageRelativeFiles $extracted)
  $dcontrol = @($files | Where-Object { $_.StartsWith('tools/security/dcontrol/') })
  Assert-True ($dcontrol.Count -eq 2) 'dcontrol package is not the two-file allow-list'
  Assert-True (($dcontrol -contains 'tools/security/dcontrol/ReadMe.txt') -and ($dcontrol -contains 'tools/security/dcontrol/STATUS.md')) 'dcontrol allow-list files were not packaged'
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
  Assert-True (-not $forward.ContainsKey('AllowHarnessFailSwap')) 'the harness swap switch was forwarded'
  $sourceTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('dw-source-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $sourceTemp | Out-Null
  $previousDirectory = [Environment]::CurrentDirectory
  try {
    [Environment]::CurrentDirectory = $sourceTemp
    $relativeSource = Get-SetupForwardParameters -Brand 'mercedes' -Source 'payload'
    $expectedSource = [System.IO.Path]::GetFullPath((Join-Path -Path $sourceTemp -ChildPath 'payload'))
    Assert-True ([System.IO.Path]::IsPathRooted([string]$relativeSource.Source)) 'relative -Source was forwarded as a relative path'
    Assert-True ([string]$relativeSource.Source -ceq $expectedSource) 'relative -Source was not resolved from the current directory'
  } finally {
    [Environment]::CurrentDirectory = $previousDirectory
    if (Test-Path -LiteralPath $sourceTemp) { Remove-Item -LiteralPath $sourceTemp -Recurse -Force }
  }

  $readme = [System.IO.File]::ReadAllText((Join-Path -Path $extracted -ChildPath 'README-INSTALL.txt'))
  Assert-True ($readme.Contains('offline\<tag>\workstation.zip')) 'README does not document the offline zip'
  Assert-True ($readme.Contains('update-manifest.json')) 'README does not document the offline manifest'
  Assert-True ($readme.Contains('ECDSA P-256')) 'README does not say signing comes later'
  Assert-True ($readme.Contains('unsigned')) 'README does not say the package is unsigned'
  Assert-True ($readme.Contains('SHA256SUMS.txt')) 'README does not mention SHA256SUMS.txt'
  Assert-True ($readme.Contains('-WhatIf')) 'README does not document report mode'
  Assert-True ($readme.Contains('does not stop the WinDefend or MDCoreSvc')) 'README does not say those services stay running'
  Assert-True ($readme.Contains('not byte-reproducible')) 'README does not say PS2EXE output is not byte-reproducible'
  Assert-True ($readme.Contains('attested value')) 'README does not say the CI artifact hash is the attested value'
  Assert-True ($readme.Contains('SmartScreen')) 'README does not mention SmartScreen'
  Assert-True ($readme.Contains('More info')) 'README does not give the SmartScreen workaround'
  Assert-True ($readme.Contains('Run anyway')) 'README does not give the SmartScreen workaround'
  Assert-True ($readme.Contains('Execution policy is overridden. Run Get-ExecutionPolicy -List. Nothing was installed.')) 'README does not document an overridden execution policy'
  Assert-True ($readme.Contains('desktop.ini')) 'README does not ignore desktop.ini'
  Assert-True ($readme.Contains('admin-only')) 'README does not document the admin-only copy'

  $setupText = [System.IO.File]::ReadAllText((Join-Path -Path (Join-Path -Path (Join-Path -Path $repo -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'Setup.ps1'))
  $planText = [System.IO.File]::ReadAllText((Join-Path -Path (Join-Path -Path (Join-Path -Path (Join-Path -Path $repo -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'lib') -ChildPath 'SetupPlan.ps1'))
  Assert-True ($setupText.Contains('Install-Master.ps1')) 'Setup.ps1 does not run Install-Master.ps1'
  Assert-True ($setupText.Contains('exit $code')) 'Setup.ps1 does not return the installer exit code'
  Assert-True (-not $setupText.Contains('exit 0')) 'Setup.ps1 forces exit 0'
  Assert-True ($setupText.Contains('Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force')) 'Setup.ps1 does not set the process execution policy'
  Assert-True ($setupText.Contains('System.Diagnostics.Process')) 'Setup.ps1 does not run the installer in a child process'
  Assert-True ($setupText.Contains('-ExecutionPolicy')) 'Setup.ps1 does not pass ExecutionPolicy Bypass to the child'
  Assert-True ($setupText.Contains('__EMBEDDED_SHA256SUMS__')) 'Setup.ps1 has no SHA256SUMS embed token'
  Assert-True ($setupText.Contains('SHA-256 mismatch for')) 'Setup.ps1 does not refuse a checksum mismatch'
  Assert-True ($setupText.Contains('Unlisted extra file')) 'Setup.ps1 does not refuse an unlisted file'
  Assert-True ($setupText.Contains('desktop.ini') -and $setupText.Contains('Thumbs.db')) 'Setup.ps1 does not ignore desktop clutter'
  Assert-True ($setupText.Contains('AllowHarnessFailSwap')) 'Setup.ps1 does not drop the harness swap switch'
  Assert-True ($setupText.Contains("GetFolderPath('System')")) 'Setup.ps1 does not locate Windows PowerShell from the system directory'
  Assert-True ($setupText.Contains('Execution policy is overridden. Run Get-ExecutionPolicy -List. Nothing was installed.')) 'Setup.ps1 does not report an overridden execution policy'
  Assert-True ($setupText.Contains('GetFullPath($Source)')) 'Setup.ps1 does not resolve -Source before the copy'
  Assert-True ($setupText.Contains('StringComparer]::Ordinal')) 'Setup.ps1 does not compare listed paths case-exactly'
  Assert-True ($setupText.Contains('ReparsePoint')) 'Setup.ps1 does not refuse reparse points'
  Assert-True ($setupText.Contains('SetOwner')) 'Setup.ps1 does not set the work directory owner'
  Assert-True ($readme.Contains('Get-ExecutionPolicy -List')) 'README does not suggest Get-ExecutionPolicy -List'
  Assert-True ($planText.Contains('GetFullPath($Source)')) 'SetupPlan.ps1 forwards a relative -Source'
  Assert-True ($setupText.Contains('[string](Get-ExecutionPolicy)')) 'Setup.ps1 does not check the effective execution policy'
  Assert-True ($setupText.Contains('S-1-5-32-544') -and $setupText.Contains('S-1-5-18') -and $setupText.Contains('SetAccessRuleProtection')) 'Setup.ps1 does not keep the work directory admin-only'
  Assert-True ($setupText.Contains("'-' + [string]`$key + ':' + [string]`$value")) 'child arguments are not passed as -Key:value'
  Assert-True (-not $setupText.Contains('Start-Process')) 'Setup.ps1 uses the Start-Process cmdlet'
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
  Assert-True (-not $workflow.Contains('actions: write')) 'workflow keeps actions: write'
  Assert-True ($workflow.Contains('not byte-reproducible')) 'workflow does not say PS2EXE output is not byte-reproducible'
  Assert-True ($workflow.Contains('attested value')) 'workflow does not say the CI artifact hash is the attested value'
  $attributes = [System.IO.File]::ReadAllText((Join-Path -Path $repo -ChildPath '.gitattributes'))
  Assert-True ($attributes.Contains('keys/** -text')) 'gitattributes does not pin keys as text'
  Assert-True ($attributes.Contains('brands/*/release.json -text')) 'gitattributes does not pin brand release.json as text'
  Assert-True ($buildText.Contains('ReadMe.txt') -and $buildText.Contains('STATUS.md') -and $buildText.Contains('allow-list')) 'dcontrol allow-list is missing'
  Assert-True ($buildText.Contains('__EMBEDDED_SHA256SUMS__')) 'build does not embed the SHA256SUMS hash'
} finally {
  if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

Write-Output 'PASS setup package layout'
exit 0
