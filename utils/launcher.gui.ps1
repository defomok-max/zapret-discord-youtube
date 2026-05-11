#Requires -Version 5.1
<#
.SYNOPSIS
  WPF-based GUI for codeDPI launcher.
.DESCRIPTION
  Loads launcher.lib.ps1, builds a single-window WPF UI for:
    - DPI services (winws.exe via zapret)
    - Strategy picker + Start/Stop bypass
    - Cloudflare WARP (install / connect / mode / auto-start with bypass)
    - Geo-blocked services routed via WARP using a generated PAC file
    - Custom VPN (WireGuard import, system proxy)
    - Tools (custom domain editor, list updates, diagnostics)
    - Log box
#>

$ErrorActionPreference = 'Stop'

# Top-level safety net: any uncaught error gets logged and shown to the user
# instead of silently closing the cmd window before they can read it.
trap {
    $err = $_
    $msg = "$($err.Exception.GetType().Name): $($err.Exception.Message)"
    try {
        $logPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'launcher.log'
        $line = "[{0}] gui FATAL: {1}`n{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg, $err.ScriptStackTrace
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch { }
    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Red
    Write-Host '  codeDPI GUI — FATAL ERROR' -ForegroundColor Red
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

. (Join-Path $PSScriptRoot 'launcher.lib.ps1')

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName Microsoft.VisualBasic

# ============================================================================
# XAML
# ============================================================================
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="codeDPI — настройки"
        Width="780" Height="820"
        Background="#1b1d22" Foreground="#dddddd"
        FontFamily="Segoe UI" FontSize="12"
        WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style TargetType="Border" x:Key="Card">
      <Setter Property="BorderBrush" Value="#3a3d44"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="12"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Background" Value="#23262d"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="SectionTitle">
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#ffffff"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="Hint">
      <Setter Property="Foreground" Value="#808591"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="Background" Value="#33373f"/>
      <Setter Property="Foreground" Value="#dddddd"/>
      <Setter Property="BorderBrush" Value="#444"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,2,0,2"/>
      <Setter Property="Foreground" Value="#dddddd"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#33373f"/>
      <Setter Property="Foreground" Value="#dddddd"/>
      <Setter Property="BorderBrush" Value="#444"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#15171b"/>
      <Setter Property="Foreground" Value="#cdf3cd"/>
      <Setter Property="BorderBrush" Value="#444"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="11"/>
    </Style>
  </Window.Resources>

  <DockPanel Margin="14">

    <!-- Header -->
    <Border DockPanel.Dock="Top" Margin="0,0,0,10" Padding="14,12" CornerRadius="0">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
          <GradientStop Color="#1b4332" Offset="0"/>
          <GradientStop Color="#2d6a4f" Offset="0.5"/>
          <GradientStop Color="#1b4332" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <StackPanel>
        <TextBlock Text="codeDPI — настройки" FontSize="18" FontWeight="Bold" Foreground="#ffffff"/>
        <TextBlock x:Name="lblStatusLine" Text="loading..." Foreground="#b0d4c0" FontSize="11" Margin="0,3,0,0"/>
      </StackPanel>
    </Border>

    <!-- Log (bottom) -->
    <Border DockPanel.Dock="Bottom" Style="{StaticResource Card}" Padding="6">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="160"/>
        </Grid.RowDefinitions>
        <DockPanel Grid.Row="0">
          <TextBlock Text="Журнал" Style="{StaticResource SectionTitle}" Margin="2,0,0,2"/>
          <Button x:Name="btnLogClear" Content="Очистить" DockPanel.Dock="Right" Padding="8,1" Margin="0,0,0,2"/>
        </DockPanel>
        <TextBox x:Name="txtLog" Grid.Row="1" IsReadOnly="True"
                 VerticalScrollBarVisibility="Auto"
                 TextWrapping="NoWrap"/>
      </Grid>
    </Border>

    <!-- Main content (scrollable) -->
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel>

        <!-- DPI services -->
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="DPI-обход (zapret) — сервисы" Style="{StaticResource SectionTitle}"/>
            <TextBlock Style="{StaticResource Hint}" Text="Домены с DPI-десинхронизацией через winws.exe. YouTube и Discord всегда включены (живут в апстримных списках). Остальное — тумблером. Изменения сохраняются и применяются сразу."/>
            <ItemsControl x:Name="pnlServices">
              <ItemsControl.ItemsPanel>
                <ItemsPanelTemplate>
                  <UniformGrid Columns="2"/>
                </ItemsPanelTemplate>
              </ItemsControl.ItemsPanel>
            </ItemsControl>
          </StackPanel>
        </Border>

        <!-- Strategy + Start/Stop -->
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="Запуск и стратегия" Style="{StaticResource SectionTitle}"/>
            <TextBlock Style="{StaticResource Hint}" Text="Разные провайдеры отвечают на разные техники десинхронизации. Если текущая стратегия перестала работать — попробуй ALT / FAKE TLS AUTO / SIMPLE FAKE по очереди, пока трафик не восстановится."/>
            <DockPanel Margin="0,0,0,10">
              <TextBlock Text="Стратегия:" VerticalAlignment="Center" Margin="0,0,8,0" Width="72"/>
              <ComboBox x:Name="cmbStrategy"/>
            </DockPanel>
            <TextBlock Style="{StaticResource Hint}"
                       Text="Три варианта запуска: только DPI (обход провайдера), только WARP+Гео (AI-сервисы), или всё сразу."/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
              <Button x:Name="btnStartDpi"    Content="▶ Старт DPI"              Background="#264d3b" FontWeight="SemiBold" Padding="14,6"/>
              <Button x:Name="btnStartWarp"   Content="▶ Старт WARP+Гео"         Background="#264d3b" FontWeight="SemiBold" Padding="14,6"/>
              <Button x:Name="btnStartAll"    Content="▶ Старт Всё (DPI+WARP)"   Background="#2d7a55" FontWeight="Bold"     Padding="14,6"/>
              <Button x:Name="btnStop"        Content="■ Стоп"                   Background="#5c2a2a" Padding="14,6"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnInstallSvc"  Content="Установить как Windows-службу…"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <!-- Cloudflare WARP -->
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="Cloudflare WARP" Style="{StaticResource SectionTitle}"/>
            <TextBlock Style="{StaticResource Hint}" Text="Бесплатный, без регистрации. От Cloudflare. Даёт другой выходной IP. Используется тут чтобы достучаться до сервисов, блокирующих RU IP. Авто-старт запускает WARP вместе с каждым нажатием Старт."/>
            <TextBlock x:Name="lblWarpStatus" Margin="0,0,0,8" Foreground="#a0a4ad"/>
            <CheckBox x:Name="chkWarpAutostart"  Content="Авто-запуск WARP при старте bypass (proxy-режим + PAC)"/>
            <CheckBox x:Name="chkAutoInstallWarp" Content="Автоматически ставить WARP через winget, если не найден (работает при Старт WARP/Всё)"/>
            <CheckBox x:Name="chkGeoRouting"     Content="Применять PAC для гео-сервисов (системный AutoConfigURL)"/>
            <DockPanel Margin="0,8,0,8">
              <TextBlock Text="Ручной режим:" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <ComboBox x:Name="cmbWarpMode" Width="160">
                <ComboBoxItem>warp</ComboBoxItem>
                <ComboBoxItem>warp+doh</ComboBoxItem>
                <ComboBoxItem>doh</ComboBoxItem>
                <ComboBoxItem>proxy</ComboBoxItem>
              </ComboBox>
              <Button x:Name="btnWarpApplyMode" Content="Применить режим" DockPanel.Dock="Left" Margin="6,0,0,0"/>
            </DockPanel>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnWarpInstall"     Content="Установить (winget)"/>
              <Button x:Name="btnWarpConnect"     Content="Подключить"/>
              <Button x:Name="btnWarpDisconnect"  Content="Отключить"/>
              <Button x:Name="btnWarpStatusShow"  Content="Подробный статус"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <!-- Geo-blocked services -->
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="Гео-блокированные сервисы (через WARP)" Style="{StaticResource SectionTitle}"/>
            <TextBlock Style="{StaticResource Hint}" Text="Эти домены zapret НЕ разблокирует — они отказывают RU IP на своей стороне. Выбранные идут через WARP по сгенерированному PAC-файлу (работает для Chrome / Edge / IE). Для Firefox нужен ручной PAC URL — см. README."/>
            <ItemsControl x:Name="pnlGeo">
              <ItemsControl.ItemsPanel>
                <ItemsPanelTemplate>
                  <UniformGrid Columns="2"/>
                </ItemsPanelTemplate>
              </ItemsControl.ItemsPanel>
            </ItemsControl>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <Button x:Name="btnGeoRebuild"     Content="Пересобрать PAC сейчас"/>
              <Button x:Name="btnGeoEditCustom"  Content="Правка custom-списка…"/>
              <Button x:Name="btnGeoCopyUrl"     Content="Скопировать PAC URL (для Firefox)"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <!-- Custom VPN -->
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="Свой VPN / прокси" Style="{StaticResource SectionTitle}"/>
            <TextBlock Style="{StaticResource Hint}" Text="Для ТВОЕГО собственного VPN/прокси (свой VPS, платный VPN и т.д.). Случайные публичные прокси мы принципиально НЕ поставляем — это honeypot-ы."/>
            <TextBlock x:Name="lblWgStatus" Margin="0,0,0,8" Foreground="#a0a4ad"/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
              <Button x:Name="btnWgImport"        Content="Импорт WireGuard .conf…"/>
              <Button x:Name="btnWgStop"          Content="Остановить / снять туннели"/>
              <Button x:Name="btnWgInstall"       Content="Установить WireGuard (winget)"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnProxySet"        Content="Системный SOCKS5/HTTP…"/>
              <Button x:Name="btnProxyDisable"    Content="Отключить системный прокси"/>
              <Button x:Name="btnOpenCustomDir"   Content="Открыть папку custom-vpn"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <!-- Tools -->
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="Инструменты" Style="{StaticResource SectionTitle}"/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
              <Button x:Name="btnConnTest"    Content="Тест соединения"/>
              <Button x:Name="btnEditCustom"  Content="Правка custom DPI-доменов"/>
              <Button x:Name="btnUpdateLists" Content="Обновить списки доменов"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnDiagnostics" Content="Диагностика (service.bat)"/>
              <Button x:Name="btnOpenCli"     Content="Открыть консольный лаунчер"/>
            </StackPanel>
          </StackPanel>
        </Border>

      </StackPanel>
    </ScrollViewer>

  </DockPanel>
</Window>
'@

# ============================================================================
# Load XAML
# ============================================================================
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xamlText)
$Script:window = [Windows.Markup.XamlReader]::Load($reader)

function Find($name) { $Script:window.FindName($name) }

$Script:txtLog            = Find 'txtLog'
$Script:lblStatusLine     = Find 'lblStatusLine'
$Script:pnlServices       = Find 'pnlServices'
$Script:pnlGeo            = Find 'pnlGeo'
$Script:cmbStrategy       = Find 'cmbStrategy'
$Script:cmbWarpMode       = Find 'cmbWarpMode'
$Script:lblWarpStatus     = Find 'lblWarpStatus'
$Script:lblWgStatus         = Find 'lblWgStatus'
$Script:chkWarpAutostart    = Find 'chkWarpAutostart'
$Script:chkAutoInstallWarp  = Find 'chkAutoInstallWarp'
$Script:chkGeoRouting       = Find 'chkGeoRouting'

# ============================================================================
# Logging — sink writes to txtLog
# ============================================================================
$Script:LogSink = {
    param([string]$msg, [string]$color)
    if ([string]::IsNullOrEmpty($msg)) { return }
    $time = (Get-Date).ToString('HH:mm:ss')
    $Script:window.Dispatcher.Invoke([Action]{
        $Script:txtLog.AppendText("[$time] $msg`r`n")
        $Script:txtLog.ScrollToEnd()
    })
}

# ============================================================================
# Load config
# ============================================================================
$Script:Cfg = Read-Config

# ============================================================================
# Build dynamic checkboxes
# ============================================================================
$Script:ServiceCheckboxes = @{}
foreach ($key in $Services.Keys) {
    $svc = $Services[$key]
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $svc.Name
    $cb.Tag = $key
    if ($svc.AlwaysOn) {
        $cb.IsChecked = $true
        $cb.IsEnabled = $false
        $cb.Opacity = 0.6
        $cb.ToolTip = 'Always on (built into upstream zapret strategies)'
    } else {
        $cb.IsChecked = ($Script:Cfg["service_$key"] -eq '1')
    }
    $cb.Add_Click({
        $k = $this.Tag
        $Script:Cfg["service_$k"] = if ($this.IsChecked) { '1' } else { '0' }
        Save-Config $Script:Cfg
        Apply-Services $Script:Cfg
        Write-LauncherLog "DPI service '$($Services[$k].Name)' -> $(if ($this.IsChecked) { 'ON' } else { 'OFF' })" 'Cyan'
    })
    $null = $Script:pnlServices.Items.Add($cb)
    $Script:ServiceCheckboxes[$key] = $cb
}

$Script:GeoCheckboxes = @{}
foreach ($key in $GeoServices.Keys) {
    $svc = $GeoServices[$key]
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $svc.Name
    $cb.Tag = $key
    $cb.IsChecked = ($Script:Cfg["geo_$key"] -eq '1')
    $cb.Add_Click({
        $k = $this.Tag
        $Script:Cfg["geo_$k"] = if ($this.IsChecked) { '1' } else { '0' }
        Save-Config $Script:Cfg
        # If WARP+PAC currently enabled, rebuild on the fly.
        if (Test-PacEnabled $Script:Cfg) {
            Write-PacFile $Script:Cfg | Out-Null
            Write-LauncherLog "PAC rebuilt: '$($GeoServices[$k].Name)' -> $(if ($this.IsChecked) { 'ON' } else { 'OFF' })" 'Cyan'
        } else {
            Write-LauncherLog "Geo service '$($GeoServices[$k].Name)' -> $(if ($this.IsChecked) { 'ON' } else { 'OFF' }) (apply on next Start bypass)" 'DarkGray'
        }
    })
    $null = $Script:pnlGeo.Items.Add($cb)
    $Script:GeoCheckboxes[$key] = $cb
}

# Strategy combobox
foreach ($f in (Get-StrategyFiles)) { $null = $Script:cmbStrategy.Items.Add($f) }
$Script:cmbStrategy.SelectedItem = $Script:Cfg.strategy
$Script:cmbStrategy.Add_SelectionChanged({
    if ($Script:cmbStrategy.SelectedItem) {
        $Script:Cfg.strategy = [string]$Script:cmbStrategy.SelectedItem
        Save-Config $Script:Cfg
        Write-LauncherLog "Strategy: $($Script:Cfg.strategy)" 'Cyan'
    }
})

# WARP mode combobox — match by Content
foreach ($it in $Script:cmbWarpMode.Items) {
    if ([string]$it.Content -eq $Script:Cfg.warp_mode) {
        $Script:cmbWarpMode.SelectedItem = $it
        break
    }
}

# Auto-start toggles
$Script:chkWarpAutostart.IsChecked    = ($Script:Cfg.warp_autostart    -eq '1')
$Script:chkAutoInstallWarp.IsChecked  = ($Script:Cfg.auto_install_warp -eq '1')
$Script:chkGeoRouting.IsChecked       = ($Script:Cfg.geo_routing       -eq '1')
$Script:chkAutoInstallWarp.Add_Click({
    $Script:Cfg.auto_install_warp = if ($this.IsChecked) { '1' } else { '0' }
    Save-Config $Script:Cfg
})
$Script:chkWarpAutostart.Add_Click({
    $Script:Cfg.warp_autostart = if ($this.IsChecked) { '1' } else { '0' }
    Save-Config $Script:Cfg
    Write-LauncherLog "WARP auto-start: $(if ($this.IsChecked) { 'ON' } else { 'OFF' })" 'Cyan'
})
$Script:chkGeoRouting.Add_Click({
    $Script:Cfg.geo_routing = if ($this.IsChecked) { '1' } else { '0' }
    Save-Config $Script:Cfg
    Write-LauncherLog "PAC geo-routing: $(if ($this.IsChecked) { 'ON' } else { 'OFF' })" 'Cyan'
})

# ============================================================================
# Status updater (DispatcherTimer)
# ============================================================================
# Cached pieces — refreshed on a slower cadence than the status timer to avoid
# hammering Get-Service every 3 seconds on machines with many services.
$Script:WgCacheTick    = 0
$Script:WgInstalledExe = $null
$Script:WgTunnels      = @()

function Update-Status {
    $bypass = if (Test-WinwsRunning) { 'РАБОТАЕТ' } else { 'остановлен' }
    $svc    = if (Test-ServiceInstalled 'zapret') {
                  if (Test-ServiceRunning 'zapret') { 'служба работает' } else { 'служба установлена (не запущена)' }
              } else { 'без службы' }
    $warp   = Get-WarpStatus
    $warpStr = if (-not $warp.Installed) { 'не установлен' }
               elseif ($warp.Connected)  { 'подключён' }
               else                      { 'отключён' }

    $pac = Test-PacEnabled $Script:Cfg
    $pacSrv = Test-PacServerRunning
    $pacStr = if ($pac -and $pacSrv) { 'PAC активен' }
              elseif ($pac)          { 'PAC reg есть, сервер УПАЛ' }
              elseif ($pacSrv)       { 'сервер PAC есть (не зарег.)' }
              else                   { 'PAC выкл' }

    $Script:lblStatusLine.Text = "Bypass: $bypass   |   Win-служба: $svc   |   WARP: $warpStr   |   $pacStr"
    $Script:lblWarpStatus.Text = "WARP: $warpStr"

    # Refresh WG cache every ~5th tick (~15 sec) — Get-Service can be slow.
    $Script:WgCacheTick++
    if ($Script:WgCacheTick -ge 5 -or -not $Script:WgInstalledExe) {
        $Script:WgInstalledExe = Get-WireGuardExe
        $Script:WgTunnels      = Get-WireGuardTunnels
        $Script:WgCacheTick    = 0
    }
    $proxy = Get-SystemProxyStatus
    $wgLine = "WireGuard: $(if ($Script:WgInstalledExe) { 'установлен' } else { 'НЕ установлен' })"
    if ($Script:WgTunnels) { $wgLine += "   |   туннели: $($Script:WgTunnels.Name -join ', ')" }
    if ($proxy.Enabled) { $wgLine += "   |   системный прокси: $($proxy.Server)" }
    if ($proxy.AutoConfigURL) { $wgLine += "   |   AutoConfigURL установлен" }
    $Script:lblWgStatus.Text = $wgLine
}
Update-Status

$Script:timer = New-Object System.Windows.Threading.DispatcherTimer
$Script:timer.Interval = [TimeSpan]::FromSeconds(3)
$Script:timer.Add_Tick({ try { Update-Status } catch { } })
$Script:timer.Start()

# Stop the timer cleanly when the window is closed; otherwise the dispatcher
# keeps the process alive in some PS hosts.
$Script:window.Add_Closed({
    try { if ($Script:timer) { $Script:timer.Stop() } } catch { }
})

# ============================================================================
# Button wiring
# ============================================================================
$Script:Busy = $false
function Catch-Click([scriptblock]$body) {
    return {
        if ($Script:Busy) { return }
        $Script:Busy = $true
        try { & $body } catch { Write-LauncherLog "ERROR: $_" 'Red' }
        try { Update-Status } catch { }
        $Script:Busy = $false
    }.GetNewClosure()
}

# Wrap an action so the bypass buttons are disabled while it runs — prevents
# double-clicks from racing Start/Stop or a long warp-cli call.
function With-BypassBusy([scriptblock]$body) {
    return {
        if ($Script:Busy) { return }
        $Script:Busy = $true
        $btnNames = @('btnStartDpi', 'btnStartWarp', 'btnStartAll', 'btnStop')
        $btns = foreach ($n in $btnNames) { Find $n }
        try {
            foreach ($b in $btns) { if ($b) { $b.IsEnabled = $false } }
            & $body
        } catch {
            Write-LauncherLog "ERROR: $_" 'Red'
        } finally {
            foreach ($b in $btns) { if ($b) { $b.IsEnabled = $true } }
            try { Update-Status } catch { }
            $Script:Busy = $false
        }
    }.GetNewClosure()
}

# ---- Bypass ----
function Run-StartMode([string]$mode) {
    Write-LauncherLog ("Старт (режим={0})..." -f $mode) 'Yellow'
    $r = Start-Mode -cfg $Script:Cfg -Mode $mode
    $col = if ($r.Success) { if ($r.Errors.Count -eq 0) { 'Green' } else { 'Yellow' } } else { 'Red' }
    Write-LauncherLog $r.Message $col
    if ($r.Errors.Count -gt 0) {
        foreach ($e in $r.Errors) { Write-LauncherLog "  $e" 'DarkYellow' }
    }
}

(Find 'btnStartDpi' ).Add_Click( (With-BypassBusy { Run-StartMode 'dpi'  }) )
(Find 'btnStartWarp').Add_Click( (With-BypassBusy { Run-StartMode 'warp' }) )
(Find 'btnStartAll' ).Add_Click( (With-BypassBusy { Run-StartMode 'all'  }) )

(Find 'btnStop').Add_Click( (With-BypassBusy {
    Write-LauncherLog 'Остановка...' 'Yellow'
    Stop-Combined $Script:Cfg
    Write-LauncherLog 'Остановлено.' 'Green'
}) )

(Find 'btnInstallSvc').Add_Click( (Catch-Click {
    $bat = Join-Path $RepoRoot 'service.bat'
    if (-not (Test-Path -LiteralPath $bat)) { throw "service.bat не найден: $bat" }
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', "call `"$bat`"")
    Write-LauncherLog 'Открыт service.bat в новом окне — установи/удали Windows-службу оттуда.' 'Cyan'
}) )

# ---- WARP ----
(Find 'btnWarpInstall').Add_Click( (Catch-Click {
    Install-Warp | Out-Null
}) )

(Find 'btnWarpConnect').Add_Click( (Catch-Click {
    Connect-Warp
    Write-LauncherLog 'WARP: connect requested.' 'Cyan'
}) )

(Find 'btnWarpDisconnect').Add_Click( (Catch-Click {
    Disconnect-Warp
    Write-LauncherLog 'WARP: disconnect requested.' 'Cyan'
}) )

(Find 'btnWarpApplyMode').Add_Click( (Catch-Click {
    if ($Script:cmbWarpMode.SelectedItem) {
        $m = [string]$Script:cmbWarpMode.SelectedItem.Content
        Set-WarpMode $m
        $Script:Cfg.warp_mode = $m
        Save-Config $Script:Cfg
        Write-LauncherLog "WARP mode -> $m" 'Cyan'
    }
}) )

(Find 'btnWarpStatusShow').Add_Click( (Catch-Click {
    $st = Get-WarpStatus
    if ($st.Installed) {
        foreach ($l in ($st.Raw -split "`n")) { Write-LauncherLog $l 'DarkGray' }
    } else {
        Write-LauncherLog 'WARP is not installed.' 'Red'
    }
}) )

# ---- Geo ----
(Find 'btnGeoRebuild').Add_Click( (Catch-Click {
    $info = Write-PacFile $Script:Cfg
    # If PAC is currently active OR auto-routing is enabled, also (re)start the
    # localhost server + register AutoConfigURL so changes take effect now.
    if ((Test-PacEnabled $Script:Cfg) -or ($Script:Cfg.geo_routing -eq '1' -and $Script:Cfg.warp_autostart -eq '1')) {
        $srv = Start-PacServer $Script:Cfg
        Enable-PacAutoConfig $Script:Cfg | Out-Null
        Write-LauncherLog "PAC rebuilt: $($info.DomainCount) domain(s) -> WARP. Serving at $($srv.Url)" 'Green'
    } else {
        Write-LauncherLog "PAC rebuilt: $($info.DomainCount) domain(s) (offline; will be served on next Start)" 'Cyan'
    }
}) )

(Find 'btnGeoEditCustom').Add_Click( (Catch-Click {
    Open-CustomGeoDomains
}) )

(Find 'btnGeoCopyUrl').Add_Click( (Catch-Click {
    $u = Get-PacFileUrl $Script:Cfg
    [System.Windows.Clipboard]::SetText($u)
    Write-LauncherLog "PAC URL скопирован в буфер: $u" 'Cyan'
    Write-LauncherLog "Firefox: about:preferences -> Network Settings -> Automatic proxy configuration URL -> вставить." 'DarkGray'
    if (-not (Test-PacServerRunning)) {
        Write-LauncherLog 'Внимание: PAC-сервер ещё не запущен. Нажми Старт (или Подключить WARP), иначе Firefox не сможет загрузить URL.' 'Yellow'
    }
}) )

# ---- Custom VPN ----
(Find 'btnWgImport').Add_Click( (Catch-Click {
    if (-not (Test-Path $CustomDir)) { $null = New-Item -ItemType Directory -Path $CustomDir }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'WireGuard config (*.conf)|*.conf'
    $dlg.InitialDirectory = $CustomDir
    if ($dlg.ShowDialog() -eq $true) {
        Install-WireGuardTunnel $dlg.FileName
        Write-LauncherLog "Imported WireGuard tunnel: $($dlg.FileName)" 'Green'
    }
}) )

(Find 'btnWgStop').Add_Click( (Catch-Click {
    $n = Stop-WireGuardTunnels
    Write-LauncherLog "Stopped $n WireGuard tunnel(s)." $(if ($n -gt 0) { 'Green' } else { 'DarkGray' })
}) )

(Find 'btnWgInstall').Add_Click( (Catch-Click {
    Install-WireGuard | Out-Null
}) )

(Find 'btnProxySet').Add_Click( (Catch-Click {
    $p = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Примеры:`r`n  socks=127.0.0.1:1080`r`n  http=proxy.example.com:8080`r`n  myproxy.example.com:3128",
        'Системный прокси', '')
    if ($p) {
        Set-SystemProxy $p
        Write-LauncherLog "Системный прокси установлен: $p" 'Green'
    }
}) )

(Find 'btnProxyDisable').Add_Click( (Catch-Click {
    Disable-SystemProxy
    Write-LauncherLog 'Системный прокси отключён.' 'Green'
}) )

(Find 'btnOpenCustomDir').Add_Click( (Catch-Click {
    if (-not (Test-Path $CustomDir)) { $null = New-Item -ItemType Directory -Path $CustomDir }
    Start-Process explorer.exe $CustomDir
}) )

# ---- Tools ----
(Find 'btnEditCustom').Add_Click(  (Catch-Click { Open-CustomDomains; Write-LauncherLog 'Открыт lists/list-custom.txt — сохрани, закрой и перезапусти bypass.' 'DarkGray' }) )
(Find 'btnUpdateLists').Add_Click( (Catch-Click { Update-Lists }) )
(Find 'btnDiagnostics').Add_Click( (Catch-Click { Run-Diagnostics }) )
(Find 'btnOpenCli').Add_Click( (Catch-Click {
    $bat = Join-Path $RepoRoot 'launcher.bat'
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', "call `"$bat`" admin cli")
}) )
(Find 'btnConnTest').Add_Click( (Catch-Click {
    Write-LauncherLog 'Тест соединения: PAC-сервер, WARP-прокси, DPI-путь (youtube), Geo-путь (chatgpt через WARP)...' 'Yellow'
    $t = Test-Connectivity $Script:Cfg
    foreach ($k in 'PacServer','Warp','Dpi','Geo') {
        $row = $t[$k]
        $col = if ($row.Ok) { 'Green' } else { 'Yellow' }
        $tag = if ($row.Ok) { 'OK  ' } else { 'FAIL' }
        Write-LauncherLog ("{0,-10} [{1}] {2}" -f $k, $tag, $row.Detail) $col
    }
}) )

(Find 'btnLogClear').Add_Click({ $Script:txtLog.Clear() })

# ============================================================================
# Apply current toggles to lists/list-general-user.txt at startup
# ============================================================================
try {
    Apply-Services $Script:Cfg
    Write-LauncherLog "Загружен конфиг: $ConfigPath" 'DarkGray'
    Write-LauncherLog "DPI-сервисы применены -> lists/list-general-user.txt" 'DarkGray'
} catch {
    Write-LauncherLog "Ошибка при старте: $_" 'Red'
}

# ============================================================================
# Show window
# ============================================================================
[void]$Script:window.ShowDialog()
