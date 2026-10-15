param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'

try {
    $root = Split-Path -Parent $PSCommandPath
    $launcher = Join-Path $root 'Launcher.ps1'
    $dock = Join-Path $root 'Dock.ps1'
    $manager = Join-Path $root 'WorkstationManager.exe'
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $logDir = Join-Path $root 'logs'
    $log = Join-Path $logDir 'ShellHost.log'

    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    function Log-Message([string]$message) {
        "$(Get-Date -Format s) $message" |
            Out-File -LiteralPath $log -Append -Encoding UTF8
    }

    $profile = Get-Content (Join-Path $root 'profile.json') -Raw |
        ConvertFrom-Json

    $homeTitle = ([string]$profile.displayName) + ' Diagnostic System'
    $dockTitle = 'Workstation Glass Dock'

    foreach ($file in @($launcher, $dock)) {
        if (-not (Test-Path $file)) {
            throw "Missing script: $file"
        }

        $tokens = $null
        $errorsFound = $null

        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $file, [ref]$tokens, [ref]$errorsFound
        )

        if (@($errorsFound).Count -gt 0) {
            throw "Invalid script: $file"
        }
    }

    $logo = Join-Path $root ([string]$profile.logo)
    if (-not (Test-Path -LiteralPath $logo)) {
        throw "Missing logo: $logo"
    }

    Add-Type -TypeDefinition '
using System;
using System.Runtime.InteropServices;
public static class MercedesShellNative {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hwnd);
}'

    function Test-Window([string]$title) {
        $handle = [MercedesShellNative]::FindWindow($null, $title)
        return ($handle -ne [IntPtr]::Zero -and
                [MercedesShellNative]::IsWindowVisible($handle))
    }

    if ($SelfTest) {
        if (-not (Test-Window $homeTitle)) {
            throw "Mercedes Home is not visible: $homeTitle"
        }
        if (-not (Test-Window $dockTitle)) {
            throw 'Mercedes dock is not visible.'
        }

        Write-Host 'PASS: Home, dock, and scripts verified.'
        exit 0
    }

    Log-Message 'Mercedes custom shell starting.'

    # Use the existing workstation manager when available
    if (Test-Path $manager) {
        $managerRunning = Get-Process WorkstationManager -ErrorAction SilentlyContinue
        if (-not $managerRunning) {
            Start-Process -FilePath $manager
            Log-Message 'Workstation manager started.'
        }
    }

    function Ensure-Workstation {
        $processes = @(
            Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"
        )

        foreach ($item in @(
            @{ Name='Launcher'; Path=$launcher },
            @{ Name='Dock'; Path=$dock }
        )) {
            $found = @($processes | Where-Object {
                $_.CommandLine -like "*$($item.Path)*"
            })

            if ($found.Count -eq 0) {
                Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
                    '-NoProfile',
                    '-STA',
                    '-ExecutionPolicy', 'Bypass',
                    "-File `"$($item.Path)`""
                )
                Log-Message "$($item.Name) started."
            }
        }
    }

    $deadline = (Get-Date).AddSeconds(90)
    $ready = $false
    $lastHealthy = Get-Date

    while ($true) {
        Ensure-Workstation

        $homeVisible = Test-Window $homeTitle
        $dockVisible = Test-Window $dockTitle

        if ($homeVisible -and $dockVisible) {
            if (-not $ready) {
                Log-Message 'Home and dock confirmed visible.'
            }
            $ready = $true
            $lastHealthy = Get-Date
        }
        elseif (-not $ready -and (Get-Date) -gt $deadline) {
            throw 'Workstation failed its initial 90-second startup check.'
        }
        elseif ($ready -and ((Get-Date) - $lastHealthy).TotalSeconds -gt 90) {
            throw 'Workstation remained unhealthy for 90 seconds.'
        }

        Start-Sleep -Seconds 4
    }
}
catch {
    $message = $_.Exception.Message

    if ($SelfTest) {
        Write-Error $message
        exit 1
    }

    try {
        $root = Join-Path $env:LOCALAPPDATA 'DiagnosticWorkstation'
        $log = Join-Path $root 'logs\ShellHost.log'
        "$(Get-Date -Format s) RECOVERY: $message" |
            Out-File -LiteralPath $log -Append -Encoding UTF8

        & (Join-Path $root 'Restore-ExplorerShell.ps1')
    }
    catch {
        Start-Process explorer.exe
    }
}