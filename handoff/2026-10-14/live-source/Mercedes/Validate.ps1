param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference='Stop'
foreach($name in @('Launcher.ps1','Dock.ps1','SystemPanel.ps1','Watchdog.ps1','UpdateAgent.ps1','UpdateRunner.ps1','ApplyUpdate.ps1','Uninstall.ps1')) {
 $f=Join-Path $Root $name
 if(-not(Test-Path -LiteralPath $f)){throw "Missing required runtime file: $name"}
 $t=$null;$e=$null
 [void][System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$t,[ref]$e)
 if(@($e).Count){throw "Syntax error in $name : $($e[0].Message)"}
}
$profile=Get-Content -LiteralPath (Join-Path $Root 'profile.json') -Raw | ConvertFrom-Json
if(-not $profile.id -or -not $profile.displayName){throw 'Invalid brand profile'}
Write-Host 'PASS: Universal workstation script syntax and profile valid.'
