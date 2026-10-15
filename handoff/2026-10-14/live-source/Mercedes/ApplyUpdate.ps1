# Replaces the Mercedes install from a verified package and restores it if Home or the dock does not return.
# Windows PowerShell 5.1. apps.json, controls-pin.json, profile apps, and the wallpaper are left alone.
param(
  [string]$PackageDirectory,
  [string]$ManifestPath,
  [string]$Tag
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = $PSScriptRoot
$savedLibrary = $env:MERCEDES_UPDATER_LIBRARY
$env:MERCEDES_UPDATER_LIBRARY = '1'
. (Join-Path $root 'UpdateAgent.ps1')
if ([string]::IsNullOrEmpty($savedLibrary)) {
  Remove-Item Env:\MERCEDES_UPDATER_LIBRARY -ErrorAction SilentlyContinue
} else {
  $env:MERCEDES_UPDATER_LIBRARY = $savedLibrary
}

$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$status = Join-Path $root 'update-status.json'
$log = Join-Path $root 'update-install.log'
$installMarker = Join-Path $root 'install-in-progress.lock'
$script:DockTitle = 'Workstation Glass Dock'

function Write-InstallLog([string]$line) {
  Add-Content -LiteralPath $log -Value ('{0} {1}' -f (Get-Date).ToString('s'), $line) -Encoding UTF8
}

function Set-InstallStatus([string]$state, [string]$message) {
  Set-UpdateStatus $state '' $message
}

function Read-HomeTitle {
  $profilePath = Join-Path $root 'profile.json'
  if (-not (Test-Path -LiteralPath $profilePath)) { return 'Mercedes-Benz Diagnostic System' }
  $profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
  $name = [string]$profile.displayName
  if ([string]::IsNullOrWhiteSpace($name)) { return 'Mercedes-Benz Diagnostic System' }
  return ($name + ' Diagnostic System')
}

function Get-WorkstationProcess([string]$kind) {
  $marker = 'DiagnosticWorkstation\' + $kind + '.ps1'
  try {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop | Where-Object {
      $_.CommandLine -and ($_.CommandLine.Replace('/', '\') -match [regex]::Escape($marker)) -and $_.ProcessId -ne $PID
    })
  } catch {
    return @()
  }
}

function Stop-WorkstationUi {
  foreach ($kind in @('Launcher', 'Dock', 'Watchdog', 'SystemPanel')) {
    foreach ($proc in @(Get-WorkstationProcess $kind)) {
      Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
}

function Stop-WorkstationManager {
  Get-Process -Name 'WorkstationManager' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Test-ManagerNeedsReplacement([string]$packageDirectory, $manifest) {
  foreach ($entry in @($manifest.files)) {
    $relative = Get-SafeRelativePath ([string]$entry.path)
    if ([System.IO.Path]::GetFileName($relative) -ne 'WorkstationManager.exe') { continue }
    $dest = Join-RelativePath $root $relative
    $source = Join-RelativePath $packageDirectory $relative
    if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { return $true }
    $left = Get-FileHash -LiteralPath $dest -Algorithm SHA256
    $right = Get-FileHash -LiteralPath $source -Algorithm SHA256
    if ($left.Hash -ne $right.Hash) { return $true }
  }
  return $false
}

function Write-BackupMap([string]$backupRoot, $records) {
  $chunks = New-Object System.Collections.ArrayList
  foreach ($rec in $records) {
    $flag = 'added'
    if ($rec.existed) { $flag = 'existed' }
    [void]$chunks.Add($flag + "`t" + [string]$rec.path)
  }
  $text = ''
  if ($chunks.Count -gt 0) { $text = ($chunks -join "`n") + "`n" }
  Write-Utf8File (Join-Path $backupRoot 'backup-map.txt') $text
}

function Backup-ReplacedFiles([string]$backupRoot, $manifest) {
  New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
  $records = New-Object System.Collections.ArrayList
  foreach ($entry in @($manifest.files)) {
    $relative = Get-SafeRelativePath ([string]$entry.path)
    if (Test-PreservedRelativePath $relative) { continue }
    $dest = Join-RelativePath $root $relative
    $existed = Test-Path -LiteralPath $dest -PathType Leaf
    if ($existed) {
      $backupFile = Join-RelativePath $backupRoot $relative
      $parent = Split-Path -Parent $backupFile
      if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
      Copy-Item -LiteralPath $dest -Destination $backupFile -Force
    }
    [void]$records.Add([pscustomobject]@{ path = $relative; existed = [bool]$existed })
  }
  Write-BackupMap $backupRoot $records
}

function Test-SameFileHash([string]$leftPath, [string]$rightPath) {
  if (-not (Test-Path -LiteralPath $leftPath -PathType Leaf)) { return $false }
  if (-not (Test-Path -LiteralPath $rightPath -PathType Leaf)) { return $false }
  $left = Get-FileHash -LiteralPath $leftPath -Algorithm SHA256
  $right = Get-FileHash -LiteralPath $rightPath -Algorithm SHA256
  return ($left.Hash -eq $right.Hash)
}

function Stop-ManagerForExeReplace([string]$relative) {
  if ([System.IO.Path]::GetFileName($relative) -ne 'WorkstationManager.exe') { return }
  $running = @(Get-Process -Name 'WorkstationManager' -ErrorAction SilentlyContinue)
  if ($running.Count -eq 0) { return }
  # A running manager is stopped only when the backup bytes differ.
  Stop-WorkstationManager
  Start-Sleep -Seconds 1
}

function Restore-InstallBackup([string]$backupRoot) {
  $map = Join-Path $backupRoot 'backup-map.txt'
  if (-not (Test-Path -LiteralPath $map)) { throw 'Backup map missing' }
  $errors = New-Object System.Collections.ArrayList
  foreach ($line in [System.IO.File]::ReadAllLines($map)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $relative = ''
    try {
      $tab = $line.IndexOf("`t")
      if ($tab -lt 1) { throw 'Backup map is unreadable' }
      $flag = $line.Substring(0, $tab)
      $relative = Get-SafeRelativePath $line.Substring($tab + 1)
      if (Test-PreservedRelativePath $relative) { continue }
      $dest = Join-RelativePath $root $relative
      if ($flag -eq 'existed') {
        $source = Join-RelativePath $backupRoot $relative
        if (Test-SameFileHash $dest $source) { continue }
        Stop-ManagerForExeReplace $relative
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $source -Destination $dest -Force
      } elseif ($flag -eq 'added') {
        if (Test-Path -LiteralPath $dest) {
          Stop-ManagerForExeReplace $relative
          Remove-Item -LiteralPath $dest -Force
        }
      } else {
        throw "Unknown backup flag $flag"
      }
    } catch {
      $detail = $relative
      if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $line.Trim() }
      $message = $detail + ': ' + $_.Exception.Message
      [void]$errors.Add($message)
      Write-InstallLog ('Restore error: ' + $message)
    }
  }
  foreach ($item in $errors) { Write-Output $item }
}

function Copy-PackageFiles([string]$packageDirectory, $manifest) {
  foreach ($entry in @($manifest.files)) {
    $relative = Get-SafeRelativePath ([string]$entry.path)
    if (Test-PreservedRelativePath $relative) { continue }
    $source = Join-RelativePath $packageDirectory $relative
    $dest = Join-RelativePath $root $relative
    if ((Test-Path -LiteralPath $dest -PathType Leaf)) {
      $left = Get-FileHash -LiteralPath $dest -Algorithm SHA256
      $right = Get-FileHash -LiteralPath $source -Algorithm SHA256
      if ($left.Hash -eq $right.Hash) { continue }
    }
    $parent = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if ([System.IO.Path]::GetFileName($relative) -eq 'profile.json') {
      Copy-ProfilePreservingApps $source $dest
    } else {
      Copy-Item -LiteralPath $source -Destination $dest -Force
    }
  }
}

function Start-HiddenScript([string]$file) {
  if (-not (Test-Path -LiteralPath $file)) { throw "Missing $file" }
  $arg = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $file + '"'
  Start-Process -FilePath $psExe -ArgumentList $arg -WindowStyle Hidden | Out-Null
}

function Start-WorkstationUi {
  # Rollback and the supervisor fallback both come through here, and both windows are started.
  foreach ($name in @('Launcher', 'Dock')) {
    if (@(Get-WorkstationProcess $name).Count -eq 0) {
      Start-HiddenScript (Join-Path $root ($name + '.ps1'))
    }
  }
}

function Start-SupervisorWhileLocked {
  $exe = Join-Path $root 'WorkstationManager.exe'
  if (-not (Test-Path -LiteralPath $exe)) { return }
  $running = @(Get-Process -Name 'WorkstationManager' -ErrorAction SilentlyContinue)
  if ($running.Count -gt 0) { return }
  Start-Process -FilePath $exe -ArgumentList '/supervise' -WorkingDirectory $root -WindowStyle Hidden | Out-Null
}

function Get-ProcessWindowTitles([int]$processId) {
  # Optional confirmation. Failure leaves readiness on the command-line check.
  try {
    if (-not ('MercedesUpdateWindowEnum' -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class MercedesUpdateWindowEnum {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  public static string[] TitlesForProcess(int processId) {
    List<string> found = new List<string>();
    uint want = (uint)processId;
    EnumProc proc = delegate(IntPtr hWnd, IntPtr lParam) {
      uint windowPid;
      GetWindowThreadProcessId(hWnd, out windowPid);
      if (windowPid != want) return true;
      int len = GetWindowTextLength(hWnd);
      if (len <= 0) return true;
      StringBuilder sb = new StringBuilder(len + 1);
      GetWindowText(hWnd, sb, sb.Capacity);
      string title = sb.ToString();
      if (!string.IsNullOrEmpty(title)) found.Add(title);
      return true;
    };
    EnumWindows(proc, IntPtr.Zero);
    return found.ToArray();
  }
}
'@ -ErrorAction Stop
    }
    return @([MercedesUpdateWindowEnum]::TitlesForProcess($processId))
  } catch {
    return @()
  }
}

function Test-WindowReady([string]$kind, [string]$title) {
  # The dock is a tool window, so the process main-window handle stays 0.
  # Readiness is the script process. EnumWindows can confirm the title, and a missing title does not fail.
  $alive = $false
  foreach ($proc in @(Get-WorkstationProcess $kind)) {
    $alive = $true
    foreach ($seen in @(Get-ProcessWindowTitles ([int]$proc.ProcessId))) {
      if ($seen -eq $title) { return $true }
    }
  }
  return $alive
}

function Wait-ForLauncherAndDock([int]$seconds, [string]$homeTitle) {
  $until = (Get-Date).AddSeconds($seconds)
  do {
    if ((Test-WindowReady 'Launcher' $homeTitle) -and (Test-WindowReady 'Dock' $script:DockTitle)) { return $true }
    Start-Sleep -Seconds 1
  } while ((Get-Date) -lt $until)
  return $false
}

function Resume-LauncherAndDock([string]$homeTitle) {
  # The manager waits while the lock exists, then starts Home and the dock.
  # If it does not, start both scripts directly.
  Start-SupervisorWhileLocked
  if (Test-Path -LiteralPath $installMarker) { Remove-Item -LiteralPath $installMarker -Force -ErrorAction SilentlyContinue }
  if (Wait-ForLauncherAndDock 20 $homeTitle) { return }
  Start-WorkstationUi
  if (-not (Wait-ForLauncherAndDock 30 $homeTitle)) { throw 'Launcher and Dock did not both restart' }
}

function Invoke-MercedesApply([string]$PackageDirectory, [string]$ManifestPath, [string]$Tag) {
  if ([string]::IsNullOrWhiteSpace($PackageDirectory) -or [string]::IsNullOrWhiteSpace($ManifestPath) -or [string]::IsNullOrWhiteSpace($Tag)) {
    throw 'PackageDirectory, ManifestPath, and Tag are required'
  }
  $settings = Resolve-MercedesUpdateSettings $root
  if (-not $settings.mercedesTags) { throw 'Mercedes updates require the mercedes-v prefix' }
  if ($Tag -notmatch $settings.pattern) { throw 'Invalid release version' }
  $manifest = Test-ManifestPackage $PackageDirectory $ManifestPath
  Assert-RequiredPackageFiles $manifest
  Assert-ManifestIdentity $manifest $Tag $settings.tagPrefix
  $bare = Get-BareVersion $Tag $settings.tagPrefix
  $packageVersion = [string](Get-Content -LiteralPath (Join-RelativePath $PackageDirectory 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
  if ($packageVersion -ne $bare) { throw 'Package version mismatch' }
  foreach ($entry in @($manifest.files)) {
    $relative = Get-SafeRelativePath ([string]$entry.path)
    if ($relative -notlike '*.ps1') { continue }
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-RelativePath $PackageDirectory $relative), [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "Invalid script $relative" }
  }
  $homeTitle = Read-HomeTitle
  $backup = Join-Path $root ('Backup-Update-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  $changesStarted = $false
  try {
    Backup-ReplacedFiles $backup $manifest
    Write-InstallLog "Backed up to $backup"
    $changesStarted = $true
    Set-Content -LiteralPath $installMarker -Value (Get-Date).ToString('o') -Encoding ASCII
    $replaceManager = Test-ManagerNeedsReplacement $PackageDirectory $manifest
    if ($replaceManager) { Stop-WorkstationManager }
    Stop-WorkstationUi
    Start-Sleep -Seconds 2
    Copy-PackageFiles $PackageDirectory $manifest
    Resume-LauncherAndDock $homeTitle
    Write-InstallLog 'Update installed; Home and dock are responding'
    Set-InstallStatus 'current' 'Up to date'
  } catch {
    $reason = $_.Exception.Message
    Write-InstallLog "Update failure: $reason"
    if (-not $changesStarted) {
      Set-InstallStatus 'error' 'Update rejected before changing live files'
      exit 1
    }
    try {
      if (-not (Test-Path -LiteralPath $installMarker)) {
        Set-Content -LiteralPath $installMarker -Value (Get-Date).ToString('o') -Encoding ASCII
      }
      Stop-WorkstationUi
      $restoreErrors = @(Restore-InstallBackup $backup)
      # Restored files are on disk. Bring Home and the dock back before reporting failure.
      Resume-LauncherAndDock $homeTitle
      if ($restoreErrors.Count -gt 0) {
        Write-InstallLog ('Recovery incomplete: ' + ($restoreErrors -join ' | '))
        Set-InstallStatus 'error' 'Recovery needs attention'
        exit 1
      }
      Write-InstallLog 'Rollback complete; Home and dock are responding'
      Set-InstallStatus 'error' 'Update rolled back'
    } catch {
      Write-InstallLog ('Recovery failed: ' + $_.Exception.Message)
      Set-InstallStatus 'error' 'Recovery needs attention'
      exit 1
    }
    exit 1
  } finally {
    if (Test-Path -LiteralPath $installMarker) { Remove-Item -LiteralPath $installMarker -Force -ErrorAction SilentlyContinue }
  }
}

if ($env:MERCEDES_UPDATER_LIBRARY -ne '1') {
  Invoke-MercedesApply -PackageDirectory $PackageDirectory -ManifestPath $ManifestPath -Tag $Tag
}
