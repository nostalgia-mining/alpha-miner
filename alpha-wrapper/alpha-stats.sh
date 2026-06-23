#!/usr/bin/env bash
#
# AlphaMiner PEARL — on-screen stats (NOCKminer-style table, every 3 min)
#
# Launched by h-run.sh as a background job.
# Env vars injected by h-run.sh:
#   LOG_FILE    — path to the miner log
#   GPU_LIST    — comma-separated CUDA indices active in this run
#   WALLET      — PEARL wallet address (for display)
set -u

LOG_FILE="${LOG_FILE:-/var/log/miner/custom/alpha-wrapper.log}"
GPU_LIST="${GPU_LIST:-}"
WALLET="${WALLET:-unknown}"

GPU_LIST_FILE="/var/run/hive/alpha-wrapper_gpus.conf"
[[ -z "$GPU_LIST" && -f "$GPU_LIST_FILE" ]] && GPU_LIST="$(cat "$GPU_LIST_FILE" 2>/dev/null)"

STATS_INTERVAL=180
MAX_SAMPLES=6

# ===== Colors =================================================================
green=$'\e[32m'
reset=$'\e[0m'

# ===== Layout constants =======================================================
CONTENT_W=71

printf -v BAR_DASH '%*s' "$CONTENT_W" ''; BAR_DASH="${BAR_DASH// /-}"
printf -v BAR_EQ   '%*s' "$CONTENT_W" ''; BAR_EQ="${BAR_EQ// /=}"

_title="[ stats ]"
_left=$(( (CONTENT_W - ${#_title}) / 2 ))
_right=$(( CONTENT_W - ${#_title} - _left ))
printf -v _L '%*s' "$_left"  ''; _L="${_L// /-}"
printf -v _R '%*s' "$_right" ''; _R="${_R// /-}"
TOP_TITLE="${_L}${_title}${_R}"
unset _title _left _right _L _R

MID_PIPE=35   # column of the vertical separator in the footer

# ===== Helpers ================================================================
VER="1.8.3"
START_EPOCH="$(date +%s)"

short_name()    { sed -E 's/^NVIDIA //; s/^GeForce //'; }
truncate_mid()  {
    local s="$1" w="$2"
    (( ${#s} <= w )) && printf "%s" "$s" && return
    local L=$(( (w-3)/2 )) R=$(( w-3-L ))
    printf "%s...%s" "${s:0:L}" "${s: -R}"
}
uptime_str() {
    local up=$(( $(date +%s) - START_EPOCH ))
    (( up >= 86400 )) \
        && printf "%dd %dh %dm" $((up/86400)) $(( (up%86400)/3600 )) $(( (up%3600)/60 )) \
        || printf "%dh %dm %ds" $((up/3600)) $(( (up%3600)/60 )) $((up%60))
}
# Auto-scale H/s value to human-readable string
fmt_hs() {
    awk -v v="$1" 'BEGIN{
        if      (v >= 1e12) printf "%.3f TH/s", v/1e12
        else if (v >= 1e9)  printf "%.3f GH/s", v/1e9
        else if (v >= 1e6)  printf "%.2f MH/s", v/1e6
        else if (v >= 1e3)  printf "%.1f kH/s", v/1e3
        else                printf "%.0f H/s",  v
    }'
}

# ===== Share counters =========================================================
TOTAL_ACC=0
TOTAL_REJ=0

load_shares() {
    # Preferred: parse from last "gpu=system" status line (accurate running totals)
    local last_sys
    last_sys=$(grep -a "component=miner status" "$LOG_FILE" 2>/dev/null \
               | grep "gpu=system" | tail -n1)
    TOTAL_ACC=$(echo "$last_sys" | grep -oE '\baccepted=[0-9]+\b' | cut -d= -f2)
    TOTAL_REJ=$(echo "$last_sys" | grep -oE '\brejected=[0-9]+\b' | cut -d= -f2)
    # Fallback: count event lines
    [[ -z "$TOTAL_ACC" ]] && TOTAL_ACC=$(grep -ac "component=share submitted" "$LOG_FILE" 2>/dev/null || echo 0)
    [[ -z "$TOTAL_REJ" ]] && TOTAL_REJ=$(grep -ac "component=share rejected"  "$LOG_FILE" 2>/dev/null || echo 0)
    TOTAL_ACC="${TOTAL_ACC:-0}"
    TOTAL_REJ="${TOTAL_REJ:-0}"
}

# ===== GPU metrics ============================================================
IFS=',' read -ra GPU_IDX_LIST <<< "$GPU_LIST"
declare -A IGNORED_ZERO=()

GPU_NAMES=() GPU_HASH=() GPU_WATTS=() GPU_TEMP=() GPU_FAN=() GPU_CCLK=() GPU_MCLK=()
TOTAL_HASH_RAW="0"
TOTAL_WATTS="0.0"

collect_gpu_metrics() {
    GPU_NAMES=(); GPU_HASH=(); GPU_WATTS=(); GPU_TEMP=(); GPU_FAN=(); GPU_CCLK=(); GPU_MCLK=()
    TOTAL_HASH_RAW="0"; TOTAL_WATTS="0.0"

    for pos in "${!GPU_IDX_LIST[@]}"; do
        local idx="${GPU_IDX_LIST[$pos]}"
        local name temp fan cclk mclk watts
        name="$( nvidia-smi -i "$idx" --query-gpu=name             --format=csv,noheader 2>/dev/null | short_name)"
        temp="$( nvidia-smi -i "$idx" --query-gpu=temperature.gpu  --format=csv,noheader,nounits 2>/dev/null)"
        fan="$(  nvidia-smi -i "$idx" --query-gpu=fan.speed        --format=csv,noheader,nounits 2>/dev/null)"
        cclk="$( nvidia-smi -i "$idx" --query-gpu=clocks.sm        --format=csv,noheader,nounits 2>/dev/null)"
        mclk="$( nvidia-smi -i "$idx" --query-gpu=clocks.mem       --format=csv,noheader,nounits 2>/dev/null)"
        watts="$(nvidia-smi -i "$idx" --query-gpu=power.draw       --format=csv,noheader,nounits 2>/dev/null)"
        [[ -z "$name"  ]] && name="n/a"
        [[ -z "$temp"  ]] && temp="n/a"
        [[ -z "$fan"   ]] && fan="n/a"
        [[ -z "$cclk"  ]] && cclk="n/a"
        [[ -z "$mclk"  ]] && mclk="n/a"
        [[ -z "$watts" || "$watts" == "N/A" ]] && watts="0.0"
        watts=$(awk -v w="$watts" 'BEGIN{printf "%.1f", w+0}')

        # Parse hashrate_th_s for this CUDA index from structured log lines.
        # The miner logs gpu=<CUDA index>: which matches pos (since we use
        # CUDA_DEVICE_ORDER=PCI_BUS_ID and CUDA_VISIBLE_DEVICES if needed).
        mapfile -t samp < <(
            grep -a "component=miner status" "$LOG_FILE" 2>/dev/null \
            | grep -a "gpu=${pos}:" \
            | grep -oE 'hashrate_th_s=[0-9.]+' \
            | awk -F= '{printf "%.0f\n", $2 * 1e12}' \
            | tail -n "$MAX_SAMPLES"
        )

        # Ignore the very first sample if it's zero (warm-up)
        if [[ -z "${IGNORED_ZERO[$pos]:-}" ]]; then
            for k in "${!samp[@]}"; do
                if [[ "${samp[$k]}" == "0" ]]; then
                    unset "samp[$k]"
                    IGNORED_ZERO[$pos]=1
                    break
                fi
            done
        fi

        local avg_raw=0
        if (( ${#samp[@]} > 0 )); then
            avg_raw=$(printf '%s\n' "${samp[@]}" | awk '{s+=$1} END{printf "%.0f", s/NR}')
        fi

        GPU_NAMES+=("$name")
        GPU_HASH+=("$avg_raw")
        GPU_WATTS+=("$watts")
        GPU_TEMP+=("$temp")
        GPU_FAN+=("$fan")
        GPU_CCLK+=("$cclk")
        GPU_MCLK+=("$mclk")

        TOTAL_HASH_RAW=$(awk -v a="$TOTAL_HASH_RAW" -v b="$avg_raw" 'BEGIN{printf "%.0f", a+b}')
        TOTAL_WATTS=$(awk -v a="$TOTAL_WATTS" -v b="$watts" 'BEGIN{printf "%.1f", a+b}')
    done
}

# ===== Render =================================================================
render() {
    local ts="[$(date +'%H:%M:%S')]"
    local up; up="$(uptime_str)"
    local addr; addr="$(truncate_mid "$WALLET" 61)"

    # Header
    printf "${green}%s %s${reset}\n" "$ts" "$TOP_TITLE"
    printf "${green}%s %-30s|  Uptime: %-12s|%s${reset}\n" \
        "$ts" "AlphaMiner v${VER}" "$up" " PEARL / AlphaPool"
    printf "${green}%s Address: %s${reset}\n" "$ts" "$addr"
    printf "${green}%s %s${reset}\n" "$ts" "$BAR_DASH"

    # GPU table header
    printf "${green}%s  %-2s  %-18s  %-14s  %-6s  %-5s  %-4s  %-4s  %-5s${reset}\n" \
        "$ts" "#" "GPU Name" "Hashrate" "Watts" "Temp" "Fan" "CClk" "MClk"
    printf "${green}%s %s${reset}\n" "$ts" "$BAR_EQ"

    # Per-GPU rows
    for i in "${!GPU_IDX_LIST[@]}"; do
        local disp; disp="$(fmt_hs "${GPU_HASH[$i]}")"
        printf "${green}%s  %-2d  %-18.18s  %-14s  %-6s  %-5s  %-4s  %-4s  %-5s${reset}\n" \
            "$ts" "$i" "${GPU_NAMES[$i]}" "$disp" \
            "${GPU_WATTS[$i]}W" "${GPU_TEMP[$i]}°C" "${GPU_FAN[$i]}%" \
            "${GPU_CCLK[$i]}" "${GPU_MCLK[$i]}"
    done

    # Total row
    local total_disp; total_disp="$(fmt_hs "$TOTAL_HASH_RAW")"
    printf "${green}%s  %-2s  %-18s  %-14s  %-6s${reset}\n" \
        "$ts" "" "Total" "$total_disp" "${TOTAL_WATTS}W"
    printf "${green}%s %s${reset}\n" "$ts" "$BAR_DASH"

    # Footer: two-column shares / pool info
    local left_w=$((MID_PIPE - 1))
    local right_w=$((CONTENT_W - MID_PIPE))
    printf "${green}%s %-*s|%-*s${reset}\n" "$ts" \
        "$left_w" "  Shares" "$right_w" " Pool Info"
    printf "${green}%s %s${reset}\n" "$ts" "$BAR_EQ"
    printf "${green}%s  Accepted : %-10s   |  Pool : AlphaPool${reset}\n"  "$ts" "$TOTAL_ACC"
    printf "${green}%s  Rejected : %-10s   |  Algo : pearlhash${reset}\n" "$ts" "$TOTAL_REJ"
    printf "${green}%s %s${reset}\n" "$ts" "$BAR_DASH"
}

# ===== Main loop ==============================================================
while [[ ! -f "$LOG_FILE" ]]; do sleep 2; done

while true; do
    sleep "$STATS_INTERVAL"
    load_shares
    collect_gpu_metrics
    render
done
