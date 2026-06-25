#!/usr/bin/env bash
# alpha-wrapper — multi-pool failover supervisor
#
# exec'd by h-run.sh (never directly by HiveOS) so "h-run.sh" never
# appears in the long-lived process argv (HiveOS wrapper contract).
#
# Architecture:
#   - Miner stdout/stderr → RAM-backed rolling buffer (/run/alpha-wrapper/miner-raw.buf)
#     NOT to the persistent log or screen. This keeps the persistent log small
#     and meaningful, and prevents --status-interval 1 + --debug-log from
#     flooding /var/log with gigabytes of raw status lines.
#   - Rolling buffer is capped at BUFFER_LINES lines (trimmed every 500 writes).
#     At status-interval 1 on 1 GPU: ~6 lines/sec → 3000 lines ≈ 8 min of data.
#     For N GPUs multiply BUFFER_LINES by N (or set BUFFER_LINES=N*3000 in
#     flight sheet extra config).
#   - alpha-events.sh and alpha-stats.sh read from the buffer in real time.
#   - Failover detection reads the buffer for recent accepted shares.
#   - Persistent log (written by h-run.sh tee) contains only wrapper messages.
#
# Failover tunables (set via flight sheet extra config → h-config.sh):
#   FAILOVER_GRACE_SEC=120   FAILOVER_DEAD_SEC=240
#   FAILOVER_RETURN_SEC=1800 FAILOVER_POLL_SEC=15
#   BUFFER_LINES=3000

SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f "$SCRIPT_PATH/h-manifest.conf" ]] && source "$SCRIPT_PATH/h-manifest.conf"
cd "$SCRIPT_PATH"

MINER_BIN="$SCRIPT_PATH/alpha"

# Rolling buffer — /run is tmpfs on Linux (RAM, not persisted across reboots)
BUFFER_DIR="/run/alpha-wrapper"
BUFFER_FILE="$BUFFER_DIR/miner-raw.buf"
: "${BUFFER_LINES:=10000}"  # 10000 lines ≈ 2 min at status-interval 1 on 12 GPUs
                            # Rule of thumb: ~68 lines/sec per 12 GPUs
                            # Override via flight sheet: BUFFER_LINES=N

if [[ ! -x "$MINER_BIN" ]]; then
    echo "ERROR: Binary not found or not executable: $MINER_BIN"
    exit 1
fi

[[ -f "$SCRIPT_PATH/miner.conf" ]] && source "$SCRIPT_PATH/miner.conf"

if [[ ${#POOLS[@]} -eq 0 || ${#ALPHA_BASE_ARGS[@]} -eq 0 ]]; then
    echo "ERROR: miner.conf missing POOLS[] or ALPHA_BASE_ARGS[] (run h-config.sh)"
    exit 1
fi

: "${FAILOVER_GRACE_SEC:=120}"
: "${FAILOVER_DEAD_SEC:=240}"
: "${FAILOVER_RETURN_SEC:=1800}"
: "${FAILOVER_POLL_SEC:=15}"

export CUDA_DEVICE_ORDER=PCI_BUS_ID

# Ensure buffer directory and file exist
mkdir -p "$BUFFER_DIR" 2>/dev/null
touch "$BUFFER_FILE"   2>/dev/null

echo "========================================"
echo "$CUSTOM_NAME v$CUSTOM_VERSION  (failover supervisor, pid $$)"
echo "Pools (${#POOLS[@]}): ${POOLS[*]}"
echo "Base args: ${ALPHA_BASE_ARGS[*]}"
echo "Failover: grace=${FAILOVER_GRACE_SEC}s dead=${FAILOVER_DEAD_SEC}s return=${FAILOVER_RETURN_SEC}s"
echo "Buffer: $BUFFER_FILE (${BUFFER_LINES} lines cap)"
echo "========================================"

miner_pid=""
writer_pid=""

# ---- Rolling buffer writer --------------------------------------------------
# Reads from a named pipe, appends to rolling buffer, trims every 500 writes.
# Also captures the first HEAD_LINES lines to a permanent head file for debugging.
HEAD_FILE="$BUFFER_DIR/miner-raw-head.buf"   # in RAM — symlinked to log dir if --extralogs
HEAD_LINES=1000
HEAD_LOG="/var/log/miner/custom/alpha-wrapper-raw-head.log"

start_buffer_writer() {
    local pipe="$1"
    local cnt_file="$BUFFER_DIR/.wc"
    local head_cnt_file="$BUFFER_DIR/.hc"
    echo 0 > "$cnt_file"
    echo 0 > "$head_cnt_file"
    # Clear head file for this session — prepopulate with wrapper startup banner
    {
        echo "========================================"
        echo "$CUSTOM_NAME v$CUSTOM_VERSION  (failover supervisor, pid $$)"
        echo "Pools (${#POOLS[@]}): ${POOLS[*]}"
        echo "Base args: ${ALPHA_BASE_ARGS[*]}"
        echo "Failover: grace=${FAILOVER_GRACE_SEC}s dead=${FAILOVER_DEAD_SEC}s return=${FAILOVER_RETURN_SEC}s"
        echo "Buffer: $BUFFER_FILE (${BUFFER_LINES} lines cap)"
        echo "========================================"
    } > "$HEAD_FILE"
    local hc=7  # 7 lines written above
    echo "$hc" > "$head_cnt_file"
    
    (
        while IFS= read -r line; do
            printf '%s\n' "$line" >> "$BUFFER_FILE"

            # Capture head (first HEAD_LINES lines only, once per session)
            hc=$(cat "$head_cnt_file" 2>/dev/null || echo 0)
            if (( hc < HEAD_LINES )); then
                printf '%s\n' "$line" >> "$HEAD_FILE"
                echo $(( hc + 1 )) > "$head_cnt_file"
            fi

            local cnt
            cnt=$(cat "$cnt_file" 2>/dev/null || echo 0)
            cnt=$(( cnt + 1 ))
            if (( cnt >= 500 )); then
                tail -n "$BUFFER_LINES" "$BUFFER_FILE" > "${BUFFER_FILE}.tmp" \
                    && mv "${BUFFER_FILE}.tmp" "$BUFFER_FILE"
                cnt=0
            fi
            echo "$cnt" > "$cnt_file"
        done < "$pipe"
    ) &
    writer_pid=$!
}

stop_miner() {
    [[ -z "$miner_pid" ]] && return
    kill -INT "$miner_pid" 2>/dev/null
    for _ in $(seq 1 12); do
        kill -0 "$miner_pid" 2>/dev/null || break
        sleep 1
    done
    kill -KILL "$miner_pid" 2>/dev/null
    wait "$miner_pid" 2>/dev/null
    miner_pid=""
    [[ -n "$writer_pid" ]] && kill "$writer_pid" 2>/dev/null
    wait "$writer_pid" 2>/dev/null
    writer_pid=""
}

on_stop() {
    trap - INT TERM
    echo "$(date -u +%FT%TZ) [wrapper] stop signal — shutting down miner"
    stop_miner
    exit 0
}
trap on_stop INT TERM

now() { date +%s; }

# Check buffer for a recent accepted share (for failover detection)
last_share_epoch() {
    local ts
    ts=$(tail -n "${FAILOVER_SHARE_SCAN_LINES:-8000}" "$BUFFER_FILE" 2>/dev/null \
         | grep -aE 'component=share accepted' \
         | tail -n 1 \
         | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}')
    if [[ -n "$ts" ]]; then
        date -d "${ts}Z" +%s 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# ---- Main failover loop -----------------------------------------------------
n=${#POOLS[@]}
idx=0
primary_retry_at=$(( $(now) + FAILOVER_RETURN_SEC ))

while :; do
    pool="${POOLS[$idx]}"
    echo "$(date -u +%FT%TZ) [wrapper] launching miner on pool[$idx]=$pool"

    # Named pipe: miner output flows into the buffer writer, never to screen/log
    MINER_PIPE="$BUFFER_DIR/miner-$$.pipe"
    mkfifo "$MINER_PIPE" 2>/dev/null

    start_buffer_writer "$MINER_PIPE"

    "$MINER_BIN" --pool "$pool" "${ALPHA_BASE_ARGS[@]}" > "$MINER_PIPE" 2>&1 &
    miner_pid=$!

    # Unlink the pipe file — open fds keep it alive; cleaned up automatically
    rm -f "$MINER_PIPE"

    launch=$(now)
    rotate=""

    while :; do
        sleep "$FAILOVER_POLL_SEC" &
        wait $!

        if ! kill -0 "$miner_pid" 2>/dev/null; then
            wait "$miner_pid" 2>/dev/null
            echo "$(date -u +%FT%TZ) [wrapper] miner exited on pool[$idx] — rotating"
            rotate="next"; break
        fi

        # ---- Fatal miner error detection ------------------------------------
        # Some errors (e.g. "pool pipeline profile changed") require a full
        # miner restart to recover. We detect these in the buffer and kill/
        # restart the miner immediately rather than waiting for the failover
        # dead-share timeout.
        if grep -qaE 'component=miner error=' "$BUFFER_FILE" 2>/dev/null; then
            # Only act on errors that appeared after this launch
            local launch_ts
            launch_ts=$(date -u -d "@$launch" +%FT%TZ 2>/dev/null || date -u +%FT%TZ)
            local err_line
            err_line=$(grep -aE 'component=miner error=' "$BUFFER_FILE" 2>/dev/null | tail -n1)
            if [[ -n "$err_line" ]]; then
                echo "$(date -u +%FT%TZ) [wrapper] miner error detected — restarting: $err_line"
                # Truncate the buffer to remove the error line so we don't
                # trigger again on the same error after restart
                grep -vaE 'component=miner error=' "$BUFFER_FILE" > "${BUFFER_FILE}.tmp" 2>/dev/null \
                    && mv "${BUFFER_FILE}.tmp" "$BUFFER_FILE"
                rotate="next"; break
            fi
        fi

        t=$(now)
        ls=$(last_share_epoch)
        (( ls < launch )) && ls=$launch

        if (( t - launch > FAILOVER_GRACE_SEC )) && (( t - ls > FAILOVER_DEAD_SEC )); then
            echo "$(date -u +%FT%TZ) [wrapper] pool[$idx]=$pool DEAD — no share for $((t-ls))s — failing over"
            rotate="next"; break
        fi

        if (( idx != 0 )) && (( t >= primary_retry_at )); then
            echo "$(date -u +%FT%TZ) [wrapper] retrying primary pool[0]"
            rotate="primary"; break
        fi
    done

    stop_miner

    [[ "$rotate" == "primary" ]] && idx=0 || idx=$(( (idx + 1) % n ))
    (( idx == 0 )) && primary_retry_at=$(( $(now) + FAILOVER_RETURN_SEC ))

    sleep 2
done
