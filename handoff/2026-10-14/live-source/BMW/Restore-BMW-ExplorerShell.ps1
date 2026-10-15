# BMW recovery: restores Explorer for THIS Windows user only. No HKLM edits.
& {
  $ErrorActionPreference='Stop'
  $keyPaths=@(
      'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System',
      'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'
  )
  foreach($key in $keyPaths) {
      $existing=[string](Get-ItemProperty -Path $key -Name Shell -ErrorAction SilentlyContinue).Shell
      if($existing -match '(?i)BMW-Stealth-Launcher[\\/](Watchdog|Launcher|BMWWorkstationShell)\.ps1') {
          Remove-ItemProperty -Path $key -Name Shell -ErrorAction Stop
          Write-Host "BMW custom shell entry removed: $key" -ForegroundColor Green
      } elseif($existing -and $existing -notmatch '^\s*(explorer(\.exe)?)?\s*$') {
          Write-Warning "Found another custom shell in $key; left it unchanged: $existing"
      }
  }
  Start-Process -FilePath 'explorer.exe'
  Write-Host 'Windows Explorer requested. Sign out/in if needed.' -ForegroundColor Green
}
