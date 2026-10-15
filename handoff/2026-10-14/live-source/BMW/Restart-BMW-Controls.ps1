# Restarts only the two BMW WPF scripts. Watchdog remains running.
& {
 $ErrorActionPreference='Stop'
 $root=Join-Path $env:LOCALAPPDATA 'BMW-Stealth-Launcher'
 $psExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 foreach($name in @('Launcher','Dock')) {
   if(-not(Test-Path -LiteralPath (Join-Path $root ($name+'.ps1')))) {throw "Missing BMW $name script."}
 }
 Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
   Where-Object { $_.CommandLine -match 'BMW-Stealth-Launcher[\\/](Launcher|Dock)\.ps1' } |
   ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
 Start-Sleep -Seconds 5
 foreach($name in @('Launcher','Dock')) {
   $path=Join-Path $root ($name+'.ps1')
   $running=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$path*" })
   if($running.Count -eq 0) {
      Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass',"-File `"$path`"")
   }
 }
 Write-Host 'BMW Home and dock restart requested.' -ForegroundColor Green
}
