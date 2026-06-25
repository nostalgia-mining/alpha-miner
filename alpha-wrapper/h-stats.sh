#!/usr/bin/env bash
#
# AlphaMiner PEARL — HiveOS h-stats.sh
# Parses structured alpha-miner log lines and emits JSON for HiveOS dashboard.
#
# Log format (alpha-miner): structured key=value lines, e.g.:
#   2026-06-22T12:34:56Z component=miner status gpu=0: hashrate_th_s=1.234 share_equiv_th_s=1.200 accepted=42 rejected=0
#   2026-06-22T12:34:56Z component=miner status gpu=system: hashrate_th_s=2.468 accepted=42 rejected=0
#
# Per-GPU hs[] reported in kH/s (th_s × 1e9) — avoids HiveOS sanitize ceiling.
# See h-stats.sh from official AlphaMine-Tech wrapper for detailed rationale.

[[ -z $SCRIPT_PATH ]] && SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f "$SCRIPT_PATH/h-manifest.conf" ]] && source "$SCRIPT_PATH/h-manifest.conf"
[[ -f "$SCRIPT_PATH/miner.conf" ]]      && source "$SCRIPT_PATH/miner.conf"

BUFFER_FILE="${BUFFER_FILE:-/run/alpha-wrapper/miner-raw.buf}"
log_file="$BUFFER_FILE"
: "${REPORT_METRIC:=raw}"
: "${HSTATS_RAW_LINES:=6000}"

case "$REPORT_METRIC" in
    equiv) metric_re='share_equiv_th_s=([0-9.]+)' ;;
    *)     metric_re='hashrate_th_s=([0-9.]+)'     ;;
esac

if [[ ! -f "$log_file" ]]; then
    echo "null"; exit 0
fi

khs=0; acc=0; rej=0; uptime_sec=0
declare -A hash_rates
declare -a hs_array bus_numbers temp_array fan_array

# ---- GPU hardware stats from nvidia-smi -------------------------------------
declare -A nvsmi_bus nvsmi_temp nvsmi_fan
if command -v nvidia-smi >/dev/null 2>&1; then
    while IFS=',' read -r idx bus_raw temp_raw fan_raw; do
        idx="${idx// /}"; bus_raw="${bus_raw// /}"
        temp_raw="${temp_raw// /}"; fan_raw="${fan_raw// /}"
        [[ "$idx" =~ ^[0-9]+$ ]] || continue
        bus_hex=$(echo "$bus_raw" | awk -F: '{print $(NF-1)}')
        [[ "$bus_hex" =~ ^[0-9A-Fa-f]+$ ]] && nvsmi_bus[$idx]=$(printf "%d" "0x$bus_hex")
        [[ "$temp_raw" =~ ^[0-9]+$ ]] && nvsmi_temp[$idx]="$temp_raw" || nvsmi_temp[$idx]="null"
        [[ "$fan_raw"  =~ ^[0-9]+$ ]] && nvsmi_fan[$idx]="$fan_raw"   || nvsmi_fan[$idx]="null"
    done < <(timeout 5 nvidia-smi --query-gpu=index,pci.bus_id,temperature.gpu,fan.speed \
                --format=csv,noheader,nounits 2>/dev/null)
fi

# ---- Parse log ---------------------------------------------------------------
while IFS= read -r line; do
    gpu_id=""; hash_val=""
    [[ $line =~ gpu=([0-9]+):      ]] && gpu_id="${BASH_REMATCH[1]}"
    [[ $line =~ gpu=system         ]] && gpu_id="total"
    [[ $line =~ $metric_re         ]] && hash_val="${BASH_REMATCH[1]}"

    if [[ "$gpu_id" == "total" && -n "$hash_val" ]]; then
        khs="$hash_val"
    elif [[ -n "$gpu_id" && "$gpu_id" != "total" && -n "$hash_val" ]]; then
        hash_rates[$gpu_id]="$hash_val"
    fi
done < <(tail -n "$HSTATS_RAW_LINES" "$log_file" 2>/dev/null \
            | grep -a "component=miner status")

# Accepted / rejected — from last status line first, fall back to event count
last_status=$(tail -n "$HSTATS_RAW_LINES" "$log_file" 2>/dev/null \
                | grep -aE 'component=miner status' | tail -n 1)
acc=$(echo "$last_status" | grep -oE '\baccepted=[0-9]+\b' | cut -d= -f2)
rej=$(echo "$last_status" | grep -oE '\brejected=[0-9]+\b' | cut -d= -f2)
[[ -z "$acc" ]] && acc=$(grep -ac "component=share submitted" "$log_file" 2>/dev/null || echo 0)
[[ -z "$rej" ]] && rej=$(grep -ac "component=share rejected"  "$log_file" 2>/dev/null || echo 0)
acc=${acc:-0}; rej=${rej:-0}

# Uptime from live process — search for the alpha binary in alpha-wrapper dir
miner_pid=$(pgrep -f "alpha-wrapper/alpha --pool" 2>/dev/null | head -1)
[[ -n "$miner_pid" ]] && uptime_sec=$(ps -o etimes= -p "$miner_pid" 2>/dev/null | tr -d ' ')
[[ "$uptime_sec" =~ ^[0-9]+$ ]] || uptime_sec=$(( $(date +%s) - $(stat -c %Y "$CUSTOM_CONFIG_FILENAME" 2>/dev/null || date +%s) ))

# ---- Build per-GPU arrays (kH/s = th_s × 1e9) --------------------------------
if [[ ${#hash_rates[@]} -gt 0 ]]; then
    IFS=$'\n' sorted_ids=($(printf '%s\n' "${!hash_rates[@]}" | sort -n)); unset IFS
    for g in "${sorted_ids[@]}"; do
        hs_array+=("$(awk -v v="${hash_rates[$g]}" 'BEGIN{printf "%.0f", v * 1000000000}')")
        bus_numbers+=("${nvsmi_bus[$g]:-$g}")
        temp_array+=("${nvsmi_temp[$g]:-null}")
        fan_array+=("${nvsmi_fan[$g]:-null}")
    done
fi

# khs = sum of per-GPU kH/s
if [[ ${#hs_array[@]} -gt 0 ]]; then
    sum=0
    for v in "${hs_array[@]}"; do sum=$(awk -v a="$sum" -v b="$v" 'BEGIN{printf "%.0f",a+b}'); done
    khs=$(awk -v s="$sum" 'BEGIN{printf "%.0f", s}')
fi

# ---- Build JSON --------------------------------------------------------------
if [[ ${#hs_array[@]} -gt 0 ]]; then
    hs_json=$(printf '%s\n'   "${hs_array[@]}"    | jq -Rs 'split("\n")[:-1]|map(tonumber)' 2>/dev/null || echo '[0]')
    bus_json=$(printf '%s\n'  "${bus_numbers[@]}"  | jq -Rs 'split("\n")[:-1]|map(tonumber)' 2>/dev/null || echo '[0]')
    temp_json=$(printf '%s\n' "${temp_array[@]}"   | jq -Rs 'split("\n")[:-1]|map(if .=="null" then null else tonumber end)' 2>/dev/null || echo '[]')
    fan_json=$(printf '%s\n'  "${fan_array[@]}"    | jq -Rs 'split("\n")[:-1]|map(if .=="null" then null else tonumber end)' 2>/dev/null || echo '[]')
else
    hs_json='[0]'; bus_json='[0]'; temp_json='[]'; fan_json='[]'
fi

[[ -z "$khs" ]] && khs=0

jq -nc \
    --argjson khs "$khs" \
    --argjson total_khs "$khs" \
    --arg     hs_units  "khs" \
    --argjson hs        "$hs_json" \
    --argjson temp      "$temp_json" \
    --argjson fan       "$fan_json" \
    --argjson uptime    "$uptime_sec" \
    --argjson ar        "[$acc, $rej]" \
    --arg     algo      "pearlhash" \
    --argjson bus_numbers "$bus_json" \
    '{$khs, $total_khs, $hs_units, $hs, $temp, $fan, $uptime, $ar, $algo, $bus_numbers}'
