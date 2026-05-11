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
    try { Write-Host ("[{0}] chooser> {1}" -f $stamp, $step) -ForegroundColor DarkGray } catch { }
    try {
        $line = "[{0}] chooser> {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $step
        Add-Content -LiteralPath $Script:LogPath -Value $line -Encoding UTF8
    } catch { }
}

# Apartment state MUST be STA for WPF. start.bat passes -STA; if someone ran
# us by hand without it, bail with a clear message.
$apt = [System.Threading.Thread]::CurrentThread.GetApartmentState()
$isAdmin = (New-Object System.Security.Principal.WindowsPrincipal(
    [System.Security.Principal.WindowsIdentity]::GetCurrent())
).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
Write-BootStep ("entered (PSv={0}, apartment={1}, host={2}, admin={3})" -f `
    $PSVersionTable.PSVersion, $apt, $Host.Name, $isAdmin)

if ($apt -ne [System.Threading.ApartmentState]::STA) {
    Write-BootStep "FATAL: not running in STA. Restart powershell.exe with -STA."
    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Red
    Write-Host '  codeDPI chooser cannot start: PowerShell is in MTA mode.' -ForegroundColor Red
    Write-Host '  Re-run via start.bat (it passes -STA) or:' -ForegroundColor Yellow
    Write-Host '    powershell -NoProfile -ExecutionPolicy Bypass -STA -File "utils\launcher.chooser.ps1"' -ForegroundColor Yellow
    Write-Host '=====================================================================' -ForegroundColor Red
    exit 2
}

if (-not $isAdmin) {
    # Elevation is now handled by start.bat. If we got here without admin, the
    # user launched chooser.ps1 directly — tell them to use start.bat.
    Write-BootStep "FATAL: not admin. Elevation is done by start.bat; do not launch chooser.ps1 by hand."
    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Red
    Write-Host '  codeDPI chooser needs administrator rights.' -ForegroundColor Red
    Write-Host '  Run start.bat (double-click, or right-click -> Run as administrator).' -ForegroundColor Yellow
    Write-Host '=====================================================================' -ForegroundColor Red
    exit 3
}

# Top-level safety net: any uncaught error gets logged. bat controls the
# pause-on-exit, so we just bail with a non-zero code.
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
    exit 1
}

Write-BootStep 'loading WPF assemblies'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

Write-BootStep 'sourcing launcher.lib.ps1'
. (Join-Path $PSScriptRoot 'launcher.lib.ps1')
Rotate-LauncherLog
$Script:Cfg = Read-Config
Write-BootStep ("config loaded ({0} keys)" -f $Script:Cfg.Count)

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="codeDPI" Width="600" Height="470"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Background="#181a1f"
        FontFamily="Segoe UI" FontSize="13"
        Foreground="#e8e8e8">
    <Window.Resources>
        <!-- Accent gradient for header bar -->
        <LinearGradientBrush x:Key="AccentGrad" StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#2d6a4f" Offset="0"/>
            <GradientStop Color="#1b4332" Offset="1"/>
        </LinearGradientBrush>
        <!-- Button base template with rounded corners + hover -->
        <Style x:Key="ActionButton" TargetType="Button">
            <Setter Property="Background" Value="#2a2d35"/>
            <Setter Property="Foreground" Value="#e8e8e8"/>
            <Setter Property="BorderBrush" Value="#3c3f47"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,12"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="MinHeight" Value="54"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="b"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="8">
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"
                                              Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="b" Property="Background" Value="#363940"/>
                                <Setter TargetName="b" Property="BorderBrush" Value="#52565e"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="b" Property="Background" Value="#1f2127"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#555"/>
                                <Setter TargetName="b" Property="Background" Value="#1f2127"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="StartButton" TargetType="Button" BasedOn="{StaticResource ActionButton}">
            <Setter Property="Background" Value="#264d3b"/>
            <Setter Property="BorderBrush" Value="#1b4332"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style x:Key="PrimaryStartButton" TargetType="Button" BasedOn="{StaticResource StartButton}">
            <Setter Property="Background" Value="#2d7a55"/>
            <Setter Property="FontSize" Value="14"/>
        </Style>
        <Style x:Key="StopButton" TargetType="Button" BasedOn="{StaticResource ActionButton}">
            <Setter Property="Background" Value="#5c2a2a"/>
            <Setter Property="BorderBrush" Value="#4a2020"/>
        </Style>
        <Style x:Key="SectionLabel" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#7d8290"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Margin" Value="6,0,0,6"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- ═══ Header bar ═══ -->
        <Border Grid.Row="0" Background="{StaticResource AccentGrad}" Padding="20,16">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <!-- Status dot with glow ring behind it -->
                <Grid Grid.Column="0" VerticalAlignment="Center" Margin="0,0,16,0"
                      Width="24" Height="24">
                    <!-- Outer glow — painted first so it sits behind the dot -->
                    <Ellipse x:Name="dotGlow" Width="24" Height="24" Opacity="0.5">
                        <Ellipse.Fill>
                            <RadialGradientBrush>
                                <GradientStop Color="#666666" Offset="0.35"/>
                                <GradientStop Color="Transparent" Offset="1"/>
                            </RadialGradientBrush>
                        </Ellipse.Fill>
                    </Ellipse>
                    <!-- Solid dot on top -->
                    <Ellipse x:Name="dot" Width="12" Height="12" Fill="#666666"
                             HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Grid>
                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock x:Name="lblStatus" Text="Проверка статуса…"
                               FontSize="16" FontWeight="SemiBold" Foreground="#ffffff"/>
                    <TextBlock x:Name="lblDetail" Text="инициализация"
                               FontSize="11" Foreground="#b0d4c0" Margin="0,3,0,0"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- ═══ Main content ═══ -->
        <Grid Grid.Row="1" Margin="20,18,20,12">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="14"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <!-- Section 1: Start -->
            <TextBlock Grid.Row="0" Style="{StaticResource SectionLabel}"
                       Text="▶  ЗАПУСК — выбери режим"/>

            <Grid Grid.Row="1">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="btnStartDpi"  Grid.Column="0" Style="{StaticResource StartButton}"
                        ToolTip="Обход блокировок провайдера: YouTube, Discord, Telegram, Meta, X… (winws.exe, без WARP)">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock Text="DPI" FontWeight="Bold" FontSize="14" HorizontalAlignment="Center"/>
                        <TextBlock Text="обход провайдера" FontSize="10" Opacity="0.75"
                                   HorizontalAlignment="Center" Margin="0,2,0,0"/>
                    </StackPanel>
                </Button>
                <Button x:Name="btnStartWarp" Grid.Column="1" Style="{StaticResource StartButton}"
                        ToolTip="Обход гео-блокировок: ChatGPT, Claude, Gemini, Cursor, Copilot… (WARP SOCKS5 + PAC). WARP ставится автоматически через winget.">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock Text="WARP + Гео" FontWeight="Bold" FontSize="14" HorizontalAlignment="Center"/>
                        <TextBlock Text="AI-сервисы, гео" FontSize="10" Opacity="0.75"
                                   HorizontalAlignment="Center" Margin="0,2,0,0"/>
                    </StackPanel>
                </Button>
                <Button x:Name="btnStartAll"  Grid.Column="2" Style="{StaticResource PrimaryStartButton}"
                        ToolTip="DPI + WARP + PAC одним кликом. Рекомендуется если не знаешь что именно нужно.">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock Text="Всё сразу" FontWeight="Bold" FontSize="14" HorizontalAlignment="Center"/>
                        <TextBlock Text="DPI + WARP + PAC" FontSize="10" Opacity="0.85"
                                   HorizontalAlignment="Center" Margin="0,2,0,0"/>
                    </StackPanel>
                </Button>
            </Grid>

            <!-- Separator -->
            <Rectangle Grid.Row="2" Height="1" Fill="#2e3038" VerticalAlignment="Center" Margin="6,0"/>

            <!-- Section 2: Actions -->
            <TextBlock Grid.Row="3" Style="{StaticResource SectionLabel}" Text="⚙  УПРАВЛЕНИЕ"/>

            <Grid Grid.Row="4">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="btnStop"     Grid.Column="0" Style="{StaticResource StopButton}"
                        ToolTip="Остановить winws, отключить WARP, убрать PAC-регистрацию">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock Text="■  Стоп" FontSize="13" HorizontalAlignment="Center"/>
                        <TextBlock Text="выключить всё" FontSize="10" Opacity="0.7"
                                   HorizontalAlignment="Center" Margin="0,2,0,0"/>
                    </StackPanel>
                </Button>
                <Button x:Name="btnSettings" Grid.Column="1" Style="{StaticResource ActionButton}"
                        ToolTip="Открыть полный GUI: чекбоксы сервисов, выбор стратегии, WARP, WireGuard, системный прокси">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock Text="⚙  Настройки" FontSize="13" HorizontalAlignment="Center"/>
                        <TextBlock Text="сервисы, стратегия, WARP" FontSize="10" Opacity="0.7"
                                   HorizontalAlignment="Center" Margin="0,2,0,0"/>
                    </StackPanel>
                </Button>
                <Button x:Name="btnTest"     Grid.Column="2" Style="{StaticResource ActionButton}"
                        ToolTip="Smoke-test: PAC server / WARP port / DPI путь (youtube) / Geo путь (chatgpt)">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock Text="✓  Тест связи" FontSize="13" HorizontalAlignment="Center"/>
                        <TextBlock Text="проверить работу" FontSize="10" Opacity="0.7"
                                   HorizontalAlignment="Center" Margin="0,2,0,0"/>
                    </StackPanel>
                </Button>
            </Grid>
        </Grid>

        <!-- ═══ Footer ═══ -->
        <Border Grid.Row="2" Background="#14161a" Padding="16,8" BorderBrush="#22252a" BorderThickness="0,1,0,0">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="lblFoot" Grid.Column="0" Foreground="#55595f"
                           FontSize="10.5" VerticalAlignment="Center"
                           Text="codeDPI"/>
                <TextBlock x:Name="lblFootRight" Grid.Column="1" Foreground="#7d8290"
                           FontSize="10.5" VerticalAlignment="Center"
                           Text=""/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

Write-BootStep 'parsing XAML'
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
Write-BootStep 'building WPF window via XamlReader.Load'
$Script:window = [Windows.Markup.XamlReader]::Load($reader)
Write-BootStep 'WPF window built'
function Get-XamlElement([string]$name) { $Script:window.FindName($name) }

$dot       = Get-XamlElement 'dot'
$dotGlow   = Get-XamlElement 'dotGlow'
$lblStatus = Get-XamlElement 'lblStatus'
$lblDetail = Get-XamlElement 'lblDetail'
$lblFoot   = Get-XamlElement 'lblFoot'
$lblFootRight = Get-XamlElement 'lblFootRight'
$btnStartDpi  = Get-XamlElement 'btnStartDpi'
$btnStartWarp = Get-XamlElement 'btnStartWarp'
$btnStartAll  = Get-XamlElement 'btnStartAll'
$btnStop      = Get-XamlElement 'btnStop'
$btnSettings  = Get-XamlElement 'btnSettings'
$btnTest      = Get-XamlElement 'btnTest'

# Verify every critical element was found — if XAML names drift, we want to
# fail fast with a readable error rather than NullReference later.
$required = @{
    dot=$dot; dotGlow=$dotGlow; lblStatus=$lblStatus; lblDetail=$lblDetail
    lblFoot=$lblFoot; lblFootRight=$lblFootRight
    btnStartDpi=$btnStartDpi; btnStartWarp=$btnStartWarp; btnStartAll=$btnStartAll
    btnStop=$btnStop; btnSettings=$btnSettings; btnTest=$btnTest
}
foreach ($kv in $required.GetEnumerator()) {
    if (-not $kv.Value) {
        throw ("XAML element '{0}' not found — launcher.chooser.ps1 XAML is out of sync with the binding list." -f $kv.Key)
    }
}
Write-BootStep ("found {0} XAML elements" -f $required.Count)

$lblFoot.Text = "codeDPI · v$Script:Version"
# Right-side footer updates dynamically in Update-Status (shows strategy).

# ============================================================================
# Status updater
# ============================================================================
function Set-Dot([string]$color) {
    $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($color))
    $dot.Fill = $brush
    # Update glow ring to match
    $glowBrush = New-Object System.Windows.Media.RadialGradientBrush
    $glowBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString($color)), 0.3))
    $glowBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Colors]::Transparent), 1.0))
    $dotGlow.Fill = $glowBrush
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
        $lblStatus.Text = 'Частично: DPI + WARP (без PAC)'
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

    # Sub-line — terse state pills.
    $bits = @()
    if ($dpiUp)  { $bits += 'winws' }
    if ($svcUp)  { $bits += 'service' }
    if ($warpUp) { $bits += 'warp' }
    if ($pacUp -and $pacSrv) { $bits += "pac:$(Get-PacPort $Script:Cfg)" }
    elseif ($pacUp -and -not $pacSrv) { $bits += 'pac: reg есть, сервер упал' }
    elseif ($pacSrv -and -not $pacUp) { $bits += 'pac: сервер есть, reg нет' }
    if (-not $bits) { $bits = @('все выключено') }
    $lblDetail.Text = ($bits -join '  ·  ')

    # Right-side footer: current strategy (trimmed so it fits on 600px window).
    $stratShort = [string]$Script:Cfg.strategy
    if ($stratShort.Length -gt 38) { $stratShort = $stratShort.Substring(0, 35) + '…' }
    $lblFootRight.Text = "стратегия: $stratShort"
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

# Show a monospace-formatted result in a proper WPF dialog. Standard
# MessageBox uses a proportional font that mangles columnar output like
# smoke-test results — this dialog preserves alignment.
function Show-Report([string]$title, [string]$body, [hashtable]$rows = $null) {
    $dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="__TITLE__" Width="560" SizeToContent="Height"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        Background="#181a1f" Foreground="#e8e8e8"
        FontFamily="Segoe UI" FontSize="12">
    <StackPanel Margin="16">
        <TextBlock Text="__TITLE__" FontSize="15" FontWeight="SemiBold"
                   Foreground="#ffffff" Margin="0,0,0,10"/>
        <Border Background="#12141a" BorderBrush="#2a2d35" BorderThickness="1"
                CornerRadius="6" Padding="12">
            <TextBox x:Name="txt" IsReadOnly="True" Background="Transparent"
                     Foreground="#cdf3cd" FontFamily="Consolas" FontSize="12"
                     BorderThickness="0" TextWrapping="NoWrap"
                     VerticalScrollBarVisibility="Auto" MaxHeight="260"/>
        </Border>
        <Button x:Name="btnOk" Content="OK" HorizontalAlignment="Right" Margin="0,12,0,0"
                Padding="24,6" Background="#264d3b" Foreground="#e8e8e8"
                BorderBrush="#1b4332" BorderThickness="1" Cursor="Hand" IsDefault="True"/>
    </StackPanel>
</Window>
'@
    $xamlText = $dlgXaml -replace '__TITLE__', ([System.Security.SecurityElement]::Escape($title))
    $rdr = New-Object System.Xml.XmlNodeReader ([xml]$xamlText)
    $dlg = [Windows.Markup.XamlReader]::Load($rdr)
    $dlg.Owner = $Script:window
    $txt = $dlg.FindName('txt')
    $txt.Text = $body
    $dlg.FindName('btnOk').Add_Click({ $dlg.Close() }.GetNewClosure())
    [void]$dlg.ShowDialog()
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
    # Open the full GUI asynchronously — non-blocking so the status timer
    # keeps firing in this window. Poll the child process with a short-lived
    # DispatcherTimer; when it exits, re-read config and refresh status.
    # WPF requires -STA.
    try {
        $gui = Join-Path $PSScriptRoot 'launcher.gui.ps1'
        if (-not (Test-Path -LiteralPath $gui)) {
            Show-Toast "launcher.gui.ps1 не найден: $gui"
            return
        }
        # Quote the path explicitly — Start-Process -ArgumentList in PS5.1
        # doesn't always quote paths with spaces. Use a single string arg.
        $argString = '-NoProfile -ExecutionPolicy Bypass -STA -File "' + $gui + '"'
        Write-BootStep "launching settings: $argString"
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argString -PassThru -ErrorAction Stop
        if (-not $proc) {
            Show-Toast 'Не удалось запустить окно настроек (Start-Process вернул null).'
            return
        }
        $btnSettings.IsEnabled = $false
        $lblDetail.Text = 'Открыты настройки — закрой то окно, чтобы вернуться сюда'
        $waitTimer = New-Object System.Windows.Threading.DispatcherTimer
        $waitTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $waitTimer.Add_Tick({
            try {
                if ($proc.HasExited) {
                    $waitTimer.Stop()
                    $btnSettings.IsEnabled = $true
                    $Script:Cfg = Read-Config
                    Update-Status
                }
            } catch {
                $waitTimer.Stop()
                $btnSettings.IsEnabled = $true
            }
        }.GetNewClosure())
        $waitTimer.Start()
    } catch {
        Write-BootStep ("settings launch failed: " + $_.Exception.Message)
        Show-Toast "Не удалось открыть настройки:`n`n$($_.Exception.Message)"
    }
})

$btnTest.Add_Click( (With-Busy {
    $lblDetail.Text = 'Проверка связи (~10 сек)...'
    $t = Test-Connectivity $Script:Cfg
    $lines = @()
    foreach ($k in 'PacServer', 'Warp', 'Dpi', 'Geo') {
        $row = $t[$k]
        $mark = if ($row.Ok) { '[  OK  ]' } else { '[ FAIL ]' }
        $lines += "{0}  {1,-9}  {2}" -f $mark, $k, $row.Detail
    }
    Show-Report 'Тест соединения' ($lines -join "`r`n")
}) )

# ============================================================================
# Show window
# ============================================================================
# Wrap ShowDialog in a DispatcherUnhandledException handler so any runtime
# error in WPF (bad binding, etc.) is caught and logged instead of silently
# killing the window. We use Window.ShowDialog() directly (no Application
# instance) because creating an Application.Run() from a script host
# conflicts with PowerShell's own message loop on some hosts.
Write-BootStep 'attaching WPF exception handlers'
try {
    $Script:window.Add_SourceInitialized({
        Write-BootStep 'WPF SourceInitialized — HWND created'
    })
    $Script:window.Add_Loaded({
        Write-BootStep 'WPF Loaded — window is visible'
    })
} catch { Write-BootStep ("handler attach failed: " + $_.Exception.Message) }

Write-BootStep 'showing main window (ShowDialog)'
try {
    [void]$Script:window.ShowDialog()
    Write-BootStep 'main window closed cleanly'
} catch {
    Write-BootStep ("ShowDialog threw: " + $_.Exception.Message)
    try { Add-Content -LiteralPath $Script:LogPath -Value $_.ScriptStackTrace -Encoding UTF8 } catch { }
    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Red
    Write-Host '  codeDPI chooser — window crashed' -ForegroundColor Red
    Write-Host '=====================================================================' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    exit 4
}
