# Captures EXACT finished Mercedes installation files for future master-installer integration.
# Deliberately excludes personal settings, PIN hashes, logs, network data, and app assignments.
param([switch]$ConfirmApproved)
& {
    $ErrorActionPreference='Stop'
    if(-not $ConfirmApproved) {
        throw 'This is a final approval action. Test the controls first, then run: & "$env:LOCALAPPDATA\DiagnosticWorkstation\Save-Approved-Mercedes.ps1" -ConfirmApproved'
    }
    $root=Join-Path $env:LOCALAPPDATA 'DiagnosticWorkstation'
    $profileFile=Join-Path $root 'profile.json'
    if(-not(Test-Path $profileFile)){throw 'No installed workstation profile found.'}
    $profile=Get-Content $profileFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if(([string]$profile.displayName) -notmatch 'Mercedes'){throw 'Current profile is not Mercedes.'}
    foreach($name in @('Launcher.ps1','Dock.ps1','SystemPanel.ps1','WorkstationControls.ps1')) {
        if(-not(Test-Path (Join-Path $root $name))){throw "Missing core file $name"}
    }
    $required= @('Launcher.ps1','Dock.ps1','SystemPanel.ps1','WorkstationControls.ps1','profile.json')
    $optional= @('Restore-ExplorerShell.ps1','Restart-Mercedes-Controls.ps1','Save-Approved-Mercedes.ps1','Watchdog.ps1','UpdateAgent.ps1','UpdateRunner.ps1','ApplyUpdate.ps1','Uninstall.ps1','version.json','WorkstationManager.exe')
    $logoRelative=([string]$profile.logo).Replace('/','\')
    if([string]::IsNullOrWhiteSpace($logoRelative) -or [IO.Path]::IsPathRooted($logoRelative) -or $logoRelative.Contains('..')){
        throw 'Unsafe logo path in profile.'
    }
    $logo=Join-Path $root $logoRelative
    if(-not(Test-Path $logo)){throw "Logo not found: $logo"}
    $documents=[Environment]::GetFolderPath('MyDocuments')
    if(-not $documents){$documents=Join-Path $env:USERPROFILE 'Documents'}
    $out=Join-Path $documents 'DiagnosticWorkstation-ApprovedBuilds'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $stage=Join-Path $env:TEMP ('Mercedes-Approved-'+$stamp)
    $zip=Join-Path $out ('Mercedes-Approved-'+$stamp+'.zip')
    if(Test-Path $stage){throw "Temporary directory already exists: $stage"}
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        $files=@($required+$optional+@($logoRelative)) | Select-Object -Unique
        $copied=New-Object System.Collections.Generic.List[string]
        foreach($relative in $files) {
            $src=Join-Path $root $relative
            if(-not(Test-Path -LiteralPath $src -PathType Leaf)){continue}
            $dst=Join-Path $stage $relative
            $parent=Split-Path -Parent $dst
            if(-not(Test-Path $parent)){New-Item -ItemType Directory -Path $parent -Force | Out-Null}
            Copy-Item -LiteralPath $src -Destination $dst -ErrorAction Stop
            $copied.Add($relative.Replace('\','/'))
        }
        # Capture content fingerprints to lock the approved per-brand source.
        $hashes=@($copied | ForEach-Object {
            $relative=$_
            $full=Join-Path $stage ($relative.Replace('/','\'))
            [pscustomobject]@{file=$relative;sha256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash}
        })
        $manifest=[ordered]@{
            format='DiagnosticWorkstation.BrandSnapshot.v1'
            brand='mercedes'
            displayName=[string]$profile.displayName
            approved=$true
            approvedAt=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            source='Captured from installed Mercedes workstation; verify on target machines before deploying'
            masterIntegration='Not yet wired into current master installer; this ZIP is its future input'
            exclusions=@('controls-pin.json','application tiles/settings','network credentials','logs','update caches','user data')
            files=$hashes
        }
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stage 'approved-brand-manifest.json') -Encoding UTF8
        @'
MERCEDES APPROVED BRAND SNAPSHOT
Exact validated-brand source files captured from the installed workstation.
This is an INPUT ARTIFACT for the future master installer, NOT a standalone installer.
The current master installer will not automatically consume this ZIP until it is updated.
The snapshot excludes PIN hashes, personal configuration, log files and Wi-Fi credentials.
The target installer must generate per-user passcodes during each new installation.
'@ | Set-Content -LiteralPath (Join-Path $stage 'README-APPROVED.txt') -Encoding UTF8
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
        if(-not(Test-Path $zip)){throw 'Snapshot ZIP was not created.'}
        Write-Host "`nPASS: Approved Mercedes source saved." -ForegroundColor Green
        Write-Host $zip
        Write-Host 'Keep this ZIP. It is the source to use when the master installer is updated.'
    } finally {
        if(Test-Path $stage){Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}
    }
}
