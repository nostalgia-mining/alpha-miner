#!/usr/bin/env bash
#
# AlphaMiner PEARL -- HiveOS h-run.sh
#
# Validates GPU selection, sets up the rolling buffer, launches the
# real-time event printer and stats table helper, then exec's the supervisor.
# h-run.sh never stays as the long-lived process (HiveOS contract).

SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f "$SCRIPT_PATH/h-manifest.conf" ]] && source "$SCRIPT_PATH/h-manifest.conf"

LOG="${CUSTOM_LOG_BASENAME:-/var/log/miner/custom/alpha-wrapper}.log"
GPU_LIST_FILE="/var/run/hive/alpha-wrapper_gpus.conf"

EVENTS_SCRIPT="$SCRIPT_PATH/alpha-events.sh"
STATS_SCRIPT="$SCRIPT_PATH/alpha-stats.sh"
EVENTS_PIDFILE="/var/run/hive/alpha-wrapper_events.pid"
STATS_PIDFILE="/var/run/hive/alpha-wrapper_stats.pid"

# Rolling buffer -- in /run (tmpfs, RAM only, not persisted across reboots)
BUFFER_DIR="/run/alpha-wrapper"
BUFFER_FILE="$BUFFER_DIR/miner-raw.buf"

mkdir -p "$(dirname "$LOG")" 2>/dev/null
mkdir -p /var/run/hive 2>/dev/null
mkdir -p "$BUFFER_DIR"  2>/dev/null

# Clear buffer and sidecar from any previous session before helpers start
> "$BUFFER_FILE"
> "$BUFFER_DIR/events.log"

# Wrapper's own startup messages go to screen and persistent log
exec > >(exec tee -a "$LOG") 2>&1

# Timestamp helper
_ts() { echo "[$(date +'%Y-%m-%d %H:%M:%S')]"; }

echo "--------------------------------------------------------------------"
echo "AlphaMiner PEARL v${CUSTOM_VERSION} -- HiveOS Wrapper by nostalgia"
echo "--------------------------------------------------------------------"

# ============================================================================
# Read miner.conf (written by h-config.sh on each HiveOS start)
# ============================================================================
if [[ ! -f "$SCRIPT_PATH/miner.conf" ]]; then
    echo "$(_ts) [FATAL] miner.conf not found -- run h-config.sh first"
    exit 1
fi
source "$SCRIPT_PATH/miner.conf"

# ============================================================================
# GPU selection
# ============================================================================
GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
if [[ "$GPU_COUNT" -eq 0 ]]; then
    echo "$(_ts) [FATAL] No NVIDIA GPUs detected. Aborting."
    exit 1
fi

if [[ "${WRAPPER_GPU_LIST:-all}" == "all" ]]; then
    GPU_LIST=$(seq -s, 0 $((GPU_COUNT - 1)))
    echo "$(_ts) [INFO] No GPU filter -- using all GPUs: $GPU_LIST"
else
    VALIDATED=""
    IFS=',' read -ra REQ <<< "$WRAPPER_GPU_LIST"
    for g in "${REQ[@]}"; do
        if (( g >= GPU_COUNT )); then
            echo "$(_ts) [WARN] GPU $g out of range (max $((GPU_COUNT-1))) -- skipped"
        else
            [[ -z "$VALIDATED" ]] && VALIDATED="$g" || VALIDATED="$VALIDATED,$g"
        fi
    done
    if [[ -z "$VALIDATED" ]]; then
        echo "$(_ts) [FATAL] All requested GPUs invalid. Aborting."
        exit 1
    fi
    GPU_LIST="$VALIDATED"
    echo "$(_ts) [INFO] GPU selection: $GPU_LIST"
fi

echo "$GPU_LIST" > "$GPU_LIST_FILE"
export CUDA_DEVICE_ORDER=PCI_BUS_ID

# ============================================================================
# --extralogs: write all raw miner output to a persistent log file on disk.
# Rotates at ~200 MB: current .log + previous .log.1 (max ~400 MB on disk).
# Access via: tail -f /var/log/miner/custom/alpha-wrapper-raw.log
# ============================================================================
RAW_LOG="/var/log/miner/custom/alpha-wrapper-raw.log"
RAW_HEAD_LOG="/var/log/miner/custom/alpha-wrapper-raw-head.log"
if [[ "${WRAPPER_EXTRALOGS:-0}" == "1" ]]; then
    # Rotate previous log and start fresh
    [[ -f "$RAW_LOG" ]] && mv -f "$RAW_LOG" "${RAW_LOG}.1" 2>/dev/null
    > "$RAW_LOG"
    ln -sf "$BUFFER_DIR/miner-raw-head.buf" "$RAW_HEAD_LOG" 2>/dev/null
    echo "$(_ts) [INFO] Extra logs enabled"
    echo "$(_ts) [INFO] Raw log: tail -f $RAW_LOG"
    echo "$(_ts) [INFO] Head: cat $RAW_HEAD_LOG"
else
    rm -f "$RAW_LOG" "${RAW_LOG}.1" "$RAW_HEAD_LOG" 2>/dev/null
fi

# ============================================================================
# Pool host for display (first pool, strip stratum+tcp:// prefix)
# ============================================================================
POOL_HOST="${POOLS[0]:-alphapool.tech:5566}"
POOL_HOST="${POOL_HOST#stratum+tcp://}"

# ============================================================================
# Launch on-screen helpers (event printer + stats table)
# Both receive BUFFER_FILE, LOG_FILE, GPU_LIST, WALLET, POOL_HOST
# ============================================================================
ENABLE_STATS=$(( ! ${WRAPPER_NOSTATS:-0} ))

_launch() {
    local script="$1" pidfile="$2" label="$3"
    [[ -x "$script" ]] || { echo "$(_ts) [WARN] $label not executable: $script"; return; }
    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        return  # already running
    fi
    BUFFER_FILE="$BUFFER_FILE" \
    LOG_FILE="$LOG" \
    GPU_LIST="$GPU_LIST" \
    WALLET="${WALLET:-unknown}" \
    POOL_HOST="$POOL_HOST" \
    WRAPPER_DETAIL="${WRAPPER_DETAIL:-0}" \
        "$script" &
    echo $! > "$pidfile"
    echo "$(_ts) [INFO] $label started (PID $!)"
}

if [[ "$ENABLE_STATS" == "1" ]]; then
    _launch "$EVENTS_SCRIPT" "$EVENTS_PIDFILE" "Event printer"
    _launch "$STATS_SCRIPT"  "$STATS_PIDFILE"  "Stats table"
else
    echo "$(_ts) [INFO] On-screen output disabled (--nostats)"
fi

# ============================================================================
# Hand off to supervisor (exec so h-run.sh leaves process table)
# ============================================================================
SUP="$SCRIPT_PATH/alpha-supervise.sh"
if [[ ! -f "$SUP" ]]; then
    echo "$(_ts) [FATAL] Supervisor not found: $SUP"
    exit 1
fi

echo "$(_ts) [INFO] Starting supervisor"
exec bash "$SUP"
