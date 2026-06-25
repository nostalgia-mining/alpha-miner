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

# ===== Colors — all disabled for plain text output ============================
G=''   # was green
Y=''   # was yellow
R=''   # was reset
RD=''  # was red
W=''   # was white
B=''   # was bold

# Helper: print to stdout only (h-run.sh tee strips ANSI and writes to log)
log_print() {
    printf '%s\n' "$1"
}

# ===== State per GPU ==========================================================
declare -A LAST_HITS_COUNT=()
declare -A GPU_HIT_QUEUE=()  # Queue of hit timestamps per GPU (space-separated)
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

# Initialize GPU_DIFF from existing buffer content (for restarts)
# For each GPU, find its MOST RECENT difficulty from pool events.
# This handles per-GPU vardiff correctly even in multi-GPU rigs.
for idx in ${GPU_LIST//,/ }; do
    # Get the last difficulty_set or job line for this specific GPU
    last_diff_line=$(grep -a "component=pool" "$BUFFER_FILE" 2>/dev/null \
        | grep -E " gpu=${idx}:" \
        | grep -E "(difficulty_set|job )" \
        | tail -n 1)
    
    if [[ -n "$last_diff_line" ]]; then
        diff=""
        [[ "$last_diff_line" =~ [[:space:]]difficulty=([0-9.]+) ]] && diff="${BASH_REMATCH[1]}"
        diff="${diff%.00}"
        [[ -n "$diff" ]] && GPU_DIFF[$idx]="$diff"
    fi

    # Initialize LAST_HITS_COUNT from the most recent status line so the
    # first status line processed doesn't spuriously queue N hit timestamps.
    last_status=$(grep -a "component=miner status" "$BUFFER_FILE" 2>/dev/null \
        | grep -a " gpu=${idx}:" | tail -n 1)
    if [[ -n "$last_status" ]]; then
        [[ "$last_status" =~ [[:space:]]hits=([0-9]+) ]] && LAST_HITS_COUNT[$idx]="${BASH_REMATCH[1]}"
    fi
done

# Record current size — only process lines written AFTER this point.
# This prevents replaying old buffer content on miner restart.
START_OFFSET=$(wc -c < "$BUFFER_FILE" 2>/dev/null || echo 0)

# ===== Main read loop =========================================================
# We can't use 'tail -f' because the buffer file gets atomically replaced
# during trimming (mv .tmp -> .buf), which causes tail -f to lose its position.
# Instead we poll with a byte-offset tracker, reading only new content.

current_offset=$(wc -c < "$BUFFER_FILE" 2>/dev/null || echo 0)

process_line() {
    local line="$1"
    [[ -z "$line" ]] && return

    local ts="${line%% *}"
    local gpu_raw="" gpu_idx="" component=""
    [[ "$line" =~ [[:space:]]gpu=([^[:space:]]+) ]] && gpu_raw="${BASH_REMATCH[1]}"
    gpu_idx="${gpu_raw%%:*}"
    [[ "$gpu_idx" == "system" || -z "$gpu_idx" ]] && gpu_idx="0"
    [[ "$line" =~ [[:space:]]component=([^[:space:]]+) ]] && component="${BASH_REMATCH[1]}"

    local hhmm; hhmm="$(date +'%H:%M:%S')"

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
            log_print "[${hhmm}] Pool connected          ${cur_pool}"
        elif [[ "$line" =~ "disconnected" ]]; then
            log_print "[${hhmm}] Pool disconnected"
        elif [[ "$line" =~ "difficulty_set" ]]; then
            local diff=""
            [[ "$line" =~ [[:space:]]difficulty=([0-9.]+) ]] && diff="${BASH_REMATCH[1]}"
            diff="${diff%.00}"
            [[ -n "$diff" ]] && GPU_DIFF[$gpu_idx]="$diff"
            log_print "[${hhmm}] Difficulty set           ${diff}"
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
                log_print "[${hhmm}] New job               id=${short}  gen=${gen}  diff=${diff}"
            fi
        fi

    elif [[ "$component" == "miner" ]] && [[ "$line" =~ [[:space:]]"status"[[:space:]] ]]; then
        local hits=0
        [[ "$line" =~ [[:space:]]hits=([0-9]+) ]] && hits="${BASH_REMATCH[1]}"
        local prev="${LAST_HITS_COUNT[$gpu_idx]:-0}"
        if (( hits > prev )); then
            local hit_ts_ms; hit_ts_ms="$(ts_to_ms "$ts")"
            # Add new hit timestamp(s) to the queue
            local new_hits=$(( hits - prev ))
            for (( i=0; i<new_hits; i++ )); do
                GPU_HIT_QUEUE[$gpu_idx]="${GPU_HIT_QUEUE[$gpu_idx]:-} $hit_ts_ms"
            done
            LAST_HITS_COUNT[$gpu_idx]="$hits"
        fi

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
        
        local local_acc=0 local_rej=0
        local last_stat
        last_stat=$(tail -n 100 "$BUFFER_FILE" 2>/dev/null \
            | grep -a "component=miner status" \
            | grep " gpu=${gpu_idx}:" | tail -n1)
        [[ "$last_stat" =~ [[:space:]]accepted=([0-9]+) ]] && local_acc="${BASH_REMATCH[1]}"
        [[ "$last_stat" =~ [[:space:]]rejected=([0-9]+) ]] && local_rej="${BASH_REMATCH[1]}"
        local diff="${GPU_DIFF[$gpu_idx]:-?}"
        local short_job="${job_id:0:8}"
        local ping_str="n/a"
        (( ping_ms > 0 )) && ping_str="${ping_ms} ms"
        log_print "[${hhmm}] GPU ${gpu_idx} Share accepted   ping=${ping_str}   diff=${diff}   job=${short_job}   [${local_acc}/${local_rej}]"

    elif [[ "$component" == "share" ]] && [[ "$line" =~ "rejected" || "$line" =~ "dropped" ]]; then
        # Pop from hit queue to keep it in sync (same as accepted, but no ping)
        if [[ -n "${GPU_HIT_QUEUE[$gpu_idx]:-}" ]]; then
            local queue="${GPU_HIT_QUEUE[$gpu_idx]}"
            local _discard
            read -r _discard queue <<< "$queue"
            GPU_HIT_QUEUE[$gpu_idx]="$queue"
        fi

        local local_acc=0 local_rej=0
        local last_stat
        last_stat=$(tail -n 100 "$BUFFER_FILE" 2>/dev/null \
            | grep -a "component=miner status" \
            | grep " gpu=${gpu_idx}:" | tail -n1)
        [[ "$last_stat" =~ [[:space:]]accepted=([0-9]+) ]] && local_acc="${BASH_REMATCH[1]}"
        [[ "$last_stat" =~ [[:space:]]rejected=([0-9]+) ]] && local_rej="${BASH_REMATCH[1]}"
        local diff="${GPU_DIFF[$gpu_idx]:-?}"
        local label="REJECTED"
        [[ "$line" =~ "dropped" ]] && label="DROPPED"
        log_print "[${hhmm}] GPU ${gpu_idx} Share ${label}              diff=${diff}              [${local_acc}/${local_rej}]"
    fi
}

while true; do
    local_size=$(wc -c < "$BUFFER_FILE" 2>/dev/null || echo 0)
    if (( local_size < current_offset )); then
        # File was trimmed/replaced — reset to current end
        current_offset=$local_size
    fi
    if (( local_size > current_offset )); then
        # Read only the new bytes — use process substitution (not pipe) to
        # avoid a subshell, so variable updates (GPU_HIT_QUEUE, LAST_HITS_COUNT)
        # persist across poll cycles.
        while IFS= read -r line; do
            process_line "$line"
        done < <(tail -c +$((current_offset + 1)) "$BUFFER_FILE" 2>/dev/null)
        current_offset=$local_size
    fi
    sleep 0.5
done
