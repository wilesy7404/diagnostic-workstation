# Applies one Defender command batch. The parent runs this file as SYSTEM with no window.
# If SYSTEM is denied, the remainder runs once as TrustedInstaller, then this process records the result.
# Windows PowerShell 5.1. Join-Path uses -Path and -ChildPath only.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$CommandFile,
  [Parameter(Mandatory = $true)][string]$ResultFile,
  [switch]$NoTrustedInstallerFallback
)

$ErrorActionPreference = 'Stop'
$script:DefenderJobPath = $MyInvocation.MyCommand.Path
$here = Split-Path -Parent $script:DefenderJobPath
. (Join-Path -Path $here -ChildPath 'Common.ps1')
. (Join-Path -Path $here -ChildPath 'Defender.ps1')

$script:TrustedInstallerSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class DefenderTrustedInstallerProcess
{
    const uint SE_PRIVILEGE_ENABLED = 0x00000002;
    const uint TOKEN_QUERY = 0x0008;
    const uint TOKEN_DUPLICATE = 0x0002;
    const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    const int SecurityImpersonation = 2;
    const int TokenPrimary = 1;
    const uint CREATE_NO_WINDOW = 0x08000000;
    const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    const int STARTF_USESHOWWINDOW = 0x00000001;
    const short SW_HIDE = 0;

    [StructLayout(LayoutKind.Sequential)]
    struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct LUID_AND_ATTRIBUTES
    {
        public LUID Luid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct TOKEN_PRIVILEGES
    {
        public uint PrivilegeCount;
        public LUID_AND_ATTRIBUTES Privileges;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool DuplicateTokenEx(IntPtr hExistingToken, uint dwDesiredAccess, IntPtr lpTokenAttributes, int ImpersonationLevel, int TokenType, out IntPtr phNewToken);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessWithTokenW(IntPtr hToken, uint dwLogonFlags, string lpApplicationName, StringBuilder lpCommandLine, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    public static string Run(int processId, string application, string commandLine, int timeoutMs)
    {
        IntPtr selfToken;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out selfToken))
        {
            return "OpenProcessToken self failed " + Marshal.GetLastWin32Error();
        }
        try
        {
            LUID luid;
            if (!LookupPrivilegeValue(null, "SeDebugPrivilege", out luid))
            {
                return "LookupPrivilegeValue failed " + Marshal.GetLastWin32Error();
            }
            LUID_AND_ATTRIBUTES attributes = new LUID_AND_ATTRIBUTES();
            attributes.Luid = luid;
            attributes.Attributes = SE_PRIVILEGE_ENABLED;
            TOKEN_PRIVILEGES privileges = new TOKEN_PRIVILEGES();
            privileges.PrivilegeCount = 1;
            privileges.Privileges = attributes;
            if (!AdjustTokenPrivileges(selfToken, false, ref privileges, 0, IntPtr.Zero, IntPtr.Zero))
            {
                return "AdjustTokenPrivileges failed " + Marshal.GetLastWin32Error();
            }
            int privilegeError = Marshal.GetLastWin32Error();
            if (privilegeError != 0)
            {
                return "AdjustTokenPrivileges error " + privilegeError;
            }
            IntPtr process = OpenProcess(0x1000, false, processId);
            if (process == IntPtr.Zero)
            {
                process = OpenProcess(0x0400, false, processId);
            }
            if (process == IntPtr.Zero)
            {
                return "OpenProcess failed " + Marshal.GetLastWin32Error();
            }
            try
            {
                IntPtr token;
                if (!OpenProcessToken(process, TOKEN_DUPLICATE | TOKEN_QUERY, out token))
                {
                    return "OpenProcessToken target failed " + Marshal.GetLastWin32Error();
                }
                try
                {
                    IntPtr primary;
                    if (!DuplicateTokenEx(token, 0x02000000, IntPtr.Zero, SecurityImpersonation, TokenPrimary, out primary))
                    {
                        return "DuplicateTokenEx failed " + Marshal.GetLastWin32Error();
                    }
                    try
                    {
                        STARTUPINFO startup = new STARTUPINFO();
                        startup.cb = Marshal.SizeOf(startup);
                        startup.dwFlags = STARTF_USESHOWWINDOW;
                        startup.wShowWindow = SW_HIDE;
                        PROCESS_INFORMATION info;
                        StringBuilder buffer = new StringBuilder(commandLine.Length + 16);
                        buffer.Append(commandLine);
                        uint flags = CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT;
                        if (!CreateProcessWithTokenW(primary, 0, application, buffer, flags, IntPtr.Zero, null, ref startup, out info))
                        {
                            return "CreateProcessWithTokenW failed " + Marshal.GetLastWin32Error();
                        }
                        try
                        {
                            uint waited = WaitForSingleObject(info.hProcess, (uint)timeoutMs);
                            if (waited != 0)
                            {
                                return "WaitForSingleObject " + waited;
                            }
                            uint code;
                            if (!GetExitCodeProcess(info.hProcess, out code))
                            {
                                return "GetExitCodeProcess failed " + Marshal.GetLastWin32Error();
                            }
                            if (code != 0)
                            {
                                return "trusted installer exit " + code;
                            }
                            return null;
                        }
                        finally
                        {
                            if (info.hThread != IntPtr.Zero) { CloseHandle(info.hThread); }
                            if (info.hProcess != IntPtr.Zero) { CloseHandle(info.hProcess); }
                        }
                    }
                    finally
                    {
                        CloseHandle(primary);
                    }
                }
                finally
                {
                    CloseHandle(token);
                }
            }
            finally
            {
                CloseHandle(process);
            }
        }
        finally
        {
            CloseHandle(selfToken);
        }
    }
}
'@

function Write-DefenderJobResult($Result) {
  Write-Utf8NoBom $ResultFile (($Result | ConvertTo-Json -Depth 8) + "`n")
}

function Get-TrustedInstallerProcessId {
  $service = Get-Service -Name 'TrustedInstaller' -ErrorAction Stop
  if ($service.Status -ne 'Running') {
    Start-Service -Name 'TrustedInstaller' -ErrorAction Stop
  }
  $attempt = 0
  while ($attempt -lt 20) {
    $wmi = Get-CimInstance -ClassName Win32_Service -Filter "Name='TrustedInstaller'" -ErrorAction Stop
    $processId = [int]$wmi.ProcessId
    if ($processId -gt 0) { return $processId }
    Start-Sleep -Milliseconds 250
    $attempt++
  }
  throw 'TrustedInstaller process id is not available'
}

function Invoke-JobTrustedInstallerBatch($Remaining) {
  $folder = Split-Path -Parent $CommandFile
  $childCommands = Join-Path -Path $folder -ChildPath 'ti-commands.json'
  $childResult = Join-Path -Path $folder -ChildPath 'ti-result.json'
  if (Test-Path -LiteralPath $childResult) { Remove-Item -LiteralPath $childResult -Force }
  Write-Utf8NoBom $childCommands (([pscustomobject]@{ commands = @($Remaining) } | ConvertTo-Json -Depth 6) + "`n")
  $powershell = Get-MasterWindowsPowerShell
  $commandLine = Format-MasterCommandLine @(
    $powershell,
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', $script:DefenderJobPath,
    '-CommandFile', $childCommands,
    '-ResultFile', $childResult,
    '-NoTrustedInstallerFallback'
  )
  try {
    if (-not ('DefenderTrustedInstallerProcess' -as [type])) {
      Add-Type -TypeDefinition $script:TrustedInstallerSource -Language CSharp
    }
    $processId = Get-TrustedInstallerProcessId
    $launchError = [DefenderTrustedInstallerProcess]::Run($processId, $powershell, $commandLine, 110000)
    if ((Test-Path -LiteralPath $childResult)) {
      $child = Read-JsonFile $childResult
      $applied = @()
      foreach ($item in @($child.applied)) { if ($item) { $applied += $item } }
      return [pscustomobject]@{ ok = [bool]$child.ok; error = $child.error; applied = $applied }
    }
    $detail = 'Access is denied. TrustedInstaller fallback wrote no result.'
    if ($launchError) { $detail = 'Access is denied. TrustedInstaller fallback failed: ' + [string]$launchError }
    return [pscustomobject]@{ ok = $false; error = $detail; applied = @() }
  } catch {
    return [pscustomobject]@{ ok = $false; error = ('Access is denied. TrustedInstaller fallback failed: ' + $_.Exception.Message); applied = @() }
  }
}

$outcome = $null
try {
  $data = Read-JsonFile $CommandFile
  $commands = @($data.commands | Where-Object { $_ })
  if ($NoTrustedInstallerFallback) {
    $ran = Invoke-DefenderCommands $commands $null
    $outcome = [pscustomobject]@{
      ok = [bool]$ran.ok
      error = $ran.error
      applied = @($ran.applied)
      trustedInstaller = $true
    }
  } else {
    $ran = Invoke-DefenderCommandListWithFallback -Commands $commands -Executor {
      param($Command)
      Invoke-DefenderLiveCommand $Command
    } -TrustedInstallerBatch {
      param($Remaining)
      Invoke-JobTrustedInstallerBatch $Remaining
    }
    $outcome = [pscustomobject]@{
      ok = [bool]$ran.ok
      error = $ran.error
      applied = @($ran.applied)
      trustedInstaller = [bool]$ran.trustedInstaller
    }
  }
} catch {
  $outcome = [pscustomobject]@{
    ok = $false
    error = $_.Exception.Message
    applied = @()
    trustedInstaller = [bool]$NoTrustedInstallerFallback
  }
}

Write-DefenderJobResult $outcome
if (-not $outcome.ok) { exit 1 }
exit 0
