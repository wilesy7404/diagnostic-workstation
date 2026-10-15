param([string]$Root)
$ws=New-Object -ComObject WScript.Shell
$paths=@((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Diagnostic Workstation.lnk'),(Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Diagnostic Workstation\Diagnostic Workstation.lnk'))
foreach($p in $paths){New-Item -ItemType Directory -Force -Path (Split-Path $p)|Out-Null;$s=$ws.CreateShortcut($p);$s.TargetPath=Join-Path $Root 'WorkstationManager.exe';$s.Arguments='/supervise';$s.WorkingDirectory=$Root;$s.Description='Launch Diagnostic Workstation';$s.Save()}
