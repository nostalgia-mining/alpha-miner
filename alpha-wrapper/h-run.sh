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
touch "$BUFFER_FILE"    2>/dev/null

# Wrapper's own startup messages go to screen and persistent log (ANSI stripped for log)
exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG")) 2>&1

echo "--------------------------------------------------------------------"
echo "AlphaMiner PEARL v${CUSTOM_VERSION} -- HiveOS Wrapper"
echo "--------------------------------------------------------------------"

# ============================================================================
# Read miner.conf (written by h-config.sh on each HiveOS start)
# ============================================================================
if [[ ! -f "$SCRIPT_PATH/miner.conf" ]]; then
    echo "[$(date +'%H:%M:%S')] [FATAL] miner.conf not found -- run h-config.sh first"
    exit 1
fi
source "$SCRIPT_PATH/miner.conf"

# ============================================================================
# GPU selection
# ============================================================================
GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
if [[ "$GPU_COUNT" -eq 0 ]]; then
    echo "[$(date +'%H:%M:%S')] [FATAL] No NVIDIA GPUs detected. Aborting."
    exit 1
fi

if [[ "${WRAPPER_GPU_LIST:-all}" == "all" ]]; then
    GPU_LIST=$(seq -s, 0 $((GPU_COUNT - 1)))
    echo "[$(date +'%H:%M:%S')] [INFO]  No GPU filter -- using all GPUs: $GPU_LIST"
else
    VALIDATED=""
    IFS=',' read -ra REQ <<< "$WRAPPER_GPU_LIST"
    for g in "${REQ[@]}"; do
        if (( g >= GPU_COUNT )); then
            echo "[$(date +'%H:%M:%S')] [WARN]  GPU $g out of range (max $((GPU_COUNT-1))) -- skipped"
        else
            [[ -z "$VALIDATED" ]] && VALIDATED="$g" || VALIDATED="$VALIDATED,$g"
        fi
    done
    if [[ -z "$VALIDATED" ]]; then
        echo "[$(date +'%H:%M:%S')] [FATAL] All requested GPUs invalid. Aborting."
        exit 1
    fi
    GPU_LIST="$VALIDATED"
    echo "[$(date +'%H:%M:%S')] [INFO]  GPU selection: $GPU_LIST"
fi

echo "$GPU_LIST" > "$GPU_LIST_FILE"
export CUDA_DEVICE_ORDER=PCI_BUS_ID

# ============================================================================
# --extralogs: symlink the RAM buffer to an accessible log path so you can
# tail it from HiveOS or a shell for debugging.
# Access via: tail -f /var/log/miner/custom/alpha-wrapper-raw.log
# ============================================================================
RAW_LOG="/var/log/miner/custom/alpha-wrapper-raw.log"
if [[ "${WRAPPER_EXTRALOGS:-0}" == "1" ]]; then
    ln -sf "$BUFFER_FILE" "$RAW_LOG" 2>/dev/null
    echo "[$(date +'%H:%M:%S')] [INFO]  Extra logs enabled → tail -f $RAW_LOG"
else
    rm -f "$RAW_LOG" 2>/dev/null
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
    [[ -x "$script" ]] || { echo "[$(date +'%H:%M:%S')] [WARN]  $label not executable: $script"; return; }
    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        return  # already running
    fi
    BUFFER_FILE="$BUFFER_FILE" \
    LOG_FILE="$LOG" \
    GPU_LIST="$GPU_LIST" \
    WALLET="${WALLET:-unknown}" \
    POOL_HOST="$POOL_HOST" \
        "$script" &
    echo $! > "$pidfile"
    echo "[$(date +'%H:%M:%S')] [INFO]  $label started (PID $!)"
}

if [[ "$ENABLE_STATS" == "1" ]]; then
    _launch "$EVENTS_SCRIPT" "$EVENTS_PIDFILE" "Event printer"
    _launch "$STATS_SCRIPT"  "$STATS_PIDFILE"  "Stats table"
else
    echo "[$(date +'%H:%M:%S')] [INFO]  On-screen output disabled (--nostats)"
fi

# ============================================================================
# Hand off to supervisor (exec so h-run.sh leaves process table)
# ============================================================================
SUP="$SCRIPT_PATH/alpha-supervise.sh"
if [[ ! -f "$SUP" ]]; then
    echo "[$(date +'%H:%M:%S')] [FATAL] Supervisor not found: $SUP"
    exit 1
fi

echo "[$(date +'%H:%M:%S')] [INFO]  Starting supervisor"
exec bash "$SUP"
