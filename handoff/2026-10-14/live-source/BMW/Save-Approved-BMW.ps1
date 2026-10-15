# Snapshot the ACTUAL installed BMW source after user approval. Does not deploy.
param([switch]$ConfirmApproved)
& {
    $ErrorActionPreference='Stop'
    if(-not $ConfirmApproved){throw 'Test BMW first. Then rerun with -ConfirmApproved.'}
    $root=Join-Path $env:LOCALAPPDATA 'BMW-Stealth-Launcher'
    $required=@('Launcher.ps1','Dock.ps1','SystemPanel.ps1','Watchdog.ps1','BMWWorkstationControls.ps1')
    $optional=@('UpdateAgent.ps1','ApplyUpdate.ps1','UpdateRunner.ps1','Restore-BMW-ExplorerShell.ps1','Restart-BMW-Controls.ps1','Save-Approved-BMW.ps1')
    foreach($name in $required) {if(-not(Test-Path -LiteralPath (Join-Path $root $name))){throw "Required file missing: $name"}}
    $documents=[Environment]::GetFolderPath('MyDocuments')
    if(-not $documents){$documents=Join-Path $env:USERPROFILE 'Documents'}
    $out=Join-Path $documents 'DiagnosticWorkstation-ApprovedBuilds'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $stage=Join-Path $env:TEMP ('BMW-Approved-'+$stamp+'-'+[guid]::NewGuid().ToString('N'))
    $zip=Join-Path $out ('BMW-Approved-'+$stamp+'.zip')
    New-Item -ItemType Directory -Path $stage -ErrorAction Stop | Out-Null
    try {
        $copied=@()
        foreach($name in @($required+$optional | Select-Object -Unique)) {
            $src=Join-Path $root $name
            if(Test-Path -LiteralPath $src -PathType Leaf){Copy-Item $src (Join-Path $stage $name) -ErrorAction Stop; $copied+= $name}
        }
        $hashes=@($copied | ForEach-Object {
            [pscustomobject]@{file=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $stage $_) -Algorithm SHA256).Hash}
        })
        $manifest=[ordered]@{
            format='DiagnosticWorkstation.BrandSnapshot.v1'
            brand='bmw'
            approved=$true
            createdAt=(Get-Date).ToUniversalTime().ToString('o')
            source='Captured from installed BMW-Stealth-Launcher; use as master-installer input only'
            files=$hashes
            excluded=@('controls-pin.json','apps.json','logs','user information','Wi-Fi credentials','registry settings')
        }
        $manifest | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $stage 'approved-brand-manifest.json') -Encoding UTF8
        @'
BMW APPROVED BUILD SNAPSHOT
This is a source snapshot, not a standalone installer. The master installer must be
updated to ingest this format; it does not do so automatically. Excludes personal
PIN, app assignments, logs, Wi-Fi passwords, and user registry configuration.
'@ | Set-Content (Join-Path $stage 'README.txt') -Encoding UTF8
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
        Write-Host "PASS: Approved BMW source snapshot saved: $zip" -ForegroundColor Green
    } finally { if(Test-Path $stage){Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue} }
}
