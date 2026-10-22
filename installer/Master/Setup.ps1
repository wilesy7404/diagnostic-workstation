# Setup.exe entry point. PS2EXE compiles this file.
# One run: the exe manifest asks for administrator approval, then this script
# checks SHA256SUMS.txt and runs Install-Master.ps1 in a child powershell.exe.
# The build replaces __EMBEDDED_SHA256SUMS__ with the SHA-256 of SHA256SUMS.txt.
# -WhatIf and /report print the resolved brand and the package file list.
# Windows PowerShell 5.1.
[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$Brand,
  [ValidateSet('beta', 'stable')]
  [string]$Channel = 'beta',
  [string]$Tag,
  [string]$Source,
  [switch]$OfflineOnly,
  [switch]$VerifyOnly,
  [switch]$AllowDowngrade,
  [switch]$WhatIf,
  [switch]$Report,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Remaining
)

$ErrorActionPreference = 'Stop'
$script:EmbeddedSha256Sums = '__EMBEDDED_SHA256SUMS__'

function Format-SetupProcessArgument {
  param([string]$Text)
  if ($null -eq $Text) { $Text = '' }
  $needsQuote = $Text.Length -eq 0
  if (-not $needsQuote) {
    foreach ($ch in $Text.ToCharArray()) {
      if ($ch -eq ' ' -or $ch -eq "`t" -or $ch -eq "`n" -or $ch -eq "`v" -or $ch -eq '"') {
        $needsQuote = $true
        break
      }
    }
  }
  if (-not $needsQuote) { return $Text }
  $builder = New-Object System.Text.StringBuilder
  [void]$builder.Append('"')
  $chars = $Text.ToCharArray()
  $index = 0
  while ($index -lt $chars.Length) {
    $slashes = 0
    while ($index -lt $chars.Length -and $chars[$index] -eq '\') {
      $slashes++
      $index++
    }
    if ($index -ge $chars.Length) {
      if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
      break
    }
    if ($chars[$index] -eq '"') {
      [void]$builder.Append(('\' * (($slashes * 2) + 1)))
      [void]$builder.Append('"')
      $index++
      continue
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)) }
    [void]$builder.Append($chars[$index])
    $index++
  }
  [void]$builder.Append('"')
  return $builder.ToString()
}

function Resolve-SetupExeDirectory {
  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace([string]$ScriptRoot)) {
    [void]$candidates.Add([string]$ScriptRoot)
  }
  try {
    $base = [System.AppDomain]::CurrentDomain.BaseDirectory
    if (-not [string]::IsNullOrWhiteSpace($base)) { [void]$candidates.Add($base) }
  } catch { }
  try {
    $proc = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($proc -and $proc -notmatch '(?i)(^|[\\/])(powershell|pwsh)(\.exe)?$') {
      [void]$candidates.Add((Split-Path -Parent $proc))
    }
  } catch { }
  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $sums = Join-Path -Path $candidate -ChildPath 'SHA256SUMS.txt'
    if (Test-Path -LiteralPath $sums -PathType Leaf) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
  }
  return $null
}

function Get-SetupRelativeFiles {
  param([Parameter(Mandatory = $true)][string]$Root)
  $fullRoot = [System.IO.Path]::GetFullPath($Root)
  $prefix = $fullRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($file in [System.IO.Directory]::EnumerateFiles($fullRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
    $full = [System.IO.Path]::GetFullPath($file)
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    [void]$list.Add($full.Substring($prefix.Length).Replace('\', '/'))
  }
  return @($list.ToArray())
}

function Resolve-SetupListedPath {
  param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Relative)
  $rel = $Relative.Replace('\', '/')
  if ($rel -match '(^|/)\.\.(/|$)') { return $null }
  $path = $Root
  foreach ($part in @($rel -split '/')) {
    if ([string]::IsNullOrWhiteSpace($part) -or $part -eq '.' -or $part -eq '..') { return $null }
    $path = Join-Path -Path $path -ChildPath $part
  }
  return $path
}

function Get-SetupLeafName {
  param([Parameter(Mandatory = $true)][string]$Relative)
  $rel = $Relative.Replace('\', '/')
  $slash = $rel.LastIndexOf('/')
  if ($slash -lt 0) { return $rel }
  return $rel.Substring($slash + 1)
}

function Get-SetupApprovedTags {
  param([Parameter(Mandatory = $true)][string]$PackageRoot, [Parameter(Mandatory = $true)]$Listed)
  $rel = 'catalog/catalog.json'
  if (-not $Listed.ContainsKey($rel)) {
    Write-Output 'catalog/catalog.json is not in SHA256SUMS.txt. Nothing was installed.'
    exit 1
  }
  $full = Resolve-SetupListedPath $PackageRoot $rel
  if ([string]::IsNullOrWhiteSpace($full)) {
    Write-Output 'catalog/catalog.json is not in SHA256SUMS.txt. Nothing was installed.'
    exit 1
  }
  $bytes = [System.IO.File]::ReadAllBytes($full)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
  } finally { $sha.Dispose() }
  if ($hash -ne [string]$Listed[$rel]) {
    Write-Output 'SHA-256 mismatch for catalog/catalog.json. Nothing was installed.'
    exit 1
  }
  $text = ''
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, ($bytes.Length - 3))
  } else {
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  }
  $catalog = $text | ConvertFrom-Json
  $tags = New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([System.StringComparer]::Ordinal)
  foreach ($brand in @($catalog.brands)) {
    foreach ($release in @($brand.releases)) {
      $tag = [string]$release.tag
      if ($tag -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$') { continue }
      $tags[$tag] = $true
    }
  }
  return $tags
}

function Get-SetupPathKind {
  param([Parameter(Mandatory = $true)][string]$Relative, [Parameter(Mandatory = $true)]$Listed, [Parameter(Mandatory = $true)]$Tags)
  $rel = $Relative.Replace('\', '/')
  $leaf = Get-SetupLeafName $rel
  if ($leaf -ieq 'desktop.ini' -or $leaf -ieq 'Thumbs.db') { return 'ignore' }
  if ($rel -eq 'SHA256SUMS.txt' -or $rel -eq 'Setup.exe') { return 'package' }
  if ($Listed.ContainsKey($rel)) { return 'listed' }
  if ($rel -match '^(?i)offline/([^/]+)/(workstation\.zip|update-manifest\.json)$') {
    if ($Tags.ContainsKey($Matches[1])) { return 'offline' }
  }
  return 'refuse'
}

function Assert-SetupPackageHashes {
  param([Parameter(Mandatory = $true)][string]$PackageRoot)
  $expected = ([string]$script:EmbeddedSha256Sums).Trim().ToLowerInvariant()
  if ($expected -notmatch '^[0-9a-f]{64}$') {
    Write-Output 'Setup.exe has no embedded SHA256SUMS hash. Nothing was installed.'
    exit 1
  }
  $sumsPath = Join-Path -Path $PackageRoot -ChildPath 'SHA256SUMS.txt'
  if (-not (Test-Path -LiteralPath $sumsPath -PathType Leaf)) {
    Write-Output 'SHA256SUMS.txt is missing. Nothing was installed.'
    exit 1
  }
  $actualSums = (Get-FileHash -LiteralPath $sumsPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualSums -ne $expected) {
    Write-Output 'SHA256SUMS.txt does not match the hash embedded in Setup.exe. Nothing was installed.'
    exit 1
  }
  $text = [System.IO.File]::ReadAllText($sumsPath)
  if ($text.Contains("`r")) {
    Write-Output 'SHA256SUMS.txt contains CR. Nothing was installed.'
    exit 1
  }
  $listed = @{}
  foreach ($line in @($text -split "`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') {
      Write-Output 'SHA256SUMS.txt contains a bad line. Nothing was installed.'
      exit 1
    }
    $rel = $Matches[2]
    if ($listed.ContainsKey($rel) -or $rel -eq 'SHA256SUMS.txt' -or $rel -eq 'Setup.exe') {
      Write-Output "SHA256SUMS.txt lists $rel. Nothing was installed."
      exit 1
    }
    if ($null -eq (Resolve-SetupListedPath $PackageRoot $rel)) {
      Write-Output "SHA256SUMS.txt lists an unsafe path $rel. Nothing was installed."
      exit 1
    }
    $listed[$rel] = $Matches[1]
  }
  if ($listed.Count -eq 0) {
    Write-Output 'SHA256SUMS.txt lists no files. Nothing was installed.'
    exit 1
  }
  $actual = @(Get-SetupRelativeFiles $PackageRoot)
  foreach ($rel in @($listed.Keys)) {
    $full = Resolve-SetupListedPath $PackageRoot $rel
    if ([string]::IsNullOrWhiteSpace($full) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
      Write-Output "SHA256SUMS.txt lists a missing file ${rel}. Nothing was installed."
      exit 1
    }
    $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $listed[$rel]) {
      Write-Output "SHA-256 mismatch for ${rel}. Nothing was installed."
      exit 1
    }
  }
  $tags = Get-SetupApprovedTags $PackageRoot $listed
  foreach ($rel in $actual) {
    $kind = Get-SetupPathKind $rel $listed $tags
    if ($kind -eq 'ignore' -or $kind -eq 'package' -or $kind -eq 'listed' -or $kind -eq 'offline') { continue }
    Write-Output "Unlisted extra file ${rel}. Nothing was installed."
    exit 1
  }
  $exe = Join-Path -Path $PackageRoot -ChildPath 'Setup.exe'
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    Write-Output 'Setup.exe is missing from this package. Nothing was installed.'
    exit 1
  }
}

function Find-SetupPlanPath {
  param([Parameter(Mandatory = $true)][string]$PackageRoot)
  $lib = Join-Path -Path (Join-Path -Path (Join-Path -Path $PackageRoot -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'lib'
  $plan = Join-Path -Path $lib -ChildPath 'SetupPlan.ps1'
  if (Test-Path -LiteralPath $plan -PathType Leaf) { return $plan }
  return $null
}

function Test-SetupShouldPrompt {
  if ($env:GITHUB_ACTIONS -eq 'true') { return $false }
  if ($env:CI -eq 'true') { return $false }
  try {
    if ([Console]::IsInputRedirected) { return $false }
  } catch {
    return $false
  }
  if (-not [Environment]::UserInteractive) { return $false }
  return $true
}

function Invoke-SetupInstallerProcess {
  param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [Parameter(Mandatory = $true)][string]$Installer,
    [Parameter(Mandatory = $true)]$Parameters
  )
  $powershell = Join-Path -Path ([Environment]::GetFolderPath('System')) -ChildPath 'WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) {
    Write-Output 'Windows PowerShell was not found. Nothing was installed.'
    exit 1
  }
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($token in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Installer)) {
    [void]$parts.Add((Format-SetupProcessArgument $token))
  }
  foreach ($key in @($Parameters.Keys)) {
    if ([string]$key -eq 'AllowHarnessFailSwap') { continue }
    $value = $Parameters[$key]
    if ($value -is [bool] -or $value -is [switch]) {
      if ($value) { [void]$parts.Add((Format-SetupProcessArgument ('-' + [string]$key))) }
      continue
    }
    [void]$parts.Add((Format-SetupProcessArgument ('-' + [string]$key + ':' + [string]$value)))
  }
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = $powershell
  $info.Arguments = ($parts.ToArray() -join ' ')
  $info.WorkingDirectory = $PackageRoot
  $info.UseShellExecute = $false
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $info
  [void]$proc.Start()
  $proc.WaitForExit()
  if (-not $proc.HasExited) {
    Write-Output 'Install-Master.ps1 did not return an exit code. Nothing was installed.'
    exit 1
  }
  return [int]$proc.ExitCode
}

function New-SetupAdminWorkRoot {
  $base = [Environment]::GetFolderPath('CommonApplicationData')
  if ([string]::IsNullOrWhiteSpace($base)) {
    Write-Output 'ProgramData is not available. Nothing was installed.'
    exit 1
  }
  $root = Join-Path -Path $base -ChildPath ('DiagnosticWorkstation-Setup-' + [guid]::NewGuid().ToString('n'))
  $acl = New-Object System.Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
  $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
  $prop = [System.Security.AccessControl.PropagationFlags]::None
  $allow = [System.Security.AccessControl.AccessControlType]::Allow
  foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
    $account = New-Object System.Security.Principal.SecurityIdentifier($sid)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($account, $rights, $inherit, $prop, $allow)
    $acl.AddAccessRule($rule)
  }
  $created = [System.IO.Directory]::CreateDirectory($root, $acl)
  [System.IO.Directory]::SetAccessControl($created.FullName, $acl)
  return [System.IO.Path]::GetFullPath($created.FullName)
}

function Copy-SetupVerifiedTree {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)]$Listed,
    [Parameter(Mandatory = $true)]$Tags
  )
  foreach ($rel in @(Get-SetupRelativeFiles $Source)) {
    $kind = Get-SetupPathKind $rel $Listed $Tags
    if ($kind -eq 'ignore') { continue }
    if ($kind -eq 'refuse') {
      Write-Output "Unlisted extra file ${rel}. Nothing was installed."
      exit 1
    }
    $from = Resolve-SetupListedPath $Source $rel
    $to = Resolve-SetupListedPath $Destination $rel
    if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)) {
      Write-Output "Unlisted extra file ${rel}. Nothing was installed."
      exit 1
    }
    $parent = Split-Path -Parent $to
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $bytes = [System.IO.File]::ReadAllBytes($from)
    [System.IO.File]::WriteAllBytes($to, $bytes)
  }
}

function Remove-SetupAdminWorkRoot {
  param([string]$Root)
  if ([string]::IsNullOrWhiteSpace($Root)) { return }
  if (-not (Test-Path -LiteralPath $Root)) { return }
  try { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

$script:SetupWorkRoot = $null
try {
  try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
  } catch {
    Write-Output 'Execution policy is overridden. Nothing was installed.'
    exit 1
  }
  $effectivePolicy = [string](Get-ExecutionPolicy)
  if ($effectivePolicy -ne 'Bypass' -and $effectivePolicy -ne 'Unrestricted') {
    Write-Output 'Execution policy is overridden. Nothing was installed.'
    exit 1
  }
  $packageRoot = Resolve-SetupExeDirectory
  if ([string]::IsNullOrWhiteSpace($packageRoot)) {
    Write-Output 'Setup could not find the package root. Nothing was installed.'
    exit 1
  }
  Assert-SetupPackageHashes $packageRoot
  $script:SetupWorkRoot = New-SetupAdminWorkRoot
  $sumsPath = Join-Path -Path $packageRoot -ChildPath 'SHA256SUMS.txt'
  $sumsText = [System.IO.File]::ReadAllText($sumsPath)
  $listed = @{}
  foreach ($line in @($sumsText -split "`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -match '^([0-9a-f]{64})  (.+)$') { $listed[$Matches[2]] = $Matches[1] }
  }
  $tags = Get-SetupApprovedTags $packageRoot $listed
  Copy-SetupVerifiedTree -Source $packageRoot -Destination $script:SetupWorkRoot -Listed $listed -Tags $tags
  Assert-SetupPackageHashes $script:SetupWorkRoot
  $planPath = Find-SetupPlanPath $script:SetupWorkRoot
  if (-not $planPath) {
    Write-Output 'Setup could not find the package root. Nothing was installed.'
    exit 1
  }
  . $planPath
  $lib = Join-Path -Path (Join-Path -Path (Join-Path -Path $script:SetupWorkRoot -ChildPath 'installer') -ChildPath 'Master') -ChildPath 'lib'
  . (Join-Path -Path $lib -ChildPath 'Common.ps1')
  . (Join-Path -Path $lib -ChildPath 'Catalog.ps1')
  $plan = Get-SetupPlan -PackageRoot $script:SetupWorkRoot -Brand $Brand -Channel $Channel -Tag $Tag -Source $Source -OfflineOnly:$OfflineOnly -VerifyOnly:$VerifyOnly -AllowDowngrade:$AllowDowngrade -WhatIf:$WhatIf -Report:$Report -Remaining $Remaining -NonInteractive:(-not (Test-SetupShouldPrompt))
  foreach ($line in @($plan.Lines)) { Write-Output $line }
  if ($plan.Report -or [int]$plan.ExitCode -ne 0) { exit [int]$plan.ExitCode }
  if ([string]::IsNullOrWhiteSpace([string]$plan.Installer) -or -not (Test-Path -LiteralPath ([string]$plan.Installer) -PathType Leaf)) {
    Write-Output 'Install-Master.ps1 is missing from this package. Nothing was installed.'
    exit 1
  }
  $code = Invoke-SetupInstallerProcess -PackageRoot $script:SetupWorkRoot -Installer ([string]$plan.Installer) -Parameters $plan.Parameters
  exit $code
} catch {
  Write-Output ([string]$_.Exception.Message)
  exit 1
} finally {
  Remove-SetupAdminWorkRoot $script:SetupWorkRoot
}
