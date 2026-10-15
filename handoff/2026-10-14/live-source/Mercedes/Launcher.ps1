# Universal Diagnostic Launcher v2 | Windows PowerShell 5.1 | WPF
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
Add-Type @'
using System;using System.Runtime.InteropServices;
public static class UniversalNative {
 [DllImport("user32.dll",CharSet=CharSet.Auto)] public static extern IntPtr FindWindow(string cls,string title);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd,int command);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] icons, uint[] ids, uint count, uint flags);
 [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
}
'@
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$config=Join-Path $root 'apps.json'
$brandProfile=Get-Content -LiteralPath (Join-Path $root 'profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$script:brandName=[string]$brandProfile.displayName
$brandShort=[string]$brandProfile.short
$accent=if($brandProfile.accent){[string]$brandProfile.accent}else{'#45ADFF'}
$accentSoft=if($brandProfile.accentSoft){[string]$brandProfile.accentSoft}else{'#9FD7FF'}
$logoPath=Join-Path $root ([string]$brandProfile.logo)
$homeTitle=$brandName+' Diagnostic System' 
$script:apps=@()
$script:hidden=$false
function Taskbar([bool]$hide) {
 $action=if($hide){0}else{5}
 foreach($cls in @('Shell_TrayWnd','Shell_SecondaryTrayWnd')) {
  $hw=[UniversalNative]::FindWindow($cls,$null)
  if($hw -ne [IntPtr]::Zero){[void][UniversalNative]::ShowWindow($hw,$action)}
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
function Brush($value){New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($value))}
function Image-Source($path) {
 if(-not $path -or -not(Test-Path -LiteralPath $path)){return $null}
 try {
  if([IO.Path]::GetExtension($path) -ieq '.exe'){
   # Ask Windows for a high-resolution native icon before using its tiny associated icon.
   $handles=New-Object 'IntPtr[]' 1
   $ids=New-Object 'uint32[]' 1
   try {
    $count=[UniversalNative]::PrivateExtractIcons($path,0,256,256,$handles,$ids,1,0)
    if($count -gt 0 -and $handles[0] -ne [IntPtr]::Zero){
     $bitmap=[Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($handles[0],[Windows.Int32Rect]::Empty,[Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
     $bitmap.Freeze();return $bitmap
    }
   } finally {if($handles[0] -ne [IntPtr]::Zero){[void][UniversalNative]::DestroyIcon($handles[0])}}
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
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="UNIVERSAL_HOME_TITLE" WindowStyle="None" WindowState="Maximized" ResizeMode="NoResize" ShowInTaskbar="True" Background="#080D14" FontFamily="Segoe UI">
 <Window.Resources>
  <Style x:Key="Tile" TargetType="Button">
   <Setter Property="Background" Value="#E51A2637"/><Setter Property="BorderBrush" Value="THEME_ACCENT_SOFT"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="11"/><Setter Property="Padding" Value="17"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="surface" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="19" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/></Border><ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="surface" Property="Background" Value="#F020344C"/><Setter TargetName="surface" Property="BorderBrush" Value="THEME_ACCENT_SOFT"/></Trigger>
     <Trigger Property="IsPressed" Value="True"><Setter TargetName="surface" Property="Background" Value="#F0284C73"/></Trigger>
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
  <Border VerticalAlignment="Top" Height="70" Background="Transparent"/>

  <Grid Margin="35,13,35,21">
   <Grid.RowDefinitions><RowDefinition Height="58"/><RowDefinition Height="*"/><RowDefinition Height="60"/></Grid.RowDefinitions>
   <Grid Grid.Row="0">
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <Border Grid.Column="0" Width="48" Height="48" CornerRadius="24" BorderBrush="Transparent" BorderThickness="0" Background="Transparent" Padding="0"><Image x:Name="HeaderBrandLogo" Stretch="UniformToFill" RenderOptions.BitmapScalingMode="HighQuality"/></Border>
    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="13,0,0,0">
      <Border Width="1" Background="THEME_ACCENT" Margin="0,7,13,7"/>
      <StackPanel VerticalAlignment="Center"><TextBlock Text="UNIVERSAL_BRAND_LABEL" FontSize="21" FontWeight="SemiBold" Foreground="#F3F8FF"/><TextBlock Text="DIAGNOSTIC WORKSTATION" FontSize="9" FontWeight="SemiBold" Foreground="THEME_ACCENT_SOFT"/></StackPanel>
    </StackPanel>
    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Right"><Border Width="1" Height="37" Margin="0,0,15,0" Background="#7BBDD8F2"/><StackPanel VerticalAlignment="Center"><TextBlock Text="LOCAL TIME" HorizontalAlignment="Right" Foreground="#AAC8E0" FontSize="9"/><TextBlock x:Name="Clock" HorizontalAlignment="Right" Foreground="#F3F8FF" FontSize="15" FontWeight="SemiBold"/></StackPanel></StackPanel>
   </Grid>
   <Grid Grid.Row="1">
     <ScrollViewer HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Center"><ItemsControl x:Name="Tiles" HorizontalAlignment="Center" VerticalAlignment="Center"><ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel HorizontalAlignment="Center"/></ItemsPanelTemplate></ItemsControl.ItemsPanel></ItemsControl></ScrollViewer>
     <StackPanel x:Name="EmptyState" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed" Margin="12" MaxWidth="530">
      <Border Background="#B7122436" BorderBrush="THEME_ACCENT_SOFT" BorderThickness="1" CornerRadius="18" Padding="24">
       <StackPanel><TextBlock Text="READY FOR DIAGNOSTICS" HorizontalAlignment="Center" Foreground="#F2F7FF" FontSize="24" FontWeight="Light"/><TextBlock Text="Your diagnostic workspace is ready. Open ADMIN to add a diagnostic application, choose an icon, and launch it from here." TextAlignment="Center" TextWrapping="Wrap" Foreground="#B3C6DC" FontSize="13" Margin="12,12,12,0"/></StackPanel>
      </Border>
     </StackPanel>
   </Grid>
   <DockPanel Grid.Row="2" LastChildFill="False" VerticalAlignment="Bottom" Margin="0,0,0,3">
    <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center"><Border Width="22" Height="2" Background="#C0C6CE" Margin="0,0,10,0"/><TextBlock x:Name="FooterUpdateStatus" Foreground="#AFC6DF" FontSize="11" VerticalAlignment="Center" Text="Checking" TextTrimming="CharacterEllipsis" MaxWidth="560"/></StackPanel>
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
# Brand values are escaped for safe inclusion as XAML text and attributes.
$escBrand=[Security.SecurityElement]::Escape($brandName)
$escShort=[Security.SecurityElement]::Escape($brandShort)
$windowXaml=$windowXaml.Replace('THEME_ACCENT_SOFT',$accentSoft).Replace('THEME_ACCENT',$accent)
$windowXaml=$windowXaml.Replace('UNIVERSAL_HOME_TITLE',[Security.SecurityElement]::Escape($homeTitle)).Replace('UNIVERSAL_BRAND_LABEL',$escBrand).Replace('UNIVERSAL_BRAND_SHORT',$escShort)
# WPF TextBlock doesn't support LetterSpacing; remove attribute before loading.
$windowXaml=$windowXaml -replace ' LetterSpacing="1"',''
$window=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader ([xml]$windowXaml)))
# Load the selected brand mark from a local packaged asset; fail visibly if absent.
if(-not (Test-Path -LiteralPath $logoPath)){throw "Missing brand logo: $logoPath"}
$headerLogo=$window.FindName('HeaderBrandLogo')
if(-not $headerLogo){throw 'HeaderBrandLogo element missing'}
$headerLogo.Source=Image-Source $logoPath
if(-not $headerLogo.Source){throw "Could not load brand logo: $logoPath"}

# MERCEDES-WORKSTATION-FOOTER-UPDATE-STATUS-v3
try {
 $script:workstationRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
 $script:workstationLabel=$window.FindName('FooterUpdateStatus')
 if(-not $script:workstationLabel){throw 'FooterUpdateStatus is missing'}
 $script:workstationStatusTimer=New-Object Windows.Threading.DispatcherTimer
 $script:workstationStatusTimer.Interval=[TimeSpan]::FromSeconds(12)
 $script:workstationStatusTimer.Add_Tick({
  try {
   $v=(Get-Content (Join-Path $script:workstationRoot 'version.json') -Raw | ConvertFrom-Json).version
   $s='Checking'
   $sp=Join-Path $script:workstationRoot 'update-status.json'
   if(Test-Path $sp){
    $st=Get-Content $sp -Raw | ConvertFrom-Json
    switch($st.state){'current'{$s='Up to date'} 'available'{$s='Update available'} 'restart'{$s='Restart to finish'} 'error'{$s='Unavailable'} 'unconfigured'{$s='No release'} 'offline'{$s='Offline'} default{$s='Checking'}}
   }
   $script:workstationLabel.Text=('v'+$v+'  |  '+$s)
  } catch {$script:workstationLabel.Text='Status unavailable'}
 })
 $window.Add_Loaded({
  $script:workstationStatusTimer.Start()
  try {
   $v=(Get-Content (Join-Path $script:workstationRoot 'version.json') -Raw | ConvertFrom-Json).version
   $script:workstationLabel.Text=('v'+$v+'  |  Checking')
  }catch{$script:workstationLabel.Text='Status unavailable'}
  # UpdateAgent is started and monitored by WorkstationManager.exe. No hidden WPF windows.
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
 $btn.Width=326
 $btn.Height=132
 $btn.Margin='12,10,12,10'
 $btn.Padding='0'
 $btn.Tag=[string]$app.name

 $content=New-Object System.Windows.Controls.Grid
 $content.Margin='15,12,15,12'
 $content.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)) | Out-Null
 $leftCol=$content.ColumnDefinitions[0]
 $leftCol.Width=New-Object System.Windows.GridLength(88)
 $rightCol=New-Object System.Windows.Controls.ColumnDefinition
 $rightCol.Width=New-Object System.Windows.GridLength(1,[System.Windows.GridUnitType]::Star)
 [void]$content.ColumnDefinitions.Add($rightCol)

 $iconPanel=New-Object System.Windows.Controls.Border
 $iconPanel.Width=76;$iconPanel.Height=76
 $iconPanel.CornerRadius=New-Object System.Windows.CornerRadius(15)
 $iconPanel.Background=Brush '#EC070D17'
 $iconPanel.BorderBrush=Brush '#5771A7C7'
 $iconPanel.BorderThickness=New-Object System.Windows.Thickness(1)
 $iconPanel.VerticalAlignment='Center';$iconPanel.HorizontalAlignment='Left'

 $icon=Image-Source ([string]$app.icon)
 if(-not $icon){$icon=Image-Source ([string]$app.path)}
 if($icon){
  $picture=New-Object System.Windows.Controls.Image
  $picture.Source=$icon;$picture.Stretch='Uniform'
  [Windows.Media.RenderOptions]::SetBitmapScalingMode($picture,[Windows.Media.BitmapScalingMode]::HighQuality)
  $picture.SnapsToDevicePixels=$true
  $picture.Width=68;$picture.Height=68
  if($icon.PixelWidth -lt 64 -or $icon.PixelHeight -lt 64){$picture.Width=[Math]::Min(48,$icon.PixelWidth);$picture.Height=[Math]::Min(48,$icon.PixelHeight)}
  $picture.HorizontalAlignment='Center';$picture.VerticalAlignment='Center'
  $iconPanel.Child=$picture
 } else {
  $glyph=New-Object System.Windows.Controls.TextBlock
  $glyph.Text=if($app.symbol){[string]$app.symbol}else{[string]$app.name.Substring(0,[Math]::Min(2,$app.name.Length))}
  $glyph.Foreground=Brush '#E4F0FF';$glyph.FontWeight='SemiBold';$glyph.FontSize=28
  $glyph.HorizontalAlignment='Center';$glyph.VerticalAlignment='Center'
  $iconPanel.Child=$glyph
 }
 [System.Windows.Controls.Grid]::SetColumn($iconPanel,0)
 [void]$content.Children.Add($iconPanel)

 $right=New-Object System.Windows.Controls.Grid
 $right.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
 $secondRow=New-Object System.Windows.Controls.RowDefinition
 $secondRow.Height=[System.Windows.GridLength]::Auto
 [void]$right.RowDefinitions.Add($secondRow)
 [System.Windows.Controls.Grid]::SetColumn($right,1)

 $heading=New-Object System.Windows.Controls.StackPanel
 $heading.VerticalAlignment='Center'
 $name=New-Object System.Windows.Controls.TextBlock
 $name.Text=[string]$app.name;$name.FontFamily='Segoe UI'
 $name.Foreground=Brush '#F7FBFF';$name.FontSize=22;$name.FontWeight='SemiBold'
 $name.TextTrimming='CharacterEllipsis'
 $heading.Children.Add($name)|Out-Null
 $detail=New-Object System.Windows.Controls.TextBlock
 $showDetail=$true
 if($null -ne $app.PSObject.Properties['showDescription']){$showDetail=($app.showDescription -ne $false)}
 $description=[string]$app.description
 $detail.Text=$description
 $detail.Visibility=if($showDetail -and -not [string]::IsNullOrWhiteSpace($description)){'Visible'}else{'Collapsed'}
 $detail.Foreground=Brush '#9DBDDC';$detail.FontSize=9.5;$detail.Margin='0,5,0,0'
 [void]$heading.Children.Add($detail)
 [System.Windows.Controls.Grid]::SetRow($heading,0)
 [void]$right.Children.Add($heading)

 $footer=New-Object System.Windows.Controls.StackPanel
 $footer.Orientation='Horizontal';$footer.Margin='0,6,0,0'
 $line=New-Object System.Windows.Controls.Border
 $line.Width=19;$line.Height=2;$line.CornerRadius=New-Object System.Windows.CornerRadius(2)
 $line.Background=Brush '#C0C6CE';$line.VerticalAlignment='Center';$line.Margin='0,0,8,0'
 [void]$footer.Children.Add($line)
 $action=New-Object System.Windows.Controls.TextBlock
 $action.Text=if($app.path -and (Test-Path ([string]$app.path))){'OPEN APPLICATION  >'}else{'CONFIGURE IN ADMIN'}
 $action.Foreground=Brush '#D0D5DB';$action.FontSize=10
 [void]$footer.Children.Add($action)
 [System.Windows.Controls.Grid]::SetRow($footer,1)
 [void]$right.Children.Add($footer)
 [void]$content.Children.Add($right)
 $btn.Content=$content

 $btn.Add_Click({
  param($sender,$ev)
  $selected=$script:apps | Where-Object { $_.name -eq $sender.Tag } | Select-Object -First 1
  if(-not $selected){return}
  if(-not $selected.path -or -not(Test-Path ([string]$selected.path))){
   [Windows.MessageBox]::Show('No application path has been configured. Open ADMIN to set the executable for this tile.','Workstation Launcher','OK','Information')|Out-Null
   return
  }
  try {Start-Process -FilePath ([string]$selected.path) -WorkingDirectory (Split-Path ([string]$selected.path) -Parent)}
  catch {[Windows.MessageBox]::Show($_.Exception.Message,'Unable to launch')|Out-Null}
 })
 return $btn
}

function Render-Cards {
 $tiles.Items.Clear()
 foreach($app in $script:apps){if($app.enabled -ne $false){$tiles.Items.Add((Make-Card $app))|Out-Null}}
 if ($window.FindName('EmptyState')) { $window.FindName('EmptyState').Visibility = 'Collapsed' }
}
function Admin-Dialog {
 # Centered on Home (Owner + CenterOwner). Not fullscreen. Dark Mercedes chrome, PowerShell 5.1.
 $x=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Workstation Administration" Width="690" Height="570" MinWidth="600" MinHeight="480" WindowStartupLocation="CenterOwner" WindowStyle="None" ResizeMode="CanResize" WindowState="Normal" ShowInTaskbar="True" Background="#0C121C" Foreground="#F4F8FC" FontFamily="Segoe UI" UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
<Window.Resources>
 <Style x:Key="AdminButton" TargetType="Button">
  <Setter Property="Foreground" Value="#E7F0FA"/>
  <Setter Property="Background" Value="#223246"/>
  <Setter Property="BorderBrush" Value="#5C7390"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="FontSize" Value="9.75"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="MinHeight" Value="34"/>
  <Setter Property="Padding" Value="12,6"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
   <Setter.Value>
    <ControlTemplate TargetType="Button">
     <Border x:Name="BdAdmin" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7.5" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
     </Border>
     <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="BdAdmin" Property="Background" Value="#314862"/></Trigger>
      <Trigger Property="IsPressed" Value="True"><Setter TargetName="BdAdmin" Property="Background" Value="#3E5A78"/></Trigger>
      <Trigger Property="IsEnabled" Value="False"><Setter TargetName="BdAdmin" Property="Opacity" Value="0.45"/></Trigger>
     </ControlTemplate.Triggers>
    </ControlTemplate>
   </Setter.Value>
  </Setter>
 </Style>
 <Style x:Key="AdminPrimary" TargetType="Button">
  <Setter Property="Foreground" Value="#0D1623"/>
  <Setter Property="Background" Value="THEME_ACCENT"/>
  <Setter Property="BorderBrush" Value="THEME_ACCENT"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="FontSize" Value="9.75"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="MinHeight" Value="36"/>
  <Setter Property="MinWidth" Value="126"/>
  <Setter Property="Padding" Value="16.5,7.5"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
   <Setter.Value>
    <ControlTemplate TargetType="Button">
     <Border x:Name="BdPrimary" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
     </Border>
     <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="BdPrimary" Property="Background" Value="#FFFFFF"/></Trigger>
      <Trigger Property="IsPressed" Value="True"><Setter TargetName="BdPrimary" Property="Background" Value="THEME_ACCENT_SOFT"/></Trigger>
     </ControlTemplate.Triggers>
    </ControlTemplate>
   </Setter.Value>
  </Setter>
 </Style>
 <Style x:Key="FieldLabel" TargetType="TextBlock">
  <Setter Property="Foreground" Value="#9BB3C9"/>
  <Setter Property="FontSize" Value="8.25"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Margin" Value="0,0,0,4.5"/>
 </Style>
 <Style TargetType="TextBox">
  <Setter Property="Background" Value="#17273A"/>
  <Setter Property="Foreground" Value="#F4F8FC"/>
  <Setter Property="BorderBrush" Value="#5C7390"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="Padding" Value="9,7.5"/>
  <Setter Property="FontSize" Value="11.25"/>
  <Setter Property="MinHeight" Value="34"/>
  <Setter Property="CaretBrush" Value="#F4F8FC"/>
  <Setter Property="SelectionBrush" Value="#5C7390"/>
 </Style>
 <Style TargetType="CheckBox">
  <Setter Property="Foreground" Value="#E7F0FA"/>
  <Setter Property="FontSize" Value="10.5"/>
  <Setter Property="MinHeight" Value="34"/>
  <Setter Property="Cursor" Value="Hand"/>
 </Style>
 <Style TargetType="ListBoxItem">
  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
  <Setter Property="Padding" Value="6,4.5"/>
  <Setter Property="Margin" Value="1.5,2.25"/>
  <Setter Property="MinHeight" Value="42"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
   <Setter.Value>
    <ControlTemplate TargetType="ListBoxItem">
     <Border x:Name="BdItem" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" CornerRadius="7.5" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
      <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Center"/>
     </Border>
     <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="BdItem" Property="Background" Value="#1C2C3E"/></Trigger>
      <Trigger Property="IsSelected" Value="True"><Setter TargetName="BdItem" Property="Background" Value="#243246"/><Setter TargetName="BdItem" Property="BorderBrush" Value="THEME_ACCENT"/></Trigger>
     </ControlTemplate.Triggers>
    </ControlTemplate>
   </Setter.Value>
  </Setter>
 </Style>
</Window.Resources>
<Border BorderBrush="#6D8199" BorderThickness="1" Background="#0C121C">
<Grid Margin="21,16.5,21,15">
 <Grid.RowDefinitions>
  <RowDefinition Height="Auto"/>
  <RowDefinition Height="*"/>
  <RowDefinition Height="Auto"/>
 </Grid.RowDefinitions>
 <Grid Grid.Row="0" Margin="0,0,0,13.5">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <StackPanel x:Name="DragHeader" VerticalAlignment="Center">
   <StackPanel Orientation="Horizontal" Margin="0,0,0,4.5">
    <Border Width="13.5" Height="1.5" Background="THEME_ACCENT" VerticalAlignment="Center" Margin="0,0,7.5,0"/>
    <TextBlock Text="UNIVERSAL_BRAND_LABEL" FontSize="8.25" FontWeight="SemiBold" Foreground="THEME_ACCENT" VerticalAlignment="Center"/>
   </StackPanel>
   <TextBlock Text="LAUNCHER SETTINGS" FontSize="19.5" FontWeight="Light" Foreground="#F7FBFF"/>
   <TextBlock Text="Choose a tile, edit its details, then Save Changes" FontSize="9.75" Foreground="#9BB3C9" Margin="0,3,0,0" TextWrapping="Wrap"/>
  </StackPanel>
  <Button x:Name="CloseAdmin" Grid.Column="1" Content="&#x2715;" Width="34" Height="34" FontSize="12" VerticalAlignment="Top" Style="{StaticResource AdminButton}" Padding="0" ToolTip="Close"/>
 </Grid>
 <Grid Grid.Row="1">
  <Grid.ColumnDefinitions><ColumnDefinition Width="225"/><ColumnDefinition Width="16.5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <DockPanel Grid.Column="0">
   <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,9,0,0">
    <Button x:Name="Add" Content="+ ADD" MinWidth="84" Margin="0,0,6,0" Style="{StaticResource AdminButton}"/>
    <Button x:Name="Remove" Content="REMOVE" MinWidth="84" Style="{StaticResource AdminButton}"/>
   </StackPanel>
   <Border Background="#101826" BorderBrush="#3E5470" BorderThickness="1" CornerRadius="10.5" Padding="4.5">
    <Grid>
     <ListBox x:Name="AppList" Background="Transparent" Foreground="#F4F8FC" BorderThickness="0" FontSize="11.25" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
     <TextBlock x:Name="ListEmpty" Text="No tiles yet. Use + ADD to create one." TextWrapping="Wrap" TextAlignment="Center" Foreground="#8AA4BE" FontSize="9.75" Margin="12" VerticalAlignment="Center" HorizontalAlignment="Center" Visibility="Collapsed" IsHitTestVisible="False"/>
    </Grid>
   </Border>
  </DockPanel>
  <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
   <StackPanel>
    <TextBlock Text="DISPLAY NAME" Style="{StaticResource FieldLabel}"/><TextBox x:Name="NameInput" Margin="0,0,0,10.5"/>
    <TextBlock Text="APPLICATION PATH" Style="{StaticResource FieldLabel}"/>
    <DockPanel Margin="0,0,0,10.5" LastChildFill="True"><Button x:Name="BrowseApp" DockPanel.Dock="Right" Width="81" Margin="6,0,0,0" Content="BROWSE" Style="{StaticResource AdminButton}"/><TextBox x:Name="PathInput"/></DockPanel>
    <TextBlock Text="CUSTOM ICON (PNG / JPG / ICO)" Style="{StaticResource FieldLabel}"/>
    <DockPanel Margin="0,0,0,10.5" LastChildFill="True"><Button x:Name="BrowseIcon" DockPanel.Dock="Right" Width="81" Margin="6,0,0,0" Content="BROWSE" Style="{StaticResource AdminButton}"/><TextBox x:Name="IconInput"/></DockPanel>
    <TextBlock Text="DESCRIPTION (OPTIONAL)" Style="{StaticResource FieldLabel}"/><TextBox x:Name="DescriptionInput" Margin="0,0,0,9" MaxLength="150"/>
    <CheckBox x:Name="ShowDescriptionInput" Content="Show description under app name" Margin="0,0,0,6" IsChecked="True"/>
    <CheckBox x:Name="EnabledInput" Content="Show tile on the dashboard" Margin="0,0,0,12" IsChecked="True"/>
    <WrapPanel Orientation="Horizontal">
     <Button x:Name="ApplyTile" Content="APPLY TILE CHANGES" Margin="0,0,6,6" Style="{StaticResource AdminButton}"/>
     <Button x:Name="MoveUp" Content="MOVE UP" Margin="0,0,6,6" Style="{StaticResource AdminButton}"/>
     <Button x:Name="MoveDown" Content="MOVE DOWN" Margin="0,0,6,6" Style="{StaticResource AdminButton}"/>
    </WrapPanel>
    <TextBlock Text="Tip: Custom icon images look best with a transparent background. Existing saved application paths are preserved." TextWrapping="Wrap" Foreground="#8AA4BE" FontSize="9" Margin="0,6,0,0"/>
   </StackPanel>
  </ScrollViewer>
 </Grid>
 <DockPanel Grid.Row="2" LastChildFill="False" Margin="0,12,0,0">
  <TextBlock DockPanel.Dock="Left" Foreground="#8AA4BE" FontSize="9" VerticalAlignment="Center" TextWrapping="Wrap" MaxWidth="390" Text="Changes apply to this Windows installation only."/>
  <Button x:Name="SaveClose" DockPanel.Dock="Right" Content="SAVE &amp; CLOSE" Style="{StaticResource AdminPrimary}"/>
 </DockPanel>
</Grid>
</Border>
</Window>
'@
 $x=$x.Replace('THEME_ACCENT_SOFT',$accentSoft).Replace('THEME_ACCENT',$accent)
 $x=$x.Replace('UNIVERSAL_BRAND_LABEL',[Security.SecurityElement]::Escape([string]$script:brandName.ToUpperInvariant()))
 $dlg=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader ([xml]$x)))
 $dlg.Owner=$window
 $dlg.FindName('DragHeader').Add_MouseLeftButtonDown({ param($sender,$evt) if($evt.ButtonState -eq 'Pressed'){ $dlg.DragMove() } }.GetNewClosure())
 $dlg.FindName('CloseAdmin').Add_Click({ $dlg.Close() }.GetNewClosure())
 $lst=$dlg.FindName('AppList');$nm=$dlg.FindName('NameInput');$pa=$dlg.FindName('PathInput');$ic=$dlg.FindName('IconInput');$en=$dlg.FindName('EnabledInput');$ds=$dlg.FindName('DescriptionInput');$sd=$dlg.FindName('ShowDescriptionInput')
 $script:editingApps=New-Object System.Collections.ArrayList
 foreach($a in $script:apps){[void]$script:editingApps.Add([pscustomobject]@{name=[string]$a.name;path=[string]$a.path;icon=[string]$a.icon;symbol=[string]$a.symbol;enabled=($a.enabled -ne $false);description=[string]$a.description;showDescription=($a.showDescription -ne $false)})}
 function New-TileRow($app) {
  $row=New-Object System.Windows.Controls.Grid
  $row.MinHeight=34
  $c0=New-Object System.Windows.Controls.ColumnDefinition
  $c0.Width=New-Object System.Windows.GridLength(34.5)
  $c1=New-Object System.Windows.Controls.ColumnDefinition
  $c1.Width=New-Object System.Windows.GridLength(1,[System.Windows.GridUnitType]::Star)
  [void]$row.ColumnDefinitions.Add($c0)
  [void]$row.ColumnDefinitions.Add($c1)
  $badge=New-Object System.Windows.Controls.Border
  $badge.Width=27;$badge.Height=27
  $badge.CornerRadius=New-Object System.Windows.CornerRadius(7.5)
  $badge.Background=Brush '#1B3048'
  $badge.BorderBrush=Brush '#5C7390'
  $badge.BorderThickness=New-Object System.Windows.Thickness(1)
  $badge.VerticalAlignment='Center';$badge.HorizontalAlignment='Left'
  $icon=$null
  try { $icon=Image-Source ([string]$app.icon); if(-not $icon){$icon=Image-Source ([string]$app.path)} } catch { $icon=$null }
  if($icon){
   $img=New-Object System.Windows.Controls.Image
   $img.Source=$icon;$img.Width=19.5;$img.Height=19.5;$img.Stretch='Uniform'
   [Windows.Media.RenderOptions]::SetBitmapScalingMode($img,[Windows.Media.BitmapScalingMode]::HighQuality)
   $img.HorizontalAlignment='Center';$img.VerticalAlignment='Center'
   $badge.Child=$img
  } else {
   $letters='APP'
   $rawName=[string]$app.name
   if(-not [string]::IsNullOrWhiteSpace($rawName)){ $letters=$rawName.Substring(0,[Math]::Min(2,$rawName.Length)).ToUpperInvariant() }
   $glyph=New-Object System.Windows.Controls.TextBlock
   $glyph.Text=$letters;$glyph.Foreground=Brush '#E7F1FB';$glyph.FontWeight='SemiBold';$glyph.FontSize=9
   $glyph.HorizontalAlignment='Center';$glyph.VerticalAlignment='Center'
   $badge.Child=$glyph
  }
  [void]$row.Children.Add($badge)
  $stack=New-Object System.Windows.Controls.StackPanel
  $stack.VerticalAlignment='Center';$stack.Margin='7.5,0,6,0'
  $title=New-Object System.Windows.Controls.TextBlock
  $title.Text=[string]$app.name;$title.Foreground=Brush '#F4F8FC';$title.FontSize=11.25;$title.FontWeight='SemiBold';$title.TextTrimming='CharacterEllipsis'
  [void]$stack.Children.Add($title)
  $rawPath=[string]$app.path
  if(-not [string]::IsNullOrWhiteSpace($rawPath)){
   $sub=New-Object System.Windows.Controls.TextBlock
   try { $sub.Text=[IO.Path]::GetFileName($rawPath) } catch { $sub.Text=$rawPath }
   $sub.Foreground=Brush '#8AA4BE';$sub.FontSize=8.25;$sub.Margin='0,1.5,0,0';$sub.TextTrimming='CharacterEllipsis'
   [void]$stack.Children.Add($sub)
  }
  [System.Windows.Controls.Grid]::SetColumn($stack,1)
  [void]$row.Children.Add($stack)
  if($app.enabled -eq $false){ $row.Opacity=0.45 }
  return $row
 }
 function Refresh-List {
  $idx=$lst.SelectedIndex
  $lst.Items.Clear()
  foreach($a in $script:editingApps){[void]$lst.Items.Add((New-TileRow $a))}
  $empty=$dlg.FindName('ListEmpty')
  if($empty){ if($script:editingApps.Count -eq 0){$empty.Visibility='Visible'}else{$empty.Visibility='Collapsed'} }
  if($lst.Items.Count -gt 0){$lst.SelectedIndex=[Math]::Max(0,[Math]::Min($idx,$lst.Items.Count-1))}
 }
 function Apply-Fields {
  $i=$lst.SelectedIndex
  if($i -lt 0){return}
  $a=$script:editingApps[$i]
  if([string]::IsNullOrWhiteSpace($nm.Text)){[Windows.MessageBox]::Show('Tile name cannot be empty.')|Out-Null;return}
  $a.name=$nm.Text.Trim();$a.path=$pa.Text.Trim();$a.icon=$ic.Text.Trim();$a.enabled=($en.IsChecked -eq $true);$a.description=$ds.Text.Trim();$a.showDescription=($sd.IsChecked -eq $true)
  Refresh-List
 }
 $lst.Add_SelectionChanged({$i=$lst.SelectedIndex;if($i -ge 0 -and $i -lt $script:editingApps.Count){$a=$script:editingApps[$i];$nm.Text=$a.name;$pa.Text=$a.path;$ic.Text=$a.icon;$en.IsChecked=$a.enabled;$ds.Text=$a.description;$sd.IsChecked=$a.showDescription}})
 $dlg.FindName('BrowseApp').Add_Click({$p=File-Pick $pa.Text;if($p){$pa.Text=$p}})
 $dlg.FindName('BrowseIcon').Add_Click({$p=File-Pick $ic.Text $true;if($p){$ic.Text=$p}})
 $dlg.FindName('ApplyTile').Add_Click({Apply-Fields})
 $dlg.FindName('Add').Add_Click({[void]$script:editingApps.Add([pscustomobject]@{name='New App';path='';icon='';symbol='APP';enabled=$true;description='';showDescription=$false});Refresh-List;$lst.SelectedIndex=$script:editingApps.Count-1})
 $dlg.FindName('Remove').Add_Click({$i=$lst.SelectedIndex;if($i -ge 0){$script:editingApps.RemoveAt($i);Refresh-List}})
 $dlg.FindName('MoveUp').Add_Click({$i=$lst.SelectedIndex;if($i -gt 0){$a=$script:editingApps[$i];$script:editingApps.RemoveAt($i);$script:editingApps.Insert($i-1,$a);Refresh-List;$lst.SelectedIndex=$i-1}})
 $dlg.FindName('MoveDown').Add_Click({$i=$lst.SelectedIndex;if($i -ge 0 -and $i -lt $script:editingApps.Count-1){$a=$script:editingApps[$i];$script:editingApps.RemoveAt($i);$script:editingApps.Insert($i+1,$a);Refresh-List;$lst.SelectedIndex=$i+1}})
 $dlg.FindName('SaveClose').Add_Click({Apply-Fields;$script:apps=@($script:editingApps.ToArray());Save-Apps;Render-Cards;$dlg.Close()})
 Refresh-List
 [void]$dlg.ShowDialog()
}
# MERCEDES SYSTEM PANEL V2: redesigned grouped vertical flyout.
. (Join-Path $root 'SystemPanel.ps1')
$script:workstationSystemPopup=New-WorkstationSystemPopup -Anchor $systemButton
$systemButton.Add_Click({
 # Ensure the popup remains anchored above the SYSTEM button after resize / DPI changes.
 $script:workstationSystemPopup.PlacementTarget=$systemButton
 $script:workstationSystemPopup.IsOpen=-not $script:workstationSystemPopup.IsOpen
 if($script:workstationSystemPopup.IsOpen){$script:workstationSystemPopup.Focus() | Out-Null}
})
$adminButton.Add_Click({Admin-Dialog})
# Desktop shortcut intentionally disabled; switching is handled by the separate dock.
$window.Add_StateChanged({if($window.WindowState -eq 'Maximized'){Taskbar $true}})
$window.Add_Closed({Taskbar $false})
$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromSeconds(30);$timer.Add_Tick({$clock.Text=Get-Date -Format 'ddd, MMM d   h:mm tt'});$clock.Text=Get-Date -Format 'ddd, MMM d   h:mm tt';$timer.Start()
Load-Apps;Apply-Wallpaper;Render-Cards
Taskbar $true
try {[void]$window.ShowDialog()}finally{Taskbar $false}
