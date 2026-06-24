#!/usr/bin/env bash
#
# alpha-events.sh — real-time event printer for alpha-wrapper
#
# Tails the rolling buffer, filters and pretty-prints:
#   - Pool connection / reconnection events
#   - Difficulty set
#   - New job (block change)
#   - Share accepted (with ping)
#   - Share rejected
#
# Launched by h-run.sh as a background process.
# Env vars injected:
#   BUFFER_FILE   — path to rolling buffer (/run/alpha-wrapper/miner-raw.buf)
#   GPU_LIST      — comma-separated active CUDA indices
#   GPU_DIFFS     — comma-separated per-GPU difficulties (from password field)
set -u

BUFFER_FILE="${BUFFER_FILE:-/run/alpha-wrapper/miner-raw.buf}"
GPU_LIST="${GPU_LIST:-0}"
GPU_DIFFS="${GPU_DIFFS:-524288}"  # comma-separated, one per GPU, or single for all

# ===== Colors =================================================================
green=$'\e[32m'
yellow=$'\e[33m'
cyan=$'\e[36m'
red=$'\e[31m'
white=$'\e[97m'
reset=$'\e[0m'
bold=$'\e[1m'

# ===== Per-GPU difficulty lookup ==============================================
# GPU_DIFFS="524288" or "524288,262144" for multiple GPUs
declare -A GPU_DIFF_MAP
IFS=',' read -ra _diffs <<< "$GPU_DIFFS"
IFS=',' read -ra _gpus  <<< "$GPU_LIST"
for i in "${!_gpus[@]}"; do
    gidx="${_gpus[$i]}"
    # If only one diff provided, use it for all GPUs
    if (( i < ${#_diffs[@]} )); then
        GPU_DIFF_MAP[$gidx]="${_diffs[$i]}"
    else
        GPU_DIFF_MAP[$gidx]="${_diffs[0]}"
    fi
done

# ===== State tracking =========================================================
# Per-GPU: last hits count (to detect submission) and its timestamp
declare -A LAST_HITS_COUNT
declare -A LAST_HITS_TS
declare -A GPU_ACCEPTED
declare -A GPU_REJECTED
declare -A GPU_NAMES
LAST_JOB_ID=""

# Extract millisecond-precision epoch from ISO timestamp
# Input:  2026-06-24T09:03:27.027Z
# Output: epoch in milliseconds (integer)
ts_to_ms() {
    local ts="$1"
    # Strip sub-second and Z, parse seconds
    local sec_part="${ts%.*}"     # 2026-06-24T09:03:27
    local ms_part="${ts##*.}"     # 027Z
    ms_part="${ms_part%Z}"        # 027
    # Pad/trim to 3 digits
    ms_part="${ms_part:0:3}"
    while (( ${#ms_part} < 3 )); do ms_part="${ms_part}0"; done
    local epoch_s
    epoch_s=$(date -d "${sec_part}Z" +%s 2>/dev/null) || epoch_s=0
    echo $(( epoch_s * 1000 + 10#$ms_part ))
}

# Format a GPU label: "GPU N" from gpu=N:Name
gpu_label() {
    local raw="$1"   # e.g. "0:NVIDIA GeForce RTX 4070 Ti SUPER"
    local idx="${raw%%:*}"
    echo "GPU $idx"
}

# Short GPU name (strip "NVIDIA GeForce ")
gpu_short_name() {
    local raw="$1"
    local name="${raw#*:}"
    name="${name/NVIDIA GeForce /}"
    name="${name/NVIDIA /}"
    echo "$name"
}

# ===== Wait for buffer ========================================================
while [[ ! -f "$BUFFER_FILE" ]]; do sleep 1; done

# ===== Main tail loop =========================================================
# Use tail -F (follow by name, handles rotation) and process line by line

tail -F "$BUFFER_FILE" 2>/dev/null | while IFS= read -r line; do

    # Skip empty lines
    [[ -z "$line" ]] && continue

    # Extract timestamp (first field)
    ts="${line%% *}"

    # Extract gpu field: gpu=0:NVIDIA GeForce RTX 4070 Ti SUPER
    gpu_raw=""
    if [[ "$line" =~ gpu=([^[:space:]]+) ]]; then
        gpu_raw="${BASH_REMATCH[1]}"
    fi
    gpu_idx="${gpu_raw%%:*}"

    # Extract component
    component=""
    if [[ "$line" =~ component=([^[:space:]]+) ]]; then
        component="${BASH_REMATCH[1]}"
    fi

    # =========================================================================
    # POOL EVENTS
    # =========================================================================
    if [[ "$component" == "pool" ]]; then

        # Pool connected
        if [[ "$line" =~ "event=connected" ]] || [[ "$line" =~ " connected " && "$line" =~ "host=" ]]; then
            host=""
            port=""
            [[ "$line" =~ host=([^[:space:]]+) ]] && host="${BASH_REMATCH[1]}"
            [[ "$line" =~ port=([^[:space:]]+) ]] && port="${BASH_REMATCH[1]}"
            printf "${green}[%s] ${cyan}◉ Pool connected${reset}  →  %s:%s\n" \
                "$(date +'%H:%M:%S')" "$host" "$port"

        # Pool disconnected / error
        elif [[ "$line" =~ "disconnected" ]] || [[ "$line" =~ "error" && "$line" =~ "component=pool" ]]; then
            printf "${red}[%s] ✗ Pool disconnected${reset}\n" "$(date +'%H:%M:%S')"

        # Difficulty set by pool
        elif [[ "$line" =~ "difficulty_set" ]]; then
            diff=""
            [[ "$line" =~ difficulty=([^[:space:]]+) ]] && diff="${BASH_REMATCH[1]}"
            # Format: remove .00 suffix if present
            diff="${diff%.00}"
            printf "${yellow}[%s] ⚡ Difficulty set: %s${reset}\n" \
                "$(date +'%H:%M:%S')" "$diff"
        fi

    # =========================================================================
    # JOB CHANGE (DEBUG level)
    # =========================================================================
    elif [[ "$component" == "pool" ]] || [[ "$line" =~ "component=pool job" ]]; then
        if [[ "$line" =~ "component=pool job" ]]; then
            job_id=""
            generation=""
            diff=""
            [[ "$line" =~ " id=([^[:space:]]+)" ]]         && job_id="${BASH_REMATCH[1]}"
            [[ "$line" =~ " generation=([^[:space:]]+)" ]]  && generation="${BASH_REMATCH[1]}"
            [[ "$line" =~ " difficulty=([^[:space:]]+)" ]]  && diff="${BASH_REMATCH[1]}"
            diff="${diff%.00}"
            if [[ -n "$job_id" && "$job_id" != "$LAST_JOB_ID" ]]; then
                LAST_JOB_ID="$job_id"
                short_id="${job_id:0:8}…${job_id: -8}"
                printf "${white}${bold}[%s] ▶ New Job  id=%-20s  gen=%-4s  diff=%s${reset}\n" \
                    "$(date +'%H:%M:%S')" "$short_id" "$generation" "$diff"
            fi
        fi

    # =========================================================================
    # MINER STATUS — track hits count for ping calculation
    # =========================================================================
    elif [[ "$component" == "miner" ]] && [[ "$line" =~ " status " ]]; then
        hits=0
        [[ "$line" =~ " hits=([0-9]+)" ]] && hits="${BASH_REMATCH[1]}"
        prev_hits="${LAST_HITS_COUNT[$gpu_idx]:-0}"
        if (( hits > prev_hits )); then
            # hits incremented → candidate submitted at this timestamp
            LAST_HITS_TS[$gpu_idx]="$(ts_to_ms "$ts")"
            LAST_HITS_COUNT[$gpu_idx]="$hits"
        fi

    # =========================================================================
    # SHARE ACCEPTED
    # =========================================================================
    elif [[ "$component" == "share" ]] && [[ "$line" =~ "accepted" ]]; then
        job_id=""
        [[ "$line" =~ " job=([^[:space:]]+)" ]] && job_id="${BASH_REMATCH[1]}"

        # Ping = accepted_ts - last_hits_ts for this GPU
        accepted_ms="$(ts_to_ms "$ts")"
        ping_ms=0
        if [[ -n "${LAST_HITS_TS[$gpu_idx]:-}" ]]; then
            ping_ms=$(( accepted_ms - LAST_HITS_TS[$gpu_idx] ))
            # Sanity: if negative or > 60s, discard (timestamp parsing issue)
            (( ping_ms < 0 || ping_ms > 60000 )) && ping_ms=0
        fi

        # Increment per-GPU accepted counter
        GPU_ACCEPTED[$gpu_idx]=$(( ${GPU_ACCEPTED[$gpu_idx]:-0} + 1 ))
        acc="${GPU_ACCEPTED[$gpu_idx]}"
        rej="${GPU_REJECTED[$gpu_idx]:-0}"

        # Difficulty for this GPU
        diff="${GPU_DIFF_MAP[$gpu_idx]:-524288}"

        # Short job id
        short_job="${job_id:0:8}"

        if (( ping_ms > 0 )); then
            printf "${green}[%s] ✓ GPU %-2s  Share accepted  ping=%4d ms  diff=%-8s  job=%s  [%d/%d]${reset}\n" \
                "$(date +'%H:%M:%S')" "$gpu_idx" "$ping_ms" "$diff" "$short_job" "$acc" "$rej"
        else
            printf "${green}[%s] ✓ GPU %-2s  Share accepted                diff=%-8s  job=%s  [%d/%d]${reset}\n" \
                "$(date +'%H:%M:%S')" "$gpu_idx" "$diff" "$short_job" "$acc" "$rej"
        fi

    # =========================================================================
    # SHARE REJECTED
    # =========================================================================
    elif [[ "$component" == "share" ]] && [[ "$line" =~ "rejected" ]]; then
        GPU_REJECTED[$gpu_idx]=$(( ${GPU_REJECTED[$gpu_idx]:-0} + 1 ))
        acc="${GPU_ACCEPTED[$gpu_idx]:-0}"
        rej="${GPU_REJECTED[$gpu_idx]}"
        diff="${GPU_DIFF_MAP[$gpu_idx]:-524288}"
        printf "${red}[%s] ✗ GPU %-2s  Share REJECTED              diff=%-8s              [%d/%d]${reset}\n" \
            "$(date +'%H:%M:%S')" "$gpu_idx" "$diff" "$acc" "$rej"

    fi

done
