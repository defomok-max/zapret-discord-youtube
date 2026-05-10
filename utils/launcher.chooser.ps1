#Requires -Version 5.1
<#
.SYNOPSIS
  Minimal launcher chooser — single small WPF window with 4 actions.
.DESCRIPTION
  One-screen entry point for the most common things:
    [▶]  Start       — apply current config, start zapret + WARP + PAC.
    [■]  Stop        — tear it all down.
    [⚙]  Settings    — open the full WPF launcher (services, strategy, WARP, PAC, custom VPN).
    [✓]  Test        — connectivity smoke-test (zapret + WARP + PAC + geo).

  Auto-refreshes the status line every 3 seconds.
#>

$ErrorActionPreference = 'Stop'

# Breadcrumb-style progress logging. We write a line at every major boot step
# so launcher.log shows exactly how far the chooser got even if the WPF window
# silently fails to appear (which is the original "black flash" symptom).
$Script:LogPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'launcher.log'
function Write-BootStep([string]$step) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    # Print to console so the user sees progress in the cmd window even if
    # the WPF stage fails. The bat ALWAYS pauses, so they will be able to
    # read this even when no window appears.
    try { Write-Host ("[{0}] chooser> {1}" -f $stamp, $step) -ForegroundColor DarkGray } catch { }
    try {
        $line = "[{0}] chooser> {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $step
        Add-Content -LiteralPath $Script:LogPath -Value $line -Encoding UTF8
    } catch { }
}

# Apartment-state sanity check. If powershell.exe was launched without -STA,
# WPF will not work and we should bail with a clear message instead of letting
# XamlReader.Load throw a confusing 'COM error 0x80010108' / hang.
$apt = [System.Threading.Thread]::CurrentThread.GetApartmentState()
Write-BootStep ("entered (PSv={0}, apartment={1}, host={2})" -f $PSVersionTable.PSVersion, $apt, $Host.Name)
if ($apt -ne [System.Threading.ApartmentState]::STA) {
    Write-BootStep "FATAL: not running in STA. Restart powershell.exe with -STA."
    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Red
    Write-Host '  codeDPI chooser cannot start: PowerShell is in MTA mode.' -ForegroundColor Red
    Write-Host '  Re-run via start.bat (it passes -STA), or:' -ForegroundColor Yellow
    Write-Host '    powershell -NoProfile -ExecutionPolicy Bypass -STA -File "utils\launcher.chooser.ps1"' -ForegroundColor Yellow
    Write-Host '=====================================================================' -ForegroundColor Red
    Write-Host 'Press ENTER to close...' -ForegroundColor DarkGray
    try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 30 }
    exit 2
}

# Top-level safety net: any uncaught error gets logged and shown to the user
# instead of silently closing the cmd window before they can read it.
trap {
    $err = $_
    $msg = "$($err.Exception.GetType().Name): $($err.Exception.Message)"
    Write-BootStep ("FATAL: " + $msg)
    try { Add-Content -LiteralPath $Script:LogPath -Value $err.ScriptStackTrace -Encoding UTF8 } catch { }
    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Red
    Write-Host '  codeDPI chooser — FATAL ERROR' -ForegroundColor Red
    Write-Host '=====================================================================' -ForegroundColor Red
    Write-Host $msg -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Stack:' -ForegroundColor DarkGray
    Write-Host $err.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Press ENTER to close this window...' -ForegroundColor DarkGray
    try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 30 }
    exit 1
}

Write-BootStep 'loading WPF assemblies'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

Write-BootStep 'sourcing launcher.lib.ps1'
. (Join-Path $PSScriptRoot 'launcher.lib.ps1')
$Script:Cfg = Read-Config
Write-BootStep ("config loaded ({0} keys)" -f $Script:Cfg.Count)

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="codeDPI" Width="540" Height="360"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Background="#1e1e1e"
        FontFamily="Segoe UI" FontSize="13"
        Foreground="#e0e0e0">
    <Window.Resources>
        <Style x:Key="ActionButton" TargetType="Button">
            <Setter Property="Background" Value="#2d2d30"/>
            <Setter Property="Foreground" Value="#e0e0e0"/>
            <Setter Property="BorderBrush" Value="#3f3f46"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,9"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="b"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"
                                              Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="b" Property="Background" Value="#3a3a3d"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="b" Property="Background" Value="#252526"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#666"/>
                                <Setter TargetName="b" Property="Background" Value="#252526"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="StartButton" TargetType="Button" BasedOn="{StaticResource ActionButton}">
            <Setter Property="Background" Value="#2d6a4f"/>
            <Setter Property="BorderBrush" Value="#1b4332"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style x:Key="StopButton" TargetType="Button" BasedOn="{StaticResource ActionButton}">
            <Setter Property="Background" Value="#793a3a"/>
            <Setter Property="BorderBrush" Value="#5a2727"/>
        </Style>
    </Window.Resources>
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="4,0,4,12">
            <StackPanel Orientation="Horizontal">
                <Ellipse x:Name="dot" Width="10" Height="10" Fill="#666" VerticalAlignment="Center"/>
                <TextBlock x:Name="lblStatus" Text="loading..." Margin="8,0,0,0" FontWeight="SemiBold"/>
            </StackPanel>
            <TextBlock x:Name="lblDetail" Text="" FontSize="11" Foreground="#999" Margin="18,2,0,0"/>
        </StackPanel>
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Grid.ColumnSpan="3" Margin="4,0,4,4"
                       Foreground="#999" FontSize="11"
                       Text="Что запустить — выбери одно из трёх:"/>
            <Button x:Name="btnStartDpi"  Grid.Row="1" Grid.Column="0" Style="{StaticResource StartButton}"
                    Content="▶  DPI" ToolTip="Обход блокировок провайдера: YouTube, Discord, Telegram, Meta, X… (winws.exe без WARP)"/>
            <Button x:Name="btnStartWarp" Grid.Row="1" Grid.Column="1" Style="{StaticResource StartButton}"
                    Content="▶  WARP+Гео" ToolTip="Обход гео-блоковки: ChatGPT, Claude, Gemini, Cursor, Copilot… (WARP как SOCKS5 + PAC, без winws). WARP ставится автоматически, если его нет."/>
            <Button x:Name="btnStartAll"  Grid.Row="1" Grid.Column="2" Style="{StaticResource StartButton}"
                    Content="▶  Всё" ToolTip="DPI + WARP + PAC одним кликом. Самый простой вариант если не знаешь что нужно."/>
            <Button x:Name="btnStop"     Grid.Row="2" Grid.Column="0" Style="{StaticResource StopButton}"
                    Content="■  Остановить"/>
            <Button x:Name="btnSettings" Grid.Row="2" Grid.Column="1" Style="{StaticResource ActionButton}"
                    Content="⚙  Настройки"/>
            <Button x:Name="btnTest"     Grid.Row="2" Grid.Column="2" Style="{StaticResource ActionButton}"
                    Content="✓  Тест связи"/>
        </Grid>
        <TextBlock Grid.Row="2" x:Name="lblFoot" Margin="4,12,4,0" Foreground="#777" FontSize="11"
                   TextAlignment="Center" Text="codeDPI · v1.2.1"/>
    </Grid>
</Window>
'@

Write-BootStep 'parsing XAML'
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
Write-BootStep 'building WPF window via XamlReader.Load'
$Script:window = [Windows.Markup.XamlReader]::Load($reader)
Write-BootStep 'WPF window built'
function Find($name) { $Script:window.FindName($name) }

$dot       = Find 'dot'
$lblStatus = Find 'lblStatus'
$lblDetail = Find 'lblDetail'
$lblFoot   = Find 'lblFoot'
$btnStartDpi  = Find 'btnStartDpi'
$btnStartWarp = Find 'btnStartWarp'
$btnStartAll  = Find 'btnStartAll'
$btnStop      = Find 'btnStop'
$btnSettings  = Find 'btnSettings'
$btnTest      = Find 'btnTest'

$lblFoot.Text = "codeDPI · v$Script:Version"

# ============================================================================
# Status updater
# ============================================================================
function Set-Dot([string]$color) {
    $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($color))
    $dot.Fill = $brush
}

function Update-Status {
    $dpiUp  = Test-WinwsRunning
    $svcUp  = Test-ServiceRunning 'zapret'
    $pacUp  = Test-PacEnabled   $Script:Cfg
    $pacSrv = Test-PacServerRunning
    $warp   = Get-WarpStatus
    $warpUp = $warp.Connected

    $bypass    = $dpiUp -or $svcUp
    $geoActive = $warpUp -and $pacUp -and $pacSrv
    $warpOnly  = (-not $bypass) -and $geoActive

    if ($bypass -and $geoActive) {
        Set-Dot '#2ea043'
        $lblStatus.Text = 'Активно: DPI + WARP + PAC'
    } elseif ($bypass -and $warpUp) {
        Set-Dot '#d29922'
        $lblStatus.Text = 'Частично: DPI + WARP, без PAC'
    } elseif ($warpOnly) {
        Set-Dot '#2ea043'
        $lblStatus.Text = 'Активно: WARP + PAC (только гео)'
    } elseif ($bypass) {
        Set-Dot '#2ea043'
        $lblStatus.Text = 'Активно: DPI bypass'
    } elseif ($warpUp) {
        Set-Dot '#d29922'
        $lblStatus.Text = 'WARP подключён (PAC не активен)'
    } else {
        Set-Dot '#666666'
        $lblStatus.Text = 'Выключено'
    }

    # Sub-line: terse details.
    $bits = @()
    if ($dpiUp)  { $bits += 'winws' }
    if ($svcUp)  { $bits += 'service' }
    if ($warpUp) { $bits += 'warp' }
    if ($pacUp -and $pacSrv) { $bits += "pac:$(Get-PacPort $Script:Cfg)" }
    elseif ($pacUp -and -not $pacSrv) { $bits += 'pac:reg(noserver)' }
    elseif ($pacSrv -and -not $pacUp) { $bits += 'pac:srv(notreg)' }
    if (-not $bits) { $bits = @('idle') }
    $lblDetail.Text = ($bits -join '  ·  ')
}

Update-Status
$Script:timer = New-Object System.Windows.Threading.DispatcherTimer
$Script:timer.Interval = [TimeSpan]::FromSeconds(3)
$Script:timer.Add_Tick({ try { Update-Status } catch { } })
$Script:timer.Start()
$Script:window.Add_Closed({ try { if ($Script:timer) { $Script:timer.Stop() } } catch { } })

# ============================================================================
# Action handlers
# ============================================================================
function Show-Toast([string]$message, [string]$title = 'launcher') {
    [System.Windows.MessageBox]::Show($Script:window, $message, $title,
        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
}

$Script:Busy = $false
function With-Busy([scriptblock]$body) {
    return {
        if ($Script:Busy) { return }
        $Script:Busy = $true
        try {
            $btnStartDpi.IsEnabled  = $false
            $btnStartWarp.IsEnabled = $false
            $btnStartAll.IsEnabled  = $false
            $btnStop.IsEnabled      = $false
            $btnTest.IsEnabled      = $false
            & $body
        } catch {
            Show-Toast "Ошибка: $_"
        } finally {
            $btnStartDpi.IsEnabled  = $true
            $btnStartWarp.IsEnabled = $true
            $btnStartAll.IsEnabled  = $true
            $btnStop.IsEnabled      = $true
            $btnTest.IsEnabled      = $true
            try { Update-Status } catch { }
            $Script:Busy = $false
        }
    }.GetNewClosure()
}

# All three start buttons share the same outcome handling — only the Mode
# argument changes — so funnel through one helper.
function Start-WithMode([string]$mode, [string]$busyText) {
    $lblDetail.Text = $busyText
    $r = Start-Mode -cfg $Script:Cfg -Mode $mode
    if ($r.Success -and $r.Errors.Count -eq 0) {
        # silent — status line will reflect the new state.
    } elseif ($r.Success) {
        Show-Toast ("Запущено с предупреждениями:`n`n" + ($r.Errors -join "`n"))
    } else {
        Show-Toast ("Не удалось запустить:`n`n" + ($r.Errors -join "`n"))
    }
}

$btnStartDpi.Add_Click(  (With-Busy { Start-WithMode 'dpi'  'Запуск DPI...' }) )
$btnStartWarp.Add_Click( (With-Busy { Start-WithMode 'warp' 'Запуск WARP+Гео (при первом разе может ставиться winget)...' }) )
$btnStartAll.Add_Click(  (With-Busy { Start-WithMode 'all'  'Запуск DPI + WARP...' }) )

$btnStop.Add_Click( (With-Busy {
    $lblDetail.Text = 'Остановка...'
    Stop-Combined $Script:Cfg
}) )

$btnSettings.Add_Click({
    # Open the full GUI in the same console (admin already), then re-read config.
    try {
        $gui = Join-Path $PSScriptRoot 'launcher.gui.ps1'
        $proc = Start-Process -FilePath 'powershell.exe' `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gui) `
                    -PassThru
        $proc.WaitForExit()
        $Script:Cfg = Read-Config
        Update-Status
    } catch {
        Show-Toast "Не удалось открыть настройки: $_"
    }
})

$btnTest.Add_Click( (With-Busy {
    $lblDetail.Text = 'Проверка связи (~10 сек)...'
    $t = Test-Connectivity $Script:Cfg
    $lines = @()
    foreach ($k in 'PacServer', 'Warp', 'Dpi', 'Geo') {
        $row = $t[$k]
        $mark = if ($row.Ok) { '[OK]  ' } else { '[FAIL]' }
        $lines += "{0,-6} {1,-9} — {2}" -f $mark, $k, $row.Detail
    }
    Show-Toast ($lines -join "`n") 'Тест соединения'
}) )

# ============================================================================
# Show window
# ============================================================================
Write-BootStep 'showing main window (ShowDialog)'
[void]$Script:window.ShowDialog()
Write-BootStep 'main window closed cleanly'
