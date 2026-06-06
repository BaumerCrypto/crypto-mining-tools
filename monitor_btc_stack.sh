#!/bin/bash
# =============================================================================
# BTC Stack Monitor — Start9 / DATUM Gateway
# =============================================================================
# Runs on: your monitoring server (Linux)
# Monitors: Start9 OS (ping), DATUM Gateway stratum (stratum probe)
# Alerts: Discord webhook
# Author: @BaumerCrypto2.0 | https://x.com/BaumerCrypto2_0 - May 2026
#
# Note: Bitcoin Knots RPC is not exposed on the LAN by Start9 — but if
#       DATUM is up, Knots is necessarily up (DATUM can't serve work without it).
#
# Note: Start9 keeps port 23334 open at the proxy layer even when DATUM is
#       stopped, so a simple TCP check is not enough. This script sends a
#       stratum mining.subscribe request and checks for a valid response.
#
# Install: crontab -e → */1 * * * * /home/ubuntu/monitor_btc_stack.sh
# =============================================================================

# --- Configuration -----------------------------------------------------------
START9_IP="YOUR_START9_IP"              # Start9 LAN IP (e.g. 192.168.0.189)
DATUM_STRATUM_PORT="23334"              # DATUM Gateway stratum port

# Discord webhook — reads from same file used by Avalon Q script
WEBHOOK_FILE="/home/ubuntu/Discord_Webhook.txt"

# State directory — tracks up/down to avoid alert spam
STATE_DIR="/home/ubuntu/.btc_monitor"
LOG_FILE="/home/ubuntu/btc_monitor.log"

# Timeouts
PING_TIMEOUT=5
STRATUM_TIMEOUT=5

# --- Setup -------------------------------------------------------------------
mkdir -p "$STATE_DIR"

# Read webhook URL
if [[ ! -f "$WEBHOOK_FILE" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Webhook file not found: $WEBHOOK_FILE" >> "$LOG_FILE"
    exit 1
fi
DISCORD_WEBHOOK=$(cat "$WEBHOOK_FILE" | tr -d '[:space:]')

# --- Functions ---------------------------------------------------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

send_discord() {
    local title="$1"
    local message="$2"
    local color="$3"  # 16711680=red, 65280=green

    curl -s -o /dev/null -X POST "$DISCORD_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"BTC Stack Monitor\",
            \"embeds\": [{
                \"title\": \"$title\",
                \"description\": \"$message\",
                \"color\": $color,
                \"footer\": {\"text\": \"BTC Stack Monitor | $(date '+%Y-%m-%d %H:%M:%S')\"}
            }]
        }"
}

check_ping() {
    ping -c 1 -W "$PING_TIMEOUT" "$START9_IP" > /dev/null 2>&1
    return $?
}

check_datum_stratum() {
    # Send a stratum mining.subscribe and check for a valid response.
    # Start9 keeps the port open even when DATUM is stopped, so a simple
    # TCP check gives false positives. A real DATUM response contains
    # "mining.notify" in the subscription result.
    local response
    response=$(echo '{"id":1,"method":"mining.subscribe","params":[]}' | timeout "$STRATUM_TIMEOUT" nc "$START9_IP" "$DATUM_STRATUM_PORT" 2>/dev/null)
    if [[ -n "$response" ]] && echo "$response" | grep -q "mining.notify"; then
        return 0
    else
        return 1
    fi
}

get_state() {
    local service="$1"
    local state_file="$STATE_DIR/$service"
    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo "up"
    fi
}

set_state() {
    local service="$1"
    local state="$2"
    echo "$state" > "$STATE_DIR/$service"
}

# --- Checks ------------------------------------------------------------------

# Check 1: Start9 OS reachable (ping)
if check_ping; then
    if [[ "$(get_state start9)" == "down" ]]; then
        log "RECOVERY: Start9 OS is reachable again"
        send_discord \
            "✅ Start9 OS — Back Online" \
            "Start9 at $START9_IP is reachable again." \
            65280
        set_state start9 "up"
    fi

    # Check 2: DATUM Gateway stratum probe (port 23334)
    if check_datum_stratum; then
        if [[ "$(get_state datum)" == "down" ]]; then
            log "RECOVERY: DATUM Gateway stratum is responding"
            send_discord \
                "✅ DATUM Gateway — Back Online" \
                "DATUM stratum on port $DATUM_STRATUM_PORT is responding.\nMiners should reconnect automatically." \
                65280
            set_state datum "up"
        fi
    else
        if [[ "$(get_state datum)" != "down" ]]; then
            log "ALERT: DATUM Gateway stratum is NOT responding on port $DATUM_STRATUM_PORT"
            send_discord \
                "🚨 DATUM Gateway — DOWN" \
                "DATUM stratum on port $DATUM_STRATUM_PORT is not responding.\n\nYour BTC miners have likely failed over to backup pools.\n\nStart9 OS is reachable. DATUM may have stopped.\n\nAction: Check Start9 dashboard." \
                16711680
            set_state datum "down"
        fi
    fi

else
    # Start9 is unreachable — everything is down
    if [[ "$(get_state start9)" != "down" ]]; then
        log "ALERT: Start9 OS at $START9_IP is UNREACHABLE"
        send_discord \
            "🚨 Start9 OS — UNREACHABLE" \
            "Cannot reach Start9 at $START9_IP.\n\nAll BTC mining is likely down:\n- Bitcoin Knots unreachable\n- DATUM Gateway unreachable\n- BTC miners have likely failed over to backup pools\n\nAction: Check physical Start9 hardware and network." \
            16711680
        set_state start9 "down"
        set_state datum "down"
    fi
fi

# --- Log rotation (keep last 1000 lines) ------------------------------------
if [[ -f "$LOG_FILE" ]] && [[ $(wc -l < "$LOG_FILE") -gt 1000 ]]; then
    tail -500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi
