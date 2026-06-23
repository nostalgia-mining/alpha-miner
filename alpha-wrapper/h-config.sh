#!/usr/bin/env bash
#
# AlphaMiner PEARL — HiveOS h-config.sh
# Translates flight-sheet variables into miner.conf
#
# HiveOS Flight Sheet setup:
#   Miner name        : alpha
#   Hash algorithm    : pearlhash
#   Wallet template   : %WAL%.%WORKER_NAME%
#   Pool URL          : stratum+tcp://%URL%      (HiveOS substitutes pool address)
#   Password          : x;d=524288               (or any difficulty value you want)
#   Extra config args : --devices 0,1  OR  --gpu 0,1   (both accepted, see below)
#                       --status-interval 30            (override miner default of 10)
#
# GPU selection: you can use either alpha-miner's native --devices flag or our
# --gpu alias — both are handled identically. --gpu is translated to --devices
# before being passed to the binary. If neither is present, all GPUs are used.
#
# Wrapper-only extra config keys (stripped, NOT forwarded to the binary):
#   --gpu 0,1,2           Alias for --devices (stripped and re-added as --devices)
#   --nostats             Suppress on-screen alpha-stats.sh display
#   FAILOVER_GRACE_SEC=N  Failover tunable
#   FAILOVER_DEAD_SEC=N
#   FAILOVER_RETURN_SEC=N
#   HSTATS_RAW_LINES=N
#   REPORT_METRIC=raw|equiv

[[ -z $SCRIPT_PATH ]] && SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f "$SCRIPT_PATH/h-manifest.conf" ]] && source "$SCRIPT_PATH/h-manifest.conf"

conf_file="${CUSTOM_CONFIG_FILENAME:-/hive/miners/custom/alpha-wrapper/miner.conf}"

# ---- Validate required inputs ------------------------------------------------
if [[ -z "${CUSTOM_TEMPLATE:-}" ]]; then
    echo "ERROR: CUSTOM_TEMPLATE (wallet) is empty" >&2
    return 1 2>/dev/null || exit 1
fi
if [[ -z "${CUSTOM_URL:-}" ]]; then
    echo "ERROR: CUSTOM_URL (pool) is empty" >&2
    return 1 2>/dev/null || exit 1
fi

# ---- Parse wallet / worker from %WAL%.%WORKER_NAME% -------------------------
wallet="${CUSTOM_TEMPLATE%%.*}"
worker="${CUSTOM_TEMPLATE#*.}"
[[ "$worker" == "$wallet" ]] && worker=""

# ---- Parse pool list (comma / whitespace / newline separated) ----------------
declare -a POOLS=()
while IFS= read -r p || [[ -n "$p" ]]; do
    p="${p//[$'\t\r ']/}"
    [[ -n "$p" ]] && POOLS+=("$p")
done < <(printf '%s' "$CUSTOM_URL" | tr ',[:space:]' '\n')

if [[ ${#POOLS[@]} -eq 0 ]]; then
    echo "ERROR: no pool URL found in CUSTOM_URL" >&2
    return 1 2>/dev/null || exit 1
fi

# ---- Split extra config into categories -------------------------------------
# We do a single-pass tokenisation so --gpu / --devices with a separate value
# token are handled correctly (e.g. "--gpu 0,1" and "--gpu=0,1" both work).

declare -a EXTRA_ARGS=()      # forwarded verbatim to alpha-miner
declare -a WRAPPER_CFG=()     # wrapper tunables written to miner.conf
WRAPPER_GPU_VAL=""            # value from --gpu alias
WRAPPER_NOSTATS=0             # set when --nostats seen

# Wrapper-only flags that must never reach the binary
WRAPPER_ONLY_FLAGS=(--gpu --nostats)

if [[ -n "${CUSTOM_USER_CONFIG:-}" ]]; then
    tokens=( $CUSTOM_USER_CONFIG )
    i=0
    while (( i < ${#tokens[@]} )); do
        tok="${tokens[$i]}"

        # ---- wrapper tunables (key=value form) -------------------------------
        if [[ "$tok" =~ ^(FAILOVER_[A-Z0-9_]+|HSTATS_RAW_LINES|REPORT_METRIC)=.+$ ]]; then
            WRAPPER_CFG+=("$tok")
            (( i++ )); continue
        fi

        # ---- --nostats -------------------------------------------------------
        if [[ "$tok" == "--nostats" ]]; then
            WRAPPER_NOSTATS=1
            (( i++ )); continue
        fi

        # ---- --gpu (our alias for --devices) ---------------------------------
        # Supports: --gpu 0,1  or  --gpu=0,1
        if [[ "$tok" == "--gpu" ]]; then
            (( i++ ))
            WRAPPER_GPU_VAL="${tokens[$i]:-}"
            (( i++ )); continue
        fi
        if [[ "$tok" =~ ^--gpu=(.+)$ ]]; then
            WRAPPER_GPU_VAL="${BASH_REMATCH[1]}"
            (( i++ )); continue
        fi

        # ---- --devices (native alpha-miner flag) -----------------------------
        # If the user passes --devices directly, extract the value for GPU_LIST
        # tracking but also keep the flag in EXTRA_ARGS for the binary.
        if [[ "$tok" == "--devices" ]]; then
            (( i++ ))
            local_val="${tokens[$i]:-}"
            # Only set WRAPPER_GPU_VAL if --gpu wasn't already used
            [[ -z "$WRAPPER_GPU_VAL" ]] && WRAPPER_GPU_VAL="$local_val"
            EXTRA_ARGS+=( "--devices" "$local_val" )
            (( i++ )); continue
        fi
        if [[ "$tok" =~ ^--devices=(.+)$ ]]; then
            local_val="${BASH_REMATCH[1]}"
            [[ -z "$WRAPPER_GPU_VAL" ]] && WRAPPER_GPU_VAL="$local_val"
            EXTRA_ARGS+=("$tok")
            (( i++ )); continue
        fi

        # ---- everything else goes to the binary ------------------------------
        EXTRA_ARGS+=("$tok")
        (( i++ ))
    done
fi

# If --gpu was used (and --devices wasn't already added), inject --devices
# with the validated value into EXTRA_ARGS.
if [[ -n "$WRAPPER_GPU_VAL" ]]; then
    # Check if --devices is already in EXTRA_ARGS (user used --devices directly)
    already_has_devices=0
    for a in "${EXTRA_ARGS[@]}"; do
        [[ "$a" == "--devices" || "$a" =~ ^--devices= ]] && already_has_devices=1 && break
    done
    if (( ! already_has_devices )); then
        EXTRA_ARGS+=( "--devices" "$WRAPPER_GPU_VAL" )
    fi
fi

# ---- Build base args for alpha-miner binary ----------------------------------
declare -a BASE_ARGS=(
    --address "$wallet"
)
[[ -n "$worker" ]] && BASE_ARGS+=( --worker "$worker" )

# Password comes from the HiveOS Password field — pass through as-is.
# The user sets whatever they want (e.g. "x;d=524288").
pass="${CUSTOM_PASS:-}"
[[ -n "$pass" ]] && BASE_ARGS+=( --password "$pass" )

BASE_ARGS+=( "${EXTRA_ARGS[@]}" )

# ---- Write miner.conf --------------------------------------------------------
{
    printf '# Generated by h-config.sh v%s — do not edit by hand\n' "$CUSTOM_VERSION"
    printf 'POOLS=('
    for p in "${POOLS[@]}"; do printf ' %q' "$p"; done
    printf ' )\n'
    printf 'ALPHA_BASE_ARGS=('
    for a in "${BASE_ARGS[@]}"; do printf ' %q' "$a"; done
    printf ' )\n'
    for kv in "${WRAPPER_CFG[@]}"; do printf '%s\n' "$kv"; done
    # GPU list for stats helper / h-run.sh GPU tracking
    printf 'WRAPPER_GPU_LIST=%q\n'  "${WRAPPER_GPU_VAL:-all}"
    printf 'WRAPPER_NOSTATS=%q\n'   "$WRAPPER_NOSTATS"
    # Human-readable
    printf 'POOL_URL=%q\n'  "${POOLS[0]}"
    printf 'WALLET=%q\n'    "$wallet"
    [[ -n "$worker" ]] && printf 'WORKER=%q\n' "$worker"
} > "$conf_file"

echo "AlphaMiner config written to $conf_file"
echo "  Pools  (${#POOLS[@]}): ${POOLS[*]}"
echo "  Base args          : ${BASE_ARGS[*]}"
echo "  GPU selection      : ${WRAPPER_GPU_VAL:-all}"
echo "  On-screen stats    : $(( ! WRAPPER_NOSTATS )) (1=enabled)"
[[ ${#WRAPPER_CFG[@]} -gt 0 ]] && echo "  Wrapper cfg        : ${WRAPPER_CFG[*]}"

return 0 2>/dev/null || exit 0
