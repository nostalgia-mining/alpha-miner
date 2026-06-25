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

    # Extract local time from log line timestamp (2026-06-25T14:17:08.839Z)
    local hhmm
    if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T([0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert UTC timestamp to local time
        local ts_epoch; ts_epoch=$(date -d "${ts}" +%s 2>/dev/null || echo 0)
        hhmm=$(date -d "@${ts_epoch}" +'%H:%M:%S' 2>/dev/null || date +'%H:%M:%S')
    else
        hhmm="$(date +'%H:%M:%S')"
    fi

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

    elif [[ "$component" == "share" ]] && [[ "$line" =~ "accepted" ]]; then
        local job_id=""
        [[ "$line" =~ [[:space:]]job=([^[:space:]]+) ]] && job_id="${BASH_REMATCH[1]}"
        local ping_ms=0
        local accepted_ms; accepted_ms="$(ts_to_ms "$ts")"
        
        # Find the most recent hit timestamp before this acceptance (same logic as alpha-stats.sh)
        # Search backwards through recent status lines to find when hits incremented
        local hit_ts_ms=0
        local recent_status
        recent_status=$(tail -n 200 "$BUFFER_FILE" 2>/dev/null | grep -a "component=miner status" | grep " gpu=${gpu_idx}:")
        
        if [[ -n "$recent_status" ]]; then
            local prev_hits=0
            local found_hit_ts=""
            while IFS= read -r status_line; do
                local s_ts="${status_line%% *}"
                local s_hits=0
                [[ "$status_line" =~ [[:space:]]hits=([0-9]+) ]] && s_hits="${BASH_REMATCH[1]}"
                
                # Check if this status line is before the acceptance
                local s_ms; s_ms="$(ts_to_ms "$s_ts")"
                (( s_ms >= accepted_ms )) && continue
                
                # Track hit increments
                if (( s_hits > prev_hits )); then
                    found_hit_ts="$s_ts"
                fi
                prev_hits="$s_hits"
            done <<< "$recent_status"
            
            if [[ -n "$found_hit_ts" ]]; then
                hit_ts_ms="$(ts_to_ms "$found_hit_ts")"
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

    elif [[ "$component" == "share" ]] && [[ "$line" =~ "rejected" ]]; then
        local local_acc=0 local_rej=0
        local last_stat
        last_stat=$(tail -n 100 "$BUFFER_FILE" 2>/dev/null \
            | grep -a "component=miner status" \
            | grep " gpu=${gpu_idx}:" | tail -n1)
        [[ "$last_stat" =~ [[:space:]]accepted=([0-9]+) ]] && local_acc="${BASH_REMATCH[1]}"
        [[ "$last_stat" =~ [[:space:]]rejected=([0-9]+) ]] && local_rej="${BASH_REMATCH[1]}"
        local diff="${GPU_DIFF[$gpu_idx]:-?}"
        log_print "[${hhmm}] GPU ${gpu_idx} Share REJECTED              diff=${diff}              [${local_acc}/${local_rej}]"
    fi
}

while true; do
    local_size=$(wc -c < "$BUFFER_FILE" 2>/dev/null || echo 0)
    if (( local_size < current_offset )); then
        # File was trimmed/replaced — reset to current end
        current_offset=$local_size
    fi
    if (( local_size > current_offset )); then
        # Read only the new bytes (tail -c + is 1-indexed)
        tail -c +$((current_offset + 1)) "$BUFFER_FILE" 2>/dev/null | \
        while IFS= read -r line; do
            process_line "$line"
        done
        current_offset=$local_size
    fi
    sleep 0.5
done
