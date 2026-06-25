#!/usr/bin/env bash
#
# alpha-stats.sh -- periodic stats table (every 30 seconds)
# Layout matches pearl_stats_table.txt exactly (TW=91).
#
# Env vars: BUFFER_FILE  LOG_FILE  GPU_LIST  WALLET  POOL_HOST
set -u

BUFFER_FILE="${BUFFER_FILE:-/run/alpha-wrapper/miner-raw.buf}"
LOG_FILE="${LOG_FILE:-/var/log/miner/custom/alpha-wrapper.log}"
GPU_LIST="${GPU_LIST:-0}"
WALLET="${WALLET:-unknown}"
POOL_HOST="${POOL_HOST:-alphapool.tech:5566}"

STATS_INTERVAL=30
MAX_SAMPLES=6
HSTATS_RAW_LINES=6000

# TTF formula derivation:
# Reference: 14453 shares/day @ 376.68 TH/s @ diff 524288
#   shares/second = 14453 / 86400 = 0.16728 shares/sec
#   seconds per share = 1 / 0.16728 = 5.98 sec at this hashrate/diff
#   
#   TTF_at_diff_d_and_rate_h = (d / 524288) × 5.98 × (376.68 / h)
#                              = d × 5.98 × 376.68 / (524288 × h)
#                              = d × 2252.8 / (524288 × h)
#                              = (d / h) × (2252.8 / 524288)
#                              = (d / h) × 0.004295597
#
# So: TTF_seconds = diff / hashrate_TH × 0.004295597
#     But we want diff / (hashrate_TH × RATE), so:
#     RATE = 1 / 0.004295597 = 232.87
POOL_RATE_DIVISOR="232.87"  # TTF = diff / (hashrate_TH × POOL_RATE_DIVISOR)

# ===== Colors — all disabled for plain text output ============================
G=''; R=''; B=''

# ===== Layout constants =======================================================
# TW=91 is the content width (chars after the "[HH:MM:SS] " timestamp prefix).
TW=91

# Column start positions (0-indexed within the 91-char content string):
#  IDX   : 0  (w=2)
#  NAME  : 3  (w=18)
#  HR    : 23 (w=12)
#  SH    : 36 (w=9)
#  WA    : 46 (w=8)
#  EFF   : 55 (w=10)   note: "Efficiency" header fits, data "X.XX TH/W" = 9
#  TEMP  : 67 (w=5)
#  FAN   : 74 (w=4)
#  CCLK  : 80 (w=4)
#  MCLK  : 86 (w=5)
#  Total width: 86+5=91 ✓
#
# Footer pipe at pos 45. Left pane 0-44 (45 chars), right pane 46-90 (45 chars).

printf -v BAR_DASH '%*s' "$TW" ''; BAR_DASH="${BAR_DASH// /-}"
printf -v BAR_EQ   '%*s' "$TW" ''; BAR_EQ="${BAR_EQ// /=}"

_ttl="[ stats ]"
_lw=$(( (TW - ${#_ttl}) / 2 ))
_rw=$(( TW - ${#_ttl} - _lw ))
printf -v _L '%*s' "$_lw" ''; _L="${_L// /-}"
printf -v _R '%*s' "$_rw" ''; _R="${_R// /-}"
TOP_TITLE="${_L}${_ttl}${_R}"
unset _ttl _lw _rw _L _R

VER="1.8.3"
START_EPOCH="$(date +%s)"

# ===== Helpers ================================================================
uptime_str() {
    local up=$(( $(date +%s) - START_EPOCH ))
    if   (( up >= 86400 )); then
        printf "%dd %dh %dm %ds" $((up/86400)) $(( (up%86400)/3600 )) $(( (up%3600)/60 )) $((up%60))
    elif (( up >= 3600 )); then
        printf "%dh %dm %ds" $((up/3600)) $(( (up%3600)/60 )) $((up%60))
    elif (( up >= 60 )); then
        printf "%dm %ds" $((up/60)) $((up%60))
    else
        printf "%ds" "$up"
    fi
}

# Auto-scale: individual GPU hashrates always TH/s (or lower).
# Total uses PH/s only when >= 10000 TH/s (1e16 raw).
# All values formatted to fixed decimal width so decimal points align
# when right-justified in a %12s field:
#   "  32.34 TH/s" (10 chars → 2 leading spaces in %12s)  ← PROBLEM
# Solution: always produce exactly N chars for the number+unit so
# right-justification keeps decimals aligned.
# Format: use %6.2f for the number (always "XXX.XX" or " XX.XX" = 6 chars)
# so total = 6 + 1 space + unit(4) = 11 chars → %12s adds 1 leading space always.
fmt_hs() {
    awk -v v="$1" 'BEGIN{
        if      (v >= 1e12) printf "%6.2f TH/s", v/1e12
        else if (v >= 1e9)  printf "%6.2f GH/s", v/1e9
        else if (v >= 1e6)  printf "%6.2f MH/s", v/1e6
        else if (v >= 1e3)  printf "%6.1f kH/s", v/1e3
        else                printf "%6.0f H/s  ", v
    }'
}

fmt_hs_total() {
    awk -v v="$1" 'BEGIN{
        if      (v >= 1e16) printf "%6.2f PH/s", v/1e15
        else if (v >= 1e12) printf "%6.2f TH/s", v/1e12
        else if (v >= 1e9)  printf "%6.2f GH/s", v/1e9
        else if (v >= 1e6)  printf "%6.2f MH/s", v/1e6
        else if (v >= 1e3)  printf "%6.1f kH/s", v/1e3
        else                printf "%6.0f H/s  ", v
    }'
}

# Pool hashrate (share_equiv): scales to PH/s at >= 1000 TH/s, 2 decimals
fmt_pool_hr() {
    awk -v v="$1" 'BEGIN{
        if      (v >= 1e15) printf "%6.2f PH/s", v/1e15
        else if (v >= 1e12) printf "%6.2f TH/s", v/1e12
        else if (v >= 1e9)  printf "%6.2f GH/s", v/1e9
        else if (v >= 1e6)  printf "%6.2f MH/s", v/1e6
        else if (v >= 1e3)  printf "%6.1f kH/s", v/1e3
        else                printf "%6.0f H/s  ", v
    }'
}

fmt_eff() {
    awk -v h="$1" -v w="$2" 'BEGIN{
        if (w > 0.001) printf "%.3f TH/W", (h/1e12)/w
        else           printf "n/a"
    }'
}

fmt_ttf() {
    awk -v s="$1" 'BEGIN{
        if (s <= 0)    { printf "n/a"; exit }
        if (s < 60)    { printf "%.0f sec", s; exit }
        if (s < 3600)  { printf "%.1f min", s/60; exit }
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

# Truncate wallet: first 10 + "..." + last 6
trunc_wallet() {
    local w="$1"
    (( ${#w} <= 19 )) && printf "%s" "$w" && return
    printf "%s...%s" "${w:0:10}" "${w: -6}"
}

short_name() { sed -E 's/^NVIDIA GeForce //; s/^NVIDIA //'; }

# Print line to stdout only — tee in h-run.sh handles the log file
tprint() {
    printf '%s\n' "$1"
}

# ===== Diff per GPU from buffer ===============================================
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

GPU_NAMES=() GPU_HASH_RAW=() GPU_EQUIV_RAW=()
GPU_WATTS=() GPU_TEMP=() GPU_FAN=() GPU_CCLK=() GPU_MCLK=()
GPU_ACC=() GPU_REJ=() GPU_DIFFS=()
TOTAL_HASH_RAW=0 TOTAL_EQUIV_RAW=0 TOTAL_WATTS=0 TOTAL_ACC=0 TOTAL_REJ=0

collect_gpu_metrics() {
    GPU_NAMES=(); GPU_HASH_RAW=(); GPU_EQUIV_RAW=()
    GPU_WATTS=(); GPU_TEMP=(); GPU_FAN=(); GPU_CCLK=(); GPU_MCLK=()
    GPU_ACC=(); GPU_REJ=(); GPU_DIFFS=()
    TOTAL_HASH_RAW=0; TOTAL_EQUIV_RAW=0; TOTAL_WATTS=0; TOTAL_ACC=0; TOTAL_REJ=0

    for pos in "${!GPU_IDX_LIST[@]}"; do
        local idx="${GPU_IDX_LIST[$pos]}"
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
        # Build temp/fan strings with consistent visual width.
        # °C is 2 bytes (UTF-8) but 1 visual char. printf %-5s counts bytes,
        # so "80°C" (5 bytes) gets no padding. We pad manually to 5 visual chars:
        #   2-digit temp: "80°C " → 5 visual chars (6 bytes for printf)
        #   3-digit temp: "100°C" → 5 visual chars (6 bytes for printf)
        if [[ -n "$temp" && "$temp" =~ ^[0-9]+$ ]] && (( temp < 100 )); then
            temp="${temp}°C "
        else
            temp="${temp}°C"
        fi
        fan="${fan}%"

        mapfile -t hash_samp < <(
            tail -n "$HSTATS_RAW_LINES" "$BUFFER_FILE" 2>/dev/null \
            | grep -a "component=miner status" | grep -a " gpu=${idx}:" \
            | grep -oE '[[:space:]]hashrate_th_s=[0-9.]+' | grep -oE '[0-9.]+' \
            | awk '{printf "%.0f\n", $1*1e12}' | tail -n "$MAX_SAMPLES")
        mapfile -t equiv_samp < <(
            tail -n "$HSTATS_RAW_LINES" "$BUFFER_FILE" 2>/dev/null \
            | grep -a "component=miner status" | grep -a " gpu=${idx}:" \
            | grep -oE '[[:space:]]share_equiv_th_s=[0-9.]+' | grep -oE '[0-9.]+' \
            | awk '{printf "%.0f\n", $1*1e12}' | tail -n "$MAX_SAMPLES")

        if [[ -z "${IGNORED_ZERO[$idx]:-}" ]] && (( ${#hash_samp[@]} > 0 )) && [[ "${hash_samp[0]}" == "0" ]]; then
            hash_samp=("${hash_samp[@]:1}"); IGNORED_ZERO[$idx]=1
        fi

        local avg_hash=0 avg_equiv=0
        (( ${#hash_samp[@]}  > 0 )) && avg_hash=$(printf '%s\n'  "${hash_samp[@]}"  | awk '{s+=$1} END{printf "%.0f",s/NR}')
        (( ${#equiv_samp[@]} > 0 )) && avg_equiv=$(printf '%s\n' "${equiv_samp[@]}" | awk '{s+=$1} END{printf "%.0f",s/NR}')

        local last_stat acc=0 rej=0
        last_stat=$(tail -n "$HSTATS_RAW_LINES" "$BUFFER_FILE" 2>/dev/null \
            | grep -a "component=miner status" | grep -a " gpu=${idx}:" | tail -n1)
        [[ "$last_stat" =~ [[:space:]]accepted=([0-9]+) ]] && acc="${BASH_REMATCH[1]}"
        [[ "$last_stat" =~ [[:space:]]rejected=([0-9]+) ]] && rej="${BASH_REMATCH[1]}"

        local diff; diff="$(get_gpu_diff "$idx")"

        GPU_NAMES+=("$name"); GPU_HASH_RAW+=("$avg_hash"); GPU_EQUIV_RAW+=("$avg_equiv")
        GPU_WATTS+=("$watts"); GPU_TEMP+=("$temp"); GPU_FAN+=("$fan")
        GPU_CCLK+=("$cclk"); GPU_MCLK+=("$mclk")
        GPU_ACC+=("$acc"); GPU_REJ+=("$rej"); GPU_DIFFS+=("$diff")

        TOTAL_HASH_RAW=$(awk  -v a="$TOTAL_HASH_RAW"  -v b="$avg_hash"  'BEGIN{printf "%.0f",a+b}')
        TOTAL_EQUIV_RAW=$(awk -v a="$TOTAL_EQUIV_RAW" -v b="$avg_equiv" 'BEGIN{printf "%.0f",a+b}')
        TOTAL_WATTS=$(awk     -v a="$TOTAL_WATTS"     -v b="$watts"     'BEGIN{printf "%.1f",a+b}')
        TOTAL_ACC=$(( TOTAL_ACC + acc )); TOTAL_REJ=$(( TOTAL_REJ + rej ))
    done
}

LAST_SHARE_AGO=-1
collect_share_metrics() {
    local last_ts
    last_ts=$(tail -n "$HSTATS_RAW_LINES" "$BUFFER_FILE" 2>/dev/null \
        | grep -a "component=share accepted" | tail -n1 \
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
    local acc_line_num
    acc_line_num=$(printf '%s\n' "$recent" | grep -na "component=share accepted" | tail -n1 | cut -d: -f1)
    [[ -z "$acc_line_num" ]] && return
    local acc_line acc_ts
    acc_line=$(printf '%s\n' "$recent" | sed -n "${acc_line_num}p")
    acc_ts="${acc_line%% *}"
    local before prev_hits=0 submit_ts=""
    before=$(printf '%s\n' "$recent" | head -n "$acc_line_num")
    while IFS= read -r sline; do
        [[ "$sline" =~ "component=miner status" ]] || continue
        local cur_hits=0
        [[ "$sline" =~ [[:space:]]hits=([0-9]+) ]] && cur_hits="${BASH_REMATCH[1]}"
        (( cur_hits > prev_hits )) && submit_ts="${sline%% *}"
        prev_hits=$cur_hits
    done <<< "$before"
    [[ -z "$submit_ts" ]] && return
    _ms() {
        local ts="$1" sp="${1%.*}" frac
        frac="${ts##*.}"; frac="${frac%Z}"; frac="${frac:0:3}"
        while (( ${#frac} < 3 )); do frac="${frac}0"; done
        local ep; ep=$(date -d "${sp}Z" +%s 2>/dev/null) || ep=0
        echo $(( ep*1000 + 10#$frac ))
    }
    local sm am dm
    sm=$(_ms "$submit_ts"); am=$(_ms "$acc_ts"); dm=$(( am - sm ))
    (( dm > 0 && dm < 60000 )) && LAST_PING_MS=$dm
}

# ===== Render =================================================================
#
# Verified column positions from pearl_stats_table2.txt:
#   pos  0 : idx    %2s  (right-aligned, e.g. " 0" or "10")
#   pos  2 : space
#   pos  3 : name   %-18.18s  (left-aligned, truncated)
#   pos 21 : space+space
#   pos 23 : hr     %12s  (RIGHT-aligned so "TH/s" always lands at pos 30-33)
#   pos 35 : space
#   pos 36 : shares %-9s  (left-aligned)
#   pos 45 : space+space  (note: Watts header at pos 47)
#   pos 47 : watts  %6s  (RIGHT-aligned, no W suffix)
#   pos 53 : space+space
#   pos 55 : eff    %-10s
#   pos 65 : space+space
#   pos 67 : temp   %-5s
#   pos 72 : space+space
#   pos 74 : fan    %-4s
#   pos 78 : space+space
#   pos 80 : cclk   %-4s
#   pos 84 : space+space
#   pos 86 : mclk   %-5s   → ends at 91 ✓
#
# Footer pipe at pos 45. Left pane 0-44 (45 chars). Right pane 46-90 (45 chars).
# Footer left colon at pos 21: 8 leading spaces + 13-char right-aligned label + " : " + value
#   8 + 13 + 3 = 24... let me verify from file: "        Time to find : "
#   "        " = 8, "Time to find" = 12, " : " = 3  → colon at pos 8+12=20, value at 23
#   So label right-aligned in 12, 8 leading spaces: format "%-8s%12s : %-s" padded to 45
# Footer right pane: "       Pool : eu1.alphapool.tech:5566        "
#   7 spaces + "Pool" (4) + " : " = 14 chars before value
#   Format: "%-7s%4s : %-s" padded to 45 chars
#
GPU_ROW_FMT="%2s %-18.18s  %12s  %-10s %-6s %-10s  %s  %-4s %-5s %-5s"
HDR_ROW_FMT="%2s %-18s   %-12s %-10s %-6s %-10s %s  %-4s %-5s %-5s"

render() {
    local ts; ts="[$(date +'%H:%M:%S')]"
    local up; up="$(uptime_str)"
    local wallet_s; wallet_s="$(trunc_wallet "$WALLET")"

    # ---- Title ---------------------------------------------------------------
    tprint "${G}${B}${ts} ${TOP_TITLE}${R}"

    # ---- Header row 1: left "AlphaMiner v1.8.3", right "Uptime: X" ----------
    # Right side must fit exactly — no trailing spaces (uptime_str has none)
    local h1_left="AlphaMiner v${VER}"
    local h1_right="Uptime: ${up}"
    local h1_gap=$(( TW - ${#h1_left} - ${#h1_right} ))
    (( h1_gap < 1 )) && h1_gap=1
    printf -v _h1 "%s%*s%s" "$h1_left" "$h1_gap" '' "$h1_right"
    tprint "${G}${ts} ${_h1}${R}"

    # ---- Header row 2: left "PEARL / AlphaPool", right "Address: ..." -------
    local h2_left="PEARL / AlphaPool"
    local h2_right="Address: ${wallet_s}"
    local h2_gap=$(( TW - ${#h2_left} - ${#h2_right} ))
    (( h2_gap < 1 )) && h2_gap=1
    printf -v _h2 "%s%*s%s" "$h2_left" "$h2_gap" '' "$h2_right"
    tprint "${G}${ts} ${_h2}${R}"

    tprint "${G}${ts} ${BAR_DASH}${R}"

    # ---- Column header -------------------------------------------------------
    local hdr_line
    printf -v hdr_line "$HDR_ROW_FMT" \
        "#" "GPU Name" "Hashrate" "Shares" "Watts" "Efficiency" "Temp" "Fan" "CClk" "MClk"
    tprint "${G}${ts} ${hdr_line}${R}"
    tprint "${G}${ts} ${BAR_EQ}${R}"

    # ---- Per-GPU rows --------------------------------------------------------
    local i
    for i in "${!GPU_IDX_LIST[@]}"; do
        local idx="${GPU_IDX_LIST[$i]}"
        local hr;    hr="$(fmt_hs  "${GPU_HASH_RAW[$i]}")"
        local eff;   eff="$(fmt_eff "${GPU_HASH_RAW[$i]}" "${GPU_WATTS[$i]}")"
        local shares="${GPU_ACC[$i]:-0}/${GPU_REJ[$i]:-0}"
        local row
        printf -v row "$GPU_ROW_FMT" \
            "$idx" "${GPU_NAMES[$i]}" \
            "$hr" "$shares" "${GPU_WATTS[$i]}" "$eff" \
            "${GPU_TEMP[$i]}" "${GPU_FAN[$i]}" \
            "${GPU_CCLK[$i]}" "${GPU_MCLK[$i]}"
        tprint "${G}${ts} ${row}${R}"
    done

    # ---- Total row -----------------------------------------------------------
    local total_hr;  total_hr="$(fmt_hs_total "$TOTAL_HASH_RAW")"
    local total_eff; total_eff="$(fmt_eff "$TOTAL_HASH_RAW" "$TOTAL_WATTS")"
    local total_sh="${TOTAL_ACC}/${TOTAL_REJ}"
    local total_row
    printf -v total_row "   %-18s  %12s  %-10s %-6s %-10s" \
        "Total" "$total_hr" "$total_sh" "$TOTAL_WATTS" "$total_eff"
    tprint "${G}${ts} ${total_row}${R}"

    tprint "${G}${ts} ${BAR_DASH}${R}"

    # ---- Footer --------------------------------------------------------------
    # Pipe at pos 45. Left pane = 45 chars. Right pane = 45 chars.
    local LPANE=45 RPANE=45

    # Section titles: "Share Metrics" (13 chars) centered in 45 → pad 16 each side
    # "Pool Info" (9 chars) centered in 45 → pad 18 each side
    local ltitle="Share Metrics" rtitle="Pool Info"
    local lpad=$(( (LPANE - ${#ltitle}) / 2 ))
    local lrpad=$(( LPANE - ${#ltitle} - lpad ))
    local rpad=$(( (RPANE - ${#rtitle}) / 2 ))
    local rrpad=$(( RPANE - ${#rtitle} - rpad ))
    printf -v _ltitle '%*s%s%*s' "$lpad"  '' "$ltitle" "$lrpad"  ''
    printf -v _rtitle '%*s%s%*s' "$rpad"  '' "$rtitle" "$rrpad"  ''
    tprint "${G}${ts} ${_ltitle}|${_rtitle}${R}"
    tprint "${G}${ts} ${BAR_EQ}${R}"

    # Footer content rows.
    # Left pane (45 chars):
    #   8 leading spaces + label right-aligned in 12 + " : " + value left-padded to fill rest
    #   8 + 12 + 3 = 23 chars before value → value has 45-23=22 chars
    #   Format: printf "%-8s%12s : %-22s"  → 8+12+3+22=45 ✓
    # Right pane (45 chars):
    #   7 leading spaces + label right-aligned in 4 + " : " + value left-padded to fill rest
    #   7 + 4 + 3 = 14 chars before value → value has 45-14=31 chars
    #   Format: printf "%-7s%4s : %-31s"  → 7+4+3+31=45 ✓

    # Compute TTF
    local diff_0="${GPU_DIFFS[0]:-524288}"
    [[ "$diff_0" == "?" ]] && diff_0=524288
    local ttf_str="n/a" ttf_secs=0
    if (( TOTAL_HASH_RAW > 0 )); then
        ttf_secs=$(awk -v d="$diff_0" -v rate="$POOL_RATE_DIVISOR" -v h="$TOTAL_HASH_RAW" \
            'BEGIN{printf "%.0f", d / ((h/1e12) * rate)}')
        ttf_str="$(fmt_ttf "$ttf_secs")"
    fi

    # Last found + alert if > 2x or 3x TTF
    local last_str; last_str="$(fmt_ago "$LAST_SHARE_AGO")"
    if (( ttf_secs > 0 && LAST_SHARE_AGO > 0 )); then
        (( LAST_SHARE_AGO >= ttf_secs * 3 )) && last_str="${last_str} !!!"
        (( LAST_SHARE_AGO >= ttf_secs * 2 && LAST_SHARE_AGO < ttf_secs * 3 )) && last_str="${last_str} !"
    fi

    local pool_hr;   pool_hr="$(fmt_pool_hr "$TOTAL_EQUIV_RAW")"
    local ping_str="n/a"
    (( LAST_PING_MS > 0 )) && ping_str="${LAST_PING_MS} ms"
    local pool_disp="${POOL_HOST#stratum+tcp://}"

    _frow() {
        local ll="$1" lv="$2" rl="$3" rv="$4"
        local lc rc
        # Left pane (45 chars): 8 leading spaces + label right-aligned in 13 + " : " + value in 21
        # 8 + 13 + 3 + 21 = 45 ✓
        # "Pool hashrate" = 13 chars → exactly fills label field
        printf -v lc '%8s%13s : %-21s' '' "$ll" "$lv"
        printf -v rc '%7s%4s : %-31s'  '' "$rl" "$rv"
        tprint "${G}${ts} ${lc}|${rc}${R}"
    }

    _frow "Time to find" "$ttf_str"   "Pool" "$pool_disp"
    _frow "Last found"   "$last_str"  "Ping" "$ping_str"
    _frow "Pool hashrate" "$pool_hr"   "Algo" "pearlhash"

    tprint "${G}${ts} ${BAR_DASH}${R}"
}

# ===== Main loop ==============================================================
while [[ ! -f "$BUFFER_FILE" ]]; do sleep 2; done
while ! grep -qa "component=miner status" "$BUFFER_FILE" 2>/dev/null; do sleep 2; done

while true; do
    sleep "$STATS_INTERVAL"
    collect_gpu_metrics
    collect_share_metrics
    collect_ping
    render
done
