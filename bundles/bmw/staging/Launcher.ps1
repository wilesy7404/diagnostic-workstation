# BMW Stealth Launcher v2 | Windows PowerShell 5.1 | WPF
# Home cards and the admin dialog. The 2026-10-14 handoff export is frozen; this file is the staging copy.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
Add-Type @'
using System;using System.Runtime.InteropServices;
public static class BMWNative {
 [DllImport("user32.dll",CharSet=CharSet.Auto)] public static extern IntPtr FindWindow(string cls,string title);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd,int command);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] icons, uint[] ids, uint count, uint flags);
 [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
}
'@
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$config=Join-Path $root 'apps.json'
$script:apps=@()
$script:boldCardDescription=$false
$script:hidden=$false
function Taskbar([bool]$hide) {
 $action=if($hide){0}else{5}
 foreach($cls in @('Shell_TrayWnd','Shell_SecondaryTrayWnd')) {
  $hw=[BMWNative]::FindWindow($cls,$null)
  if($hw -ne [IntPtr]::Zero){[void][BMWNative]::ShowWindow($hw,$action)}
 }
 $script:hidden=$hide
}
function Load-Apps {
 if(Test-Path $config){
  $data=Get-Content $config -Raw -Encoding UTF8 | ConvertFrom-Json
  $script:apps=@($data.apps)
 }
}
function Save-Apps {
 @{apps=@($script:apps)} | ConvertTo-Json -Depth 9 | Set-Content $config -Encoding UTF8
}
function Load-Profile {
 $script:boldCardDescription=$false
 $profilePath=Join-Path $root 'profile.json'
 if(-not (Test-Path -LiteralPath $profilePath)){return}
 try {
  $p=Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
  if($null -ne $p.PSObject.Properties['boldCardDescription']){ $script:boldCardDescription=($p.boldCardDescription -eq $true) }
 } catch { $script:boldCardDescription=$false }
}
function Save-Profile {
 $profilePath=Join-Path $root 'profile.json'
 $p=$null
 if(Test-Path -LiteralPath $profilePath){
  try { $p=Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $p=$null }
 }
 if($null -eq $p){
  $p=[pscustomobject]@{id='bmw';displayName='BMW';short='BMW';boldCardDescription=[bool]$script:boldCardDescription}
 } elseif($p.PSObject.Properties.Name -contains 'boldCardDescription'){
  $p.boldCardDescription=[bool]$script:boldCardDescription
 } else {
  $p | Add-Member -NotePropertyName boldCardDescription -NotePropertyValue ([bool]$script:boldCardDescription)
 }
 $utf8Bom=New-Object System.Text.UTF8Encoding $true
 [System.IO.File]::WriteAllText($profilePath, ($p | ConvertTo-Json -Depth 6), $utf8Bom)
}
function Brush($value){New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($value))}
function Image-Source($path) {
 if(-not $path -or -not(Test-Path -LiteralPath $path)){return $null}
 try {
  if([IO.Path]::GetExtension($path) -ieq '.exe'){
   # Ask Windows for a high-resolution native icon before using its tiny associated icon.
   $handles=New-Object 'IntPtr[]' 1
   $ids=New-Object 'uint32[]' 1
   try {
    $count=[BMWNative]::PrivateExtractIcons($path,0,256,256,$handles,$ids,1,0)
    if($count -gt 0 -and $handles[0] -ne [IntPtr]::Zero){
     $bitmap=[Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($handles[0],[Windows.Int32Rect]::Empty,[Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
     $bitmap.Freeze();return $bitmap
    }
   } finally {if($handles[0] -ne [IntPtr]::Zero){[void][BMWNative]::DestroyIcon($handles[0])}}
   $icon=[Drawing.Icon]::ExtractAssociatedIcon($path)
   if(-not $icon){return $null}
   try{$bitmap=[Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($icon.Handle,[Windows.Int32Rect]::Empty,[Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions());$bitmap.Freeze();return $bitmap} finally {$icon.Dispose()}
  }
  if([IO.Path]::GetExtension($path) -ieq '.lnk'){return $null}
  $bitmap=New-Object Windows.Media.Imaging.BitmapImage
  $bitmap.BeginInit(); $bitmap.UriSource=New-Object Uri($path);$bitmap.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad;$bitmap.EndInit();$bitmap.Freeze();return $bitmap
 } catch {return $null}
}
function File-Pick([string]$current,[bool]$image=$false){
 $dlg=New-Object Microsoft.Win32.OpenFileDialog
 $dlg.Filter=if($image){'Pictures|*.png;*.jpg;*.jpeg;*.bmp;*.ico|All files|*.*'}else{'Applications and shortcuts|*.exe;*.lnk;*.bat;*.cmd|All files|*.*'}
 if($current -and (Test-Path $current)){$dlg.InitialDirectory=Split-Path $current -Parent}
 if($dlg.ShowDialog() -eq $true){return $dlg.FileName}
 return $null
}
$windowXaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="BMW Diagnostic System" WindowStyle="None" WindowState="Maximized" ResizeMode="NoResize" ShowInTaskbar="True" Background="#080D14" FontFamily="Segoe UI">
 <Window.Resources>
  <Style x:Key="Tile" TargetType="Button">
   <Setter Property="BorderBrush" Value="#7694B2CF"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="12"/><Setter Property="Padding" Value="0"/>
   <Setter Property="Background">
    <Setter.Value>
     <LinearGradientBrush StartPoint="0.5,0" EndPoint="0.5,1">
      <GradientStop Color="#CC1A2637" Offset="0"/>
      <GradientStop Color="#8A121C2C" Offset="1"/>
     </LinearGradientBrush>
    </Setter.Value>
   </Setter>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="surface" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="24" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True"><ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/></Border><ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="surface" Property="BorderBrush" Value="#7694B2CF"/></Trigger>
     <Trigger Property="IsPressed" Value="True"><Setter TargetName="surface" Property="Background" Value="#F0284C73"/><Setter TargetName="surface" Property="BorderBrush" Value="#D6E9FF"/></Trigger>
   </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Ghost" TargetType="Button"><Setter Property="Background" Value="#D7111E2D"/><Setter Property="BorderBrush" Value="#75809DB9"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Foreground" Value="#E7F2FF"/><Setter Property="Padding" Value="16,9"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="12"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
  <Style x:Key="FooterButton" TargetType="Button">
   <Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="12,6"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="bg" CornerRadius="14" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bg" Property="Background" Value="#385A86B5"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="bg" Property="Background" Value="#5D7C9ABB"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
 </Window.Resources>
 <Grid x:Name="Canvas">
  <Border Background="#42040A14"/>
  <Border VerticalAlignment="Top" Height="70" Background="#33080F19"/>

  <Grid Margin="35,13,35,21">
   <Grid.RowDefinitions><RowDefinition Height="58"/><RowDefinition Height="*"/><RowDefinition Height="60"/></Grid.RowDefinitions>
   <Grid Grid.Row="0">
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <Border Grid.Column="0" CornerRadius="27" Width="46" Height="46" Background="#E8EAF0F7" BorderBrush="#B5D7F6" BorderThickness="1" VerticalAlignment="Center">
     <Grid Margin="4"><Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
       <Border Background="#B6E1FF" Grid.Row="0" Grid.Column="0" CornerRadius="22,0,0,0"/>
       <Border Background="#254A78" Grid.Row="0" Grid.Column="1" CornerRadius="0,22,0,0"/>
       <Border Background="#254A78" Grid.Row="1" Grid.Column="0" CornerRadius="0,0,0,22"/>
       <Border Background="#B6E1FF" Grid.Row="1" Grid.Column="1" CornerRadius="0,0,22,0"/>
     </Grid>
    </Border>
    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="13,0,0,0">
      <Border Width="1" Background="#63A9E0" Margin="0,7,13,7"/>
      <StackPanel VerticalAlignment="Center"><TextBlock Text="BMW" FontSize="22" FontWeight="SemiBold" Foreground="#F3F8FF"/><TextBlock Text="DIAGNOSTIC WORKSTATION" FontSize="9" FontWeight="SemiBold" Foreground="#7FB9EB"/></StackPanel>
    </StackPanel>
    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Right"><Border Width="1" Height="37" Margin="0,0,15,0" Background="#7BBDD8F2"/><StackPanel VerticalAlignment="Center"><TextBlock Text="LOCAL TIME" HorizontalAlignment="Right" Foreground="#AAC8E0" FontSize="9"/><TextBlock x:Name="Clock" HorizontalAlignment="Right" Foreground="#F3F8FF" FontSize="15" FontWeight="SemiBold"/></StackPanel></StackPanel>
   </Grid>
   <Grid Grid.Row="1">
     <ScrollViewer HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Center"><ItemsControl x:Name="Tiles" HorizontalAlignment="Center" VerticalAlignment="Center"><ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel HorizontalAlignment="Center"/></ItemsPanelTemplate></ItemsControl.ItemsPanel></ItemsControl></ScrollViewer>
     <StackPanel x:Name="EmptyState" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed" Margin="12" MaxWidth="530">
      <Border Background="#B7122436" BorderBrush="#5376A7D2" BorderThickness="1" CornerRadius="18" Padding="24">
       <StackPanel><TextBlock Text="READY FOR DIAGNOSTICS" HorizontalAlignment="Center" Foreground="#F2F7FF" FontSize="24" FontWeight="Light"/><TextBlock x:Name="EmptyStateDetail" Text="apps.json was not found on this workstation. Open ADMIN and choose Save &amp; Close to create it, then add a diagnostic application." TextAlignment="Center" TextWrapping="Wrap" Foreground="#B3C6DC" FontSize="13" Margin="12,12,12,0"/></StackPanel>
      </Border>
     </StackPanel>
   </Grid>
   <DockPanel Grid.Row="2" LastChildFill="False" VerticalAlignment="Bottom" Margin="0,0,0,3">
    <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center"><Border Width="22" Height="2" Background="#3D9EDB" Margin="0,0,10,0"/><TextBlock x:Name="FooterUpdateStatus" Foreground="#AFC6DF" FontSize="11" VerticalAlignment="Center" Text="BMW WORKSTATION  |  Checking update status..." TextTrimming="CharacterEllipsis" MaxWidth="560"/></StackPanel>
    <Border DockPanel.Dock="Right" CornerRadius="22" Background="#62121E30" BorderBrush="#729BB8D3" BorderThickness="1" Padding="10,3">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
       <Button x:Name="SystemButton" Style="{StaticResource FooterButton}">
        <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#DCEBFA" VerticalAlignment="Center" Margin="0,0,9,0"/><TextBlock Text="SYSTEM" Foreground="White" FontSize="11" VerticalAlignment="Center"/></StackPanel>
       </Button>
       <Border Width="1" Height="23" Background="#7797B3CD" Margin="7,0" VerticalAlignment="Center"/>
       <Button x:Name="AdminButton" Style="{StaticResource FooterButton}">
        <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE77B;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#DCEBFA" VerticalAlignment="Center" Margin="0,0,9,0"/><TextBlock Text="ADMIN" Foreground="White" FontSize="11" VerticalAlignment="Center"/></StackPanel>
       </Button>
      </StackPanel>
     </Border>
   </DockPanel>
  </Grid>
 </Grid>
</Window>
'@
# WPF TextBlock doesn't support LetterSpacing; remove attribute before loading.
$windowXaml=$windowXaml -replace ' LetterSpacing="1"',''
$window=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader ([xml]$windowXaml)))
# BMW-WORKSTATION-FOOTER-UPDATE-STATUS-v2
try {
 $script:bmwRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
 $script:bmwLabel=$window.FindName('FooterUpdateStatus')
 if(-not $script:bmwLabel){throw 'FooterUpdateStatus is missing'}
 $script:bmwStatusTimer=New-Object Windows.Threading.DispatcherTimer
 $script:bmwStatusTimer.Interval=[TimeSpan]::FromSeconds(12)
 $script:bmwStatusTimer.Add_Tick({
  try {
   $v=(Get-Content (Join-Path $script:bmwRoot 'version.json') -Raw | ConvertFrom-Json).version
   $s='Update source not connected'
   $sp=Join-Path $script:bmwRoot 'update-status.json'
   if(Test-Path $sp){
    $st=Get-Content $sp -Raw | ConvertFrom-Json
    switch($st.state){'current'{$s='Up to date'} 'available'{$s='Update available: '+$st.latest} 'restart'{$s='Restart to finish update'} 'error'{$s='Update check unavailable'} 'unconfigured'{$s='No verified release published'} default{$s='Update source not connected'}}
   }
   $script:bmwLabel.Text='BMW WORKSTATION  v'+$v+'  |  '+$s
  } catch {$script:bmwLabel.Text='BMW WORKSTATION | Status unavailable'}
 })
 $window.Add_Loaded({
  $script:bmwStatusTimer.Start()
  try {
   $v=(Get-Content (Join-Path $script:bmwRoot 'version.json') -Raw | ConvertFrom-Json).version
   $script:bmwLabel.Text='BMW WORKSTATION  v'+$v+'  |  Checking update status...'
  }catch{$script:bmwLabel.Text='BMW WORKSTATION | Status unavailable'}
  try {
   $agent=Join-Path $script:bmwRoot 'UpdateAgent.ps1'
   if(Test-Path $agent){Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$agent+'"')) -WindowStyle Hidden}
  }catch{}
 })
} catch {}

$tiles=$window.FindName('Tiles');$canvas=$window.FindName('Canvas');$clock=$window.FindName('Clock')
$adminButton=$window.FindName('AdminButton');$systemButton=$window.FindName('SystemButton')
function Apply-Wallpaper {
 $wall=(Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).Wallpaper
 $source=Image-Source $wall
 if($source){$brush=New-Object Windows.Media.ImageBrush($source);$brush.Stretch='UniformToFill';$canvas.Background=$brush}
}
function Make-Card($app){
 $btn=New-Object System.Windows.Controls.Button
 $btn.Style=$window.FindResource('Tile')
 $btn.Width=214
 $btn.Height=184
 $btn.Margin='14,12,14,12'
 $btn.Padding='0'
 $btn.Tag=[string]$app.name
 # ClipToBounds does not round a WPF button. RectangleGeometry is the clip that does.
 $applyRoundClip = {
  param($el)
  if(-not $el){return}
  $w=[double]$el.ActualWidth; $h=[double]$el.ActualHeight
  if($w -le 0 -or $h -le 0){return}
  $el.Clip = New-Object System.Windows.Media.RectangleGeometry (New-Object System.Windows.Rect(0,0,$w,$h)), 24, 24
 }
 $btn.Add_Loaded({ param($s,$e) & $applyRoundClip $s }.GetNewClosure())
 $btn.Add_SizeChanged({ param($s,$e) & $applyRoundClip $s }.GetNewClosure())

 $stack=New-Object System.Windows.Controls.StackPanel
 $stack.VerticalAlignment='Center'
 $stack.Margin='20,18,20,18'

 $title=New-Object System.Windows.Controls.TextBlock
 $title.Text=([string]$app.name).Trim()
 $title.FontFamily='Segoe UI'
 $title.Foreground=Brush '#F7FBFF'
 $title.FontSize=22
 $title.FontWeight='SemiBold'
 $title.TextWrapping='Wrap'
 $title.TextTrimming='CharacterEllipsis'
 $title.LineHeight=28
 $title.MaxHeight=56
 [void]$stack.Children.Add($title)

 $showDetail=$true
 if($null -ne $app.PSObject.Properties['showDescription']){ $showDetail=($app.showDescription -ne $false) }
 if($showDetail){
  $descRaw=[string]$app.description
  if([string]::IsNullOrWhiteSpace($descRaw)){
   $n=[string]$app.name
   if($n -match '(?i)^(new\s*app|untitled|app)$'){ $descRaw='Add a diagnostic app' } else { $descRaw='Diagnostic application' }
  }
  $descRaw=$descRaw.Trim()
  $maxDesc=42
  if($descRaw.Length -gt $maxDesc){ $descRaw=($descRaw.Substring(0,$maxDesc-1).TrimEnd() + [string][char]0x2026) }
  $desc=New-Object System.Windows.Controls.TextBlock
  $desc.Text=$descRaw
  $desc.FontFamily='Segoe UI'
  $desc.Foreground=Brush '#C5D9EE'
  $desc.FontSize=12
  $desc.FontWeight=$(if($script:boldCardDescription){'Bold'}else{'Normal'})
  $desc.TextWrapping='Wrap'
  $desc.LineHeight=18
  $desc.MaxHeight=40
  $desc.Margin='0,10,0,0'
  [void]$stack.Children.Add($desc)
 }

 $btn.Content=$stack
 $btn.Add_Click({
  param($sender,$ev)
  $selected=$script:apps | Where-Object { $_.name -eq $sender.Tag } | Select-Object -First 1
  if(-not $selected){return}
  $isPlaceholder=$false
  if($null -ne $selected.PSObject.Properties['placeholder']){ $isPlaceholder=($selected.placeholder -eq $true) }
  if($isPlaceholder){return}
  if(-not $selected.path -or -not(Test-Path ([string]$selected.path))){
   [Windows.MessageBox]::Show('No application path has been configured. Open ADMIN to set the executable for this tile.','BMW Launcher','OK','Information')|Out-Null
   return
  }
  try {Start-Process -FilePath ([string]$selected.path) -WorkingDirectory (Split-Path ([string]$selected.path) -Parent)}
  catch {[Windows.MessageBox]::Show($_.Exception.Message,'Unable to launch')|Out-Null}
 })
 return $btn
}

function Render-Cards {
 $tiles.Items.Clear()
 $shown=0
 foreach($app in $script:apps){if($app.enabled -ne $false){$tiles.Items.Add((Make-Card $app))|Out-Null;$shown++}}
 $empty=$window.FindName('EmptyState')
 if($empty){
  if($shown -eq 0){
   $empty.Visibility='Visible'
   $detail=$window.FindName('EmptyStateDetail')
   if($detail){
    if(Test-Path -LiteralPath $config){ $detail.Text='No tiles are enabled. Open ADMIN to add a diagnostic application or turn its tile on.' }
    else { $detail.Text='apps.json was not found on this workstation. Open ADMIN and choose Save & Close to create it, then add a diagnostic application.' }
   }
  } else { $empty.Visibility='Collapsed' }
 }
}
# Round the opaque admin dialog with DWM on Windows 11 and a region clip on Windows 10.
# Do not set AllowsTransparency. An owned transparent window crashes when Home is fullscreen.
if (-not ("BMW.AdminRound" -as [type])) {
 Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace BMW {
  public static class AdminRound {
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWCP_ROUND = 2;
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);
    [DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr hwnd, IntPtr hrgn, bool redraw);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    public static void Apply(IntPtr hwnd, int radiusPx) {
      if (hwnd == IntPtr.Zero) return;
      try { int pref = DWMWCP_ROUND; DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref pref, 4); } catch { }
      try {
        RECT rc;
        if (!GetClientRect(hwnd, out rc)) return;
        int w = rc.Right - rc.Left;
        int h = rc.Bottom - rc.Top;
        if (w < 8 || h < 8) return;
        // Ellipse width and height are diameters. 16px corners need 32.
        int diameter = radiusPx * 2;
        if (diameter < 2) diameter = 2;
        IntPtr rgn = CreateRoundRectRgn(0, 0, w + 1, h + 1, diameter, diameter);
        if (rgn != IntPtr.Zero) SetWindowRgn(hwnd, rgn, true);
      } catch { }
    }
  }
}
"@
}
function Admin-Dialog {
 $x=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="BMW Launcher Administration" Width="830" Height="780" WindowStartupLocation="CenterOwner" WindowStyle="None" ResizeMode="NoResize" BorderThickness="0" ShowInTaskbar="True" Background="#E8EDF3" Foreground="#172536" FontFamily="Segoe UI">
<Border BorderBrush="Transparent" BorderThickness="0" Background="#E8EDF3" CornerRadius="16">
<Grid Margin="24"><Grid.RowDefinitions><RowDefinition Height="65"/><RowDefinition Height="*"/><RowDefinition Height="52"/></Grid.RowDefinitions>
<StackPanel x:Name="DragHeader" Grid.Row="0"><TextBlock Text="LAUNCHER SETTINGS" FontSize="25" FontWeight="Light"/><TextBlock Text="Choose a tile, edit its details, then Save Changes" Foreground="#34465A" FontSize="12"/></StackPanel>
<Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition Width="220"/><ColumnDefinition Width="18"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<DockPanel Grid.Column="0"><StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0"><Button x:Name="Add" Content="+ ADD" Width="88" Margin="0,0,5,0"/><Button x:Name="Remove" Content="REMOVE" Width="88"/></StackPanel><ListBox x:Name="AppList" Background="#FFFFFF" Foreground="#172536" BorderBrush="#AAB8C8" FontSize="14"/></DockPanel>
<StackPanel Grid.Column="2" VerticalAlignment="Top">
<TextBlock Text="DISPLAY NAME" Foreground="#34465A" FontSize="11" Margin="0,0,0,5"/><TextBox x:Name="NameInput" FontSize="15" Padding="10" Margin="0,0,0,15"/>
<TextBlock Text="APPLICATION PATH" Foreground="#34465A" FontSize="11" Margin="0,0,0,5"/><DockPanel Margin="0,0,0,15"><Button x:Name="BrowseApp" DockPanel.Dock="Right" Width="78" Content="BROWSE"/><TextBox x:Name="PathInput" FontSize="13" Padding="8"/></DockPanel>
<TextBlock Text="CUSTOM ICON (PNG / JPG / ICO)" Foreground="#34465A" FontSize="11" Margin="0,0,0,5"/><DockPanel Margin="0,0,0,15"><Button x:Name="BrowseIcon" DockPanel.Dock="Right" Width="78" Content="BROWSE"/><TextBox x:Name="IconInput" FontSize="13" Padding="8"/></DockPanel>
<TextBlock Text="DESCRIPTION (OPTIONAL)" Foreground="#34465A" FontSize="11" Margin="0,0,0,5"/><TextBox x:Name="DescriptionInput" FontSize="13" Padding="8" Margin="0,0,0,8" MaxLength="150"/>
<CheckBox x:Name="ShowDescriptionInput" Content="Show description under app name" Margin="0,0,0,10" IsChecked="True"/>
<CheckBox x:Name="EnabledInput" Content="Show tile on the dashboard" Margin="0,0,0,14" IsChecked="True"/>
<StackPanel Orientation="Horizontal"><Button x:Name="ApplyTile" Content="APPLY TILE CHANGES" Padding="16,8" Margin="0,0,8,0"/><Button x:Name="MoveUp" Content="MOVE UP" Padding="12,8" Margin="0,0,8,0"/><Button x:Name="MoveDown" Content="MOVE DOWN" Padding="12,8"/></StackPanel>
<CheckBox x:Name="BoldCardTextInput" Content="Bold description text on home cards" Margin="0,12,0,10" IsChecked="False" MinHeight="48" VerticalContentAlignment="Center"/>
<TextBlock Text="Tip: Custom icon images look best with a transparent background. Existing saved application paths are preserved." TextWrapping="Wrap" Foreground="#526579" Margin="0,12,0,0"/>
</StackPanel></Grid>
<DockPanel Grid.Row="2" LastChildFill="False" VerticalAlignment="Bottom"><TextBlock DockPanel.Dock="Left" Foreground="#526579" VerticalAlignment="Center" Text="Changes apply to this Windows installation only."/><Button x:Name="SaveClose" DockPanel.Dock="Right" Content="SAVE &amp; CLOSE" Padding="22,10"/></DockPanel>
</Grid></Border></Window>
'@
 $dlg=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader ([xml]$x)))
 $dlg.Owner=$window
 try {
  $dlg.Add_SourceInitialized({
   param($s,$e)
   try {
    $hwnd=([System.Windows.Interop.WindowInteropHelper]$s).Handle
    [BMW.AdminRound]::Apply($hwnd, 16)
   } catch {}
  }.GetNewClosure())
  $dlg.Add_SizeChanged({
   param($s,$e)
   try {
    $hwnd=([System.Windows.Interop.WindowInteropHelper]$s).Handle
    if($hwnd -ne [IntPtr]::Zero){ [BMW.AdminRound]::Apply($hwnd, 16) }
   } catch {}
  }.GetNewClosure())
 } catch {}
 $dlg.FindName('DragHeader').Add_MouseLeftButtonDown({ param($sender,$evt) if($evt.ButtonState -eq 'Pressed'){ $dlg.DragMove() } }.GetNewClosure())
 $lst=$dlg.FindName('AppList');$nm=$dlg.FindName('NameInput');$pa=$dlg.FindName('PathInput');$ic=$dlg.FindName('IconInput');$en=$dlg.FindName('EnabledInput');$ds=$dlg.FindName('DescriptionInput');$sd=$dlg.FindName('ShowDescriptionInput');$boldCard=$dlg.FindName('BoldCardTextInput'); if($boldCard){$boldCard.IsChecked=[bool]$script:boldCardDescription}
 $script:editingApps=New-Object System.Collections.ArrayList
 foreach($a in $script:apps){[void]$script:editingApps.Add([pscustomobject]@{name=[string]$a.name;path=[string]$a.path;icon=[string]$a.icon;symbol=[string]$a.symbol;enabled=($a.enabled -ne $false);description=[string]$a.description;showDescription=($a.showDescription -ne $false);placeholder=($a.placeholder -eq $true)})}
 function Refresh-List { $idx=$lst.SelectedIndex;$lst.Items.Clear();foreach($a in $script:editingApps){[void]$lst.Items.Add($a.name)};if($lst.Items.Count -gt 0){$lst.SelectedIndex=[Math]::Max(0,[Math]::Min($idx,$lst.Items.Count-1))} }
 function Apply-Fields { $i=$lst.SelectedIndex;if($i -lt 0){return};$a=$script:editingApps[$i];if([string]::IsNullOrWhiteSpace($nm.Text)){[Windows.MessageBox]::Show('Tile name cannot be empty.')|Out-Null;return};$a.name=$nm.Text.Trim();$a.path=$pa.Text.Trim();if(-not [string]::IsNullOrWhiteSpace($a.path)){$a.placeholder=$false};$a.icon=$ic.Text.Trim();$a.enabled=($en.IsChecked -eq $true);$a.description=$ds.Text.Trim();$a.showDescription=($sd.IsChecked -eq $true);$lst.Items[$i]=$a.name }
 $lst.Add_SelectionChanged({$i=$lst.SelectedIndex;if($i -ge 0 -and $i -lt $script:editingApps.Count){$a=$script:editingApps[$i];$nm.Text=$a.name;$pa.Text=$a.path;$ic.Text=$a.icon;$en.IsChecked=$a.enabled;$ds.Text=$a.description;$sd.IsChecked=$a.showDescription}})
 $dlg.FindName('BrowseApp').Add_Click({$p=File-Pick $pa.Text;if($p){$pa.Text=$p}})
 $dlg.FindName('BrowseIcon').Add_Click({$p=File-Pick $ic.Text $true;if($p){$ic.Text=$p}})
 $dlg.FindName('ApplyTile').Add_Click({Apply-Fields})
 $dlg.FindName('Add').Add_Click({[void]$script:editingApps.Add([pscustomobject]@{name='New App';path='';icon='';symbol='APP';enabled=$true;description='';showDescription=$false;placeholder=$false});Refresh-List;$lst.SelectedIndex=$script:editingApps.Count-1})
 $dlg.FindName('Remove').Add_Click({$i=$lst.SelectedIndex;if($i -ge 0){$script:editingApps.RemoveAt($i);Refresh-List}})
 $dlg.FindName('MoveUp').Add_Click({$i=$lst.SelectedIndex;if($i -gt 0){$a=$script:editingApps[$i];$script:editingApps.RemoveAt($i);$script:editingApps.Insert($i-1,$a);Refresh-List;$lst.SelectedIndex=$i-1}})
 $dlg.FindName('MoveDown').Add_Click({$i=$lst.SelectedIndex;if($i -ge 0 -and $i -lt $script:editingApps.Count-1){$a=$script:editingApps[$i];$script:editingApps.RemoveAt($i);$script:editingApps.Insert($i+1,$a);Refresh-List;$lst.SelectedIndex=$i+1}})
 $dlg.FindName('SaveClose').Add_Click({Apply-Fields;$script:apps=@($script:editingApps.ToArray());Save-Apps;$bc=$dlg.FindName('BoldCardTextInput'); if($bc){$script:boldCardDescription=($bc.IsChecked -eq $true);Save-Profile};Render-Cards;$dlg.Close()})
 Refresh-List
 [void]$dlg.ShowDialog()
}
# BMW SYSTEM PANEL V2: redesigned grouped vertical flyout.
. (Join-Path $root 'SystemPanel.ps1')
$script:bmwSystemPopup=New-WorkstationSystemPopup -Anchor $systemButton
$systemButton.Add_Click({
 # Ensure the popup remains anchored above the SYSTEM button after resize / DPI changes.
 $script:bmwSystemPopup.PlacementTarget=$systemButton
 $script:bmwSystemPopup.IsOpen=-not $script:bmwSystemPopup.IsOpen
 if($script:bmwSystemPopup.IsOpen){$script:bmwSystemPopup.Focus() | Out-Null}
})
$adminButton.Add_Click({Admin-Dialog})
# Desktop shortcut intentionally disabled; switching is handled by the separate dock.
$window.Add_StateChanged({if($window.WindowState -eq 'Maximized'){Taskbar $true}})
$window.Add_Closed({Taskbar $false})
$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromSeconds(30);$timer.Add_Tick({$clock.Text=Get-Date -Format 'ddd, MMM d   h:mm tt'});$clock.Text=Get-Date -Format 'ddd, MMM d   h:mm tt';$timer.Start()
Load-Apps;Load-Profile;Apply-Wallpaper;Render-Cards
Taskbar $true
try {[void]$window.ShowDialog()}finally{Taskbar $false}
