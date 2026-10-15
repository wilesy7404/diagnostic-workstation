# Emergency recovery: run from Task Manager > Run new task.
# Remove ONLY workstation-owned per-user shell overrides; never change HKLM.
$ErrorActionPreference = 'Stop'
foreach ($key in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System',
    'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'
)) {
    $current = [string](Get-ItemProperty -Path $key -Name 'Shell' -ErrorAction SilentlyContinue).Shell
    if ($current -match '(?i)DiagnosticWorkstation[\\/](WorkstationShell|Watchdog|Launcher)\.ps1') {
        Remove-ItemProperty -Path $key -Name 'Shell' -ErrorAction Stop
        Write-Host "Removed workstation shell override: $key"
    }
}
Start-Process 'explorer.exe'
Write-Host 'Explorer requested. Sign out and back in if the Windows desktop does not appear immediately.'
