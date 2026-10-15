# Mercedes update check. Windows PowerShell 5.1.
# Reads tagPrefix from update-settings.json. Seeds that file only when it is missing.
# The stock universal-v prefix is rewritten to mercedes-v; other prefixes are kept and ignored.
param([switch]$Preview)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = $PSScriptRoot
$statusPath = Join-Path $root 'update-status.json'
$progressPath = Join-Path $root 'update-progress.json'
$script:MercedesTagPrefix = 'mercedes-v'
$script:SettingsSeed = @'
{
  "channel": "beta",
  "source": "public-github-releases",
  "repo": "wilesy7404/diagnostic-workstation",
  "brand": "mercedes",
  "tagPrefix": "mercedes-v"
}
'@
$script:RequiredPackageFiles = @(
  'Launcher.ps1','Dock.ps1','SystemPanel.ps1','Watchdog.ps1','WorkstationControls.ps1',
  'WorkstationShell.ps1','WorkstationManager.exe','version.json','UpdateAgent.ps1',
  'UpdateRunner.ps1','ApplyUpdate.ps1','Validate.ps1','Create-Shortcuts.ps1',
  'Remove-Legacy-Mercedes.ps1','branding/mercedes.png'
)

function Write-Utf8File([string]$path, [string]$text) {
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($path, $text, $utf8)
}

function Set-UpdateStatus([string]$state, [string]$latest, [string]$message) {
  $payload = @{ checked = (Get-Date).ToString('s'); state = $state; latest = $latest; message = $message }
  Write-Utf8File $statusPath ($payload | ConvertTo-Json -Compress)
}

function Get-TagPattern([string]$prefix) {
  if ($prefix -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,40}$') { throw 'Invalid tag prefix' }
  return ('^' + [regex]::Escape($prefix) + '\d+\.\d+\.\d+(-beta\.\d+)?$')
}

function Get-BareVersion([string]$tag, [string]$prefix) {
  $value = [string]$tag
  if ($prefix -and $value.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
    $value = $value.Substring($prefix.Length)
  }
  if ($value -match '^v\d') { $value = $value.Substring(1) }
  return $value
}

function Get-VersionRank([string]$value, [string]$prefix) {
  $bare = Get-BareVersion $value $prefix
  if ($bare -match '^(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?$') {
    $revision = 999999
    if ($Matches[4]) { $revision = [int]$Matches[4] }
    return [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], $revision)
  }
  return [version]::new(0, 0, 0, 0)
}

function Test-OfflineError($errorRecord) {
  $pending = New-Object System.Collections.Queue
  if ($errorRecord -is [System.Management.Automation.ErrorRecord]) {
    if ($errorRecord.Exception) { $pending.Enqueue($errorRecord.Exception) }
  } elseif ($errorRecord -is [System.Exception]) {
    $pending.Enqueue($errorRecord)
  }
  $seen = 0
  while ($pending.Count -gt 0 -and $seen -lt 8) {
    $ex = $pending.Dequeue()
    $seen++
    if (-not $ex) { continue }
    $typeName = $ex.GetType().FullName
    if ($typeName -eq 'System.Net.WebException' -or $typeName -eq 'System.Net.Sockets.SocketException' -or $typeName -eq 'System.Net.Http.HttpRequestException') { return $true }
    $message = [string]$ex.Message
    if ($message -match '(?i)timed out|timeout|name resolution|could not be resolved|unable to connect|no such host|network is unreachable|network path|temporarily unavailable|connection refused|\bdns\b') { return $true }
    if ($ex.InnerException) { $pending.Enqueue($ex.InnerException) }
  }
  return $false
}

function Resolve-MercedesUpdateSettings([string]$directory) {
  $path = Join-Path $directory 'update-settings.json'
  if (-not (Test-Path -LiteralPath $path)) {
    Write-Utf8File $path ($script:SettingsSeed.Trim() + "`n")
  }
  $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
  $prefix = [string]$config.tagPrefix
  # The installed stock file says universal-v, so the check never finds a Mercedes release.
  # Correct that one value. Leave channel and repo alone, and do not rewrite a file that is already mercedes-v.
  if ([string]::IsNullOrWhiteSpace($prefix) -or $prefix -eq 'universal-v') {
    if (-not ($config.PSObject.Properties.Name -contains 'tagPrefix')) {
      $config | Add-Member -NotePropertyName tagPrefix -NotePropertyValue $script:MercedesTagPrefix
    } else {
      $config.tagPrefix = $script:MercedesTagPrefix
    }
    Write-Utf8File $path (($config | ConvertTo-Json -Depth 6).Trim() + "`n")
    $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $prefix = [string]$config.tagPrefix
  }
  $repo = [string]$config.repo
  if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid repository setting' }
  $pattern = $null
  $mercedesTags = ($prefix -eq $script:MercedesTagPrefix)
  if ($mercedesTags) { $pattern = Get-TagPattern $prefix }
  return [pscustomobject]@{
    path = $path
    channel = [string]$config.channel
    repo = $repo
    tagPrefix = $prefix
    pattern = $pattern
    mercedesTags = $mercedesTags
  }
}

function Get-SafeRelativePath([string]$path) {
  $relative = ([string]$path).Replace('\', '/').Trim()
  if ([string]::IsNullOrWhiteSpace($relative)) { throw 'Empty manifest path' }
  if ($relative.StartsWith('/') -or $relative -match '(?i)^[a-z]:') { throw "Unsafe path $relative" }
  $parts = $relative.Split('/')
  foreach ($part in $parts) {
    if ($part -eq '' -or $part -eq '.' -or $part -eq '..') { throw "Unsafe path $relative" }
    if ($part -match '[<>:"|?*]') { throw "Unsafe path $relative" }
  }
  return ($parts -join '/')
}

function Join-RelativePath([string]$base, [string]$relative) {
  $path = $base
  foreach ($part in (Get-SafeRelativePath $relative).Split('/')) {
    $path = Join-Path $path $part
  }
  return $path
}

function Test-PreservedRelativePath([string]$relative) {
  $name = [System.IO.Path]::GetFileName((Get-SafeRelativePath $relative))
  if ($name -eq 'apps.json' -or $name -eq 'controls-pin.json') { return $true }
  if ($name -match '(?i)wallpaper') { return $true }
  return $false
}

function Copy-ProfilePreservingApps([string]$incoming, [string]$destination) {
  if (Test-Path -LiteralPath $destination) {
    $raw = [System.IO.File]::ReadAllText($destination)
    if ($raw -match '(?i)"apps"\s*:') { return }
  }
  $parent = Split-Path -Parent $destination
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  Copy-Item -LiteralPath $incoming -Destination $destination -Force
}

function Test-ManifestPackage([string]$packageDirectory, [string]$manifestPath) {
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'update-manifest.json missing' }
  if (-not (Test-Path -LiteralPath $packageDirectory -PathType Container)) { throw 'Update package missing' }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $manifest.files) { throw 'Manifest has no files' }
  $seen = @{}
  foreach ($entry in @($manifest.files)) {
    $relative = Get-SafeRelativePath ([string]$entry.path)
    if ($seen.ContainsKey($relative)) { throw "Duplicate manifest path $relative" }
    $seen[$relative] = $true
    if ($null -eq $entry.sha256 -or $null -eq $entry.bytes) { throw "Manifest entry incomplete: $relative" }
    $full = Join-RelativePath $packageDirectory $relative
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Missing $relative" }
    $item = Get-Item -LiteralPath $full
    if ([int64]$item.Length -ne [int64]$entry.bytes) { throw "Size mismatch $relative" }
    $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = ([string]$entry.sha256).ToLowerInvariant()
    if ($hash -ne $expected) { throw "Checksum mismatch $relative" }
  }
  return $manifest
}

function Assert-RequiredPackageFiles($manifest) {
  $have = @{}
  foreach ($entry in @($manifest.files)) {
    $have[(Get-SafeRelativePath ([string]$entry.path))] = $true
  }
  foreach ($relative in $script:RequiredPackageFiles) {
    if (-not $have.ContainsKey($relative)) { throw "Release missing $relative" }
  }
}

function Assert-ManifestIdentity($manifest, [string]$tag, [string]$prefix) {
  $bare = Get-BareVersion $tag $prefix
  if ([string]$manifest.version -ne $bare) { throw 'Release manifest version mismatch' }
  if ($manifest.tag -and [string]$manifest.tag -ne $tag) { throw 'Release manifest tag mismatch' }
  if ($manifest.brand -and [string]$manifest.brand -ne 'mercedes') { throw 'Release manifest brand mismatch' }
  if ($manifest.asset -and [string]$manifest.asset -ne 'workstation.zip') { throw 'Release manifest asset mismatch' }
}

function Test-GithubReleaseUrl([string]$url, [string]$repo, [string]$tag, [string]$assetName) {
  if ($url -match '[\s@]|\\|(\.\.)') { throw 'Unexpected download URL' }
  $clean = $url
  $query = $clean.IndexOf('?')
  if ($query -ge 0) { $clean = $clean.Substring(0, $query) }
  $expected = "https://github.com/$repo/releases/download/$tag/$assetName"
  if (-not $clean.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected download URL' }
}

function Get-LatestRelease($settings) {
  $uri = 'https://api.github.com/repos/{0}/releases?per_page=25' -f $settings.repo
  $response = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'MercedesWorkstation-Updater' } -TimeoutSec 20
  $candidates = @(foreach ($rel in @($response)) {
    if (-not $rel) { continue }
    $names = @($rel.assets | ForEach-Object { [string]$_.name })
    $tagOk = [string]$rel.tag_name -match $settings.pattern
    $assetsOk = ($names -contains 'workstation.zip') -and ($names -contains 'update-manifest.json')
    $channelOk = ($settings.channel -eq 'beta') -or (-not $rel.prerelease)
    if ((-not $rel.draft) -and $tagOk -and $assetsOk -and $channelOk) { $rel }
  })
  $sorted = @($candidates | Sort-Object -Property @{ Expression = { Get-VersionRank ([string]$_.tag_name) $settings.tagPrefix }; Descending = $true })
  if ($sorted.Count -gt 0) { return $sorted[0] }
  return $null
}

function Add-UpdaterAssemblies {
  Add-Type -AssemblyName PresentationFramework
  Add-Type -AssemblyName PresentationCore
}

function New-UpdaterBrush([string]$hex) {
  $color = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
  $brush = New-Object System.Windows.Media.SolidColorBrush $color
  $brush.Freeze()
  return $brush
}

function Set-DarkButton($button, [string]$fill, [string]$foreground) {
  $button.Background = New-UpdaterBrush $fill
  $button.Foreground = New-UpdaterBrush $foreground
  $button.BorderBrush = New-UpdaterBrush '#C0C6CE'
  $button.BorderThickness = New-Object System.Windows.Thickness 1
  $button.FontFamily = 'Segoe UI'
  $button.FontSize = 13
  $button.Cursor = [System.Windows.Input.Cursors]::Hand
  $template = @'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
  <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="2" Padding="{TemplateBinding Padding}">
    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" TextElement.Foreground="{TemplateBinding Foreground}"/>
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
    <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.45"/></Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
'@
  $button.Template = [System.Windows.Markup.XamlReader]::Parse($template)
}

function Show-Updater([string]$Tag, [string]$BareVersion, [string]$ZipUrl, [string]$ManifestUrl, [string]$Prefix, [bool]$IsPreview) {
  Add-UpdaterAssemblies
  $background = New-UpdaterBrush '#0C121C'
  $silver = New-UpdaterBrush '#C0C6CE'
  $body = New-UpdaterBrush '#D0D5DB'
  $muted = New-UpdaterBrush '#8E98A3'
  $w = New-Object System.Windows.Window
  $w.Title = 'Mercedes-Benz Update'
  $w.Width = 520
  $w.Height = 340
  $w.ResizeMode = 'NoResize'
  $w.WindowStyle = 'None'
  $w.WindowStartupLocation = 'CenterScreen'
  $w.Topmost = $true
  $w.ShowActivated = $true
  $w.ShowInTaskbar = $true
  $w.Background = $background
  $w.Foreground = $body
  $w.FontFamily = 'Segoe UI'
  $shell = New-Object System.Windows.Controls.Border
  $shell.Background = $background
  $shell.BorderBrush = $silver
  $shell.BorderThickness = New-Object System.Windows.Thickness 1
  $shell.Padding = New-Object System.Windows.Thickness 24
  $grid = New-Object System.Windows.Controls.Grid
  foreach ($height in @(36, 28, 64, 28, 48, 52)) {
    $row = New-Object System.Windows.Controls.RowDefinition
    $row.Height = [System.Windows.GridLength]::new($height)
    [void]$grid.RowDefinitions.Add($row)
  }
  $header = New-Object System.Windows.Controls.TextBlock
  $header.Text = 'MERCEDES-BENZ UPDATE'
  $header.FontSize = 18
  $header.FontWeight = 'SemiBold'
  $header.Foreground = $silver
  $header.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetRow($header, 0)
  [void]$grid.Children.Add($header)
  $rule = New-Object System.Windows.Controls.Border
  $rule.Height = 2
  $rule.Background = $silver
  $rule.HorizontalAlignment = 'Left'
  $rule.Width = 42
  $rule.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetRow($rule, 1)
  [void]$grid.Children.Add($rule)
  $message = New-Object System.Windows.Controls.TextBlock
  $message.Text = if ($IsPreview) { 'Preview. Nothing will be installed.' } else { "Version $BareVersion is ready. Install it now?" }
  $message.FontSize = 14
  $message.Foreground = $body
  $message.TextWrapping = 'Wrap'
  $message.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetRow($message, 2)
  [void]$grid.Children.Add($message)
  $bar = New-Object System.Windows.Controls.ProgressBar
  $bar.Minimum = 0
  $bar.Maximum = 100
  $bar.Value = 0
  $bar.Height = 10
  $bar.Foreground = $silver
  $bar.Background = New-UpdaterBrush '#121A26'
  $bar.BorderBrush = $silver
  $progressTemplate = @'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="ProgressBar">
  <Grid>
    <Border Name="PART_Track" Background="#121A26" BorderBrush="#C0C6CE" BorderThickness="1"/>
    <Border Name="PART_Indicator" Background="#C0C6CE" HorizontalAlignment="Left"/>
  </Grid>
</ControlTemplate>
'@
  $bar.Template = [System.Windows.Markup.XamlReader]::Parse($progressTemplate)
  [System.Windows.Controls.Grid]::SetRow($bar, 3)
  [void]$grid.Children.Add($bar)
  $detail = New-Object System.Windows.Controls.TextBlock
  $detail.Text = 'Ready'
  $detail.FontSize = 13
  $detail.Foreground = $muted
  $detail.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetRow($detail, 4)
  [void]$grid.Children.Add($detail)
  $buttons = New-Object System.Windows.Controls.StackPanel
  $buttons.Orientation = 'Horizontal'
  $buttons.HorizontalAlignment = 'Right'
  $buttons.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetRow($buttons, 5)
  $later = New-Object System.Windows.Controls.Button
  $later.Content = 'Later'
  $later.Width = 112
  $later.Height = 40
  $later.Margin = New-Object System.Windows.Thickness 0, 0, 12, 0
  Set-DarkButton $later '#172033' '#C0C6CE'
  $now = New-Object System.Windows.Controls.Button
  $now.Content = if ($IsPreview) { 'Close' } else { 'Update Now' }
  $now.Width = 140
  $now.Height = 40
  Set-DarkButton $now '#C0C6CE' '#0C121C'
  [void]$buttons.Children.Add($later)
  [void]$buttons.Children.Add($now)
  [void]$grid.Children.Add($buttons)
  $shell.Child = $grid
  $w.Content = $shell
  $header.Add_MouseLeftButtonDown({ try { $w.DragMove() } catch {} }.GetNewClosure())
  $context = @{ busy = $false; finished = $false; runner = $null; started = [datetime]::MinValue; successChecks = 0 }
  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(500)
  $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $later.Add_Click({
    if (-not $context.busy) { $w.Close() }
  }.GetNewClosure())
  $now.Add_Click({
    if ($IsPreview) { $w.Close(); return }
    if ($context.busy) { if ($context.finished) { $w.Close() }; return }
    $context.busy = $true
    $context.started = Get-Date
    $later.IsEnabled = $false
    $later.Visibility = [System.Windows.Visibility]::Collapsed
    $now.IsEnabled = $false
    $now.Content = 'Installing'
    $w.Add_Closing({ if ($context.busy -and -not $context.finished) { $_.Cancel = $true } }.GetNewClosure())
    $message.Text = 'Installing ' + $BareVersion
    $detail.Text = 'Starting update'
    $bar.IsIndeterminate = $false
    $bar.Value = 5
    if (Test-Path -LiteralPath $progressPath) { Remove-Item -LiteralPath $progressPath -Force }
    try {
      $runner = Join-Path $root 'UpdateRunner.ps1'
      if (-not (Test-Path -LiteralPath $runner)) { throw 'UpdateRunner.ps1 missing' }
      $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $runner + '" -ZipUrl "' + $ZipUrl + '" -ManifestUrl "' + $ManifestUrl + '" -Tag "' + $Tag + '"'
      $context.runner = Start-Process -FilePath $ps -ArgumentList $arg -PassThru -WindowStyle Hidden
      $timer.Start()
    } catch {
      $bar.IsIndeterminate = $false
      $detail.Text = 'Update could not start'
      $message.Text = 'Update could not start'
      $now.IsEnabled = $true
      $now.Content = 'Close'
      $context.finished = $true
    }
  }.GetNewClosure())
  $timer.Add_Tick({
    if ($context.finished) { $timer.Stop(); return }
    try {
      $data = $null
      if (Test-Path -LiteralPath $progressPath) {
        try { $data = Get-Content -LiteralPath $progressPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
      }
      if ($data) {
        $bar.IsIndeterminate = $false
        $bar.Value = [Math]::Max(0, [Math]::Min(100, [int]$data.percent))
        $detail.Text = [string]$data.message
      }
      $state = if ($data) { [string]$data.state } else { '' }
      $installedVersion = ''
      $installationStatus = ''
      try {
        $installedVersion = [string](Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
        $installationStatus = [string](Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json).state
      } catch {}
      $versionMatches = ($installedVersion -eq $BareVersion)
      $confirmed = $false
      if ($versionMatches -and $installationStatus -eq 'current') {
        try {
          $statusFile = Get-Item -LiteralPath $statusPath -ErrorAction Stop
          $confirmed = ($statusFile.LastWriteTime -ge $context.started)
        } catch {}
      }
      if ($confirmed) { $context.successChecks++ } else { $context.successChecks = 0 }
      $complete = ($state -eq 'success' -or $context.successChecks -ge 4)
      $failed = ($state -eq 'error' -and -not $complete)
      $runnerExited = $false
      if ($context.runner) { try { $context.runner.Refresh(); $runnerExited = $context.runner.HasExited } catch {} }
      if ($complete -or $failed -or ($runnerExited -and ((Get-Date) - $context.started).TotalSeconds -gt 8)) {
        $timer.Stop()
        $context.finished = $true
        $bar.IsIndeterminate = $false
        if ($complete) {
          $bar.Value = 100
          $message.Text = 'Update complete'
          $detail.Text = 'Home and the dock were verified.'
        } elseif ($failed) {
          $message.Text = 'Update failed'
          $detail.Text = if ($data -and $data.message) { [string]$data.message } else { 'The previous install was restored.' }
        } else {
          $message.Text = 'Update needs a look'
          $detail.Text = 'Check version.json and update-status.json.'
        }
        $now.Content = 'Close'
        $now.IsEnabled = $true
        $later.Visibility = [System.Windows.Visibility]::Collapsed
      }
    } catch {
      $detail.Text = 'Waiting for the installer'
    }
  }.GetNewClosure())
  $w.Add_ContentRendered({ $w.Topmost = $true; [void]$w.Activate() }.GetNewClosure())
  [void]$w.ShowDialog()
  if (-not $context.busy -and -not $IsPreview) {
    $defer = @{ version = $Tag; until = (Get-Date).AddHours(12).ToString('o') }
    Write-Utf8File (Join-Path $root 'update-deferred.json') ($defer | ConvertTo-Json -Compress)
  }
}

if ($env:MERCEDES_UPDATER_LIBRARY -eq '1') {
  # Dot-sourced for checks and for the runner. Do not start the agent.
} else {
  if ($Preview) {
    Show-Updater -Tag 'mercedes-v0.0.0-beta.0' -BareVersion '0.0.0-beta.0' -ZipUrl '' -ManifestUrl '' -Prefix $script:MercedesTagPrefix -IsPreview $true
    exit 0
  }
  $mutex = New-Object System.Threading.Mutex($false, 'Local\UniversalDiagnosticWorkstation-UpdateAgent-v1')
  if (-not $mutex.WaitOne(0)) { exit 0 }
  try {
    Start-Sleep -Seconds 10
    while ($true) {
      try {
        $settings = Resolve-MercedesUpdateSettings $root
        if (-not $settings.mercedesTags) {
          Set-UpdateStatus 'unconfigured' '' 'No Mercedes release published yet'
        } else {
          $release = Get-LatestRelease $settings
          if (-not $release) {
            Set-UpdateStatus 'unconfigured' '' 'No Mercedes release published yet'
          } else {
            $tag = [string]$release.tag_name
            $bare = Get-BareVersion $tag $settings.tagPrefix
            $installed = ''
            try { $installed = [string](Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch {}
            if ((Get-VersionRank $tag $settings.tagPrefix) -le (Get-VersionRank $installed $settings.tagPrefix)) {
              Set-UpdateStatus 'current' $tag 'Up to date'
            } else {
              Set-UpdateStatus 'available' $tag 'Update available'
              $deferPath = Join-Path $root 'update-deferred.json'
              $skip = $false
              if (Test-Path -LiteralPath $deferPath) {
                try {
                  $deferred = Get-Content -LiteralPath $deferPath -Raw -Encoding UTF8 | ConvertFrom-Json
                  $skip = ($deferred.version -eq $tag -and (Get-Date) -lt [datetime]$deferred.until)
                } catch {}
              }
              if (-not $skip) {
                $zip = [string]($release.assets | Where-Object { $_.name -eq 'workstation.zip' } | Select-Object -First 1).browser_download_url
                $manifest = [string]($release.assets | Where-Object { $_.name -eq 'update-manifest.json' } | Select-Object -First 1).browser_download_url
                Show-Updater -Tag $tag -BareVersion $bare -ZipUrl $zip -ManifestUrl $manifest -Prefix $settings.tagPrefix -IsPreview $false
              }
            }
          }
        }
      } catch {
        if (Test-OfflineError $_) { Set-UpdateStatus 'offline' '' 'Offline' }
        else { Set-UpdateStatus 'error' '' 'Update check failed' }
      }
      Start-Sleep -Seconds 21600
    }
  } finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
  }
}
