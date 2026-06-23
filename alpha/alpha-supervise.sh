#!/usr/bin/env bash
# alpha custom miner — multi-pool failover supervisor (rev 1.3.0.1)
#
# exec'd by h-run.sh (NOT by HiveOS directly). This is the long-lived
# foreground process the framework dispatcher blocks on — deliberately named
# so its argv contains no "h-run.sh" (see hiveos-wrapper-contract).
#
# alpha-miner has only a single --pool and never exits on pool-down (retries
# internally forever), so failover MUST be supervised here. Trigger is NOT
# reconnect-count (attack reconnect storms would flap); a pool is dead only
# when, past a startup grace, NO share is submitted for a continuous window.
# Tunables (overridable from flight-sheet extra config via h-config.sh):
#   FAILOVER_GRACE_SEC 120  FAILOVER_DEAD_SEC 240
#   FAILOVER_RETURN_SEC 1800  FAILOVER_POLL_SEC 15  FAILOVER_SHARE_SCAN_LINES 8000
#
# HiveOS stop = Ctrl+C to the screen (+ $MINER_STOP file). The SIGINT/TERM
# trap kills the child miner and exits so the dispatcher/miner-run return.

SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f "$SCRIPT_PATH/h-manifest.conf" ]] && source "$SCRIPT_PATH/h-manifest.conf"
cd "$SCRIPT_PATH"

MINER_BIN="$SCRIPT_PATH/alpha"
LOG="${CUSTOM_LOG_BASENAME:-/var/log/miner/custom/alpha}.log"

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

# Miner CUDA index must equal nvidia-smi (NVML/PCI) index for correct per-card
# stats. HiveOS exports this globally; we set it ourselves to be self-contained.
export CUDA_DEVICE_ORDER=PCI_BUS_ID

echo "========================================"
echo "$CUSTOM_NAME v$CUSTOM_VERSION  (failover supervisor, pid $$)"
echo "Pools (${#POOLS[@]}): ${POOLS[*]}"
echo "Base args: ${ALPHA_BASE_ARGS[*]}"
echo "Failover: grace=${FAILOVER_GRACE_SEC}s dead=${FAILOVER_DEAD_SEC}s return=${FAILOVER_RETURN_SEC}s"
echo "========================================"

miner_pid=""

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
}

on_stop() {
    trap - INT TERM
    echo "$(date -u +%FT%TZ) [wrapper] stop signal — shutting down miner"
    stop_miner
    exit 0
}
trap on_stop INT TERM

now() { date +%s; }

# Epoch of the most recent accepted-work line, or 0. Wide tail: during an
# attack the log fills with reconnect/candidate spam so a genuinely recent
# share can sit thousands of lines back.
last_share_epoch() {
    local ts
    ts=$(tail -n "${FAILOVER_SHARE_SCAN_LINES:-8000}" "$LOG" 2>/dev/null \
         | grep -aE 'component=share (submitted|accepted)' \
         | tail -n 1 \
         | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}')
    if [[ -n "$ts" ]]; then
        date -d "${ts}Z" +%s 2>/dev/null || echo 0
    else
        echo 0
    fi
}

n=${#POOLS[@]}
idx=0
primary_retry_at=$(( $(now) + FAILOVER_RETURN_SEC ))

while :; do
    pool="${POOLS[$idx]}"
    echo "$(date -u +%FT%TZ) [wrapper] launching miner on pool[$idx]=$pool"
    "$MINER_BIN" --pool "$pool" "${ALPHA_BASE_ARGS[@]}" &
    miner_pid=$!
    launch=$(now)
    rotate=""

    while :; do
        sleep "$FAILOVER_POLL_SEC" &
        wait $!

        if ! kill -0 "$miner_pid" 2>/dev/null; then
            wait "$miner_pid" 2>/dev/null
            echo "$(date -u +%FT%TZ) [wrapper] miner process exited on pool[$idx] — rotating"
            rotate="next"; break
        fi

        t=$(now)
        ls=$(last_share_epoch)
        (( ls < launch )) && ls=$launch

        if (( t - launch > FAILOVER_GRACE_SEC )) && (( t - ls > FAILOVER_DEAD_SEC )); then
            echo "$(date -u +%FT%TZ) [wrapper] pool[$idx]=$pool DEAD — no accepted share for $((t-ls))s (>${FAILOVER_DEAD_SEC}s); failing over"
            rotate="next"; break
        fi

        if (( idx != 0 )) && (( t >= primary_retry_at )); then
            echo "$(date -u +%FT%TZ) [wrapper] scheduled retry of primary pool[0]"
            rotate="primary"; break
        fi
    done

    stop_miner

    if [[ "$rotate" == "primary" ]]; then
        idx=0
    else
        idx=$(( (idx + 1) % n ))
    fi
    (( idx == 0 )) && primary_retry_at=$(( $(now) + FAILOVER_RETURN_SEC ))

    sleep 2
done
