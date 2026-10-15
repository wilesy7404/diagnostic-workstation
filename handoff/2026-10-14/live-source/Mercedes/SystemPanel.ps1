# MERCEDES-SAFE-CONTROLS-v1
function Invoke-WorkstationControl([string]$mode) {
    $file = Join-Path $env:LOCALAPPDATA 'DiagnosticWorkstation\WorkstationControls.ps1'
    if(-not(Test-Path -LiteralPath $file)){throw "Workstation controls missing: $file"}
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
       '-NoProfile','-STA','-ExecutionPolicy','Bypass',"-File `"$file`"",'-Mode',$mode
    )
}
# WORKSTATION Workstation SYSTEM popup — compact attached menu, Windows PowerShell 5.1 WPF.
# Loaded by Launcher.ps1 via: New-WorkstationSystemPopup -Anchor $systemButton
# The Popup is part of the existing launcher dispatcher, not an independent window.
function New-WorkstationSystemPopup {
    param([Parameter(Mandatory=$true)][System.Windows.Controls.Button]$Anchor)

    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    [xml]$xaml = @'
<Popup xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
       xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
       Placement="Top" VerticalOffset="0"
       AllowsTransparency="True" StaysOpen="False" PopupAnimation="None">
  <Grid x:Name="MenuRoot" Width="224" Opacity="1" RenderTransformOrigin="0.84,1">
    <Grid.RenderTransform>
      <ScaleTransform ScaleX="1" ScaleY="1"/>
    </Grid.RenderTransform>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="8"/>
    </Grid.RowDefinitions>
    <Border Grid.Row="0" Width="224" CornerRadius="12"
            Background="#F01B2939" BorderBrush="#7890B3D4"
            BorderThickness="0.8" Padding="8,9,8,7">
      <Border.Effect>
        <DropShadowEffect Color="#000000" Opacity="0.38" BlurRadius="18" ShadowDepth="2"/>
      </Border.Effect>
      <StackPanel x:Name="MenuItems">
        <StackPanel.Resources>
          <Style TargetType="{x:Type Button}">
            <Setter Property="Height" Value="29"/>
            <Setter Property="Margin" Value="0,0,0,1"/>
            <Setter Property="Padding" Value="9,0,5,0"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize" Value="11.5"/>
            <Setter Property="FontWeight" Value="Medium"/>
            <Setter Property="Foreground" Value="#E9F4FF"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
              <Setter.Value>
                <ControlTemplate TargetType="{x:Type Button}">
                  <Border x:Name="Cell" Background="{TemplateBinding Background}"
                          CornerRadius="6" SnapsToDevicePixels="True">
                    <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                      VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter TargetName="Cell" Property="Background" Value="#28508CC0"/>
                    </Trigger>
                    <Trigger Property="IsPressed" Value="True">
                      <Setter TargetName="Cell" Property="Background" Value="#4564A8D8"/>
                    </Trigger>
                    <Trigger Property="IsKeyboardFocused" Value="True">
                      <Setter TargetName="Cell" Property="Background" Value="#28508CC0"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </StackPanel.Resources>
        <DockPanel Margin="8,2,7,7" LastChildFill="False">
          <TextBlock DockPanel.Dock="Left" Text="SYSTEM" FontFamily="Segoe UI"
                     FontWeight="SemiBold" FontSize="12" Foreground="#F7FBFF"/>
          <TextBlock DockPanel.Dock="Right" Text="UNIVERSAL_BRAND_SHORT" FontFamily="Segoe UI"
                     FontSize="10" FontWeight="SemiBold" Foreground="#7CC7FF" Margin="0,1,0,0"/>
        </DockPanel>
        <Border Background="#365B7894" Height="1" Margin="3,0,3,5"/>
        <Button x:Name="WcWifi" Content="Wi-Fi &amp; Internet"/>
<Button x:Name="WcBattery" Content="Battery Status"/>
<Button x:Name="WcDesktop" Content="Windows Desktop (PIN)"/>
<Button x:Name="WcRecovery" Content="Emergency Recovery"/>        <Button x:Name="Internet" Content="Microsoft Edge"/>
        <Button x:Name="ControlPanel" Content="Control Panel"/>
        <Button x:Name="DateTime" Content="Date and Time"/>
        <Button x:Name="Network" Content="Network Connections"/>
        <Button x:Name="TaskManager" Content="Task Manager"/>
        <Button x:Name="Settings" Content="Windows Settings" Margin="0"/>
      </StackPanel>
    </Border>
    <!-- Pointer touches the actual SYSTEM control so the menu feels connected. -->
    <Path Grid.Row="1" Data="M 0,0 L 8,8 L 16,0 Z" Fill="#F01B2939"
          Stroke="#7890B3D4" StrokeThickness="0.8" Stretch="None"
          HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-1,21,0"/>
  </Grid>
</Popup>
'@
    $profile=Get-Content -LiteralPath (Join-Path $root 'profile.json') -Raw|ConvertFrom-Json
    $brandNode=$xaml.SelectSingleNode("//*[@Text='UNIVERSAL_BRAND_SHORT']")
    if($brandNode){$brandNode.SetAttribute('Text',[string]$profile.short)}
    $popup = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $popup.PlacementTarget = $Anchor

    # Final user-tested offset: menu and pointer sit over the SYSTEM button at the current display scaling.
    $align = {
        $popup.HorizontalOffset = [Math]::Round(([double]$Anchor.ActualWidth - 224.0) / 2.0) + 75
    }.GetNewClosure()
    & $align
    $popup.Add_Opened({
        & $align
        # A short scale/fade effect from the bottom-right, where the button sits.
        $body = $popup.Child
        $transform = [Windows.Media.ScaleTransform]$body.RenderTransform
        $body.Opacity = 0.75
        $transform.ScaleX = 0.97
        $transform.ScaleY = 0.97
        $fade = [Windows.Media.Animation.DoubleAnimation]::new(0.75,1.0,[TimeSpan]::FromMilliseconds(130))
        $scaleX = [Windows.Media.Animation.DoubleAnimation]::new(0.97,1.0,[TimeSpan]::FromMilliseconds(140))
        $scaleY = [Windows.Media.Animation.DoubleAnimation]::new(0.97,1.0,[TimeSpan]::FromMilliseconds(140))
        $body.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
        $transform.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $scaleX)
        $transform.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $scaleY)
    }.GetNewClosure())

    $actions = @{
        WcWifi     = { Invoke-WorkstationControl 'Wifi' }
        WcBattery  = { Invoke-WorkstationControl 'Battery' }
        WcDesktop  = { Invoke-WorkstationControl 'Desktop' }
        WcRecovery = { Invoke-WorkstationControl 'Recovery' }
        Internet     = { Start-Process 'msedge.exe' }
        ControlPanel = { Start-Process 'control.exe' }
        DateTime     = { Start-Process 'control.exe' -ArgumentList 'timedate.cpl' }
        Network      = { Start-Process 'control.exe' -ArgumentList 'ncpa.cpl' }
        TaskManager  = { Start-Process 'taskmgr.exe' }
        Settings     = { Start-Process 'ms-settings:' }
    }
    # MenuRoot (Grid) -> Border -> StackPanel. Works within the loaded XAML namescope.
    $items = $popup.Child.Children[0].Child
    foreach ($entry in $items.Children) {
        if ($entry -isnot [System.Windows.Controls.Button]) { continue }
        $action = $actions[[string]$entry.Name]
        if ($null -eq $action) { continue }
        $entry.Add_Click({
            $popup.IsOpen = $false
            try { & $action }
            catch {
                [Windows.MessageBox]::Show('Could not open that system tool.', 'WORKSTATION Workstation', 'OK', 'Warning') | Out-Null
            }
        }.GetNewClosure())
    }
    return $popup
}
