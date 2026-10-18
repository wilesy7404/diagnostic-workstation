# Approved-tool wrapper for Windows Update Blocker, plus the native Defender control module.
# Windows Update Blocker arguments come from tools/security/wub/tool-manifest.json:
#   disable / re-apply: Wub_x64.exe /D /P   (32-bit Windows uses Wub.exe)
#   enable / undo:      Wub_x64.exe /E
# Those flags are the published Sordum command line. This environment cannot run the
# Windows binaries, so a throwaway Windows VM still has to confirm `Wub_x64.exe /?`
# before this is merged. Windows Feature Updates can reset WUB; re-apply /D /P afterward.
#
# Defender is changed by installer/Master/lib/Defender.ps1 (Set-MpPreference and policy DWORDs). Protected services stay running.
# The old Defender Control binary is not shipped and is not started.

if (-not (Get-Command -Name Invoke-DefenderControl -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'Defender.ps1')
}

function Get-SecurityManifest {
  param([Parameter(Mandatory = $true)][string]$ToolsRoot, [Parameter(Mandatory = $true)][string]$Slot)
  $dir = Join-Path -Path $ToolsRoot -ChildPath $Slot
  $path = Join-Path -Path $dir -ChildPath 'tool-manifest.json'
  $manifest = Read-JsonFile $path
  if ([string]$manifest.schema -ne 'diagnostic-workstation.approved-tool/v1') { throw "unsupported tool manifest for $Slot" }
  if ([string]$manifest.tool -ne $Slot) { throw "tool manifest slot mismatch for $Slot" }
  return [pscustomobject]@{ Directory = $dir; Manifest = $manifest; Path = $path }
}

function Assert-ManifestFiles {
  param($Loaded)
  $manifest = $Loaded.Manifest
  foreach ($binary in @($manifest.binaries)) {
    if (-not $binary) { continue }
    $full = Join-Path -Path $Loaded.Directory -ChildPath ([string]$binary.name)
    $info = Assert-Sha256 $full ([string]$binary.sha256) ([string]$binary.name)
    if ($null -ne $binary.bytes -and [int64]$info.Bytes -ne [int64]$binary.bytes) { throw "size mismatch $($binary.name)" }
  }
  foreach ($side in @($manifest.sidecars)) {
    if (-not $side) { continue }
    $full = Join-Path -Path $Loaded.Directory -ChildPath ([string]$side.name)
    $info = Assert-Sha256 $full ([string]$side.sha256) ([string]$side.name)
    if ($null -ne $side.bytes -and [int64]$info.Bytes -ne [int64]$side.bytes) { throw "size mismatch $($side.name)" }
  }
}

function Get-WubArch {
  param([string]$Arch)
  if ($Arch -eq 'x64' -or $Arch -eq 'x86') { return $Arch }
  if ([Environment]::Is64BitOperatingSystem) { return 'x64' }
  return 'x86'
}

function Select-WubExecutable {
  param($Loaded, [string]$Arch)
  Assert-ManifestFiles $Loaded
  $arch = Get-WubArch $Arch
  $name = $(if ($arch -eq 'x64') { 'Wub_x64.exe' } else { 'Wub.exe' })
  $found = $false
  foreach ($binary in @($Loaded.Manifest.binaries)) {
    if ([string]$binary.name -eq $name) { $found = $true }
  }
  if (-not $found) { throw 'WUB executable for this architecture is not pinned' }
  return (Join-Path -Path $Loaded.Directory -ChildPath $name)
}

function Get-WubArguments {
  param($Manifest, [Parameter(Mandatory = $true)][ValidateSet('disable', 'enable', 'reapply')][string]$Action)
  $raw = $null
  if ($Action -eq 'enable') { $raw = $Manifest.enableArgs } else { $raw = $Manifest.disableArgs }
  $toolArgs = @($raw | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($toolArgs.Count -eq 0) { throw 'Windows Update Blocker arguments are not pinned' }
  return $toolArgs
}

function Get-UpdateServiceSnapshot {
  param([scriptblock]$StateReader)
  if ($StateReader) { return (& $StateReader) }
  if (-not (Test-MasterHostWindows)) { return @(@{ name = 'unavailable'; status = 'not-windows' }) }
  $items = @()
  foreach ($name in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')) {
    try {
      $service = Get-Service -Name $name -ErrorAction Stop
      $mode = ''
      try {
        $wmi = Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'" -ErrorAction Stop
        $mode = [string]$wmi.StartMode
      } catch { }
      $items += @{ name = $name; status = [string]$service.Status; startMode = $mode }
    } catch {
      $items += @{ name = $name; status = 'query-failed' }
    }
  }
  return $items
}

function Get-DefenderSnapshot {
  param([scriptblock]$TamperReader)
  if ($TamperReader) { return (& $TamperReader) }
  $snap = @{ tamper = 'unknown'; realtime = 'unknown' }
  if (-not (Test-MasterHostWindows)) { return $snap }
  $registry = 'unknown'
  try {
    $value = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name TamperProtection -ErrorAction Stop
    if ([int]$value.TamperProtection -eq 1) { $registry = 'on' }
    elseif ([int]$value.TamperProtection -eq 0) { $registry = 'off' }
  } catch { }
  $computed = 'unknown'
  try {
    $status = Get-MpComputerStatus -ErrorAction Stop
    if ($status.IsTamperProtected) { $computed = 'on' } else { $computed = 'off' }
    $snap.realtime = [string]$status.RealTimeProtectionEnabled
  } catch { }
  if ($registry -eq 'on' -or $computed -eq 'on') { $snap.tamper = 'on' }
  elseif ($registry -eq 'off' -or $computed -eq 'off') { $snap.tamper = 'off' }
  return $snap
}

function Request-TamperProtectionOff {
  param([scriptblock]$TamperPrompt)
  $message = 'Tamper Protection is on, so Windows Defender was not changed. Turn it off in Windows Security > Virus & threat protection > Manage settings, then choose OK to check again.'
  if ($TamperPrompt) { return [bool](& $TamperPrompt $message) }
  if (-not (Test-MasterHostWindows)) { return $false }
  Add-Type -AssemblyName System.Windows.Forms
  $result = [System.Windows.Forms.MessageBox]::Show(
    $message,
    'Diagnostic Workstation',
    [System.Windows.Forms.MessageBoxButtons]::OKCancel,
    [System.Windows.Forms.MessageBoxIcon]::Warning
  )
  return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

function Start-HiddenApprovedTool {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string[]]$ArgumentList,
    [scriptblock]$ToolRunner
  )
  if ($ToolRunner) {
    # Keep the argument array intact. The call operator would otherwise split it.
    $payload = New-Object object[] 2
    $payload[0] = $Executable
    $payload[1] = [string[]]$ArgumentList
    return [int]$ToolRunner.InvokeReturnAsIs($payload)
  }
  if ($env:MASTER_INSTALLER_FORBID_TOOL_EXECUTION -eq '1') { throw 'approved tool execution is forbidden in this session' }
  if (-not (Test-MasterHostWindows)) { throw 'approved tools run on Windows only' }
  if (-not (Test-IsWindowsAdmin)) { throw 'approved tools require an elevated session' }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Executable
  $psi.Arguments = ($ArgumentList -join ' ')
  $psi.WorkingDirectory = Split-Path -Parent $Executable
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $psi.CreateNoWindow = $true
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $process = [System.Diagnostics.Process]::Start($psi)
  if (-not $process.WaitForExit(120000)) {
    try { $process.Kill() } catch { }
    throw 'approved tool timed out'
  }
  return [int]$process.ExitCode
}

function Copy-SecuritySlot {
  param($Loaded, [Parameter(Mandatory = $true)][string]$DestinationRoot)
  $dest = Join-Path -Path $DestinationRoot -ChildPath $Loaded.Manifest.tool
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  $names = @('tool-manifest.json')
  foreach ($binary in @($Loaded.Manifest.binaries)) { if ($binary) { $names += [string]$binary.name } }
  foreach ($side in @($Loaded.Manifest.sidecars)) { if ($side) { $names += [string]$side.name } }
  foreach ($name in $names) {
    Copy-Item -LiteralPath (Join-Path -Path $Loaded.Directory -ChildPath $name) -Destination (Join-Path -Path $dest -ChildPath $name) -Force
  }
  $copied = Get-SecurityManifest $DestinationRoot $Loaded.Manifest.tool
  Assert-ManifestFiles $copied
  return $copied
}

function Invoke-WindowsUpdateTool {
  param(
    [Parameter(Mandatory = $true)][string]$ToolsRoot,
    [Parameter(Mandatory = $true)][ValidateSet('disable', 'enable', 'reapply')][string]$Action,
    [Parameter(Mandatory = $true)][string]$LogDirectory,
    [string]$Arch,
    [scriptblock]$ToolRunner,
    [scriptblock]$StateReader
  )
  $loaded = Get-SecurityManifest $ToolsRoot 'wub'
  if ([string]$loaded.Manifest.status -ne 'wired') { throw 'Windows Update Blocker is not an approved wired tool' }
  $exe = Select-WubExecutable $loaded $Arch
  $arguments = @(Get-WubArguments $loaded.Manifest $Action)
  $pre = Get-UpdateServiceSnapshot $StateReader
  Add-MasterJournal $LogDirectory ([pscustomobject]@{
    step = 'windows-update-pre'; action = $Action; exe = (Split-Path -Leaf $exe); sha256 = (Get-Sha256Hex $exe)
    arguments = ($arguments -join ' '); pre = $pre
    note = 'Windows Feature Updates may reset Windows Update Blocker. Re-apply /D /P after a feature update.'
  })
  $exitCode = Start-HiddenApprovedTool $exe $arguments $ToolRunner
  $post = Get-UpdateServiceSnapshot $StateReader
  Add-MasterJournal $LogDirectory ([pscustomobject]@{
    step = 'windows-update-post'; action = $Action; exitCode = $exitCode; post = $post
  })
  if ($exitCode -ne 0) { throw "Windows Update Blocker exited $exitCode" }
  $status = $(if ($Action -eq 'enable') { 'enabled' } else { 'disabled' })
  return [pscustomobject]@{ status = $status; exitCode = $exitCode; exe = $exe; arguments = $arguments; pre = $pre; post = $post }
}

function Invoke-DefenderDisable {
  param(
    [Parameter(Mandatory = $true)][string]$LogDirectory,
    [Parameter(Mandatory = $true)][string]$SnapshotPath,
    [scriptblock]$ReadState,
    [scriptblock]$CommandSink,
    [scriptblock]$TamperPrompt,
    [scriptblock]$TaskHost
  )
  return Invoke-DefenderControl -Action 'disable' -LogDirectory $LogDirectory -SnapshotPath $SnapshotPath -ReadState $ReadState -CommandSink $CommandSink -TamperPrompt $TamperPrompt -TaskHost $TaskHost
}

function Copy-MasterCommands {
  param([Parameter(Mandatory = $true)][string]$RepoRoot, [Parameter(Mandatory = $true)][string]$InstallerData)
  # Windows PowerShell 5.1 Join-Path accepts only -Path and -ChildPath. Nest two-argument calls.
  $source = Join-MasterPath $RepoRoot @('installer', 'Master')
  $dest = Join-Path -Path $InstallerData -ChildPath 'Master'
  $libDir = Join-Path -Path $dest -ChildPath 'lib'
  New-Item -ItemType Directory -Force -Path $dest, $libDir | Out-Null
  foreach ($name in @('Enable-Security.ps1', 'Uninstall-MasterBrand.ps1', 'Install-Master.ps1')) {
    $file = Join-Path -Path $source -ChildPath $name
    if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination (Join-Path -Path $dest -ChildPath $name) -Force }
  }
  Get-ChildItem -LiteralPath (Join-Path -Path $source -ChildPath 'lib') -Filter '*.ps1' | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path -Path $libDir -ChildPath $_.Name) -Force
  }
}

function Register-SecurityShortcuts {
  param(
    [Parameter(Mandatory = $true)][string]$Brand,
    [Parameter(Mandatory = $true)][string]$InstallerData,
    [string]$StartMenuRoot
  )
  $master = Join-Path -Path $InstallerData -ChildPath 'Master'
  if ([string]::IsNullOrWhiteSpace($StartMenuRoot)) {
    if ((Test-MasterHostWindows) -and $env:APPDATA -and $env:MASTER_INSTALLER_FORBID_TOOL_EXECUTION -ne '1') {
      $StartMenuRoot = Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\Windows\Start Menu\Programs\Diagnostic Workstation'
    } else {
      $StartMenuRoot = Join-Path -Path $InstallerData -ChildPath 'start-menu'
    }
  }
  New-Item -ItemType Directory -Force -Path $StartMenuRoot | Out-Null
  $powershell = 'powershell.exe'
  if (Test-MasterHostWindows -and $env:SystemRoot) {
    $powershell = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
  }
  $entries = @(
    [pscustomobject]@{ name = 'Re-enable Windows Update and Defender'; script = 'Enable-Security.ps1'; arguments = "-Brand $Brand -Action enable" },
    [pscustomobject]@{ name = 'Re-apply Windows Update block'; script = 'Enable-Security.ps1'; arguments = "-Brand $Brand -Action reapply" },
    [pscustomobject]@{ name = 'Uninstall Diagnostic Workstation security undo'; script = 'Uninstall-MasterBrand.ps1'; arguments = "-Brand $Brand" }
  )
  $recorded = @()
  foreach ($entry in $entries) {
    $scriptPath = Join-Path -Path $master -ChildPath $entry.script
    $argumentLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" {1}' -f $scriptPath, $entry.arguments
    $lnk = Join-Path -Path $StartMenuRoot -ChildPath ($entry.name + '.lnk')
    $recorded += [pscustomobject]@{ name = $entry.name; lnk = $lnk; target = $powershell; arguments = $argumentLine }
    if ((Test-MasterHostWindows) -and $env:MASTER_INSTALLER_FORBID_TOOL_EXECUTION -ne '1') {
      $shell = New-Object -ComObject WScript.Shell
      $link = $shell.CreateShortcut($lnk)
      $link.TargetPath = $powershell
      $link.Arguments = $argumentLine
      $link.WorkingDirectory = $master
      $link.WindowStyle = 7
      $link.Description = $entry.name
      $link.Save()
    }
  }
  $recordPath = Join-Path -Path $InstallerData -ChildPath ("shortcuts-{0}.json" -f $Brand)
  Write-Utf8NoBom $recordPath (($recorded | ConvertTo-Json -Depth 5) + "`n")
  return $recordPath
}

function Invoke-AutomaticSecurity {
  param(
    [Parameter(Mandatory = $true)][string]$Brand,
    [Parameter(Mandatory = $true)][string]$InstallerData,
    [Parameter(Mandatory = $true)][string]$LogDirectory,
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [string]$Arch,
    [string]$StartMenuRoot,
    [scriptblock]$ToolRunner,
    [scriptblock]$StateReader,
    [scriptblock]$TamperReader,
    [scriptblock]$TamperPrompt,
    [scriptblock]$DefenderReader,
    [scriptblock]$DefenderSink,
    [scriptblock]$TaskHost
  )
  $sourceTools = Find-SecurityToolsRoot $RepoRoot
  $deployed = Join-MasterPath $InstallerData @('tools', 'security')
  $wubCopy = Copy-SecuritySlot (Get-SecurityManifest $sourceTools 'wub') $deployed
  Copy-MasterCommands $RepoRoot $InstallerData
  $shortcutRecord = Register-SecurityShortcuts $Brand $InstallerData $StartMenuRoot
  $update = [pscustomobject]@{ status = 'failed'; error = $null }
  try {
    $update = Invoke-WindowsUpdateTool -ToolsRoot $deployed -Action 'disable' -LogDirectory $LogDirectory -Arch $Arch -ToolRunner $ToolRunner -StateReader $StateReader
  } catch {
    $update = [pscustomobject]@{ status = 'failed'; error = $_.Exception.Message }
    Add-MasterJournal $LogDirectory ([pscustomobject]@{ step = 'windows-update-failed'; message = $_.Exception.Message })
  }
  $reader = $DefenderReader
  if (-not $reader -and $TamperReader) { $reader = $TamperReader }
  $snapshot = Join-Path -Path $InstallerData -ChildPath 'defender-pre-state.json'
  $defender = Invoke-DefenderDisable -LogDirectory $LogDirectory -SnapshotPath $snapshot -ReadState $reader -CommandSink $DefenderSink -TamperPrompt $TamperPrompt -TaskHost $TaskHost
  $state = [ordered]@{
    brand = $Brand
    utc = [datetimeoffset]::UtcNow.ToString('o')
    windowsUpdate = $update.status
    defender = $defender.status
    tamper = $defender.tamper
    shortcuts = $shortcutRecord
    featureUpdateNote = 'Windows Feature Updates may reset Windows Update Blocker. Use Re-apply Windows Update block.'
    wubDirectory = $wubCopy.Directory
    defenderControl = 'native-powershell'
  }
  Write-Utf8NoBom (Join-Path $InstallerData ("security-state-{0}.json" -f $Brand)) (($state | ConvertTo-Json -Depth 6) + "`n")
  return [pscustomobject]@{
    windowsUpdate = [string]$update.status
    defender = [string]$defender.status
    tamper = [string]$defender.tamper
  }
}

function Invoke-SecurityUndo {
  param(
    [Parameter(Mandatory = $true)][string]$Brand,
    [Parameter(Mandatory = $true)][ValidateSet('enable', 'reapply')][string]$Action,
    [string]$InstallerData,
    [string]$LogDirectory,
    [string]$RepoRoot,
    [string]$Arch,
    [scriptblock]$ToolRunner,
    [scriptblock]$StateReader,
    [scriptblock]$DefenderReader,
    [scriptblock]$DefenderSink,
    [scriptblock]$TamperPrompt,
    [scriptblock]$TaskHost
  )
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Find-MasterRepoRoot $PSScriptRoot }
  $tools = $null
  if ($InstallerData) {
    $candidate = Join-MasterPath $InstallerData @('tools', 'security', 'wub', 'tool-manifest.json')
    if (Test-Path -LiteralPath $candidate) { $tools = Join-MasterPath $InstallerData @('tools', 'security') }
  }
  if (-not $tools) { $tools = Find-SecurityToolsRoot $(if ($InstallerData) { $InstallerData } else { $RepoRoot }) }
  if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $base = $InstallerData
    if ([string]::IsNullOrWhiteSpace($base)) { $base = Join-Path $RepoRoot 'dist-logs' }
    $LogDirectory = Join-Path $base 'logs'
  }
  $result = Invoke-WindowsUpdateTool -ToolsRoot $tools -Action $Action -LogDirectory $LogDirectory -Arch $Arch -ToolRunner $ToolRunner -StateReader $StateReader
  $defenderStatus = 'not-run'
  if ($Action -eq 'enable') {
    $snapshotRoot = $InstallerData
    if ([string]::IsNullOrWhiteSpace($snapshotRoot)) { $snapshotRoot = $LogDirectory }
    $snapshot = Join-Path -Path $snapshotRoot -ChildPath 'defender-pre-state.json'
    $defenderResult = Invoke-DefenderControl -Action 'enable' -LogDirectory $LogDirectory -SnapshotPath $snapshot -ReadState $DefenderReader -CommandSink $DefenderSink -TamperPrompt $TamperPrompt -TaskHost $TaskHost
    $defenderStatus = [string]$defenderResult.status
  }
  return [pscustomobject]@{ windowsUpdate = $result.status; defender = $defenderStatus; brand = $Brand }
}
