param(
    [int]$Interval = 30
)

$ErrorActionPreference = 'Continue'

# Enable ANSI VT processing on legacy conhost
try {
    if (-not ('Win32.Vt' -as [type])) {
        Add-Type -Namespace Win32 -Name Vt -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int n);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr h, out uint m);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr h, uint m);
'@ | Out-Null
    }
    $h = [Win32.Vt]::GetStdHandle(-11)
    $m = 0
    [void][Win32.Vt]::GetConsoleMode($h, [ref]$m)
    [void][Win32.Vt]::SetConsoleMode($h, $m -bor 0x4)
} catch {}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "Claude Code Usage Monitor"

# Target dimensions: narrow vertical column that fits a 36x28 cell window.
try {
    $newSize = New-Object System.Management.Automation.Host.Size 36, 24
    $Host.UI.RawUI.BufferSize = $newSize
    $Host.UI.RawUI.WindowSize = $newSize
} catch {}

# Pin the console window to the bottom-left of the primary monitor's
# working area (above the taskbar). Done after sizing so the pixel
# dimensions read from GetWindowRect reflect the final size.
function Place-ConsoleWindow {
    param([string]$Corner = 'BottomLeft')
    try {
        if (-not ('Win32Wnd' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Win32Wnd {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
}
'@ | Out-Null
        }
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

        $hwnd = [Win32Wnd]::GetConsoleWindow()
        if ($hwnd -eq [System.IntPtr]::Zero) { return }

        $rect = New-Object 'Win32Wnd+RECT'
        [void][Win32Wnd]::GetWindowRect($hwnd, [ref]$rect)
        $winW = $rect.Right - $rect.Left
        $winH = $rect.Bottom - $rect.Top
        if ($winW -le 0 -or $winH -le 0) { return }

        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

        switch ($Corner) {
            'BottomLeft'  { $x = $wa.Left;                 $y = $wa.Bottom - $winH }
            'BottomRight' { $x = $wa.Right - $winW;        $y = $wa.Bottom - $winH }
            'TopLeft'     { $x = $wa.Left;                 $y = $wa.Top }
            'TopRight'    { $x = $wa.Right - $winW;        $y = $wa.Top }
            default       { $x = $wa.Left;                 $y = $wa.Bottom - $winH }
        }
        if ($y -lt $wa.Top)  { $y = $wa.Top }
        if ($x -lt $wa.Left) { $x = $wa.Left }

        # SWP_NOZORDER (0x0004) | SWP_NOSIZE (0x0001) -> keep size, just move.
        [void][Win32Wnd]::SetWindowPos($hwnd, [System.IntPtr]::Zero, $x, $y, $winW, $winH, 0x0005)
    } catch {}
}

Place-ConsoleWindow -Corner 'BottomLeft'

# Adaptive layout: $script:CONTENT_W and $script:BAR_W are recomputed
# every frame from the current console width so we don't wrap on narrow windows
# and we stretch out on wide windows.
$INDENT       = '  '       # 2-space left margin
$CONTENT_W_MAX = 200       # very wide cap so ultra-wide windows still extend
$CONTENT_W_MIN = 18        # never shrink below this (bar still readable)
$CONTENT_W_DEFAULT = 56    # fallback when WindowWidth can't be read
$script:CONTENT_W = $CONTENT_W_DEFAULT
$script:BAR_W     = $CONTENT_W_DEFAULT - 2

function Update-Layout {
    $w = 0
    try { $w = [Console]::WindowWidth } catch {}
    if ($w -le 0) { $w = $CONTENT_W_DEFAULT + 4 }
    $c = $w - ($INDENT.Length * 2)   # leave equal margin on right
    if ($c -gt $CONTENT_W_MAX) { $c = $CONTENT_W_MAX }
    if ($c -lt $CONTENT_W_MIN) { $c = $CONTENT_W_MIN }
    $script:CONTENT_W = $c
    $script:BAR_W     = $c - 2
    return $c
}

$ESC  = [char]27
$R    = "$ESC[0m"
$BLD  = "$ESC[1m"
$DIM  = "$ESC[2m"
$RED  = "$ESC[91m"
$YEL  = "$ESC[93m"
$GRN  = "$ESC[92m"
$GRY  = "$ESC[90m"
$CYA  = "$ESC[36m"
$HIDE = "$ESC[?25l"
$SHOW = "$ESC[?25h"
$HOMC = "$ESC[H"
$EOL  = "$ESC[K"
$EOS  = "$ESC[J"

$FILL = [char]9608
$EMTY = [char]9617
$EQ   = [char]9552
$SPIN = @('|','/','-','\')

function Fmt-Tokens([double]$n) {
    if ($n -ge 1e9) { return ('{0:N2}B' -f ($n / 1e9)) }
    if ($n -ge 1e6) { return ('{0:N2}M' -f ($n / 1e6)) }
    if ($n -ge 1e3) { return ('{0:N1}K' -f ($n / 1e3)) }
    return ('{0:N0}' -f $n)
}

function Fmt-Dur([double]$totalMin) {
    if ($totalMin -lt 0) { $totalMin = 0 }
    $totalMin = [math]::Floor($totalMin)
    $days = [int][math]::Floor($totalMin / 1440)
    $rem  = $totalMin - ($days * 1440)
    $hrs  = [int][math]::Floor($rem / 60)
    $mins = [int]($rem % 60)
    if ($days -gt 0) { return ("{0}d {1}h" -f $days, $hrs) }
    if ($hrs  -gt 0) { return ("{0}h {1}m" -f $hrs, $mins) }
    return ("{0}m" -f $mins)
}

function Bar-Clr([double]$pct) {
    if ($pct -ge 90) { return $RED }
    if ($pct -ge 70) { return $YEL }
    return $GRN
}

function Make-Bar([double]$pct, [int]$width) {
    if ($pct -lt 0)   { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    if ($width -lt 4) { $width = 4 }
    $f = [int][math]::Round($width * $pct / 100)
    $e = $width - $f
    return (([string]$FILL * $f) + ([string]$EMTY * $e))
}

function Pad-Row([string]$leftPlain, [string]$leftAnsi, [string]$rightPlain, [string]$rightAnsi) {
    # Returns: $INDENT + leftAnsi + padding + rightAnsi   such that the visible width equals $script:CONTENT_W.
    $vis = $leftPlain.Length + $rightPlain.Length
    $pad = $script:CONTENT_W - $vis
    if ($pad -lt 1) { $pad = 1 }
    return $INDENT + $leftAnsi + (' ' * $pad) + $rightAnsi
}

function Truncate-Vis([string]$s) {
    if ($null -eq $s) { return '' }
    if ($s.Length -le $script:CONTENT_W) { return $s }
    if ($script:CONTENT_W -le 0) { return '' }
    return $s.Substring(0, $script:CONTENT_W)
}

function Get-OAuthToken {
    try {
        $path = Join-Path $env:USERPROFILE '.claude\.credentials.json'
        if (-not (Test-Path $path)) { return $null }
        $c = Get-Content $path -Raw | ConvertFrom-Json
        return $c.claudeAiOauth.accessToken
    } catch { return $null }
}

function Start-FetchJob([string]$token) {
    return Start-Job -ArgumentList $token -ScriptBlock {
        param($tok)
        $b = $null; $w = $null; $q = $null
        try { $b = (& ccusage blocks --offline -j -t max 2>$null) -join "`n" } catch {}
        try { $w = (& ccusage weekly --offline -j -o desc 2>$null) -join "`n" } catch {}
        if ($tok) {
            try {
                $headers = @{
                    'Authorization'  = "Bearer $tok"
                    'anthropic-beta' = 'oauth-2025-04-20'
                    'User-Agent'     = 'claude-code/2.0.31'
                    'Accept'         = 'application/json'
                }
                $q = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $headers -Method GET -TimeoutSec 10 -ErrorAction Stop
            } catch { $q = $null }
        }
        return @{ blocksRaw = $b; weeklyRaw = $w; quota = $q }
    }
}

function Parse-ResetMin($iso) {
    if (-not $iso) { return -1 }
    try {
        $dt = [datetime]::Parse($iso).ToLocalTime()
        $m = ($dt - (Get-Date)).TotalMinutes
        if ($m -lt 0) { return 0 }
        return $m
    } catch { return -1 }
}

function Render-Frame {
    param(
        $blocks, $weekly, $quota,
        [bool]$fetching, [int]$secsUntilNext, [int]$spinIdx, [bool]$everFetched
    )

    # Local ccusage data (always-available token counts + burn)
    $active = $null
    if ($blocks -and $blocks.blocks) {
        $active = $blocks.blocks | Where-Object { $_.isActive -eq $true } | Select-Object -First 1
    }

    $latestWk = $null
    $peakWkTokens = 0
    if ($weekly -and $weekly.weekly) {
        $latestWk = $weekly.weekly | Select-Object -First 1
        $peakWkTokens = ($weekly.weekly | Measure-Object -Property totalTokens -Maximum).Maximum
    }

    $sonnetTokensLocal = 0.0
    $sonnetCostLocal   = 0.0
    if ($latestWk -and $latestWk.modelBreakdowns) {
        foreach ($mb in $latestWk.modelBreakdowns) {
            if ($mb.modelName -like '*sonnet*') {
                $sonnetTokensLocal += [double]($mb.inputTokens + $mb.outputTokens + $mb.cacheCreationTokens + $mb.cacheReadTokens)
                $sonnetCostLocal   += [double]$mb.cost
            }
        }
    }

    Update-Layout | Out-Null

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($HOMC)

    $now    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $border = $INDENT + ([string]$EQ * $script:CONTENT_W)

    # Header: title on its own line, timestamp on next line
    [void]$sb.AppendLine($border + $EOL)
    [void]$sb.AppendLine($INDENT + $BLD + (Truncate-Vis 'Claude Code Usage') + $R + $EOL)
    [void]$sb.AppendLine($INDENT + $GRY + (Truncate-Vis $now) + $R + $EOL)
    [void]$sb.AppendLine($border + $EOL)
    [void]$sb.AppendLine($EOL)

    if (-not $everFetched) {
        $spinCh = $SPIN[$spinIdx % 4]
        [void]$sb.AppendLine($INDENT + $CYA + $spinCh + ' Loading usage data...' + $R + $EOL)
        [void]$sb.AppendLine($INDENT + $DIM + '(first fetch is slow)' + $R + $EOL)
        for ($i = 0; $i -lt 12; $i++) { [void]$sb.AppendLine($EOL) }
    }
    else {
        # ---------- SESSION (5hr) ----------
        $sessPct  = $null
        $remMin   = $null
        $usingApi = $false
        if ($quota -and $quota.five_hour -and $null -ne $quota.five_hour.utilization) {
            $sessPct  = [double]$quota.five_hour.utilization
            $remMin   = Parse-ResetMin $quota.five_hour.resets_at
            $usingApi = $true
        } elseif ($active) {
            $tl = [double]$active.tokenLimitStatus.limit
            $tu = [double]$active.totalTokens
            $sessPct = if ($tl -gt 0) { 100.0 * $tu / $tl } else { 0 }
            $remMin  = [double]$active.projection.remainingMinutes
        }

        if ($null -ne $sessPct) {
            $c       = Bar-Clr $sessPct
            $head    = 'Session (5hr)'
            $pctVis  = ('{0,5:N1}%' -f $sessPct)
            $pctAnsi = $c + $BLD + $pctVis + $R
            [void]$sb.AppendLine((Pad-Row $head $head $pctVis $pctAnsi) + $EOL)
            [void]$sb.AppendLine($INDENT + '[' + $c + (Make-Bar $sessPct $script:BAR_W) + $R + ']' + $EOL)
            # Info line: resets + (if active) tokens/cost
            $info = ''
            if ($remMin -ge 0) { $info = "Resets in $(Fmt-Dur $remMin)" }
            if ($active) {
                $tu = [double]$active.totalTokens
                $co = [double]$active.costUSD
                if ($info) { $info += '  ' }
                $info += "$(Fmt-Tokens $tu) tok  `$" + ('{0:N2}' -f $co)
            }
            [void]$sb.AppendLine($INDENT + $GRY + (Truncate-Vis $info) + $R + $EOL)
        } else {
            [void]$sb.AppendLine($INDENT + $DIM + (Truncate-Vis 'Session (5hr)  -  no data') + $R + $EOL)
            [void]$sb.AppendLine($EOL)
            [void]$sb.AppendLine($EOL)
        }

        # Burn rate sub-line (from local data)
        if ($active) {
            $bt = [double]$active.burnRate.tokensPerMinute
            $bh = [double]$active.burnRate.costPerHour
            $burnLine = "Burn $(Fmt-Tokens $bt)/m | `$" + ('{0:N2}' -f $bh) + '/h'
            [void]$sb.AppendLine($INDENT + $GRY + (Truncate-Vis $burnLine) + $R + $EOL)
        } else {
            [void]$sb.AppendLine($EOL)
        }

        [void]$sb.AppendLine($EOL)

        # ---------- WEEKLY (7 day) ----------
        $wkPct = $null; $wkRem = $null; $wkUsingApi = $false
        if ($quota -and $quota.seven_day -and $null -ne $quota.seven_day.utilization) {
            $wkPct = [double]$quota.seven_day.utilization
            $wkRem = Parse-ResetMin $quota.seven_day.resets_at
            $wkUsingApi = $true
        } elseif ($latestWk -and $peakWkTokens -gt 0) {
            $wkPct = 100.0 * [double]$latestWk.totalTokens / $peakWkTokens
            try {
                $ws = [datetime]::ParseExact($latestWk.week, 'yyyy-MM-dd', $null)
                $wkRem = (($ws.AddDays(7)) - (Get-Date)).TotalMinutes
                if ($wkRem -lt 0) { $wkRem = 0 }
            } catch { $wkRem = -1 }
        }

        if ($null -ne $wkPct) {
            $wc      = Bar-Clr $wkPct
            $head    = 'Weekly (7 day)'
            $pctVis  = ('{0,5:N1}%' -f $wkPct)
            $pctAnsi = $wc + $BLD + $pctVis + $R
            [void]$sb.AppendLine((Pad-Row $head $head $pctVis $pctAnsi) + $EOL)
            [void]$sb.AppendLine($INDENT + '[' + $wc + (Make-Bar $wkPct $script:BAR_W) + $R + ']' + $EOL)
            $wkInfo = ''
            if ($wkRem -ge 0) { $wkInfo = "Resets in $(Fmt-Dur $wkRem)" }
            if ($latestWk) {
                if ($wkInfo) { $wkInfo += '  ' }
                $wkInfo += "$(Fmt-Tokens $latestWk.totalTokens) tok  `$" + ('{0:N2}' -f [double]$latestWk.totalCost)
            }
            [void]$sb.AppendLine($INDENT + $GRY + (Truncate-Vis $wkInfo) + $R + $EOL)
        } else {
            [void]$sb.AppendLine($INDENT + $DIM + (Truncate-Vis 'Weekly (7 day)  -  no data') + $R + $EOL)
            [void]$sb.AppendLine($EOL)
            [void]$sb.AppendLine($EOL)
        }

        [void]$sb.AppendLine($EOL)

        # ---------- WEEKLY SONNET ----------
        $snPct = $null; $snRem = $null
        if ($quota -and $quota.seven_day_sonnet -and $null -ne $quota.seven_day_sonnet.utilization) {
            $snPct = [double]$quota.seven_day_sonnet.utilization
            $snRem = Parse-ResetMin $quota.seven_day_sonnet.resets_at
        }

        if ($null -ne $snPct) {
            $sc      = Bar-Clr $snPct
            $head    = 'Weekly Sonnet'
            $pctVis  = ('{0,5:N1}%' -f $snPct)
            $pctAnsi = $sc + $BLD + $pctVis + $R
            [void]$sb.AppendLine((Pad-Row $head $head $pctVis $pctAnsi) + $EOL)
            [void]$sb.AppendLine($INDENT + '[' + $sc + (Make-Bar $snPct $script:BAR_W) + $R + ']' + $EOL)
            $snInfo = ''
            if ($snRem -ge 0) { $snInfo = "Resets in $(Fmt-Dur $snRem)" }
            if ($sonnetTokensLocal -gt 0) {
                if ($snInfo) { $snInfo += '  ' }
                $snInfo += "$(Fmt-Tokens $sonnetTokensLocal) tok  `$" + ('{0:N2}' -f $sonnetCostLocal)
            }
            [void]$sb.AppendLine($INDENT + $GRY + (Truncate-Vis $snInfo) + $R + $EOL)
        } else {
            [void]$sb.AppendLine($INDENT + $DIM + (Truncate-Vis 'Weekly Sonnet  -  no Sonnet usage') + $R + $EOL)
            [void]$sb.AppendLine($EOL)
            [void]$sb.AppendLine($EOL)
        }
    }

    [void]$sb.AppendLine($EOL)

    # Source / status footer
    if ($everFetched) {
        if ($quota) {
            $srcLine = if ($script:CONTENT_W -ge 30) { 'Quota: api.anthropic.com (live)' } else { 'Quota: live API' }
            [void]$sb.AppendLine($INDENT + $GRY + (Truncate-Vis $srcLine) + $R + $EOL)
        } else {
            $srcLine = if ($script:CONTENT_W -ge 40) { 'Quota API unavailable - local peak %' } else { 'Quota offline (local %)' }
            [void]$sb.AppendLine($INDENT + $YEL + (Truncate-Vis $srcLine) + $R + $EOL)
        }
    } else {
        [void]$sb.AppendLine($EOL)
    }

    if ($fetching) {
        $spinCh = $SPIN[$spinIdx % 4]
        $statusLine = "$spinCh refreshing data..."
        $statusAnsi = $CYA + $statusLine + $R
    } elseif ($everFetched) {
        $statusLine = if ($script:CONTENT_W -ge 32) { ('next in ' + $secsUntilNext + 's | Ctrl+C to quit') } else { ('next ' + $secsUntilNext + 's') }
        $statusAnsi = $GRY + $statusLine + $R
    } else {
        $statusLine = 'starting first fetch...'
        $statusAnsi = $GRY + $statusLine + $R
    }
    # Truncate via plain length, but emit ANSI form when it fits
    if ($statusLine.Length -le $script:CONTENT_W) {
        [void]$sb.AppendLine($INDENT + $statusAnsi + $EOL)
    } else {
        [void]$sb.AppendLine($INDENT + (Truncate-Vis $statusLine) + $EOL)
    }
    [void]$sb.Append($EOS)

    [Console]::Write($sb.ToString())
}

# --- Main loop ---
Clear-Host
[Console]::Write($HIDE)

$token         = Get-OAuthToken
$lastBlocks    = $null
$lastWeekly    = $null
$lastQuota     = $null
$lastFetchTime = [datetime]::MinValue
$everFetched   = $false
$bgFetch       = $null
$spinIdx       = 0
$lastWindowW   = -1

$bgFetch = Start-FetchJob $token

try {
    while ($true) {
        if ($null -ne $bgFetch -and $bgFetch.State -ne 'Running' -and $bgFetch.State -ne 'NotStarted') {
            $result = Receive-Job $bgFetch -ErrorAction SilentlyContinue
            Remove-Job $bgFetch -Force -ErrorAction SilentlyContinue
            $bgFetch = $null
            $lastFetchTime = Get-Date
            $everFetched = $true
            if ($result) {
                try { if ($result.blocksRaw) { $lastBlocks = $result.blocksRaw | ConvertFrom-Json } } catch {}
                try { if ($result.weeklyRaw) { $lastWeekly = $result.weeklyRaw | ConvertFrom-Json } } catch {}
                $lastQuota = $result.quota
            }
        }

        $elapsed  = if ($lastFetchTime -eq [datetime]::MinValue) { 99999 } else { ((Get-Date) - $lastFetchTime).TotalSeconds }
        $secsLeft = [int][math]::Max(0, $Interval - $elapsed)

        if ($null -eq $bgFetch -and $everFetched -and $elapsed -ge $Interval) {
            $bgFetch = Start-FetchJob $token
        }

        # Detect window resize - clear the screen so stale wider content
        # from a previous frame can't bleed past the new narrower border.
        $curW = 0
        try { $curW = [Console]::WindowWidth } catch {}
        if ($curW -ne $lastWindowW) {
            Clear-Host
            $lastWindowW = $curW
        }

        $fetching = ($null -ne $bgFetch)
        Render-Frame -blocks $lastBlocks -weekly $lastWeekly -quota $lastQuota `
                     -fetching $fetching -secsUntilNext $secsLeft `
                     -spinIdx $spinIdx -everFetched $everFetched

        $spinIdx++
        Start-Sleep -Milliseconds 1000
    }
}
finally {
    if ($null -ne $bgFetch) {
        try { Stop-Job $bgFetch -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job $bgFetch -Force -ErrorAction SilentlyContinue } catch {}
    }
    [Console]::Write($SHOW + $R + "`n")
}
