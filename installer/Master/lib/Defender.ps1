# Native Windows Defender control for the master installer.
# Uses documented Set-MpPreference settings, Defender policy values, and the WinDefend service family.
# Policy registry writes stay in the elevated admin process. Set-MpPreference and service start/stop
# run as SYSTEM through a transient scheduled task, with one TrustedInstaller retry if SYSTEM is denied.
# The task is created, started, and deleted in the same step. It has no trigger and does not change Winlogon.
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

function Test-DefenderAccessDenied([string]$Message) {
  return $Message -match '(?i)access is denied|access denied|0x80070005'
}

function Get-DefenderCommandScope([string]$Kind) {
  if ($Kind -eq 'Set-Policy' -or $Kind -eq 'Remove-Policy') { return 'admin' }
  return 'system'
}

# Runs commands in order. An access-denied failure retries the remainder once through the
# TrustedInstaller delegate. Policy writes stay with the caller; this is used for the SYSTEM job.
function Invoke-DefenderCommandListWithFallback {
  param($Commands, [scriptblock]$Executor, [scriptblock]$TrustedInstallerBatch)
  $applied = @()
  $list = @($Commands | Where-Object { $_ })
  $index = 0
  while ($index -lt $list.Count) {
    $command = $list[$index]
    try {
      & $Executor $command
      $applied += $command
      $index++
    } catch {
      $message = $_.Exception.Message
      if ($TrustedInstallerBatch -and (Test-DefenderAccessDenied $message)) {
        $rest = @()
        for ($cursor = $index; $cursor -lt $list.Count; $cursor++) { $rest += $list[$cursor] }
        $fallback = & $TrustedInstallerBatch $rest
        if (-not $fallback -or -not [bool]$fallback.ok) {
          $detail = $message
          if ($fallback -and $fallback.error) { $detail = [string]$fallback.error }
          return [pscustomobject]@{ ok = $false; error = $detail; applied = @($applied); failed = $command; trustedInstaller = $true }
        }
        $merged = @($applied)
        foreach ($item in @($fallback.applied)) { if ($item) { $merged += $item } }
        return [pscustomobject]@{ ok = $true; error = $null; applied = $merged; failed = $null; trustedInstaller = $true }
      }
      return [pscustomobject]@{ ok = $false; error = $message; applied = @($applied); failed = $command; trustedInstaller = $false }
    }
  }
  return [pscustomobject]@{ ok = $true; error = $null; applied = @($applied); failed = $null; trustedInstaller = $false }
}

function Test-DefenderTrustedInstallerIdentity {
  if (-not (Test-MasterHostWindows)) { return $false }
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([string]$identity.Name) -match '(?i)TrustedInstaller'
  } catch { return $false }
}

function Invoke-DefenderLiveCommand($Command) {
  if ($env:MASTER_INSTALLER_FORBID_TOOL_EXECUTION -eq '1') { throw 'defender changes are forbidden in this session' }
  if (-not (Test-MasterHostWindows)) { throw 'defender changes run on Windows only' }
  $elevated = (Test-IsWindowsAdmin) -or (Test-DefenderTrustedInstallerIdentity)
  if (-not $elevated) { throw 'defender changes require an elevated session' }
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

function Register-DefenderSystemTask($Spec) {
  if ($env:MASTER_INSTALLER_FORBID_TOOL_EXECUTION -eq '1') { throw 'defender system task is forbidden in this session' }
  if (-not (Test-MasterHostWindows)) { throw 'defender system task runs on Windows only' }
  $stale = @(Get-ScheduledTask -TaskName 'DiagnosticWorkstation-Defender-*' -ErrorAction SilentlyContinue)
  foreach ($task in $stale) {
    if ($task.TaskName -and [string]$task.TaskName -ne [string]$Spec.taskName) {
      Unregister-ScheduledTask -TaskName ([string]$task.TaskName) -Confirm:$false -ErrorAction SilentlyContinue
    }
  }
  $action = New-ScheduledTaskAction -Execute ([string]$Spec.execute) -Argument ([string]$Spec.argumentLine) -WorkingDirectory ([string]$Spec.workingDirectory)
  $principal = New-ScheduledTaskPrincipal -UserId ([string]$Spec.userId) -LogonType ServiceAccount -RunLevel ([string]$Spec.runLevel)
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
  try { $settings.Hidden = $true } catch { }
  Register-ScheduledTask -TaskName ([string]$Spec.taskName) -Action $action -Principal $principal -Settings $settings -Description 'Transient Diagnostic Workstation Defender change. Deleted when the step finishes.' -Force | Out-Null
}

function Start-DefenderSystemTask($Spec) {
  Start-ScheduledTask -TaskName ([string]$Spec.taskName) | Out-Null
}

function Remove-DefenderSystemTask($Spec) {
  Unregister-ScheduledTask -TaskName ([string]$Spec.taskName) -Confirm:$false -ErrorAction SilentlyContinue
}

function Wait-DefenderSystemTaskResult($Spec) {
  $deadline = [datetime]::UtcNow.AddSeconds(180)
  while ([datetime]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath ([string]$Spec.resultFile)) {
      try {
        $data = Read-JsonFile ([string]$Spec.resultFile)
        return [pscustomobject]@{
          ok = [bool]$data.ok
          error = $data.error
          applied = @($data.applied)
          trustedInstaller = [bool]$data.trustedInstaller
        }
      } catch { }
    }
    Start-Sleep -Milliseconds 200
  }
  return [pscustomobject]@{ ok = $false; error = 'defender system task timed out'; applied = @(); trustedInstaller = $false }
}

function Invoke-DefenderSystemBatch {
  param($Commands, [scriptblock]$TaskHost, [string]$LogDirectory)
  $list = @($Commands | Where-Object { $_ })
  if ($list.Count -eq 0) {
    return [pscustomobject]@{ ok = $true; error = $null; applied = @(); failed = $null }
  }
  $taskName = 'DiagnosticWorkstation-Defender-' + [guid]::NewGuid().ToString('n')
  $work = Join-Path -Path $LogDirectory -ChildPath ('defender-task-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $commandFile = Join-Path -Path $work -ChildPath 'commands.json'
  $resultFile = Join-Path -Path $work -ChildPath 'result.json'
  Write-Utf8NoBom $commandFile (([pscustomobject]@{ commands = @($list) } | ConvertTo-Json -Depth 6) + "`n")
  $job = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-DefenderSystemJob.ps1'
  $execute = Get-MasterWindowsPowerShell
  $argumentLine = Format-MasterCommandLine @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', $job, '-CommandFile', $commandFile, '-ResultFile', $resultFile
  )
  $spec = [pscustomobject]@{
    taskName = $taskName
    userId = 'SYSTEM'
    runLevel = 'Highest'
    execute = $execute
    argumentLine = $argumentLine
    workingDirectory = $PSScriptRoot
    commands = @($list)
    hidden = $true
    transient = $true
    commandFile = $commandFile
    resultFile = $resultFile
  }
  $registered = $false
  $deleted = $false
  $taskOk = $false
  $taskError = $null
  $trustedInstaller = $false
  try {
    if ($TaskHost) { $null = & $TaskHost 'register' $spec }
    else { Register-DefenderSystemTask $spec }
    $registered = $true
    if ($TaskHost) { $null = & $TaskHost 'start' $spec }
    else { Start-DefenderSystemTask $spec }
    if ($TaskHost) { $wait = & $TaskHost 'wait' $spec }
    else { $wait = Wait-DefenderSystemTaskResult $spec }
    $taskOk = [bool]($wait -and $wait.ok)
    if ($wait) { $trustedInstaller = [bool]$wait.trustedInstaller }
    if (-not $taskOk) {
      $taskError = 'defender system task failed'
      if ($wait -and $wait.error) { $taskError = [string]$wait.error }
      return [pscustomobject]@{ ok = $false; error = $taskError; applied = @(); failed = $list[0] }
    }
    $applied = @($list)
    if ($wait -and $wait.applied) {
      $fromWait = @($wait.applied | Where-Object { $_ })
      if ($fromWait.Count -gt 0) { $applied = $fromWait }
    }
    return [pscustomobject]@{ ok = $true; error = $null; applied = $applied; failed = $null }
  } catch {
    $taskError = $_.Exception.Message
    return [pscustomobject]@{ ok = $false; error = $taskError; applied = @(); failed = $list[0] }
  } finally {
    if ($registered) {
      try {
        if ($TaskHost) { $null = & $TaskHost 'delete' $spec }
        else { Remove-DefenderSystemTask $spec }
        $deleted = $true
      } catch { $deleted = $false }
    }
    if ($LogDirectory) {
      try {
        Add-MasterJournal $LogDirectory ([pscustomobject]@{
          step = 'defender-system-task'
          taskName = $taskName
          principal = 'SYSTEM'
          runLevel = 'Highest'
          deleted = $deleted
          transient = $true
          ok = $taskOk
          trustedInstaller = $trustedInstaller
          error = $taskError
        })
      } catch { }
    }
  }
}

function Invoke-DefenderScopedBatch {
  param($Scope, $Batch, [scriptblock]$CommandSink, [scriptblock]$TaskHost, [string]$LogDirectory)
  $items = @()
  foreach ($item in @($Batch)) { if ($item) { $items += $item } }
  if ($Scope -eq 'admin') { return Invoke-DefenderCommands $items $CommandSink }
  return Invoke-DefenderSystemBatch -Commands $items -TaskHost $TaskHost -LogDirectory $LogDirectory
}

# Policy writes run in this process. Set-MpPreference and Set-Service run as SYSTEM.
# Consecutive commands of the same scope stay in one batch so disable order is preserved.
function Invoke-DefenderPlannedCommands {
  param($Commands, [scriptblock]$CommandSink, [scriptblock]$TaskHost, [string]$LogDirectory)
  if ($CommandSink -and -not $TaskHost) { return Invoke-DefenderCommands $Commands $CommandSink }
  $applied = @()
  $pending = New-Object System.Collections.Generic.List[object]
  $scope = $null
  foreach ($command in @($Commands)) {
    if (-not $command) { continue }
    $next = Get-DefenderCommandScope ([string]$command.kind)
    if ($null -ne $scope -and $next -ne $scope -and $pending.Count -gt 0) {
      $batchItems = @($pending.ToArray())
      $batch = Invoke-DefenderScopedBatch -Scope $scope -Batch $batchItems -CommandSink $CommandSink -TaskHost $TaskHost -LogDirectory $LogDirectory
      if (-not $batch.ok) {
        return [pscustomobject]@{ ok = $false; error = $batch.error; applied = @($applied); failed = $batch.failed }
      }
      foreach ($item in @($batch.applied)) { if ($item) { $applied += $item } }
      $pending.Clear()
    }
    $scope = $next
    $pending.Add($command) | Out-Null
  }
  if ($pending.Count -gt 0) {
    $batchItems = @($pending.ToArray())
    $batch = Invoke-DefenderScopedBatch -Scope $scope -Batch $batchItems -CommandSink $CommandSink -TaskHost $TaskHost -LogDirectory $LogDirectory
    if (-not $batch.ok) {
      return [pscustomobject]@{ ok = $false; error = $batch.error; applied = @($applied); failed = $batch.failed }
    }
    foreach ($item in @($batch.applied)) { if ($item) { $applied += $item } }
  }
  return [pscustomobject]@{ ok = $true; error = $null; applied = @($applied); failed = $null }
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
    [scriptblock]$TamperPrompt,
    [scriptblock]$TaskHost
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
  $result = Invoke-DefenderPlannedCommands -Commands $commands -CommandSink $CommandSink -TaskHost $TaskHost -LogDirectory $LogDirectory
  if (-not $result.ok -and (Test-DefenderTamperError ([string]$result.error)) -and -not $gate.prompted) {
    $accepted = Request-TamperProtectionOff $TamperPrompt
    if ($accepted) {
      $retryState = if ($ReadState) { & $ReadState } else { Get-DefenderLiveState }
      if ([string]$retryState.tamper -eq 'off') {
        if ($Action -eq 'enable') {
          $saved = Read-DefenderSnapshot $SnapshotPath
          if (-not $saved) { $saved = New-DefenderDefaultEnableSnapshot $state }
          Invoke-DefenderPlannedCommands -Commands (Get-DefenderEnableCommands $saved) -CommandSink $CommandSink -TaskHost $TaskHost -LogDirectory $LogDirectory | Out-Null
        }
        $result = Invoke-DefenderPlannedCommands -Commands $commands -CommandSink $CommandSink -TaskHost $TaskHost -LogDirectory $LogDirectory
      }
    }
  }
  if (-not $result.ok) {
    if ($Action -eq 'disable') {
      $saved = Read-DefenderSnapshot $SnapshotPath
      if ($saved) { Invoke-DefenderPlannedCommands -Commands (Get-DefenderEnableCommands $saved) -CommandSink $CommandSink -TaskHost $TaskHost -LogDirectory $LogDirectory | Out-Null }
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
