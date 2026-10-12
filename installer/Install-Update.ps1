# Diagnostic Workstation core package installer (PowerShell 5.1)
# For use only with locally verified and approved release packages.
param([Parameter(Mandatory=$true)][string]$PackageDirectory)
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'BMW-Stealth-Launcher'
$names=@('Launcher.ps1','Dock.ps1','Watchdog.ps1','SystemPanel.ps1')
$staged=Join-Path $PackageDirectory 'core'
if(-not (Test-Path $staged -PathType Container)){throw 'Missing core directory. No changes made.'}
$required=@('Launcher.ps1','Dock.ps1','Watchdog.ps1')
foreach($name in $required){if(-not(Test-Path (Join-Path $staged $name))){throw "Missing $name. No changes made."}}
foreach($name in $names){
 $path=Join-Path $staged $name
 if(Test-Path $path){
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
  if($errors.Count){throw "PowerShell syntax error in $name. No changes made."}
 }
}
# An update must be run by a separate approved updater after the UI and watchdog exit.
# Do not run this in the currently active custom-shell process.
$live=Get-CimInstance Win32_Process -Filter "name='powershell.exe'" -ErrorAction SilentlyContinue |
 Where-Object { $_.CommandLine -match 'BMW-Stealth-Launcher\\(Launcher|Dock|Watchdog)\.ps1' }
if($live){throw 'BMW workstation is running. Stop/restart it through the approved updater before installation. Nothing changed.'}
if(-not(Test-Path $root)){throw 'Existing workstation installation not found.'}
$backup=Join-Path $root ('Backup-Release-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
foreach($name in $names){$dest=Join-Path $root $name;if(Test-Path $dest){Copy-Item $dest (Join-Path $backup $name) -Force}}
$applied=New-Object 'System.Collections.Generic.List[string]'
try {
 foreach($name in $names){
  $source=Join-Path $staged $name
  if(Test-Path $source){
   Copy-Item $source (Join-Path $root $name) -Force
   $applied.Add($name)
  }
 }
 Write-Host "Core files installed. Backup: $backup"
 Write-Host 'Local app settings, brand configuration and OEM diagnostic programs were not touched.'
} catch {
 foreach($name in $applied){
  $prior=Join-Path $backup $name
  if(Test-Path $prior){Copy-Item $prior (Join-Path $root $name) -Force}
 }
 throw "Install failed and file backups were restored: $($_.Exception.Message)"
}
