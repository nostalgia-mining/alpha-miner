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
MDL_WALLET="${MDL_WALLET:-}"

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

VER="unknown"
START_EPOCH="$(date +%s)"
START_FROM_JOB=0  # flag: have we anchored uptime to first job yet

# Read runtime version (written by supervisor from first miner status line)
_ver_file="${BUFFER_DIR:-/run/alpha-wrapper}/miner-version"
_ver_wait=0
while [[ ! -f "$_ver_file" ]] && (( _ver_wait < 30 )); do sleep 0.5; (( _ver_wait++ )); done
[[ -f "$_ver_file" ]] && VER=$(cat "$_ver_file")

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
        if (s < 60)    { printf "%.1f sec", s; exit }
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
    # Use cached buffer content if available
    local val
    val=$(printf '%s\n' "$_BUF_CACHE" 2>/dev/null \
          | grep -a "component=pool" \
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
CURRENT_POOL="${POOL_HOST#stratum+tcp://}"
CURRENT_JOB=""
CURRENT_JOB_GEN=""

collect_gpu_metrics() {
    GPU_NAMES=(); GPU_HASH_RAW=(); GPU_EQUIV_RAW=()
    GPU_WATTS=(); GPU_TEMP=(); GPU_FAN=(); GPU_CCLK=(); GPU_MCLK=()
    GPU_ACC=(); GPU_REJ=(); GPU_DIFFS=()
    TOTAL_HASH_RAW=0; TOTAL_EQUIV_RAW=0; TOTAL_WATTS=0; TOTAL_ACC=0; TOTAL_REJ=0

    # Cache buffer content once for all GPUs (avoids repeated tail+grep)
    _BUF_CACHE=$(tail -n "$HSTATS_RAW_LINES" "$BUFFER_FILE" 2>/dev/null)

    # Anchor uptime to first job (generation=1) once per session
    if (( START_FROM_JOB == 0 )); then
        local first_job_ts
        first_job_ts=$(printf '%s\n' "$_BUF_CACHE" \
            | grep -aE 'component=pool.*generation=1[^0-9]' \
            | head -1 \
            | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}')
        if [[ -n "$first_job_ts" ]]; then
            local job_epoch
            job_epoch=$(date -d "${first_job_ts}Z" +%s 2>/dev/null) || true
            if [[ -n "$job_epoch" && "$job_epoch" =~ ^[0-9]+$ ]]; then
                START_EPOCH="$job_epoch"
                START_FROM_JOB=1
            fi
        fi
    fi

    # Detect current pool from latest "connected" event in buffer
    local conn_line
    conn_line=$(printf '%s\n' "$_BUF_CACHE" | grep -a "component=pool connected" | tail -n1)
    if [[ -n "$conn_line" ]]; then
        local _h="" _p=""
        [[ "$conn_line" =~ [[:space:]]host=([^[:space:]]+) ]] && _h="${BASH_REMATCH[1]}"
        [[ "$conn_line" =~ [[:space:]]port=([^[:space:]]+) ]] && _p="${BASH_REMATCH[1]}"
        [[ -n "$_h" ]] && CURRENT_POOL="${_h}:${_p}"
    fi

    # Detect current job ID and generation from latest job line
    local job_line
    job_line=$(printf '%s\n' "$_BUF_CACHE" | grep -a "component=pool" | grep -a " job " | tail -n1)
    if [[ -n "$job_line" ]]; then
        [[ "$job_line" =~ [[:space:]]id=([^[:space:]]+) ]] && CURRENT_JOB="${BASH_REMATCH[1]%%:*}"
        [[ "$job_line" =~ [[:space:]]generation=([^[:space:]]+) ]] && CURRENT_JOB_GEN="${BASH_REMATCH[1]}"
    fi

    for pos in "${!GPU_IDX_LIST[@]}"; do
        local idx="${GPU_IDX_LIST[$pos]}"

        # Single nvidia-smi call per GPU — all metrics at once
        local nvsmi_line
        nvsmi_line=$(nvidia-smi -i "$idx" --query-gpu=name,temperature.gpu,fan.speed,clocks.sm,clocks.mem,power.draw --format=csv,noheader,nounits 2>/dev/null)
        local name temp fan cclk mclk watts
        IFS=',' read -r name temp fan cclk mclk watts <<< "$nvsmi_line"
        # Trim whitespace
        name="${name## }"; name="${name%% }"; name=$(echo "$name" | short_name)
        temp="${temp## }"; temp="${temp%% }"
        fan="${fan## }";   fan="${fan%% }"
        cclk="${cclk## }"; cclk="${cclk%% }"
        mclk="${mclk## }"; mclk="${mclk%% }"
        watts="${watts## }"; watts="${watts%% }"

        [[ -z "$name"  ]] && name="n/a"
        [[ -z "$temp"  ]] && temp="n/a"
        [[ -z "$fan"   ]] && fan="n/a"
        [[ -z "$cclk"  ]] && cclk="n/a"
        [[ -z "$mclk"  ]] && mclk="n/a"
        [[ -z "$watts" || "$watts" == "N/A" ]] && watts=0
        watts=$(awk -v w="$watts" 'BEGIN{printf "%.1f", w+0}')

        if [[ -n "$temp" && "$temp" =~ ^[0-9]+$ ]] && (( temp < 100 )); then
            temp="${temp}°C "
        else
            temp="${temp}°C"
        fi
        fan="${fan}%"

        # Filter status lines for this GPU from cached buffer (single pass)
        local gpu_status
        gpu_status=$(printf '%s\n' "$_BUF_CACHE" | grep -a "component=miner status" | grep -a " gpu=${idx}:")

        mapfile -t hash_samp < <(printf '%s\n' "$gpu_status" \
            | grep -oE '[[:space:]]hashrate_th_s=[0-9.]+' | grep -oE '[0-9.]+' \
            | awk '{printf "%.0f\n", $1*1e12}' | tail -n "$MAX_SAMPLES")
        mapfile -t equiv_samp < <(printf '%s\n' "$gpu_status" \
            | grep -oE '[[:space:]]share_equiv_th_s=[0-9.]+' | grep -oE '[0-9.]+' \
            | awk '{printf "%.0f\n", $1*1e12}' | tail -n "$MAX_SAMPLES")

        if [[ -z "${IGNORED_ZERO[$idx]:-}" ]] && (( ${#hash_samp[@]} > 0 )) && [[ "${hash_samp[0]}" == "0" ]]; then
            hash_samp=("${hash_samp[@]:1}"); IGNORED_ZERO[$idx]=1
        fi

        local avg_hash=0 avg_equiv=0
        (( ${#hash_samp[@]}  > 0 )) && avg_hash=$(printf '%s\n'  "${hash_samp[@]}"  | awk '{s+=$1} END{printf "%.0f",s/NR}')
        (( ${#equiv_samp[@]} > 0 )) && avg_equiv=$(printf '%s\n' "${equiv_samp[@]}" | awk '{s+=$1} END{printf "%.0f",s/NR}')

        local last_stat acc=0 rej=0
        last_stat=$(printf '%s\n' "$gpu_status" | tail -n1)
        [[ "$last_stat" =~ [[:space:]]accepted=([0-9]+) ]] && acc="${BASH_REMATCH[1]}"
        [[ "$last_stat" =~ [[:space:]]rejected=([0-9]+) ]] && rej="${BASH_REMATCH[1]}"
        local drop=0
        [[ "$last_stat" =~ [[:space:]]dropped=([0-9]+) ]] && drop="${BASH_REMATCH[1]}"
        rej=$(( rej + drop ))

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
    last_ts=$(printf '%s\n' "$_BUF_CACHE" \
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
    # Real TCP ping to pool host:port via /dev/tcp (always available in bash).
    # Measures TCP connect time = network round-trip latency.
    LAST_PING_MS=0
    local host="$CURRENT_POOL"
    local pool_h="${host%%:*}"
    local pool_p="${host##*:}"
    [[ -z "$pool_h" || -z "$pool_p" ]] && return

    # Timeout of 3 seconds to avoid blocking the stats loop
    local start_ms end_ms
    start_ms=$(date +%s%3N)
    if timeout 3 bash -c "exec 3<>/dev/tcp/${pool_h}/${pool_p}" 2>/dev/null; then
        end_ms=$(date +%s%3N)
        LAST_PING_MS=$(( end_ms - start_ms ))
        (( LAST_PING_MS <= 0 || LAST_PING_MS > 10000 )) && LAST_PING_MS=0
    fi
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
GPU_ROW_FMT="%2s %-17.17s  %12s  %-9s %6s   %-10s  %-5s  %-4s  %-4s  %-5s"
HDR_ROW_FMT="%2s %-17s   %-12s %-9s  %-6s  %-10s  %-5s  %-4s  %-4s  %-5s"

render() {
    local ts; ts="[$(date +'%Y-%m-%d %H:%M:%S')]"
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

    # ---- Header row 2: left "AlphaPool PEARL (pearlhash)", right "Wallet: ..." -------
    local h2_left="AlphaPool PEARL (pearlhash)"
    local h2_right="Wallet: ${wallet_s}"
    local h2_gap=$(( TW - ${#h2_left} - ${#h2_right} ))
    (( h2_gap < 1 )) && h2_gap=1
    printf -v _h2 "%s%*s%s" "$h2_left" "$h2_gap" '' "$h2_right"
    tprint "${G}${ts} ${_h2}${R}"

    # ---- Header row 3 (optional): merged mining MDL -------------------------
    if [[ -n "$MDL_WALLET" ]]; then
        local mdl_s; mdl_s="$(trunc_wallet "$MDL_WALLET")"
        local h3_left="Merged mining: MDL (auxpow)"
        local h3_right="MDL Wallet: ${mdl_s}"
        local h3_gap=$(( TW - ${#h3_left} - ${#h3_right} ))
        (( h3_gap < 1 )) && h3_gap=1
        printf -v _h3 "%s%*s%s" "$h3_left" "$h3_gap" '' "$h3_right"
        tprint "${G}${ts} ${_h3}${R}"
    fi

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
    printf -v total_row "   %-17s  %12s  %-9s %6s   %-10s" \
        "Total" "$total_hr" "$total_sh" "$TOTAL_WATTS" "$total_eff"
    tprint "${G}${ts} ${total_row}${R}"

    tprint "${G}${ts} ${BAR_DASH}${R}"

    # ---- Footer --------------------------------------------------------------
    # Pipe at pos 45. Left pane = 45 chars. Right pane = 45 chars (pipe excluded).
    local LPANE=45 RPANE=45

    # Section titles (no pipe between them)
    local ltitle="Share Metrics" rtitle="Pool Info"
    local lpad=$(( (LPANE - ${#ltitle}) / 2 ))
    local lrpad=$(( LPANE - ${#ltitle} - lpad ))
    local rpad=$(( (RPANE - ${#rtitle}) / 2 ))
    local rrpad=$(( RPANE - ${#rtitle} - rpad ))
    printf -v _ltitle '%*s%s%*s' "$lpad"  '' "$ltitle" "$lrpad"  ''
    printf -v _rtitle '%*s%s%*s' "$rpad"  '' "$rtitle" "$rrpad"  ''
    tprint "${G}${ts} ${_ltitle} ${_rtitle}${R}"
    tprint "${G}${ts} ${BAR_EQ}${R}"

    # Compute TTF (combined rate across all GPUs, handles mixed difficulties)
    # TTF_total = 1 / (sum of 1/TTF_i for each GPU)
    # Where TTF_i = diff_i / (hashrate_i_TH × POOL_RATE_DIVISOR)
    # For vardiff: uses the CURRENT difficulty per GPU (updates each new job)
    local ttf_str="n/a" ttf_secs=0
    if (( TOTAL_HASH_RAW > 0 )); then
        local _diffs="" _hashes=""
        for i in "${!GPU_IDX_LIST[@]}"; do
            local d="${GPU_DIFFS[$i]:-524288}"
            [[ "$d" == "?" ]] && d=524288
            _diffs="${_diffs} $d"
            _hashes="${_hashes} ${GPU_HASH_RAW[$i]}"
        done
        ttf_secs=$(awk -v diffs="$_diffs" -v hashes="$_hashes" -v rate="$POOL_RATE_DIVISOR" \
            'BEGIN{
                n = split(diffs, d); split(hashes, h)
                sum_rate = 0
                for (i=1; i<=n; i++) {
                    hr_th = h[i] / 1e12
                    if (hr_th > 0 && d[i] > 0)
                        sum_rate += (hr_th * rate) / d[i]
                }
                if (sum_rate > 0) printf "%.1f", 1.0 / sum_rate
                else printf "0"
            }')
        ttf_str="$(fmt_ttf "$ttf_secs")"
    fi

    # Avg between shares = uptime / total_accepted + alert thresholds
    local avg_str="n/a"
    local uptime_now=$(( $(date +%s) - START_EPOCH ))
    if (( TOTAL_ACC > 0 )); then
        local avg_secs=$(awk -v u="$uptime_now" -v n="$TOTAL_ACC" 'BEGIN{printf "%.1f", u/n}')
        avg_str="$(fmt_ttf "$avg_secs")"
        # Alert: > TTF*1.5 → (!), > TTF*2 → (!!)
        local ttf_int=${ttf_secs%.*}
        if (( ttf_int > 0 )); then
            local avg_int=${avg_secs%.*}
            local thresh_warn=$(( ttf_int * 3 / 2 ))   # 1.5x
            local thresh_crit=$(( ttf_int * 2 ))        # 2x
            (( avg_int >= thresh_crit )) && avg_str="${avg_str}  (!!)"
            (( avg_int >= thresh_warn && avg_int < thresh_crit )) && avg_str="${avg_str}  (!)"
        fi
    fi

    local pool_hr; pool_hr="$(fmt_pool_hr "$TOTAL_EQUIV_RAW" | sed 's/^ *//')"
    local ping_str="n/a"
    (( LAST_PING_MS > 0 )) && ping_str="${LAST_PING_MS} ms"
    local pool_disp="$CURRENT_POOL"
    local job_disp="n/a"
    [[ -n "$CURRENT_JOB" ]] && job_disp="${CURRENT_JOB:0:8} [${CURRENT_JOB_GEN:-?}]"

    _frow() {
        local ll="$1" lv="$2" rl="$3" rv="$4"
        local lc rc
        # Left pane (45 chars): 21 label + " : " + 21 value = 45
        printf -v lc '%21s : %-21s' "$ll" "$lv"
        # Right pane (45 chars): 13 label + " : " + 29 value = 45
        printf -v rc '%13s : %-29s' "$rl" "$rv"
        tprint "${G}${ts} ${lc}|${rc}${R}"
    }

    _frow "Theoretical TTF" "$ttf_str"   "Stratum" "$pool_disp"
    _frow "Avg. between shares" "$avg_str"  "Ping" "$ping_str"
    _frow "Pool hashrate" "$pool_hr"   "Job" "$job_disp"

    tprint "${G}${ts} ${BAR_DASH}${R}"
}

# ===== Main loop ==============================================================
while [[ ! -f "$BUFFER_FILE" ]]; do sleep 2; done
while ! grep -qa "component=miner status" "$BUFFER_FILE" 2>/dev/null; do sleep 2; done

while true; do
    sleep $(( STATS_INTERVAL - 4 ))   # wait most of the interval
    collect_ping                       # TCP ping (up to 3 sec timeout)
    sleep 1                            # buffer before render
    collect_gpu_metrics
    collect_share_metrics
    render
done
