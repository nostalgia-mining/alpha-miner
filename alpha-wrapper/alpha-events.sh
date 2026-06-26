#!/usr/bin/env bash
#
# alpha-events.sh -- real-time event printer for alpha-wrapper
#
# Reads lines from a named FIFO fed by the buffer writer. This guarantees
# every line is seen exactly once with no trim race conditions.
# Auto-restarts: if the FIFO breaks (writer dies/restarts), the read loop
# exits and h-run.sh's wrapper relaunches us.
#
# Env vars:
#   BUFFER_FILE   /run/alpha-wrapper/miner-raw.buf (for counter init on restart)
#   EVENTS_PIPE   /run/alpha-wrapper/events.pipe (FIFO from buffer writer)
#   GPU_LIST      comma-separated active CUDA indices
set -u

BUFFER_FILE="${BUFFER_FILE:-/run/alpha-wrapper/miner-raw.buf}"
EVENTS_PIPE="${EVENTS_PIPE:-/run/alpha-wrapper/events.pipe}"
GPU_LIST="${GPU_LIST:-0}"

# Helper: print to stdout only (h-run.sh tee handles the log file)
log_print() {
    printf '%s\n' "$1"
}

# ===== State per GPU ==========================================================
declare -A LAST_HITS_COUNT=()
declare -A LAST_ACC_COUNT=()
declare -A DISPLAY_ACC=()
declare -A DISPLAY_REJ=()
declare -A GPU_HIT_QUEUE=()
declare -A GPU_DIFF=()
LAST_JOB_ID=""
LAST_POOL_HOST=""

# ===== Timestamp -> milliseconds ==============================================
ts_to_ms() {
    local ts="$1"
    local sec_part="${ts%.*}"
    local frac="${ts##*.}"; frac="${frac%Z}"; frac="${frac:0:3}"
    while (( ${#frac} < 3 )); do frac="${frac}0"; done
    local ep; ep=$(date -d "${sec_part}Z" +%s 2>/dev/null) || ep=0
    echo $(( ep * 1000 + 10#$frac ))
}

# ===== Initialize counters from buffer (for seamless restart) =================
# On restart, read the last status line per GPU to recover accepted/rejected
# counts and hits baseline so we don't reset to 0.
init_from_buffer() {
    [[ ! -f "$BUFFER_FILE" ]] && return
    for idx in ${GPU_LIST//,/ }; do
        local last_status
        last_status=$(grep -a "component=miner status" "$BUFFER_FILE" 2>/dev/null \
            | grep -a " gpu=${idx}:" | tail -n 1)
        if [[ -n "$last_status" ]]; then
            [[ "$last_status" =~ [[:space:]]hits=([0-9]+) ]]     && LAST_HITS_COUNT[$idx]="${BASH_REMATCH[1]}"
            [[ "$last_status" =~ [[:space:]]accepted=([0-9]+) ]] && DISPLAY_ACC[$idx]="${BASH_REMATCH[1]}"
            [[ "$last_status" =~ [[:space:]]rejected=([0-9]+) ]] && DISPLAY_REJ[$idx]="${BASH_REMATCH[1]}"
        fi
        # Also recover difficulty
        local last_diff_line
        last_diff_line=$(grep -a "component=pool" "$BUFFER_FILE" 2>/dev/null \
            | grep -a " gpu=${idx}:" \
            | grep -aE "(difficulty_set|job )" \
            | tail -n 1)
        if [[ -n "$last_diff_line" ]]; then
            local diff=""
            [[ "$last_diff_line" =~ [[:space:]]difficulty=([0-9.]+) ]] && diff="${BASH_REMATCH[1]}"
            diff="${diff%.00}"
            [[ -n "$diff" ]] && GPU_DIFF[$idx]="$diff"
        fi
    done
}

# ===== Process a single miner output line =====================================
process_line() {
    local line="$1"
    [[ -z "$line" ]] && return

    local ts="${line%% *}"
    local gpu_raw="" gpu_idx="" component=""
    [[ "$line" =~ [[:space:]]gpu=([^[:space:]]+) ]] && gpu_raw="${BASH_REMATCH[1]}"
    gpu_idx="${gpu_raw%%:*}"
    [[ "$gpu_idx" == "system" || -z "$gpu_idx" ]] && gpu_idx="0"
    [[ "$line" =~ [[:space:]]component=([^[:space:]]+) ]] && component="${BASH_REMATCH[1]}"

    local hhmm; hhmm="$(date +'%Y-%m-%d %H:%M:%S')"

    if [[ "$component" == "pool" ]]; then
        if [[ "$line" =~ [[:space:]]connected[[:space:]] && "$line" =~ host= ]]; then
            local host="" port=""
            [[ "$line" =~ [[:space:]]host=([^[:space:]]+) ]] && host="${BASH_REMATCH[1]}"
            [[ "$line" =~ [[:space:]]port=([^[:space:]]+) ]] && port="${BASH_REMATCH[1]}"
            local cur_pool="${host}:${port}"
            if [[ -n "$LAST_POOL_HOST" && "$LAST_POOL_HOST" != "$cur_pool" ]]; then
                log_print "[${hhmm}] ===== POOL FAILOVER: ${LAST_POOL_HOST} -> ${cur_pool} ====="
            elif [[ -n "$LAST_POOL_HOST" ]]; then
                log_print "[${hhmm}] ===== POOL RECONNECT: ${cur_pool} ====="
            fi
            LAST_POOL_HOST="$cur_pool"
            log_print "[${hhmm}] [INFO] Pool connected: ${cur_pool}"
        elif [[ "$line" =~ "disconnected" ]]; then
            log_print "[${hhmm}] [INFO] Pool disconnected"
        elif [[ "$line" =~ "difficulty_set" ]]; then
            local diff=""
            [[ "$line" =~ [[:space:]]difficulty=([0-9.]+) ]] && diff="${BASH_REMATCH[1]}"
            diff="${diff%.00}"
            [[ -n "$diff" ]] && GPU_DIFF[$gpu_idx]="$diff"
            log_print "[${hhmm}] [INFO] Difficulty set: ${diff}"
        elif [[ "$line" =~ [[:space:]]"job "[[:space:]] ]] || [[ "$line" =~ [[:space:]]job[[:space:]]id= ]]; then
            local job_id="" gen="" diff=""
            [[ "$line" =~ [[:space:]]id=([^[:space:]]+) ]]        && job_id="${BASH_REMATCH[1]}"
            [[ "$line" =~ [[:space:]]generation=([^[:space:]]+) ]] && gen="${BASH_REMATCH[1]}"
            [[ "$line" =~ [[:space:]]difficulty=([0-9.]+) ]]       && diff="${BASH_REMATCH[1]}"
            diff="${diff%.00}"
            [[ -n "$diff" ]] && GPU_DIFF[$gpu_idx]="$diff"
            if [[ -n "$job_id" && "$job_id" != "$LAST_JOB_ID" ]]; then
                LAST_JOB_ID="$job_id"
                local short="${job_id:0:8}...${job_id: -8}"
                log_print "[${hhmm}] GPU ${gpu_idx} New job (${short})  gen=${gen}  diff=${diff}"
            fi
        fi

    elif [[ "$component" == "miner" ]] && [[ "$line" =~ [[:space:]]"status"[[:space:]] ]]; then
        local hits=0 acc=0
        [[ "$line" =~ [[:space:]]hits=([0-9]+) ]] && hits="${BASH_REMATCH[1]}"
        [[ "$line" =~ [[:space:]]accepted=([0-9]+) ]] && acc="${BASH_REMATCH[1]}"
        local prev_hits="${LAST_HITS_COUNT[$gpu_idx]:-0}"
        local prev_acc="${LAST_ACC_COUNT[$gpu_idx]:-0}"

        # Only queue a hit timestamp on exactly +1 increment (ignore duplicates/jumps)
        if (( hits == prev_hits + 1 )); then
            local hit_ts_ms; hit_ts_ms="$(ts_to_ms "$ts")"
            GPU_HIT_QUEUE[$gpu_idx]="${GPU_HIT_QUEUE[$gpu_idx]:-} $hit_ts_ms"
        fi
        (( hits > prev_hits )) && LAST_HITS_COUNT[$gpu_idx]="$hits"
        (( acc > prev_acc )) && LAST_ACC_COUNT[$gpu_idx]="$acc"

    elif [[ "$component" == "share" ]] && [[ "$line" =~ "accepted" ]]; then
        local job_id=""
        [[ "$line" =~ [[:space:]]job=([^[:space:]]+) ]] && job_id="${BASH_REMATCH[1]}"
        local ping_ms=0
        local accepted_ms; accepted_ms="$(ts_to_ms "$ts")"

        # Pop the oldest hit timestamp from the queue for this GPU
        if [[ -n "${GPU_HIT_QUEUE[$gpu_idx]:-}" ]]; then
            local queue="${GPU_HIT_QUEUE[$gpu_idx]}"
            local hit_ts_ms
            read -r hit_ts_ms queue <<< "$queue"
            GPU_HIT_QUEUE[$gpu_idx]="$queue"

            if [[ -n "$hit_ts_ms" && "$hit_ts_ms" =~ ^[0-9]+$ ]]; then
                ping_ms=$(( accepted_ms - hit_ts_ms ))
                (( ping_ms < 0 || ping_ms > 60000 )) && ping_ms=0
            fi
        fi

        local local_acc local_rej
        DISPLAY_ACC[$gpu_idx]=$(( ${DISPLAY_ACC[$gpu_idx]:-0} + 1 ))
        local_acc="${DISPLAY_ACC[$gpu_idx]}"
        local_rej="${DISPLAY_REJ[$gpu_idx]:-0}"
        local diff="${GPU_DIFF[$gpu_idx]:-?}"
        local short_job="${job_id:0:8}"
        local ping_str="n/a"
        (( ping_ms > 0 )) && ping_str="${ping_ms} ms"
        printf -v ping_field "%-10s" "(${ping_str})"
        log_print "[${hhmm}] GPU ${gpu_idx} Share accepted ${ping_field} diff=${diff}   job=${short_job}   [${local_acc}/${local_rej}]"

    elif [[ "$component" == "share" ]] && [[ "$line" =~ "rejected" || "$line" =~ "dropped" ]]; then
        # Pop from hit queue to keep it in sync
        if [[ -n "${GPU_HIT_QUEUE[$gpu_idx]:-}" ]]; then
            local queue="${GPU_HIT_QUEUE[$gpu_idx]}"
            local _discard
            read -r _discard queue <<< "$queue"
            GPU_HIT_QUEUE[$gpu_idx]="$queue"
        fi

        local local_acc local_rej
        DISPLAY_REJ[$gpu_idx]=$(( ${DISPLAY_REJ[$gpu_idx]:-0} + 1 ))
        local_acc="${DISPLAY_ACC[$gpu_idx]:-0}"
        local_rej="${DISPLAY_REJ[$gpu_idx]}"
        local diff="${GPU_DIFF[$gpu_idx]:-?}"
        local label="REJECTED"
        [[ "$line" =~ "dropped" ]] && label="DROPPED"
        printf -v label_field "%-10s" "${label}"
        log_print "[${hhmm}] GPU ${gpu_idx} Share ${label_field} diff=${diff}   [${local_acc}/${local_rej}]"
    fi
}

# ===== Main ===================================================================
init_from_buffer

# Wait for the events FIFO to exist (created by buffer writer)
while [[ ! -p "$EVENTS_PIPE" ]]; do sleep 0.5; done

# Read lines from the FIFO — blocks until writer sends data.
# If the writer dies (pipe breaks), read returns EOF and we exit.
# h-run.sh's restart wrapper will relaunch us.
while IFS= read -r line; do
    process_line "$line"
done < "$EVENTS_PIPE"

# If we get here, the pipe broke — exit so the wrapper can restart us
exit 0
