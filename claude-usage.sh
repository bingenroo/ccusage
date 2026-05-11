#!/usr/bin/env bash
# claude-usage.sh — live Claude Code usage monitor for macOS and Linux.
# Mirrors the Windows claude-usage.ps1 feature set:
#   - dashboard with Session / Weekly / Weekly-Sonnet bars
#   - OAuth API call against api.anthropic.com (with local-peak fallback)
#   - persistent config at ~/.claude-usage/config.json
#   - BIOS-style settings menu, opened with the `c` hotkey
#   - direct hotkeys: q quit, r refresh-now, p pause
#
# Bash 3.2 compatible (so macOS's stock /bin/bash works).
# Requires: jq, curl, awk, ccusage on PATH.

set -u

# ----------------------------------------------------------------------------
# Dep checks
# ----------------------------------------------------------------------------
for dep in jq curl awk ccusage; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        printf 'Error: %s not found on PATH.\n' "$dep" >&2
        if [[ "$dep" == "ccusage" ]]; then
            printf 'Install with: npm i -g ccusage\n' >&2
        fi
        exit 1
    fi
done

# ----------------------------------------------------------------------------
# CLI args (interval is positional, noconfig is a flag)
# ----------------------------------------------------------------------------
CLI_INTERVAL=""
NO_CONFIG=0
for arg in "$@"; do
    case "$arg" in
        noconfig|--no-config|-n) NO_CONFIG=1 ;;
        ''|*[!0-9]*) ;;   # ignore non-numeric
        *) CLI_INTERVAL="$arg" ;;
    esac
done

# ----------------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------------
CFG_DIR="${HOME}/.claude-usage"
CFG_FILE="${CFG_DIR}/config.json"
CRED_FILE="${HOME}/.claude/.credentials.json"
TMP_DIR="$(mktemp -d -t claude-usage.XXXXXX)"
CONFIG_PARSE_ERROR=0

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
    # Show cursor + reset attributes
    printf '\e[?25h\e[0m\n'
}
trap cleanup EXIT INT TERM

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
DEF_INTERVAL=30
DEF_TITLE="Claude Code Usage Monitor"
DEF_DATEFMT="%Y-%m-%d %H:%M:%S"
DEF_COLS=36
DEF_ROWS=24
DEF_CORNER="BottomLeft"
DEF_ALWAYS_ON_TOP=false
DEF_THEME="default"
DEF_BAR_STYLE="block"
DEF_SHOW_WEEKLY=true
DEF_SHOW_SONNET=true
DEF_SHOW_BURNRATE=true
DEF_SHOW_COST=true
DEF_COMPACT=false
DEF_ALERT_THRESHOLD=80
DEF_SPINNER=true
DEF_FORCE_LOCAL=false

# Active config (loaded / mutated at runtime)
CFG_INTERVAL=$DEF_INTERVAL
CFG_TITLE="$DEF_TITLE"
CFG_DATEFMT="$DEF_DATEFMT"
CFG_COLS=$DEF_COLS
CFG_ROWS=$DEF_ROWS
CFG_CORNER="$DEF_CORNER"
CFG_ALWAYS_ON_TOP=$DEF_ALWAYS_ON_TOP
CFG_THEME="$DEF_THEME"
CFG_BAR_STYLE="$DEF_BAR_STYLE"
CFG_SHOW_WEEKLY=$DEF_SHOW_WEEKLY
CFG_SHOW_SONNET=$DEF_SHOW_SONNET
CFG_SHOW_BURNRATE=$DEF_SHOW_BURNRATE
CFG_SHOW_COST=$DEF_SHOW_COST
CFG_COMPACT=$DEF_COMPACT
CFG_ALERT_THRESHOLD=$DEF_ALERT_THRESHOLD
CFG_SPINNER=$DEF_SPINNER
CFG_FORCE_LOCAL=$DEF_FORCE_LOCAL

# ----------------------------------------------------------------------------
# Config load / save
# ----------------------------------------------------------------------------
load_config() {
    if [[ $NO_CONFIG -eq 1 ]]; then return 0; fi
    [[ -f "$CFG_FILE" ]] || return 0
    if ! jq empty "$CFG_FILE" >/dev/null 2>&1; then
        CONFIG_PARSE_ERROR=1
        return 0
    fi
    local v
    v=$(jq -r '.interval        // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_INTERVAL="$v"
    v=$(jq -r '.title           // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_TITLE="$v"
    v=$(jq -r '.dateFormat      // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_DATEFMT="$v"
    v=$(jq -r '.dimensions.cols // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_COLS="$v"
    v=$(jq -r '.dimensions.rows // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_ROWS="$v"
    v=$(jq -r '.corner          // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_CORNER="$v"
    v=$(jq -r '.alwaysOnTop     // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_ALWAYS_ON_TOP="$v"
    v=$(jq -r '.theme           // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_THEME="$v"
    v=$(jq -r '.barStyle        // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_BAR_STYLE="$v"
    v=$(jq -r '.showWeekly      // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_SHOW_WEEKLY="$v"
    v=$(jq -r '.showSonnet      // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_SHOW_SONNET="$v"
    v=$(jq -r '.showBurnRate    // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_SHOW_BURNRATE="$v"
    v=$(jq -r '.showCost        // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_SHOW_COST="$v"
    v=$(jq -r '.compactMode     // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_COMPACT="$v"
    v=$(jq -r '.alertThreshold  // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_ALERT_THRESHOLD="$v"
    v=$(jq -r '.spinner         // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_SPINNER="$v"
    v=$(jq -r '.forceLocalMode  // empty' "$CFG_FILE"); [[ -n "$v" ]] && CFG_FORCE_LOCAL="$v"
}

save_config() {
    mkdir -p "$CFG_DIR" 2>/dev/null || return 1
    local tmp="${CFG_FILE}.tmp"
    cat > "$tmp" <<JSON
{
  "version": 1,
  "interval": ${CFG_INTERVAL},
  "title": $(printf '%s' "$CFG_TITLE" | jq -Rs .),
  "dateFormat": $(printf '%s' "$CFG_DATEFMT" | jq -Rs .),
  "dimensions": { "cols": ${CFG_COLS}, "rows": ${CFG_ROWS} },
  "corner": "${CFG_CORNER}",
  "alwaysOnTop": ${CFG_ALWAYS_ON_TOP},
  "theme": "${CFG_THEME}",
  "barStyle": "${CFG_BAR_STYLE}",
  "showWeekly": ${CFG_SHOW_WEEKLY},
  "showSonnet": ${CFG_SHOW_SONNET},
  "showBurnRate": ${CFG_SHOW_BURNRATE},
  "showCost": ${CFG_SHOW_COST},
  "compactMode": ${CFG_COMPACT},
  "alertThreshold": ${CFG_ALERT_THRESHOLD},
  "spinner": ${CFG_SPINNER},
  "forceLocalMode": ${CFG_FORCE_LOCAL}
}
JSON
    mv "$tmp" "$CFG_FILE" 2>/dev/null || return 1
    return 0
}

snapshot_config() {
    # Returns one-line snapshot we can restore from
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
        "$CFG_INTERVAL" "$CFG_TITLE" "$CFG_DATEFMT" "$CFG_COLS" "$CFG_ROWS" \
        "$CFG_CORNER" "$CFG_ALWAYS_ON_TOP" "$CFG_THEME" "$CFG_BAR_STYLE" \
        "$CFG_SHOW_WEEKLY" "$CFG_SHOW_SONNET" "$CFG_SHOW_BURNRATE" "$CFG_SHOW_COST" \
        "$CFG_COMPACT" "$CFG_ALERT_THRESHOLD" "$CFG_SPINNER" "$CFG_FORCE_LOCAL"
}

restore_config() {
    local s="$1"
    IFS='|' read -r CFG_INTERVAL CFG_TITLE CFG_DATEFMT CFG_COLS CFG_ROWS \
        CFG_CORNER CFG_ALWAYS_ON_TOP CFG_THEME CFG_BAR_STYLE \
        CFG_SHOW_WEEKLY CFG_SHOW_SONNET CFG_SHOW_BURNRATE CFG_SHOW_COST \
        CFG_COMPACT CFG_ALERT_THRESHOLD CFG_SPINNER CFG_FORCE_LOCAL <<<"$s"
}

# ----------------------------------------------------------------------------
# ANSI / glyphs / themes
# ----------------------------------------------------------------------------
ESC=$'\e'
R="$ESC[0m"
BLD="$ESC[1m"
DIM="$ESC[2m"
RED="$ESC[91m"
YEL="$ESC[93m"
GRN="$ESC[92m"
GRY="$ESC[90m"
CYA="$ESC[36m"
REV="$ESC[7m"

HIDE="$ESC[?25l"
SHOW="$ESC[?25h"
HOMC="$ESC[H"
EOLN="$ESC[K"
EOS="$ESC[J"

# UTF-8 box-drawing
FILL=$'\xe2\x96\x88'   # █
EMPTY=$'\xe2\x96\x91'  # ░
EQ=$'\xe2\x95\x90'     # ═
BX_TL=$'\xe2\x95\x94'  # ╔
BX_TR=$'\xe2\x95\x97'  # ╗
BX_BL=$'\xe2\x95\x9a'  # ╚
BX_BR=$'\xe2\x95\x9d'  # ╝
BX_VR=$'\xe2\x95\x91'  # ║
BX_LT=$'\xe2\x95\xa0'  # ╠
BX_RT=$'\xe2\x95\xa3'  # ╣

SPIN_CHARS='|/-\'

apply_theme() {
    case "$1" in
        dark)
            RED="$ESC[31m"; YEL="$ESC[33m"; GRN="$ESC[32m"
            GRY="$ESC[37m"; CYA="$ESC[96m" ;;
        mono)
            RED="$ESC[37m"; YEL="$ESC[37m"; GRN="$ESC[37m"
            GRY="$ESC[90m"; CYA="$ESC[37m" ;;
        high-contrast)
            RED="$ESC[91;1m"; YEL="$ESC[93;1m"; GRN="$ESC[92;1m"
            GRY="$ESC[97m";   CYA="$ESC[96;1m" ;;
        *)
            RED="$ESC[91m"; YEL="$ESC[93m"; GRN="$ESC[92m"
            GRY="$ESC[90m"; CYA="$ESC[36m" ;;
    esac
}

apply_bar_style() {
    case "$1" in
        ascii)   FILL='#';                 EMPTY='-' ;;
        braille) FILL=$'\xe2\xa3\xbf';     EMPTY=$'\xe2\xa0\x80' ;;  # ⣿ / ⠀
        *)       FILL=$'\xe2\x96\x88';     EMPTY=$'\xe2\x96\x91' ;;
    esac
}

# ----------------------------------------------------------------------------
# Adaptive layout
# ----------------------------------------------------------------------------
INDENT='  '
CONTENT_W_MAX=200
CONTENT_W_MIN=18
CONTENT_W_DEFAULT=56
CONTENT_W=$CONTENT_W_DEFAULT
BAR_W=$((CONTENT_W_DEFAULT - 2))

update_layout() {
    local w
    w=$(tput cols 2>/dev/null || echo "$CONTENT_W_DEFAULT")
    [[ -z "$w" || "$w" -le 0 ]] && w=$((CONTENT_W_DEFAULT + 4))
    local c=$(( w - 2 * ${#INDENT} ))
    [[ $c -gt $CONTENT_W_MAX ]] && c=$CONTENT_W_MAX
    [[ $c -lt $CONTENT_W_MIN ]] && c=$CONTENT_W_MIN
    CONTENT_W=$c
    BAR_W=$((c - 2))
}

# ----------------------------------------------------------------------------
# Window control (per platform best-effort)
# ----------------------------------------------------------------------------
is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }
is_apple_terminal() { [[ "${TERM_PROGRAM:-}" == "Apple_Terminal" ]]; }

set_window_title() {
    printf '\033]0;%s\007' "$1"
}

# osascript helper that resizes + positions the Terminal.app front window
# according to the active CFG_* values.
apply_terminal_window() {
    is_macos || return 0
    is_apple_terminal || return 0
    command -v osascript >/dev/null 2>&1 || return 0
    local corner="$CFG_CORNER"
    local cols="$CFG_COLS"
    local rows="$CFG_ROWS"
    local dock_margin=80
    local menu_bar=25
    osascript >/dev/null 2>&1 <<OSA || true
tell application "Finder"
    set sb to bounds of window of desktop
end tell
set screenW to item 3 of sb
set screenH to item 4 of sb
tell application "Terminal"
    activate
    if (count windows) is 0 then return
    set frontWin to window 1
    try
        set number of columns of frontWin to ${cols}
        set number of rows of frontWin to ${rows}
    end try
    delay 0.1
    set wb to bounds of frontWin
    set winW to (item 3 of wb) - (item 1 of wb)
    set winH to (item 4 of wb) - (item 2 of wb)
    set newLeft to 0
    set newTop to ${menu_bar}
    if "${corner}" is "BottomLeft" then
        set newLeft to 0
        set newTop to screenH - winH - ${dock_margin}
    else if "${corner}" is "BottomRight" then
        set newLeft to screenW - winW
        set newTop to screenH - winH - ${dock_margin}
    else if "${corner}" is "TopLeft" then
        set newLeft to 0
        set newTop to ${menu_bar}
    else if "${corner}" is "TopRight" then
        set newLeft to screenW - winW
        set newTop to ${menu_bar}
    end if
    if newTop < ${menu_bar} then set newTop to ${menu_bar}
    set bounds of frontWin to {newLeft, newTop, newLeft + winW, newTop + winH}
end tell
OSA
}

# Linux: emit xterm CSI 8 to resize. Best-effort, host-dependent.
apply_xterm_resize() {
    if [[ -n "${CFG_COLS:-}" && -n "${CFG_ROWS:-}" ]]; then
        printf '\e[8;%d;%dt' "$CFG_ROWS" "$CFG_COLS"
    fi
}

# Linux: try wmctrl for "always on top" + corner placement
apply_linux_alwaystop() {
    command -v wmctrl >/dev/null 2>&1 || return 0
    if [[ "$CFG_ALWAYS_ON_TOP" == "true" ]]; then
        wmctrl -r :ACTIVE: -b add,above 2>/dev/null || true
    else
        wmctrl -r :ACTIVE: -b remove,above 2>/dev/null || true
    fi
}

apply_config() {
    apply_theme "$CFG_THEME"
    apply_bar_style "$CFG_BAR_STYLE"
    set_window_title "$CFG_TITLE"
    if is_macos && is_apple_terminal; then
        apply_terminal_window
    else
        apply_xterm_resize
        apply_linux_alwaystop
    fi
}

# ----------------------------------------------------------------------------
# Formatting helpers (awk-based math)
# ----------------------------------------------------------------------------
fmt_tokens() {
    awk -v n="$1" 'BEGIN {
        if (n >= 1e9)      printf("%.2fB", n/1e9);
        else if (n >= 1e6) printf("%.2fM", n/1e6);
        else if (n >= 1e3) printf("%.1fK", n/1e3);
        else               printf("%d",    n);
    }'
}

fmt_dur() {
    awk -v m="$1" 'BEGIN {
        if (m < 0) m = 0;
        d = int(m / 1440);
        rem = m - d * 1440;
        h = int(rem / 60);
        mn = int(rem) % 60;
        if (d > 0)      printf("%dd %dh", d, h);
        else if (h > 0) printf("%dh %dm", h, mn);
        else            printf("%dm",     mn);
    }'
}

bar_color() {
    local pct="$1"
    local thr="${CFG_ALERT_THRESHOLD:-80}"
    [[ "$thr" -le 0 ]] && thr=80
    local warn
    warn=$(awk -v t="$thr" 'BEGIN { printf("%.0f", t * 0.75) }')
    if awk -v p="$pct" -v t="$thr"  'BEGIN { exit !(p >= t) }'; then
        printf '%s' "$RED"; return
    fi
    if awk -v p="$pct" -v w="$warn" 'BEGIN { exit !(p >= w) }'; then
        printf '%s' "$YEL"; return
    fi
    printf '%s' "$GRN"
}

make_bar() {
    local pct="$1" width="$2"
    local f
    f=$(awk -v p="$pct" -v w="$width" 'BEGIN {
        if (p < 0)   p = 0;
        if (p > 100) p = 100;
        if (w < 4)   w = 4;
        printf("%d", w * p / 100 + 0.5);
    }')
    local e=$((width - f))
    local out=""
    local i
    for ((i=0; i<f; i++)); do out+="$FILL"; done
    for ((i=0; i<e; i++)); do out+="$EMPTY"; done
    printf '%s' "$out"
}

# Visible padding so right column ends at CONTENT_W
pad_row() {
    local left="$1" right="$2"
    local vis=$(( ${#left} + ${#right} ))
    local pad=$(( CONTENT_W - vis ))
    [[ $pad -lt 1 ]] && pad=1
    printf '%s%s%*s%s' "$INDENT" "$left" "$pad" "" "$right"
}

truncate_vis() {
    local s="$1"
    if [[ ${#s} -le $CONTENT_W ]]; then
        printf '%s' "$s"
    else
        printf '%s' "${s:0:$CONTENT_W}"
    fi
}

# ----------------------------------------------------------------------------
# OAuth token + fetch
# ----------------------------------------------------------------------------
get_token() {
    [[ -f "$CRED_FILE" ]] || return 1
    jq -r '.claudeAiOauth.accessToken // empty' "$CRED_FILE" 2>/dev/null
}

# Background fetch: writes ${TMP_DIR}/blocks.json, weekly.json, quota.json, then .done
spawn_fetch() {
    local token="$1" skip_quota="$2"
    rm -f "$TMP_DIR/.done"
    (
        ccusage blocks --offline -j -t max  > "$TMP_DIR/blocks.json" 2>/dev/null
        ccusage weekly --offline -j -o desc > "$TMP_DIR/weekly.json" 2>/dev/null
        if [[ -n "$token" && "$skip_quota" != "true" ]]; then
            curl -fsS --max-time 10 \
                -H "Authorization: Bearer ${token}" \
                -H "anthropic-beta: oauth-2025-04-20" \
                -H "User-Agent: claude-code/2.0.31" \
                -H "Accept: application/json" \
                "https://api.anthropic.com/api/oauth/usage" \
                > "$TMP_DIR/quota.json" 2>/dev/null || rm -f "$TMP_DIR/quota.json"
        else
            rm -f "$TMP_DIR/quota.json"
        fi
        touch "$TMP_DIR/.done"
    ) &
    FETCH_PID=$!
}

fetch_done() {
    [[ -f "$TMP_DIR/.done" ]]
}

# ISO timestamp to "minutes remaining" — handles GNU & BSD `date`.
parse_reset_min() {
    local iso="$1"
    [[ -z "$iso" ]] && { echo -1; return; }
    local target now
    target=$(date -d "$iso" +%s 2>/dev/null || echo "")
    if [[ -z "$target" ]]; then
        local clean="${iso%%.*}"
        clean="${clean%Z}"
        target=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null || echo "")
    fi
    [[ -z "$target" ]] && { echo -1; return; }
    now=$(date +%s)
    local diff=$(( (target - now) / 60 ))
    [[ $diff -lt 0 ]] && diff=0
    echo "$diff"
}

# ----------------------------------------------------------------------------
# Render dashboard
# ----------------------------------------------------------------------------
render_frame() {
    local fetching="$1"        # true|false
    local secs_until_next="$2"
    local spin_idx="$3"
    local ever_fetched="$4"    # true|false
    local paused="$5"          # true|false

    update_layout

    local blocks="$TMP_DIR/blocks.json"
    local weekly="$TMP_DIR/weekly.json"
    local quota="$TMP_DIR/quota.json"

    local now
    now=$(date "+${CFG_DATEFMT}" 2>/dev/null || date)

    # Build border
    local border="$INDENT"
    local i
    for ((i=0; i<CONTENT_W; i++)); do border+="$EQ"; done

    # Output buffer
    local out="$HOMC"
    out+="${border}${EOLN}"$'\n'
    out+="${INDENT}${BLD}$(truncate_vis "Claude Code Usage")${R}${EOLN}"$'\n'
    out+="${INDENT}${GRY}$(truncate_vis "$now")${R}${EOLN}"$'\n'
    out+="${border}${EOLN}"$'\n'
    out+="${EOLN}"$'\n'

    if [[ "$ever_fetched" != "true" ]]; then
        local spin_ch='*'
        [[ "$CFG_SPINNER" == "true" ]] && spin_ch=${SPIN_CHARS:$((spin_idx % 4)):1}
        out+="${INDENT}${CYA}${spin_ch} Loading usage data...${R}${EOLN}"$'\n'
        out+="${INDENT}${DIM}(first fetch is slow)${R}${EOLN}"$'\n'
        for ((i=0; i<12; i++)); do out+="${EOLN}"$'\n'; done
    else
        # SESSION block — online API only. utilization is already a 0-100 percent.
        local sess_pct="" sess_rem=-1
        if [[ -s "$quota" ]] && jq -e '.five_hour.utilization' "$quota" >/dev/null 2>&1; then
            sess_pct=$(jq -r '.five_hour.utilization' "$quota")
            local iso; iso=$(jq -r '.five_hour.resets_at // empty' "$quota")
            sess_rem=$(parse_reset_min "$iso")
        fi

        if [[ -n "$sess_pct" ]]; then
            local color; color=$(bar_color "$sess_pct")
            local pct_vis; pct_vis=$(printf '%5.1f%%' "$sess_pct")
            local head="Session (5hr)"
            out+="$(pad_row "$head" "${color}${BLD}${pct_vis}${R}")${EOLN}"$'\n'
            out+="${INDENT}[${color}$(make_bar "$sess_pct" "$BAR_W")${R}]${EOLN}"$'\n'
            if [[ "$CFG_COMPACT" != "true" ]]; then
                local info=""
                if awk -v r="$sess_rem" 'BEGIN { exit !(r >= 0) }'; then
                    info="Resets in $(fmt_dur "$sess_rem")"
                fi
                if [[ -s "$blocks" ]] && jq -e '.blocks[]|select(.isActive==true)' "$blocks" >/dev/null 2>&1; then
                    local tu co
                    tu=$(jq -r '[.blocks[]|select(.isActive==true)][0].totalTokens // 0' "$blocks")
                    co=$(jq -r '[.blocks[]|select(.isActive==true)][0].costUSD     // 0' "$blocks")
                    [[ -n "$info" ]] && info+="  "
                    if [[ "$CFG_SHOW_COST" == "true" ]]; then
                        info+="$(fmt_tokens "$tu") tok  \$$(printf '%.2f' "$co")"
                    else
                        info+="$(fmt_tokens "$tu") tok"
                    fi
                fi
                out+="${INDENT}${GRY}$(truncate_vis "$info")${R}${EOLN}"$'\n'
            fi
        else
            local msg="Session (5hr)  -  API unavailable, retrying"
            [[ "$fetching" == "true" ]] && msg="Session (5hr)  -  fetching API..."
            out+="${INDENT}${YEL}$(truncate_vis "$msg")${R}${EOLN}"$'\n'
            out+="${EOLN}"$'\n'
            [[ "$CFG_COMPACT" != "true" ]] && out+="${EOLN}"$'\n'
        fi

        # Burn rate
        if [[ "$CFG_SHOW_BURNRATE" == "true" && "$CFG_COMPACT" != "true" ]]; then
            if [[ -s "$blocks" ]] && jq -e '.blocks[]|select(.isActive==true)' "$blocks" >/dev/null 2>&1; then
                local bt bh
                bt=$(jq -r '[.blocks[]|select(.isActive==true)][0].burnRate.tokensPerMinute // 0' "$blocks")
                bh=$(jq -r '[.blocks[]|select(.isActive==true)][0].burnRate.costPerHour     // 0' "$blocks")
                local burn
                if [[ "$CFG_SHOW_COST" == "true" ]]; then
                    burn="Burn $(fmt_tokens "$bt")/m | \$$(printf '%.2f' "$bh")/h"
                else
                    burn="Burn $(fmt_tokens "$bt")/m"
                fi
                out+="${INDENT}${GRY}$(truncate_vis "$burn")${R}${EOLN}"$'\n'
            else
                out+="${EOLN}"$'\n'
            fi
        fi

        [[ "$CFG_COMPACT" != "true" ]] && out+="${EOLN}"$'\n'

        # WEEKLY — online API only.
        if [[ "$CFG_SHOW_WEEKLY" == "true" ]]; then
            local wk_pct="" wk_rem=-1
            if [[ -s "$quota" ]] && jq -e '.seven_day.utilization' "$quota" >/dev/null 2>&1; then
                wk_pct=$(jq -r '.seven_day.utilization' "$quota")
                local iso; iso=$(jq -r '.seven_day.resets_at // empty' "$quota")
                wk_rem=$(parse_reset_min "$iso")
            fi

            if [[ -n "$wk_pct" ]]; then
                local color; color=$(bar_color "$wk_pct")
                local pct_vis; pct_vis=$(printf '%5.1f%%' "$wk_pct")
                local head="Weekly (7 day)"
                out+="$(pad_row "$head" "${color}${BLD}${pct_vis}${R}")${EOLN}"$'\n'
                out+="${INDENT}[${color}$(make_bar "$wk_pct" "$BAR_W")${R}]${EOLN}"$'\n'
                if [[ "$CFG_COMPACT" != "true" ]]; then
                    local info=""
                    if awk -v r="$wk_rem" 'BEGIN { exit !(r >= 0) }'; then
                        info="Resets in $(fmt_dur "$wk_rem")"
                    fi
                    if [[ -s "$weekly" ]] && jq -e '.weekly[0]' "$weekly" >/dev/null 2>&1; then
                        local tt tc
                        tt=$(jq -r '.weekly[0].totalTokens // 0' "$weekly")
                        tc=$(jq -r '.weekly[0].totalCost   // 0' "$weekly")
                        [[ -n "$info" ]] && info+="  "
                        if [[ "$CFG_SHOW_COST" == "true" ]]; then
                            info+="$(fmt_tokens "$tt") tok  \$$(printf '%.2f' "$tc")"
                        else
                            info+="$(fmt_tokens "$tt") tok"
                        fi
                    fi
                    out+="${INDENT}${GRY}$(truncate_vis "$info")${R}${EOLN}"$'\n'
                fi
            else
                local msg="Weekly (7 day)  -  API unavailable, retrying"
                [[ "$fetching" == "true" ]] && msg="Weekly (7 day)  -  fetching API..."
                out+="${INDENT}${YEL}$(truncate_vis "$msg")${R}${EOLN}"$'\n'
                out+="${EOLN}"$'\n'
                [[ "$CFG_COMPACT" != "true" ]] && out+="${EOLN}"$'\n'
            fi
            [[ "$CFG_COMPACT" != "true" ]] && out+="${EOLN}"$'\n'
        fi

        # WEEKLY SONNET
        if [[ "$CFG_SHOW_SONNET" == "true" ]]; then
            local sn_pct="" sn_rem=-1
            if [[ -s "$quota" ]] && jq -e '.seven_day_sonnet.utilization' "$quota" >/dev/null 2>&1; then
                sn_pct=$(jq -r '.seven_day_sonnet.utilization' "$quota")
                local iso; iso=$(jq -r '.seven_day_sonnet.resets_at // empty' "$quota")
                sn_rem=$(parse_reset_min "$iso")
            fi

            if [[ -n "$sn_pct" ]]; then
                local color; color=$(bar_color "$sn_pct")
                local pct_vis; pct_vis=$(printf '%5.1f%%' "$sn_pct")
                local head="Weekly Sonnet"
                out+="$(pad_row "$head" "${color}${BLD}${pct_vis}${R}")${EOLN}"$'\n'
                out+="${INDENT}[${color}$(make_bar "$sn_pct" "$BAR_W")${R}]${EOLN}"$'\n'
                if [[ "$CFG_COMPACT" != "true" ]]; then
                    local info=""
                    if awk -v r="$sn_rem" 'BEGIN { exit !(r >= 0) }'; then
                        info="Resets in $(fmt_dur "$sn_rem")"
                    fi
                    # local sonnet tokens from weekly model breakdowns
                    if [[ -s "$weekly" ]] && jq -e '.weekly[0].modelBreakdowns' "$weekly" >/dev/null 2>&1; then
                        local stk sct
                        stk=$(jq -r '[.weekly[0].modelBreakdowns[] | select(.modelName|test("sonnet";"i")) | (.inputTokens + .outputTokens + .cacheCreationTokens + .cacheReadTokens)] | add // 0' "$weekly")
                        sct=$(jq -r '[.weekly[0].modelBreakdowns[] | select(.modelName|test("sonnet";"i")) | .cost] | add // 0' "$weekly")
                        if awk -v s="$stk" 'BEGIN { exit !(s > 0) }'; then
                            [[ -n "$info" ]] && info+="  "
                            if [[ "$CFG_SHOW_COST" == "true" ]]; then
                                info+="$(fmt_tokens "$stk") tok  \$$(printf '%.2f' "$sct")"
                            else
                                info+="$(fmt_tokens "$stk") tok"
                            fi
                        fi
                    fi
                    out+="${INDENT}${GRY}$(truncate_vis "$info")${R}${EOLN}"$'\n'
                fi
            else
                out+="${INDENT}${DIM}$(truncate_vis "Weekly Sonnet  -  no Sonnet usage")${R}${EOLN}"$'\n'
                out+="${EOLN}"$'\n'
                [[ "$CFG_COMPACT" != "true" ]] && out+="${EOLN}"$'\n'
            fi
        fi
    fi

    out+="${EOLN}"$'\n'

    # Quota source footer
    if [[ "$ever_fetched" == "true" ]]; then
        if [[ -s "$quota" ]]; then
            local src
            if [[ $CONTENT_W -ge 30 ]]; then src="Quota: api.anthropic.com (live)"
            else                             src="Quota: live API"; fi
            out+="${INDENT}${GRY}$(truncate_vis "$src")${R}${EOLN}"$'\n'
        else
            local src="API unavailable - retrying next fetch"
            [[ $CONTENT_W -lt 38 ]] && src="API unavailable"
            out+="${INDENT}${YEL}$(truncate_vis "$src")${R}${EOLN}"$'\n'
        fi
    else
        out+="${EOLN}"$'\n'
    fi

    [[ $CONFIG_PARSE_ERROR -eq 1 ]] && out+="${INDENT}${YEL}$(truncate_vis "config: parse error - using defaults")${R}${EOLN}"$'\n'

    # Status line
    local status
    if [[ "$paused" == "true" ]]; then
        if [[ $CONTENT_W -ge 32 ]]; then status="paused | c menu  q quit  r resume"
        else                             status="paused"; fi
        out+="${INDENT}${YEL}$(truncate_vis "$status")${R}${EOLN}"$'\n'
    elif [[ "$fetching" == "true" ]]; then
        local spin_ch='*'
        [[ "$CFG_SPINNER" == "true" ]] && spin_ch=${SPIN_CHARS:$((spin_idx % 4)):1}
        status="${spin_ch} refreshing data..."
        out+="${INDENT}${CYA}$(truncate_vis "$status")${R}${EOLN}"$'\n'
    elif [[ "$ever_fetched" == "true" ]]; then
        if [[ $CONTENT_W -ge 38 ]]; then status="next in ${secs_until_next}s | c menu  q quit"
        elif [[ $CONTENT_W -ge 24 ]]; then status="next ${secs_until_next}s | c menu"
        else                              status="next ${secs_until_next}s"; fi
        out+="${INDENT}${GRY}$(truncate_vis "$status")${R}${EOLN}"$'\n'
    else
        status="starting first fetch..."
        out+="${INDENT}${GRY}$(truncate_vis "$status")${R}${EOLN}"$'\n'
    fi

    out+="$EOS"
    printf '%s' "$out"
}

# ----------------------------------------------------------------------------
# Key reading
# ----------------------------------------------------------------------------
# Returns symbolic name on stdout. Codes:
#   UP DOWN LEFT RIGHT ESC ENTER  (and the literal char for everything else)
# Returns nonzero on timeout.
read_key() {
    local timeout="${1:--1}"
    local k1=""
    if [[ "$timeout" == "-1" ]]; then
        IFS= read -rsn1 k1
        local rc=$?
    else
        IFS= read -rsn1 -t "$timeout" k1
        local rc=$?
    fi
    [[ $rc -ne 0 ]] && return 1
    if [[ -z "$k1" ]]; then printf 'ENTER'; return 0; fi
    if [[ "$k1" == $'\e' ]]; then
        local rest=""
        IFS= read -rsn2 -t 0.01 rest
        case "$rest" in
            '[A') printf 'UP' ;;
            '[B') printf 'DOWN' ;;
            '[C') printf 'RIGHT' ;;
            '[D') printf 'LEFT' ;;
            *)    printf 'ESC' ;;
        esac
        return 0
    fi
    printf '%s' "$k1"
}

# ----------------------------------------------------------------------------
# Setup menu (BIOS-style)
# ----------------------------------------------------------------------------
# Menu schema as parallel arrays (bash 3.2 — no associative arrays)
MENU_KEYS=(   interval    theme    corner    dimensions    alwaysOnTop    title    dateFormat    barStyle    showWeekly    showSonnet    showBurnRate    showCost    compactMode    alertThreshold    spinner    forceLocalMode)
MENU_LABELS=( "Refresh interval" "Color theme" "Window corner" "Window size" "Always on top" "Title" "Date/time format" "Bar style" "Show Weekly" "Show Sonnet" "Show Burn rate" "Show Cost" "Compact mode" "Alert threshold" "Spinner" "Force local mode" )
MENU_HELPS=(
    "Refresh interval (5-3600 sec)"
    "default / dark / mono / high-contrast"
    "Screen corner where the window parks"
    "Window size as cols x rows (e.g. 48x28)"
    "Keep window above other apps (Linux: wmctrl)"
    "Window title (free text)"
    "strftime format string"
    "block / ascii / braille glyphs"
    "Show the 7-day quota panel"
    "Show the Weekly Sonnet panel"
    "Show tokens-per-minute burn line"
    'Display $ cost amounts'
    "Hide info sub-lines for a shorter UI"
    "Bar turns red when % is at/above this"
    "Animated spinner glyph (reduced motion)"
    "Skip OAuth API call - use peak fallback"
)
MENU_TYPES=(  int         cycle    cycle     dims          bool           text     cycleText     cycle       bool          bool          bool            bool        bool           int               bool       bool          )

THEMES="default dark mono high-contrast"
CORNERS="BottomLeft BottomRight TopRight TopLeft"
BAR_STYLES="block ascii braille"
DATE_PRESETS=(
    '%Y-%m-%d %H:%M:%S'
    '%Y-%m-%d %H:%M'
    '%m/%d %H:%M:%S'
    '%m/%d %I:%M %p'
    '%a %H:%M:%S'
    '%H:%M:%S'
)

cycle_next() {
    local cur="$1"; shift
    local list="$*"
    local prev="" first="" found=0
    for v in $list; do
        [[ -z "$first" ]] && first="$v"
        if [[ $found -eq 1 ]]; then echo "$v"; return; fi
        if [[ "$v" == "$cur" ]]; then found=1; fi
    done
    echo "$first"
}
cycle_prev() {
    local cur="$1"; shift
    local list="$*"
    local last=""
    for v in $list; do last="$v"; done
    local prev="$last"
    for v in $list; do
        if [[ "$v" == "$cur" ]]; then echo "$prev"; return; fi
        prev="$v"
    done
    echo "$last"
}
cycle_next_arr() {
    # cycle_next_arr current_value array_name
    local cur="$1" name="$2"
    eval "local arr=(\"\${${name}[@]}\")"
    local n=${#arr[@]} i
    for ((i=0; i<n; i++)); do
        if [[ "${arr[$i]}" == "$cur" ]]; then
            echo "${arr[$(( (i+1) % n ))]}"; return
        fi
    done
    echo "${arr[0]}"
}
cycle_prev_arr() {
    local cur="$1" name="$2"
    eval "local arr=(\"\${${name}[@]}\")"
    local n=${#arr[@]} i
    for ((i=0; i<n; i++)); do
        if [[ "${arr[$i]}" == "$cur" ]]; then
            echo "${arr[$(( (i - 1 + n) % n ))]}"; return
        fi
    done
    echo "${arr[0]}"
}

get_cfg() {
    case "$1" in
        interval)        echo "$CFG_INTERVAL" ;;
        title)           echo "$CFG_TITLE" ;;
        dateFormat)      echo "$CFG_DATEFMT" ;;
        corner)          echo "$CFG_CORNER" ;;
        alwaysOnTop)     echo "$CFG_ALWAYS_ON_TOP" ;;
        theme)           echo "$CFG_THEME" ;;
        barStyle)        echo "$CFG_BAR_STYLE" ;;
        showWeekly)      echo "$CFG_SHOW_WEEKLY" ;;
        showSonnet)      echo "$CFG_SHOW_SONNET" ;;
        showBurnRate)    echo "$CFG_SHOW_BURNRATE" ;;
        showCost)        echo "$CFG_SHOW_COST" ;;
        compactMode)     echo "$CFG_COMPACT" ;;
        alertThreshold)  echo "$CFG_ALERT_THRESHOLD" ;;
        spinner)         echo "$CFG_SPINNER" ;;
        forceLocalMode)  echo "$CFG_FORCE_LOCAL" ;;
        dimensions)      echo "${CFG_COLS} x ${CFG_ROWS}" ;;
    esac
}

set_cfg() {
    case "$1" in
        interval)        CFG_INTERVAL="$2" ;;
        title)           CFG_TITLE="$2" ;;
        dateFormat)      CFG_DATEFMT="$2" ;;
        corner)          CFG_CORNER="$2" ;;
        alwaysOnTop)     CFG_ALWAYS_ON_TOP="$2" ;;
        theme)           CFG_THEME="$2" ;;
        barStyle)        CFG_BAR_STYLE="$2" ;;
        showWeekly)      CFG_SHOW_WEEKLY="$2" ;;
        showSonnet)      CFG_SHOW_SONNET="$2" ;;
        showBurnRate)    CFG_SHOW_BURNRATE="$2" ;;
        showCost)        CFG_SHOW_COST="$2" ;;
        compactMode)     CFG_COMPACT="$2" ;;
        alertThreshold)  CFG_ALERT_THRESHOLD="$2" ;;
        spinner)         CFG_SPINNER="$2" ;;
        forceLocalMode)  CFG_FORCE_LOCAL="$2" ;;
    esac
}

toggle_bool() {
    local k="$1" cur
    cur=$(get_cfg "$k")
    if [[ "$cur" == "true" ]]; then set_cfg "$k" "false"; else set_cfg "$k" "true"; fi
}

format_menu_value() {
    local idx="$1"
    local k="${MENU_KEYS[$idx]}"
    local t="${MENU_TYPES[$idx]}"
    case "$t" in
        bool)
            local v; v=$(get_cfg "$k")
            if [[ "$v" == "true" ]]; then echo "[x] on"; else echo "[ ] off"; fi
            ;;
        dims)
            echo "${CFG_COLS} x ${CFG_ROWS}"
            ;;
        int)
            local v; v=$(get_cfg "$k")
            case "$k" in
                interval)       echo "${v}s" ;;
                alertThreshold) echo "${v}%" ;;
                *)              echo "$v" ;;
            esac
            ;;
        *)
            get_cfg "$k"
            ;;
    esac
}

read_line_bottom() {
    local prompt="$1"
    printf '%s\n  %s%s%s ' "$SHOW" "$CYA" "$prompt" "$R"
    local line=""
    IFS= read -r line
    printf '%s' "$HIDE"
    printf '%s' "$line"
}

edit_item() {
    local idx="$1" dir="$2"
    local k="${MENU_KEYS[$idx]}"
    local t="${MENU_TYPES[$idx]}"
    case "$t" in
        bool) toggle_bool "$k" ;;
        cycle)
            local cur; cur=$(get_cfg "$k")
            local newv
            case "$k" in
                theme)
                    if [[ "$dir" == "prev" ]]; then newv=$(cycle_prev "$cur" $THEMES); else newv=$(cycle_next "$cur" $THEMES); fi ;;
                corner)
                    if [[ "$dir" == "prev" ]]; then newv=$(cycle_prev "$cur" $CORNERS); else newv=$(cycle_next "$cur" $CORNERS); fi ;;
                barStyle)
                    if [[ "$dir" == "prev" ]]; then newv=$(cycle_prev "$cur" $BAR_STYLES); else newv=$(cycle_next "$cur" $BAR_STYLES); fi ;;
            esac
            set_cfg "$k" "$newv"
            ;;
        cycleText)
            if [[ "$dir" == "edit" ]]; then
                local nv; nv=$(read_line_bottom "$(printf '%s (blank to keep):' "${MENU_LABELS[$idx]}")")
                [[ -n "$nv" ]] && set_cfg "$k" "$nv"
            else
                local cur; cur=$(get_cfg "$k")
                local newv
                if [[ "$dir" == "prev" ]]; then newv=$(cycle_prev_arr "$cur" DATE_PRESETS); else newv=$(cycle_next_arr "$cur" DATE_PRESETS); fi
                set_cfg "$k" "$newv"
            fi
            ;;
        int)
            local cur; cur=$(get_cfg "$k")
            local nv; nv=$(read_line_bottom "$(printf '%s (current %s):' "${MENU_LABELS[$idx]}" "$cur")")
            if [[ "$nv" =~ ^[0-9]+$ ]]; then
                case "$k" in
                    interval)
                        [[ $nv -lt 5 ]] && nv=5
                        [[ $nv -gt 3600 ]] && nv=3600
                        ;;
                    alertThreshold)
                        [[ $nv -lt 0 ]] && nv=0
                        [[ $nv -gt 100 ]] && nv=100
                        ;;
                esac
                set_cfg "$k" "$nv"
            fi
            ;;
        text)
            local nv; nv=$(read_line_bottom "$(printf '%s (blank to keep):' "${MENU_LABELS[$idx]}")")
            if [[ -n "$nv" ]]; then
                [[ ${#nv} -gt 80 ]] && nv="${nv:0:80}"
                set_cfg "$k" "$nv"
            fi
            ;;
        dims)
            local nv; nv=$(read_line_bottom "Window size (cols x rows, e.g. 48x28):")
            if [[ "$nv" =~ ^[[:space:]]*([0-9]+)[[:space:]]*[xX][[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
                local c="${BASH_REMATCH[1]}" r="${BASH_REMATCH[2]}"
                [[ $c -lt 20 ]] && c=20; [[ $c -gt 200 ]] && c=200
                [[ $r -lt 10 ]] && r=10; [[ $r -gt 60 ]]  && r=60
                CFG_COLS="$c"; CFG_ROWS="$r"
            fi
            ;;
    esac
    apply_config
}

reset_item() {
    local idx="$1"
    local k="${MENU_KEYS[$idx]}"
    case "$k" in
        interval)        CFG_INTERVAL=$DEF_INTERVAL ;;
        title)           CFG_TITLE="$DEF_TITLE" ;;
        dateFormat)      CFG_DATEFMT="$DEF_DATEFMT" ;;
        corner)          CFG_CORNER="$DEF_CORNER" ;;
        alwaysOnTop)     CFG_ALWAYS_ON_TOP=$DEF_ALWAYS_ON_TOP ;;
        theme)           CFG_THEME="$DEF_THEME" ;;
        barStyle)        CFG_BAR_STYLE="$DEF_BAR_STYLE" ;;
        showWeekly)      CFG_SHOW_WEEKLY=$DEF_SHOW_WEEKLY ;;
        showSonnet)      CFG_SHOW_SONNET=$DEF_SHOW_SONNET ;;
        showBurnRate)    CFG_SHOW_BURNRATE=$DEF_SHOW_BURNRATE ;;
        showCost)        CFG_SHOW_COST=$DEF_SHOW_COST ;;
        compactMode)     CFG_COMPACT=$DEF_COMPACT ;;
        alertThreshold)  CFG_ALERT_THRESHOLD=$DEF_ALERT_THRESHOLD ;;
        spinner)         CFG_SPINNER=$DEF_SPINNER ;;
        forceLocalMode)  CFG_FORCE_LOCAL=$DEF_FORCE_LOCAL ;;
        dimensions)      CFG_COLS=$DEF_COLS; CFG_ROWS=$DEF_ROWS ;;
    esac
    apply_config
}

render_menu() {
    local sel="$1" scroll="$2" visible="$3" blankRows="${4:-0}"
    local winW winH
    winW=$(tput cols 2>/dev/null || echo 80)
    winH=$(tput lines 2>/dev/null || echo 24)
    [[ -z "$winW" || $winW -lt 14 ]] && winW=14
    [[ -z "$winH" || $winH -lt 8  ]] && winH=8

    # Full-window modal: leave 1 col on the right so the last char doesn't
    # cause a terminal auto-wrap.
    local boxW=$(( winW - 1 ))
    [[ $boxW -lt 12 ]] && boxW=12
    local inner=$(( boxW - 2 ))      # chars between the ║ side walls
    local contentW=$(( inner - 2 ))  # 1-char pad on each side
    [[ $contentW -lt 8 ]] && contentW=8

    local n=${#MENU_KEYS[@]}
    local hasUp=0 hasDown=0
    [[ $scroll -gt 0 ]] && hasUp=1
    [[ $((scroll + visible)) -lt $n ]] && hasDown=1

    local top="$BX_TL" sep="$BX_LT" bot="$BX_BL"
    local i
    for ((i=0; i<inner; i++)); do
        top+="$EQ"; sep+="$EQ"; bot+="$EQ"
    done
    top+="$BX_TR"; sep+="$BX_RT"; bot+="$BX_BR"

    # Title (with [n/N] when scrolled)
    local title_text=" Claude Usage Setup "
    if [[ $hasUp -eq 1 || $hasDown -eq 1 ]]; then
        local sm="[$((sel + 1))/${n}] "
        if [[ $(( ${#title_text} + ${#sm} )) -le $inner ]]; then
            title_text+="$sm"
        fi
    fi
    [[ ${#title_text} -gt $inner ]] && title_text="${title_text:0:$inner}"
    local title_pad=$(( inner - ${#title_text} ))
    [[ $title_pad -lt 0 ]] && title_pad=0
    local lpad=$(( title_pad / 2 ))
    local rpad=$(( title_pad - lpad ))

    local out="$HOMC"
    out+="${top}${EOLN}"$'\n'
    out+="${BX_VR}$(printf '%*s' $lpad '')${BLD}${title_text}${R}$(printf '%*s' $rpad '')${BX_VR}${EOLN}"$'\n'
    out+="${sep}${EOLN}"$'\n'

    # Arrow occupies the right-pad slot, so blank-arrow rows render symmetric
    local rowW=$(( contentW ))
    [[ $rowW -lt 6 ]] && rowW=6
    local markerW=2 labelMaxW=0
    local _li
    for ((_li=0; _li<n; _li++)); do
        local _ll=${#MENU_LABELS[$_li]}
        [[ $_ll -gt $labelMaxW ]] && labelMaxW=$_ll
    done
    local desiredStart=$(( markerW + labelMaxW + 4 ))
    local valueStart=0 valueCellW=0
    local alignMode="compact"
    if [[ $desiredStart -lt $(( rowW - 6 )) ]]; then
        valueStart=$desiredStart
        valueCellW=$(( rowW - valueStart ))
        alignMode="wide"
    fi

    local vi i marker val label arrow dots plain pad padded arrowOut
    for ((vi=0; vi<visible; vi++)); do
        i=$(( scroll + vi ))
        marker="  "
        [[ $i -eq $sel ]] && marker="> "
        val=$(format_menu_value "$i")
        # Normalize boolean values to a common width so on/off line up
        if [[ "$val" == "[x] on" ]]; then val="[x] on "; fi
        label="${MENU_LABELS[$i]}"

        arrow=" "
        if [[ $vi -eq 0 && $hasUp -eq 1 ]]; then
            arrow=$'\xe2\x96\xb2'   # ▲
        elif [[ $vi -eq $((visible - 1)) && $hasDown -eq 1 ]]; then
            arrow=$'\xe2\x96\xbc'   # ▼
        fi

        if [[ "$alignMode" == "wide" ]]; then
            # Truncate long values so they don't blow past the row
            [[ ${#val} -gt $valueCellW ]] && val="${val:0:$valueCellW}"
            dots=$(( valueStart - markerW - ${#label} - 2 ))
            [[ $dots -lt 2 ]] && dots=2
            local _dotstr; _dotstr=$(printf '%*s' $dots '' | tr ' ' '.')
            plain="${marker}${label} ${_dotstr} ${val}"
        else
            local maxlabel=$(( rowW - markerW - ${#val} - 1 ))
            [[ $maxlabel -lt 3 ]] && maxlabel=3
            [[ ${#label} -gt $maxlabel ]] && label="${label:0:$maxlabel}"
            pad=$(( rowW - markerW - ${#label} - ${#val} ))
            [[ $pad -lt 1 ]] && pad=1
            plain="${marker}${label}$(printf '%*s' $pad '')${val}"
        fi

        [[ ${#plain} -gt $rowW ]] && plain="${plain:0:$rowW}"
        pad=$(( rowW - ${#plain} ))
        [[ $pad -lt 0 ]] && pad=0
        padded="${plain}$(printf '%*s' $pad '')"

        if [[ "$arrow" == " " ]]; then
            arrowOut=" "
        else
            arrowOut="${CYA}${arrow}${R}"
        fi

        if [[ $i -eq $sel ]]; then
            out+="${BX_VR} ${REV}${padded}${R}${arrowOut}${BX_VR}${EOLN}"$'\n'
        else
            out+="${BX_VR} ${padded}${arrowOut}${BX_VR}${EOLN}"$'\n'
        fi
    done

    # Pad with blank box rows so the menu fills the window vertically
    if [[ $blankRows -gt 0 ]]; then
        local _bspaces; _bspaces=$(printf '%*s' "$inner" '')
        local _bi
        for ((_bi=0; _bi<blankRows; _bi++)); do
            out+="${BX_VR}${_bspaces}${BX_VR}${EOLN}"$'\n'
        done
    fi

    out+="${sep}${EOLN}"$'\n'

    # Help row (adaptive)
    local help="${MENU_HELPS[$sel]}"
    [[ ${#help} -gt $contentW ]] && help="${help:0:$contentW}"
    local helppad=$(( contentW - ${#help} ))
    [[ $helppad -lt 0 ]] && helppad=0
    out+="${BX_VR} ${CYA}${help}${R}$(printf '%*s' $helppad '') ${BX_VR}${EOLN}"$'\n'
    out+="${sep}${EOLN}"$'\n'

    # Footer (picks the longest variant that fits)
    local foot_full="UpDn Nav  Enter Edit  +/- Cycle  s Save  Esc Cancel"
    local foot_med="UpDn Nav  Enter  s Save  Esc"
    local foot_short="UpDn  s Save  Esc"
    local foot_tiny="s/Esc"
    local foot="$foot_tiny"
    if   [[ ${#foot_full}  -le $contentW ]]; then foot="$foot_full"
    elif [[ ${#foot_med}   -le $contentW ]]; then foot="$foot_med"
    elif [[ ${#foot_short} -le $contentW ]]; then foot="$foot_short"
    fi
    [[ ${#foot} -gt $contentW ]] && foot="${foot:0:$contentW}"
    local footpad=$(( contentW - ${#foot} ))
    [[ $footpad -lt 0 ]] && footpad=0
    out+="${BX_VR} ${GRY}${foot}${R}$(printf '%*s' $footpad '') ${BX_VR}${EOLN}"$'\n'
    # No trailing newline after the bottom border - it would scroll the buffer
    # up by one row and clip the top border on tight windows.
    out+="${bot}${EOLN}"
    out+="$EOS"
    printf '%s' "$out"
}

show_setup_menu() {
    local snap; snap=$(snapshot_config)
    local sel=0 scroll=0
    local n=${#MENU_KEYS[@]}
    local lastW=-1 lastH=-1
    local needRedraw=1
    clear
    while true; do
        # Recompute visible rows + scroll so the menu reflows on resize
        local winW winH
        winW=$(tput cols 2>/dev/null || echo 80)
        winH=$(tput lines 2>/dev/null || echo 24)
        [[ -z "$winW" || $winW -lt 14 ]] && winW=14
        [[ -z "$winH" || $winH -lt 8  ]] && winH=8

        if [[ $winW -ne $lastW || $winH -ne $lastH ]]; then
            clear
            lastW=$winW
            lastH=$winH
            needRedraw=1
        fi

        local maxRows=$(( winH - 8 ))
        [[ $maxRows -lt 3 ]] && maxRows=3
        local visible=$maxRows
        [[ $n -lt $visible ]] && visible=$n
        # Fill the window vertically when there are fewer items than rows
        local blanks=$(( maxRows - visible ))
        [[ $blanks -lt 0 ]] && blanks=0

        [[ $sel -lt $scroll ]] && scroll=$sel
        [[ $sel -ge $((scroll + visible)) ]] && scroll=$(( sel - visible + 1 ))
        local maxScroll=$(( n - visible ))
        [[ $scroll -gt $maxScroll ]] && scroll=$maxScroll
        [[ $scroll -lt 0 ]] && scroll=0

        if [[ $needRedraw -eq 1 ]]; then
            render_menu "$sel" "$scroll" "$visible" "$blanks"
            needRedraw=0
        fi

        # Poll with a short timeout so resize is detected between keystrokes
        local k; k=$(read_key 0.2)
        local rc=$?
        if [[ $rc -ne 0 || -z "$k" ]]; then
            continue
        fi
        needRedraw=1
        case "$k" in
            UP|k)      sel=$(( (sel - 1 + n) % n )) ;;
            DOWN|j)    sel=$(( (sel + 1) % n )) ;;
            ESC|q|Q)   restore_config "$snap"; apply_config; break ;;
            s|S)       save_config; break ;;
            ENTER|' ') edit_item "$sel" "edit"; clear ;;
            '+')       edit_item "$sel" "next"; clear ;;
            '-')       edit_item "$sel" "prev"; clear ;;
            r|R)       reset_item "$sel"; clear ;;
        esac
    done
    clear
    apply_config
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
load_config

# CLI override
if [[ -n "$CLI_INTERVAL" ]]; then
    CFG_INTERVAL="$CLI_INTERVAL"
fi

apply_config

TOKEN=$(get_token || true)
EVER_FETCHED=false
LAST_FETCH=0
PAUSED=false
FORCE_REFRESH=false
SPIN_IDX=0
LAST_W=-1
FETCH_PID=""

printf '%s' "$HIDE"
clear

spawn_fetch "$TOKEN" "$CFG_FORCE_LOCAL"

while true; do
    # Reap finished fetch
    if [[ -n "$FETCH_PID" ]] && fetch_done; then
        wait "$FETCH_PID" 2>/dev/null || true
        FETCH_PID=""
        LAST_FETCH=$(date +%s)
        EVER_FETCHED=true
    fi

    NOW=$(date +%s)
    if [[ $LAST_FETCH -eq 0 ]]; then ELAPSED=99999; else ELAPSED=$((NOW - LAST_FETCH)); fi
    SECS_LEFT=$(( CFG_INTERVAL - ELAPSED ))
    [[ $SECS_LEFT -lt 0 ]] && SECS_LEFT=0

    if [[ -z "$FETCH_PID" && "$EVER_FETCHED" == "true" && "$PAUSED" != "true" ]] && \
       { [[ $ELAPSED -ge $CFG_INTERVAL ]] || [[ "$FORCE_REFRESH" == "true" ]]; }; then
        spawn_fetch "$TOKEN" "$CFG_FORCE_LOCAL"
        FORCE_REFRESH=false
    fi

    CUR_W=$(tput cols 2>/dev/null || echo "$CONTENT_W_DEFAULT")
    if [[ "$CUR_W" != "$LAST_W" ]]; then
        clear
        LAST_W="$CUR_W"
    fi

    # Re-assert always-on-top each frame. Window managers may strip the flag
    # on resize / focus / theme change; wmctrl is idempotent so this is cheap.
    if [[ "$CFG_ALWAYS_ON_TOP" == "true" ]] && ! is_macos; then
        command -v wmctrl >/dev/null 2>&1 && wmctrl -r :ACTIVE: -b add,above >/dev/null 2>&1
    fi

    FETCHING=false
    [[ -n "$FETCH_PID" ]] && FETCHING=true
    render_frame "$FETCHING" "$SECS_LEFT" "$SPIN_IDX" "$EVER_FETCHED" "$PAUSED"
    SPIN_IDX=$((SPIN_IDX + 1))

    # Key-poll slice loop (10 x 0.1s = 1s frame cadence)
    SHOULD_QUIT=false
    for ((s=0; s<10; s++)); do
        K=$(read_key 0.1) || { K=""; }
        if [[ -n "$K" ]]; then
            case "$K" in
                c|C|'?')
                    show_setup_menu
                    LAST_W=-1
                    break ;;
                q|Q) SHOULD_QUIT=true; break ;;
                r|R) FORCE_REFRESH=true; break ;;
                p|P) if [[ "$PAUSED" == "true" ]]; then PAUSED=false; else PAUSED=true; fi; break ;;
            esac
        fi
    done
    [[ "$SHOULD_QUIT" == "true" ]] && break
done
