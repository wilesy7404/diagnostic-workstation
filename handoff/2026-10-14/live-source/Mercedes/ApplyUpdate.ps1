param([Parameter(Mandatory=$true)][string]$PackageDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$source=Join-Path $PackageDirectory 'core'
$files=@('Launcher.ps1','Dock.ps1','Watchdog.ps1','SystemPanel.ps1','version.json')
$required=@('Launcher.ps1','Dock.ps1','Watchdog.ps1')
$psExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$backup=Join-Path $root ('Backup-Update-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
$status=Join-Path $root 'update-status.json'
$profile=Get-Content -LiteralPath (Join-Path $root 'profile.json') -Raw|ConvertFrom-Json
$homeTitle=([string]$profile.displayName)+' Diagnostic System'
$log=Join-Path $root 'update-install.log'
$installMarker=Join-Path $root 'install-in-progress.lock'
function Log([string]$s){ Add-Content -LiteralPath $log -Value ('{0} {1}' -f (Get-Date -Format 's'),$s) }
function Set-Status([string]$state,[string]$msg){
  @{state=$state;latest='';message=$msg;checked=(Get-Date).ToString('s')} | ConvertTo-Json -Compress | Set-Content -LiteralPath $status -Encoding UTF8
}
function Get-WorkstationProcess([string]$kind){
  @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
    $_.CommandLine -match ('(?i)DiagnosticWorkstation\\'+[regex]::Escape($kind)+'\.ps1(?:\s|"|$)') -and $_.ProcessId -ne $PID
  })
}
function Stop-Workstation {
  foreach($kind in @('Launcher','Dock','Watchdog','SystemPanel')) {
    foreach($p in (Get-WorkstationProcess $kind)) {
      Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
}
function Start-Watchdog {
  $w=Join-Path $root 'Watchdog.ps1'
  if(-not (Test-Path -LiteralPath $w)){throw 'Watchdog missing'}
  Start-Process -FilePath $psExe -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$w+'"') -WindowStyle Hidden | Out-Null
}
function Wait-ForHome([int]$seconds){
  $until=(Get-Date).AddSeconds($seconds)
  do {
    foreach($proc in (Get-WorkstationProcess 'Launcher')) {
      $p=Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
      if($null -ne $p -and $p.MainWindowHandle -ne [IntPtr]::Zero -and $p.MainWindowTitle -eq $homeTitle -and $p.Responding){return $true}
    }
    Start-Sleep -Seconds 2
  } while((Get-Date) -lt $until)
  return $false
}
$present=@{}
$changesStarted=$false
try {
  if(-not(Test-Path -LiteralPath $PackageDirectory -PathType Container)){throw 'Update package missing'}
  foreach($f in $required){if(-not(Test-Path -LiteralPath (Join-Path $source $f) -PathType Leaf)){throw "Release missing $f"}}
  foreach($f in @('Launcher.ps1','Dock.ps1','Watchdog.ps1','SystemPanel.ps1')){
    $path=Join-Path $source $f
    if(Test-Path -LiteralPath $path -PathType Leaf){
      $tokens=$null;$errors=$null
      [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
      if(@($errors).Count -gt 0){throw "Syntax error in $f"}
    }
  }
  $incomingVersion=Join-Path $PackageDirectory 'version.json'
  if(Test-Path -LiteralPath $incomingVersion){
    $obj=Get-Content -LiteralPath $incomingVersion -Raw | ConvertFrom-Json
    if([string]::IsNullOrWhiteSpace([string]$obj.version)){throw 'Invalid package version'}
  }
  New-Item -ItemType Directory -Path $backup -Force | Out-Null
  foreach($f in $files){
    $p=Join-Path $root $f
    $present[$f]=Test-Path -LiteralPath $p -PathType Leaf
    if($present[$f]){Copy-Item -LiteralPath $p -Destination (Join-Path $backup $f) -Force -ErrorAction Stop}
  }
  Log "Backed up to $backup"
  $changesStarted=$true
  Set-Content -LiteralPath $installMarker -Value (Get-Date).ToString('o') -Encoding UTF8
  Stop-Workstation
  Start-Sleep -Seconds 2
  foreach($f in $files){
    $src=if($f -eq 'version.json'){$incomingVersion}else{Join-Path $source $f}
    if(Test-Path -LiteralPath $src -PathType Leaf){Copy-Item -LiteralPath $src -Destination (Join-Path $root $f) -Force -ErrorAction Stop}
  }
  # Hand control back to the single shared supervisor: do not spawn a second watchdog.
  Remove-Item -LiteralPath $installMarker -Force -ErrorAction SilentlyContinue
  if(-not(Wait-ForHome 50)){throw 'Workstation Home did not display a responding window within 35 seconds'}
  Log 'Update installed; Workstation Home window is responding'
  Set-Status 'current' 'Update installed; Workstation Home window verified'
}catch{
  $reason=$_.Exception.Message
  Log "Update failure: $reason"
  if(-not $changesStarted){ Set-Status 'error' ("Update rejected before changing live files: $reason"); exit 1 }
  try {
    Set-Content -LiteralPath $installMarker -Value (Get-Date).ToString('o') -Encoding UTF8
    Stop-Workstation
    foreach($f in $files){
      if($present.ContainsKey($f)) {
        $dest=Join-Path $root $f
        if($present[$f]){Copy-Item -LiteralPath (Join-Path $backup $f) -Destination $dest -Force -ErrorAction Stop}
        elseif(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Force -ErrorAction Stop}
      }
    }
    Remove-Item -LiteralPath $installMarker -Force -ErrorAction SilentlyContinue
    if(-not(Wait-ForHome 50)) {
      # A direct launch is a fallback if the original watchdog did not relaunch Home.
      $launcher=Join-Path $root 'Launcher.ps1'
      if(Test-Path -LiteralPath $launcher){Start-Process -FilePath $psExe -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$launcher+'"') -WindowStyle Hidden | Out-Null}
      if(-not(Wait-ForHome 20)){throw 'Rollback files restored, but Workstation Home did not restart'}
    }
    Log 'Rollback complete; Workstation Home responding'
    Set-Status 'error' ("Update rolled back: $reason")
  }catch{
    Log ("CRITICAL: Recovery failed: " + $_.Exception.Message)
    Set-Status 'error' ("Recovery needs attention: " + $_.Exception.Message + "; original backup: " + $backup)
  }
  exit 1
}

finally { Remove-Item -LiteralPath $installMarker -Force -ErrorAction SilentlyContinue }
