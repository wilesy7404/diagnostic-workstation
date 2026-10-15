# Mercedes Diagnostic Workstation pre-shell controls v1.0 (Windows PowerShell 5.1).
# Intentionally does not enable/change the custom shell.
param(
    [ValidateSet('Wifi','Battery','Settings','Desktop','Return','Recovery')]
    [string]$Mode = 'Wifi'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
$script:controlsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:pinFile = Join-Path $script:controlsRoot 'controls-pin.json'
$script:profile = Get-Content -LiteralPath (Join-Path $script:controlsRoot 'profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$script:homeTitle = ([string]$script:profile.displayName) + ' Diagnostic System'

function Show-Notice([string]$text, [string]$caption = 'Mercedes Workstation') {
    [void][System.Windows.MessageBox]::Show($text,$caption,'OK','Information')
}
function Open-Settings([string]$uri) {
    try { Start-Process $uri -ErrorAction Stop }
    catch { Start-Process 'control.exe' -ErrorAction Stop }
}
function Test-ControlPin([string]$candidate) {
    if (-not (Test-Path -LiteralPath $script:pinFile)) { return $false }
    $record = Get-Content -LiteralPath $script:pinFile -Raw | ConvertFrom-Json
    if ([int]$record.version -ne 1 -or [int]$record.iterations -lt 100000) { return $false }
    $salt = [Convert]::FromBase64String([string]$record.salt)
    $expected = [Convert]::FromBase64String([string]$record.hash)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($candidate,$salt,[int]$record.iterations)
    try { $actual = $kdf.GetBytes($expected.Length) } finally { $kdf.Dispose() }
    if ($actual.Length -ne $expected.Length) { return $false }
    $diff = 0
    for ($i=0; $i -lt $actual.Length; $i++) { $diff = $diff -bor ($actual[$i] -bxor $expected[$i]) }
    return ($diff -eq 0)
}
# MERCEDES-CONTROLS-v2-PIN: touch-friendly PIN keypad; original PIN hash remains unchanged.
function Ask-ControlPin {
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Mercedes - Desktop Access" Width="458" Height="610"
        Background="#0D1623" Foreground="#F3F7FC" FontFamily="Segoe UI"
        WindowStartupLocation="CenterScreen" WindowStyle="None"
        ResizeMode="NoResize" Topmost="True" ShowInTaskbar="True"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style x:Key="KeyButton" TargetType="Button">
      <Setter Property="Height" Value="59"/>
      <Setter Property="Margin" Value="5"/>
      <Setter Property="FontSize" Value="23"/>
      <Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="Foreground" Value="#F3F7FC"/>
      <Setter Property="Background" Value="#223246"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Cell" CornerRadius="12" Background="{TemplateBinding Background}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Cell" Property="Background" Value="#354C65"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="Cell" Property="Background" Value="#4B6784"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Border Margin="1" Background="#101B2B" BorderBrush="#6D8199" BorderThickness="1" CornerRadius="17">
    <Grid Margin="27,24,27,22">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <DockPanel Grid.Row="0" LastChildFill="False" Margin="0,0,0,24">
        <Image x:Name="PinBrandLogo" Width="43" Height="43" Stretch="Uniform" DockPanel.Dock="Left" Margin="0,0,12,0"/>
        <StackPanel DockPanel.Dock="Left" VerticalAlignment="Center">
          <TextBlock Text="MERCEDES-BENZ" FontSize="14" FontWeight="SemiBold" Foreground="#E7F0FA"/>
          <TextBlock Text="DIAGNOSTIC WORKSTATION" FontSize="9" FontWeight="SemiBold" Foreground="#94B4D4"/>
        </StackPanel>
        <Button x:Name="ClosePin" DockPanel.Dock="Right" Content="&#x2715;" Width="33" Height="33" FontSize="14" Foreground="#B6CAE0" Background="#26364B" BorderThickness="0" Cursor="Hand"/>
      </DockPanel>
      <TextBlock Grid.Row="1" Text="DESKTOP ACCESS" FontSize="25" FontWeight="Light" Foreground="#FFFFFF"/>
      <TextBlock Grid.Row="2" Text="Enter your 6–12 digit passcode to open Windows desktop."
                 Margin="0,8,0,12" FontSize="12" Foreground="#B7C9DC" TextWrapping="Wrap"/>
      <Border Grid.Row="3" CornerRadius="12" BorderThickness="1" BorderBrush="#506986" Background="#17273A" Height="65" Padding="10">
        <TextBlock x:Name="PinDots" Text="••••••" FontSize="26" Foreground="#E8F2FC"
                   FontFamily="Segoe UI" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <TextBlock Grid.Row="4" x:Name="PinStatus" Text="Enter passcode using touch or keyboard"
                 Foreground="#92B1CB" Margin="0,12,0,8" FontSize="12" TextAlignment="Center"/>
      <UniformGrid Grid.Row="5" Columns="3" Rows="4" Margin="0,6,0,12">
        <Button x:Name="Key1" Content="1" Style="{StaticResource KeyButton}"/>
        <Button x:Name="Key2" Content="2" Style="{StaticResource KeyButton}"/>
        <Button x:Name="Key3" Content="3" Style="{StaticResource KeyButton}"/>
        <Button x:Name="Key4" Content="4" Style="{StaticResource KeyButton}"/>
        <Button x:Name="Key5" Content="5" Style="{StaticResource KeyButton}"/>
        <Button x:Name="Key6" Content="6" Style="{StaticResource KeyButton}"/>
        <Button x:Name="Key7" Content="7" Style="{StaticResource KeyButton}"/>
        <Button x:Name="Key8" Content="8" Style="{StaticResource KeyButton}"/>
        <Button x:Name="Key9" Content="9" Style="{StaticResource KeyButton}"/>
        <Button x:Name="BackspacePin" Content="&#x232B;" Style="{StaticResource KeyButton}" FontSize="19"/>
        <Button x:Name="Key0" Content="0" Style="{StaticResource KeyButton}"/>
        <Button x:Name="ClearPin" Content="CLR" Style="{StaticResource KeyButton}" FontSize="15"/>
      </UniformGrid>
      <Grid Grid.Row="6" Margin="0,8,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Button Grid.Column="0" x:Name="CancelPin" Content="CANCEL" Height="44" Background="#26364B" Foreground="#E7F0FC" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
        <Button Grid.Column="2" x:Name="UnlockPin" Content="OPEN DESKTOP" Height="44" IsEnabled="False" Background="#B9CADB" Foreground="#0D1927" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@
    $w=[Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
    try {
        $logoPath=Join-Path $script:controlsRoot ([string]$script:profile.logo)
        if(Test-Path -LiteralPath $logoPath) {
            $bitmap=New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.UriSource=New-Object System.Uri($logoPath)
            $bitmap.CacheOption=[System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.EndInit()
            $bitmap.Freeze()
            $w.FindName('PinBrandLogo').Source=$bitmap
        }
    } catch { } # Logo failure must not prevent emergency desktop access.

    $state=[pscustomobject]@{Digits='';Attempts=0}
    $dots=$w.FindName('PinDots')
    $status=$w.FindName('PinStatus')
    $unlock=$w.FindName('UnlockPin')

    $render={
        if($state.Digits.Length -eq 0){$dots.Text='••••••'}
        else{$dots.Text=('●' * $state.Digits.Length)}
        $unlock.IsEnabled=($state.Digits.Length -ge 6)
    }.GetNewClosure()
    $addDigit={
        param([string]$digit)
        if($state.Digits.Length -lt 12){$state.Digits += $digit}
        $status.Text='Enter passcode using touch or keyboard'
        $status.Foreground=[System.Windows.Media.Brushes]::LightSteelBlue
        & $render
    }.GetNewClosure()
    $doUnlock={
        if($state.Digits.Length -lt 6){$status.Text='Enter at least six digits';return}
        $candidate=$state.Digits
        $state.Digits=''
        try {
            if(Test-ControlPin $candidate){$w.DialogResult=$true;return}
            $state.Attempts++
            $status.Text='Incorrect passcode. Please try again.'
            $status.Foreground=[System.Windows.Media.Brushes]::Salmon
            if($state.Attempts -ge 5){$w.DialogResult=$false;return}
        } catch {
            $status.Text='Passcode could not be verified. Cancel and retry.'
            $status.Foreground=[System.Windows.Media.Brushes]::Salmon
        } finally { $candidate=$null }
        & $render
    }.GetNewClosure()

    for($digit=0; $digit -le 9; $digit++) {
        $key=$w.FindName('Key'+$digit)
        $digitText=[string]$digit
        $key.Add_Click({ & $addDigit $digitText }.GetNewClosure())
    }
    $w.FindName('BackspacePin').Add_Click({
        if($state.Digits.Length -gt 0){$state.Digits=$state.Digits.Substring(0,$state.Digits.Length-1)}
        & $render
    }.GetNewClosure())
    $w.FindName('ClearPin').Add_Click({$state.Digits=''; & $render}.GetNewClosure())
    $w.FindName('CancelPin').Add_Click({$w.DialogResult=$false}.GetNewClosure())
    $w.FindName('ClosePin').Add_Click({$w.DialogResult=$false}.GetNewClosure())
    $unlock.Add_Click({& $doUnlock}.GetNewClosure())
    $w.Add_PreviewKeyDown({
        param($sender,$evt)
        $keyName=[string]$evt.Key
        if($keyName -match '^D([0-9])$' -or $keyName -match '^NumPad([0-9])$'){
            & $addDigit $Matches[1]
            $evt.Handled=$true
        } elseif($keyName -eq 'Back') {
            if($state.Digits.Length -gt 0){$state.Digits=$state.Digits.Substring(0,$state.Digits.Length-1)}
            & $render
            $evt.Handled=$true
        } elseif($keyName -eq 'Delete') {
            $state.Digits=''; & $render; $evt.Handled=$true
        } elseif($keyName -eq 'Return') {
            & $doUnlock; $evt.Handled=$true
        } elseif($keyName -eq 'Escape') {
            $w.DialogResult=$false; $evt.Handled=$true
        }
    }.GetNewClosure())
    $w.Add_Closed({$state.Digits='';}.GetNewClosure())
    return ($w.ShowDialog() -eq $true)
}

function Ensure-NativeWindows {
    if (-not ('MercedesWorkstationControlsNativeV1' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class MercedesWorkstationControlsNativeV1 {
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string className,string windowTitle);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd,int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  public delegate bool EnumProc(IntPtr hwnd, IntPtr state);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback,IntPtr state);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd,StringBuilder value,int maxCount);
  public static IntPtr FindByTitle(string title) {
      IntPtr found=IntPtr.Zero;
      EnumWindows(delegate(IntPtr hwnd, IntPtr state) {
          var buffer=new StringBuilder(512);
          GetWindowText(hwnd,buffer,buffer.Capacity);
          if (String.Equals(buffer.ToString(),title,StringComparison.OrdinalIgnoreCase)) { found=hwnd; return false; }
          return true;
      },IntPtr.Zero);
      return found;
  }
}
'@
    }
}
function Set-WindowMode([bool]$desktop) {
    Ensure-NativeWindows
    if ($desktop) {
        Start-Process 'explorer.exe'
        $taskbar=[IntPtr]::Zero
        for ($i=0;$i -lt 16;$i++) {
            Start-Sleep -Milliseconds 500
            $taskbar=[MercedesWorkstationControlsNativeV1]::FindWindow('Shell_TrayWnd',$null)
            if ($taskbar -ne [IntPtr]::Zero) {break}
        }
        if ($taskbar -eq [IntPtr]::Zero) {
            Show-Notice 'Explorer did not create the Windows desktop/taskbar. Workstation remains visible. Use Emergency Recovery if needed.'
            return
        }
        foreach ($title in @($script:homeTitle,'Workstation Glass Dock','Workstation Dock Touch Reveal')) {
            $hw = [MercedesWorkstationControlsNativeV1]::FindByTitle($title)
            if ($hw -ne [IntPtr]::Zero) { [void][MercedesWorkstationControlsNativeV1]::ShowWindow($hw,6) }
        }
        foreach ($cls in @('Shell_TrayWnd','Shell_SecondaryTrayWnd')) {
            $hw = [MercedesWorkstationControlsNativeV1]::FindWindow($cls,$null)
            if ($hw -ne [IntPtr]::Zero) { [void][MercedesWorkstationControlsNativeV1]::ShowWindow($hw,5) }
        }
    } else {
        # Return shortcut works even when a workstation window needs a manual restart.
        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)
        foreach ($name in @('Launcher','Dock')) {
            $file = Join-Path $script:controlsRoot ($name + '.ps1')
            if (-not (@($processes | Where-Object { $_.CommandLine -like "*$file*" }).Count) -and (Test-Path $file)) {
                Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass',"-File `"$file`"")
            }
        }
        Start-Sleep -Milliseconds 1100
        foreach ($title in @('Workstation Dock Touch Reveal','Workstation Glass Dock',$script:homeTitle)) {
            $hw = [MercedesWorkstationControlsNativeV1]::FindByTitle($title)
            if ($hw -ne [IntPtr]::Zero) {
                $command=if($title -eq $script:homeTitle){3}else{9}
                [void][MercedesWorkstationControlsNativeV1]::ShowWindow($hw,$command)
                if ($title -eq $script:homeTitle) { [void][MercedesWorkstationControlsNativeV1]::SetForegroundWindow($hw) }
            }
        }
        foreach ($cls in @('Shell_TrayWnd','Shell_SecondaryTrayWnd')) {
            $hw = [MercedesWorkstationControlsNativeV1]::FindWindow($cls,$null)
            if ($hw -ne [IntPtr]::Zero) { [void][MercedesWorkstationControlsNativeV1]::ShowWindow($hw,0) }
        }
    }
}
function Show-BatteryPanel {
    $w = New-Object System.Windows.Window
    $w.Title='Battery Status';$w.Width=390;$w.Height=205
    $w.Background=[System.Windows.Media.Brushes]::WhiteSmoke
    $w.WindowStartupLocation='CenterScreen';$w.Topmost=$true
    $grid = New-Object System.Windows.Controls.StackPanel
    $grid.Margin='22'
    $text = New-Object System.Windows.Controls.TextBlock
    $text.FontSize=17;$text.Margin='0,0,0,15'
    $status=[System.Windows.Forms.SystemInformation]::PowerStatus
    $pct=$status.BatteryLifePercent
    if (($status.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery) -ne 0 -or $pct -lt 0) {
        $text.Text='No battery reported by Windows'
    } else {
        $charge=if($status.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Online){'AC connected'}else{'On battery'}
        $text.Text=('{0}% remaining  -  {1}' -f [Math]::Round($pct*100),$charge)
    }
    [void]$grid.Children.Add($text)
    $button=New-Object System.Windows.Controls.Button
    $button.Content='Open Windows Power and Battery';$button.Height=40
    $button.Add_Click({Open-Settings 'ms-settings:powersleep'})
    [void]$grid.Children.Add($button)
    $w.Content=$grid
    [void]$w.ShowDialog()
}
function Show-WifiPanel {
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Wi-Fi Connections" Height="545" Width="530" ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen" Topmost="True" Background="#111D2E" Foreground="White" FontFamily="Segoe UI">
<Grid Margin="20"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<TextBlock Text="WI-FI CONNECTIONS" FontSize="20" FontWeight="SemiBold"/>
<TextBlock Grid.Row="1" Text="Select a network. Enter a password for a new WPA2-Personal network." Foreground="#B4C9DF" FontSize="12" TextWrapping="Wrap" Margin="0,8,0,12" />
<ListBox Grid.Row="2" x:Name="Networks" FontSize="16" Background="#1C2B40" Foreground="White" BorderBrush="#6688B2"/>
<TextBlock Grid.Row="3" Text="PASSWORD (leave blank for a previously saved network)" FontSize="11" Margin="0,12,0,5"/>
<PasswordBox Grid.Row="4" x:Name="Password" FontSize="16" Height="37" MaxLength="63"/>
<TextBlock Grid.Row="5" x:Name="Status" Text="Ready" TextWrapping="Wrap" Foreground="#D2E6F8" Margin="0,10,0,9" MinHeight="36"/>
<StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
<Button x:Name="Refresh" Content="REFRESH" Width="90" Height="37" Margin="0,0,8,0"/>
<Button x:Name="Settings" Content="WINDOWS SETTINGS" Width="144" Height="37" Margin="0,0,8,0"/>
<Button x:Name="Connect" Content="CONNECT" Width="95" Height="37"/>
</StackPanel></Grid></Window>
'@
    $w=[Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
    $list=$w.FindName('Networks');$password=$w.FindName('Password');$status=$w.FindName('Status')
    $refresh = {
        $list.Items.Clear()
        $raw = @( & netsh.exe wlan show networks mode=bssid 2>&1 )
        foreach ($line in $raw) {
            if ([string]$line -match '^\s*SSID\s+\d+\s*:\s*(.+?)\s*$') {
                $ssid=$Matches[1].Trim()
                if ($ssid.Length -gt 0 -and -not $list.Items.Contains($ssid)) { [void]$list.Items.Add($ssid) }
            }
        }
        $status.Text=if($list.Items.Count){"Found $($list.Items.Count) network(s)."}else{"No networks detected. Check Wi-Fi adapter; Windows Settings is available below."}
    }.GetNewClosure()
    $w.FindName('Refresh').Add_Click({ & $refresh }.GetNewClosure())
    $w.FindName('Settings').Add_Click({ Open-Settings 'ms-settings:network-wifi' }.GetNewClosure())
    $w.FindName('Connect').Add_Click({
        $ssid=[string]$list.SelectedItem
        if ([string]::IsNullOrWhiteSpace($ssid)) { $status.Text='Select a network first.';return }
        if($ssid.Contains('"')) { $status.Text='Network name contains unsupported quotation marks. Use Windows Settings.';return }
        $status.Text="Connecting to $ssid ..."
        $pwText=$password.Password
        try {
            if (-not [string]::IsNullOrEmpty($pwText)) {
                if ($pwText.Length -lt 8) { $status.Text='WPA2 Personal passwords must be at least 8 characters.';return }
                $xmlSsid=[Security.SecurityElement]::Escape($ssid)
                $xmlPass=[Security.SecurityElement]::Escape($pwText)
                $profileXml=@"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
<name>$xmlSsid</name><SSIDConfig><SSID><name>$xmlSsid</name></SSID></SSIDConfig>
<connectionType>ESS</connectionType><connectionMode>auto</connectionMode>
<MSM><security><authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption><sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$xmlPass</keyMaterial></sharedKey></security></MSM>
</WLANProfile>
"@
                $tmp = Join-Path $env:TEMP ('mb-wifi-'+[guid]::NewGuid().ToString('N')+'.xml')
                try {
                    [IO.File]::WriteAllText($tmp,$profileXml,(New-Object System.Text.UTF8Encoding($false)))
                    $output=@( & netsh.exe wlan add profile "filename=$tmp" user=current 2>&1 )
                    if ($LASTEXITCODE -ne 0) {throw ($output -join ' ')}
                } finally {
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                }
            }
            $output=@( & netsh.exe wlan connect "name=$ssid" "ssid=$ssid" 2>&1 )
            if ($LASTEXITCODE -ne 0) {throw ($output -join ' ')}
            $status.Text='Connection requested. Windows may take a few seconds to connect.'
            $password.Clear()
        } catch {
            $status.Text='Unable to connect. For WPA3/enterprise Wi-Fi use Windows Settings. '+$_.Exception.Message
        } finally { $pwText=$null }
    }.GetNewClosure())
    $w.Add_ContentRendered({& $refresh}.GetNewClosure())
    [void]$w.ShowDialog()
}
function Show-RecoveryPanel {
    $answer=[Windows.MessageBox]::Show(
      "Emergency recovery restores the normal Explorer shell for this Windows account.`n`nOnly use it if you need to exit workstation shell mode. It does not require the desktop passcode.`n`nRestore Explorer now?",
      'Emergency Recovery','YesNo','Warning')
    if ($answer -eq [Windows.MessageBoxResult]::Yes) {
        & (Join-Path $script:controlsRoot 'Restore-ExplorerShell.ps1')
    }
}

switch ($Mode) {
    'Wifi'     { Show-WifiPanel }
    'Battery'  { Show-BatteryPanel }
    'Settings' { Open-Settings 'ms-settings:' }
    'Desktop'  {
        if (-not (Test-Path $script:pinFile)) {
            Show-Notice 'Desktop access is not configured. Run the controls installer to create a passcode.'
        } elseif (Ask-ControlPin) { Set-WindowMode $true }
    }
    'Return'   { Set-WindowMode $false }
    'Recovery' { Show-RecoveryPanel }
}
