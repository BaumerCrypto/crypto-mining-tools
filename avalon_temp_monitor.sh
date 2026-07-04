#!/bin/bash
#=====================================================
# Avalon Q Temperature Monitor & Auto-Switch Script
# Runs on: your monitoring server (Linux)
# Monitors: Avalon Q via CGMiner API
# Author: @BaumerCrypto2.0 | https://x.com/BaumerCrypto2_0 - July 2026
# Updated: May 28, 2026
#   - Added fan error detection (FanErr, individual RPMs)
#   - Added hardware health checks (ECHU, ECMM, CRC, BOOTBY)
#   - Added crash detection (0 hashrate for 2+ polls)
#   - Added Discord webhook alerting
#   - All API commands verified per Canaan docs:
#     workmode: ascset|0,workmode,set,N (instant, no reboot)
#     softoff:  ascset|0,softoff,1:<timestamp> (5s delay)
#     softon:   ascset|0,softon,1:<timestamp> (5s delay)
#     fan-spd:  ascset|0,fan-spd,N (15-100, -1 for auto)
#     Emergency: Eco first, then softoff as last resort
# Updated: July 3, 2026
#   - Alert gating: persistent conditions (unreachable, crash, fan_err,
#     dead_fan, echu, ecmm) alert once on transition, re-alert hourly
#     while still down. State files at ~/.avalon_alerts/.
#   - Recovery ✅ notifications sent when conditions clear.
#   - Discord webhook: --max-time 10 + HTTP status logging on failure.
#   - Mode-switch/emergency/BOOTBY alerts unchanged (state-change by nature).
#=====================================================

# --- Configuration ---
AVALON_IP="YOUR_MINER_IP"         # Avalon Q LAN IP (e.g. 192.168.0.116)
API_PORT="4028"                    # CGMiner API port (default 4028)
LOG_FILE="/home/ubuntu/avalon_monitor.log"
LOCKOUT_FILE="/home/ubuntu/.avalon_eco_lockout"
SOFTOFF_FILE="/home/ubuntu/.avalon_softoff"
CRASH_FILE="/home/ubuntu/.avalon_crash_count"

# Alert state tracking — prevents duplicate alerts on persistent conditions
ALERT_STATE_DIR="/home/ubuntu/.avalon_alerts"
ALERT_REALERT_SECONDS=3600  # Re-alert every hour while a condition persists
mkdir -p "$ALERT_STATE_DIR" 2>/dev/null

# Discord webhook for alerts
WEBHOOK_FILE="/home/ubuntu/Discord_Webhook.txt"
DISCORD_WEBHOOK=$(cat "$WEBHOOK_FILE" 2>/dev/null | tr -d '[:space:]')

# Timezone — adjust to your local timezone
TZ='America/Regina'
export TZ

# Temperature thresholds (TMax - hottest ASIC chip)
TEMP_ECO=93        # Switch to Eco mode at this temp
TEMP_SHUTDOWN=97   # Emergency: Eco first, then softoff if still hot
TEMP_RECOVER=78    # Switch back to Standard when cooled below this

# Cooldown lockout (seconds) - must stay in Eco for this long
# before switching back to Standard (5 hours = 18000 seconds)
LOCKOUT_SECONDS=18000

# Crash detection - how many consecutive 0-hashrate polls before alerting
CRASH_THRESHOLD=2

# Work modes (Avalon Q API format: ascset|0,workmode,set,N)
# 0 = Eco / Low (~54.5 TH/s @ 800W)
# 1 = Standard / Medium (~81-85 TH/s @ 1300W)
# 2 = Super / High (~100 TH/s @ 1600W)

# --- Functions ---

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

# Send Discord webhook with --max-time and HTTP status capture.
# Non-2xx responses are logged as WARN so failures don't happen silently.
send_discord() {
    local message="$1"
    if [ -z "$DISCORD_WEBHOOK" ]; then
        log_msg "WARN | Discord webhook empty — cannot send: ${message}"
        return 1
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time 10 \
        -H "Content-Type: application/json" \
        -X POST \
        -d "{\"content\":\"⚠️ **Avalon Q Alert** ($(date '+%Y-%m-%d %H:%M'))\\n${message}\"}" \
        "$DISCORD_WEBHOOK" 2>/dev/null)

    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        return 0
    else
        # Truncate message to keep log lines readable
        log_msg "WARN | Discord webhook failed HTTP=${http_code} — ${message:0:100}"
        return 1
    fi
}

# Alert gating — returns 0 (yes, send alert) if:
#   - No state file exists for this condition (transition into alert), OR
#   - State file exists but last alert was >= ALERT_REALERT_SECONDS ago
# Returns 1 (skip) otherwise.
# On "yes", writes current timestamp to the state file so the next call
# within the re-alert window will be suppressed.
should_alert() {
    local condition="$1"
    local state_file="${ALERT_STATE_DIR}/${condition}"
    local now
    now=$(date +%s)

    if [ ! -f "$state_file" ]; then
        echo "$now" > "$state_file"
        return 0
    fi

    local last_alert
    last_alert=$(cat "$state_file" 2>/dev/null)
    if [ -z "$last_alert" ] || ! [[ "$last_alert" =~ ^[0-9]+$ ]]; then
        # Corrupt state file — treat as transition
        echo "$now" > "$state_file"
        return 0
    fi

    local elapsed=$((now - last_alert))
    if [ "$elapsed" -ge "$ALERT_REALERT_SECONDS" ]; then
        echo "$now" > "$state_file"
        return 0
    fi

    return 1
}

# Called when a condition clears — sends recovery ✅ Discord message
# if we previously alerted on this condition. No-op if the state file
# doesn't exist (i.e., we never alerted).
clear_alert_state() {
    local condition="$1"
    local recovery_msg="$2"
    local state_file="${ALERT_STATE_DIR}/${condition}"

    if [ -f "$state_file" ]; then
        rm -f "$state_file"
        log_msg "RECOVERY | ${condition} — ${recovery_msg}"
        send_discord "✅ ${recovery_msg}"
    fi
}

get_stats() {
    echo -n "litestats" | socat -t 10 stdio tcp:${AVALON_IP}:${API_PORT},shut-none 2>/dev/null | cat -v
}

get_tmax() {
    local stats="$1"
    echo "$stats" | grep -oP 'TMax\[\K[0-9]+' 2>/dev/null
}

get_workmode() {
    local stats="$1"
    echo "$stats" | grep -oP 'WORKMODE\[\K[0-9]+' 2>/dev/null
}

get_tavg() {
    local stats="$1"
    echo "$stats" | grep -oP 'TAvg\[\K[0-9]+' 2>/dev/null
}

get_hbo_temp() {
    local stats="$1"
    echo "$stats" | grep -oP 'HBOTemp\[\K[0-9]+' 2>/dev/null
}

get_fan_ratio() {
    local stats="$1"
    echo "$stats" | grep -oP 'FanR\[\K[0-9]+' 2>/dev/null
}

get_hashrate() {
    local stats="$1"
    local ghs=$(echo "$stats" | grep -oP 'GHSspd\[\K[0-9.]+' 2>/dev/null)
    if [ -n "$ghs" ]; then
        echo $(echo "$ghs" | awk '{printf "%.1f", $1/1000}')
    fi
}

get_power() {
    local stats="$1"
    echo "$stats" | grep -oP 'MPO\[\K[0-9]+' 2>/dev/null
}

# --- Diagnostic parsers ---

get_fan_err() {
    local stats="$1"
    echo "$stats" | grep -oP 'FanErr\[\K[0-9]+' 2>/dev/null
}

get_fan_rpms() {
    local stats="$1"
    local f1=$(echo "$stats" | grep -oP 'Fan1\[\K[0-9]+' 2>/dev/null)
    local f2=$(echo "$stats" | grep -oP 'Fan2\[\K[0-9]+' 2>/dev/null)
    local f3=$(echo "$stats" | grep -oP 'Fan3\[\K[0-9]+' 2>/dev/null)
    local f4=$(echo "$stats" | grep -oP 'Fan4\[\K[0-9]+' 2>/dev/null)
    echo "${f1:-0} ${f2:-0} ${f3:-0} ${f4:-0}"
}

get_echu() {
    local stats="$1"
    echo "$stats" | grep -oP 'ECHU\[\K[0-9]+' 2>/dev/null
}

get_ecmm() {
    local stats="$1"
    echo "$stats" | grep -oP 'ECMM\[\K[0-9]+' 2>/dev/null
}

get_crc() {
    local stats="$1"
    echo "$stats" | grep -oP 'CRC\[\K[0-9]+' 2>/dev/null
}

get_bootby() {
    local stats="$1"
    echo "$stats" | grep -oP 'BOOTBY\[\K[^]]+' 2>/dev/null
}

decode_bootby() {
    local code="$1"
    local hex=$(echo "$code" | grep -oP '0x\K[0-9a-fA-F]+' | head -1)
    case "$hex" in
        01) echo "POWRON (hard reboot)" ;;
        02|0[aA]) echo "OVERHEAT" ;;
        03) echo "NETFAIL (network)" ;;
        04) echo "WEB (web reboot)" ;;
        05) echo "API (API reboot)" ;;
        11) echo "NOSHARE (5min no hashrate)" ;;
        12) echo "LOW_HASHRATE (<70%)" ;;
        21) echo "SOFTON (soft reboot)" ;;
        *)  echo "UNKNOWN ($code)" ;;
    esac
}

set_workmode() {
    local mode=$1
    echo -n "ascset|0,workmode,set,${mode}" | socat -t 30 stdio tcp:${AVALON_IP}:${API_PORT},shut-none 2>/dev/null
}

soft_shutdown() {
    local future_ts=$(date -d '+5 seconds' +%s)
    echo -n "ascset|0,softoff,1:${future_ts}" | socat -t 30 stdio tcp:${AVALON_IP}:${API_PORT},shut-none 2>/dev/null
}

check_lockout() {
    if [ ! -f "$LOCKOUT_FILE" ]; then
        return 0
    fi
    local lockout_time=$(cat "$LOCKOUT_FILE" 2>/dev/null)
    local now=$(date +%s)
    local elapsed=$((now - lockout_time))
    if [ "$elapsed" -ge "$LOCKOUT_SECONDS" ]; then
        return 0
    else
        local remaining=$(( (LOCKOUT_SECONDS - elapsed) / 60 ))
        log_msg "LOCKOUT | ${remaining} minutes remaining before Standard mode allowed"
        return 1
    fi
}

set_lockout() {
    date +%s > "$LOCKOUT_FILE"
}

clear_lockout() {
    rm -f "$LOCKOUT_FILE"
}

# --- Crash detection ---

increment_crash_count() {
    local count=0
    if [ -f "$CRASH_FILE" ]; then
        count=$(cat "$CRASH_FILE" 2>/dev/null)
    fi
    count=$((count + 1))
    echo "$count" > "$CRASH_FILE"
    echo "$count"
}

reset_crash_count() {
    rm -f "$CRASH_FILE"
}

# =============================================
# MAIN LOGIC
# =============================================

# Get stats from Avalon Q
STATS=$(get_stats)

# Check if we got a response
if [ -z "$STATS" ]; then
    log_msg "ERROR | Cannot reach Avalon Q at ${AVALON_IP}:${API_PORT} - miner may be offline"
    CRASH_COUNT=$(increment_crash_count)
    if [ "$CRASH_COUNT" -ge "$CRASH_THRESHOLD" ]; then
        if should_alert "downtime"; then
            send_discord "🔴 Cannot reach Avalon Q — unreachable for ${CRASH_COUNT} consecutive polls ($(( CRASH_COUNT * 5 )) min)"
        fi
    fi
    exit 1
fi

# Parse core values
TMAX=$(get_tmax "$STATS")
TAVG=$(get_tavg "$STATS")
HBO=$(get_hbo_temp "$STATS")
FANR=$(get_fan_ratio "$STATS")
MODE=$(get_workmode "$STATS")
HASHRATE=$(get_hashrate "$STATS")
POWER=$(get_power "$STATS")

# Parse diagnostic values
FAN_ERR=$(get_fan_err "$STATS")
FAN_RPMS=$(get_fan_rpms "$STATS")
ECHU=$(get_echu "$STATS")
ECMM=$(get_ecmm "$STATS")
CRC=$(get_crc "$STATS")
BOOTBY=$(get_bootby "$STATS")

# Validate we got temperature data
if [ -z "$TMAX" ]; then
    log_msg "ERROR | Could not parse TMax from API response"
    exit 1
fi

# Mode names for logging
case $MODE in
    0) MODE_NAME="Eco" ;;
    1) MODE_NAME="Standard" ;;
    2) MODE_NAME="Super" ;;
    *) MODE_NAME="Unknown($MODE)" ;;
esac

# Log current status (includes individual fan RPMs)
log_msg "STATUS | Mode:${MODE_NAME} TMax:${TMAX}°C TAvg:${TAVG}°C HBOut:${HBO}°C Fan:${FANR}% Hash:${HASHRATE}TH/s Power:${POWER}W Fans:[${FAN_RPMS}]"

# =============================================
# HEALTH CHECKS (run before temperature logic)
# =============================================

# --- Fan error check ---
if [ -n "$FAN_ERR" ] && [ "$FAN_ERR" -ne 0 ]; then
    log_msg "ALERT | FanErr=${FAN_ERR} - Fan fault detected!"
    if should_alert "fan_err"; then
        send_discord "🌀 Fan fault detected! FanErr=${FAN_ERR}. RPMs: [${FAN_RPMS}]. Check miner immediately."
    fi
elif [ "$FAN_ERR" = "0" ]; then
    clear_alert_state "fan_err" "Fan fault cleared (FanErr=0). RPMs: [${FAN_RPMS}]"
fi

# --- Individual fan RPM check (any fan at 0 = dead) ---
read -r F1 F2 F3 F4 <<< "$FAN_RPMS"
DEAD_FANS=""
[[ "$F1" =~ ^[0-9]+$ ]] && [ "$F1" -eq 0 ] && DEAD_FANS="${DEAD_FANS}Fan1 "
[[ "$F2" =~ ^[0-9]+$ ]] && [ "$F2" -eq 0 ] && DEAD_FANS="${DEAD_FANS}Fan2 "
[[ "$F3" =~ ^[0-9]+$ ]] && [ "$F3" -eq 0 ] && DEAD_FANS="${DEAD_FANS}Fan3 "
[[ "$F4" =~ ^[0-9]+$ ]] && [ "$F4" -eq 0 ] && DEAD_FANS="${DEAD_FANS}Fan4 "
if [ -n "$DEAD_FANS" ] && [[ "${FANR:-0}" =~ ^[0-9]+$ ]] && [ "${FANR:-0}" -ne 0 ]; then
    log_msg "ALERT | Dead fan(s): ${DEAD_FANS}(RPMs: F1=${F1} F2=${F2} F3=${F3} F4=${F4})"
    if should_alert "dead_fan"; then
        send_discord "🌀 Dead fan(s): ${DEAD_FANS}— RPMs: F1=${F1} F2=${F2} F3=${F3} F4=${F4}"
    fi
elif [ -z "$DEAD_FANS" ] && [[ "$F1" =~ ^[0-9]+$ ]] && [[ "$F2" =~ ^[0-9]+$ ]] && [[ "$F3" =~ ^[0-9]+$ ]] && [[ "$F4" =~ ^[0-9]+$ ]]; then
    # All 4 fans reporting valid nonzero RPM — definitive recovery
    clear_alert_state "dead_fan" "All fans reporting RPM > 0 — fault cleared. RPMs: F1=${F1} F2=${F2} F3=${F3} F4=${F4}"
fi

# --- ECHU (hashboard error code) check ---
# 0 or 512 = normal, 128 = overheated, 513 = abnormal
if [ -n "$ECHU" ]; then
    case $ECHU in
        0|512)
            # Normal — clear any prior ECHU alert state
            clear_alert_state "echu" "ECHU cleared (hashboard errors resolved, ECHU=${ECHU})"
            ;;
        128)
            log_msg "ALERT | ECHU=${ECHU} - Hashboard OVERHEATED"
            if should_alert "echu"; then
                send_discord "🔥 Hashboard overheated! ECHU=128. TMax=${TMAX}°C"
            fi
            ;;
        513)
            log_msg "ALERT | ECHU=${ECHU} - Hashboard ABNORMAL"
            if should_alert "echu"; then
                send_discord "⚠️ Hashboard abnormal! ECHU=513. Check hardware."
            fi
            ;;
        *)
            log_msg "ALERT | ECHU=${ECHU} - Unknown hashboard error code"
            if should_alert "echu"; then
                send_discord "⚠️ Unknown hashboard error ECHU=${ECHU}"
            fi
            ;;
    esac
fi

# --- ECMM (control board) check ---
if [ -n "$ECMM" ] && [ "$ECMM" -ne 0 ]; then
    log_msg "ALERT | ECMM=${ECMM} - Control board fault or hashboard connection issue"
    if should_alert "ecmm"; then
        send_discord "🔧 Control board fault! ECMM=${ECMM}. May need reboot or physical inspection."
    fi
elif [ "$ECMM" = "0" ]; then
    clear_alert_state "ecmm" "ECMM cleared (control board OK, ECMM=0)"
fi

# --- CRC (communication errors) check ---
if [ -n "$CRC" ] && [[ "$CRC" =~ ^[0-9]+$ ]] && [ "$CRC" -gt 0 ]; then
    log_msg "WARN | CRC=${CRC} - Communication errors detected (rising count = problem)"
fi

# --- BOOTBY check (log restart reason on first poll after reboot) ---
if [ -n "$BOOTBY" ]; then
    ELAPSED=$(echo "$STATS" | grep -oP 'Elapsed\[\K[0-9]+' 2>/dev/null)
    if [ -n "$ELAPSED" ] && [ "$ELAPSED" -lt 900 ]; then
        BOOT_REASON=$(decode_bootby "$BOOTBY")
        log_msg "BOOT | Last restart reason: ${BOOT_REASON} (BOOTBY=${BOOTBY}, uptime=${ELAPSED}s)"
        case "$BOOTBY" in
            *0x02*|*0x0[aA]*)
                send_discord "🔥 Miner restarted due to OVERHEAT (BOOTBY=${BOOTBY})"
                ;;
            *0x11*)
                send_discord "⛏️ Miner restarted — no shares for 5 min (BOOTBY=${BOOTBY})"
                ;;
            *0x12*)
                send_discord "📉 Miner restarted — low hashrate <70% (BOOTBY=${BOOTBY})"
                ;;
            *0x03*)
                send_discord "🌐 Miner restarted due to network failure (BOOTBY=${BOOTBY})"
                ;;
        esac
    fi
fi

# --- Crash detection (hashrate = 0 while miner is reachable) ---
if [ "$HASHRATE" = "0.0" ] || [ -z "$HASHRATE" ]; then
    CRASH_COUNT=$(increment_crash_count)
    log_msg "WARN | Hashrate is ${HASHRATE:-null} — crash count: ${CRASH_COUNT}/${CRASH_THRESHOLD}"
    if [ "$CRASH_COUNT" -ge "$CRASH_THRESHOLD" ]; then
        log_msg "ALERT | Miner appears crashed — 0 hashrate for ${CRASH_COUNT} consecutive polls ($(( CRASH_COUNT * 5 )) min)"
        if should_alert "downtime"; then
            send_discord "🔴 Miner DOWN — 0 TH/s for $(( CRASH_COUNT * 5 )) min! Fan:${FANR}% TMax:${TMAX}°C. Check immediately."
        fi
    fi
else
    reset_crash_count
    clear_alert_state "downtime" "Avalon Q back online — hashing at ${HASHRATE} TH/s"
fi

# =============================================
# TEMPERATURE ACTIONS
# =============================================

# CRITICAL EMERGENCY: If already in Eco and STILL above shutdown temp, softoff
if [ "$TMAX" -ge "$TEMP_SHUTDOWN" ] && [ "$MODE" -eq 0 ]; then
    log_msg "EMERGENCY | TMax ${TMAX}°C >= ${TEMP_SHUTDOWN}°C IN ECO MODE - SOFT SHUTDOWN"
    soft_shutdown
    log_msg "EMERGENCY | Soft shutdown command sent - miner entering standby"
    send_discord "🛑 EMERGENCY SHUTDOWN — TMax=${TMAX}°C in Eco mode. Miner entering standby."
    touch "$SOFTOFF_FILE"
    exit 0
fi

# EMERGENCY: Too hot in Standard/Super - switch to Eco FIRST
if [ "$TMAX" -ge "$TEMP_SHUTDOWN" ] && [ "$MODE" -ne 0 ]; then
    log_msg "EMERGENCY | TMax ${TMAX}°C >= ${TEMP_SHUTDOWN}°C - Switching to Eco mode FIRST"
    set_workmode 0
    set_lockout
    log_msg "EMERGENCY | Eco mode applied - will softoff next cycle if still too hot"
    send_discord "🔥 EMERGENCY — TMax=${TMAX}°C! Switched to Eco. Will shutdown next cycle if still hot."
    exit 0
fi

# HOT: Switch to Eco if overheating and not already in Eco
if [ "$TMAX" -ge "$TEMP_ECO" ] && [ "$MODE" -ne 0 ]; then
    log_msg "ACTION | TMax ${TMAX}°C >= ${TEMP_ECO}°C - Switching from ${MODE_NAME} to Eco mode"
    set_workmode 0
    set_lockout
    log_msg "ACTION | Eco mode applied instantly + 5hr lockout started"
    send_discord "🌡️ TMax=${TMAX}°C — switched from ${MODE_NAME} to Eco + 5hr lockout."
    exit 0
fi

# COOL: Switch back to Standard if in Eco, cooled down enough, AND lockout expired
if [ "$MODE" -eq 0 ] && [ "$TMAX" -le "$TEMP_RECOVER" ]; then
    if check_lockout; then
        log_msg "ACTION | TMax ${TMAX}°C <= ${TEMP_RECOVER}°C + lockout expired - Switching from Eco back to Standard mode"
        set_workmode 1
        clear_lockout
        rm -f "$SOFTOFF_FILE"
        log_msg "ACTION | Standard mode applied instantly + lockout cleared"
        send_discord "✅ Cooled to ${TMAX}°C — switching back to Standard mode."
        exit 0
    fi
fi

# If in Eco due to heat but not yet cooled enough, log it
if [ "$MODE" -eq 0 ] && [ "$TMAX" -gt "$TEMP_RECOVER" ]; then
    log_msg "HOLDING | In Eco mode, TMax ${TMAX}°C - waiting to cool below ${TEMP_RECOVER}°C before switching back"
fi

exit 0
