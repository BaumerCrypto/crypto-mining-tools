#!/bin/bash
#=====================================================
# BTC Fleet Monitor — AxeOS Poller (no alerting)
#=====================================================
# Runs on: your monitoring server (Linux)
# Polls:   3 BTC NerdQaxe miners via AxeOS /api/system/info
# Writes:  /home/ubuntu/btc_fleet_monitor.log
# Sends:   nothing — pure data collection.
#          GSSM dashboard handles miner alerts. This script
#          exists only to feed daily_btc_fleet_summary.sh.
# Author:  @BaumerCrypto2.0 | https://x.com/BaumerCrypto2_0 - June 2026
#
# Install: chmod +x /home/ubuntu/btc_fleet_monitor.sh
#          crontab -e → */5 * * * * /home/ubuntu/btc_fleet_monitor.sh
#
# One STATUS line per miner per poll. If a miner is unreachable,
# a single STATUS|UNREACHABLE line is logged so the summary script
# can compute accurate uptime %.
#=====================================================

# --- Configuration ---

# Format: "DisplayName:IP" — display name MUST be unique per miner.
# The summary script groups by display name.
MINERS=(
    "NerdQaxe1:192.168.0.95"
    "NerdQaxe2:192.168.0.182"
    "NerdQX:192.168.0.109"
)

LOG_FILE="/home/ubuntu/btc_fleet_monitor.log"
HTTP_TIMEOUT=8  # seconds — keep tight so cron job finishes well under 5min

# Timezone — adjust to your local timezone
TZ='America/Regina'
export TZ

# --- Functions ---

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

# Safe jq extractor — returns "0" or "?" on null/missing, never empty
jq_str() {
    local json="$1"
    local path="$2"
    local default="${3:-0}"
    local v
    v=$(echo "$json" | jq -r "${path} // \"${default}\"" 2>/dev/null)
    [ -z "$v" ] || [ "$v" = "null" ] && v="$default"
    echo "$v"
}

poll_miner() {
    local name="$1"
    local ip="$2"
    local response

    response=$(curl -s --max-time "$HTTP_TIMEOUT" "http://${ip}/api/system/info" 2>/dev/null)

    if [ -z "$response" ]; then
        log_msg "STATUS | ${name} | Host:${ip} UNREACHABLE"
        return 1
    fi

    # Validate JSON before parsing
    if ! echo "$response" | jq empty 2>/dev/null; then
        log_msg "STATUS | ${name} | Host:${ip} INVALID_JSON"
        return 1
    fi

    # --- Parse fields ---
    local hash_now hash_1m hash_10m temp vr_temp power fan_pct fan_rpm
    local accepted rejected best_diff best_session uptime version
    local pool_connected stratum_url stratum_port

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
    stratum_url=$(jq_str    "$response" ".stratumURL"      "?")
    stratum_port=$(jq_str   "$response" ".stratumPort"     "?")

    # Round floats to keep log readable (power/temps come back with decimals)
    power=$(awk -v p="$power"  'BEGIN{printf "%.0f", p}')
    vr_temp=$(awk -v v="$vr_temp" 'BEGIN{printf "%.0f", v}')
    temp=$(awk -v t="$temp" 'BEGIN{printf "%.1f", t}')
    hash_now=$(awk -v h="$hash_now"  'BEGIN{printf "%.1f", h}')
    hash_1m=$(awk -v h="$hash_1m"    'BEGIN{printf "%.1f", h}')
    hash_10m=$(awk -v h="$hash_10m"  'BEGIN{printf "%.1f", h}')

    log_msg "STATUS | ${name} | Host:${ip} Hash:${hash_now}GH/s H1m:${hash_1m} H10m:${hash_10m} Temp:${temp}C VRTemp:${vr_temp}C Power:${power}W Fan:${fan_pct}% RPM:${fan_rpm} Accepted:${accepted} Rejected:${rejected} BestDiff:${best_diff} BestSession:${best_session} Uptime:${uptime} FW:${version} PoolConn:${pool_connected} Stratum:${stratum_url}:${stratum_port}"
    return 0
}

# --- Main ---

# Sanity: log file must be writable
if ! touch "$LOG_FILE" 2>/dev/null; then
    echo "ERROR: Cannot write to $LOG_FILE" >&2
    exit 1
fi

# Sanity: jq required
if ! command -v jq >/dev/null 2>&1; then
    log_msg "ERROR | jq not installed — install with: sudo apt install -y jq"
    exit 1
fi

# Poll each miner. Errors logged but don't kill the loop.
for miner_def in "${MINERS[@]}"; do
    name="${miner_def%%:*}"
    ip="${miner_def##*:}"
    poll_miner "$name" "$ip"
done

exit 0
