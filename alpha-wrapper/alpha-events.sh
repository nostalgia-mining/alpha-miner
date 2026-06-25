#!/usr/bin/env bash
#
# alpha-events.sh -- real-time event printer for alpha-wrapper
#
# Reads only NEW lines from the rolling buffer (from current EOF at launch time)
# so miner restarts never replay old events or inflate counters.
#
# Env vars:
#   BUFFER_FILE   /run/alpha-wrapper/miner-raw.buf
#   LOG_FILE      /var/log/miner/custom/alpha-wrapper.log (written by h-run.sh tee)
#   GPU_LIST      comma-separated active CUDA indices
set -u

BUFFER_FILE="${BUFFER_FILE:-/run/alpha-wrapper/miner-raw.buf}"
LOG_FILE="${LOG_FILE:-/var/log/miner/custom/alpha-wrapper.log}"
GPU_LIST="${GPU_LIST:-0}"

# ===== Colors =================================================================
G=$'\e[32m'   # green
Y=$'\e[33m'   # yellow
R=$'\e[0m'    # reset
RD=$'\e[31m'  # red
W=$'\e[97m'   # bright white
B=$'\e[1m'    # bold

# Helper: print to stdout and append (ANSI-stripped) to log
log_print() {
    local line="$1"
    printf '%s\n' "$line"
    printf '%s\n' "$line" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

# ===== State per GPU ==========================================================
declare -A LAST_HITS_COUNT=()
declare -A LAST_HITS_TS_MS=()
declare -A GPU_DIFF=()
LAST_JOB_ID=""
LAST_POOL_HOST=""    # track reconnects
SESSION_START=$(date +%s)

# ===== Timestamp -> milliseconds ==============================================
ts_to_ms() {
    local ts="$1"
    local sec_part="${ts%.*}"
    local frac="${ts##*.}"; frac="${frac%Z}"; frac="${frac:0:3}"
    while (( ${#frac} < 3 )); do frac="${frac}0"; done
    local ep; ep=$(date -d "${sec_part}Z" +%s 2>/dev/null) || ep=0
    echo $(( ep * 1000 + 10#$frac ))
}

# ===== Wait for buffer and start from current EOF ============================
while [[ ! -f "$BUFFER_FILE" ]]; do sleep 1; done

# Record current size — only process lines written AFTER this point.
# This prevents replaying old buffer content on miner restart.
START_OFFSET=$(wc -c < "$BUFFER_FILE" 2>/dev/null || echo 0)

# ===== Main tail loop =========================================================
# tail -c +N starts reading from byte N (1-indexed), so +$(START_OFFSET+1)
# skips everything before our start point.
tail -c "+$(( START_OFFSET + 1 ))" -f "$BUFFER_FILE" 2>/dev/null \
| while IFS= read -r line; do

    [[ -z "$line" ]] && continue

    # Extract timestamp
    ts="${line%% *}"

    # Extract gpu index: gpu=0:Name  or  gpu=system
    gpu_raw=""
    [[ "$line" =~ [[:space:]]gpu=([^[:space:]]+) ]] && gpu_raw="${BASH_REMATCH[1]}"
    gpu_idx="${gpu_raw%%:*}"
    [[ "$gpu_idx" == "system" || -z "$gpu_idx" ]] && gpu_idx="0"

    # Extract component
    component=""
    [[ "$line" =~ [[:space:]]component=([^[:space:]]+) ]] && component="${BASH_REMATCH[1]}"

    hhmm="$(date +'%H:%M:%S')"

    # =========================================================================
    # POOL EVENTS
    # =========================================================================
    if [[ "$component" == "pool" ]]; then

        # Connected — detect reconnect vs first connect
        if [[ "$line" =~ [[:space:]]connected[[:space:]] && "$line" =~ host= ]]; then
            host="" ; port=""
            [[ "$line" =~ [[:space:]]host=([^[:space:]]+) ]] && host="${BASH_REMATCH[1]}"
            [[ "$line" =~ [[:space:]]port=([^[:space:]]+) ]] && port="${BASH_REMATCH[1]}"
            cur_pool="${host}:${port}"

            if [[ -n "$LAST_POOL_HOST" && "$LAST_POOL_HOST" != "$cur_pool" ]]; then
                # Switched to a different pool (failover)
                log_print "${Y}${B}[${hhmm}] ===== POOL FAILOVER: ${LAST_POOL_HOST} -> ${cur_pool} =====${R}"
            elif [[ -n "$LAST_POOL_HOST" ]]; then
                # Reconnect to same pool
                log_print "${Y}${B}[${hhmm}] ===== POOL RECONNECT: ${cur_pool} =====${R}"
            fi
            LAST_POOL_HOST="$cur_pool"
            log_print "${G}[${hhmm}] Pool connected          ${cur_pool}${R}"

        # Disconnected
        elif [[ "$line" =~ "disconnected" ]]; then
            log_print "${RD}[${hhmm}] Pool disconnected${R}"

        # Difficulty set
        elif [[ "$line" =~ "difficulty_set" ]]; then
            diff=""
            [[ "$line" =~ [[:space:]]difficulty=([0-9.]+) ]] && diff="${BASH_REMATCH[1]}"
            diff="${diff%.00}"
            log_print "${Y}[${hhmm}] Difficulty set           ${diff}${R}"

        # New job (DEBUG: component=pool job ...)
        elif [[ "$line" =~ [[:space:]]"job "[[:space:]] ]] || [[ "$line" =~ [[:space:]]job[[:space:]]id= ]]; then
            job_id="" ; gen="" ; diff=""
            [[ "$line" =~ [[:space:]]id=([^[:space:]]+) ]]        && job_id="${BASH_REMATCH[1]}"
            [[ "$line" =~ [[:space:]]generation=([^[:space:]]+) ]] && gen="${BASH_REMATCH[1]}"
            [[ "$line" =~ [[:space:]]difficulty=([0-9.]+) ]]       && diff="${BASH_REMATCH[1]}"
            diff="${diff%.00}"
            [[ -n "$diff" ]] && GPU_DIFF[$gpu_idx]="$diff"

            if [[ -n "$job_id" && "$job_id" != "$LAST_JOB_ID" ]]; then
                LAST_JOB_ID="$job_id"
                local_short="${job_id:0:8}...${job_id: -8}"
                log_print "${W}${B}[${hhmm}] New job               id=${local_short}  gen=${gen}  diff=${diff}${R}"
            fi
        fi

    # =========================================================================
    # MINER STATUS — track hits increment for ping
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

        # Ping from hits-increment timestamp
        ping_ms=0
        accepted_ms="$(ts_to_ms "$ts")"
        if [[ -n "${LAST_HITS_TS_MS[$gpu_idx]:-}" ]]; then
            ping_ms=$(( accepted_ms - LAST_HITS_TS_MS[$gpu_idx] ))
            (( ping_ms < 0 || ping_ms > 60000 )) && ping_ms=0
        fi

        # Get acc/rej from the miner's own counter (latest status line) — stays
        # accurate across restarts because we read the miner's value, not ours.
        local_acc=0 ; local_rej=0
        last_stat=$(grep -a "component=miner status" "$BUFFER_FILE" 2>/dev/null \
            | grep " gpu=${gpu_idx}:" | tail -n1)
        [[ "$last_stat" =~ [[:space:]]accepted=([0-9]+) ]] && local_acc="${BASH_REMATCH[1]}"
        [[ "$last_stat" =~ [[:space:]]rejected=([0-9]+) ]] && local_rej="${BASH_REMATCH[1]}"

        diff="${GPU_DIFF[$gpu_idx]:-?}"
        short_job="${job_id:0:8}"

        if (( ping_ms > 0 )); then
            ping_str="${ping_ms} ms"
        else
            ping_str="n/a"
        fi

        log_print "${G}[${hhmm}] GPU ${gpu_idx} Share accepted   ping=${ping_str}   diff=${diff}   job=${short_job}   [${local_acc}/${local_rej}]${R}"

    # =========================================================================
    # SHARE REJECTED
    # =========================================================================
    elif [[ "$component" == "share" ]] && [[ "$line" =~ "rejected" ]]; then
        local_acc=0 ; local_rej=0
        last_stat=$(grep -a "component=miner status" "$BUFFER_FILE" 2>/dev/null \
            | grep " gpu=${gpu_idx}:" | tail -n1)
        [[ "$last_stat" =~ [[:space:]]accepted=([0-9]+) ]] && local_acc="${BASH_REMATCH[1]}"
        [[ "$last_stat" =~ [[:space:]]rejected=([0-9]+) ]] && local_rej="${BASH_REMATCH[1]}"
        diff="${GPU_DIFF[$gpu_idx]:-?}"

        log_print "${RD}[${hhmm}] GPU ${gpu_idx} Share REJECTED              diff=${diff}              [${local_acc}/${local_rej}]${R}"

    fi

done
