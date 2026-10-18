param([switch]$Quiet)
$ErrorActionPreference='Stop'
$old=Join-Path $env:LOCALAPPDATA 'Mercedes-Diagnostic-Workstation'
Add-Type -AssemblyName PresentationFramework
if(-not $Quiet){
 $confirm=[Windows.MessageBox]::Show("Remove the older Mercedes workstation and its startup entry?`n`nA backup of its settings and installer logs will be kept. This does not uninstall XENTRY, DTS Monaco, Vediamo, or affect BMW.", 'Legacy Mercedes Cleanup','YesNo','Question')
 if($confirm -ne [Windows.MessageBoxResult]::Yes){exit 0}
}
$backup=Join-Path $env:LOCALAPPDATA ('DiagnosticWorkstation-Backups\Legacy-Mercedes-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -Path $backup -ItemType Directory -Force|Out-Null
foreach($name in @('apps.json','version.json','update-settings.json','logs')){
 $p=Join-Path $old $name
 if(Test-Path $p){Copy-Item -LiteralPath $p -Destination (Join-Path $backup $name) -Force -Recurse}
}
# Preserve earlier installer backups, which may contain the only copy of app paths.
if(Test-Path -LiteralPath $old){
 foreach($directory in @(Get-ChildItem -LiteralPath $old -Directory -Filter 'Backup-*' -ErrorAction SilentlyContinue)) {
  Copy-Item -LiteralPath $directory.FullName -Destination (Join-Path $backup $directory.Name) -Recurse -Force
 }
}

foreach($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System','HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon')){
 $shell=[string](Get-ItemProperty $key -Name Shell -ErrorAction SilentlyContinue).Shell
 if($shell -match '(?i)Mercedes-Diagnostic-Workstation'){
  New-ItemProperty -Path $key -Name Shell -PropertyType String -Value 'explorer.exe' -Force|Out-Null
 }
}
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'MercedesDiagnosticWorkstation' -ErrorAction SilentlyContinue
$procs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
 ($_.Name -eq 'MercedesSupervisor.exe' -and $_.ExecutablePath -and $_.ExecutablePath.StartsWith($old,[StringComparison]::OrdinalIgnoreCase)) -or
 ($_.Name -eq 'powershell.exe' -and $_.CommandLine -and $_.CommandLine.Contains($old+'\') -and $_.CommandLine -match '(Launcher|Dock|Watchdog|UpdateAgent)\.ps1')
})
foreach($p in $procs){if($p.ProcessId -ne $PID){Stop-Process $p.ProcessId -Force -ErrorAction SilentlyContinue}}
Start-Sleep 1
if(Test-Path $old){Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction Stop}
$desktop=[Environment]::GetFolderPath('Desktop')
foreach($name in @('Mercedes Diagnostic Workstation.lnk','Mercedes Workstation.lnk')){$p=Join-Path $desktop $name;if(Test-Path $p){Remove-Item $p -Force}}
# The failed shell-mode tool did not establish a published installation. Do not alter machine-wide registry.
if(-not $Quiet){[Windows.MessageBox]::Show("Legacy Mercedes workstation removed.`n`nBackup: $backup`n`nWindows Explorer shell remains available. Any change takes effect at next sign-in.",'Legacy Mercedes Cleanup','OK','Information')|Out-Null}
