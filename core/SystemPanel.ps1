# BMW shared SYSTEM panel (preview only). Dot-source this file.
function Show-WorkstationSystemPanel {
 param([System.Windows.Window]$Owner)
 Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
 $xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="Workstation System" Width="590" Height="490" WindowStartupLocation="CenterScreen"
 ResizeMode="NoResize" Background="#101A28" Foreground="#F5FAFF" FontFamily="Segoe UI" ShowInTaskbar="False">
 <Window.Resources>
  <Style x:Key="Action" TargetType="Button">
   <Setter Property="Margin" Value="6"/><Setter Property="FontSize" Value="15"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Foreground" Value="#F5FAFF"/><Setter Property="Background" Value="#203348"/>
   <Setter Property="BorderBrush" Value="#526D89"/><Setter Property="BorderThickness" Value="1"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="Surface" CornerRadius="15" Background="{TemplateBinding Background}"
    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="19">
     <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True">
     <Setter TargetName="Surface" Property="Background" Value="#2D4B69"/>
     <Setter TargetName="Surface" Property="BorderBrush" Value="#68B6FF"/>
    </Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
 </Window.Resources>
 <Grid Margin="26">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <StackPanel><TextBlock Text="SYSTEM" FontWeight="SemiBold" FontSize="30"/>
   <TextBlock Text="Workstation tools and Windows controls" Foreground="#ABC4DC" Margin="0,5,0,20"/></StackPanel>
  <UniformGrid Grid.Row="1" Rows="3" Columns="2">
   <Button x:Name="Internet" Style="{StaticResource Action}" Content="Internet"/>
   <Button x:Name="ControlPanel" Style="{StaticResource Action}" Content="Control Panel"/>
   <Button x:Name="DateTime" Style="{StaticResource Action}" Content="Date &amp; Time"/>
   <Button x:Name="Network" Style="{StaticResource Action}" Content="Network Connections"/>
   <Button x:Name="TaskManager" Style="{StaticResource Action}" Content="Task Manager"/>
   <Button x:Name="Settings" Style="{StaticResource Action}" Content="Windows Settings"/>
  </UniformGrid>
  <DockPanel Grid.Row="2" Margin="0,16,0,0">
   <TextBlock Foreground="#95B0CA" VerticalAlignment="Center" Text="Workstation v1.0.0 beta preview"/>
   <Button x:Name="ClosePanel" DockPanel.Dock="Right" Content="CLOSE" Padding="17,8"
    Foreground="White" Background="#29496B"/>
  </DockPanel>
 </Grid>
</Window>
'@
 $panel=[Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
 if($Owner){$panel.Owner=$Owner;$panel.WindowStartupLocation='CenterOwner'}
 $actions=@{
  Internet={Start-Process 'microsoft-edge:https://www.google.com'}
  ControlPanel={Start-Process 'control.exe'}
  DateTime={Start-Process 'timedate.cpl'}
  Network={Start-Process 'ncpa.cpl'}
  TaskManager={Start-Process 'taskmgr.exe'}
  Settings={Start-Process 'ms-settings:'}
 }
 foreach($key in @('Internet','ControlPanel','DateTime','Network','TaskManager','Settings')){
  $button=$panel.FindName($key);$button.Tag=$key
  $button.Add_Click({
   param($sender,$ev)
   try { & $actions[[string]$sender.Tag] }
   catch {
    $message='Windows could not open the requested tool. Try Control Panel instead. '+$_.Exception.Message
    [Windows.MessageBox]::Show($message,'Workstation System','OK','Warning')|Out-Null
   }
  }.GetNewClosure())
 }
 $panel.FindName('ClosePanel').Add_Click({$panel.Close()}.GetNewClosure())
 [void]$panel.ShowDialog()
}
