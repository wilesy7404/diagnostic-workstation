$profile=Get-Content -LiteralPath (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'profile.json') -Raw -Encoding UTF8|ConvertFrom-Json
$script:homeTitle=([string]$profile.displayName)+' Diagnostic System'
$script:brandShort=[string]$profile.short
$script:accent=if($profile.accent){[string]$profile.accent}else{'#45ADFF'}
$script:logoPath=Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) ([string]$profile.logo)
# Workstation Glass Dock v4 - animated auto-hide and touch reveal | Windows PowerShell 5.1
# Independent WPF taskbar-style application switcher
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Drawing,System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class UniversalGlassWin {
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd,int cmd);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll",CharSet=CharSet.Auto)] public static extern IntPtr FindWindow(string cls,string title);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd,out RECT rect);
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
}
'@

$xml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Workstation Glass Dock" UseLayoutRounding="True" Width="260" Height="61" SizeToContent="Width"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True"
        Background="Transparent" ShowInTaskbar="False" ShowActivated="False"
        Topmost="True" WindowStartupLocation="Manual" SnapsToDevicePixels="True">
 <Window.Resources>
  <Style x:Key="DockButton" TargetType="Button">
   <Setter Property="Width" Value="40"/><Setter Property="Height" Value="40"/>
   <Setter Property="Margin" Value="2,0"/><Setter Property="Padding" Value="0"/>
   <Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template"><Setter.Value>
    <ControlTemplate TargetType="Button">
     <Border x:Name="Bubble" CornerRadius="12" Background="{TemplateBinding Background}" BorderThickness="1" BorderBrush="Transparent">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
     </Border>
     <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bubble" Property="Background" Value="#334E7EBA"/><Setter TargetName="Bubble" Property="BorderBrush" Value="#667BA3D9"/></Trigger>
      <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bubble" Property="Background" Value="#665F91CF"/></Trigger>
     </ControlTemplate.Triggers>
    </ControlTemplate>
   </Setter.Value></Setter>
  </Style>
  <Style TargetType="MenuItem">
   <Setter Property="FontSize" Value="14"/><Setter Property="Padding" Value="13,10"/>
  </Style>
 </Window.Resources>
 <Border CornerRadius="20" Background="#F00C131E" BorderBrush="#59728AA8" BorderThickness="1"
         Padding="9,6" Margin="2">
  
  <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
   <Button x:Name="Home" Style="{StaticResource DockButton}" ToolTip="Workstation Home">
    <Grid Width="36" Height="38">
     
     
     <Image x:Name="DockBrandLogo" Width="34" Height="34" Stretch="Uniform" SnapsToDevicePixels="True" RenderOptions.BitmapScalingMode="Fant"/>
     <Border Width="14" Height="2" Background="THEME_ACCENT" CornerRadius="2" VerticalAlignment="Bottom" HorizontalAlignment="Center"/>
    </Grid>
   </Button>
   <Border Width="1" Height="25" Background="#4B71849E" Margin="6,0" VerticalAlignment="Center"/>
   <StackPanel x:Name="Running" Orientation="Horizontal" VerticalAlignment="Center"/>
   <Border Width="1" Height="25" Background="#4B71849E" Margin="6,0" VerticalAlignment="Center"/>
   <Button x:Name="WcBatteryButton" Style="{StaticResource DockButton}" ToolTip="Battery percentage">
     <TextBlock x:Name="WcBatteryPercent" Text="--" FontFamily="Segoe UI" FontSize="11" FontWeight="SemiBold" Foreground="#F2F6FC" TextAlignment="Center" HorizontalAlignment="Center" VerticalAlignment="Center" SnapsToDevicePixels="True" />
    </Button>
    <Button x:Name="System" Style="{StaticResource DockButton}" ToolTip="System controls">
    <TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#DDEAF9"/>
   </Button>
  </StackPanel>
 </Border>
</Window>
'@
$xml=$xml.Replace('THEME_ACCENT',$script:accent).Replace('UNIVERSAL_HOME_TITLE',[Security.SecurityElement]::Escape($script:homeTitle)).Replace('UNIVERSAL_BRAND_SHORT',[Security.SecurityElement]::Escape($script:brandShort))
$window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader ([xml]$xml)))
if(-not (Test-Path -LiteralPath $script:logoPath)){throw "Dock brand logo missing: $script:logoPath"}
$brandImg=$window.FindName('DockBrandLogo')
$bmp=New-Object Windows.Media.Imaging.BitmapImage
$bmp.BeginInit();$bmp.UriSource=New-Object Uri($script:logoPath);$bmp.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad;$bmp.EndInit();$bmp.Freeze()
$brandImg.Source=$bmp

$running = $window.FindName('Running')

function Activate-App([IntPtr]$h) {
 if($h -eq [IntPtr]::Zero){return}
 [void][UniversalGlassWin]::ShowWindow($h,9)
 [void][UniversalGlassWin]::SetForegroundWindow($h)
}
function Move-Dock {
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    $src = [System.Windows.PresentationSource]::FromVisual($window)

    $sx = 1.0
    $sy = 1.0

    if ($src -and $src.CompositionTarget) {
        $sx = $src.CompositionTarget.TransformFromDevice.M11
        $sy = $src.CompositionTarget.TransformFromDevice.M22
    }

    $bounds = $screen.Bounds
    $w = if ($window.ActualWidth -gt 0) {
        $window.ActualWidth
    } else {
        260
    }
    $h = if ($window.ActualHeight -gt 0) {
        $window.ActualHeight
    } else {
        61
    }

    $window.Left = ($bounds.Left * $sx) +
        (($bounds.Width * $sx - $w) / 2)

    $window.Top = ($bounds.Bottom * $sy) - $h - 6
}
function Get-Image([string]$p){
 if([string]::IsNullOrEmpty($p) -or -not (Test-Path -LiteralPath $p)){return $null}
 try {
  $ico=[System.Drawing.Icon]::ExtractAssociatedIcon($p)
  if(-not $ico){return $null}
  try {return [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle,[System.Windows.Int32Rect]::Empty,[System.Windows.Media.Imaging.BitmapSizeOptions]::FromWidthAndHeight(40,40))}
  finally {$ico.Dispose()}
 } catch {return $null}
}
function App-Button($p){
 $button=New-Object System.Windows.Controls.Button
 $button.Style=$window.FindResource('DockButton')
 $button.ToolTip=$p.MainWindowTitle
 $button.Tag=[IntPtr]$p.MainWindowHandle
 $grid=New-Object System.Windows.Controls.Grid
 $grid.Width=36;$grid.Height=38
 $imgSource=$null
 try {$imgSource=Get-Image $p.MainModule.FileName} catch {}
 if($imgSource){
  $img=New-Object System.Windows.Controls.Image
  $img.Width=25;$img.Height=25;$img.Stretch='Uniform';$img.Source=$imgSource
  $img.VerticalAlignment='Center';$img.HorizontalAlignment='Center'
  $grid.Children.Add($img)|Out-Null
 } else {
  $label=New-Object System.Windows.Controls.TextBlock
  $label.Text=$p.ProcessName.Substring(0,[Math]::Min(2,$p.ProcessName.Length)).ToUpperInvariant()
  $label.FontFamily='Segoe UI';$label.FontSize=15;$label.FontWeight='SemiBold'
  $label.Foreground=[System.Windows.Media.Brushes]::White
  $label.VerticalAlignment='Center';$label.HorizontalAlignment='Center'
  $grid.Children.Add($label)|Out-Null
 }
 $dot=New-Object System.Windows.Controls.Border
 $dot.Width=13;$dot.Height=2;$dot.CornerRadius='2'
 $dot.Background=[System.Windows.Media.Brushes]::DeepSkyBlue
 $dot.HorizontalAlignment='Center';$dot.VerticalAlignment='Bottom'
 $grid.Children.Add($dot)|Out-Null
 $button.Content=$grid
 $button.Add_Click({param($sender,$e) Activate-App ([IntPtr]$sender.Tag)})
 return $button
}

$window.FindName('Home').Add_Click({
 $handle=[UniversalGlassWin]::FindWindow($null,$script:homeTitle)
 if($handle -ne [IntPtr]::Zero){Activate-App $handle}
})
# MERCEDES-SAFE-CONTROLS-v1
function Invoke-MercedesDockControl([string]$mode) {
    $file=Join-Path $env:LOCALAPPDATA 'DiagnosticWorkstation\WorkstationControls.ps1'
    if(-not(Test-Path -LiteralPath $file)){throw "Workstation controls missing: $file"}
    $psExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-STA','-ExecutionPolicy','Bypass',"-File `"$file`"",'-Mode',$mode
    )
}
$window.FindName('WcBatteryButton').Add_Click({Invoke-MercedesDockControl 'Battery'})
$menu=New-Object System.Windows.Controls.ContextMenu
$choices=@(
 @{Text='Internet  -  Microsoft Edge';Cmd='edge'},
 @{Text='Control Panel';Cmd='control'},
 @{Text='Date and Time';Cmd='date'},
 @{Text='Network Connections';Cmd='network'},
 @{Text='Task Manager';Cmd='taskmgr'}
)
$choices+=@(
 @{Text='Wi-Fi & Internet';Cmd='wcwifi'},
 @{Text='Battery Status';Cmd='wcbattery'},
 @{Text='Windows Settings';Cmd='wcsettings'},
 @{Text='Windows Desktop (PIN)';Cmd='wcdesktop'},
 @{Text='Emergency Recovery';Cmd='wcrecovery'}
)
foreach($c in $choices){
 $m=New-Object System.Windows.Controls.MenuItem
 $m.Header=$c.Text
 $m.Tag=$c.Cmd
 $m.Add_Click({param($sender,$e)
  switch([string]$sender.Tag){
   edge {Start-Process 'microsoft-edge:https://www.google.com'}
   control {Start-Process 'control.exe'}
   date {Start-Process 'timedate.cpl'}
   network {Start-Process 'ncpa.cpl'}
   taskmgr {Start-Process 'taskmgr.exe'}
    wcwifi {Invoke-MercedesDockControl 'Wifi'}
    wcbattery {Invoke-MercedesDockControl 'Battery'}
    wcsettings {Invoke-MercedesDockControl 'Settings'}
    wcdesktop {Invoke-MercedesDockControl 'Desktop'}
    wcrecovery {Invoke-MercedesDockControl 'Recovery'}
  }
 })
 [void]$menu.Items.Add($m)
}
$window.FindName('System').Add_Click({param($sender,$e)
 $menu.PlacementTarget=$sender
 $menu.Placement=[System.Windows.Controls.Primitives.PlacementMode]::Top
 $menu.IsOpen=$true
})

# Animated fullscreen hide and accessible touch reveal zone.
# The strip is a separate topmost window, so it remains touchable when the dock is hidden.
$script:DockRevealedAt=Get-Date
$script:DockFullscreen=$false
$script:DockHidden=$false
$script:DockBusy=$false
$script:DockSlide=New-Object System.Windows.Media.TranslateTransform
$window.RenderTransform=$script:DockSlide

function Animate-Dock([bool]$visible) {
 if($visible -eq (-not $script:DockHidden)){return}
 $duration=[TimeSpan]::FromMilliseconds(220)
 $ease=New-Object System.Windows.Media.Animation.CubicEase
 $ease.EasingMode=[System.Windows.Media.Animation.EasingMode]::EaseOut
 $opacityAnim=New-Object System.Windows.Media.Animation.DoubleAnimation
 $opacityAnim.To=if($visible){1.0}else{0.0}
 $opacityAnim.Duration=New-Object System.Windows.Duration($duration)
 $opacityAnim.EasingFunction=$ease
 $slideAnim=New-Object System.Windows.Media.Animation.DoubleAnimation
 $slideAnim.To=if($visible){0.0}else{36.0}
 $slideAnim.Duration=New-Object System.Windows.Duration($duration)
 $slideAnim.EasingFunction=$ease
 if($visible){$window.IsHitTestVisible=$true}
 $window.BeginAnimation([System.Windows.Window]::OpacityProperty,$opacityAnim)
 $script:DockSlide.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty,$slideAnim)
 $script:DockHidden=-not $visible
 if($visible){$script:DockRevealedAt=Get-Date}
}
function Reveal-Dock { Animate-Dock $true }
function Conceal-Dock {
 if($menu.IsOpen -or $window.IsMouseOver){return}
 Animate-Dock $false
}
function Test-OtherFullscreen {
 # The MERCEDES dashboard must never trigger auto-hide.
 $home=[UniversalGlassWin]::FindWindow($null,$script:homeTitle)
 $hw=[UniversalGlassWin]::GetForegroundWindow()
 if($hw -eq [IntPtr]::Zero){return $false}
 if($home -ne [IntPtr]::Zero -and $hw -eq $home){return $false}

 # Ignore our own dock, reveal strip, and their menu windows. Preserve the
 # previous state only while interacting with dock controls.
 $self=([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle
 $edgeHandle=([System.Windows.Interop.WindowInteropHelper]::new($edge)).Handle
 if($hw -eq $self -or $hw -eq $edgeHandle -or $menu.IsOpen){return $script:DockFullscreen}

 # Compare the foreground application with the actual monitor bounds.
 $r=New-Object 'UniversalGlassWin+RECT'
 if(-not [UniversalGlassWin]::GetWindowRect($hw,[ref]$r)){return $false}
 $bounds=[System.Windows.Forms.Screen]::FromHandle($hw).Bounds
 $coversScreen=($r.Left -le ($bounds.Left+3) -and
  $r.Top -le ($bounds.Top+3) -and
  $r.Right -ge ($bounds.Right-3) -and
  $r.Bottom -ge ($bounds.Bottom-3))
 return $coversScreen
}

# 30 px-tall touch activation target (previously just 9 px).
# Bounded to the center of the display to avoid intercepting full-width bottom controls.
$edgeXml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 Title="Workstation Dock Touch Reveal" WindowStyle="None" ResizeMode="NoResize"
 AllowsTransparency="True" Background="#02000000"
 ShowInTaskbar="False" ShowActivated="False" Focusable="False" Topmost="True"
 Width="440" Height="30" WindowStartupLocation="Manual"/>
'@
$edge=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader ([xml]$edgeXml)))
function Place-Edge {
 $screen=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
 # WPF DIP conversion handles display scaling for positioning.
 $source=[System.Windows.PresentationSource]::FromVisual($window)
 $sx=1.0;$sy=1.0
 if($source -and $source.CompositionTarget){
  $sx=$source.CompositionTarget.TransformFromDevice.M11
  $sy=$source.CompositionTarget.TransformFromDevice.M22
 }
 $edge.Width=[Math]::Min(520, [Math]::Max(260, $screen.Width*$sx*0.55))
 $edge.Left=($screen.Left*$sx)+(($screen.Width*$sx-$edge.Width)/2)
 $edge.Top=($screen.Bottom*$sy)-$edge.Height
}
# TouchDown fires immediately on a bottom-edge touch. A genuine OS-level bezel
# swipe beginning outside the screen cannot be captured by WPF; touch near the bottom.
$edge.Add_PreviewTouchDown({Reveal-Dock; $script:DockRevealedAt=Get-Date})
$edge.Add_TouchDown({Reveal-Dock})
$edge.Add_PreviewStylusDown({Reveal-Dock})
$edge.Add_PreviewMouseDown({Reveal-Dock})
$edge.Add_MouseEnter({if($script:DockHidden){Reveal-Dock}})
$window.Add_MouseEnter({$script:DockRevealedAt=Get-Date})
$window.Add_TouchDown({$script:DockRevealedAt=Get-Date})
$window.Add_PreviewStylusDown({$script:DockRevealedAt=Get-Date})

$autoTimer=New-Object System.Windows.Threading.DispatcherTimer
$autoTimer.Interval=[TimeSpan]::FromMilliseconds(180)
$autoTimer.Add_Tick({
 try {
  $script:DockFullscreen=Test-OtherFullscreen
  if([UniversalGlassWin]::GetForegroundWindow() -eq [UniversalGlassWin]::FindWindow($null,$script:homeTitle)){$script:DockFullscreen=$false}
  if(-not $script:DockFullscreen){
   if($script:DockHidden){Reveal-Dock}
   return
  }
  $mouse=[System.Windows.Forms.Control]::MousePosition
  $bounds=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $nearBottom=($mouse.Y -ge ($bounds.Bottom-3))
  if($nearBottom){if($script:DockHidden){Reveal-Dock};return}
  if($menu.IsOpen -or $window.IsMouseOver){$script:DockRevealedAt=Get-Date;return}
  if(((Get-Date)-$script:DockRevealedAt).TotalMilliseconds -ge 1700){Conceal-Dock}
 } catch {
  # Preserve the dock if detecting fullscreen fails.
  if($script:DockHidden){Reveal-Dock}
 }
})

$script:last=''
function Update-Running {
 $processes=@(Get-Process -ErrorAction SilentlyContinue | Where-Object {
   $_.MainWindowHandle -ne [IntPtr]::Zero -and
   -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle) -and
   $_.MainWindowTitle -ne $script:homeTitle -and
   $_.MainWindowTitle -ne 'Workstation Glass Dock' -and
   $_.ProcessName -notin @('powershell','pwsh','ApplicationFrameHost')
  } | Sort-Object ProcessName,Id | Select-Object -First 8)
 $sig=($processes | ForEach-Object {"$($_.Id):$($_.MainWindowTitle)"}) -join '|'
 if($sig -eq $script:last){return}
 $script:last=$sig
 $running.Children.Clear()
 foreach($p in $processes){[void]$running.Children.Add((App-Button $p))}
 Move-Dock
}
$timer=New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromSeconds(2)
$timer.Add_Tick({try{Update-Running}catch{}})
$window.Add_Loaded({
    $window.Opacity = 1
    $window.Visibility = [System.Windows.Visibility]::Visible
    $window.Topmost = $true
    $window.IsHitTestVisible = $true

    $window.UpdateLayout()

    Move-Dock
    Update-Running

    $edge.Show()
    Place-Edge

    $timer.Start()
    $autoTimer.Start()
})
$window.Add_SizeChanged({Move-Dock})
# Battery status is updated independently without altering fullscreen hide/reveal logic.
$script:wcBatteryPercent=$window.FindName('WcBatteryPercent')
$wcBatteryTimer=New-Object System.Windows.Threading.DispatcherTimer
$wcBatteryTimer.Interval=[TimeSpan]::FromSeconds(20)
$wcBatteryTimer.Add_Tick({
    try {
        $info=[System.Windows.Forms.SystemInformation]::PowerStatus
        $pct=$info.BatteryLifePercent
        if ($pct -ge 0 -and $pct -le 1 -and
            ($info.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery) -eq 0) {
            $script:wcBatteryPercent.Text=('{0}%' -f [Math]::Round($pct*100))
        } else { $script:wcBatteryPercent.Text='--' }
    } catch { $script:wcBatteryPercent.Text='--' }
})
$window.Add_Loaded({
$wcBatteryTimer.Start()
    try {
        $info=[System.Windows.Forms.SystemInformation]::PowerStatus
        $pct=$info.BatteryLifePercent
        $script:wcBatteryPercent.Text=if(($info.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery) -eq 0 -and $pct -ge 0 -and $pct -le 1){('{0}%' -f [Math]::Round($pct*100))}else{'--'}
    } catch { $script:wcBatteryPercent.Text='--' }
})
[void]$window.ShowDialog()
