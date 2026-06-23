#!/usr/bin/env bash
#
# AlphaMiner PEARL — HiveOS h-run.sh
#
# Thin launcher: reads miner.conf, resolves active GPU list for stats,
# optionally starts the on-screen stats helper, then exec's alpha-supervise.sh
# so "h-run.sh" never stays in the long-lived process argv (HiveOS contract).

SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f "$SCRIPT_PATH/h-manifest.conf" ]] && source "$SCRIPT_PATH/h-manifest.conf"

LOG="${CUSTOM_LOG_BASENAME:-/var/log/miner/custom/alpha-wrapper}.log"
GPU_LIST_FILE="/var/run/hive/alpha-wrapper_gpus.conf"
STATS_HELPER="$SCRIPT_PATH/alpha-stats.sh"
STATS_PIDFILE="/var/run/hive/alpha-wrapper_stats.pid"

mkdir -p "$(dirname "$LOG")" 2>/dev/null
mkdir -p /var/run/hive 2>/dev/null

# Route stdout/stderr to log + screen from here on
exec > >(exec tee -a "$LOG") 2>&1

echo "--------------------------------------------------------------------"
echo "AlphaMiner PEARL v${CUSTOM_VERSION} — HiveOS Wrapper"
echo "--------------------------------------------------------------------"

# ============================================================================
# Read miner.conf (written by h-config.sh)
# ============================================================================
if [[ ! -f "$SCRIPT_PATH/miner.conf" ]]; then
    echo -e "\e[31m[$(date +'%H:%M:%S')] [FATAL] miner.conf not found — run h-config.sh first\e[0m"
    exit 1
fi
source "$SCRIPT_PATH/miner.conf"

# ============================================================================
# Resolve actual GPU list for the stats helper
# WRAPPER_GPU_LIST is set by h-config.sh:
#   "all"       → no --devices/--gpu arg → use every GPU
#   "0,1,2"     → explicit selection
# ============================================================================
GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
if [[ "$GPU_COUNT" -eq 0 ]]; then
    echo -e "\e[31m[$(date +'%H:%M:%S')] [FATAL] No NVIDIA GPUs detected. Aborting.\e[0m"
    exit 1
fi

if [[ "${WRAPPER_GPU_LIST:-all}" == "all" ]]; then
    GPU_LIST=$(seq -s, 0 $((GPU_COUNT - 1)))
    echo -e "\e[32m[$(date +'%H:%M:%S')] [INFO] No GPU filter → using all GPUs: $GPU_LIST\e[0m"
else
    # Validate each requested index
    VALIDATED=""
    IFS=',' read -ra REQ <<< "$WRAPPER_GPU_LIST"
    for g in "${REQ[@]}"; do
        if (( g >= GPU_COUNT )); then
            echo -e "\e[33m[$(date +'%H:%M:%S')] [WARN] GPU $g out of range (max $((GPU_COUNT-1))) — skipped\e[0m"
        else
            [[ -z "$VALIDATED" ]] && VALIDATED="$g" || VALIDATED="$VALIDATED,$g"
        fi
    done
    if [[ -z "$VALIDATED" ]]; then
        echo -e "\e[31m[$(date +'%H:%M:%S')] [FATAL] All requested GPUs invalid. Aborting.\e[0m"
        exit 1
    fi
    GPU_LIST="$VALIDATED"
    echo -e "\e[32m[$(date +'%H:%M:%S')] [INFO] GPU selection: $GPU_LIST\e[0m"
fi

echo "$GPU_LIST" > "$GPU_LIST_FILE"

# alpha-miner uses --devices for its own GPU selection (already in BASE_ARGS
# from h-config.sh). We set CUDA_DEVICE_ORDER so miner index == nvidia-smi index.
export CUDA_DEVICE_ORDER=PCI_BUS_ID

# ============================================================================
# On-screen stats helper
# ============================================================================
ENABLE_STATS=$(( ! ${WRAPPER_NOSTATS:-0} ))

if [[ "$ENABLE_STATS" == "1" && -x "$STATS_HELPER" ]]; then
    if ! { [[ -f "$STATS_PIDFILE" ]] && kill -0 "$(cat "$STATS_PIDFILE")" 2>/dev/null; }; then
        LOG_FILE="$LOG" \
        GPU_LIST="$GPU_LIST" \
        WALLET="${WALLET:-unknown}" \
            "$STATS_HELPER" &
        echo $! > "$STATS_PIDFILE"
        echo -e "\e[32m[$(date +'%H:%M:%S')] [INFO] On-screen stats helper started (PID $!)\e[0m"
    fi
else
    echo -e "\e[32m[$(date +'%H:%M:%S')] [INFO] On-screen stats helper disabled (--nostats)\e[0m"
fi

# ============================================================================
# Hand off to supervisor (keeps h-run.sh out of long-lived argv)
# ============================================================================
SUP="$SCRIPT_PATH/alpha-supervise.sh"
if [[ ! -f "$SUP" ]]; then
    echo -e "\e[31m[$(date +'%H:%M:%S')] [FATAL] Supervisor not found: $SUP\e[0m"
    exit 1
fi

echo -e "\e[32m[$(date +'%H:%M:%S')] [INFO] Starting supervisor → $SUP\e[0m"
exec bash "$SUP"
