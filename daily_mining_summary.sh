#!/bin/bash
#=====================================================
# Daily Mining Summary — Avalon Q
#=====================================================
# Runs on: your monitoring server (Linux)
# Parses: avalon_monitor.log (from avalon_temp_monitor.sh)
# Sends: Discord embed with 24-hour mining stats
# Author: @BaumerCrypto2.0 | https://x.com/BaumerCrypto2_0 - June 2026
#
# Features:
#   - Hashrate: avg / peak / low
#   - Temperature: high / low / avg (TMax)
#   - Power consumption: avg watts, total kWh, daily cost
#   - Mode split: % time in Eco / Standard / Super
#   - Uptime: % of expected polls received
#   - Event count: mode switches, alerts, emergencies
#   - Monthly cost/energy projection
#   - --dry-run flag for testing without sending
#   - --date YYYY-MM-DD to generate for a specific day
#   - --today to generate for the current (partial) day
#
# Install: crontab -e → 0 0 * * * /home/ubuntu/daily_mining_summary.sh
#=====================================================

# --- Configuration ---
LOG_FILE="/home/ubuntu/avalon_monitor.log"
WEBHOOK_FILE="/home/ubuntu/Discord_Webhook_Summary.txt"
POWER_RATE=0.15476      # SaskPower E01 rate in $/kWh (15.476¢/kWh)
POLL_INTERVAL=5         # Minutes between polls (matches avalon_temp_monitor.sh cron)
EXPECTED_POLLS=288      # 24 hours * 60 / 5 = 288 STATUS polls per full day

# Timezone — Saskatchewan (CST year-round)
TZ='America/Regina'
export TZ

# --- Parse arguments ---
DRY_RUN=false
TARGET_DATE=$(date -d "yesterday" +%Y-%m-%d)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --date)     TARGET_DATE="$2"; shift 2 ;;
        --today)    TARGET_DATE=$(date +%Y-%m-%d); shift ;;
        -h|--help)
            echo "Usage: $0 [--dry-run] [--date YYYY-MM-DD] [--today]"
            echo "  --dry-run   Print summary to stdout, don't send to Discord"
            echo "  --date      Generate summary for a specific date"
            echo "  --today     Generate summary for today (partial day)"
            exit 0
            ;;
        *)  echo "Unknown option: $1. Use --help for usage."; exit 1 ;;
    esac
done

# --- Validate ---
if [[ ! -f "$LOG_FILE" ]]; then
    echo "ERROR: Log file not found: $LOG_FILE"
    exit 1
fi

if [[ "$DRY_RUN" == "false" ]]; then
    if [[ ! -f "$WEBHOOK_FILE" ]]; then
        echo "ERROR: Webhook file not found: $WEBHOOK_FILE"
        exit 1
    fi
    DISCORD_WEBHOOK=$(cat "$WEBHOOK_FILE" | tr -d '[:space:]')
    if [[ -z "$DISCORD_WEBHOOK" ]]; then
        echo "ERROR: Webhook file is empty: $WEBHOOK_FILE"
        exit 1
    fi
fi

# --- Extract lines for target date ---
STATUS_LINES=$(grep "^${TARGET_DATE}" "$LOG_FILE" | grep "| STATUS |")
ALL_LINES=$(grep "^${TARGET_DATE}" "$LOG_FILE")

STATUS_COUNT=$(echo "$STATUS_LINES" | grep -c "STATUS" 2>/dev/null)
# Handle empty grep (returns 1 line of empty string)
if [[ -z "$STATUS_LINES" ]]; then
    STATUS_COUNT=0
fi

# --- No data check ---
if [[ "$STATUS_COUNT" -eq 0 ]]; then
    MSG="No mining data found for ${TARGET_DATE}. The Avalon Q may have been offline or the monitor wasn't running."
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "=== Daily Mining Summary — ${TARGET_DATE} ==="
        echo "$MSG"
    else
        curl -s -o /dev/null -X POST "$DISCORD_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{
                \"username\": \"Daily Mining Summary\",
                \"embeds\": [{
                    \"title\": \"⛏️ Avalon Q — No Data\",
                    \"description\": \"${MSG}\",
                    \"color\": 16711680,
                    \"footer\": {\"text\": \"Daily Mining Summary | ${TARGET_DATE}\"}
                }]
            }"
    fi
    exit 0
fi

# --- Parse STATUS lines for stats ---

# Extract hashrate values
HASHRATES=$(echo "$STATUS_LINES" | grep -oP 'Hash:\K[0-9.]+')

# Extract TMax values
TMAXES=$(echo "$STATUS_LINES" | grep -oP 'TMax:\K[0-9]+')

# Extract TAvg values
TAVGS=$(echo "$STATUS_LINES" | grep -oP 'TAvg:\K[0-9]+')

# Extract Power values
POWERS=$(echo "$STATUS_LINES" | grep -oP 'Power:\K[0-9]+')

# Extract Fan % values
FANS=$(echo "$STATUS_LINES" | grep -oP 'Fan:\K[0-9]+')

# Extract Modes
MODES=$(echo "$STATUS_LINES" | grep -oP 'Mode:\K[A-Za-z]+')

# --- Compute hashrate stats ---
HASH_STATS=$(echo "$HASHRATES" | awk '
    NR==1 { min=$1; max=$1 }
    { sum+=$1; count++; if($1<min)min=$1; if($1>max)max=$1 }
    END { if(count>0) printf "%.1f %.1f %.1f", sum/count, min, max; else print "0 0 0" }
')
HASH_AVG=$(echo "$HASH_STATS" | awk '{print $1}')
HASH_MIN=$(echo "$HASH_STATS" | awk '{print $2}')
HASH_MAX=$(echo "$HASH_STATS" | awk '{print $3}')

# --- Compute TMax stats ---
TMAX_STATS=$(echo "$TMAXES" | awk '
    NR==1 { min=$1; max=$1 }
    { sum+=$1; count++; if($1<min)min=$1; if($1>max)max=$1 }
    END { if(count>0) printf "%.0f %d %d", sum/count, min, max; else print "0 0 0" }
')
TMAX_AVG=$(echo "$TMAX_STATS" | awk '{print $1}')
TMAX_LOW=$(echo "$TMAX_STATS" | awk '{print $2}')
TMAX_HIGH=$(echo "$TMAX_STATS" | awk '{print $3}')

# --- Compute power stats ---
POWER_STATS=$(echo "$POWERS" | awk -v interval="$POLL_INTERVAL" '
    { sum+=$1; count++ }
    END {
        if(count>0) {
            avg = sum/count
            kwh = sum * interval / 60 / 1000
            printf "%.0f %.2f", avg, kwh
        } else print "0 0"
    }
')
POWER_AVG=$(echo "$POWER_STATS" | awk '{print $1}')
POWER_KWH=$(echo "$POWER_STATS" | awk '{print $2}')

# --- Compute daily cost ---
DAILY_COST=$(echo "$POWER_KWH $POWER_RATE" | awk '{printf "%.2f", $1 * $2}')

# --- Compute fan avg ---
FAN_AVG=$(echo "$FANS" | awk '{ sum+=$1; count++ } END { if(count>0) printf "%.0f", sum/count; else print "0" }')

# --- Compute mode split ---
MODE_COUNTS=$(echo "$MODES" | awk '
    { modes[$1]++ }
    END {
        printf "%d %d %d", modes["Eco"]+0, modes["Standard"]+0, modes["Super"]+0
    }
')
ECO_COUNT=$(echo "$MODE_COUNTS" | awk '{print $1}')
STD_COUNT=$(echo "$MODE_COUNTS" | awk '{print $2}')
SUP_COUNT=$(echo "$MODE_COUNTS" | awk '{print $3}')

# Mode percentages
ECO_PCT=$(echo "$ECO_COUNT $STATUS_COUNT" | awk '{if($2>0) printf "%.1f", $1/$2*100; else print "0"}')
STD_PCT=$(echo "$STD_COUNT $STATUS_COUNT" | awk '{if($2>0) printf "%.1f", $1/$2*100; else print "0"}')
SUP_PCT=$(echo "$SUP_COUNT $STATUS_COUNT" | awk '{if($2>0) printf "%.1f", $1/$2*100; else print "0"}')

# --- Compute uptime ---
UPTIME_PCT=$(echo "$STATUS_COUNT $EXPECTED_POLLS" | awk '{if($2>0) printf "%.1f", $1/$2*100; else print "0"}')

# --- Count events ---
ACTION_COUNT=$(echo "$ALL_LINES" | grep -c "| ACTION |" 2>/dev/null)
ALERT_COUNT=$(echo "$ALL_LINES" | grep -c "| ALERT |" 2>/dev/null)
EMERGENCY_COUNT=$(echo "$ALL_LINES" | grep -c "| EMERGENCY |" 2>/dev/null)
WARN_COUNT=$(echo "$ALL_LINES" | grep -c "| WARN |" 2>/dev/null)

# --- Monthly projection ---
# Scale to full 24h if partial day, then multiply by 30
if [[ "$STATUS_COUNT" -gt 0 ]]; then
    MONTHLY_KWH=$(echo "$POWER_KWH $STATUS_COUNT $EXPECTED_POLLS" | awk '{
        daily = $1 * ($3 / $2)
        printf "%.1f", daily * 30
    }')
    MONTHLY_COST=$(echo "$MONTHLY_KWH $POWER_RATE" | awk '{printf "%.2f", $1 * $2}')
else
    MONTHLY_KWH="0"
    MONTHLY_COST="0"
fi

# --- Determine embed color ---
# Green = clean day, Orange = actions fired, Red = emergencies
if [[ "$EMERGENCY_COUNT" -gt 0 ]]; then
    EMBED_COLOR=16711680    # Red
elif [[ "$ACTION_COUNT" -gt 0 ]] || [[ "$ALERT_COUNT" -gt 0 ]]; then
    EMBED_COLOR=16744448    # Orange
else
    EMBED_COLOR=3066993     # Green
fi

# --- Build mode split line ---
MODE_LINE=""
if [[ "$STD_COUNT" -gt 0 ]]; then
    MODE_LINE="Standard ${STD_PCT}% (${STD_COUNT})"
fi
if [[ "$ECO_COUNT" -gt 0 ]]; then
    [[ -n "$MODE_LINE" ]] && MODE_LINE="${MODE_LINE} | "
    MODE_LINE="${MODE_LINE}Eco ${ECO_PCT}% (${ECO_COUNT})"
fi
if [[ "$SUP_COUNT" -gt 0 ]]; then
    [[ -n "$MODE_LINE" ]] && MODE_LINE="${MODE_LINE} | "
    MODE_LINE="${MODE_LINE}Super ${SUP_PCT}% (${SUP_COUNT})"
fi

# --- Build events line ---
EVENTS_LINE=""
EVENTS_TOTAL=$((ACTION_COUNT + ALERT_COUNT + EMERGENCY_COUNT))
if [[ "$EVENTS_TOTAL" -eq 0 ]]; then
    EVENTS_LINE="None — clean day ✅"
else
    PARTS=()
    [[ "$ACTION_COUNT" -gt 0 ]] && PARTS+=("${ACTION_COUNT} mode switches")
    [[ "$ALERT_COUNT" -gt 0 ]] && PARTS+=("${ALERT_COUNT} alerts")
    [[ "$EMERGENCY_COUNT" -gt 0 ]] && PARTS+=("${EMERGENCY_COUNT} emergencies")
    [[ "$WARN_COUNT" -gt 0 ]] && PARTS+=("${WARN_COUNT} warnings")
    EVENTS_LINE=$(IFS=" | "; echo "${PARTS[*]}")
fi

# --- Build summary ---
SUMMARY="⚡ **Hashrate:** Avg ${HASH_AVG} TH/s | Peak ${HASH_MAX} TH/s | Low ${HASH_MIN} TH/s"
SUMMARY="${SUMMARY}\\n🌡️ **Temperature (TMax):** High ${TMAX_HIGH}°C | Low ${TMAX_LOW}°C | Avg ${TMAX_AVG}°C"
SUMMARY="${SUMMARY}\\n🔋 **Power:** Avg ${POWER_AVG}W | Total ${POWER_KWH} kWh | Cost \$${DAILY_COST} CAD"
SUMMARY="${SUMMARY}\\n⏱️ **Mode Split:** ${MODE_LINE}"
SUMMARY="${SUMMARY}\\n🌀 **Fan Avg:** ${FAN_AVG}%"
SUMMARY="${SUMMARY}\\n📊 **Uptime:** ${UPTIME_PCT}% (${STATUS_COUNT} of ${EXPECTED_POLLS} polls)"
SUMMARY="${SUMMARY}\\n⚠️ **Events:** ${EVENTS_LINE}"
SUMMARY="${SUMMARY}\\n💰 **Monthly Projection:** ~${MONTHLY_KWH} kWh | ~\$${MONTHLY_COST} CAD"

# --- Output ---
if [[ "$DRY_RUN" == "true" ]]; then
    echo "=== ⛏️ Avalon Q — Daily Mining Summary ==="
    echo "Date: ${TARGET_DATE}"
    echo ""
    echo -e "$SUMMARY" | sed 's/\\n/\n/g' | sed 's/\*\*//g'
    echo ""
    echo "Embed color: ${EMBED_COLOR}"
    echo "(dry run — not sent to Discord)"
else
    curl -s -o /dev/null -X POST "$DISCORD_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"Daily Mining Summary\",
            \"embeds\": [{
                \"title\": \"⛏️ Avalon Q — Daily Mining Summary\",
                \"description\": \"${SUMMARY}\",
                \"color\": ${EMBED_COLOR},
                \"footer\": {\"text\": \"Daily Mining Summary | ${TARGET_DATE} | SaskPower E01 @ 15.476¢/kWh\"}
            }]
        }"
fi

exit 0
