# BMW supervisor: remains the logged-in shell; restarts launcher and dock if they exit.
$ErrorActionPreference='Continue'
$folder=Split-Path -Parent $MyInvocation.MyCommand.Path
$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launch=Join-Path $folder 'Launcher.ps1'
$dock=Join-Path $folder 'Dock.ps1'
$failures=@{}
function Is-Running([string]$path) {
 try {
  $needle=[IO.Path]::GetFileName($path)
  return (@(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop | Where-Object {
    $_.CommandLine -and $_.CommandLine.Contains($needle) -and -not $_.CommandLine.Contains('Watchdog.ps1')
  }).Count -gt 0)
 } catch {return $true} # avoid duplicates if process enumeration temporarily fails
}
while($true){
 foreach($scriptPath in @($launch,$dock)){
  if((Test-Path $scriptPath) -and -not(Is-Running $scriptPath)){
   try {
    $key=[IO.Path]::GetFileName($scriptPath)
    $now=Get-Date
    if($failures.ContainsKey($key) -and (($now-$failures[$key]).TotalSeconds -lt 8)){continue}
    $failures[$key]=$now
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$scriptPath+'"')) -WindowStyle Hidden
   }catch{}
  }
 }
 Start-Sleep -Seconds 4
}
