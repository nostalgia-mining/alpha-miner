#!/usr/bin/env bash
#
# alpha-events.sh -- real-time event printer for alpha-wrapper
#
# Tails the rolling buffer and pretty-prints:
#   - Pool connection events
#   - Difficulty set
#   - New job (block change, from DEBUG lines)
#   - Share accepted (with ping derived from hits-increment timestamp)
#   - Share rejected
#
# All output goes to stdout (screen) AND is tee'd to LOG_FILE.
#
# Env vars:
#   BUFFER_FILE   /run/alpha-wrapper/miner-raw.buf
#   LOG_FILE      /var/log/miner/custom/alpha-wrapper.log
#   GPU_LIST      comma-separated active CUDA indices
set -u

BUFFER_FILE="${BUFFER_FILE:-/run/alpha-wrapper/miner-raw.buf}"
LOG_FILE="${LOG_FILE:-/var/log/miner/custom/alpha-wrapper.log}"
GPU_LIST="${GPU_LIST:-0}"

# ===== Colors =================================================================
G=$'\e[32m'   # green
Y=$'\e[33m'   # yellow
C=$'\e[36m'   # cyan
R=$'\e[0m'    # reset
RD=$'\e[31m'  # red
W=$'\e[97m'   # bright white
B=$'\e[1m'    # bold

# Helper: print a line to both stdout and log
log_print() { printf '%s\n' "$1" | tee -a "$LOG_FILE"; }

# ===== State per GPU ==========================================================
# hits count and its timestamp (to compute ping)
declare -A LAST_HITS_COUNT=()
declare -A LAST_HITS_TS_MS=()
# running share counters (these stay in sync with accepted/rejected from log)
declare -A GPU_ACC=()
declare -A GPU_REJ=()
# per-GPU difficulty (set from pool job DEBUG lines)
declare -A GPU_DIFF=()
LAST_JOB_ID=""

# ===== Timestamp -> milliseconds ==============================================
ts_to_ms() {
    local ts="$1"
    # Format: 2026-06-24T09:03:27.027Z
    local sec_part="${ts%.*}"     # 2026-06-24T09:03:27
    local frac="${ts##*.}"        # 027Z
    frac="${frac%Z}"              # 027
    frac="${frac:0:3}"            # ensure 3 digits
    while (( ${#frac} < 3 )); do frac="${frac}0"; done
    local epoch_s
    epoch_s=$(date -d "${sec_part}Z" +%s 2>/dev/null) || epoch_s=0
    echo $(( epoch_s * 1000 + 10#$frac ))
}

# ===== Wait for buffer ========================================================
while [[ ! -f "$BUFFER_FILE" ]]; do sleep 1; done

# ===== Main tail loop =========================================================
tail -F "$BUFFER_FILE" 2>/dev/null | while IFS= read -r line; do

    [[ -z "$line" ]] && continue

    # --- Extract fields -------------------------------------------------------
    ts="${line%% *}"

    # gpu index: gpu=0:Name  or  gpu=system
    gpu_raw=""
    [[ "$line" =~ [[:space:]]gpu=([^[:space:]]+) ]] && gpu_raw="${BASH_REMATCH[1]}"
    gpu_idx="${gpu_raw%%:*}"
    [[ "$gpu_idx" == "system" || -z "$gpu_idx" ]] && gpu_idx="0"

    component=""
    [[ "$line" =~ [[:space:]]component=([^[:space:]]+) ]] && component="${BASH_REMATCH[1]}"

    hhmm="$(date +'%H:%M:%S')"

    # =========================================================================
    # POOL EVENTS
    # =========================================================================
    if [[ "$component" == "pool" ]]; then

        # Connected
        if [[ "$line" =~ [[:space:]]connected[[:space:]] && "$line" =~ host= ]]; then
            host="" ; port=""
            [[ "$line" =~ [[:space:]]host=([^[:space:]]+) ]] && host="${BASH_REMATCH[1]}"
            [[ "$line" =~ [[:space:]]port=([^[:space:]]+) ]] && port="${BASH_REMATCH[1]}"
            log_print "${G}[${hhmm}] Pool connected          ${host}:${port}${R}"

        # Disconnected / error
        elif [[ "$line" =~ "disconnected" ]]; then
            log_print "${RD}[${hhmm}] Pool disconnected${R}"

        # Difficulty set
        elif [[ "$line" =~ "difficulty_set" ]]; then
            diff="" ; [[ "$line" =~ [[:space:]]difficulty=([0-9.]+) ]] && diff="${BASH_REMATCH[1]}"
            diff="${diff%.00}"
            log_print "${Y}[${hhmm}] Difficulty set           ${diff}${R}"

        # New job (DEBUG line: component=pool job id=... generation=... difficulty=...)
        elif [[ "$line" =~ [[:space:]]"job "[[:space:]] ]] || [[ "$line" =~ [[:space:]]job[[:space:]]id= ]]; then
            job_id="" ; gen="" ; diff=""
            [[ "$line" =~ [[:space:]]id=([^[:space:]]+) ]]         && job_id="${BASH_REMATCH[1]}"
            [[ "$line" =~ [[:space:]]generation=([^[:space:]]+) ]]  && gen="${BASH_REMATCH[1]}"
            [[ "$line" =~ [[:space:]]difficulty=([0-9.]+) ]]        && diff="${BASH_REMATCH[1]}"
            diff="${diff%.00}"

            # Store difficulty for this GPU
            [[ -n "$diff" ]] && GPU_DIFF[$gpu_idx]="$diff"

            if [[ -n "$job_id" && "$job_id" != "$LAST_JOB_ID" ]]; then
                LAST_JOB_ID="$job_id"
                # Show short job id: first 8 chars + last 8 chars
                local_short="${job_id:0:8}...${job_id: -8}"
                log_print "${W}${B}[${hhmm}] New job               id=${local_short}  gen=${gen}  diff=${diff}${R}"
            fi
        fi

    # =========================================================================
    # MINER STATUS -- track hits increment for ping calculation
    # =========================================================================
    elif [[ "$component" == "miner" ]] && [[ "$line" =~ [[:space:]]"status"[[:space:]] ]]; then
        hits=0
        [[ "$line" =~ [[:space:]]hits=([0-9]+) ]] && hits="${BASH_REMATCH[1]}"
        prev="${LAST_HITS_COUNT[$gpu_idx]:-0}"
        if (( hits > prev )); then
            LAST_HITS_TS_MS[$gpu_idx]="$(ts_to_ms "$ts")"
            LAST_HITS_COUNT[$gpu_idx]="$hits"
        fi

    # =========================================================================
    # SHARE ACCEPTED
    # =========================================================================
    elif [[ "$component" == "share" ]] && [[ "$line" =~ "accepted" ]]; then
        job_id=""
        [[ "$line" =~ [[:space:]]job=([^[:space:]]+) ]] && job_id="${BASH_REMATCH[1]}"

        # Ping
        ping_ms=0
        accepted_ms="$(ts_to_ms "$ts")"
        if [[ -n "${LAST_HITS_TS_MS[$gpu_idx]:-}" ]]; then
            ping_ms=$(( accepted_ms - LAST_HITS_TS_MS[$gpu_idx] ))
            (( ping_ms < 0 || ping_ms > 60000 )) && ping_ms=0
        fi

        GPU_ACC[$gpu_idx]=$(( ${GPU_ACC[$gpu_idx]:-0} + 1 ))
        acc="${GPU_ACC[$gpu_idx]}"
        rej="${GPU_REJ[$gpu_idx]:-0}"
        diff="${GPU_DIFF[$gpu_idx]:-?}"
        short_job="${job_id:0:8}"

        if (( ping_ms > 0 )); then
            ping_str="$(printf '%d ms' "$ping_ms")"
        else
            ping_str="n/a"
        fi

        log_print "${G}[${hhmm}] GPU ${gpu_idx} Share accepted   ping=${ping_str}   diff=${diff}   job=${short_job}   [${acc}/${rej}]${R}"

    # =========================================================================
    # SHARE REJECTED
    # =========================================================================
    elif [[ "$component" == "share" ]] && [[ "$line" =~ "rejected" ]]; then
        GPU_REJ[$gpu_idx]=$(( ${GPU_REJ[$gpu_idx]:-0} + 1 ))
        acc="${GPU_ACC[$gpu_idx]:-0}"
        rej="${GPU_REJ[$gpu_idx]}"
        diff="${GPU_DIFF[$gpu_idx]:-?}"

        log_print "${RD}[${hhmm}] GPU ${gpu_idx} Share REJECTED              diff=${diff}              [${acc}/${rej}]${R}"

    fi

done
