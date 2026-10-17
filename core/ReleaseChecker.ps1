# Diagnostic Workstation public GitHub release checker
# Windows PowerShell 5.1 | check only, no code execution or installation.
# The master installer does not use this generic ^v? filter. Approved tags are mercedes-v* and bmw-v*.
# universal-v* and bare v* tags are retired.
param(
 [ValidateSet('stable','beta')][string]$Channel='beta',
 [string]$Repo='wilesy7404/diagnostic-workstation',
 [string]$InstalledVersion='0.0.0'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$uri="https://api.github.com/repos/$Repo/releases?per_page=30"
$headers=@{'User-Agent'='DiagnosticWorkstation-Updater/1.0';'Accept'='application/vnd.github+json'}
try {
 $releases=@(Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15)
 $chosen=$releases | Where-Object {
   -not $_.draft -and ($Channel -eq 'beta' -or -not $_.prerelease) -and
   $_.tag_name -match '^v?[0-9]+\.[0-9]+\.[0-9]+' -and
   @($_.assets | Where-Object { $_.name -eq 'workstation.zip' }).Count -ge 1
 } | Sort-Object -Property @{Expression={
     try { [version](($_.tag_name -replace '^v','') -split '-')[0] } catch { [version]'0.0.0' }
   };Descending=$true} | Select-Object -First 1
 if(-not $chosen) {
   [pscustomobject]@{status='no_release';channel=$Channel;installed=$InstalledVersion;available=$null;releaseUrl=$null}
   exit 0
 }
 $latest=[version](($chosen.tag_name -replace '^v','') -split '-')[0]
 $installed=[version](($InstalledVersion -replace '^v','') -split '-')[0]
 $status=if($latest -gt $installed){'update_available'}else{'up_to_date'}
 [pscustomobject]@{status=$status;channel=$Channel;installed=$InstalledVersion;available=$chosen.tag_name;releaseUrl=$chosen.html_url}
} catch {
 [pscustomobject]@{status='check_failed';channel=$Channel;installed=$InstalledVersion;available=$null;error=$_.Exception.Message}
 exit 1
}
