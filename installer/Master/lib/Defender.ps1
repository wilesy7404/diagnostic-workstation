# Native Windows Defender control for the master installer.
# Uses documented Set-MpPreference settings, Defender policy values, and the WinDefend service family.
# It does not start the old Defender Control binary, does not open a window, and does not change Winlogon or boot-start drivers.
# Tamper Protection is detected first. The user is prompted only when it is on and blocking.

function Get-DefenderControlPlan {
  $preference = @(
    @{ Name = 'DisableRealtimeMonitoring'; Disable = $true; Enable = $false },
    @{ Name = 'DisableBehaviorMonitoring'; Disable = $true; Enable = $false },
    @{ Name = 'DisableIOAVProtection'; Disable = $true; Enable = $false },
    @{ Name = 'DisableScriptScanning'; Disable = $true; Enable = $false },
    @{ Name = 'DisableBlockAtFirstSeen'; Disable = $true; Enable = $false },
    @{ Name = 'DisableIntrusionPreventionSystem'; Disable = $true; Enable = $false },
    @{ Name = 'DisableEmailScanning'; Disable = $true; Enable = $false },
    @{ Name = 'DisableRemovableDriveScanning'; Disable = $true; Enable = $false },
    @{ Name = 'DisableScanningMappedNetworkDrivesForFullScan'; Disable = $true; Enable = $false },
    @{ Name = 'DisableArchiveScanning'; Disable = $true; Enable = $false },
    @{ Name = 'PUAProtection'; Disable = 0; Enable = 1 },
    @{ Name = 'MAPSReporting'; Disable = 0; Enable = 2 },
    @{ Name = 'SubmitSamplesConsent'; Disable = 2; Enable = 1 }
  )
  $policyRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
  $realtime = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'
  $policy = @(
    @{ Path = $policyRoot; Name = 'DisableAntiSpyware' },
    @{ Path = $policyRoot; Name = 'DisableAntiVirus' },
    @{ Path = $realtime; Name = 'DisableRealtimeMonitoring' },
    @{ Path = $realtime; Name = 'DisableBehaviorMonitoring' },
    @{ Path = $realtime; Name = 'DisableOnAccessProtection' },
    @{ Path = $realtime; Name = 'DisableScanOnRealtimeEnable' },
    @{ Path = $realtime; Name = 'DisableIOAVProtection' },
    @{ Path = $realtime; Name = 'DisableScriptScanning' }
  )
  return [pscustomobject]@{
    Preferences = $preference
    Policies = $policy
    Services = @('WinDefend', 'WdNisSvc', 'MDCoreSvc')
  }
}

function ConvertTo-DefenderHashtable($Object) {
  if ($null -eq $Object) { return @{} }
  if ($Object -is [System.Collections.IDictionary]) { return $Object }
  $table = @{}
  foreach ($property in $Object.PSObject.Properties) { $table[$property.Name] = $property.Value }
  return $table
}

function Get-DefenderPolicyObserved($State, [string]$Path, [string]$Name) {
  foreach ($item in @($State.policies)) {
    if (-not $item) { continue }
    if ([string]$item.path -eq $Path -and [string]$item.name -eq $Name) { return $item }
  }
  return [pscustomobject]@{ path = $Path; name = $Name; exists = $false; value = $null }
}

function Get-DefenderServiceObserved($State, [string]$Name) {
  foreach ($item in @($State.services | Where-Object { $_ })) {
    if ([string]$item.name -eq $Name) { return $item }
  }
  return [pscustomobject]@{ name = $Name; present = $false; status = 'absent'; startMode = '' }
}

function New-DefenderDefaultEnableSnapshot($LiveState) {
  $plan = Get-DefenderControlPlan
  $services = @()
  foreach ($name in @($plan.Services)) {
    $observed = Get-DefenderServiceObserved $LiveState $name
    if (-not [bool]$observed.present) { continue }
    $services += [pscustomobject]@{
      name = $name
      present = $true
      status = 'Running'
      startMode = 'Automatic'
    }
  }
  return [pscustomobject]@{
    schema = 'diagnostic-workstation.defender-snapshot/v1'
    capturedUtc = [datetimeoffset]::UtcNow.ToString('o')
    tamper = [string]$LiveState.tamper
    preferences = @{}
    policies = @()
    services = $services
  }
}

function Get-DefenderLiveState {
  $plan = Get-DefenderControlPlan
  $preferences = @{}
  $mp = $null
  try { $mp = Get-MpPreference -ErrorAction Stop } catch { }
  foreach ($item in @($plan.Preferences)) {
    $value = $null
    if ($mp -and ($mp.PSObject.Properties.Name -contains $item.Name)) { $value = $mp.($item.Name) }
    $preferences[$item.Name] = $value
  }
  $status = @{ tamper = 'unknown'; realtime = 'unknown' }
  try {
    $computer = Get-MpComputerStatus -ErrorAction Stop
    if ($computer.IsTamperProtected) { $status.tamper = 'on' } else { $status.tamper = 'off' }
    $status.realtime = [string]$computer.RealTimeProtectionEnabled
    $status.ioav = [string]$computer.IoavProtectionEnabled
    $status.behavior = [string]$computer.BehaviorMonitorEnabled
    $status.antivirus = [string]$computer.AntivirusEnabled
    $status.nis = [string]$computer.NISEnabled
  } catch { }
  $registryTamper = 'unknown'
  try {
    $value = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name TamperProtection -ErrorAction Stop
    if ([int]$value.TamperProtection -eq 1) { $registryTamper = 'on' }
    elseif ([int]$value.TamperProtection -eq 0) { $registryTamper = 'off' }
  } catch { }
  if ($registryTamper -eq 'on' -or $status.tamper -eq 'on') { $status.tamper = 'on' }
  elseif ($registryTamper -eq 'off' -or $status.tamper -eq 'off') { $status.tamper = 'off' }
  $policies = @()
  foreach ($item in @($plan.Policies)) {
    $exists = $false
    $current = $null
    try {
      $property = Get-ItemProperty -Path $item.Path -Name $item.Name -ErrorAction Stop
      $exists = $true
      $current = $property.($item.Name)
    } catch { }
    $policies += [pscustomobject]@{ path = $item.Path; name = $item.Name; exists = $exists; value = $current }
  }
  $services = @()
  foreach ($name in @($plan.Services)) {
    try {
      $service = Get-Service -Name $name -ErrorAction Stop
      $mode = ''
      try {
        $wmi = Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'" -ErrorAction Stop
        $mode = [string]$wmi.StartMode
      } catch { }
      $services += [pscustomobject]@{ name = $name; present = $true; status = [string]$service.Status; startMode = $mode }
    } catch {
      $services += [pscustomobject]@{ name = $name; present = $false; status = 'absent'; startMode = '' }
    }
  }
  return [pscustomobject]@{
    tamper = [string]$status.tamper
    computerStatus = $status
    preferences = $preferences
    policies = $policies
    services = $services
  }
}

function New-DefenderSnapshot($State) {
  $plan = Get-DefenderControlPlan
  $preferences = ConvertTo-DefenderHashtable $State.preferences
  $storedPreferences = @{}
  foreach ($item in @($plan.Preferences)) {
    if ($preferences.ContainsKey($item.Name)) { $storedPreferences[$item.Name] = $preferences[$item.Name] }
    else { $storedPreferences[$item.Name] = $null }
  }
  $policies = @()
  foreach ($item in @($plan.Policies)) {
    $observed = Get-DefenderPolicyObserved $State $item.Path $item.Name
    $policies += [pscustomobject]@{
      path = $item.Path
      name = $item.Name
      exists = [bool]$observed.exists
      value = $observed.value
    }
  }
  $services = @()
  foreach ($name in @($plan.Services)) {
    $observed = Get-DefenderServiceObserved $State $name
    $services += [pscustomobject]@{
      name = $name
      present = [bool]$observed.present
      status = [string]$observed.status
      startMode = [string]$observed.startMode
    }
  }
  return [pscustomobject]@{
    schema = 'diagnostic-workstation.defender-snapshot/v1'
    capturedUtc = [datetimeoffset]::UtcNow.ToString('o')
    tamper = [string]$State.tamper
    preferences = $storedPreferences
    policies = $policies
    services = $services
  }
}

function Get-DefenderServiceStartup([string]$StartMode, [string]$Fallback) {
  switch ($StartMode) {
    'Auto' { return 'Automatic' }
    'Automatic' { return 'Automatic' }
    'Manual' { return 'Manual' }
    'Disabled' { return 'Disabled' }
    default { return $Fallback }
  }
}

function Get-DefenderDisableCommands($State) {
  $plan = Get-DefenderControlPlan
  $commands = @()
  foreach ($item in @($plan.Preferences)) {
    $commands += [pscustomobject]@{ kind = 'Set-MpPreference'; name = $item.Name; value = $item.Disable }
  }
  foreach ($item in @($plan.Policies)) {
    $commands += [pscustomobject]@{ kind = 'Set-Policy'; path = $item.Path; name = $item.Name; value = 1 }
  }
  $names = @($plan.Services)
  for ($index = $names.Count - 1; $index -ge 0; $index--) {
    $name = [string]$names[$index]
    $observed = Get-DefenderServiceObserved $State $name
    if (-not [bool]$observed.present) { continue }
    $commands += [pscustomobject]@{ kind = 'Set-Service'; name = $name; startupType = 'Disabled'; status = 'Stopped' }
  }
  return $commands
}

function Get-DefenderEnableCommands($Snapshot) {
  $plan = Get-DefenderControlPlan
  $commands = @()
  $preferences = ConvertTo-DefenderHashtable $Snapshot.preferences
  foreach ($item in @($plan.Preferences)) {
    $value = $item.Enable
    if ($preferences.ContainsKey($item.Name) -and $null -ne $preferences[$item.Name]) { $value = $preferences[$item.Name] }
    $commands += [pscustomobject]@{ kind = 'Set-MpPreference'; name = $item.Name; value = $value }
  }
  foreach ($item in @($plan.Policies)) {
    $observed = Get-DefenderPolicyObserved $Snapshot $item.Path $item.Name
    if ([bool]$observed.exists) {
      $commands += [pscustomobject]@{ kind = 'Set-Policy'; path = $item.Path; name = $item.Name; value = $observed.value }
    } else {
      $commands += [pscustomobject]@{ kind = 'Remove-Policy'; path = $item.Path; name = $item.Name }
    }
  }
  foreach ($name in @($plan.Services)) {
    $observed = Get-DefenderServiceObserved $Snapshot $name
    if (-not [bool]$observed.present) { continue }
    $running = ([string]$observed.status -eq 'Running')
    $commands += [pscustomobject]@{
      kind = 'Set-Service'
      name = $name
      startupType = (Get-DefenderServiceStartup ([string]$observed.startMode) 'Automatic')
      status = $(if ($running) { 'Running' } else { 'Stopped' })
    }
  }
  return $commands
}

function Test-DefenderTamperError([string]$Message) {
  return $Message -match '(?i)tamper protection|tamperprotection|not allowed because tamper'
}

function Invoke-DefenderLiveCommand($Command) {
  if ($env:MASTER_INSTALLER_FORBID_TOOL_EXECUTION -eq '1') { throw 'defender changes are forbidden in this session' }
  if (-not (Test-MasterHostWindows)) { throw 'defender changes run on Windows only' }
  if (-not (Test-IsWindowsAdmin)) { throw 'defender changes require an elevated session' }
  switch ([string]$Command.kind) {
    'Set-MpPreference' {
      $parameters = @{}
      $parameters[[string]$Command.name] = $Command.value
      Set-MpPreference @parameters
    }
    'Set-Policy' {
      if (-not (Test-Path -LiteralPath ([string]$Command.path))) {
        New-Item -Path ([string]$Command.path) -Force | Out-Null
      }
      New-ItemProperty -Path ([string]$Command.path) -Name ([string]$Command.name) -Value ([int]$Command.value) -PropertyType DWord -Force | Out-Null
    }
    'Remove-Policy' {
      if (Test-Path -LiteralPath ([string]$Command.path)) {
        Remove-ItemProperty -Path ([string]$Command.path) -Name ([string]$Command.name) -ErrorAction SilentlyContinue
      }
    }
    'Set-Service' {
      $startup = [string]$Command.startupType
      if ($startup -ne 'Automatic' -and $startup -ne 'Manual' -and $startup -ne 'Disabled') { $startup = 'Automatic' }
      Set-Service -Name ([string]$Command.name) -StartupType $startup -ErrorAction Stop
      if ([string]$Command.status -eq 'Stopped') {
        Stop-Service -Name ([string]$Command.name) -Force -ErrorAction Stop
      } elseif ([string]$Command.status -eq 'Running') {
        Start-Service -Name ([string]$Command.name) -ErrorAction Stop
      }
    }
    default { throw "Unknown defender command $($Command.kind)" }
  }
}

function Invoke-DefenderCommands($Commands, [scriptblock]$CommandSink) {
  $applied = @()
  foreach ($command in @($Commands)) {
    if (-not $command) { continue }
    try {
      if ($CommandSink) { & $CommandSink $command }
      else { Invoke-DefenderLiveCommand $command }
      $applied += $command
    } catch {
      return [pscustomobject]@{ ok = $false; error = $_.Exception.Message; applied = $applied; failed = $command }
    }
  }
  return [pscustomobject]@{ ok = $true; error = $null; applied = $applied; failed = $null }
}

function Save-DefenderSnapshot([string]$Path, $Snapshot) {
  Write-Utf8NoBom $Path (($Snapshot | ConvertTo-Json -Depth 8) + "`n")
}

function Read-DefenderSnapshot([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return Read-JsonFile $Path
}

function Resolve-DefenderTamper {
  param($State, [scriptblock]$ReadState, [scriptblock]$TamperPrompt, [string]$LogDirectory, [string]$Action)
  $tamper = [string]$State.tamper
  if ($tamper -ne 'on') {
    return [pscustomobject]@{ proceed = $true; state = $State; tamper = $(if ($tamper) { $tamper } else { 'unknown' }); prompted = $false }
  }
  Add-MasterJournal $LogDirectory ([pscustomobject]@{ step = 'defender-tamper-detected'; action = $Action; tamper = 'on' })
  $accepted = Request-TamperProtectionOff $TamperPrompt
  if (-not $accepted) {
    return [pscustomobject]@{ proceed = $false; state = $State; tamper = 'on'; prompted = $true; status = 'tamper-blocked' }
  }
  $again = if ($ReadState) { & $ReadState } else { Get-DefenderLiveState }
  $next = [string]$again.tamper
  if ($next -ne 'off') {
    return [pscustomobject]@{ proceed = $false; state = $again; tamper = $(if ($next) { $next } else { 'unknown' }); prompted = $true; status = 'tamper-blocked' }
  }
  return [pscustomobject]@{ proceed = $true; state = $again; tamper = 'off'; prompted = $true }
}

function Invoke-DefenderControl {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('disable', 'enable')][string]$Action,
    [Parameter(Mandatory = $true)][string]$LogDirectory,
    [Parameter(Mandatory = $true)][string]$SnapshotPath,
    [scriptblock]$ReadState,
    [scriptblock]$CommandSink,
    [scriptblock]$TamperPrompt
  )
  $read = if ($ReadState) { & $ReadState } else { Get-DefenderLiveState }
  Add-MasterJournal $LogDirectory ([pscustomobject]@{ step = 'defender-pre'; action = $Action; pre = $read })
  $gate = Resolve-DefenderTamper -State $read -ReadState $ReadState -TamperPrompt $TamperPrompt -LogDirectory $LogDirectory -Action $Action
  if (-not $gate.proceed) {
    Add-MasterJournal $LogDirectory ([pscustomobject]@{ step = 'defender-tamper'; action = $Action; status = 'tamper-blocked'; tamper = $gate.tamper; changed = $false })
    return [pscustomobject]@{ status = 'tamper-blocked'; changed = $false; tamper = [string]$gate.tamper; pre = $read; post = $read }
  }
  $state = $gate.state
  if ($Action -eq 'disable') {
    $snapshot = New-DefenderSnapshot $state
    Save-DefenderSnapshot $SnapshotPath $snapshot
    $commands = @(Get-DefenderDisableCommands $state)
  } else {
    $saved = Read-DefenderSnapshot $SnapshotPath
    if (-not $saved) { $saved = New-DefenderDefaultEnableSnapshot $state }
    $commands = @(Get-DefenderEnableCommands $saved)
  }
  $result = Invoke-DefenderCommands $commands $CommandSink
  if (-not $result.ok -and (Test-DefenderTamperError ([string]$result.error)) -and -not $gate.prompted) {
    $accepted = Request-TamperProtectionOff $TamperPrompt
    if ($accepted) {
      $retryState = if ($ReadState) { & $ReadState } else { Get-DefenderLiveState }
      if ([string]$retryState.tamper -eq 'off') {
        if ($Action -eq 'enable') {
          $saved = Read-DefenderSnapshot $SnapshotPath
          if (-not $saved) { $saved = New-DefenderDefaultEnableSnapshot $state }
          Invoke-DefenderCommands (Get-DefenderEnableCommands $saved) $CommandSink | Out-Null
        }
        $result = Invoke-DefenderCommands $commands $CommandSink
      }
    }
  }
  if (-not $result.ok) {
    if ($Action -eq 'disable') {
      $saved = Read-DefenderSnapshot $SnapshotPath
      if ($saved) { Invoke-DefenderCommands (Get-DefenderEnableCommands $saved) $CommandSink | Out-Null }
    }
    Add-MasterJournal $LogDirectory ([pscustomobject]@{ step = 'defender-failed'; action = $Action; message = [string]$result.error; changed = $false })
    if (Test-DefenderTamperError ([string]$result.error)) {
      return [pscustomobject]@{ status = 'tamper-blocked'; changed = $false; tamper = 'on'; pre = $state; post = $state }
    }
    return [pscustomobject]@{ status = 'failed'; changed = $false; tamper = [string]$state.tamper; pre = $state; post = $state; error = [string]$result.error }
  }
  $post = if ($ReadState) { & $ReadState } else { Get-DefenderLiveState }
  Add-MasterJournal $LogDirectory ([pscustomobject]@{
    step = 'defender-post'; action = $Action; status = $(if ($Action -eq 'disable') { 'disabled' } else { 'enabled' })
    commands = @($commands | ForEach-Object { @{ kind = [string]$_.kind; name = [string]$_.name; path = [string]$_.path; value = $_.value; startupType = [string]$_.startupType; status = [string]$_.status } })
    post = $post
  })
  $status = $(if ($Action -eq 'disable') { 'disabled' } else { 'enabled' })
  return [pscustomobject]@{ status = $status; changed = $true; tamper = [string]$post.tamper; pre = $state; post = $post }
}
