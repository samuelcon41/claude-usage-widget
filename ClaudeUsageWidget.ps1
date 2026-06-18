# ClaudeUsageWidget.ps1 - floating, draggable, always-on-top 5-hour limit tracker.
#
# Data sources, best first:
#   1. LIVE  - reads ~/.claude/.credentials.json and polls Anthropic's OAuth
#              usage endpoint for the exact 5h/weekly limit %. When the access
#              token expires it delegates renewal to the `claude` CLI (which
#              refreshes the credentials file via its own supported mechanism);
#              the widget never POSTs the refresh endpoint itself, because doing
#              so reliably gets the account stuck on HTTP 429.
#   2. EST.  - otherwise estimates % from local transcripts (~/.claude/projects),
#              calibrated against the last time the limit was actually hit
#              (found in the desktop app's logs).

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:DataDir    = Join-Path $env:USERPROFILE '.claude\projects'
$script:LogDir     = Join-Path $env:APPDATA 'Claude\logs'
$script:StateFile  = Join-Path $PSScriptRoot 'widget-state.json'
$script:ConfigFile = Join-Path $PSScriptRoot 'config.json'
$script:TokenFile  = Join-Path $PSScriptRoot 'token.txt'
$script:ClaudeExe  = Join-Path $env:USERPROFILE '.local\bin\claude.exe'

# ---------------- transcript parsing ----------------

function Get-UsageEntries([datetime]$cutoff) {
    $entries = @{}
    $files = Get-ChildItem -Path $script:DataDir -Filter *.jsonl -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -gt $cutoff }
    foreach ($f in $files) {
        try {
            $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
            $sr = New-Object System.IO.StreamReader($fs)
            try {
                while ($null -ne ($line = $sr.ReadLine())) {
                    if ($line.IndexOf('"usage"') -lt 0 -or $line.IndexOf('"assistant"') -lt 0) { continue }
                    $tsM = [regex]::Match($line, '"timestamp"\s*:\s*"([^"]+)"')
                    if (-not $tsM.Success) { continue }
                    $t = [datetime]::Parse($tsM.Groups[1].Value, $null,
                         [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
                    if ($t -lt $cutoff) { continue }

                    $idM = [regex]::Match($line, '"id"\s*:\s*"(msg_[^"]+)"')
                    $key = if ($idM.Success) { $idM.Groups[1].Value } else { [guid]::NewGuid().ToString() }

                    $in = 0; $out = 0; $cw = 0; $cr = 0
                    $m = [regex]::Match($line, '"input_tokens"\s*:\s*(\d+)')
                    if ($m.Success) { $in = [long]$m.Groups[1].Value }
                    $m = [regex]::Match($line, '"output_tokens"\s*:\s*(\d+)')
                    if ($m.Success) { $out = [long]$m.Groups[1].Value }
                    $m = [regex]::Match($line, '"cache_creation_input_tokens"\s*:\s*(\d+)')
                    if ($m.Success) { $cw = [long]$m.Groups[1].Value }
                    $m = [regex]::Match($line, '"cache_read_input_tokens"\s*:\s*(\d+)')
                    if ($m.Success) { $cr = [long]$m.Groups[1].Value }

                    $entries[$key] = [pscustomobject]@{ Time = $t; In = $in; Out = $out; CacheW = $cw; CacheR = $cr }
                }
            } finally { $sr.Close() }
        } catch { }
    }
    @($entries.Values | Sort-Object Time)
}

# Cost-style weighting so cache reads (cheap) don't swamp real usage
function Get-WeightedTotal($entries) {
    $t = [long]0
    foreach ($x in $entries) {
        $t += $x.In + [long](1.25 * $x.CacheW) + [long](0.1 * $x.CacheR) + 5 * $x.Out
    }
    $t
}

# 5-hour blocks: start at top of the hour of first message; new block after 5h or a 5h idle gap
function Get-Blocks($e) {
    $blocks = New-Object System.Collections.ArrayList
    $blockStart = $null; $last = $null; $cur = $null
    foreach ($x in $e) {
        if ($null -eq $blockStart -or
            ($x.Time - $blockStart).TotalHours -ge 5 -or
            ($x.Time - $last.Time).TotalHours -ge 5) {
            $blockStart = $x.Time.Date.AddHours($x.Time.Hour)
            $cur = [pscustomobject]@{ Start = $blockStart; Entries = (New-Object System.Collections.ArrayList) }
            [void]$blocks.Add($cur)
        }
        [void]$cur.Entries.Add($x)
        $last = $x
    }
    ,$blocks
}

# ---------------- calibration ----------------
# The desktop app logs an "exceeded_limit" error when the 5h limit is hit.
# Tokens spent in that window = a real-world 100% reference.

function Get-CalibratedBudget($allEntries) {
    $best = [long]0
    if (-not (Test-Path $script:LogDir)) { return $best }
    foreach ($lf in Get-ChildItem $script:LogDir -Filter *.log -File -ErrorAction SilentlyContinue) {
        try {
            $fs = [System.IO.File]::Open($lf.FullName, 'Open', 'Read', 'ReadWrite')
            $sr = New-Object System.IO.StreamReader($fs)
            try {
                while ($null -ne ($line = $sr.ReadLine())) {
                    if ($line.IndexOf('exceeded_limit') -lt 0 -or $line.IndexOf('five_hour') -lt 0) { continue }
                    $m = [regex]::Match($line, 'resetsAt\\?"\s*:\s*(\d{10})')
                    if (-not $m.Success) { continue }
                    $reset = [DateTimeOffset]::FromUnixTimeSeconds([long]$m.Groups[1].Value).LocalDateTime
                    $start = $reset.AddHours(-5)
                    $win = @($allEntries | Where-Object { $_.Time -ge $start -and $_.Time -lt $reset })
                    if ($win.Count -gt 0) {
                        $w = Get-WeightedTotal $win
                        if ($w -gt $best) { $best = $w }
                    }
                }
            } finally { $sr.Close() }
        } catch { }
    }
    $best
}

function Initialize-Budget {
    $all    = Get-UsageEntries ([datetime]::MinValue)
    $calib  = Get-CalibratedBudget $all
    $hist   = [long]0
    foreach ($b in (Get-Blocks $all)) {
        $w = Get-WeightedTotal $b.Entries
        if ($w -gt $hist) { $hist = $w }
    }
    $stored = [long]0; $storedSrc = ''
    if (Test-Path $script:ConfigFile) {
        try {
            $c = Get-Content $script:ConfigFile -Raw | ConvertFrom-Json
            $stored = [long]$c.Budget; $storedSrc = [string]$c.Source
        } catch { }
    }
    if ($calib -gt 0) {
        $script:Budget = [math]::Max($calib, $stored)
        $script:BudgetSource = 'calibrated'
    } elseif ($storedSrc -eq 'calibrated' -and $stored -gt 0) {
        $script:Budget = $stored
        $script:BudgetSource = 'calibrated'
    } else {
        $script:Budget = [math]::Max([math]::Max($hist, $stored), 1000000)
        $script:BudgetSource = 'historical-max'
    }
    Save-BudgetConfig
}

function Save-BudgetConfig {
    try {
        @{ Budget = $script:Budget; Source = $script:BudgetSource } | ConvertTo-Json |
            Out-File -FilePath $script:ConfigFile -Encoding utf8
    } catch { }
}

# ---------------- live mode (optional) ----------------

function Get-AccessToken {
    # Preferred: CLI credentials from interactive login (has the user:profile
    # scope the usage endpoint needs). Auto-refreshes when expired.
    $cf = Join-Path $env:USERPROFILE '.claude\.credentials.json'
    if (Test-Path $cf) {
        try {
            $cred = Get-Content $cf -Raw | ConvertFrom-Json
            $c = $cred.claudeAiOauth
            if ($c -and $c.accessToken) {
                $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                if (-not $c.expiresAt -or [long]$c.expiresAt -gt ($nowMs + 300000)) {
                    return $c.accessToken
                }
                # Token expired/near-expiry. Delegate renewal to the claude CLI,
                # which refreshes ~/.claude/.credentials.json using its own
                # supported mechanism. We do NOT POST the refresh endpoint
                # ourselves - doing so (esp. while a token is still valid, or too
                # often) gets the account stuck in a persistent 429 penalty.
                # The CLI refreshes at the correct moment (at/after expiry), which
                # is the pattern that actually works.
                if ((Get-Date) -ge $script:NextRefreshTry) {
                    # Optimistic throttle; lengthened to 60 min below if the
                    # refresh fails, so a broken refresh can't spawn a billable
                    # CLI call every few minutes.
                    $script:NextRefreshTry = (Get-Date).AddMinutes(15)
                    if (Test-Path $script:ClaudeExe) {
                        try {
                            # Tiny print-mode call - the CLI renews the token while
                            # initializing, before the (negligible) inference runs.
                            $psi = New-Object System.Diagnostics.ProcessStartInfo
                            $psi.FileName               = $script:ClaudeExe
                            $psi.Arguments              = '-p "."'
                            $psi.UseShellExecute        = $false
                            $psi.CreateNoWindow         = $true
                            $psi.RedirectStandardOutput = $true
                            $psi.RedirectStandardError  = $true
                            $proc = [System.Diagnostics.Process]::Start($psi)
                            if (-not $proc.WaitForExit(45000)) { try { $proc.Kill() } catch { } }
                            # Re-read the file the CLI just refreshed
                            $cred2 = Get-Content $cf -Raw | ConvertFrom-Json
                            $c2 = $cred2.claudeAiOauth
                            if ($c2.accessToken -and $c2.expiresAt -and
                                [long]$c2.expiresAt -gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) {
                                return $c2.accessToken
                            }
                        } catch { }
                    }
                    # Refresh didn't produce a valid token - wait an hour before retry
                    $script:NextRefreshTry = (Get-Date).AddMinutes(60)
                }
            }
        } catch { }
    }
    # Fallback: manually provided token
    if (Test-Path $script:TokenFile) {
        $t = (Get-Content $script:TokenFile -Raw -ErrorAction SilentlyContinue)
        if ($t) { $t = $t.Trim() }
        if ($t) { return $t }
    }
    $null
}

$script:LiveData       = $null
$script:NextFetch      = [datetime]::MinValue
$script:NextRefreshTry = [datetime]::MinValue

function Update-LiveData {
    # All throttling happens BEFORE any network call (incl. the token refresh
    # inside Get-AccessToken): poll every 5 min, back off 20 min on failure.
    $now = Get-Date
    if ($now -lt $script:NextFetch) { return }
    $tok = Get-AccessToken
    if (-not $tok) {
        $script:LiveData  = $null
        $script:NextFetch = $now.AddMinutes(5)
        return
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $script:LiveData = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Method Get `
            -Headers @{ Authorization = "Bearer $tok"; 'anthropic-beta' = 'oauth-2025-04-20' } `
            -UserAgent 'claude-code/2.1.0' -TimeoutSec 15
        $script:NextFetch = $now.AddMinutes(5)
    } catch {
        $script:LiveData  = $null
        $script:NextFetch = $now.AddMinutes(20)
    }
}

# ---------------- local stats ----------------

function Get-Stats {
    $e   = Get-UsageEntries ((Get-Date).AddHours(-26))
    $now = Get-Date
    $stats = [pscustomobject]@{
        Active = $false; BlockStart = $null; BlockEnd = $null
        SessMsgs = 0; SessWeighted = [long]0
        TodayMsgs = 0; TodayTok = [long]0
    }
    foreach ($x in $e) {
        if ($x.Time.Date -eq $now.Date) {
            $stats.TodayMsgs++
            $stats.TodayTok += $x.In + $x.Out
        }
    }
    if ($e.Count -eq 0) { return $stats }
    $blocks = Get-Blocks $e
    $b = $blocks[$blocks.Count - 1]
    $lastT = $b.Entries[$b.Entries.Count - 1].Time
    if (($now - $b.Start).TotalHours -lt 5 -and ($now - $lastT).TotalHours -lt 5) {
        $stats.Active       = $true
        $stats.BlockStart   = $b.Start
        $stats.BlockEnd     = $b.Start.AddHours(5)
        $stats.SessMsgs     = $b.Entries.Count
        $stats.SessWeighted = Get-WeightedTotal $b.Entries
    }
    $stats
}

function Format-Tokens([long]$n) {
    if ($n -ge 1000000) { return ('{0:N1}M' -f ($n / 1000000)) }
    if ($n -ge 1000)    { return ('{0:N1}K' -f ($n / 1000)) }
    [string]$n
}

function Format-Countdown([datetime]$end) {
    $ts = $end - (Get-Date)
    if ($ts.TotalSeconds -le 0) { return 'now' }
    if ($ts.TotalMinutes -lt 60) { return ('{0}m' -f [int][math]::Ceiling($ts.TotalMinutes)) }
    '{0}h {1:d2}m' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes
}

# ---------------- UI ----------------

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude 5h Limit" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize"
        Left="100" Top="100">
  <Border CornerRadius="12" Background="#F01B1B26" BorderBrush="#44C97B5A" BorderThickness="1" Padding="16,12,16,14">
    <StackPanel MinWidth="235">
      <DockPanel Margin="0,0,0,8">
        <TextBlock Text="&#x25CF;" Foreground="#D97757" FontSize="13" VerticalAlignment="Center"/>
        <TextBlock Text=" Claude &#x2014; 5-hour limit" Foreground="#EDEDF2" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <Button x:Name="CloseBtn" DockPanel.Dock="Right" HorizontalAlignment="Right" Content="&#x2715;"
                Foreground="#8888A0" Background="Transparent" BorderThickness="0" FontSize="12"
                Padding="6,0" Cursor="Hand"/>
      </DockPanel>

      <StackPanel Orientation="Horizontal" Margin="0,0,0,2">
        <TextBlock x:Name="FivePct" Text="--%" Foreground="#EDEDF2" FontSize="30" FontWeight="Bold"/>
        <TextBlock x:Name="ModeTag" Text=" est." Foreground="#9A9AB0" FontSize="12" VerticalAlignment="Bottom" Margin="4,0,0,6"/>
      </StackPanel>
      <ProgressBar x:Name="FiveBar" Height="8" Minimum="0" Maximum="100" Value="0"
                   Background="#33334050" Foreground="#D97757" BorderThickness="0" Margin="0,0,0,4"/>
      <TextBlock x:Name="ResetLine"  Text="" Foreground="#C9C9D8" FontSize="12"/>
      <TextBlock x:Name="WindowLine" Text="" Foreground="#9A9AB0" FontSize="11" Margin="0,1,0,8"/>

      <StackPanel x:Name="WeekPanel" Visibility="Collapsed" Margin="0,0,0,8">
        <TextBlock Text="WEEKLY LIMIT" Foreground="#9A9AB0" FontSize="10" Margin="0,2,0,3"/>
        <ProgressBar x:Name="WeekBar" Height="5" Minimum="0" Maximum="100" Value="0"
                     Background="#33334050" Foreground="#7B9ED9" BorderThickness="0" Margin="0,0,0,3"/>
        <TextBlock x:Name="WeekLine" Text="" Foreground="#C9C9D8" FontSize="11"/>
      </StackPanel>

      <TextBlock x:Name="TodayLine"   Text="" Foreground="#9A9AB0" FontSize="11"/>
      <TextBlock x:Name="UpdatedLine" Text="" Foreground="#66667A" FontSize="10" HorizontalAlignment="Right" Margin="0,4,0,0"/>
    </StackPanel>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$ui = @{}
foreach ($n in 'CloseBtn','FivePct','ModeTag','FiveBar','ResetLine','WindowLine','WeekPanel','WeekBar','WeekLine','TodayLine','UpdatedLine') {
    $ui[$n] = $window.FindName($n)
}

if (Test-Path $script:StateFile) {
    try {
        $st = Get-Content $script:StateFile -Raw | ConvertFrom-Json
        $window.Left = $st.Left; $window.Top = $st.Top
    } catch { }
}

$window.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })
$ui.CloseBtn.Add_Click({ $window.Close() })
$window.Add_Closing({
    try {
        @{ Left = $window.Left; Top = $window.Top } | ConvertTo-Json |
            Out-File -FilePath $script:StateFile -Encoding utf8
    } catch { }
})

$bc = New-Object System.Windows.Media.BrushConverter
function Set-BarColor($bar, $pct) {
    $color = if ($pct -ge 90) { '#E05252' } elseif ($pct -ge 70) { '#E0A030' } else { '#D97757' }
    $bar.Foreground = $bc.ConvertFromString($color)
}

function Update-Widget {
    try {
        Update-LiveData
        $s = Get-Stats

        if ($script:LiveData -and $script:LiveData.five_hour) {
            # LIVE: exact server-side numbers
            $fh    = $script:LiveData.five_hour
            $pct   = [math]::Round([double]$fh.utilization)
            $reset = [DateTimeOffset]::Parse($fh.resets_at).LocalDateTime
            $ui.FivePct.Text  = ('{0}%' -f $pct)
            $ui.ModeTag.Text  = ' live'
            $ui.FiveBar.Value = $pct
            Set-BarColor $ui.FiveBar $pct
            $ui.ResetLine.Text = ('resets in {0} (at {1:HH:mm})' -f (Format-Countdown $reset), $reset)
            $sd = $script:LiveData.seven_day
            if ($sd) {
                $wp = [math]::Round([double]$sd.utilization)
                $wr = [DateTimeOffset]::Parse($sd.resets_at).LocalDateTime
                $ui.WeekBar.Value = $wp
                $ui.WeekLine.Text = ('{0}%  -  resets {1:ddd HH:mm}' -f $wp, $wr)
                $ui.WeekPanel.Visibility = 'Visible'
            } else { $ui.WeekPanel.Visibility = 'Collapsed' }
        } else {
            # ESTIMATE: local transcripts vs calibrated budget
            $ui.WeekPanel.Visibility = 'Collapsed'
            $ui.ModeTag.Text = ' est.'
            if ($s.Active) {
                if ($s.SessWeighted -gt $script:Budget) {
                    $script:Budget = $s.SessWeighted
                    Save-BudgetConfig
                }
                $pct = [math]::Min(100, [math]::Round(100.0 * $s.SessWeighted / $script:Budget))
                $ui.FivePct.Text  = ('{0}%' -f $pct)
                $ui.FiveBar.Value = $pct
                Set-BarColor $ui.FiveBar $pct
                $ui.ResetLine.Text = ('window resets in {0} (at {1:HH:mm})' -f (Format-Countdown $s.BlockEnd), $s.BlockEnd)
            } else {
                $ui.FivePct.Text  = '0%'
                $ui.FiveBar.Value = 0
                $ui.ResetLine.Text = 'idle - no active window'
            }
        }

        if ($s.Active) {
            $ui.WindowLine.Text = ('this window: {0} msgs, {1} weighted tok' -f $s.SessMsgs, (Format-Tokens $s.SessWeighted))
        } else {
            $ui.WindowLine.Text = ''
        }
        if ($s.TodayMsgs -gt 0) {
            $ui.TodayLine.Text = ('today: {0} msgs, {1} tok (in+out)' -f $s.TodayMsgs, (Format-Tokens $s.TodayTok))
        } else {
            $ui.TodayLine.Text = 'today: no usage yet'
        }
        $ui.UpdatedLine.Text = ('updated {0:HH:mm}' -f (Get-Date))
    } catch {
        $ui.UpdatedLine.Text = 'refresh failed'
    }
}

Initialize-Budget

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(60)
$timer.Add_Tick({ Update-Widget })
$timer.Start()

Update-Widget
[void]$window.ShowDialog()
