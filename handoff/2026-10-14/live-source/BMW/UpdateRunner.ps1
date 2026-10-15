param(
 [Parameter(Mandatory=$true)][string]$ZipUrl,
 [Parameter(Mandatory=$true)][string]$ManifestUrl,
 [Parameter(Mandatory=$true)][string]$Tag
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$status=Join-Path $root 'update-progress.json'
function Progress([string]$stage,[string]$message,[int]$percent){
 $o=@{state=$stage;message=$message;percent=$percent;checked=(Get-Date).ToString('o')}
 $tmp="$status.$PID.tmp"
 [IO.File]::WriteAllText($tmp,($o|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
 Move-Item -LiteralPath $tmp -Destination $status -Force
}
try {
 $target='https://github.com/wilesy7404/diagnostic-workstation/releases/download/'
 if(-not $ZipUrl.StartsWith($target,[StringComparison]::OrdinalIgnoreCase) -or -not $ManifestUrl.StartsWith($target,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected download URLs'}
 if($Tag -notmatch '^v\d+\.\d+\.\d+(-beta\.\d+)?$'){throw 'Invalid release version'}
 $stage=Join-Path $root ('Pending-'+($Tag -replace '[^0-9a-zA-Z.-]',''))
 [void](New-Item -ItemType Directory -Force -Path $stage)
 $zip=Join-Path $stage 'workstation.zip';$manifestFile=Join-Path $stage 'update-manifest.json'
 Progress downloading 'Downloading update package...' 10
 Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 120
 Progress verifying 'Downloading and verifying manifest...' 45
 Invoke-WebRequest -Uri $ManifestUrl -OutFile $manifestFile -UseBasicParsing -TimeoutSec 30
 $manifest=Get-Content -LiteralPath $manifestFile -Raw|ConvertFrom-Json
 if([string]$manifest.version -ne $Tag.Substring(1)){throw 'Release manifest version mismatch'}
 if((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$manifest.sha256).ToLowerInvariant()){throw 'Package checksum mismatch'}
 Progress validating 'Extracting and validating scripts...' 60
 $unpack=Join-Path $stage 'package';Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
 $expected=@('Launcher.ps1','Dock.ps1','Watchdog.ps1','SystemPanel.ps1')
 foreach($name in $expected){
  $f=Join-Path (Join-Path $unpack 'core') $name
  if(-not(Test-Path -LiteralPath $f -PathType Leaf)){throw "Missing $name"}
  $t=$null;$err=$null
  [void][Management.Automation.Language.Parser]::ParseFile($f,[ref]$t,[ref]$err)
  if(@($err).Count){throw "Invalid script $name"}
 }
 $ver=(Get-Content -LiteralPath (Join-Path $unpack 'version.json') -Raw | ConvertFrom-Json).version
 if([string]$ver -ne $Tag.Substring(1)){throw 'Package version mismatch'}
 $worker=Join-Path $root 'ApplyUpdate.ps1'
 if(-not(Test-Path $worker)){throw 'Recovery installer missing'}
 Progress installing 'Installing. BMW Home may restart...' 75
 $ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $p=Start-Process -FilePath $ps -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$worker+'" -PackageDirectory "'+$unpack+'"') -WindowStyle Hidden -PassThru
 # WaitForExit waits only for the updater worker, unlike Start-Process -Wait,
 # which can wait on descendants such as the long-running watchdog.
 if(-not $p.WaitForExit(180000)){throw 'Installer did not exit within 3 minutes; check BMW Home and update status'}
 $p.Refresh()
 # Do not treat a stale 'Update available' status as an installer failure.
 # Validate worker exit code, installed version and the responding BMW Home window.
 if($p.ExitCode -ne 0){throw ('Update worker exited with code '+$p.ExitCode)}
 $versionPath=Join-Path $root 'version.json'
 $verified=$false
 for($i=0;$i -lt 20;$i++){
  $installed=''
  try {$installed=[string](Get-Content -LiteralPath $versionPath -Raw|ConvertFrom-Json).version}catch{}
  $home=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
   Where-Object {$_.CommandLine -match 'BMW-Stealth-Launcher\\Launcher\.ps1'})
  foreach($proc in $home){
   try {
    $gp=Get-Process -Id $proc.ProcessId -ErrorAction Stop
    if($installed -eq $Tag.Substring(1) -and $gp.MainWindowTitle -eq 'BMW Diagnostic System' -and $gp.MainWindowHandle -ne 0 -and $gp.Responding){
     $verified=$true;break
    }
   }catch{}
  }
  if($verified){break}
  Start-Sleep -Seconds 1
 }
 if(-not $verified){throw 'Installer finished but target version and responsive BMW Home were not both verified'}
 Progress success 'Update installed. BMW Home verified.' 100
}catch{
 Progress error ('Update failed: '+$_.Exception.Message) 0
}
