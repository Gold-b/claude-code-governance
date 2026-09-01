# gov-notify.ps1 — Governance popup notification (Windows)
# Called async from _common.sh gov_notify(). Shows a topmost WPF dialog
# with dismiss button. Stays on screen until clicked.
#
# ENCODING NOTE: All Hebrew text is set programmatically via .NET Unicode
# strings (not embedded in XAML) to avoid Windows codepage issues.
#
# Usage: powershell.exe -ExecutionPolicy Bypass -File gov-notify.ps1 -Title "..." -Message "..." [-Skill "..."] [-Project "..."]

param(
    [Parameter(Mandatory=$true)][string]$Title,
    [Parameter(Mandatory=$true)][string]$Message,
    [string]$Skill = "",
    [string]$Project = ""
)

# Force UTF-8 for any console output
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore

# --- Hebrew strings defined as .NET Unicode (immune to file encoding) ---
$hebrewDismiss   = [char]0x05E7 + [char]0x05E8 + [char]0x05D0 + [char]0x05EA + [char]0x05D9  # קראתי
$hebrewProject   = [char]0x05E4 + [char]0x05E8 + [char]0x05D5 + [char]0x05D9 + [char]0x05E7 + [char]0x05D8  # פרויקט

# Build skill block XAML (empty if no skill)
$skillBlock = ""
if ($Skill -ne "") {
    $escapedSkill = [System.Security.SecurityElement]::Escape($Skill)
    $skillBlock = @"
        <Border Background="#E8F5E9" CornerRadius="6" Padding="10" Margin="0,8,0,0">
            <TextBlock Text="$escapedSkill" FontSize="18" FontWeight="Bold"
                       Foreground="#2E7D32" HorizontalAlignment="Center" FontFamily="Consolas"/>
        </Border>
"@
}

# Build project context block (empty if no project)
$projectBlock = ""
if ($Project -ne "") {
    $escapedProject = [System.Security.SecurityElement]::Escape($Project)
    $projectBlock = @"
        <Border Background="#E3F2FD" CornerRadius="4" Padding="6,4" Margin="0,0,0,8">
            <TextBlock FontSize="11" Foreground="#546E7A" HorizontalAlignment="Right" Name="txtProject"/>
        </Border>
"@
}

$escapedTitle = [System.Security.SecurityElement]::Escape($Title)
$escapedMessage = [System.Security.SecurityElement]::Escape($Message)

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Context Governance"
        Width="480" SizeToContent="Height" MinHeight="220"
        WindowStartupLocation="CenterScreen"
        Topmost="True"
        ResizeMode="NoResize"
        WindowStyle="SingleBorderWindow"
        FlowDirection="RightToLeft"
        Background="#FAFAFA">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Project context bar -->
        <ContentControl Grid.Row="0">$projectBlock</ContentControl>

        <!-- Title -->
        <StackPanel Grid.Row="1" Orientation="Horizontal" FlowDirection="RightToLeft" Margin="0,0,0,12">
            <TextBlock Text="&#x1F4CB;" FontSize="24" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <TextBlock Name="txtTitle" FontSize="18" FontWeight="SemiBold"
                       Foreground="#1565C0" VerticalAlignment="Center" TextWrapping="Wrap"/>
        </StackPanel>

        <!-- Message body -->
        <TextBlock Grid.Row="2" Name="txtMessage" FontSize="14"
                   TextWrapping="Wrap" Foreground="#333333" LineHeight="22" Margin="0,0,0,4"/>

        <!-- Skill highlight -->
        <ContentControl Grid.Row="3">$skillBlock</ContentControl>

        <!-- Dismiss button -->
        <Button Grid.Row="4" Name="btnDismiss" FontSize="15" FontWeight="SemiBold"
                Padding="20,10" Margin="0,18,0,0" HorizontalAlignment="Center"
                Background="#1976D2" Foreground="White" BorderThickness="0"
                Cursor="Hand">
            <Button.Resources>
                <Style TargetType="Border">
                    <Setter Property="CornerRadius" Value="6"/>
                </Style>
            </Button.Resources>
        </Button>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# --- Set all text programmatically (Unicode-safe, no encoding issues) ---
$window.FindName("txtTitle").Text = $Title
$window.FindName("txtMessage").Text = $Message
$window.FindName("btnDismiss").Content = "$([char]0x2705)  $hebrewDismiss"

# Set project context if provided
if ($Project -ne "") {
    $txtProject = $window.FindName("txtProject")
    if ($txtProject -ne $null) {
        $txtProject.Text = "$hebrewProject`: $Project"
    }
}

$btnDismiss = $window.FindName("btnDismiss")
$btnDismiss.Add_Click({ $window.Close() })

# Play a subtle notification sound
[System.Media.SystemSounds]::Exclamation.Play()

$window.ShowDialog() | Out-Null
