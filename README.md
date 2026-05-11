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
  Resets in 3h 2m  14.14M tok  $12.

  Weekly (7 day)                62.0%
  [█████████████████████░░░░░░░░░░░░░]
  Resets in 2d 3h  63.74M tok  $56.

  Weekly Sonnet                  8.0%
  [██░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]
  Resets in 2d 3h

  Quota: api.anthropic.com (live)
  - refreshing data...
```

## Features

- **Real quota numbers**, not local approximations — reads `GET /api/oauth/usage` using the OAuth token from `~/.claude/.credentials.json`.
- **Three live bars**: Session (5h), Weekly (7-day), Weekly Sonnet — each with utilization %, reset countdown, and token/cost totals.
- **In-place refresh** — frame redraws every second over itself; no scroll spam.
- **Adaptive layout** — content stretches from 18 chars wide up to 200; resize the window mid-run and it re-renders cleanly.
- **Burn rate** — tokens/min and $/hr for the active session (sourced from local `ccusage`).
- **Graceful fallback** — if the OAuth endpoint is unreachable, falls back to local peak-based % from `ccusage` and shows a `Quota offline` notice.
- **Auto window placement** — on Windows (any cmd window) and on macOS (Terminal.app), the script resizes itself to a compact 36×24 column and pins to the bottom-left of your main display on launch. Linux skips this step (too many WM/terminal combinations to handle reliably).

## Files

| File | Platform | Purpose |
|---|---|---|
| [`claude-usage.bat`](claude-usage.bat) | Windows | cmd launcher; verifies deps, sets window mode, invokes PowerShell. |
| [`claude-usage.ps1`](claude-usage.ps1) | Windows | OAuth fetch, ccusage parse, render loop, window placement. |
| [`claude-usage.sh`](claude-usage.sh) | macOS / Linux | Same behaviour in bash — OAuth fetch, ccusage parse, render loop. |

## Requirements

All platforms:

- An active Claude Code login. The credentials file `~/.claude/.credentials.json` is created automatically the first time you authenticate.
- Node.js with [ccusage](https://www.npmjs.com/package/ccusage) on PATH:
  ```
  npm i -g ccusage
  ```

Per-platform extras:

| Platform | Extras |
|---|---|
| Windows 10 / 11 | PowerShell 5.1+ (ships with Windows). Nothing else. |
| macOS | `jq` and `curl`. Install with `brew install jq` (curl is preinstalled). |
| Linux | `jq` and `curl`. Install with `sudo apt install jq curl` (or your distro's equivalent). |

## Install & run

### Windows

1. Drop both files into the same directory (e.g. `D:\Code\`):
   - `claude-usage.bat`
   - `claude-usage.ps1`
2. Double-click `claude-usage.bat`. A console window opens at the bottom-left of your screen and starts polling.

CLI form:

```cmd
claude-usage.bat            REM refresh every 10s (the bat's default)
claude-usage.bat 5          REM refresh every 5s
```

### macOS / Linux

```bash
chmod +x claude-usage.sh
./claude-usage.sh           # refresh every 10s
./claude-usage.sh 5         # refresh every 5s
```

On **macOS Terminal.app** (the default `Apple_Terminal`) the script auto-resizes itself to 36×24 and snaps to the bottom-left of the main display — same UX as the Windows version. Open a fresh Terminal window and run the script; it'll reposition itself.

On Linux (and on macOS with iTerm2 or other terminals), the script doesn't try to resize/move the window — set the geometry in your terminal profile instead. Resize at any time and the layout will adapt to fit.

The first fetch can take ~14s because `ccusage --offline` scans `~/.claude/projects/*.jsonl`. A spinner shows during the scan; subsequent refreshes are fast.

## Auto-start on login

### Windows — Task Scheduler

1. Open **Task Scheduler** → Create Task.
2. **Triggers**: At log on.
3. **Actions**: Start a program → `cmd.exe` with arguments `/c "D:\Code\claude-usage.bat"`.
4. Save. The monitor will appear at the bottom-left every time you log in.

### macOS — launchd or Login Items

Easiest: **System Settings → General → Login Items → Open at Login** → add the `claude-usage.sh` script wrapped in a `.command` file or invoked via Terminal/iTerm profile.

Power-user: drop a `~/Library/LaunchAgents/com.user.claude-usage.plist` that runs the script in a small Terminal window. Window placement is up to your terminal app's profile preferences (Terminal.app: *Settings → Profiles → Window → Window Size*; iTerm2: *Profiles → Window → Style/Columns/Rows*).

### Linux — systemd user unit or WM autostart

Easiest: add `claude-usage.sh` to your desktop environment's autostart (e.g. GNOME *Startup Applications*, KDE *Autostart*, or `~/.config/autostart/claude-usage.desktop`). Wrap in your terminal of choice, e.g.:

```
Exec=alacritty -e bash -lc '/path/to/claude-usage.sh'
```

Window placement / geometry is handled per-terminal — set columns/rows in your terminal's config, and pin position via your WM (e.g. i3 `for_window`, KWin window rules, GNOME extensions).

## Configuration

### Refresh interval

Pass seconds as the first CLI argument on every platform:

```
claude-usage.bat 5
./claude-usage.sh 5
```

### Windows — window size & position

All knobs live near the top of `claude-usage.ps1`:

| Setting | Where | Default |
|---|---|---|
| Console size (cols × rows) | `New-Object Size 36, 24` | `36 × 24` |
| Window corner | `Place-ConsoleWindow -Corner 'BottomLeft'` | `BottomLeft` |
| Max content width | `$CONTENT_W_MAX` | `200` |
| Min content width | `$CONTENT_W_MIN` | `18` |

`Place-ConsoleWindow -Corner` accepts `BottomLeft`, `BottomRight`, `TopLeft`, or `TopRight`.

### macOS — Terminal.app window size & position

When the script detects it's running inside Apple Terminal (`$TERM_PROGRAM == Apple_Terminal`), it uses `osascript` to resize the front window and pin it to the bottom-left of the main display. Knobs at the top of `claude-usage.sh`:

| Setting | Default | What it controls |
|---|---|---|
| `TARGET_COLS` | `36` | Columns the Terminal window is resized to. |
| `TARGET_ROWS` | `24` | Rows the Terminal window is resized to. |
| `DOCK_MARGIN_PX` | `80` | Vertical pixel margin reserved for the dock at the bottom. Reduce if your dock is hidden or on the side. |
| `MENU_BAR_PX` | `25` | Top margin so the window never tucks under the menu bar. |
| `CONTENT_W_MAX` | `200` | Cap on rendered content width. |
| `CONTENT_W_MIN` | `18` | Floor on rendered content width. |

If you use iTerm2 or another terminal on macOS, the placement step is skipped — set geometry in the terminal's profile preferences.

### Linux — layout

The bash script doesn't try to resize or move terminal windows on Linux — too many WM/terminal combinations to handle reliably. Same two layout knobs apply (`CONTENT_W_MAX`, `CONTENT_W_MIN`); the script reads `tput cols` every frame and adapts.

## How it works

Two parallel data sources every refresh:

1. **Anthropic OAuth quota endpoint** (the real numbers):
   ```
   GET https://api.anthropic.com/api/oauth/usage
   Authorization: Bearer <token from ~/.claude/.credentials.json>
   anthropic-beta: oauth-2025-04-20
   ```
   Returns `five_hour.utilization`, `seven_day.utilization`, `seven_day_sonnet.utilization` as 0–100 percentages with ISO `resets_at` timestamps. This is the same endpoint the Claude Code VSCode extension uses for its Account & Usage panel.

2. **`ccusage --offline`** (local session logs):
   - Token counts, cost totals, burn rate for the active 5h block.
   - Fallback denominators for the bars if the OAuth call fails.

Both run in the background (PowerShell `Start-Job` on Windows, `&` subshell + temp files on macOS/Linux) so the UI keeps ticking at 1Hz while fetches are in flight.

Rendering uses ANSI VT escapes (cursor home, erase-to-EOL, erase-to-EOS) over a fixed-width layout that recomputes from the terminal's current column count every frame.

## Caveats

- The `/api/oauth/usage` endpoint is **undocumented**. Anthropic could change or remove it at any time; the local-fallback path keeps the monitor working in that case.
- On Windows the OAuth token in `.credentials.json` is read in plaintext. If your system stores it DPAPI-wrapped instead, the script falls back to local peak %.
- On macOS the credentials file is sometimes stored in the Keychain rather than `~/.claude/.credentials.json`. If so, the script falls back to local peak %.
- `ccusage --offline` reads JSONL session logs and can take 10–20 seconds on the first scan. That's not a hang — the spinner means it's working.
- Bars use 0–100% as reported by the API; the API itself sometimes briefly exceeds 100 around reset boundaries.

## Troubleshooting

**Window flashes and closes immediately (Windows).** `ccusage` isn't on PATH. Run `where ccusage` in cmd; if nothing prints, run `npm i -g ccusage`. The bat will pause and show the error if so.

**`claude-usage: 'jq' is required but not on PATH` (macOS/Linux).** Install with `brew install jq` on macOS or `sudo apt install jq` on Debian/Ubuntu.

**Bars show "Quota offline - local %".** The OAuth call failed (no credentials file, expired token, network blocked, or endpoint changed). Re-authenticate Claude Code (just open it) to refresh `.credentials.json`.

**Numbers are zero / blank.** Your active session may have 0 tokens so far. Send one message in Claude Code and refresh.

**Window opens on the wrong monitor (Windows).** `System.Windows.Forms.Screen.PrimaryScreen.WorkingArea` is used — set your laptop's main display as the primary in Windows display settings.

**Content wraps or looks misaligned.** Resize the window — the layout will redraw to fit on the next tick. If the window is very narrow, info lines are truncated to fit.

**Reset countdowns show `-`/`0m` only (macOS).** Likely a `date` parsing fallback issue with sub-second timestamps. Make sure you're on macOS 10.15+; the script handles both GNU and BSD `date` syntaxes.

## License

Personal utility — use it however you like.
