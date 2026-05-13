# Claude Code Usage Monitor

A small terminal widget that shows your live [Claude Code](https://claude.ai/code) quota. Pulls the **same numbers as the VSCode "Account & Usage" panel** straight from Anthropic's API, so the bars match what Claude Code itself sees — not a local approximation.

Works on **Windows**, **macOS**, and **Linux**.

```
  ════════════════════════════════════
  Claude Code Usage
  2026-05-11 11:17:08
  ════════════════════════════════════

  Session (5hr)                 37.0%
  [█████████████░░░░░░░░░░░░░░░░░░░░░]
  Resets in 3h 2m

  Weekly (7 day)                62.0%
  [█████████████████████░░░░░░░░░░░░░]
  Resets in 2d 3h

  Weekly Sonnet                  8.0%
  [██░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]
  Resets in 2d 3h

  Quota: api.anthropic.com (live)
  Enter to refresh | c menu  q quit
```

## Features

- **Real quota numbers**, not local approximations — reads `GET /api/oauth/usage` using the OAuth token from `~/.claude/.credentials.json`.
- **Three live bars**: Session (5h), Weekly (7-day), Weekly Sonnet — each with utilization % and reset countdown.
- **Zero subprocess overhead** — one warm HTTPS call per refresh from a single process. No Node.js, no background jobs, no `ccusage`.
- **In-place refresh** — frame redraws every second over itself; no scroll spam.
- **Adaptive layout** — content stretches from 18 chars wide up to 200; resize the window mid-run and it re-renders cleanly.
- **Auto window placement** — on Windows (any cmd window) and on macOS (Terminal.app), the script resizes itself to a compact 36×24 column and pins to the bottom-left of your main display on launch. Linux skips this step.
- **BIOS-style setup menu** — press `c` to change theme, interval, dimensions, corner, alert threshold, etc. Saved to `~/.claude-usage/config.json`.

## Files

| File | Platform | Purpose |
|---|---|---|
| [`claude-usage.bat`](claude-usage.bat) | Windows | cmd launcher; sets window mode, invokes PowerShell. |
| [`claude-usage.ps1`](claude-usage.ps1) | Windows | OAuth fetch, render loop, window placement. |
| [`claude-usage.sh`](claude-usage.sh) | macOS / Linux | Same behaviour in bash — OAuth fetch, render loop. |

## Requirements

All platforms:

- An active Claude Code login. The credentials file `~/.claude/.credentials.json` is created automatically the first time you authenticate.

Per-platform extras:

| Platform | Extras |
|---|---|
| Windows 10 / 11 | PowerShell 5.1+ (ships with Windows). Nothing else. |
| macOS | `jq` and `curl`. Install with `brew install jq` (curl is preinstalled). |
| Linux | `jq` and `curl`. Install with `sudo apt install jq curl` (or your distro's equivalent). |

> Earlier versions also required Node.js + `ccusage` for burn rate and local token counts. Those are gone — the monitor now relies entirely on the OAuth quota endpoint, which is what makes refreshes near-instant.

## Install & run

### Windows

1. Drop both files into the same directory (e.g. `D:\Code\`):
   - `claude-usage.bat`
   - `claude-usage.ps1`
2. Double-click `claude-usage.bat`. A console window opens at the bottom-left of your screen and shows the dashboard.

CLI form:

```cmd
claude-usage.bat            REM use saved interval (default: manual — press Enter to refresh)
claude-usage.bat 60         REM refresh every 60s
claude-usage.bat noconfig   REM launch with defaults, ignore saved config
```

### macOS / Linux

```bash
chmod +x claude-usage.sh
./claude-usage.sh           # use saved interval
./claude-usage.sh 60        # refresh every 60s
```

On **macOS Terminal.app** (the default `Apple_Terminal`) the script auto-resizes itself to 36×24 and snaps to the bottom-left of the main display. On Linux (and on macOS with iTerm2 or other terminals), the script doesn't try to resize/move the window — set geometry in your terminal profile instead. Resize at any time and the layout will adapt.

First fetch completes in well under a second — there's no local-log scan to do.

## Auto-start on login

### Windows — Task Scheduler

1. Open **Task Scheduler** → Create Task.
2. **Triggers**: At log on.
3. **Actions**: Start a program → `cmd.exe` with arguments `/c "D:\Code\claude-usage.bat"`.
4. Save. The monitor will appear at the bottom-left every time you log in.

### macOS — launchd or Login Items

Easiest: **System Settings → General → Login Items → Open at Login** → add `claude-usage.sh` wrapped in a `.command` file or invoked via Terminal/iTerm profile.

Power-user: drop a `~/Library/LaunchAgents/com.user.claude-usage.plist` that runs the script in a small Terminal window. Window placement is up to your terminal app's profile preferences.

### Linux — systemd user unit or WM autostart

Easiest: add `claude-usage.sh` to your desktop environment's autostart (e.g. GNOME *Startup Applications*, KDE *Autostart*, or `~/.config/autostart/claude-usage.desktop`). Wrap in your terminal of choice, e.g.:

```
Exec=alacritty -e bash -lc '/path/to/claude-usage.sh'
```

Window placement / geometry is handled per-terminal — set columns/rows in your terminal's config, and pin position via your WM.

## Configuration

Press `c` while the monitor is running to open the BIOS-style setup menu. All settings persist to `~/.claude-usage/config.json`. Press `s` to save, `Esc` to discard.

| Setting | Notes |
|---|---|
| Refresh interval | `0` = manual mode (press Enter to refresh). Else 5–3600 seconds. |
| Theme | `default`, `dark`, `mono`, `high-contrast`. |
| Window corner | `BottomLeft`, `BottomRight`, `TopLeft`, `TopRight`. |
| Window size | Cols × rows, e.g. `36x24`. |
| Always on top | Keeps the window above other apps. |
| Title | Window title text. |
| Date/time format | .NET (Windows) / strftime (bash) format string. |
| Bar style | `block`, `ascii`, `braille`. |
| Show Weekly | Toggle the 7-day quota bar. |
| Show Sonnet | Toggle the Weekly Sonnet bar. |
| Compact mode | Hide info sub-lines (no "Resets in X"). |
| Alert threshold | Percentage at which a bar turns red. |
| Spinner | Animated spinner glyph (reduced motion). |

You can also pass the interval as a CLI argument on every platform — useful for one-off overrides:

```
claude-usage.bat 60
./claude-usage.sh 60
```

## Hotkeys

| Key | Action |
|---|---|
| Enter / `r` | Force refresh now |
| `c` | Open setup menu |
| `p` | Pause / resume |
| `q` / Esc | Quit |

## How it works

Single source of truth — the Anthropic OAuth quota endpoint:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <token from ~/.claude/.credentials.json>
anthropic-beta: oauth-2025-04-20
```

Returns `five_hour.utilization`, `seven_day.utilization`, `seven_day_sonnet.utilization` as 0–100 percentages with ISO `resets_at` timestamps. This is the same endpoint the Claude Code VSCode extension uses for its Account & Usage panel.

The call happens inline on the main process — no background job, no subprocess. At idle (default `interval=0`, manual mode), zero CPU. With a periodic interval set, one warm HTTPS call per cycle (~50–200 ms with keep-alive).

Rendering uses ANSI VT escapes (cursor home, erase-to-EOL, erase-to-EOS) over a fixed-width layout that recomputes from the terminal's current column count every frame.

## Caveats

- The `/api/oauth/usage` endpoint is **undocumented**. Anthropic could change or remove it at any time, at which point the monitor will display "API unavailable" until it's updated.
- On Windows the OAuth token in `.credentials.json` is read in plaintext. If your system stores it DPAPI-wrapped instead, the API call will fail and the bars will show "API unavailable".
- On macOS the credentials file is sometimes stored in the Keychain rather than `~/.claude/.credentials.json`. If so, the API call will fail.
- Bars use 0–100% as reported by the API; the API itself sometimes briefly exceeds 100 around reset boundaries.

## Troubleshooting

**`claude-usage: 'jq' is required but not on PATH` (macOS/Linux).** Install with `brew install jq` on macOS or `sudo apt install jq` on Debian/Ubuntu.

**Bars show "API unavailable" / "API err: no OAuth token...".** The credentials file is missing, the token expired, the network is blocked, or the endpoint changed. Re-authenticate Claude Code (open it once) to refresh `.credentials.json`.

**Numbers are zero / blank.** Your account may have no recent usage. Send one message in Claude Code and refresh.

**Window opens on the wrong monitor (Windows).** `System.Windows.Forms.Screen.PrimaryScreen.WorkingArea` is used — set your laptop's main display as the primary in Windows display settings.

**Content wraps or looks misaligned.** Resize the window — the layout will redraw to fit on the next tick. If the window is very narrow, info lines are truncated.

**Reset countdowns show `-`/`0m` only (macOS).** Likely a `date` parsing fallback issue with sub-second timestamps. Make sure you're on macOS 10.15+; the script handles both GNU and BSD `date` syntaxes.

## License

Personal utility — use it however you like.
