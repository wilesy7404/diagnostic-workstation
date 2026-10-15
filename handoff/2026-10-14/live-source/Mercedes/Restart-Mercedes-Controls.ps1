# Restart only the WPF launcher and dock; leave the workstation manager running.
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach ($name in @('Launcher','Dock')) {
    if (-not (Test-Path (Join-Path $root ($name+'.ps1')))) {throw "$name script missing."}
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $_.CommandLine -match 'DiagnosticWorkstation\\(Launcher|Dock)\.ps1'
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 4
foreach ($name in @('Launcher','Dock')) {
    $file=Join-Path $root ($name+'.ps1')
    $running=Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$file*" }
    if (-not $running) { Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass',"-File `"$file`"") }
}
Write-Host 'Mercedes Home and dock restart requested.' -ForegroundColor Green
