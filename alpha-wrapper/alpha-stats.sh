#!/usr/bin/env bash
#
# alpha-stats.sh -- periodic stats table for alpha-wrapper (every 30 seconds)
#
# Output goes to stdout (screen) AND is tee'd to LOG_FILE.
#
# Env vars:
#   BUFFER_FILE   /run/alpha-wrapper/miner-raw.buf
#   LOG_FILE      /var/log/miner/custom/alpha-wrapper.log
#   GPU_LIST      comma-separated CUDA indices
#   WALLET        PEARL wallet address
#   POOL_HOST     pool host:port string (for display)
set -u

BUFFER_FILE="${BUFFER_FILE:-/run/alpha-wrapper/miner-raw.buf}"
LOG_FILE="${LOG_FILE:-/var/log/miner/custom/alpha-wrapper.log}"
GPU_LIST="${GPU_LIST:-0}"
WALLET="${WALLET:-unknown}"
POOL_HOST="${POOL_HOST:-alphapool.tech:5566}"

STATS_INTERVAL=30
MAX_SAMPLES=6
HSTATS_RAW_LINES=2000

# Pool calibration:
#   14453 shares / 86400 sec @ diff 524288 = 376.68 TH/s
#   => seconds per share = diff * 86400 * 524288 / (14453 * 524288 * th_rate)
#      simplified: TTF = diff * K / hashrate_TH_s
#      K = 86400 / (14453 / 524288) = 86400 * 524288 / 14453 = 3,132,026.7
POOL_K="3132026.7"

# ===== Colors =================================================================
G=$'\e[32m'
R=$'\e[0m'
B=$'\e[1m'

# ===== Layout =================================================================
#
# Table width TW=100 (the content between the leading timestamp and newline).
# Timestamp prefix is printed separately: "[HH:MM:SS] " = 11 chars, not in TW.
#
# GPU table column content widths (must sum to TW with separators):
#   Sep pattern: 1 space between every column
#   #(2) + Name(21) + Hashrate(14) + Shares(7) + Watts(8) + Eff(11) + Temp(5) + Fan(4) + CClk(5) + MClk(5)
#   = 2+21+14+7+8+11+5+4+5+5 = 82 content + 9 separators = 91
#   Add 1 leading space: 92. Pad to TW=100 with extra space in wider columns.
#
# Adjusted (add slack to Name=22, Hashrate=15, Eff=12):
#   2 + 22 + 15 + 7 + 8 + 12 + 5 + 4 + 5 + 5 = 85 + 9 seps = 94 + 1 lead = 95
# Use TW=96 to keep things tight.
#
TW=96

# Build bars
printf -v BAR_DASH '%*s' "$TW" ''; BAR_DASH="${BAR_DASH// /-}"
printf -v BAR_EQ   '%*s' "$TW" ''; BAR_EQ="${BAR_EQ// /=}"

# Title bar: "[ stats ]" centered in TW dashes
_ttl="[ stats ]"
_lw=$(( (TW - ${#_ttl}) / 2 ))
_rw=$(( TW - ${#_ttl} - _lw ))
printf -v _L '%*s' "$_lw" ''; _L="${_L// /-}"
printf -v _R '%*s' "$_rw" ''; _R="${_R// /-}"
TOP_TITLE="${_L}${_ttl}${_R}"
unset _ttl _lw _rw _L _R

# Footer split: MID=48 so left pane = 48 chars, '|', right pane = TW-49 = 47 chars
# TW=96: left=48, pipe=1, right=47
MID=48

# ===== Helpers ================================================================
VER="1.8.3"
START_EPOCH="$(date +%s)"

uptime_str() {
    local up=$(( $(date +%s) - START_EPOCH ))
    (( up >= 86400 )) \
        && printf "%dd %dh %dm" $((up/86400)) $(( (up%86400)/3600 )) $(( (up%3600)/60 )) \
        || printf "%dh %dm %ds" $((up/3600)) $(( (up%3600)/60 )) $((up%60))
}

fmt_hs() {
    awk -v v="$1" 'BEGIN{
        if      (v >= 1e12) printf "%.2f TH/s", v/1e12
        else if (v >= 1e9)  printf "%.2f GH/s", v/1e9
        else if (v >= 1e6)  printf "%.2f MH/s", v/1e6
        else if (v >= 1e3)  printf "%.1f kH/s", v/1e3
        else                printf "%.0f H/s",  v
    }'
}

fmt_eff() {
    awk -v h="$1" -v w="$2" 'BEGIN{
        if (w > 0.0001) printf "%.2f TH/W", (h/1e12)/w
        else            printf "n/a"
    }'
}

fmt_ttf() {
    awk -v s="$1" 'BEGIN{
        if (s <= 0)    { printf "n/a"; next }
        if (s < 60)    { printf "%.0f sec", s; next }
        if (s < 3600)  { printf "%.1f min", s/60; next }
        printf "%.1f hr", s/3600
    }'
}

fmt_ago() {
    local ago=$1
    (( ago < 0 ))    && printf "n/a" && return
    (( ago < 60 ))   && printf "%d sec ago" "$ago" && return
    (( ago < 3600 )) && printf "%d min ago" $((ago/60)) && return
    printf "%d hr ago" $((ago/3600))
}

# Truncate wallet: first 6 chars + "..." + last 6 chars
trunc_wallet() {
    local w="$1"
    (( ${#w} <= 15 )) && printf "%s" "$w" && return
    printf "%s...%s" "${w:0:6}" "${w: -6}"
}

short_name() { sed -E 's/^NVIDIA GeForce //; s/^NVIDIA //'; }

# Print a line to stdout AND append to log (strips ANSI for log)
# Usage: tprint "raw string with colors"
tprint() {
    local line="$1"
    printf '%s\n' "$line"
    # Strip ANSI escape codes before writing to log
    printf '%s\n' "$line" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

# ===== Per-GPU diff tracking ==================================================
# Read from buffer: latest difficulty per GPU from component=pool job DEBUG lines
get_gpu_diff() {
    local idx="$1"
    local val
    val=$(grep -a "component=pool" "$BUFFER_FILE" 2>/dev/null \
          | grep -a " gpu=${idx}:" \
          | grep -a " difficulty=" \
          | tail -n1 \
          | grep -oE '[[:space:]]difficulty=[0-9.]+' \
          | grep -oE '[0-9.]+')
    val="${val%.00}"
    printf '%s' "${val:-?}"
}

# ===== Data collection ========================================================
IFS=',' read -ra GPU_IDX_LIST <<< "$GPU_LIST"
declare -A IGNORED_ZERO=()

GPU_NAMES=()
GPU_HASH_RAW=()
GPU_EQUIV_RAW=()
GPU_WATTS=()
GPU_TEMP=()
GPU_FAN=()
GPU_CCLK=()
GPU_MCLK=()
GPU_ACC=()
GPU_REJ=()
GPU_DIFFS=()
TOTAL_HASH_RAW=0
TOTAL_EQUIV_RAW=0
TOTAL_WATTS=0
TOTAL_ACC=0
TOTAL_REJ=0

collect_gpu_metrics() {
    GPU_NAMES=(); GPU_HASH_RAW=(); GPU_EQUIV_RAW=()
    GPU_WATTS=(); GPU_TEMP=(); GPU_FAN=(); GPU_CCLK=(); GPU_MCLK=()
    GPU_ACC=(); GPU_REJ=(); GPU_DIFFS=()
    TOTAL_HASH_RAW=0; TOTAL_EQUIV_RAW=0; TOTAL_WATTS=0
    TOTAL_ACC=0; TOTAL_REJ=0

    for pos in "${!GPU_IDX_LIST[@]}"; do
        local idx="${GPU_IDX_LIST[$pos]}"

        # Hardware
        local name temp fan cclk mclk watts
        name="$(nvidia-smi -i "$idx" --query-gpu=name            --format=csv,noheader 2>/dev/null | short_name)"
        temp="$(nvidia-smi -i "$idx" --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null)"
        fan="$( nvidia-smi -i "$idx" --query-gpu=fan.speed       --format=csv,noheader,nounits 2>/dev/null)"
        cclk="$(nvidia-smi -i "$idx" --query-gpu=clocks.sm       --format=csv,noheader,nounits 2>/dev/null)"
        mclk="$(nvidia-smi -i "$idx" --query-gpu=clocks.mem      --format=csv,noheader,nounits 2>/dev/null)"
        watts="$(nvidia-smi -i "$idx" --query-gpu=power.draw     --format=csv,noheader,nounits 2>/dev/null)"
        [[ -z "$name"  ]] && name="n/a"
        [[ -z "$temp"  ]] && temp="n/a"
        [[ -z "$fan"   ]] && fan="n/a"
        [[ -z "$cclk"  ]] && cclk="n/a"
        [[ -z "$mclk"  ]] && mclk="n/a"
        [[ -z "$watts" || "$watts" == "N/A" ]] && watts=0
        watts=$(awk -v w="$watts" 'BEGIN{printf "%.1f", w+0}')

        # Hashrate samples from buffer
        mapfile -t hash_samp < <(
            tail -n "$HSTATS_RAW_LINES" "$BUFFER_FILE" 2>/dev/null \
            | grep -a "component=miner status" \
            | grep -a " gpu=${idx}:" \
            | grep -oE '[[:space:]]hashrate_th_s=[0-9.]+' \
            | grep -oE '[0-9.]+' \
            | awk '{printf "%.0f\n", $1 * 1e12}' \
            | tail -n "$MAX_SAMPLES"
        )
        mapfile -t equiv_samp < <(
            tail -n "$HSTATS_RAW_LINES" "$BUFFER_FILE" 2>/dev/null \
            | grep -a "component=miner status" \
            | grep -a " gpu=${idx}:" \
            | grep -oE '[[:space:]]share_equiv_th_s=[0-9.]+' \
            | grep -oE '[0-9.]+' \
            | awk '{printf "%.0f\n", $1 * 1e12}' \
            | tail -n "$MAX_SAMPLES"
        )

        # Skip initial zero
        if [[ -z "${IGNORED_ZERO[$idx]:-}" ]] && (( ${#hash_samp[@]} > 0 )); then
            if [[ "${hash_samp[0]}" == "0" ]]; then
                hash_samp=("${hash_samp[@]:1}")
                IGNORED_ZERO[$idx]=1
            fi
        fi

        local avg_hash=0 avg_equiv=0
        (( ${#hash_samp[@]}  > 0 )) && avg_hash=$(printf '%s\n'  "${hash_samp[@]}"  | awk '{s+=$1} END{printf "%.0f",s/NR}')
        (( ${#equiv_samp[@]} > 0 )) && avg_equiv=$(printf '%s\n' "${equiv_samp[@]}" | awk '{s+=$1} END{printf "%.0f",s/NR}')

        # Accepted / rejected from last status line for this GPU
        local last_stat acc=0 rej=0
        last_stat=$(tail -n "$HSTATS_RAW_LINES" "$BUFFER_FILE" 2>/dev/null \
            | grep -a "component=miner status" \
            | grep -a " gpu=${idx}:" \
            | tail -n1)
        [[ "$last_stat" =~ [[:space:]]accepted=([0-9]+) ]] && acc="${BASH_REMATCH[1]}"
        [[ "$last_stat" =~ [[:space:]]rejected=([0-9]+) ]] && rej="${BASH_REMATCH[1]}"

        # Difficulty from pool job DEBUG lines
        local diff; diff="$(get_gpu_diff "$idx")"

        GPU_NAMES+=("$name")
        GPU_HASH_RAW+=("$avg_hash")
        GPU_EQUIV_RAW+=("$avg_equiv")
        GPU_WATTS+=("$watts")
        GPU_TEMP+=("$temp")
        GPU_FAN+=("$fan")
        GPU_CCLK+=("$cclk")
        GPU_MCLK+=("$mclk")
        GPU_ACC+=("$acc")
        GPU_REJ+=("$rej")
        GPU_DIFFS+=("$diff")

        TOTAL_HASH_RAW=$(awk  -v a="$TOTAL_HASH_RAW"  -v b="$avg_hash"  'BEGIN{printf "%.0f",a+b}')
        TOTAL_EQUIV_RAW=$(awk -v a="$TOTAL_EQUIV_RAW" -v b="$avg_equiv" 'BEGIN{printf "%.0f",a+b}')
        TOTAL_WATTS=$(awk     -v a="$TOTAL_WATTS"     -v b="$watts"     'BEGIN{printf "%.1f",a+b}')
        TOTAL_ACC=$(( TOTAL_ACC + acc ))
        TOTAL_REJ=$(( TOTAL_REJ + rej ))
    done
}

LAST_SHARE_AGO=-1
collect_share_metrics() {
    local last_ts
    last_ts=$(tail -n "$HSTATS_RAW_LINES" "$BUFFER_FILE" 2>/dev/null \
        | grep -a "component=share accepted" \
        | tail -n1 \
        | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}')
    LAST_SHARE_AGO=-1
    if [[ -n "$last_ts" ]]; then
        local ep; ep=$(date -d "${last_ts}Z" +%s 2>/dev/null) || ep=0
        LAST_SHARE_AGO=$(( $(date +%s) - ep ))
    fi
}

LAST_PING_MS=0
collect_ping() {
    LAST_PING_MS=0
    local recent; recent=$(tail -n 200 "$BUFFER_FILE" 2>/dev/null)

    # Find line number of last accepted share in the recent block
    local acc_line_num
    acc_line_num=$(printf '%s\n' "$recent" \
        | grep -na "component=share accepted" | tail -n1 | cut -d: -f1)
    [[ -z "$acc_line_num" ]] && return

    local acc_line acc_ts
    acc_line=$(printf '%s\n' "$recent" | sed -n "${acc_line_num}p")
    acc_ts="${acc_line%% *}"

    # In the lines before accepted, find the last hits-increment
    local before prev_hits=0 submit_ts=""
    before=$(printf '%s\n' "$recent" | head -n "$acc_line_num")

    while IFS= read -r sline; do
        [[ "$sline" =~ "component=miner status" ]] || continue
        local cur_hits=0
        [[ "$sline" =~ [[:space:]]hits=([0-9]+) ]] && cur_hits="${BASH_REMATCH[1]}"
        if (( cur_hits > prev_hits )); then
            submit_ts="${sline%% *}"
        fi
        prev_hits=$cur_hits
    done <<< "$before"

    [[ -z "$submit_ts" ]] && return

    # ms conversion (local function to avoid subshell)
    _to_ms() {
        local ts="$1"
        local sp="${ts%.*}" frac="${ts##*.}"
        frac="${frac%Z}"; frac="${frac:0:3}"
        while (( ${#frac} < 3 )); do frac="${frac}0"; done
        local ep; ep=$(date -d "${sp}Z" +%s 2>/dev/null) || ep=0
        echo $(( ep * 1000 + 10#$frac ))
    }

    local sub_ms acc_ms diff_ms
    sub_ms=$(_to_ms "$submit_ts")
    acc_ms=$(_to_ms "$acc_ts")
    diff_ms=$(( acc_ms - sub_ms ))
    (( diff_ms > 0 && diff_ms < 60000 )) && LAST_PING_MS=$diff_ms
}

# ===== Render =================================================================
#
# Column widths for GPU table (content only, printed with %-Xs):
#   IDX=2  NAME=22  HR=14  SH=7  WA=8  EFF=11  TMP=5  FAN=4  CLK=5  MCL=5
#   Separator: single space between columns
#   Total: 2+1+22+1+14+1+7+1+8+1+11+1+5+1+4+1+5+1+5 = 91 + leading space = 92
#   TW=96 -> header line ends with 4 extra spaces (absorbed by last col)
#
# Footer panes: MID=48 | right=47
#   Left label col: 18 chars right-aligned, ": ", value left-aligned in rest
#   Right label col: 9 chars right-aligned, ": ", value left-aligned in rest
#   The ":" is at position 20 from left edge of each pane (1-indexed).
#
# All lines prefixed with "[HH:MM:SS] " (11 chars) by tprint.
# We DON'T include the timestamp in TW; TW is the content width only.

render() {
    local ts; ts="[$(date +'%H:%M:%S')]"
    local up; up="$(uptime_str)"
    local wallet_s; wallet_s="$(trunc_wallet "$WALLET")"

    # Right-align fields: "Uptime: X" and "Address: Y" flush right in TW
    local uptime_str="Uptime: ${up}"
    local addr_str="Address: ${wallet_s}"

    # ---- Title bar -----------------------------------------------------------
    tprint "${G}${B}${ts} ${TOP_TITLE}${R}"

    # ---- Header row 1: left="AlphaMiner v1.8.3"  right="Uptime: Xh Xm Xs"
    # Left is printed as-is, right is right-justified in TW
    local left1="AlphaMiner v${VER}"
    local pad1=$(( TW - ${#left1} - ${#uptime_str} ))
    (( pad1 < 1 )) && pad1=1
    printf -v _sp1 '%*s' "$pad1" ''
    tprint "${G}${ts} ${left1}${_sp1}${uptime_str}${R}"

    # ---- Header row 2: left="PEARL / AlphaPool"  right="Address: prl1XX...XX"
    local left2="PEARL / AlphaPool"
    local pad2=$(( TW - ${#left2} - ${#addr_str} ))
    (( pad2 < 1 )) && pad2=1
    printf -v _sp2 '%*s' "$pad2" ''
    tprint "${G}${ts} ${left2}${_sp2}${addr_str}${R}"

    tprint "${G}${ts} ${BAR_DASH}${R}"

    # ---- GPU table header ----------------------------------------------------
    # Format: " %-2s  %-22s  %-14s  %-7s  %-8s  %-11s  %-5s  %-4s  %-5s  %-5s"
    local hdr
    printf -v hdr " %-2s  %-22s  %-14s  %-7s  %-8s  %-11s  %-5s  %-4s  %-5s  %-5s" \
        "#" "GPU Name" "Hashrate" "Shares" "Watts" "Efficiency" "Temp" "Fan" "CClk" "MClk"
    tprint "${G}${ts}${hdr}${R}"
    tprint "${G}${ts} ${BAR_EQ}${R}"

    # ---- Per-GPU rows --------------------------------------------------------
    local i
    for i in "${!GPU_IDX_LIST[@]}"; do
        local idx="${GPU_IDX_LIST[$i]}"
        local hr;     hr="$(fmt_hs "${GPU_HASH_RAW[$i]}")"
        local eff;    eff="$(fmt_eff "${GPU_HASH_RAW[$i]}" "${GPU_WATTS[$i]}")"
        local shares="${GPU_ACC[$i]:-0}/${GPU_REJ[$i]:-0}"
        local watts_s="${GPU_WATTS[$i]}W"
        local temp_s="${GPU_TEMP[$i]}C"
        local fan_s="${GPU_FAN[$i]}%"
        local row
        printf -v row " %-2d  %-22.22s  %-14s  %-7s  %-8s  %-11s  %-5s  %-4s  %-5s  %-5s" \
            "$idx" "${GPU_NAMES[$i]}" \
            "$hr" "$shares" "$watts_s" "$eff" \
            "$temp_s" "$fan_s" \
            "${GPU_CCLK[$i]}" "${GPU_MCLK[$i]}"
        tprint "${G}${ts}${row}${R}"
    done

    # ---- Total row -----------------------------------------------------------
    local total_hr;  total_hr="$(fmt_hs  "$TOTAL_HASH_RAW")"
    local total_eff; total_eff="$(fmt_eff "$TOTAL_HASH_RAW" "$TOTAL_WATTS")"
    local total_sh="${TOTAL_ACC}/${TOTAL_REJ}"
    local total_w="${TOTAL_WATTS}W"
    local total_row
    printf -v total_row " %-2s  %-22s  %-14s  %-7s  %-8s  %-11s" \
        "" "Total" "$total_hr" "$total_sh" "$total_w" "$total_eff"
    tprint "${G}${ts}${total_row}${R}"

    tprint "${G}${ts} ${BAR_DASH}${R}"

    # ---- Footer --------------------------------------------------------------
    # Layout: left pane = MID=48 chars | right pane = TW-MID-1=47 chars
    # Column titles centered in each pane
    local left_w=$MID
    local right_w=$(( TW - MID - 1 ))

    # Center "Share Metrics" in left_w
    local ltitle="Share Metrics"
    local lpad=$(( (left_w - ${#ltitle}) / 2 ))
    local lrpad=$(( left_w - ${#ltitle} - lpad ))
    printf -v lhdr '%*s%s%*s' "$lpad" '' "$ltitle" "$lrpad" ''

    # Center "Pool Info" in right_w
    local rtitle="Pool Info"
    local rpad=$(( (right_w - ${#rtitle}) / 2 ))
    local rrpad=$(( right_w - ${#rtitle} - rpad ))
    printf -v rhdr '%*s%s%*s' "$rpad" '' "$rtitle" "$rrpad" ''

    tprint "${G}${ts} ${lhdr}|${rhdr}${R}"
    tprint "${G}${ts} ${BAR_EQ}${R}"

    # Footer content rows.
    # Each row: label + ": " + value, centered such that ":" is at fixed col 22
    # within each pane (label is right-padded to 20 chars, then ": ", then value).
    # Label width = 20, colon at pos 21, value starts at 23.
    # Total left content = left_w=48: "  " + 18-char label + ": " + value(26) = 48
    # We use: printf "  %-18s: %-26s" label value  -> 2+18+2+26 = 48. Perfect.

    # Gather values
    local diff_0="${GPU_DIFFS[0]:-?}"
    local ttf_str="n/a"
    if (( TOTAL_HASH_RAW > 0 )); then
        local ttf_secs
        ttf_secs=$(awk -v d="$diff_0" -v k="$POOL_K" -v h="$TOTAL_HASH_RAW" \
            'BEGIN{printf "%.0f", (d+0) * k / (h / 1e12)}')
        ttf_str="$(fmt_ttf "$ttf_secs")"
    fi

    local last_str; last_str="$(fmt_ago "$LAST_SHARE_AGO")"
    local est_str;  est_str="$(fmt_hs  "$TOTAL_EQUIV_RAW")"

    local ping_str="n/a"
    (( LAST_PING_MS > 0 )) && ping_str="${LAST_PING_MS} ms"

    local pool_disp="${POOL_HOST#stratum+tcp://}"

    # Build each row: "  %-18s: %-26s" | "  %-9s: %-s"
    # Left pane: label 18 chars right-aligned, value 26 chars left-aligned
    # Right pane: label 9 chars right-aligned, value left-aligned in remaining space
    _frow() {
        local ll="$1" lv="$2" rl="$3" rv="$4"
        # Left pane: 2 leading spaces + 18-char label + ": " + 26-char value = 48
        local lc; printf -v lc '  %18s: %-26s' "$ll" "$lv"
        lc="${lc:0:$left_w}"
        # Right pane: 2 leading spaces + 9-char label + ": " + rest
        local rc; printf -v rc '  %9s: %s' "$rl" "$rv"
        tprint "${G}${ts} ${lc}|${rc}${R}"
    }

    _frow "Time to find" "$ttf_str"   "Pool"  "$pool_disp"
    _frow "Last found"   "$last_str"  "Ping"  "$ping_str"
    _frow "Est. hashrate" "$est_str"  "Algo"  "pearlhash"

    tprint "${G}${ts} ${BAR_DASH}${R}"
}

# ===== Main loop ==============================================================
while [[ ! -f "$BUFFER_FILE" ]]; do sleep 2; done
while ! grep -qa "component=miner status" "$BUFFER_FILE" 2>/dev/null; do sleep 2; done

while true; do
    collect_gpu_metrics
    collect_share_metrics
    collect_ping
    render
    sleep "$STATS_INTERVAL"
done
