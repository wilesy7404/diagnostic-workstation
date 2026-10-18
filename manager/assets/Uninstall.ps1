param([switch]$Quiet)
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'DiagnosticWorkstation'
$brand='Diagnostic Workstation'
if(Test-Path (Join-Path $root 'profile.json')){try{$brand=[string](Get-Content (Join-Path $root 'profile.json') -Raw | ConvertFrom-Json).displayName}catch{}}
Add-Type -AssemblyName PresentationFramework
if(-not $Quiet){
 $choice=[System.Windows.MessageBox]::Show("Uninstall $brand Diagnostic Workstation for this Windows account?`n`nYour app settings will be backed up. Windows Explorer and other manufacturer partitions will not be modified.",'Uninstall Diagnostic Workstation','YesNo','Question')
 if($choice -ne [System.Windows.MessageBoxResult]::Yes){exit 0}
}
$backup=Join-Path $env:LOCALAPPDATA ('DiagnosticWorkstation-Backups\Uninstall-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $backup|Out-Null
foreach($name in @('apps.json','profile.json','update-settings.json')){ $p=Join-Path $root $name;if(Test-Path $p){Copy-Item $p (Join-Path $backup $name) -Force} }
# Do not remove the active Windows shell. Restore Explorer only if a legacy/universal shell explicitly points to our path.
foreach($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System','HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon')){
 $shell=[string](Get-ItemProperty $key -Name Shell -ErrorAction SilentlyContinue).Shell
 if($shell -match '(?i)DiagnosticWorkstation|Mercedes-Diagnostic-Workstation'){
  New-ItemProperty -Path $key -Name Shell -Value 'explorer.exe' -PropertyType String -Force|Out-Null
 }
}
$run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
Remove-ItemProperty -Path $run -Name 'UniversalDiagnosticWorkstation' -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\UniversalDiagnosticWorkstation' -Recurse -Force -ErrorAction SilentlyContinue
# Stop only this workstation. Never terminate generic powershell sessions or another brand's installation.
$procs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
 ($_.Name -eq 'WorkstationManager.exe' -and $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) -or
 ($_.Name -eq 'powershell.exe' -and $_.CommandLine -and $_.CommandLine.Contains((Join-Path $root 'Launcher.ps1'))) -or
 ($_.Name -eq 'powershell.exe' -and $_.CommandLine -and $_.CommandLine.Contains((Join-Path $root 'Dock.ps1'))) -or
 ($_.Name -eq 'powershell.exe' -and $_.CommandLine -and $_.CommandLine.Contains((Join-Path $root 'UpdateAgent.ps1')))
})
foreach($p in $procs){if($p.ProcessId -ne $PID){Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue}}
Start-Sleep 1
$desk=[Environment]::GetFolderPath('Desktop')
$short=Join-Path $desk 'Diagnostic Workstation.lnk'
if(Test-Path $short){Remove-Item $short -Force}
$programs=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Diagnostic Workstation'
if(Test-Path $programs){Remove-Item $programs -Recurse -Force}
# Keep the data backup outside the program folder.
if(Test-Path $root){
 try{Remove-Item $root -Recurse -Force -ErrorAction Stop}
 catch{
  # A manager binary may remain locked briefly; run a post-exit cleanup outside its directory.
  $cleanup=Join-Path $env:TEMP ('DW-Remove-'+[guid]::NewGuid().ToString('N')+'.ps1')
  '$p='+"'"+$root.Replace("'","''")+"'"+"`nStart-Sleep -Seconds 5`nRemove-Item -LiteralPath `$p -Recurse -Force -ErrorAction SilentlyContinue`n" | Set-Content $cleanup -Encoding UTF8
  Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$cleanup+'"') -WindowStyle Hidden
 }
}
if(-not $Quiet){[System.Windows.MessageBox]::Show("Uninstall completed.`n`nSettings backup: $backup`n`nIf this account used a custom shell, sign out/in to return to Explorer.",'Diagnostic Workstation','OK','Information')|Out-Null}
