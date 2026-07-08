#!/usr/bin/env bash
#
# alpha-events.sh -- real-time event printer for alpha-wrapper
#
# Reads from the events sidecar file (/run/alpha-wrapper/events.log) which
# contains only meaningful events (pool, share, hit changes). This file
# NEVER gets trimmed, so no lines are ever lost — eliminating ping desync.
#
# Dual-mode ping measurement:
#   v1.8.3: push to queue on status line `hits` increment (prints every attempt)
#   v1.8.5: push to queue on `component=share found_candidate` line (exact hit timestamp)
#
# Env vars:
#   BUFFER_FILE   /run/alpha-wrapper/miner-raw.buf (for counter init only)
#   EVENTS_FILE   /run/alpha-wrapper/events.log (sidecar — never trimmed)
#   GPU_LIST      comma-separated active CUDA indices
set -u

BUFFER_FILE="${BUFFER_FILE:-/run/alpha-wrapper/miner-raw.buf}"
EVENTS_FILE="${EVENTS_FILE:-/run/alpha-wrapper/events.log}"
GPU_LIST="${GPU_LIST:-0}"
BUFFER_DIR="${BUFFER_DIR:-/run/alpha-wrapper}"
WRAPPER_DETAIL="${WRAPPER_DETAIL:-0}"
GPU_COMPUTE_NUM="${GPU_COMPUTE_NUM:-0}"

# Helper: print to stdout only (h-run.sh tee handles the log file)
log_print() {
    printf '%s\n' "$1"
}

# ===== Version detection ======================================================
# Wait for supervisor to detect version from miner output
MINER_VERSION=""
PING_MODE="status"  # "status" = v1.8.3 (push on hits increment), "candidate" = v1.8.5+

detect_version() {
    local ver_file="$BUFFER_DIR/miner-version"
    local wait_count=0
    while [[ ! -f "$ver_file" ]] && (( wait_count < 60 )); do
        sleep 0.5
        (( wait_count++ ))
    done
    if [[ -f "$ver_file" ]]; then
        MINER_VERSION=$(cat "$ver_file")
        local major minor patch
        IFS='.' read -r major minor patch <<< "$MINER_VERSION"
        if (( major > 1 )) || (( major == 1 && minor > 8 )) || (( major == 1 && minor == 8 && patch >= 5 )); then
            # v1.8.5+: candidate mode unless GPU is Ampere or older (no found_candidate)
            if (( GPU_COMPUTE_NUM > 0 && GPU_COMPUTE_NUM < 89 )); then
                PING_MODE="n/a"
            else
                PING_MODE="candidate"
            fi
        fi
    fi
    log_print "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] Miner version: ${MINER_VERSION:-unknown} — ping mode: $PING_MODE"
}

# ===== State per GPU ==========================================================
declare -A LAST_HITS_COUNT=()
declare -A LAST_ACC_COUNT=()
declare -A LAST_DROPPED_COUNT=()
declare -A DISPLAY_ACC=()   # Our own accepted counter (incremented on share accepted event)
declare -A DISPLAY_REJ=()   # Our own rejected counter (incremented on share rejected/dropped event)
declare -A GPU_HIT_QUEUE=()  # Queue of hit timestamps per GPU (space-separated)
declare -A GPU_GHOST_HITS=() # Hits counted by miner but never seen as found_candidate (obsolete_job)
declare -A GPU_DIFF=()
declare -A PENDING_CHALLENGE=()  # Per-GPU: "solve_sec|hhmm" buffered until difficulty_set arrives
LAST_JOB_ID=""
LAST_POOL_HOST=""
POOL_RECONNECTING=0  # flag: suppress "connected" prints during reconnect attempts
POOL_CONNECTED_PRINTED=0  # flag: "Pool connected" printed for this connection

# ===== Timestamp -> milliseconds ==============================================
ts_to_ms() {
    local ts="$1"
    local sec_part="${ts%.*}"
    local frac="${ts##*.}"; frac="${frac%Z}"; frac="${frac:0:3}"
    while (( ${#frac} < 3 )); do frac="${frac}0"; done
    # date -d is called ~4 times/min (on hit/acceptance only) — acceptable cost
    local ep; ep=$(date -d "${sec_part}Z" +%s 2>/dev/null) || ep=0
    echo $(( ep * 1000 + 10#$frac ))
}

# ===== Initialize counters from buffer (for seamless restart) =================
init_from_buffer() {
    [[ ! -f "$BUFFER_FILE" ]] && return
    for idx in ${GPU_LIST//,/ }; do
        local last_status
        last_status=$(grep -a "component=miner status" "$BUFFER_FILE" 2>/dev/null \
            | grep -a " gpu=${idx}:" | tail -n 1)
        if [[ -n "$last_status" ]]; then
            [[ "$last_status" =~ [[:space:]]accepted=([0-9]+) ]] && DISPLAY_ACC[$idx]="${BASH_REMATCH[1]}"
            [[ "$last_status" =~ [[:space:]]rejected=([0-9]+) ]] && DISPLAY_REJ[$idx]="${BASH_REMATCH[1]}"
        fi
    done
}

# ===== Wait for sidecar to exist ==============================================
while [[ ! -f "$EVENTS_FILE" ]]; do sleep 0.5; done
detect_version
init_from_buffer

# ===== Main read loop =========================================================
# The sidecar (events.log) NEVER gets trimmed — only grows with meaningful
# events (~12 lines/min). No trim = no lost lines = no ping desync.

process_line() {
    local line="$1"
    [[ -z "$line" ]] && return

    # Guard: skip partial lines (from mid-write reads). Valid lines start with ISO timestamp.
    [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || return

    local ts="${line%% *}"
    local gpu_raw="" gpu_idx="" component=""
    [[ "$line" =~ [[:space:]]gpu=([^[:space:]]+) ]] && gpu_raw="${BASH_REMATCH[1]}"
    gpu_idx="${gpu_raw%%:*}"
    [[ "$gpu_idx" == "system" || -z "$gpu_idx" ]] && gpu_idx="0"
    [[ "$line" =~ [[:space:]]component=([^[:space:]]+) ]] && component="${BASH_REMATCH[1]}"

    # Skip lines that don't match any handler (vast majority are status lines
    # that only need hit tracking — no date call needed for those)
    if [[ "$component" != "pool" && "$component" != "share" && "$component" != "miner" ]]; then
        return
    fi

    if [[ "$component" == "pool" ]]; then
        local hhmm; hhmm="$(date +'%Y-%m-%d %H:%M:%S')"
        if [[ "$line" =~ "drop_ambiguous_share" || "$line" =~ "action=reconnect_drop" ]]; then
            # Pool silently dropped a share during reconnect — pop from hit queue
            if [[ -n "${GPU_HIT_QUEUE[$gpu_idx]:-}" ]]; then
                local queue="${GPU_HIT_QUEUE[$gpu_idx]}"
                local _discard
                read -r _discard queue <<< "$queue"
                GPU_HIT_QUEUE[$gpu_idx]="$queue"
            fi
            log_print "[${hhmm}] [WARN] Share dropped (pool reconnect)"
        elif [[ "$line" =~ "connection_lost" ]]; then
            POOL_RECONNECTING=1
            log_print "[${hhmm}] [WARN] Pool connection lost — reconnecting"
        elif [[ "$line" =~ "reconnect_failed" ]]; then
            local failures=""
            [[ "$line" =~ [[:space:]]failures=([0-9]+) ]] && failures="${BASH_REMATCH[1]}"
            log_print "[${hhmm}] [WARN] Reconnect failed (attempt ${failures:-?})"
        elif [[ "$line" =~ "challenge_solved" ]]; then
            local solve_sec=""
            [[ "$line" =~ [[:space:]]seconds=([0-9.]+) ]] && solve_sec="${BASH_REMATCH[1]}"
            POOL_RECONNECTING=0
            # Print "Pool connected" once for this connection (first GPU to solve)
            if (( POOL_CONNECTED_PRINTED == 0 )); then
                POOL_CONNECTED_PRINTED=1
                log_print "[${hhmm}] [INFO] Pool connected: ${LAST_POOL_HOST}"
            fi
            # Buffer until difficulty_set arrives — combine into one line per GPU
            PENDING_CHALLENGE[$gpu_idx]="${solve_sec:-?}|${hhmm}"
        elif [[ "$line" =~ [[:space:]]connected[[:space:]] && "$line" =~ host= ]]; then
            local host="" port=""
            [[ "$line" =~ [[:space:]]host=([^[:space:]]+) ]] && host="${BASH_REMATCH[1]}"
            [[ "$line" =~ [[:space:]]port=([^[:space:]]+) ]] && port="${BASH_REMATCH[1]}"
            LAST_POOL_HOST="${host}:${port}"
            POOL_CONNECTED_PRINTED=0  # reset for this new connection
            # Don't print "Pool connected" here — wait for challenge_solved to confirm
        elif [[ "$line" =~ "disconnected" ]]; then
            log_print "[${hhmm}] [INFO] Pool disconnected"
        elif [[ "$line" =~ "difficulty_set" ]]; then
            local diff=""
            [[ "$line" =~ [[:space:]]difficulty=([0-9.]+) ]] && diff="${BASH_REMATCH[1]}"
            diff="${diff%.00}"
            [[ -n "$diff" ]] && GPU_DIFF[$gpu_idx]="$diff"
            # Combine with pending challenge line for this GPU
            if [[ -n "${PENDING_CHALLENGE[$gpu_idx]:-}" ]]; then
                local pending="${PENDING_CHALLENGE[$gpu_idx]}"
                local solve_sec="${pending%%|*}"
                local ch_hhmm="${pending##*|}"
                unset "PENDING_CHALLENGE[$gpu_idx]"
                log_print "$(printf "[%s] [INFO] GPU %-2s  Challenge solved (%ss)  Difficulty set: %s" "$ch_hhmm" "$gpu_idx" "$solve_sec" "$diff")"
            else
                log_print "[${hhmm}] [INFO] GPU ${gpu_idx} Difficulty set: ${diff}"
            fi
        elif [[ "$line" =~ [[:space:]]"job "[[:space:]] ]] || [[ "$line" =~ [[:space:]]job[[:space:]]id= ]]; then
            local job_id="" gen="" diff=""
            [[ "$line" =~ [[:space:]]id=([^[:space:]]+) ]]        && job_id="${BASH_REMATCH[1]}"
            [[ "$line" =~ [[:space:]]generation=([^[:space:]]+) ]] && gen="${BASH_REMATCH[1]}"
            [[ "$line" =~ [[:space:]]difficulty=([0-9.]+) ]]       && diff="${BASH_REMATCH[1]}"
            diff="${diff%.00}"
            [[ -n "$diff" ]] && GPU_DIFF[$gpu_idx]="$diff"
            if [[ -n "$job_id" && "$job_id" != "$LAST_JOB_ID" ]]; then
                LAST_JOB_ID="$job_id"
                local _line
                printf -v _line "[%s] [INFO] New job generation=%-6s diff=%-17s job=%s" \
                    "$hhmm" "$gen" "$diff" "$job_id"
                log_print "$_line"
            fi
        fi

    elif [[ "$component" == "share" ]] && [[ "$line" =~ "component=share found_candidate" ]]; then
        # v1.8.5+ candidate detection — push hit timestamp to queue
        if [[ "$PING_MODE" == "candidate" ]]; then
            local hit_ts_ms; hit_ts_ms="$(ts_to_ms "$ts")"
            GPU_HIT_QUEUE[$gpu_idx]="${GPU_HIT_QUEUE[$gpu_idx]:-} $hit_ts_ms"
        fi

    elif [[ "$component" == "miner" ]] && [[ "$line" =~ [[:space:]]"status"[[:space:]] ]]; then
        local hits=0 acc=0 dropped=0
        [[ "$line" =~ [[:space:]]hits=([0-9]+) ]] && hits="${BASH_REMATCH[1]}"
        [[ "$line" =~ [[:space:]]accepted=([0-9]+) ]] && acc="${BASH_REMATCH[1]}"
        [[ "$line" =~ [[:space:]]dropped=([0-9]+) ]] && dropped="${BASH_REMATCH[1]}"
        local prev_hits="${LAST_HITS_COUNT[$gpu_idx]:-0}"
        local prev_acc="${LAST_ACC_COUNT[$gpu_idx]:-0}"
        local prev_dropped="${LAST_DROPPED_COUNT[$gpu_idx]:-0}"

        # Only queue a hit timestamp on exactly +1 increment (ignore duplicates/jumps)
        # v1.8.3 mode: status line IS the hit signal (prints every attempt)
        # v1.8.5 mode: found_candidate handles this — skip here
        if [[ "$PING_MODE" == "status" ]] && (( hits == prev_hits + 1 )); then
            local hit_ts_ms; hit_ts_ms="$(ts_to_ms "$ts")"
            GPU_HIT_QUEUE[$gpu_idx]="${GPU_HIT_QUEUE[$gpu_idx]:-} $hit_ts_ms"
        fi
        (( hits > prev_hits )) && LAST_HITS_COUNT[$gpu_idx]="$hits"

        # Track dropped count — pop queue when dropped increments (silent share loss)
        if (( dropped > prev_dropped )); then
            local drops_to_pop=$(( dropped - prev_dropped ))
            while (( drops_to_pop > 0 )) && [[ -n "${GPU_HIT_QUEUE[$gpu_idx]:-}" ]]; do
                local queue="${GPU_HIT_QUEUE[$gpu_idx]}"
                local _discard
                read -r _discard queue <<< "$queue"
                GPU_HIT_QUEUE[$gpu_idx]="$queue"
                (( drops_to_pop-- ))
            done
            LAST_DROPPED_COUNT[$gpu_idx]="$dropped"
        fi

        # Track accepted count
        (( acc > prev_acc )) && LAST_ACC_COUNT[$gpu_idx]="$acc"

        # ---- Queue sanity check (failsafe) ----
        # Only check on steady-state lines (hits didn't change this line).
        # When hits just incremented, the accepted counter hasn't caught up yet
        # so the expected in-flight would be artificially high.
        if (( hits == prev_hits )); then
            local ghost="${GPU_GHOST_HITS[$gpu_idx]:-0}"
            local expected_inflight=$(( hits - acc - dropped - ghost ))
            (( expected_inflight < 0 )) && expected_inflight=0
            local queue_str="${GPU_HIT_QUEUE[$gpu_idx]:-}"
            local actual_len=0
            if [[ -n "$queue_str" ]]; then
                local _arr=($queue_str)
                actual_len=${#_arr[@]}
            fi
            if (( actual_len != expected_inflight && actual_len > 0 )); then
                GPU_HIT_QUEUE[$gpu_idx]=""
                log_print "[$(date +'%Y-%m-%d %H:%M:%S')] [DEBUG] Queue reset: gpu=$gpu_idx hits=$hits acc=$acc dropped=$dropped expected=$expected_inflight actual=$actual_len"
            fi
        fi

    elif [[ "$component" == "share" ]] && [[ "$line" =~ "accepted" ]] && [[ ! "$line" =~ "component=share found_candidate" ]]; then
        local hhmm; hhmm="$(date +'%Y-%m-%d %H:%M:%S')"
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
        local ping_str=""
        if [[ "$PING_MODE" != "n/a" ]]; then
            (( ping_ms > 0 )) && ping_str="${ping_ms} ms" || ping_str="n/a"
        fi
        local _line
        if (( WRAPPER_DETAIL )); then
            local share_label="Share accepted"
            [[ -n "$ping_str" ]] && share_label="Share accepted (${ping_str})"
            printf -v _line "[%s] GPU %-2s %-32s diff=%-16s job=%s [%s/%s]" \
                "$hhmm" "$gpu_idx" "$share_label" "$diff" "$short_job" "$local_acc" "$local_rej"
        else
            if [[ -n "$ping_str" ]]; then
                printf -v _line "[%s] GPU %-2s Share accepted (%s)" \
                    "$hhmm" "$gpu_idx" "$ping_str"
            else
                printf -v _line "[%s] GPU %-2s Share accepted" \
                    "$hhmm" "$gpu_idx"
            fi
        fi
        log_print "$_line"

    elif [[ "$component" == "share" ]] && [[ "$line" =~ "rejected" || "$line" =~ "dropped" ]] && [[ ! "$line" =~ "component=share found_candidate" ]]; then
        local hhmm; hhmm="$(date +'%Y-%m-%d %H:%M:%S')"

        if [[ "$line" =~ "reason=obsolete_job" ]]; then
            # Internal drop: miner found candidate but job became stale before submission.
            # hits increments but dropped counter does NOT. Track as ghost hit.
            GPU_GHOST_HITS[$gpu_idx]=$(( ${GPU_GHOST_HITS[$gpu_idx]:-0} + 1 ))
            # Pop from queue if we saw the found_candidate for this hit
            if [[ -n "${GPU_HIT_QUEUE[$gpu_idx]:-}" ]]; then
                local queue="${GPU_HIT_QUEUE[$gpu_idx]}"
                local _discard
                read -r _discard queue <<< "$queue"
                GPU_HIT_QUEUE[$gpu_idx]="$queue"
            fi
            if (( WRAPPER_DETAIL )); then
                printf -v _line "[%s] GPU %-2s Share dropped (stale)" "$hhmm" "$gpu_idx"
                log_print "$_line"
            fi
        else
            # Real pool rejection — pop from queue
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
            local job_id=""
            [[ "$line" =~ [[:space:]]job=([^[:space:]]+) ]] && job_id="${BASH_REMATCH[1]}"
            local short_job="${job_id:0:8}"
            local label="REJECTED"
            [[ "$line" =~ "dropped" ]] && label="DROPPED"
            local _line
            if (( WRAPPER_DETAIL )); then
                printf -v _line "[%s] GPU %-2s %-32s diff=%-16s job=%s [%s/%s]" \
                    "$hhmm" "$gpu_idx" "Share $label" "$diff" "$short_job" "$local_acc" "$local_rej"
            else
                printf -v _line "[%s] GPU %-2s Share %s" \
                    "$hhmm" "$gpu_idx" "$label"
            fi
            log_print "$_line"
        fi
    fi
}

# Use tail -f for instant line delivery. Since the sidecar never gets
# replaced (mv) or trimmed, tail -f works perfectly via inotify.
# No polling, no partial lines, no missed data.
while IFS= read -r line; do
    process_line "$line"
done < <(tail -f -n +1 "$EVENTS_FILE" 2>/dev/null)
