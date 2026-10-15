# BMW controls rollback. Restores last backed-up SystemPanel.ps1 and Dock.ps1.
param([string]$BackupDir)
& {
    $ErrorActionPreference='Stop'
    $root=Join-Path $env:LOCALAPPDATA 'BMW-Stealth-Launcher'
    if(-not $BackupDir) {
        $latest=Get-ChildItem -LiteralPath $root -Directory -Filter 'BMW-ControlBackup-v1-*' -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if(-not $latest) {throw 'No BMW control backup available.'}
        $BackupDir=$latest.FullName
    }
    foreach($name in @('Dock.ps1','SystemPanel.ps1')) {
        $source=Join-Path $BackupDir $name
        if(-not(Test-Path -LiteralPath $source)){throw "Backup missing $name. No changes made."}
        $tok=$null;$bad=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($source,[ref]$tok,[ref]$bad)
        if(@($bad | Where-Object {$null -ne $_}).Count -ne 0){throw "Invalid backup $name. No changes made."}
    }
    foreach($name in @('Dock.ps1','SystemPanel.ps1')) {
        Copy-Item -LiteralPath (Join-Path $BackupDir $name) -Destination (Join-Path $root $name) -Force -ErrorAction Stop
    }
    Write-Host "PASS: BMW dock/system menus restored from $BackupDir" -ForegroundColor Green
    Write-Host 'Control helper files and your PIN remain available; they no longer appear in the menus.'
    Write-Host 'Run Restart-BMW-Controls.ps1 to reload the original BMW menus.'
}
