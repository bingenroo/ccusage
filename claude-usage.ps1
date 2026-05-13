param(
    [int]$Interval = -1,
    [switch]$NoConfig
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

# PowerShell 5.1 defaults to TLS 1.0 for [Net.ServicePointManager], which
# api.anthropic.com refuses. Force TLS 1.2 so Invoke-RestMethod works.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------------------------------------------------------------------------
# Win32 window control (positioning + always-on-top)
# ---------------------------------------------------------------------------
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
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError=true)] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    public static IntPtr HWND_TOPMOST    = new IntPtr(-1);
    public static IntPtr HWND_NOTOPMOST  = new IntPtr(-2);
    public const uint GA_ROOT            = 2;
    public const int  GWL_EXSTYLE        = -20;
    public const int  WS_EX_TOPMOST      = 0x00000008;
}
'@ | Out-Null
}
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

function Place-ConsoleWindow {
    param([string]$Corner = 'BottomLeft')
    try {
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

        # SWP_NOZORDER (0x0004) | SWP_NOSIZE (0x0001) = 0x0005 -> move only
        [void][Win32Wnd]::SetWindowPos($hwnd, [System.IntPtr]::Zero, $x, $y, $winW, $winH, 0x0005)
    } catch {}
}

function Get-ConsoleTopLevelHwnd {
    # Walk up to the top-level ancestor so we manipulate the visible window
    # (under Windows Terminal / ConPTY, GetConsoleWindow returns a hidden proxy).
    try {
        $hwnd = [Win32Wnd]::GetConsoleWindow()
        if ($hwnd -eq [System.IntPtr]::Zero) { return [System.IntPtr]::Zero }
        $root = [Win32Wnd]::GetAncestor($hwnd, [Win32Wnd]::GA_ROOT)
        if ($root -ne [System.IntPtr]::Zero -and [Win32Wnd]::IsWindow($root)) { return $root }
        return $hwnd
    } catch { return [System.IntPtr]::Zero }
}

function Set-AlwaysOnTop {
    param([bool]$On)
    try {
        $hwnd = Get-ConsoleTopLevelHwnd
        if ($hwnd -eq [System.IntPtr]::Zero) { return }
        $after = if ($On) { [Win32Wnd]::HWND_TOPMOST } else { [Win32Wnd]::HWND_NOTOPMOST }
        # SWP_NOMOVE (0x0002) | SWP_NOSIZE (0x0001) | SWP_NOACTIVATE (0x0010) | SWP_SHOWWINDOW (0x0040) = 0x0053
        [void][Win32Wnd]::SetWindowPos($hwnd, $after, 0, 0, 0, 0, 0x0053)
    } catch {}
}

# Returns $true if the console's top-level window currently has WS_EX_TOPMOST set.
function Test-WindowIsTopmost {
    try {
        $hwnd = Get-ConsoleTopLevelHwnd
        if ($hwnd -eq [System.IntPtr]::Zero) { return $false }
        $ex = [Win32Wnd]::GetWindowLong($hwnd, [Win32Wnd]::GWL_EXSTYLE)
        return (($ex -band [Win32Wnd]::WS_EX_TOPMOST) -ne 0)
    } catch { return $false }
}

function Set-WindowSize {
    param([int]$Cols, [int]$Rows)
    try {
        $newSize = New-Object System.Management.Automation.Host.Size $Cols, $Rows
        # Buffer first if growing; else window first
        $cur = $Host.UI.RawUI.WindowSize
        if ($Cols -ge $cur.Width -and $Rows -ge $cur.Height) {
            $Host.UI.RawUI.BufferSize = $newSize
            $Host.UI.RawUI.WindowSize = $newSize
        } else {
            $Host.UI.RawUI.WindowSize = $newSize
            $Host.UI.RawUI.BufferSize = $newSize
        }
    } catch {}
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
$ConfigDir  = Join-Path $env:USERPROFILE '.claude-usage'
$ConfigPath = Join-Path $ConfigDir 'config.json'
$script:ConfigParseError = $false

function Get-DefaultConfig {
    return [pscustomobject]@{
        version        = 1
        interval       = 0
        title          = 'Claude Code Usage Monitor'
        dateFormat     = 'yyyy-MM-dd HH:mm:ss'
        dimensions     = [pscustomobject]@{ cols = 36; rows = 24 }
        corner         = 'BottomLeft'
        alwaysOnTop    = $false
        theme          = 'default'
        barStyle       = 'block'
        showWeekly     = $true
        showSonnet     = $true
        compactMode    = $false
        alertThreshold = 80
        spinner        = $true
    }
}

function Merge-Config {
    param($base, $override)
    if ($null -eq $override) { return $base }
    foreach ($p in $base.PSObject.Properties) {
        $name = $p.Name
        if ($override.PSObject.Properties.Match($name).Count -gt 0) {
            $v = $override.$name
            if ($null -ne $v) {
                if ($name -eq 'dimensions') {
                    if ($v.PSObject.Properties.Match('cols').Count -gt 0 -and $null -ne $v.cols) { $base.dimensions.cols = [int]$v.cols }
                    if ($v.PSObject.Properties.Match('rows').Count -gt 0 -and $null -ne $v.rows) { $base.dimensions.rows = [int]$v.rows }
                } else {
                    $base.$name = $v
                }
            }
        }
    }
    return $base
}

function Load-Config {
    $cfg = Get-DefaultConfig
    if ($NoConfig) { return $cfg }
    if (-not (Test-Path $ConfigPath)) { return $cfg }
    try {
        $raw = Get-Content $ConfigPath -Raw -ErrorAction Stop
        $loaded = $raw | ConvertFrom-Json -ErrorAction Stop
        $cfg = Merge-Config $cfg $loaded
    } catch {
        $script:ConfigParseError = $true
    }
    return $cfg
}

function Save-Config {
    param($cfg)
    try {
        if (-not (Test-Path $ConfigDir)) {
            New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
        }
        $json = $cfg | ConvertTo-Json -Depth 6
        $tmp  = "$ConfigPath.tmp"
        Set-Content -Path $tmp -Value $json -Encoding UTF8
        Move-Item -Path $tmp -Destination $ConfigPath -Force
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Themes & glyphs (rebindable so Apply-Theme can swap them live)
# ---------------------------------------------------------------------------
$ESC = [char]27
$script:R    = "$ESC[0m"
$script:BLD  = "$ESC[1m"
$script:DIM  = "$ESC[2m"
$script:RED  = "$ESC[91m"
$script:YEL  = "$ESC[93m"
$script:GRN  = "$ESC[92m"
$script:GRY  = "$ESC[90m"
$script:CYA  = "$ESC[36m"
$script:REV  = "$ESC[7m"

$HIDE = "$ESC[?25l"
$SHOW = "$ESC[?25h"
$HOMC = "$ESC[H"
$EOL  = "$ESC[K"
$EOS  = "$ESC[J"

$script:FILL = [char]9608   # full block
$script:EMTY = [char]9617   # light shade
$script:EQ   = [char]9552   # box double-horizontal
$script:BAR_OPEN  = '['
$script:BAR_CLOSE = ']'
$SPIN = @('|','/','-','\')

# Box-drawing chars for menu modal
$BX_TL = [char]9556   # ╔
$BX_TR = [char]9559   # ╗
$BX_BL = [char]9562   # ╚
$BX_BR = [char]9565   # ╝
$BX_HR = [char]9552   # ═
$BX_VR = [char]9553   # ║
$BX_LT = [char]9568   # ╠
$BX_RT = [char]9571   # ╣

function Apply-Theme {
    param([string]$Name)
    switch ($Name) {
        'dark' {
            $script:RED = "$ESC[31m"; $script:YEL = "$ESC[33m"
            $script:GRN = "$ESC[32m"; $script:GRY = "$ESC[37m"
            $script:CYA = "$ESC[96m"
        }
        'mono' {
            $script:RED = "$ESC[37m"; $script:YEL = "$ESC[37m"
            $script:GRN = "$ESC[37m"; $script:GRY = "$ESC[90m"
            $script:CYA = "$ESC[37m"
        }
        'high-contrast' {
            $script:RED = "$ESC[91;1m"; $script:YEL = "$ESC[93;1m"
            $script:GRN = "$ESC[92;1m"; $script:GRY = "$ESC[97m"
            $script:CYA = "$ESC[96;1m"
        }
        default {
            $script:RED = "$ESC[91m"; $script:YEL = "$ESC[93m"
            $script:GRN = "$ESC[92m"; $script:GRY = "$ESC[90m"
            $script:CYA = "$ESC[36m"
        }
    }
}

function Apply-BarStyle {
    param([string]$Name)
    switch ($Name) {
        'ascii'   { $script:FILL = '#'; $script:EMTY = '-' }
        'braille' { $script:FILL = [char]10495; $script:EMTY = [char]10240 }  # ⣿ / ⠀
        default   { $script:FILL = [char]9608; $script:EMTY = [char]9617 }    # █ / ░
    }
}

# ---------------------------------------------------------------------------
# Adaptive layout
# ---------------------------------------------------------------------------
$INDENT            = '  '
$CONTENT_W_MAX     = 200
$CONTENT_W_MIN     = 18
$CONTENT_W_DEFAULT = 56
$script:CONTENT_W  = $CONTENT_W_DEFAULT
$script:BAR_W      = $CONTENT_W_DEFAULT - 2

function Update-Layout {
    $w = 0
    try { $w = [Console]::WindowWidth } catch {}
    if ($w -le 0) { $w = $CONTENT_W_DEFAULT + 4 }
    $c = $w - ($INDENT.Length * 2)
    if ($c -gt $CONTENT_W_MAX) { $c = $CONTENT_W_MAX }
    if ($c -lt $CONTENT_W_MIN) { $c = $CONTENT_W_MIN }
    $script:CONTENT_W = $c
    $script:BAR_W     = $c - 2
    return $c
}

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------
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
    $thr = [double]$script:Config.alertThreshold
    if ($thr -le 0) { $thr = 80 }
    if ($pct -ge $thr) { return $script:RED }
    if ($pct -ge ($thr * 0.75)) { return $script:YEL }
    return $script:GRN
}

function Make-Bar([double]$pct, [int]$width) {
    if ($pct -lt 0)   { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    if ($width -lt 4) { $width = 4 }
    $f = [int][math]::Round($width * $pct / 100)
    $e = $width - $f
    return (([string]$script:FILL * $f) + ([string]$script:EMTY * $e))
}

function Pad-Row([string]$leftPlain, [string]$leftAnsi, [string]$rightPlain, [string]$rightAnsi) {
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

# ---------------------------------------------------------------------------
# Fetch / OAuth
# ---------------------------------------------------------------------------
function Get-OAuthToken {
    try {
        $path = Join-Path $env:USERPROFILE '.claude\.credentials.json'
        if (-not (Test-Path $path)) { return $null }
        $c = Get-Content $path -Raw | ConvertFrom-Json
        return $c.claudeAiOauth.accessToken
    } catch { return $null }
}

function Fetch-Quota([string]$token) {
    if (-not $token) {
        return @{ quota = $null; quotaErr = 'no OAuth token in ~/.claude/.credentials.json' }
    }
    try {
        $headers = @{
            'Authorization'  = "Bearer $token"
            'anthropic-beta' = 'oauth-2025-04-20'
            'User-Agent'     = 'claude-code/2.0.31'
            'Accept'         = 'application/json'
        }
        $q = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $headers -Method GET -TimeoutSec 10 -ErrorAction Stop
        return @{ quota = $q; quotaErr = $null }
    } catch {
        $msg = $_.Exception.Message
        try {
            $code = [int]$_.Exception.Response.StatusCode
            if ($code -gt 0) {
                $msg = switch ($code) {
                    429     { '429 rate limited' }
                    401     { '401 expired token' }
                    403     { '403 forbidden' }
                    default { "HTTP $code" }
                }
            }
        } catch {}
        return @{ quota = $null; quotaErr = $msg }
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

# ---------------------------------------------------------------------------
# Render-Frame
# ---------------------------------------------------------------------------
function Render-Frame {
    param(
        $quota, $quotaErr,
        [bool]$fetching, [int]$secsUntilNext, [int]$spinIdx, [bool]$everFetched,
        [bool]$paused
    )

    $cfg = $script:Config

    Update-Layout | Out-Null

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($HOMC)

    $now    = Get-Date -Format $cfg.dateFormat
    $border = $INDENT + ([string]$script:EQ * $script:CONTENT_W)

    [void]$sb.AppendLine($border + $EOL)
    [void]$sb.AppendLine($INDENT + $script:BLD + (Truncate-Vis 'Claude Code Usage') + $script:R + $EOL)
    [void]$sb.AppendLine($INDENT + $script:GRY + (Truncate-Vis $now) + $script:R + $EOL)
    [void]$sb.AppendLine($border + $EOL)
    [void]$sb.AppendLine($EOL)

    if (-not $everFetched) {
        $spinCh = if ($cfg.spinner) { $SPIN[$spinIdx % 4] } else { '*' }
        [void]$sb.AppendLine($INDENT + $script:CYA + $spinCh + ' Loading usage data...' + $script:R + $EOL)
        [void]$sb.AppendLine($INDENT + $script:DIM + '(first fetch is slow)' + $script:R + $EOL)
        for ($i = 0; $i -lt 12; $i++) { [void]$sb.AppendLine($EOL) }
    }
    else {
        # ---------- SESSION (5hr) ----------
        # Online API only. No local-peak fallback - we'd rather show "waiting"
        # than display a misleading number.
        $sessPct  = $null
        $remMin   = $null
        if ($quota -and $quota.five_hour -and $null -ne $quota.five_hour.utilization) {
            $sessPct  = [double]$quota.five_hour.utilization
            $remMin   = Parse-ResetMin $quota.five_hour.resets_at
        }

        if ($null -ne $sessPct) {
            $c       = Bar-Clr $sessPct
            $head    = 'Session (5hr)'
            $pctVis  = ('{0,5:N1}%' -f $sessPct)
            $pctAnsi = $c + $script:BLD + $pctVis + $script:R
            [void]$sb.AppendLine((Pad-Row $head $head $pctVis $pctAnsi) + $EOL)
            [void]$sb.AppendLine($INDENT + $script:BAR_OPEN + $c + (Make-Bar $sessPct $script:BAR_W) + $script:R + $script:BAR_CLOSE + $EOL)
            if (-not $cfg.compactMode) {
                $info = ''
                if ($remMin -ge 0) { $info = "Resets in $(Fmt-Dur $remMin)" }
                [void]$sb.AppendLine($INDENT + $script:GRY + (Truncate-Vis $info) + $script:R + $EOL)
            }
        } else {
            $msg = if ($fetching) { 'Session (5hr)  -  fetching API...' } else { 'Session (5hr)  -  API unavailable, retrying' }
            [void]$sb.AppendLine($INDENT + $script:YEL + (Truncate-Vis $msg) + $script:R + $EOL)
            [void]$sb.AppendLine($EOL)
            if (-not $cfg.compactMode) { [void]$sb.AppendLine($EOL) }
        }

        if (-not $cfg.compactMode) { [void]$sb.AppendLine($EOL) }

        # ---------- WEEKLY ----------
        if ($cfg.showWeekly) {
            # Online API only - no local-peak fallback.
            $wkPct = $null; $wkRem = $null
            if ($quota -and $quota.seven_day -and $null -ne $quota.seven_day.utilization) {
                $wkPct = [double]$quota.seven_day.utilization
                $wkRem = Parse-ResetMin $quota.seven_day.resets_at
            }

            if ($null -ne $wkPct) {
                $wc      = Bar-Clr $wkPct
                $head    = 'Weekly (7 day)'
                $pctVis  = ('{0,5:N1}%' -f $wkPct)
                $pctAnsi = $wc + $script:BLD + $pctVis + $script:R
                [void]$sb.AppendLine((Pad-Row $head $head $pctVis $pctAnsi) + $EOL)
                [void]$sb.AppendLine($INDENT + $script:BAR_OPEN + $wc + (Make-Bar $wkPct $script:BAR_W) + $script:R + $script:BAR_CLOSE + $EOL)
                if (-not $cfg.compactMode) {
                    $wkInfo = ''
                    if ($wkRem -ge 0) { $wkInfo = "Resets in $(Fmt-Dur $wkRem)" }
                    [void]$sb.AppendLine($INDENT + $script:GRY + (Truncate-Vis $wkInfo) + $script:R + $EOL)
                }
            } else {
                $msg = if ($fetching) { 'Weekly (7 day)  -  fetching API...' } else { 'Weekly (7 day)  -  API unavailable, retrying' }
                [void]$sb.AppendLine($INDENT + $script:YEL + (Truncate-Vis $msg) + $script:R + $EOL)
                [void]$sb.AppendLine($EOL)
                if (-not $cfg.compactMode) { [void]$sb.AppendLine($EOL) }
            }

            if (-not $cfg.compactMode) { [void]$sb.AppendLine($EOL) }
        }

        # ---------- WEEKLY SONNET ----------
        if ($cfg.showSonnet) {
            $snPct = $null; $snRem = $null
            if ($quota -and $quota.seven_day_sonnet -and $null -ne $quota.seven_day_sonnet.utilization) {
                $snPct = [double]$quota.seven_day_sonnet.utilization
                $snRem = Parse-ResetMin $quota.seven_day_sonnet.resets_at
            }

            if ($null -ne $snPct) {
                $sc      = Bar-Clr $snPct
                $head    = 'Weekly Sonnet'
                $pctVis  = ('{0,5:N1}%' -f $snPct)
                $pctAnsi = $sc + $script:BLD + $pctVis + $script:R
                [void]$sb.AppendLine((Pad-Row $head $head $pctVis $pctAnsi) + $EOL)
                [void]$sb.AppendLine($INDENT + $script:BAR_OPEN + $sc + (Make-Bar $snPct $script:BAR_W) + $script:R + $script:BAR_CLOSE + $EOL)
                if (-not $cfg.compactMode) {
                    $snInfo = ''
                    if ($snRem -ge 0) { $snInfo = "Resets in $(Fmt-Dur $snRem)" }
                    [void]$sb.AppendLine($INDENT + $script:GRY + (Truncate-Vis $snInfo) + $script:R + $EOL)
                }
            } else {
                [void]$sb.AppendLine($INDENT + $script:DIM + (Truncate-Vis 'Weekly Sonnet  -  no Sonnet usage') + $script:R + $EOL)
                [void]$sb.AppendLine($EOL)
                if (-not $cfg.compactMode) { [void]$sb.AppendLine($EOL) }
            }
        }
    }

    [void]$sb.AppendLine($EOL)

    # Source / status footer
    if ($everFetched) {
        if ($quota) {
            $srcLine = if ($script:CONTENT_W -ge 30) { 'Quota: api.anthropic.com (live)' } else { 'Quota: live API' }
            [void]$sb.AppendLine($INDENT + $script:GRY + (Truncate-Vis $srcLine) + $script:R + $EOL)
        } else {
            $srcLine = if ($quotaErr) {
                'API err: ' + $quotaErr
            } elseif ($script:CONTENT_W -ge 38) {
                'API unavailable - retrying next fetch'
            } else {
                'API unavailable'
            }
            [void]$sb.AppendLine($INDENT + $script:YEL + (Truncate-Vis $srcLine) + $script:R + $EOL)
        }
    } else {
        [void]$sb.AppendLine($EOL)
    }

    if ($script:ConfigParseError) {
        [void]$sb.AppendLine($INDENT + $script:YEL + (Truncate-Vis 'config: parse error - using defaults') + $script:R + $EOL)
    }

    # Status line + hint
    if ($paused) {
        $statusLine = if ($script:CONTENT_W -ge 32) { 'paused | c menu  q quit  r resume' } else { 'paused' }
        $statusAnsi = $script:YEL + $statusLine + $script:R
    } elseif ($fetching) {
        $spinCh = if ($cfg.spinner) { $SPIN[$spinIdx % 4] } else { '*' }
        $statusLine = "$spinCh refreshing data..."
        $statusAnsi = $script:CYA + $statusLine + $script:R
    } elseif ($everFetched) {
        if ($cfg.interval -le 0) {
            if ($script:CONTENT_W -ge 38) {
                $statusLine = 'Enter to refresh | c menu  q quit'
            } elseif ($script:CONTENT_W -ge 24) {
                $statusLine = 'Enter refresh | c menu'
            } else {
                $statusLine = 'Enter refresh'
            }
        } elseif ($script:CONTENT_W -ge 38) {
            $statusLine = ('next in ' + $secsUntilNext + 's | c menu  q quit')
        } elseif ($script:CONTENT_W -ge 24) {
            $statusLine = ('next ' + $secsUntilNext + 's | c menu')
        } else {
            $statusLine = ('next ' + $secsUntilNext + 's')
        }
        $statusAnsi = $script:GRY + $statusLine + $script:R
    } else {
        $statusLine = 'starting first fetch...'
        $statusAnsi = $script:GRY + $statusLine + $script:R
    }
    if ($statusLine.Length -le $script:CONTENT_W) {
        [void]$sb.AppendLine($INDENT + $statusAnsi + $EOL)
    } else {
        [void]$sb.AppendLine($INDENT + (Truncate-Vis $statusLine) + $EOL)
    }
    [void]$sb.Append($EOS)

    [Console]::Write($sb.ToString())
}

# ---------------------------------------------------------------------------
# Setup menu (BIOS-style modal)
# ---------------------------------------------------------------------------

# Date format presets
$DATE_PRESETS = @(
    'yyyy-MM-dd HH:mm:ss',
    'yyyy-MM-dd HH:mm',
    'MM/dd HH:mm:ss',
    'MM/dd hh:mm tt',
    'ddd HH:mm:ss',
    'HH:mm:ss'
)
$THEMES       = @('default','dark','mono','high-contrast')
$BAR_STYLES   = @('block','ascii','braille')
$CORNERS      = @('BottomLeft','BottomRight','TopRight','TopLeft')

function CycleNext { param([array]$arr, $cur)
    $i = [array]::IndexOf($arr, $cur)
    if ($i -lt 0) { return $arr[0] }
    return $arr[(($i + 1) % $arr.Count)]
}
function CyclePrev { param([array]$arr, $cur)
    $i = [array]::IndexOf($arr, $cur)
    if ($i -lt 0) { return $arr[0] }
    return $arr[(($i - 1 + $arr.Count) % $arr.Count)]
}

function Get-MenuItems {
    param($cfg)
    return @(
        @{ key='interval';       label='Refresh interval'; help='0 = manual (Enter to fetch), else 5-3600 sec'; type='int';    val=$cfg.interval }
        @{ key='theme';          label='Color theme';      help='default / dark / mono / high-contrast';    type='cycle';  val=$cfg.theme;    options=$THEMES }
        @{ key='corner';         label='Window corner';    help='Screen corner where the window parks';     type='cycle';  val=$cfg.corner;   options=$CORNERS }
        @{ key='dimensions';     label='Window size';      help='Window size as cols x rows (e.g. 48x28)';  type='dims';   val=$cfg.dimensions }
        @{ key='alwaysOnTop';    label='Always on top';    help='Keep window above other applications';     type='bool';   val=$cfg.alwaysOnTop }
        @{ key='title';          label='Title';            help='Window title (free text)';                 type='text';   val=$cfg.title }
        @{ key='dateFormat';     label='Date/time format'; help='.NET date format string';                  type='cycleText'; val=$cfg.dateFormat; options=$DATE_PRESETS }
        @{ key='barStyle';       label='Bar style';        help='block / ascii / braille glyphs';           type='cycle';  val=$cfg.barStyle; options=$BAR_STYLES }
        @{ key='showWeekly';     label='Show Weekly';      help='Show the 7-day quota panel';               type='bool';   val=$cfg.showWeekly }
        @{ key='showSonnet';     label='Show Sonnet';      help='Show the Weekly Sonnet panel';             type='bool';   val=$cfg.showSonnet }
        @{ key='compactMode';    label='Compact mode';     help='Hide info sub-lines for a shorter UI';     type='bool';   val=$cfg.compactMode }
        @{ key='alertThreshold'; label='Alert threshold';  help='Bar turns red when % is at/above this';    type='int';    val=$cfg.alertThreshold }
        @{ key='spinner';        label='Spinner';          help='Animated spinner glyph (reduced motion)';  type='bool';   val=$cfg.spinner }
    )
}

function Format-MenuValue {
    param($item)
    switch ($item.type) {
        'bool'      { if ($item.val) { return '[x] on' } else { return '[ ] off' } }
        'dims'      { return ('{0} x {1}' -f $item.val.cols, $item.val.rows) }
        'int'       {
            if ($item.key -eq 'alertThreshold') { return ('{0}%' -f $item.val) }
            if ($item.key -eq 'interval') {
                if ([int]$item.val -eq 0) { return 'manual' }
                return ('{0}s' -f $item.val)
            }
            return [string]$item.val
        }
        default     { return [string]$item.val }
    }
}

function Read-LineAtBottom {
    param([string]$Prompt)
    # Move cursor to a known spot below the menu, show it, read, hide
    [Console]::Write($SHOW)
    [Console]::Write("`n  " + $script:CYA + $Prompt + $script:R + ' ')
    $line = [Console]::ReadLine()
    [Console]::Write($HIDE)
    return $line
}

function Apply-Config {
    param($cfg, [bool]$Initial)
    Apply-Theme   $cfg.theme
    Apply-BarStyle $cfg.barStyle
    $title = if ($cfg.title) { $cfg.title } else { 'Claude Code Usage Monitor' }
    try { $Host.UI.RawUI.WindowTitle = $title } catch {}
    [Console]::Write(($ESC.ToString() + ']0;' + $title + [char]7))
    if ($cfg.dimensions -and $cfg.dimensions.cols -gt 0 -and $cfg.dimensions.rows -gt 0) {
        Set-WindowSize -Cols $cfg.dimensions.cols -Rows $cfg.dimensions.rows
    }
    Place-ConsoleWindow -Corner $cfg.corner
    Set-AlwaysOnTop -On ([bool]$cfg.alwaysOnTop)
}

function Show-SetupMenu {
    param([ref]$cfgRef)
    # Snapshot original so Esc reverts
    $snap = $cfgRef.Value | ConvertTo-Json -Depth 6
    $cfg  = $cfgRef.Value

    $items = Get-MenuItems $cfg
    $sel = 0
    $scroll = 0
    $exitMenu = $false
    $saved = $false

    $lastW = -1
    $lastH = -1
    $needRedraw = $true
    Clear-Host
    while (-not $exitMenu) {
        $items = Get-MenuItems $cfg

        # Probe live window size every iteration so the menu responds to resizes
        $winW = 80; $winH = 24
        try { $winW = [Console]::WindowWidth } catch {}
        try { $winH = [Console]::WindowHeight } catch {}
        if ($winW -lt 14) { $winW = 14 }
        if ($winH -lt 8)  { $winH = 8 }

        if ($winW -ne $lastW -or $winH -ne $lastH) {
            Clear-Host
            $lastW = $winW
            $lastH = $winH
            $needRedraw = $true
        }

        if ($needRedraw) {
            # Full-window modal, no outer indent. Leave 1 col on the right so the
            # last char never triggers conhost's auto-wrap.
            $boxW = $winW - 1
            if ($boxW -lt 12) { $boxW = 12 }
            $innerW   = $boxW - 2       # chars between the ║ side walls
            $contentW = $innerW - 2     # 1-char pad on each side
            if ($contentW -lt 8) { $contentW = 8 }

            # Vertical chrome: top + title + sep + ... + sep + help + sep + footer + bot = 8
            $chrome = 8
            $maxRows = $winH - $chrome
            if ($maxRows -lt 3) { $maxRows = 3 }
            $visibleRows = if ($items.Count -lt $maxRows) { $items.Count } else { $maxRows }
            # Pad with blank rows so the menu fills the window (no gap at the bottom)
            $blankRows = $maxRows - $visibleRows
            if ($blankRows -lt 0) { $blankRows = 0 }

            # Keep the selection in view
            if ($sel -lt $scroll) { $scroll = $sel }
            if ($sel -ge ($scroll + $visibleRows)) { $scroll = $sel - $visibleRows + 1 }
            $maxScroll = $items.Count - $visibleRows
            if ($scroll -gt $maxScroll) { $scroll = $maxScroll }
            if ($scroll -lt 0) { $scroll = 0 }
            $hasUp   = ($scroll -gt 0)
            $hasDown = ($scroll + $visibleRows -lt $items.Count)

            # The arrow occupies the right-pad slot, so blank-arrow rows render
            # as "║ <content> ║" with 1 space on each side (symmetric).
            $rowW = $contentW
            if ($rowW -lt 6) { $rowW = 6 }

            # ----- Alignment: pick a single value-column position for all rows -----
            $markerW = 2
            $labelMaxW = 0
            foreach ($it in $items) {
                if ($it.label.Length -gt $labelMaxW) { $labelMaxW = $it.label.Length }
            }
            # Wide mode: marker(2) + label + ' .. ' (4) + value, value left-aligned at fixed col
            $desiredStart = $markerW + $labelMaxW + 4
            if ($desiredStart -lt ($rowW - 6)) {
                $valueStart = $desiredStart
                $valueCellW = $rowW - $valueStart
                $alignMode  = 'wide'
            } else {
                $valueStart = 0
                $valueCellW = 0
                $alignMode  = 'compact'
            }

            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append($HOMC)

            $hbar = [string]$BX_HR * $innerW
            $top = "$BX_TL$hbar$BX_TR"
            $sep = "$BX_LT$hbar$BX_RT"
            $bot = "$BX_BL$hbar$BX_BR"

            # Title row: show scroll position when not everything fits
            $titleText = ' Claude Usage Setup '
            if ($hasUp -or $hasDown) {
                $sm = '[' + ($sel + 1) + '/' + $items.Count + '] '
                if (($titleText.Length + $sm.Length) -le $innerW) { $titleText = $titleText + $sm }
            }
            if ($titleText.Length -gt $innerW) { $titleText = $titleText.Substring(0, $innerW) }
            $titlePad = $innerW - $titleText.Length
            if ($titlePad -lt 0) { $titlePad = 0 }
            $leftPad  = [int]($titlePad / 2)
            $rightPad = $titlePad - $leftPad
            $titleRow = "$BX_VR" + (' ' * $leftPad) + $script:BLD + $titleText + $script:R + (' ' * $rightPad) + "$BX_VR"

            [void]$sb.Append($top + $EOL + "`n")
            [void]$sb.Append($titleRow + $EOL + "`n")
            [void]$sb.Append($sep + $EOL + "`n")

            for ($vi = 0; $vi -lt $visibleRows; $vi++) {
                $i = $scroll + $vi
                $it = $items[$i]
                $marker = if ($i -eq $sel) { '> ' } else { '  ' }
                $valStr = Format-MenuValue $it
                # Normalize booleans to the same width so 'on'/'off' line up
                if ($it.type -eq 'bool' -and $valStr -eq '[x] on') { $valStr = '[x] on ' }
                $label  = $it.label

                # Show ▲ / ▼ on the first/last visible row when there's more above/below
                $arrow = ' '
                if ($vi -eq 0 -and $hasUp) { $arrow = [char]9650 }
                elseif ($vi -eq ($visibleRows - 1) -and $hasDown) { $arrow = [char]9660 }

                if ($alignMode -eq 'wide') {
                    # Truncate over-long values so they don't blow past the row
                    if ($valStr.Length -gt $valueCellW) { $valStr = $valStr.Substring(0, $valueCellW) }
                    # dots between label and the fixed value column
                    $dots = $valueStart - $markerW - $label.Length - 2
                    if ($dots -lt 2) { $dots = 2 }
                    $plain = $marker + $label + ' ' + ('.' * $dots) + ' ' + $valStr
                } else {
                    # Window too narrow for aligned columns - truncate label and pack tight
                    $maxLabel = $rowW - $markerW - $valStr.Length - 1
                    if ($maxLabel -lt 3) { $maxLabel = 3 }
                    if ($label.Length -gt $maxLabel) { $label = $label.Substring(0, $maxLabel) }
                    $pad = $rowW - $markerW - $label.Length - $valStr.Length
                    if ($pad -lt 1) { $pad = 1 }
                    $plain = $marker + $label + (' ' * $pad) + $valStr
                }

                if ($plain.Length -gt $rowW) { $plain = $plain.Substring(0, $rowW) }
                $endPad = $rowW - $plain.Length
                if ($endPad -lt 0) { $endPad = 0 }
                $padded = $plain + (' ' * $endPad)

                if ($i -eq $sel) {
                    $rowAnsi = $script:REV + $padded + $script:R
                } else {
                    $rowAnsi = $padded
                }

                $arrowOut = if ($arrow -ne ' ') { $script:CYA + $arrow + $script:R } else { ' ' }
                [void]$sb.Append("$BX_VR " + $rowAnsi + $arrowOut + "$BX_VR" + $EOL + "`n")
            }

            # Pad with blank box rows so the menu fills the window vertically
            if ($blankRows -gt 0) {
                $blankRow = "$BX_VR" + (' ' * $innerW) + "$BX_VR"
                for ($bb = 0; $bb -lt $blankRows; $bb++) {
                    [void]$sb.Append($blankRow + $EOL + "`n")
                }
            }

            [void]$sb.Append($sep + $EOL + "`n")

            # Help row (adaptive)
            $help = $items[$sel].help
            if ($help.Length -gt $contentW) { $help = $help.Substring(0, $contentW) }
            $helpPad = $contentW - $help.Length
            if ($helpPad -lt 0) { $helpPad = 0 }
            [void]$sb.Append("$BX_VR " + $script:CYA + $help + $script:R + (' ' * $helpPad) + " $BX_VR" + $EOL + "`n")
            [void]$sb.Append($sep + $EOL + "`n")

            # Footer (picks the longest text that fits)
            $footFull  = 'UpDn Nav  Enter Edit  +/- Cycle  s Save  Esc Cancel'
            $footMed   = 'UpDn Nav  Enter  s Save  Esc'
            $footShort = 'UpDn  s Save  Esc'
            $footTiny  = 's/Esc'
            $foot = if ($footFull.Length  -le $contentW) { $footFull }
                    elseif ($footMed.Length   -le $contentW) { $footMed }
                    elseif ($footShort.Length -le $contentW) { $footShort }
                    else { $footTiny }
            if ($foot.Length -gt $contentW) { $foot = $foot.Substring(0, $contentW) }
            $footPad = $contentW - $foot.Length
            if ($footPad -lt 0) { $footPad = 0 }
            [void]$sb.Append("$BX_VR " + $script:GRY + $foot + $script:R + (' ' * $footPad) + " $BX_VR" + $EOL + "`n")
            # No trailing newline after the bottom border - it would scroll the
            # buffer up by one row and clip the top border on tight windows.
            [void]$sb.Append($bot + $EOL)
            [void]$sb.Append($EOS)

            [Console]::Write($sb.ToString())
            $needRedraw = $false
        }

        # Non-blocking key poll so we notice resizes between keystrokes.
        # Poll for up to ~200ms, then loop back to recheck window size.
        $keyReady = $false
        for ($poll = 0; $poll -lt 4; $poll++) {
            try {
                if ([Console]::KeyAvailable) { $keyReady = $true; break }
            } catch {
                # Stdin not interactive - fall back to blocking read
                $keyReady = $true; break
            }
            Start-Sleep -Milliseconds 50
        }
        if (-not $keyReady) { continue }

        $k = [Console]::ReadKey($true)
        $kc = $k.Key
        $kch = $k.KeyChar
        $needRedraw = $true

        if ($kc -eq [ConsoleKey]::UpArrow -or $kch -eq 'k') {
            $sel = ($sel - 1 + $items.Count) % $items.Count
        } elseif ($kc -eq [ConsoleKey]::DownArrow -or $kch -eq 'j') {
            $sel = ($sel + 1) % $items.Count
        } elseif ($kc -eq [ConsoleKey]::PageUp) {
            $sel -= $visibleRows
            if ($sel -lt 0) { $sel = 0 }
        } elseif ($kc -eq [ConsoleKey]::PageDown) {
            $sel += $visibleRows
            if ($sel -ge $items.Count) { $sel = $items.Count - 1 }
        } elseif ($kc -eq [ConsoleKey]::Home) {
            $sel = 0
        } elseif ($kc -eq [ConsoleKey]::End) {
            $sel = $items.Count - 1
        } elseif ($kc -eq [ConsoleKey]::Escape -or $kch -eq 'q' -or $kch -eq 'Q') {
            # Discard: revert from snapshot
            $cfg = $snap | ConvertFrom-Json
            $exitMenu = $true
        } elseif ($kch -eq 's' -or $kch -eq 'S') {
            $ok = Save-Config $cfg
            if ($ok) { $saved = $true }
            $exitMenu = $true
        } elseif ($kc -eq [ConsoleKey]::Enter -or $kch -eq ' ' -or $kch -eq '+' -or $kch -eq '-') {
            $it = $items[$sel]
            $dir = if ($kch -eq '-') { 'prev' } else { 'next' }
            switch ($it.type) {
                'bool' {
                    $cfg.($it.key) = -not [bool]$cfg.($it.key)
                }
                'cycle' {
                    if ($dir -eq 'next') { $cfg.($it.key) = CycleNext $it.options $cfg.($it.key) }
                    else                 { $cfg.($it.key) = CyclePrev $it.options $cfg.($it.key) }
                }
                'cycleText' {
                    # Enter on a cycleText: cycle through presets; if user wants custom, prompt instead via 'e'
                    if ($kc -eq [ConsoleKey]::Enter) {
                        $newVal = Read-LineAtBottom ("$($it.label) (blank to keep, or pick from cycle):")
                        if ($newVal) { $cfg.($it.key) = $newVal }
                    } else {
                        if ($dir -eq 'next') { $cfg.($it.key) = CycleNext $it.options $cfg.($it.key) }
                        else                 { $cfg.($it.key) = CyclePrev $it.options $cfg.($it.key) }
                    }
                }
                'int' {
                    $newVal = Read-LineAtBottom ("$($it.label) (current $($cfg.($it.key))):")
                    if ($newVal -match '^\d+$') {
                        $iv = [int]$newVal
                        if ($it.key -eq 'interval') {
                            # 0 is a valid sentinel (manual mode); otherwise clamp.
                            if ($iv -ne 0) {
                                if ($iv -lt 5)    { $iv = 5 }
                                if ($iv -gt 3600) { $iv = 3600 }
                            }
                        } elseif ($it.key -eq 'alertThreshold') {
                            if ($iv -lt 0)   { $iv = 0 }
                            if ($iv -gt 100) { $iv = 100 }
                        }
                        $cfg.($it.key) = $iv
                    }
                }
                'text' {
                    $newVal = Read-LineAtBottom ("$($it.label) (blank to keep):")
                    if ($newVal) {
                        if ($newVal.Length -gt 80) { $newVal = $newVal.Substring(0, 80) }
                        $cfg.($it.key) = $newVal
                    }
                }
                'dims' {
                    $newVal = Read-LineAtBottom ("Window size (cols x rows, e.g. 48x28):")
                    if ($newVal -match '^\s*(\d+)\s*[xX]\s*(\d+)\s*$') {
                        $c = [int]$matches[1]; $r = [int]$matches[2]
                        if ($c -lt 20)  { $c = 20 };  if ($c -gt 200) { $c = 200 }
                        if ($r -lt 10)  { $r = 10 };  if ($r -gt 60)  { $r = 60 }
                        $cfg.dimensions.cols = $c
                        $cfg.dimensions.rows = $r
                    }
                }
            }
            # Live-apply where it matters so the user sees instant feedback
            Apply-Config -cfg $cfg -Initial $false
            Clear-Host
        } elseif ($kch -eq 'r' -or $kch -eq 'R') {
            # Reset highlighted to default
            $def = Get-DefaultConfig
            $it = $items[$sel]
            if ($it.key -eq 'dimensions') {
                $cfg.dimensions.cols = $def.dimensions.cols
                $cfg.dimensions.rows = $def.dimensions.rows
            } else {
                $cfg.($it.key) = $def.($it.key)
            }
            Apply-Config -cfg $cfg -Initial $false
            Clear-Host
        }
    }

    Clear-Host
    Apply-Config -cfg $cfg -Initial $false
    $cfgRef.Value = $cfg
    return $saved
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$script:Config = Load-Config

# CLI override for interval (does not persist). 0 = manual mode.
if ($Interval -ge 0) { $script:Config.interval = $Interval }

Apply-Config -cfg $script:Config -Initial $true

Clear-Host
[Console]::Write($HIDE)

$token         = Get-OAuthToken
$lastQuota     = $null
$lastQuotaErr  = $null
$lastFetchTime = [datetime]::MinValue
$everFetched   = $false
$spinIdx       = 0
$lastWindowW   = -1
$paused        = $false
$forceRefresh  = $false

# First fetch is inline before the render loop starts.
$fetchResult   = Fetch-Quota $token
$lastQuota     = $fetchResult.quota
$lastQuotaErr  = $fetchResult.quotaErr
$lastFetchTime = Get-Date
$everFetched   = $true

# Detect whether we have an interactive console. When stdin is redirected
# (e.g. piped, scheduled task without a window, CI), [Console]::KeyAvailable
# throws. Probe once and remember.
$script:KeyboardAvailable = $true
try { [void][Console]::KeyAvailable } catch { $script:KeyboardAvailable = $false }

try {
    while ($true) {
        $elapsed = if ($lastFetchTime -eq [datetime]::MinValue) { 99999 } else { ((Get-Date) - $lastFetchTime).TotalSeconds }
        $secsLeft = [int][math]::Max(0, $script:Config.interval - $elapsed)

        # interval=0 disables auto-polling; only $forceRefresh (Enter / 'r') fires a fetch.
        # Manual refresh is debounced to ~2s so spamming Enter can't hit the rate limit.
        $autoDue      = ($script:Config.interval -gt 0 -and $elapsed -ge $script:Config.interval)
        $manualDue    = ($forceRefresh -and $elapsed -ge 2)
        $forceRefresh = $false
        if (-not $paused -and ($autoDue -or $manualDue)) {
            $fetchResult   = Fetch-Quota $token
            $lastQuota     = $fetchResult.quota
            $lastQuotaErr  = $fetchResult.quotaErr
            $lastFetchTime = Get-Date
        }

        $curW = 0
        try { $curW = [Console]::WindowWidth } catch {}
        if ($curW -ne $lastWindowW) {
            Clear-Host
            $lastWindowW = $curW
        }

        # Re-assert always-on-top each frame. Some operations (resize, theme
        # switch, DPI change, focus rules) can silently clear WS_EX_TOPMOST.
        if ([bool]$script:Config.alwaysOnTop -and -not (Test-WindowIsTopmost)) {
            Set-AlwaysOnTop -On $true
        }

        Render-Frame -quota $lastQuota -quotaErr $lastQuotaErr `
                     -fetching $false -secsUntilNext $secsLeft `
                     -spinIdx $spinIdx -everFetched $everFetched -paused $paused

        $spinIdx++

        # Key-poll slice loop (10 x 100ms = 1s frame cadence).
        # If we have no interactive keyboard (redirected stdin), just sleep.
        $shouldQuit = $false
        if (-not $script:KeyboardAvailable) {
            Start-Sleep -Milliseconds 1000
        } else {
            for ($i = 0; $i -lt 10; $i++) {
                $keyReady = $false
                try { $keyReady = [Console]::KeyAvailable } catch { $script:KeyboardAvailable = $false; break }
                if ($keyReady) {
                    $k = [Console]::ReadKey($true)
                    $kch = $k.KeyChar
                    $kc  = $k.Key
                    if ($kch -eq 'c' -or $kch -eq 'C' -or $kch -eq '?') {
                        [void](Show-SetupMenu ([ref]$script:Config))
                        $lastWindowW = -1   # force redraw at new size
                        break
                    } elseif ($kch -eq 'q' -or $kch -eq 'Q') {
                        $shouldQuit = $true; break
                    } elseif ($kch -eq 'r' -or $kch -eq 'R' -or $kc -eq [ConsoleKey]::Enter) {
                        $forceRefresh = $true; break
                    } elseif ($kch -eq 'p' -or $kch -eq 'P') {
                        $paused = -not $paused; break
                    }
                }
                Start-Sleep -Milliseconds 100
            }
        }
        if ($shouldQuit) { break }
    }
}
finally {
    [Console]::Write($SHOW + $script:R + "`n")
}
