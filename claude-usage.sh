#!/usr/bin/env bash
# claude-usage.sh - Live Claude Code quota monitor for macOS / Linux.
# Mirrors the Windows claude-usage.ps1 behaviour: pulls real numbers from
# Anthropic's OAuth quota endpoint and renders three live bars in place.
#
# Usage:
#   ./claude-usage.sh            # refresh every 10s
#   ./claude-usage.sh 5          # refresh every 5s
#
# Deps: bash 3.2+, jq, curl, ccusage (npm i -g ccusage)

set -u
INTERVAL="${1:-10}"

# ---------- dep check ----------
need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "claude-usage: '$1' is required but not on PATH." >&2
        echo "  install: $2" >&2
        exit 1
    }
}
need jq      "brew install jq      (macOS)  |  sudo apt install jq      (Debian/Ubuntu)"
need curl    "preinstalled on macOS; sudo apt install curl on Linux"
need ccusage "npm i -g ccusage"

CREDS="$HOME/.claude/.credentials.json"

# ---------- ANSI / glyphs ----------
ESC=$'\033'
R="${ESC}[0m";   BLD="${ESC}[1m"; DIM="${ESC}[2m"
RED="${ESC}[91m"; YEL="${ESC}[93m"; GRN="${ESC}[92m"
GRY="${ESC}[90m"; CYA="${ESC}[36m"
HIDE="${ESC}[?25l"; SHOW="${ESC}[?25h"
HOMC="${ESC}[H"; EOL="${ESC}[K"; EOS="${ESC}[J"

FILL=$'\xe2\x96\x88'   # U+2588 full block
EMTY=$'\xe2\x96\x91'   # U+2591 light shade
EQCH=$'\xe2\x95\x90'   # U+2550 double horizontal

INDENT="  "
CONTENT_W_MAX=200
CONTENT_W_MIN=18
CONTENT_W=56
BAR_W=54
SPIN=('|' '/' '-' '\')

# ---------- tmp + cleanup ----------
TMPDIR_="$(mktemp -d 2>/dev/null || mktemp -d -t claude-usage.XXXXXX)"
cleanup() {
    rm -rf "$TMPDIR_" 2>/dev/null
    [[ -n "${BG_PID:-}" ]] && kill "$BG_PID" 2>/dev/null
    printf '%s%s\n' "$SHOW" "$R"
}
trap cleanup EXIT INT TERM

# ---------- macOS Terminal.app setup ----------
# Target the bundled Terminal.app: resize to a narrow vertical column
# and pin to the bottom-left of the main display.
TARGET_COLS=36
TARGET_ROWS=24
DOCK_MARGIN_PX=80     # approximate dock height (bottom dock, not hidden)
MENU_BAR_PX=25        # approximate menu bar height

setup_macos_terminal() {
    [[ "$(uname -s)" == "Darwin" ]] || return 0
    [[ "${TERM_PROGRAM:-}" == "Apple_Terminal" ]] || return 0
    command -v osascript >/dev/null 2>&1 || return 0

    osascript >/dev/null 2>&1 <<OSA || true
tell application "Finder"
    set screenBounds to bounds of window of desktop
end tell
set screenH to item 4 of screenBounds

tell application "Terminal"
    activate
    if (count windows) is 0 then return
    set frontWin to window 1
    try
        set number of columns of frontWin to ${TARGET_COLS}
        set number of rows of frontWin to ${TARGET_ROWS}
    end try
    delay 0.15
    set wb to bounds of frontWin
    set winW to (item 3 of wb) - (item 1 of wb)
    set winH to (item 4 of wb) - (item 2 of wb)
    set newLeft to 0
    set newTop to screenH - winH - ${DOCK_MARGIN_PX}
    if newTop < ${MENU_BAR_PX} then set newTop to ${MENU_BAR_PX}
    set bounds of frontWin to {newLeft, newTop, newLeft + winW, newTop + winH}
end tell
OSA
}

# Set terminal tab/window title (works in Terminal.app, iTerm2, GNOME Terminal, etc.)
set_window_title() {
    printf '\033]0;%s\007' "Claude Code Usage Monitor"
}

set_window_title
setup_macos_terminal

# ---------- helpers ----------
get_token() {
    [[ -f "$CREDS" ]] || return
    jq -r '.claudeAiOauth.accessToken // empty' "$CREDS" 2>/dev/null
}

update_layout() {
    local w
    w=$(tput cols 2>/dev/null || echo 60)
    local c=$((w - 4))
    (( c > CONTENT_W_MAX )) && c=$CONTENT_W_MAX
    (( c < CONTENT_W_MIN )) && c=$CONTENT_W_MIN
    CONTENT_W=$c
    BAR_W=$((c - 2))
}

repeat_char() {
    local ch="$1" n="$2"
    awk -v c="$ch" -v n="$n" 'BEGIN { for (i = 0; i < n; i++) printf "%s", c }'
}

truncate_vis() {
    local s="$1"
    (( ${#s} <= CONTENT_W )) && { printf '%s' "$s"; return; }
    printf '%s' "${s:0:$CONTENT_W}"
}

pad_row() {
    # $1 = left plain, $2 = right plain, $3 = left ansi-wrapped, $4 = right ansi-wrapped
    local lp="$1" rp="$2" la="$3" ra="$4"
    local pad=$((CONTENT_W - ${#lp} - ${#rp}))
    (( pad < 1 )) && pad=1
    printf '%s%s' "$INDENT" "$la"
    repeat_char " " $pad
    printf '%s' "$ra"
}

fmt_tokens() {
    awk -v n="$1" 'BEGIN {
        if (n+0 >= 1e9) printf "%.2fB", n/1e9
        else if (n+0 >= 1e6) printf "%.2fM", n/1e6
        else if (n+0 >= 1e3) printf "%.1fK", n/1e3
        else printf "%d", n
    }'
}

fmt_dur() {
    awk -v t="$1" 'BEGIN {
        if (t+0 < 0) t = 0
        t = int(t)
        d = int(t / 1440); rem = t - d * 1440
        h = int(rem / 60); m = int(rem % 60)
        if (d > 0) printf "%dd %dh", d, h
        else if (h > 0) printf "%dh %dm", h, m
        else printf "%dm", m
    }'
}

bar_clr() {
    awk -v p="$1" -v r="$RED" -v y="$YEL" -v g="$GRN" 'BEGIN {
        if (p+0 >= 90) printf "%s", r
        else if (p+0 >= 70) printf "%s", y
        else printf "%s", g
    }'
}

make_bar() {
    awk -v p="$1" -v w="$2" -v f="$FILL" -v e="$EMTY" 'BEGIN {
        if (p+0 < 0) p = 0
        if (p+0 > 100) p = 100
        fill = int(w * p / 100 + 0.5)
        empty = w - fill
        for (i = 0; i < fill; i++) printf "%s", f
        for (i = 0; i < empty; i++) printf "%s", e
    }'
}

# Parse ISO-8601 timestamp -> minutes from now. Handles GNU + BSD date.
parse_reset_min() {
    local iso="$1"
    [[ -z "$iso" || "$iso" == "null" ]] && { echo "-1"; return; }
    local target=""
    # GNU date (Linux)
    target=$(date -d "$iso" +%s 2>/dev/null) || target=""
    # BSD date (macOS) - strip subseconds & trailing Z, try common formats
    if [[ -z "$target" ]]; then
        local clean="${iso%%.*}"
        clean="${clean%Z}"
        target=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null) || target=""
    fi
    [[ -z "$target" ]] && { echo "-1"; return; }
    local now diff
    now=$(date +%s)
    diff=$(( (target - now) / 60 ))
    (( diff < 0 )) && diff=0
    echo "$diff"
}

# ---------- background fetch ----------
fetch_data() {
    local tok="$1" base="$2"
    ccusage blocks --offline -j -t max > "$base.blocks" 2>/dev/null || : > "$base.blocks"
    ccusage weekly --offline -j -o desc > "$base.weekly" 2>/dev/null || : > "$base.weekly"
    if [[ -n "$tok" ]]; then
        curl -sS --max-time 10 \
            -H "Authorization: Bearer $tok" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.0.31" \
            -H "Accept: application/json" \
            "https://api.anthropic.com/api/oauth/usage" \
            > "$base.quota" 2>/dev/null || : > "$base.quota"
    else
        : > "$base.quota"
    fi
    : > "$base.done"
}

BG_PID=""
BG_BASE=""
start_fetch() {
    BG_BASE="$TMPDIR_/fetch-$$-$RANDOM"
    fetch_data "$TOKEN" "$BG_BASE" &
    BG_PID=$!
}

fetch_done() {
    [[ -z "$BG_PID" ]] && return 1
    [[ -f "$BG_BASE.done" ]] && return 0
    return 1
}

# ---------- rendering ----------
render_frame() {
    local fetching="$1" secs_left="$2" spin_idx="$3" ever="$4"
    local blocks_json="$5" weekly_json="$6" quota_json="$7"

    update_layout

    local out="$HOMC"
    local now border
    now=$(date "+%Y-%m-%d %H:%M:%S")
    border="$INDENT$(repeat_char "$EQCH" $CONTENT_W)"

    out+="${border}${EOL}"$'\n'
    out+="${INDENT}${BLD}$(truncate_vis 'Claude Code Usage')${R}${EOL}"$'\n'
    out+="${INDENT}${GRY}$(truncate_vis "$now")${R}${EOL}"$'\n'
    out+="${border}${EOL}"$'\n'
    out+="${EOL}"$'\n'

    if [[ "$ever" != "1" ]]; then
        local sp="${SPIN[$((spin_idx % 4))]}"
        out+="${INDENT}${CYA}${sp} Loading usage data...${R}${EOL}"$'\n'
        out+="${INDENT}${DIM}(first fetch is slow)${R}${EOL}"$'\n'
        local i
        for (( i = 0; i < 12; i++ )); do out+="${EOL}"$'\n'; done
    else
        # Parse local + remote with jq (gracefully handle empty/invalid)
        local active_present=0 sess_pct="" sess_rem="" tokens="" cost="" burn_t="" burn_h=""
        if [[ -s "$BG_BASE.blocks" ]]; then
            local active
            active=$(jq -c '.blocks // [] | map(select(.isActive == true)) | .[0] // empty' "$BG_BASE.blocks" 2>/dev/null)
            if [[ -n "$active" && "$active" != "null" ]]; then
                active_present=1
                tokens=$(jq -r '.totalTokens // 0' <<<"$active" 2>/dev/null)
                cost=$(jq -r '.costUSD // 0' <<<"$active" 2>/dev/null)
                burn_t=$(jq -r '.burnRate.tokensPerMinute // 0' <<<"$active" 2>/dev/null)
                burn_h=$(jq -r '.burnRate.costPerHour // 0' <<<"$active" 2>/dev/null)
                local lim tok_used proj_rem
                lim=$(jq -r '.tokenLimitStatus.limit // 0' <<<"$active" 2>/dev/null)
                tok_used=$(jq -r '.totalTokens // 0' <<<"$active" 2>/dev/null)
                proj_rem=$(jq -r '.projection.remainingMinutes // -1' <<<"$active" 2>/dev/null)
                sess_pct=$(awk -v t="$tok_used" -v l="$lim" 'BEGIN { if (l+0 > 0) printf "%.1f", 100*t/l; else printf "0" }')
                sess_rem="$proj_rem"
            fi
        fi

        local quota_ok=0 fh_util="" fh_reset_at="" sd_util="" sd_reset_at="" sn_util="" sn_reset_at=""
        if [[ -s "$BG_BASE.quota" ]] && jq -e . "$BG_BASE.quota" >/dev/null 2>&1; then
            quota_ok=1
            fh_util=$(jq -r '.five_hour.utilization // empty' "$BG_BASE.quota" 2>/dev/null)
            fh_reset_at=$(jq -r '.five_hour.resets_at // empty' "$BG_BASE.quota" 2>/dev/null)
            sd_util=$(jq -r '.seven_day.utilization // empty' "$BG_BASE.quota" 2>/dev/null)
            sd_reset_at=$(jq -r '.seven_day.resets_at // empty' "$BG_BASE.quota" 2>/dev/null)
            sn_util=$(jq -r '.seven_day_sonnet.utilization // empty' "$BG_BASE.quota" 2>/dev/null)
            sn_reset_at=$(jq -r '.seven_day_sonnet.resets_at // empty' "$BG_BASE.quota" 2>/dev/null)
        fi

        # ---- SESSION ----
        local s_pct="" s_rem_min=-1
        if [[ -n "$fh_util" ]]; then
            s_pct="$fh_util"
            s_rem_min=$(parse_reset_min "$fh_reset_at")
        elif (( active_present )); then
            s_pct="$sess_pct"
            s_rem_min="$sess_rem"
        fi

        if [[ -n "$s_pct" ]]; then
            local clr head pct_vis bar info
            clr=$(bar_clr "$s_pct")
            head="Session (5hr)"
            pct_vis=$(awk -v p="$s_pct" 'BEGIN { printf "%5.1f%%", p }')
            local row
            row=$(pad_row "$head" "$pct_vis" "$head" "${clr}${BLD}${pct_vis}${R}")
            out+="${row}${EOL}"$'\n'
            bar=$(make_bar "$s_pct" "$BAR_W")
            out+="${INDENT}[${clr}${bar}${R}]${EOL}"$'\n'
            info=""
            if (( $(awk -v r="$s_rem_min" 'BEGIN { print (r+0 >= 0) ? 1 : 0 }') )); then
                info="Resets in $(fmt_dur "$s_rem_min")"
            fi
            if (( active_present )); then
                [[ -n "$info" ]] && info+="  "
                info+="$(fmt_tokens "$tokens") tok  \$$(awk -v c="$cost" 'BEGIN { printf "%.2f", c }')"
            fi
            out+="${INDENT}${GRY}$(truncate_vis "$info")${R}${EOL}"$'\n'
        else
            out+="${INDENT}${DIM}$(truncate_vis 'Session (5hr)  -  no data')${R}${EOL}"$'\n'
            out+="${EOL}"$'\n'; out+="${EOL}"$'\n'
        fi

        if (( active_present )); then
            local burnline
            burnline="Burn $(fmt_tokens "$burn_t")/m | \$$(awk -v c="$burn_h" 'BEGIN { printf "%.2f", c }')/h"
            out+="${INDENT}${GRY}$(truncate_vis "$burnline")${R}${EOL}"$'\n'
        else
            out+="${EOL}"$'\n'
        fi
        out+="${EOL}"$'\n'

        # ---- WEEKLY ----
        local w_pct="" w_rem=-1 wk_tokens="" wk_cost=""
        if [[ -n "$sd_util" ]]; then
            w_pct="$sd_util"
            w_rem=$(parse_reset_min "$sd_reset_at")
        fi
        if [[ -s "$BG_BASE.weekly" ]]; then
            wk_tokens=$(jq -r '.weekly[0].totalTokens // 0' "$BG_BASE.weekly" 2>/dev/null)
            wk_cost=$(jq -r '.weekly[0].totalCost // 0' "$BG_BASE.weekly" 2>/dev/null)
        fi

        if [[ -n "$w_pct" ]]; then
            local clr head pct_vis bar info row
            clr=$(bar_clr "$w_pct")
            head="Weekly (7 day)"
            pct_vis=$(awk -v p="$w_pct" 'BEGIN { printf "%5.1f%%", p }')
            row=$(pad_row "$head" "$pct_vis" "$head" "${clr}${BLD}${pct_vis}${R}")
            out+="${row}${EOL}"$'\n'
            bar=$(make_bar "$w_pct" "$BAR_W")
            out+="${INDENT}[${clr}${bar}${R}]${EOL}"$'\n'
            info=""
            (( $(awk -v r="$w_rem" 'BEGIN { print (r+0 >= 0) ? 1 : 0 }') )) && info="Resets in $(fmt_dur "$w_rem")"
            if [[ -n "$wk_tokens" && "$wk_tokens" != "0" ]]; then
                [[ -n "$info" ]] && info+="  "
                info+="$(fmt_tokens "$wk_tokens") tok  \$$(awk -v c="$wk_cost" 'BEGIN { printf "%.2f", c }')"
            fi
            out+="${INDENT}${GRY}$(truncate_vis "$info")${R}${EOL}"$'\n'
        else
            out+="${INDENT}${DIM}$(truncate_vis 'Weekly (7 day)  -  no data')${R}${EOL}"$'\n'
            out+="${EOL}"$'\n'; out+="${EOL}"$'\n'
        fi
        out+="${EOL}"$'\n'

        # ---- WEEKLY SONNET ----
        local sn_pct="" sn_rem=-1
        if [[ -n "$sn_util" ]]; then
            sn_pct="$sn_util"
            sn_rem=$(parse_reset_min "$sn_reset_at")
        fi
        if [[ -n "$sn_pct" ]]; then
            local clr head pct_vis bar info row
            clr=$(bar_clr "$sn_pct")
            head="Weekly Sonnet"
            pct_vis=$(awk -v p="$sn_pct" 'BEGIN { printf "%5.1f%%", p }')
            row=$(pad_row "$head" "$pct_vis" "$head" "${clr}${BLD}${pct_vis}${R}")
            out+="${row}${EOL}"$'\n'
            bar=$(make_bar "$sn_pct" "$BAR_W")
            out+="${INDENT}[${clr}${bar}${R}]${EOL}"$'\n'
            info=""
            (( $(awk -v r="$sn_rem" 'BEGIN { print (r+0 >= 0) ? 1 : 0 }') )) && info="Resets in $(fmt_dur "$sn_rem")"
            out+="${INDENT}${GRY}$(truncate_vis "$info")${R}${EOL}"$'\n'
        else
            out+="${INDENT}${DIM}$(truncate_vis 'Weekly Sonnet  -  no Sonnet usage')${R}${EOL}"$'\n'
            out+="${EOL}"$'\n'; out+="${EOL}"$'\n'
        fi

        out+="${EOL}"$'\n'

        # ---- footer ----
        if (( quota_ok )); then
            local src
            if (( CONTENT_W >= 30 )); then src="Quota: api.anthropic.com (live)"
            else src="Quota: live API"; fi
            out+="${INDENT}${GRY}$(truncate_vis "$src")${R}${EOL}"$'\n'
        else
            local src
            if (( CONTENT_W >= 40 )); then src="Quota API unavailable - local peak %"
            else src="Quota offline (local %)"; fi
            out+="${INDENT}${YEL}$(truncate_vis "$src")${R}${EOL}"$'\n'
        fi
    fi

    # ---- status line ----
    local status_line status_ansi
    if [[ "$fetching" == "1" ]]; then
        local sp="${SPIN[$((spin_idx % 4))]}"
        status_line="${sp} refreshing data..."
        status_ansi="${CYA}${status_line}${R}"
    elif [[ "$ever" == "1" ]]; then
        if (( CONTENT_W >= 32 )); then status_line="next in ${secs_left}s | Ctrl+C to quit"
        else status_line="next ${secs_left}s"; fi
        status_ansi="${GRY}${status_line}${R}"
    else
        status_line="starting first fetch..."
        status_ansi="${GRY}${status_line}${R}"
    fi
    if (( ${#status_line} <= CONTENT_W )); then
        out+="${INDENT}${status_ansi}${EOL}"$'\n'
    else
        out+="${INDENT}$(truncate_vis "$status_line")${EOL}"$'\n'
    fi

    out+="$EOS"
    printf '%s' "$out"
}

# ---------- main loop ----------
TOKEN="$(get_token)"
EVER=0
LAST_FETCH_EPOCH=0
SPIN_IDX=0
LAST_W=-1

# Best-effort: clear screen, hide cursor
printf '%s%s' "$HIDE" "${ESC}[2J${ESC}[H"

start_fetch

while true; do
    if fetch_done; then
        wait "$BG_PID" 2>/dev/null
        BG_PID=""
        LAST_FETCH_EPOCH=$(date +%s)
        EVER=1
    fi

    NOW_EPOCH=$(date +%s)
    if (( LAST_FETCH_EPOCH > 0 )); then
        ELAPSED=$((NOW_EPOCH - LAST_FETCH_EPOCH))
    else
        ELAPSED=99999
    fi
    SECS_LEFT=$((INTERVAL - ELAPSED))
    (( SECS_LEFT < 0 )) && SECS_LEFT=0

    if [[ -z "$BG_PID" ]] && (( EVER == 1 )) && (( ELAPSED >= INTERVAL )); then
        start_fetch
    fi

    # Detect resize -> clear so stale wider content doesn't bleed past new border
    CUR_W=$(tput cols 2>/dev/null || echo 60)
    if (( CUR_W != LAST_W )); then
        printf '%s' "${ESC}[2J"
        LAST_W=$CUR_W
    fi

    FETCHING=0
    [[ -n "$BG_PID" ]] && FETCHING=1

    render_frame "$FETCHING" "$SECS_LEFT" "$SPIN_IDX" "$EVER"

    SPIN_IDX=$((SPIN_IDX + 1))
    sleep 1
done
