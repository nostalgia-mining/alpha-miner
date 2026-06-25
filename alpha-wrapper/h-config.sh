#!/usr/bin/env bash
#
# AlphaMiner PEARL — HiveOS h-config.sh
# Translates flight-sheet variables into miner.conf
#
# HiveOS Flight Sheet setup:
#   Miner name        : alpha-wrapper
#   Hash algorithm    : pearlhash
#   Wallet template   : %WAL%.%WORKER_NAME%
#   Pool URL          : stratum+tcp://%URL%      (HiveOS substitutes pool address)
#   Password          : x                        (leave as x; use --diff for difficulty)
#   Extra config args : see below
#
# Wrapper-only extra config keys (stripped, NOT forwarded to the binary):
#   --gpu 0,1,2           Alias for --devices
#   --diff 524288         Static difficulty — single value applied to all GPUs,
#   --diff 524288,262144  or comma-separated per-GPU values.
#                         Translates to --password 'x;d=VALUE' (or appends to
#                         existing password if user also set one).
#                         If user already has d= in the Password field, --diff
#                         takes precedence.
#   --nostats             Suppress on-screen stats
#   FAILOVER_GRACE_SEC=N  Failover tunables
#   FAILOVER_DEAD_SEC=N
#   FAILOVER_RETURN_SEC=N
#   BUFFER_LINES=N        Rolling buffer size (default 10000)
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

# ---- Split extra config into categories --------------------------------------
declare -a EXTRA_ARGS=()
declare -a WRAPPER_CFG=()
WRAPPER_GPU_VAL=""
WRAPPER_NOSTATS=0
WRAPPER_DIFF_VAL=""   # value from --diff (e.g. "524288" or "524288,262144")

if [[ -n "${CUSTOM_USER_CONFIG:-}" ]]; then
    tokens=( $CUSTOM_USER_CONFIG )
    i=0
    while (( i < ${#tokens[@]} )); do
        tok="${tokens[$i]}"

        # ---- wrapper tunables (key=value form) -------------------------------
        if [[ "$tok" =~ ^(FAILOVER_[A-Z0-9_]+|HSTATS_RAW_LINES|REPORT_METRIC|BUFFER_LINES)=.+$ ]]; then
            WRAPPER_CFG+=("$tok")
            (( i++ )); continue
        fi

        # ---- --nostats -------------------------------------------------------
        if [[ "$tok" == "--nostats" ]]; then
            WRAPPER_NOSTATS=1
            (( i++ )); continue
        fi

        # ---- --diff (wrapper alias for setting difficulty) -------------------
        # --diff 524288   or   --diff=524288
        # --diff 524288,262144  (per-GPU, comma-separated)
        if [[ "$tok" == "--diff" ]]; then
            (( i++ ))
            WRAPPER_DIFF_VAL="${tokens[$i]:-}"
            (( i++ )); continue
        fi
        if [[ "$tok" =~ ^--diff=(.+)$ ]]; then
            WRAPPER_DIFF_VAL="${BASH_REMATCH[1]}"
            (( i++ )); continue
        fi

        # ---- --gpu (alias for --devices) ------------------------------------
        if [[ "$tok" == "--gpu" ]]; then
            (( i++ ))
            WRAPPER_GPU_VAL="${tokens[$i]:-}"
            (( i++ )); continue
        fi
        if [[ "$tok" =~ ^--gpu=(.+)$ ]]; then
            WRAPPER_GPU_VAL="${BASH_REMATCH[1]}"
            (( i++ )); continue
        fi

        # ---- --devices (native flag, also track for GPU_LIST) ---------------
        if [[ "$tok" == "--devices" ]]; then
            (( i++ ))
            local_val="${tokens[$i]:-}"
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

# Inject --devices if --gpu was used and --devices isn't already in EXTRA_ARGS
if [[ -n "$WRAPPER_GPU_VAL" ]]; then
    already_has_devices=0
    for a in "${EXTRA_ARGS[@]}"; do
        [[ "$a" == "--devices" || "$a" =~ ^--devices= ]] && already_has_devices=1 && break
    done
    (( ! already_has_devices )) && EXTRA_ARGS+=( "--devices" "$WRAPPER_GPU_VAL" )
fi

# ---- Build base args for alpha-miner binary ----------------------------------
# --status-interval 1 : required for accurate per-attempt ping calculation
# --debug-log         : required for component=pool job lines (job detection +
#                       per-GPU difficulty parsing)
declare -a BASE_ARGS=(
    --address "$wallet"
    --status-interval 1
    --debug-log
)
[[ -n "$worker" ]] && BASE_ARGS+=( --worker "$worker" )

# ---- Password / difficulty ---------------------------------------------------
# Priority: --diff extra config arg > Password field
# --diff 524288            → --password 'x;d=524288'
# --diff 524288,262144     → --password 'x;d=524288,262144'  (alpha-miner per-GPU syntax)
# Password field set       → passed through as-is
# Neither                  → no --password arg (vardiff)
pass="${CUSTOM_PASS:-}"

if [[ -n "$WRAPPER_DIFF_VAL" ]]; then
    # --diff takes precedence; build password string
    pass="x;d=${WRAPPER_DIFF_VAL}"
    echo "  Difficulty (--diff): $WRAPPER_DIFF_VAL → --password '$pass'"
fi

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
    printf 'WRAPPER_GPU_LIST=%q\n'  "${WRAPPER_GPU_VAL:-all}"
    printf 'WRAPPER_NOSTATS=%q\n'   "$WRAPPER_NOSTATS"
    printf 'WRAPPER_PASSWORD=%q\n'  "$pass"
    printf 'POOL_URL=%q\n'          "${POOLS[0]}"
    printf 'WALLET=%q\n'            "$wallet"
    [[ -n "$worker" ]] && printf 'WORKER=%q\n' "$worker"
} > "$conf_file"

echo "AlphaMiner config written to $conf_file"
echo "  Pools  (${#POOLS[@]}): ${POOLS[*]}"
echo "  Base args          : ${BASE_ARGS[*]}"
echo "  GPU selection      : ${WRAPPER_GPU_VAL:-all}"
echo "  On-screen stats    : $(( ! WRAPPER_NOSTATS )) (1=enabled)"
[[ ${#WRAPPER_CFG[@]} -gt 0 ]] && echo "  Wrapper cfg        : ${WRAPPER_CFG[*]}"

return 0 2>/dev/null || exit 0
