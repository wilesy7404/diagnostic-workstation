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

function Get-ReleaseSummary([string]$body) {
  if ([string]::IsNullOrWhiteSpace($body)) { return '' }
  $line = ''
  foreach ($part in ($body -split '\r?\n')) {
    $part = $part.Trim()
    if ($part.Length -gt 0) { $line = $part; break }
  }
  if (-not $line) { return '' }
  $line = $line -replace '^#+\s*', ''
  $line = ($line -replace '\s+', ' ').Trim()
  if ($line.Length -gt 140) { $line = $line.Substring(0, 137) + '...' }
  return $line
}

function Get-UpdaterBrand {
  $name = 'Mercedes-Benz'
  $logo = Join-Path $root 'branding/mercedes.png'
  $profilePath = Join-Path $root 'profile.json'
  if (Test-Path -LiteralPath $profilePath) {
    try {
      $profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
      if (-not [string]::IsNullOrWhiteSpace([string]$profile.displayName)) { $name = [string]$profile.displayName }
      if (-not [string]::IsNullOrWhiteSpace([string]$profile.logo)) {
        $candidate = Join-Path $root ([string]$profile.logo -replace '/', '\')
        if (-not (Test-Path -LiteralPath $candidate)) { $candidate = Join-Path $root ([string]$profile.logo) }
        if (Test-Path -LiteralPath $candidate) { $logo = $candidate }
      }
    } catch {}
  }
  return [pscustomobject]@{ Name = $name; Logo = $logo }
}

function Show-Updater([string]$Tag, [string]$BareVersion, [string]$ZipUrl, [string]$ManifestUrl, [string]$Prefix, [bool]$IsPreview, [string]$Notes) {
  Add-UpdaterAssemblies
  # Each ControlTemplate is its own XAML root when parsed, so xmlns:x has to be on that root.
  # The same declaration is repeated on the templates embedded in this window.
  $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="Software Update" Width="520" Height="340" WindowStyle="None" AllowsTransparency="True" ResizeMode="NoResize"
 WindowStartupLocation="CenterScreen" ShowInTaskbar="True" Topmost="True" Background="Transparent" Foreground="#D0D5DB"
 FontFamily="Segoe UI" UseLayoutRounding="True" SnapsToDevicePixels="True">
 <Window.Resources>
  <ControlTemplate xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" x:Key="UpdatePrimary" TargetType="Button">
   <Border x:Name="BdPrimary" Background="#C0C6CE" BorderBrush="#C0C6CE" BorderThickness="1" CornerRadius="8" Padding="16,0">
    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" TextElement.Foreground="#0C121C"/>
   </Border>
   <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="BdPrimary" Property="Background" Value="#D5DAE0"/><Setter TargetName="BdPrimary" Property="BorderBrush" Value="#D5DAE0"/></Trigger>
    <Trigger Property="IsPressed" Value="True"><Setter TargetName="BdPrimary" Property="Background" Value="#AEB6C0"/><Setter TargetName="BdPrimary" Property="BorderBrush" Value="#AEB6C0"/></Trigger>
    <Trigger Property="IsEnabled" Value="False"><Setter TargetName="BdPrimary" Property="Opacity" Value="0.45"/></Trigger>
   </ControlTemplate.Triggers>
  </ControlTemplate>
  <ControlTemplate xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" x:Key="UpdateSecondary" TargetType="Button">
   <Border x:Name="BdSecondary" Background="#0C121C" BorderBrush="#C0C6CE" BorderThickness="1" CornerRadius="8" Padding="16,0">
    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" TextElement.Foreground="#C0C6CE"/>
   </Border>
   <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="BdSecondary" Property="Background" Value="#1A2230"/></Trigger>
    <Trigger Property="IsPressed" Value="True"><Setter TargetName="BdSecondary" Property="Background" Value="#243044"/></Trigger>
    <Trigger Property="IsEnabled" Value="False"><Setter TargetName="BdSecondary" Property="Opacity" Value="0.45"/></Trigger>
   </ControlTemplate.Triggers>
  </ControlTemplate>
  <ControlTemplate xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" x:Key="UpdateClose" TargetType="Button">
   <Border x:Name="BdClose" Background="#0C121C" CornerRadius="8">
    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
   </Border>
   <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="BdClose" Property="Background" Value="#1A2230"/></Trigger>
    <Trigger Property="IsPressed" Value="True"><Setter TargetName="BdClose" Property="Background" Value="#243044"/></Trigger>
   </ControlTemplate.Triggers>
  </ControlTemplate>
 </Window.Resources>
 <Border Margin="12" Background="#0C121C" BorderBrush="#2A3442" BorderThickness="1" CornerRadius="14" Padding="24">
  <Border.Effect>
   <DropShadowEffect BlurRadius="18" ShadowDepth="0" Opacity="0.5" Color="#000000"/>
  </Border.Effect>
  <Grid>
   <Grid.RowDefinitions>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="*"/>
    <RowDefinition Height="Auto"/>
   </Grid.RowDefinitions>
   <Grid x:Name="DragHeader" Grid.Row="0">
    <Grid.ColumnDefinitions>
     <ColumnDefinition Width="Auto"/>
     <ColumnDefinition Width="*"/>
     <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <Border x:Name="LogoFrame" Width="36" Height="36" CornerRadius="18" Background="#121820" Margin="0,0,12,0">
     <Image x:Name="BrandLogo" Stretch="Uniform" Margin="5"/>
    </Border>
    <StackPanel Grid.Column="1" VerticalAlignment="Center">
     <TextBlock Text="Software Update" FontSize="18" FontWeight="SemiBold" Foreground="#E6ECEF"/>
     <TextBlock x:Name="BrandSubtitle" FontSize="12" Foreground="#8A96A6" Margin="0,2,0,0"/>
    </StackPanel>
    <Button x:Name="CloseUpdate" Grid.Column="2" Width="28" Height="28" Template="{StaticResource UpdateClose}" Cursor="Hand" ToolTip="Close" VerticalAlignment="Center">
     <TextBlock Text="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="#8A96A6" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Button>
   </Grid>
   <Border Grid.Row="1" Margin="0,16,0,0" Background="#121820" BorderBrush="#2A3442" BorderThickness="1" CornerRadius="10" Padding="14,10">
    <StackPanel Orientation="Horizontal">
     <StackPanel Width="200">
      <TextBlock Text="CURRENT VERSION" FontSize="10" FontWeight="SemiBold" Foreground="#8A96A6"/>
      <TextBlock x:Name="CurrentVersion" FontSize="15" Foreground="#E6ECEF" Margin="0,4,0,0"/>
     </StackPanel>
     <StackPanel x:Name="NewVersionPanel" Width="200" Margin="24,0,0,0">
      <TextBlock Text="NEW VERSION" FontSize="10" FontWeight="SemiBold" Foreground="#8A96A6"/>
      <TextBlock x:Name="NewVersion" FontSize="15" Foreground="#C0C6CE" Margin="0,4,0,0"/>
     </StackPanel>
    </StackPanel>
   </Border>
   <TextBlock x:Name="NotesLine" Grid.Row="2" Margin="0,10,0,0" FontSize="12" Foreground="#8A96A6" TextTrimming="CharacterEllipsis"/>
   <TextBlock x:Name="MessageLine" Grid.Row="3" Margin="0,8,0,0" FontSize="13" Foreground="#D0D5DB" TextWrapping="Wrap"/>
   <Grid Grid.Row="4" Margin="0,12,0,0">
    <Grid.ColumnDefinitions>
     <ColumnDefinition Width="*"/>
     <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <ProgressBar x:Name="UpdateProgress" Height="6" Minimum="0" Maximum="100" Value="0" BorderThickness="0" Foreground="#C0C6CE" Background="#1A2230" VerticalAlignment="Center">
     <ProgressBar.Template>
      <ControlTemplate xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="ProgressBar">
       <Grid Height="6">
        <Border x:Name="PART_Track" Background="#1A2230" CornerRadius="3" Height="6"/>
        <Border x:Name="PART_Indicator" Background="#C0C6CE" CornerRadius="3" HorizontalAlignment="Left" Height="6"/>
       </Grid>
      </ControlTemplate>
     </ProgressBar.Template>
    </ProgressBar>
    <TextBlock x:Name="PercentText" Grid.Column="1" Margin="12,0,0,0" MinWidth="36" FontSize="12" Foreground="#C0C6CE" VerticalAlignment="Center" Text="0%"/>
   </Grid>
   <TextBlock x:Name="DetailLine" Grid.Row="5" Margin="0,8,0,0" FontSize="12" Foreground="#8A96A6" TextWrapping="Wrap" VerticalAlignment="Top"/>
   <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Bottom">
    <Button x:Name="LaterButton" Content="Later" Width="112" Height="36" Margin="0,0,12,0" FontFamily="Segoe UI" FontSize="13" Cursor="Hand" Template="{StaticResource UpdateSecondary}" Foreground="#C0C6CE"/>
    <Button x:Name="NowButton" Content="Update Now" Width="140" Height="36" FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold" Cursor="Hand" Template="{StaticResource UpdatePrimary}" Foreground="#0C121C"/>
   </StackPanel>
  </Grid>
 </Border>
</Window>
'@
  $w = [System.Windows.Markup.XamlReader]::Parse($xaml)
  $message = $w.FindName('MessageLine')
  $detail = $w.FindName('DetailLine')
  $bar = $w.FindName('UpdateProgress')
  $later = $w.FindName('LaterButton')
  $now = $w.FindName('NowButton')
  $header = $w.FindName('DragHeader')
  $brand = Get-UpdaterBrand
  $w.FindName('BrandSubtitle').Text = $brand.Name
  $currentVersion = ''
  try { $currentVersion = [string](Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch {}
  if ([string]::IsNullOrWhiteSpace($currentVersion)) { $currentVersion = 'Unknown' }
  $w.FindName('CurrentVersion').Text = $currentVersion
  if ($IsPreview) {
    $w.FindName('NewVersionPanel').Visibility = 'Collapsed'
  } else {
    $w.FindName('NewVersion').Text = $BareVersion
  }
  $notesLine = $w.FindName('NotesLine')
  if ([string]::IsNullOrWhiteSpace($Notes)) { $notesLine.Visibility = 'Collapsed' } else { $notesLine.Text = $Notes }
  $message.Text = if ($IsPreview) { 'Preview. Nothing will be installed.' } else { "Version $BareVersion is ready. Install it now?" }
  $now.Content = if ($IsPreview) { 'Close' } else { 'Update Now' }
  $detail.Text = 'Ready'
  if (Test-Path -LiteralPath $brand.Logo) {
    try {
      $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
      $bitmap.BeginInit()
      $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bitmap.UriSource = New-Object System.Uri ([string](Resolve-Path -LiteralPath $brand.Logo).Path)
      $bitmap.EndInit()
      if ($bitmap.CanFreeze) { $bitmap.Freeze() }
      $w.FindName('BrandLogo').Source = $bitmap
    } catch {
      $w.FindName('LogoFrame').Visibility = 'Collapsed'
    }
  } else {
    $w.FindName('LogoFrame').Visibility = 'Collapsed'
  }
  $percent = $w.FindName('PercentText')
  $bar.Add_ValueChanged({ $percent.Text = ([int][Math]::Round($bar.Value)).ToString() + '%' }.GetNewClosure())
  $header.Add_MouseLeftButtonDown({ try { $w.DragMove() } catch {} }.GetNewClosure())
  $w.FindName('CloseUpdate').Add_Click({ $w.Close() }.GetNewClosure())
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
  # Stay running when another agent holds the mutex. A clean exit makes WorkstationManager relaunch this script.
  $ownsMutex = $false
  while (-not $ownsMutex) {
    try {
      $ownsMutex = [bool]$mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
      $ownsMutex = $true
    } catch {
      $inner = $_.Exception.InnerException
      if ($inner -is [System.Threading.AbandonedMutexException]) { $ownsMutex = $true }
    }
    if (-not $ownsMutex) { Start-Sleep -Seconds 30 }
  }
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
                $notes = ''
                try { $notes = Get-ReleaseSummary ([string]$release.body) } catch {}
                Show-Updater -Tag $tag -BareVersion $bare -ZipUrl $zip -ManifestUrl $manifest -Prefix $settings.tagPrefix -IsPreview $false -Notes $notes
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
    if ($ownsMutex) {
      try { $mutex.ReleaseMutex() } catch {}
    }
    $mutex.Dispose()
  }
}
