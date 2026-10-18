# Parse inline PowerShell from GitHub workflow run blocks.
# shell: powershell is parsed by Windows PowerShell 5.1.
# shell: pwsh is parsed by PowerShell 7.
[CmdletBinding()]
param([string]$ParsePath)

$ErrorActionPreference = 'Stop'

function Test-OneFile([string]$Path) {
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  $problems = @($errors)
  if ($problems.Count -gt 0) {
    foreach ($problem in $problems) {
      Write-Host ("{0}: {1}" -f $Path, [string]$problem.Message)
    }
    return $false
  }
  return $true
}

if (-not [string]::IsNullOrWhiteSpace($ParsePath)) {
  if (-not (Test-OneFile $ParsePath)) { exit 1 }
  exit 0
}

function Get-DedentedText($Lines) {
  $min = [int]::MaxValue
  foreach ($line in @($Lines)) {
    if ($line -match '^\s*$') { continue }
    $count = ([regex]::Match([string]$line, '^\s*')).Length
    if ($count -lt $min) { $min = $count }
  }
  if ($min -eq [int]::MaxValue) { $min = 0 }
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($line in @($Lines)) {
    $text = [string]$line
    if ($text.Length -ge $min) { $out.Add($text.Substring($min)) | Out-Null }
    else { $out.Add($text.TrimStart()) | Out-Null }
  }
  return ($out -join "`r`n")
}

function Get-WorkflowPowerShellRuns([string]$Path) {
  $lines = @(Get-Content -LiteralPath $Path)
  $found = New-Object System.Collections.Generic.List[object]
  $i = 0
  while ($i -lt $lines.Count) {
    $line = [string]$lines[$i]
    if ($line -match '^(\s*)-\s+\S') {
      $stepIndent = $Matches[1].Length
      $name = ''
      if ($line -match 'name:\s*(.+)$') { $name = $Matches[1].Trim().Trim("'").Trim('"') }
      $shell = ''
      $runLines = $null
      $i++
      while ($i -lt $lines.Count) {
        $inner = [string]$lines[$i]
        if ($inner -match '^(\s*)-\s+\S' -and $Matches[1].Length -le $stepIndent) { break }
        if ($inner -match '^\s*shell:\s*[''"]?([^''"#\s]+)') { $shell = $Matches[1] }
        if ($inner -match '^(\s*)run:\s*\|[-+]?\s*$') {
          $runIndent = $Matches[1].Length
          $buf = New-Object System.Collections.Generic.List[string]
          $i++
          while ($i -lt $lines.Count) {
            $body = [string]$lines[$i]
            if ($body -match '^\s*$') {
              $buf.Add('') | Out-Null
              $i++
              continue
            }
            $bodyIndent = ([regex]::Match($body, '^\s*')).Length
            if ($bodyIndent -le $runIndent) { break }
            $buf.Add($body) | Out-Null
            $i++
          }
          $runLines = $buf
          continue
        }
        $i++
      }
      if ($null -ne $runLines -and ($shell -eq 'powershell' -or $shell -eq 'pwsh')) {
        $found.Add([pscustomobject]@{
          File = $Path
          Name = $name
          Shell = $shell
          Text = (Get-DedentedText $runLines)
        }) | Out-Null
      }
      continue
    }
    $i++
  }
  return $found
}

function Invoke-EngineParse([string]$Path, [string]$Shell, [string]$WindowsPowerShell) {
  if ($Shell -eq 'powershell' -and -not [string]::IsNullOrWhiteSpace($WindowsPowerShell)) {
    $parseOutput = & $WindowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ParsePath $Path 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -ne 0) {
      Write-Host $parseOutput
      return $false
    }
    return $true
  }
  $parsed = Test-OneFile $Path
  return $parsed
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$workflowRoot = Join-Path $repoRoot '.github/workflows'
if (-not (Test-Path -LiteralPath $workflowRoot)) { throw "Missing $workflowRoot" }

$windowsPowerShell = $null
if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
  $candidate = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (Test-Path -LiteralPath $candidate) { $windowsPowerShell = $candidate }
}
if ([string]::IsNullOrWhiteSpace($windowsPowerShell) -and $env:OS -eq 'Windows_NT') {
  throw 'Windows PowerShell 5.1 is required to parse shell: powershell steps.'
}
if ([string]::IsNullOrWhiteSpace($windowsPowerShell)) {
  Write-Output 'NOT RUN 5.1 parser: powershell.exe is not installed. shell: powershell steps are parsed with the current engine.'
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('workflow-ps-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
  $badPath = Join-Path $tempRoot 'bad-colon.ps1'
  $badText = @'
Write-Output "NOT RUN $id: broken"
'@
  [System.IO.File]::WriteAllText($badPath, $badText)
  $badParsed = Invoke-EngineParse $badPath 'powershell' $windowsPowerShell
  if ($badParsed) { throw 'parser accepted a double-quoted variable followed by a colon' }

  $runs = New-Object System.Collections.Generic.List[object]
  $workflowFiles = @(Get-ChildItem -LiteralPath $workflowRoot -Filter '*.yml' -File)
  if ($workflowFiles.Count -eq 0) { throw 'no workflow files found' }
  foreach ($file in $workflowFiles) {
    foreach ($run in @(Get-WorkflowPowerShellRuns $file.FullName)) { $runs.Add($run) | Out-Null }
  }
  $powershellCount = @($runs | Where-Object { $_.Shell -eq 'powershell' }).Count
  if ($powershellCount -lt 1) { throw 'no shell: powershell run block was found' }
  $index = 0
  foreach ($run in $runs) {
    $index++
    $out = Join-Path $tempRoot ('run-' + $index.ToString() + '.ps1')
    [System.IO.File]::WriteAllText($out, [string]$run.Text)
    $parsed = Invoke-EngineParse $out ([string]$run.Shell) $windowsPowerShell
    if (-not $parsed) { throw ("workflow PowerShell parse failed: {0} [{1}] {2}" -f $run.Shell, $run.Name, $run.File) }
    Write-Output ("PASS {0} {1} :: {2}" -f $run.Shell, $run.Name, $run.File)
  }
} finally {
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
Write-Output ("PASS workflow PowerShell ({0} blocks)" -f $runs.Count)
exit 0
