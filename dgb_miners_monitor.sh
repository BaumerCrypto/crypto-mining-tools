#!/bin/bash
#=====================================================
# DGB Nerd/Nano Monitor — AxeOS + Canaan Poller (no alerting)
#=====================================================
# Runs on: your monitoring server (Linux)
# Polls:   NerdQaxe3 via AxeOS    /api/system/info (HTTP 80)
#          Nano3S    via Canaan   "litestats" (TCP 4028)
# Writes:  /home/ubuntu/dgb_miners_monitor.log
# Sends:   nothing — pure data collection.
#          GSSM dashboard handles miner alerts. This script
#          exists only to feed daily_dgb_summary.sh.
# Author:  @BaumerCrypto2.0 - June 2026
#
# Install: chmod +x /home/ubuntu/dgb_miners_monitor.sh
#          crontab -e → */5 * * * * /home/ubuntu/dgb_miners_monitor.sh
#
# Log format is normalized across both miner types so the
# summary script's parser can work uniformly. Type-specific
# fields appear only for the miner type that supports them.
#=====================================================

# --- Configuration ---

# Format: "DisplayName:Type:IP"
# Type is 'axeos' (HTTP /api/system/info) or 'canaan' (TCP CGMiner litestats)
MINERS=(
    "NerdQaxe3:axeos:192.168.0.93"
    "Nano3S:canaan:192.168.0.162"
)

LOG_FILE="/home/ubuntu/dgb_miners_monitor.log"
HTTP_TIMEOUT=8           # seconds for AxeOS HTTP calls
TCP_TIMEOUT=10           # seconds for Canaan socat calls
CANAAN_API_PORT=4028     # standard CGMiner port

TZ='America/Regina'
export TZ

# --- Functions ---

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

# Safe jq extractor — returns default on null/missing/empty
jq_str() {
    local json="$1"
    local path="$2"
    local default="${3:-0}"
    local v
    v=$(echo "$json" | jq -r "${path} // \"${default}\"" 2>/dev/null)
    [ -z "$v" ] || [ "$v" = "null" ] && v="$default"
    echo "$v"
}

# Canaan field extractor — Pattern is FieldName[value] in CGMiner output
canaan_field() {
    local stats="$1"
    local field="$2"
    local default="${3:-0}"
    local v
    v=$(echo "$stats" | grep -oP "${field}\[\K[^]]+" | head -1)
    [ -z "$v" ] && v="$default"
    echo "$v"
}

# Poll an AxeOS device (Bitaxe, NerdQAxe family)
poll_axeos() {
    local name="$1"
    local ip="$2"
    local response

    response=$(curl -s --max-time "$HTTP_TIMEOUT" "http://${ip}/api/system/info" 2>/dev/null)

    if [ -z "$response" ]; then
        log_msg "STATUS | ${name} | Host:${ip} Type:axeos UNREACHABLE"
        return 1
    fi

    if ! echo "$response" | jq empty 2>/dev/null; then
        log_msg "STATUS | ${name} | Host:${ip} Type:axeos INVALID_JSON"
        return 1
    fi

    local hash_now hash_1m hash_10m temp vr_temp power fan_pct fan_rpm
    local accepted rejected best_diff best_session uptime version pool_connected

    hash_now=$(jq_str       "$response" ".hashRate"        "0")
    hash_1m=$(jq_str        "$response" ".hashRate_1m"     "0")
    hash_10m=$(jq_str       "$response" ".hashRate_10m"    "0")
    temp=$(jq_str           "$response" ".temp"            "0")
    vr_temp=$(jq_str        "$response" ".vrTemp"          "0")
    power=$(jq_str          "$response" ".power"           "0")
    fan_pct=$(jq_str        "$response" ".fanspeed"        "0")
    fan_rpm=$(jq_str        "$response" ".fanrpm"          "0")
    accepted=$(jq_str       "$response" ".sharesAccepted"  "0")
    rejected=$(jq_str       "$response" ".sharesRejected"  "0")
    best_diff=$(jq_str      "$response" ".bestDiff"        "0")
    best_session=$(jq_str   "$response" ".bestSessionDiff" "0")
    uptime=$(jq_str         "$response" ".uptimeSeconds"   "0")
    version=$(jq_str        "$response" ".version"         "?")
    pool_connected=$(jq_str "$response" ".stratum.pools[0].connected" "false")

    # Round numerics to keep log readable
    power=$(awk -v p="$power"        'BEGIN{printf "%.0f", p}')
    vr_temp=$(awk -v v="$vr_temp"    'BEGIN{printf "%.0f", v}')
    temp=$(awk -v t="$temp"          'BEGIN{printf "%.1f", t}')
    hash_now=$(awk -v h="$hash_now"  'BEGIN{printf "%.1f", h}')
    hash_1m=$(awk -v h="$hash_1m"    'BEGIN{printf "%.1f", h}')
    hash_10m=$(awk -v h="$hash_10m"  'BEGIN{printf "%.1f", h}')

    log_msg "STATUS | ${name} | Host:${ip} Type:axeos Hash:${hash_now}GH/s H1m:${hash_1m} H10m:${hash_10m} Temp:${temp}C VRTemp:${vr_temp}C Power:${power}W Fan:${fan_pct}% RPM:${fan_rpm} Accepted:${accepted} Rejected:${rejected} BestDiff:${best_diff} BestSession:${best_session} Uptime:${uptime} FW:${version} PoolConn:${pool_connected}"
    return 0
}

# Poll a Canaan CGMiner device (Avalon Nano 3S, Avalon Q)
# Uses two CGMiner commands:
#   - "stats"   for hashrate, temp, power, fan, uptime, workmode
#   - "summary" for accepted/rejected share counts + lifetime best share
# Field formats differ between commands:
#   - stats   uses bracket syntax:  FieldName[value]
#   - summary uses key=value syntax: FieldName=value,
poll_canaan() {
    local name="$1"
    local ip="$2"
    local stats summary

    stats=$(echo -n "stats" | socat -t "$TCP_TIMEOUT" stdio "tcp:${ip}:${CANAAN_API_PORT},shut-none" 2>/dev/null | cat -v)

    if [ -z "$stats" ]; then
        log_msg "STATUS | ${name} | Host:${ip} Type:canaan UNREACHABLE"
        return 1
    fi

    # Second call for shares/best — best-effort; if it fails we log "-"
    summary=$(echo -n "summary" | socat -t "$TCP_TIMEOUT" stdio "tcp:${ip}:${CANAAN_API_PORT},shut-none" 2>/dev/null | cat -v)

    local ghs_raw hash_now temp tavg power fan_pct uptime workmode
    local f1 f2 f3 f4 fan_rpm mode_name

    ghs_raw=$(canaan_field  "$stats" "GHSspd"   "0")
    temp=$(canaan_field     "$stats" "TMax"     "0")
    tavg=$(canaan_field     "$stats" "TAvg"     "0")
    power=$(canaan_field    "$stats" "MPO"      "0")
    fan_pct=$(canaan_field  "$stats" "FanR"     "0")
    # Strip trailing % — Nano3S returns FanR[15%] while Avalon Q returns FanR[15].
    # Without this strip, log would show "Fan:15%%"
    fan_pct="${fan_pct%\%}"
    uptime=$(canaan_field   "$stats" "Elapsed"  "0")
    workmode=$(canaan_field "$stats" "WORKMODE" "1")
    f1=$(canaan_field       "$stats" "Fan1"     "0")
    f2=$(canaan_field       "$stats" "Fan2"     "0")
    f3=$(canaan_field       "$stats" "Fan3"     "0")
    f4=$(canaan_field       "$stats" "Fan4"     "0")

    # RPM field: max of available fan readings
    fan_rpm=$(echo "$f1 $f2 $f3 $f4" | awk '{m=0; for(i=1;i<=NF;i++) if($i+0>m)m=$i+0; print m}')

    # Hashrate normalization: GHSspd is GH/s on Canaan devices.
    hash_now=$(awk -v h="$ghs_raw" 'BEGIN{if(h+0>0) printf "%.1f", h+0; else print "0"}')
    temp=$(awk -v t="$temp" 'BEGIN{printf "%.1f", t+0}')

    case "$workmode" in
        0) mode_name="Eco" ;;
        1) mode_name="Standard" ;;
        2) mode_name="Super" ;;
        *) mode_name="Unknown" ;;
    esac

    # Parse summary output for shares + best.
    # Format is "FieldName=value,FieldName=value,..." — different from stats' bracket syntax.
    local accepted rejected best_share
    accepted="-"
    rejected="-"
    best_share="-"
    if [ -n "$summary" ]; then
        # Extract via key=value pattern (numeric only)
        local a r b
        a=$(echo "$summary" | grep -oP 'Accepted=\K[0-9]+'    | head -1)
        r=$(echo "$summary" | grep -oP 'Rejected=\K[0-9]+'    | head -1)
        b=$(echo "$summary" | grep -oP 'Best Share=\K[0-9]+'  | head -1)
        [ -n "$a" ] && accepted="$a"
        [ -n "$r" ] && rejected="$r"
        [ -n "$b" ] && best_share="$b"
    fi

    # On Canaan devices, "Best Share" is a single lifetime counter — no session split.
    # Log BestDiff = lifetime, BestSession = - (unknown).
    # The summary parser will treat BestSession=- as "no today's best", showing — in the embed.
    log_msg "STATUS | ${name} | Host:${ip} Type:canaan Hash:${hash_now}GH/s Temp:${temp}C TAvg:${tavg}C Power:${power}W Fan:${fan_pct}% RPM:${fan_rpm} Mode:${mode_name} Uptime:${uptime} Accepted:${accepted} Rejected:${rejected} BestDiff:${best_share} BestSession:-"
    return 0
}

# --- Main ---

# Sanity: log file writable
if ! touch "$LOG_FILE" 2>/dev/null; then
    echo "ERROR: Cannot write to $LOG_FILE" >&2
    exit 1
fi

# Sanity: required tools
if ! command -v jq >/dev/null 2>&1; then
    log_msg "ERROR | jq not installed — install with: sudo apt install -y jq"
    exit 1
fi
if ! command -v socat >/dev/null 2>&1; then
    log_msg "ERROR | socat not installed — install with: sudo apt install -y socat"
    exit 1
fi

# Poll each miner. Errors logged but don't kill the loop.
for miner_def in "${MINERS[@]}"; do
    IFS=':' read -r name type ip <<< "$miner_def"
    case "$type" in
        axeos)  poll_axeos  "$name" "$ip" ;;
        canaan) poll_canaan "$name" "$ip" ;;
        *)      log_msg "ERROR | Unknown miner type '$type' for $name" ;;
    esac
done

exit 0
