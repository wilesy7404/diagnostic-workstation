# Shared helpers for the master installer. Windows PowerShell 5.1 and PowerShell 7.
# This file defines functions only. It does not install software or change security settings.

$ErrorActionPreference = 'Stop'

$script:MasterRepo = 'wilesy7404/diagnostic-workstation'
# Machine-local files. A bundle that contains one of these is rejected, and an
# existing copy is carried onto the new tree.
$script:MasterPreserveFiles = @(
  'apps.json',
  'controls-pin.json',
  'update-settings.json',
  'update-status.json',
  'update-deferred.json',
  'update-progress.json',
  'device.json',
  'secrets.json'
)

# Ships in the bundle as the fresh-install default. If the brand folder already
# has this file, that copy is carried across and the bundle copy is not used.
$script:MasterCarryExistingFiles = @(
  'profile.json'
)

function Test-MasterHostWindows {
  if ($PSVersionTable.PSVersion.Major -ge 6) {
    return [bool]$IsWindows
  }
  return $env:OS -eq 'Windows_NT'
}

function Test-IsWindowsAdmin {
  if (-not (Test-MasterHostWindows)) { return $false }
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-MasterWindowsPowerShell {
  if (Test-MasterHostWindows) {
    $system = [Environment]::GetFolderPath('System')
    if (-not [string]::IsNullOrWhiteSpace($system)) {
      $candidate = Join-Path -Path $system -ChildPath 'WindowsPowerShell\v1.0\powershell.exe'
      if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
  }
  return 'powershell.exe'
}

function Format-MasterCommandLine {
  param([string[]]$ArgumentList)
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($arg in @($ArgumentList)) {
    if ($null -eq $arg) { continue }
    $text = [string]$arg
    if ($text -match '[\s"]') { $parts.Add('"' + $text.Replace('"', '\"') + '"') }
    else { $parts.Add($text) }
  }
  return ($parts -join ' ')
}

function Get-MasterForwardArguments {
  param($Bound)
  $forward = New-Object System.Collections.Generic.List[string]
  foreach ($key in @($Bound.Keys)) {
    if ($key -eq 'ElevatedRelaunch' -or $key -eq 'Library') { continue }
    $value = $Bound[$key]
    if ($value -is [switch] -or $value -is [bool]) {
      if ($value) { $forward.Add("-$key") }
    } else {
      $forward.Add("-$key")
      $forward.Add([string]$value)
    }
  }
  return @($forward.ToArray())
}

function New-MasterHiddenCommand {
  param([Parameter(Mandatory = $true)][string]$ScriptPath, [string[]]$ArgumentList)
  $command = New-Object System.Collections.Generic.List[string]
  foreach ($flag in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $ScriptPath)) {
    $command.Add($flag)
  }
  foreach ($item in @($ArgumentList)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$item)) { $command.Add([string]$item) }
  }
  if (-not ($command.Contains('-ElevatedRelaunch'))) { $command.Add('-ElevatedRelaunch') }
  return @($command.ToArray())
}

# Relaunch the current entry script at most once, hidden, and wait for it.
# The child is marked with -ElevatedRelaunch so a failed admin check cannot open another window.
function Invoke-MasterElevatedOnce {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string[]]$ArgumentList,
    [switch]$AlreadyRelaunched,
    [scriptblock]$AdminTest,
    [scriptblock]$Starter
  )
  $isAdmin = $false
  if ($AdminTest) { $isAdmin = [bool](& $AdminTest) }
  else { $isAdmin = Test-IsWindowsAdmin }
  if ($isAdmin) { return [pscustomobject]@{ action = 'continue'; relaunched = $false; exitCode = 0 } }
  if ($AlreadyRelaunched -or $env:MASTER_INSTALLER_ELEVATION -eq '1') {
    throw 'The installer already relaunched for elevation. Refusing to open another window. Nothing was installed.'
  }
  $arguments = @(New-MasterHiddenCommand $ScriptPath $ArgumentList)
  $launch = [pscustomobject]@{
    file = (Get-MasterWindowsPowerShell)
    arguments = $arguments
    verb = 'RunAs'
    windowStyle = 'Hidden'
    wait = $true
  }
  if ($Starter) {
    $box = New-Object object[] 1
    $box[0] = $launch
    $code = $Starter.InvokeReturnAsIs($box)
    return [pscustomobject]@{ action = 'relaunched'; relaunched = $true; exitCode = [int]$code }
  }
  if ($env:MASTER_INSTALLER_FORBID_TOOL_EXECUTION -eq '1') { throw 'elevation relaunch is forbidden in this session' }
  if (-not (Test-MasterHostWindows)) { throw 'The master installer runs on Windows. Nothing was installed.' }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $launch.file
  $psi.Arguments = (Format-MasterCommandLine $arguments)
  $psi.UseShellExecute = $true
  $psi.Verb = 'RunAs'
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  try { $process = [System.Diagnostics.Process]::Start($psi) } catch { throw 'Elevation was declined. Nothing was installed.' }
  if (-not $process) { throw 'Elevation was declined. Nothing was installed.' }
  $process.WaitForExit()
  return [pscustomobject]@{ action = 'relaunched'; relaunched = $true; exitCode = [int]$process.ExitCode }
}

function Enter-MasterInstallerProcess {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    $Bound,
    [switch]$AlreadyRelaunched,
    [switch]$SkipElevation
  )
  if ($SkipElevation) { return }
  $forward = @(Get-MasterForwardArguments $Bound)
  $decision = Invoke-MasterElevatedOnce -ScriptPath $ScriptPath -ArgumentList $forward -AlreadyRelaunched:$AlreadyRelaunched
  if ($decision.action -eq 'relaunched') { exit $decision.exitCode }
}

function Join-MasterPath {
  param([Parameter(Mandatory = $true)][string]$Base, [Parameter(Mandatory = $true)][string[]]$Child)
  $path = $Base
  foreach ($part in $Child) {
    $path = Join-Path -Path $path -ChildPath $part
  }
  return $path
}

function Write-Utf8NoBom {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing $Path" }
  $text = [System.IO.File]::ReadAllText($Path)
  if ([string]::IsNullOrWhiteSpace($text)) { throw "Empty JSON $Path" }
  return ($text | ConvertFrom-Json)
}

function Get-Sha256Hex {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing $Path" }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Sha256 {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Expected,
    [string]$Label
  )
  $actual = Get-Sha256Hex $Path
  $want = $Expected.ToLowerInvariant()
  if ($actual -ne $want) {
    $name = $Label
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $Path }
    throw "hash mismatch for $name"
  }
  $item = Get-Item -LiteralPath $Path
  return [pscustomobject]@{ Path = $Path; Sha256 = $actual; Bytes = [int64]$item.Length }
}

function Assert-SafeRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $relative = ([string]$Path).Replace('\', '/').Trim()
  if ([string]::IsNullOrWhiteSpace($relative)) { throw 'Unsafe path' }
  if ($relative.StartsWith('/') -or $relative -match '(?i)^[a-z]:') { throw "Unsafe path $relative" }
  $parts = $relative.Split('/')
  foreach ($part in $parts) {
    if ($part -eq '' -or $part -eq '.' -or $part -eq '..') { throw "Unsafe path $relative" }
    if ($part -match '[<>:"|?*]') { throw "Unsafe path $relative" }
  }
  return ($parts -join '/')
}

function Join-SafeRelativePath {
  param([Parameter(Mandatory = $true)][string]$Base, [Parameter(Mandatory = $true)][string]$Relative)
  $path = $Base
  foreach ($part in (Assert-SafeRelativePath $Relative).Split('/')) {
    $path = Join-Path -Path $path -ChildPath $part
  }
  return $path
}

function Test-PreservedLeaf {
  param([Parameter(Mandatory = $true)][string]$Relative)
  $safe = Assert-SafeRelativePath $Relative
  $leaf = $safe.Split('/')[-1]
  if ($script:MasterPreserveFiles -contains $leaf) { return $true }
  if ($leaf -like '*.backup-*') { return $true }
  if ($safe -match '(?i)^(logs|ControlBackup-|Backup-)(/|$)') { return $true }
  if ($leaf -eq '.installed-bundle.json') { return $true }
  return $false
}

function Get-BrandAllowMap {
  # Roots are fixed. A catalog cannot redirect Mercedes into the BMW folder or the reverse.
  return @{
    mercedes = [pscustomobject]@{
      Id = 'mercedes'
      DisplayName = 'Mercedes-Benz'
      TagPrefix = 'mercedes-v'
      Root = 'DiagnosticWorkstation'
      RootBase = 'LOCALAPPDATA'
      Supervisor = 'WorkstationManager.exe'
      SupervisorNote = 'WorkstationManager.exe is the supervisor for every brand. This installer does not register Run or Winlogon startup.'
    }
    bmw = [pscustomobject]@{
      Id = 'bmw'
      DisplayName = 'BMW'
      TagPrefix = 'bmw-v'
      Root = 'BMW-Stealth-Launcher'
      RootBase = 'LOCALAPPDATA'
      Supervisor = 'Watchdog.ps1'
      SupervisorNote = 'The BMW bundle supervisor is the transitional Watchdog.ps1. WorkstationManager.exe migration is later. This installer does not register Run or Winlogon startup.'
    }
  }
}

function Get-BrandAllowEntry {
  param([Parameter(Mandatory = $true)][string]$Brand)
  $map = Get-BrandAllowMap
  if (-not $map.ContainsKey($Brand)) { throw "Brand $Brand is not approved for the master installer. Nothing was installed." }
  return $map[$Brand]
}

function Test-RetiredTag {
  param([Parameter(Mandatory = $true)][string]$Tag)
  if ($Tag -match '^(?i)universal-v') { throw 'universal-v tags are retired. Nothing was installed.' }
  if ($Tag -match '^v\d') { throw 'bare v tags are retired. Nothing was installed.' }
}

function Assert-BrandTag {
  param([Parameter(Mandatory = $true)][string]$Brand, [Parameter(Mandatory = $true)][string]$Tag)
  Test-RetiredTag $Tag
  $entry = Get-BrandAllowEntry $Brand
  $pattern = '^' + [regex]::Escape($entry.TagPrefix) + '\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$'
  if ($Tag -notmatch $pattern) { throw "Tag $Tag does not use $($entry.TagPrefix). Nothing was installed." }
}

function Get-ReleaseRank {
  param([Parameter(Mandatory = $true)][string]$Version)
  if ($Version -match '^(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?$') {
    $revision = 999999
    if ($Matches[4]) { $revision = [int]$Matches[4] }
    return [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], $revision)
  }
  throw "Unsupported version $Version"
}

function Find-MasterRepoRoot {
  param([Parameter(Mandatory = $true)][string]$Start)
  $dir = $Start
  for ($i = 0; $i -lt 8; $i++) {
    $catalog = Join-MasterPath $dir @('catalog', 'catalog.json')
    if (Test-Path -LiteralPath $catalog -PathType Leaf) { return $dir }
    $parent = Split-Path -Parent $dir
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
    $dir = $parent
  }
  throw 'Master repository root not found. Nothing was installed.'
}

function Find-SecurityToolsRoot {
  param([Parameter(Mandatory = $true)][string]$Start)
  $dir = $Start
  for ($i = 0; $i -lt 8; $i++) {
    $manifest = Join-MasterPath $dir @('tools', 'security', 'wub', 'tool-manifest.json')
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
      return (Join-MasterPath $dir @('tools', 'security'))
    }
    $parent = Split-Path -Parent $dir
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
    $dir = $parent
  }
  throw 'Approved security tools were not found. Nothing was changed.'
}

function Add-MasterJournal {
  param([Parameter(Mandatory = $true)][string]$Directory, [Parameter(Mandatory = $true)]$Event)
  if (-not (Test-Path -LiteralPath $Directory)) {
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
  }
  $payload = @{ utc = [datetimeoffset]::UtcNow.ToString('o') }
  if ($Event -is [System.Collections.IDictionary]) {
    foreach ($key in @($Event.Keys)) { $payload[$key] = $Event[$key] }
  } else {
    foreach ($property in $Event.PSObject.Properties) { $payload[$property.Name] = $property.Value }
  }
  $path = Join-Path -Path $Directory -ChildPath 'install-journal.log'
  $line = ($payload | ConvertTo-Json -Compress -Depth 8)
  [System.IO.File]::AppendAllText($path, $line + "`n", (New-Object System.Text.UTF8Encoding $false))
}

function Import-ZipAssembly {
  if ('System.IO.Compression.ZipFile' -as [type]) { return }
  try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
  if ('System.IO.Compression.ZipFile' -as [type]) { return }
  try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { }
  if (-not ('System.IO.Compression.ZipFile' -as [type])) { throw 'ZIP support is unavailable. Nothing was installed.' }
}

function Resolve-BrandInstallRoot {
  param([Parameter(Mandatory = $true)][string]$Brand, [string]$LocalAppData)
  $entry = Get-BrandAllowEntry $Brand
  if ([string]::IsNullOrWhiteSpace($LocalAppData)) { $LocalAppData = $env:LOCALAPPDATA }
  if ([string]::IsNullOrWhiteSpace($LocalAppData)) { throw 'LOCALAPPDATA is not set. Nothing was installed.' }
  return (Join-Path -Path $LocalAppData -ChildPath $entry.Root)
}
