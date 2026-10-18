param([switch]$Preview)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$progressPath=Join-Path $root 'update-progress.json'
$statusPath=Join-Path $root 'update-status.json'
function Set-UpdateStatus([string]$state,[string]$latest,[string]$message){
 @{checked=(Get-Date).ToString('s');state=$state;latest=$latest;message=$message}|ConvertTo-Json -Compress|Set-Content -LiteralPath $statusPath -Encoding UTF8
}
function Rank([string]$value){
 $v=$value -replace '^universal-v','' -replace '^v',''
 if($v -match '^(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?$'){
  $r=if($Matches[4]){[int]$Matches[4]}else{999999}
  return [version]::new([int]$Matches[1],[int]$Matches[2],[int]$Matches[3],$r)
 }
 return [version]'0.0.0.0'
}
function Get-Latest {
 $config=Get-Content -LiteralPath (Join-Path $root 'update-settings.json') -Raw|ConvertFrom-Json
 $repo=[string]$config.repo
 if($repo -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$'){throw 'Invalid repository setting'}
 $response=Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=25" -Headers @{'User-Agent'='DiagnosticWorkstation-Updater'} -TimeoutSec 20
 $results=if($response -is [array]){$response}else{@($response)}
 $candidates=@(foreach($rel in $results){
  $names=@($rel.assets|ForEach-Object{$_.name})
  if(-not $rel.draft -and ($config.channel -eq 'beta' -or -not $rel.prerelease) -and $rel.tag_name -match '^universal-v\d+\.\d+\.\d+(-beta\.\d+)?$' -and
  $names -contains 'workstation.zip' -and $names -contains 'update-manifest.json'){
    $rel
  }
 })
 $sorted=@($candidates|Sort-Object -Property @{Expression={Rank ([string]$_.tag_name)};Descending=$true})
 if($sorted.Count){return $sorted[0]}
 return $null
}
function Show-Updater([string]$version,[string]$zipUrl,[string]$manifestUrl,[bool]$isPreview){
 $w=New-Object System.Windows.Window
 $w.Title='Workstation Update';$w.Width=540;$w.Height=390;$w.MinHeight=390;$w.MaxHeight=390
 $w.ResizeMode='NoResize';$w.WindowStartupLocation='CenterScreen'
 $w.Topmost=$true;$w.ShowActivated=$true;$w.ShowInTaskbar=$true
 $w.Background=[Windows.Media.Brushes]::White
 $grid=New-Object Windows.Controls.Grid
 $grid.Margin=New-Object Windows.Thickness(24)
 foreach($h in @(55,70,50,65,70)){  $row=New-Object Windows.Controls.RowDefinition; $row.Height=[System.Windows.GridLength]::new($h);[void]$grid.RowDefinitions.Add($row)}
 $header=New-Object Windows.Controls.TextBlock
 $header.Text='DIAGNOSTIC WORKSTATION UPDATE';$header.FontSize=19;$header.FontWeight='SemiBold'
 [Windows.Controls.Grid]::SetRow($header,0);[void]$grid.Children.Add($header)
 $message=New-Object Windows.Controls.TextBlock
 $message.Text=if($isPreview){'Preview mode - no installation will occur.'}else{"Version $version is available. Install now?"}
 $message.FontSize=14;$message.TextWrapping='Wrap'
 [Windows.Controls.Grid]::SetRow($message,1);[void]$grid.Children.Add($message)
 $bar=New-Object Windows.Controls.ProgressBar
 $bar.Minimum=0;$bar.Maximum=100;$bar.Value=0;$bar.Height=16;$bar.IsIndeterminate=$false
 [Windows.Controls.Grid]::SetRow($bar,2);[void]$grid.Children.Add($bar)
 $detail=New-Object Windows.Controls.TextBlock
 $detail.Text='Ready to update';$detail.FontSize=13
 [Windows.Controls.Grid]::SetRow($detail,3);[void]$grid.Children.Add($detail)
 $buttons=New-Object Windows.Controls.StackPanel
 $buttons.Orientation='Horizontal';$buttons.HorizontalAlignment='Right';$buttons.VerticalAlignment='Center'
 [Windows.Controls.Grid]::SetRow($buttons,4)
 $later=New-Object Windows.Controls.Button
 $later.Content='Later';$later.Width=112;$later.Height=42;$later.Foreground=[Windows.Media.Brushes]::Black;$later.Background=[Windows.Media.Brushes]::LightGray;$later.Padding=New-Object Windows.Thickness(8,4,8,4);$later.Margin=New-Object Windows.Thickness(0,0,12,0)
 $now=New-Object Windows.Controls.Button
 $now.Content=if($isPreview){'Close Preview'}else{'Update Now'};$now.Width=140;$now.Height=42;$now.Foreground=[Windows.Media.Brushes]::Black;$now.Background=[Windows.Media.Brushes]::LightSteelBlue;$now.Padding=New-Object Windows.Thickness(8,4,8,4)
 [void]$buttons.Children.Add($later);[void]$buttons.Children.Add($now);[void]$grid.Children.Add($buttons)
 $w.Content=$grid
 # Mutable reference shared by both event handlers; no script-scope / closure-value mismatch.
 $context=@{busy=$false;last='';finished=$false;runner=$null;started=[datetime]::MinValue;successChecks=0}
 $timer=New-Object Windows.Threading.DispatcherTimer
 $timer.Interval=[TimeSpan]::FromMilliseconds(500)
 $later.Add_Click({
  if(-not $context.busy){$w.Close()}
 }.GetNewClosure())
 $now.Add_Click({
  if($isPreview){$w.Close();return}
  if($context.busy){if($context.finished){$w.Close()};return}
  $context.busy=$true
  $context.started=Get-Date
  $later.IsEnabled=$false;$later.Visibility=[Windows.Visibility]::Collapsed
  $now.IsEnabled=$false;$now.Content='Installing...'
  $w.Add_Closing({if($context.busy -and -not $context.finished){$_.Cancel=$true}}.GetNewClosure())
  $message.Text='Installing '+$version
  $detail.Text='Starting update...';$bar.IsIndeterminate=$true
  if(Test-Path -LiteralPath $progressPath){Remove-Item -LiteralPath $progressPath -Force}
  try {
   $runner=Join-Path $root 'UpdateRunner.ps1'
   if(-not(Test-Path -LiteralPath $runner)){throw 'UpdateRunner.ps1 missing'}
   $params='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$runner+'" -ZipUrl "'+$zipUrl+'" -ManifestUrl "'+$manifestUrl+'" -Tag "'+$version+'"'
   $context.runner=Start-Process -FilePath $ps -ArgumentList $params -PassThru -WindowStyle Hidden
   $timer.Start()
  } catch {
   $bar.IsIndeterminate=$false;$detail.Text=$_.Exception.Message
   $message.Text='Update could not start';$now.IsEnabled=$true;$now.Content='Close';$context.finished=$true
  }
 }.GetNewClosure())
 $timer.Add_Tick({
  if($context.finished){$timer.Stop();return}
  try {
   $data=$null
   if(Test-Path -LiteralPath $progressPath){
    try {$data=Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json} catch {}
   }
   if($data){
    $bar.IsIndeterminate=($data.state -eq 'downloading' -or $data.state -eq 'installing')
    if(-not $bar.IsIndeterminate){$bar.Value=[Math]::Max(0,[Math]::Min(100,[int]$data.percent))}
    $detail.Text=[string]$data.message
   }
   $state=if($data){[string]$data.state}else{''}
   # An update can restart the shell while progress events are in flight. Also
   # confirm installed version and installer status instead of relying on the
   # progress file as the single signal.
   $installedVersion=''
   $installationStatus=''
   try {
    $installedVersion=[string](Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw|ConvertFrom-Json).version
    $installationStatus=[string](Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json).state
   } catch {}
   $versionMatches=($installedVersion -eq ($version -replace '^universal-v',''))
   # Terminal worker event is authoritative. Fallback: the *new* target
   # version and a post-start, successful installer status must agree.
   $confirmed=$false
   if($versionMatches -and $installationStatus -eq 'current'){
    try {
     $statusFile=Get-Item -LiteralPath $statusPath -ErrorAction Stop
     $confirmed=($statusFile.LastWriteTime -ge $context.started)
    }catch{}
   }
   if($confirmed){$context.successChecks++}else{$context.successChecks=0}
   $complete=($state -eq 'success' -or $context.successChecks -ge 4)
   # A stale/late error event must not override confirmed installation.
   $failed=($state -eq 'error' -and -not $complete)
   $runnerExited=$false
   if($context.runner){try {$context.runner.Refresh();$runnerExited=$context.runner.HasExited} catch {}}
   if($complete -or $failed -or ($runnerExited -and ((Get-Date) - $context.started).TotalSeconds -gt 5)){
    $timer.Stop();$context.finished=$true;$bar.IsIndeterminate=$false
    if($complete){
     $bar.Value=100;$message.Text='Update complete'
     $detail.Text='Installed version and Workstation Home update verified.'
    } elseif($failed){
     $message.Text='Update failed';$detail.Text=[string]$data.message
    } else {
     $message.Text='Installer finished - verification needed'
     $detail.Text='Check update-status.json and version.json before confirming success.'
    }
    $now.Content='Close';$now.IsEnabled=$true;$later.Visibility=[Windows.Visibility]::Collapsed
   }
  } catch {
   $detail.Text='Progress monitor error: '+$_.Exception.Message
   if($context.runner){try {$context.runner.Refresh();if($context.runner.HasExited){
    $timer.Stop();$context.finished=$true;$bar.IsIndeterminate=$false
    $message.Text='Installation result needs verification';$now.Content='Close';$now.IsEnabled=$true
   }} catch {}}
  }
 }.GetNewClosure())
 $w.Add_ContentRendered({$w.Topmost=$true;[void]$w.Activate()}.GetNewClosure())
 [void]$w.ShowDialog()
 if(-not $context.busy -and -not $isPreview){
  @{version=$version;until=(Get-Date).AddHours(12).ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $root 'update-deferred.json')
 }
}
if($Preview){Show-Updater 'PREVIEW' '' '' $true;exit}
$mutex=New-Object Threading.Mutex($false,'Local\UniversalDiagnosticWorkstation-UpdateAgent-v1')
if(-not $mutex.WaitOne(0)){exit}
try{
 Start-Sleep -Seconds 10
 while($true){
  try{
   $release=Get-Latest
   if(-not $release){Set-UpdateStatus 'unconfigured' '' 'No universal release published yet'}
   else {
    $version=[string]$release.tag_name
    $installed=[string](Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw | ConvertFrom-Json).version
    if((Rank $version) -le (Rank $installed)){Set-UpdateStatus 'current' $version 'Up to date'}
    else{
     Set-UpdateStatus 'available' $version 'Update available'
     $defer=Join-Path $root 'update-deferred.json';$skip=$false
     if(Test-Path $defer){try{$d=Get-Content $defer -Raw|ConvertFrom-Json;$skip=($d.version -eq $version -and (Get-Date) -lt [datetime]$d.until)}catch{}}
     if(-not $skip){
      $zip=($release.assets|Where-Object name -eq 'workstation.zip'|Select-Object -First 1).browser_download_url
      $manifest=($release.assets|Where-Object name -eq 'update-manifest.json'|Select-Object -First 1).browser_download_url
      Show-Updater $version $zip $manifest $false
     }
    }
   }
  }catch{Set-UpdateStatus 'error' '' $_.Exception.Message}
  Start-Sleep -Seconds 21600
 }
}finally{$mutex.ReleaseMutex();$mutex.Dispose()}
