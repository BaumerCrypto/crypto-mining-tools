#!/bin/bash
#=====================================================
# Daily BTC Fleet Mining Summary
#=====================================================
# Runs on: your monitoring server (Linux)
# Parses:  btc_fleet_monitor.log (from btc_fleet_monitor.sh)
# Sends:   Discord embed to #daily-mining-summary
# Author:  @BaumerCrypto2.0 | https://x.com/BaumerCrypto2_0 - June 2026
#
# Features:
#   - Per-miner: avg hashrate, avg temp, avg power,
#     24h share delta (restart-aware),
#     "Today" best session diff (restart-aware) + Lifetime best diff,
#     uptime%
#   - Fleet totals: hashrate sum, kWh, daily cost, share totals
#   - Color: green = clean / orange = any rejected shares /
#            red = any miner uptime < 90%
#   - Monthly projection scaled from partial-day if needed
#   - --dry-run, --date YYYY-MM-DD, --today flags
#
# Install: chmod +x /home/ubuntu/daily_btc_fleet_summary.sh
#          crontab -e → 2 0 * * * /home/ubuntu/daily_btc_fleet_summary.sh
#=====================================================

# --- Configuration ---
LOG_FILE="/home/ubuntu/btc_fleet_monitor.log"
WEBHOOK_FILE="/home/ubuntu/Discord_Webhook_Summary.txt"
POWER_RATE=0.15476       # E01 in $/kWh
POLL_INTERVAL=5          # Minutes, matches btc_fleet_monitor.sh cron
EXPECTED_POLLS=288       # 24h * 60 / 5

# Miner display names (must match column 3 of STATUS lines exactly)
MINERS=("NerdQaxe1" "NerdQaxe2" "NerdQX")

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
            echo "  --dry-run   Print to stdout, don't send to Discord"
            echo "  --date      Generate for a specific date"
            echo "  --today     Generate for today (partial day)"
            exit 0
            ;;
        *) echo "Unknown option: $1. Use --help."; exit 1 ;;
    esac
done

# --- Validate prerequisites ---
[[ -f "$LOG_FILE" ]] || { echo "ERROR: Log file not found: $LOG_FILE"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required. Install: sudo apt install -y jq"; exit 1; }

if [[ "$DRY_RUN" == "false" ]]; then
    [[ -f "$WEBHOOK_FILE" ]] || { echo "ERROR: Webhook file not found: $WEBHOOK_FILE"; exit 1; }
    DISCORD_WEBHOOK=$(cat "$WEBHOOK_FILE" | tr -d '[:space:]')
    [[ -z "$DISCORD_WEBHOOK" ]] && { echo "ERROR: Webhook file empty"; exit 1; }
fi

# =============================================
# HELPERS
# =============================================

# Format big difficulty numbers (e.g., 33774038447 → "33.77G")
fmt_diff() {
    awk -v d="$1" 'BEGIN{
        if (d >= 1e12) printf "%.2fT", d/1e12
        else if (d >= 1e9)  printf "%.2fG", d/1e9
        else if (d >= 1e6)  printf "%.2fM", d/1e6
        else if (d >= 1e3)  printf "%.2fK", d/1e3
        else printf "%d", d
    }'
}

# Thousand separators (locale-free)
fmt_num() {
    echo "$1" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'
}

# =============================================
# PARSE ONE MINER'S DAY
# =============================================
# Returns tab-separated 12 fields:
#   1 hash_avg  2 hash_min  3 hash_max
#   4 temp_avg
#   5 power_avg  6 power_kwh
#   7 share_delta  8 reject_delta
#   9 today_best (0 if undetermined)  10 lifetime_best
#   11 total_polls  12 valid_polls
parse_miner() {
    local miner="$1"
    local lines valid_lines total_count valid_count

    lines=$(grep "^${TARGET_DATE}" "$LOG_FILE" \
            | grep -F "| STATUS |" \
            | grep -F "| ${miner} |")

    if [[ -z "$lines" ]]; then
        echo -e "0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0"
        return
    fi

    total_count=$(echo "$lines" | wc -l)
    valid_lines=$(echo "$lines" | grep -v "UNREACHABLE" | grep -v "INVALID_JSON")
    valid_count=$(echo "$valid_lines" | grep -c "STATUS" 2>/dev/null || echo 0)
    [[ -z "$valid_lines" ]] && valid_count=0

    if [[ "$valid_count" -eq 0 ]]; then
        echo -e "0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t${total_count}\t0"
        return
    fi

    # Extract per-field streams
    local hashes temps powers accepteds rejecteds best_sessions best_diffs
    hashes=$(echo "$valid_lines"        | grep -oP 'Hash:\K[0-9.]+')
    temps=$(echo "$valid_lines"         | grep -oP 'Temp:\K[0-9.]+')
    powers=$(echo "$valid_lines"        | grep -oP 'Power:\K[0-9]+')
    accepteds=$(echo "$valid_lines"     | grep -oP 'Accepted:\K[0-9]+')
    rejecteds=$(echo "$valid_lines"     | grep -oP 'Rejected:\K[0-9]+')
    best_sessions=$(echo "$valid_lines" | grep -oP 'BestSession:\K[0-9]+')
    best_diffs=$(echo "$valid_lines"    | grep -oP 'BestDiff:\K[0-9]+')

    # Hashrate avg / min / max
    local hash_stats
    hash_stats=$(echo "$hashes" | awk '
        NR==1 { min=$1; max=$1 }
        { s+=$1; n++; if($1<min)min=$1; if($1>max)max=$1 }
        END { if(n>0) printf "%.1f\t%.1f\t%.1f", s/n, min, max; else printf "0\t0\t0" }
    ')

    # Temperature avg
    local temp_avg
    temp_avg=$(echo "$temps" | awk '{ s+=$1; n++ } END { if(n>0) printf "%.1f", s/n; else print "0" }')

    # Power avg (W) + total kWh
    local power_stats
    power_stats=$(echo "$powers" | awk -v interval="$POLL_INTERVAL" '
        { s+=$1; n++ }
        END {
            if(n>0) printf "%.0f\t%.2f", s/n, (s * interval / 60 / 1000)
            else printf "0\t0"
        }
    ')

    # Share delta with restart detection
    local share_delta
    share_delta=$(echo "$accepteds" | awk '
        BEGIN { prev=-1; baseline=-1; total=0 }
        {
            current=$1
            if (baseline == -1) baseline = current
            else if (current < prev) { total += (prev - baseline); baseline = current }
            prev = current
        }
        END { if (baseline != -1) total += (prev - baseline); print total }
    ')

    # Reject delta (same logic — restart resets to 0)
    local reject_delta
    reject_delta=$(echo "$rejecteds" | awk '
        BEGIN { prev=-1; baseline=-1; total=0 }
        {
            current=$1
            if (baseline == -1) baseline = current
            else if (current < prev) { total += (prev - baseline); baseline = current }
            prev = current
        }
        END { if (baseline != -1) total += (prev - baseline); print total }
    ')

    # Detect: did the current session start on the target date?
    # If first_timestamp - first_uptime >= target_midnight, session is fully today.
    # This is the key fix for miners that restarted recently — without it,
    # we conservatively show "—" until BestSession improves.
    local first_record first_ts first_uptime target_midnight first_ts_epoch session_start_epoch session_started_today
    first_record=$(echo "$valid_lines" | head -n 1)
    first_ts=$(echo "$first_record" | awk '{print $1, $2}')
    first_uptime=$(echo "$first_record" | grep -oP 'Uptime:\K[0-9]+')
    target_midnight=$(date -d "${TARGET_DATE} 00:00:00" +%s 2>/dev/null)
    first_ts_epoch=$(date -d "$first_ts" +%s 2>/dev/null)
    session_started_today=0
    if [[ -n "$first_uptime" && -n "$target_midnight" && -n "$first_ts_epoch" ]]; then
        session_start_epoch=$((first_ts_epoch - first_uptime))
        [[ "$session_start_epoch" -ge "$target_midnight" ]] && session_started_today=1
    fi

    # Today's best (restart-aware, segment-aware, session-start-aware)
    # Pairs Accepted + BestSession per poll, tracks segments separated by Accepted drops.
    # Rules:
    #   - If session started today (sst=1): initial segment is fully today → use max
    #   - If session started before today (sst=0): initial segment only counts when
    #     max > first reading (proves today added something above carry-over)
    #   - Post-restart segments are always fully today → count their max as-is
    #   - Final today_best = max across all qualifying segment values; 0 if none qualify
    local today_best
    today_best=$(paste <(echo "$accepteds") <(echo "$best_sessions") | awk -v sst="$session_started_today" '
        BEGIN {
            first_bs = -1
            current_segment_max = 0
            today_best = 0
            prev_acc = -1
            baseline_acc = -1
            current_segment_is_today = (sst == 1) ? 1 : 0
        }
        {
            acc = $1; bs = $2
            if (first_bs == -1) first_bs = bs

            if (baseline_acc == -1) {
                baseline_acc = acc
                current_segment_max = bs
            } else if (acc < prev_acc) {
                # End of a segment
                if (current_segment_is_today) {
                    if (current_segment_max > today_best) today_best = current_segment_max
                } else {
                    if (current_segment_max > first_bs && current_segment_max > today_best) {
                        today_best = current_segment_max
                    }
                }
                # New segment after a restart is always fully today
                current_segment_is_today = 1
                current_segment_max = bs
            } else {
                if (bs > current_segment_max) current_segment_max = bs
            }
            prev_acc = acc
        }
        END {
            # Final segment
            if (current_segment_is_today) {
                if (current_segment_max > today_best) today_best = current_segment_max
            } else {
                if (current_segment_max > first_bs && current_segment_max > today_best) {
                    today_best = current_segment_max
                }
            }
            print today_best
        }
    ')

    # Lifetime best (BestDiff never resets — max == last value)
    local lifetime_best
    lifetime_best=$(echo "$best_diffs" | awk 'BEGIN{m=0} {if($1>m)m=$1} END{print m}')

    echo -e "${hash_stats}\t${temp_avg}\t${power_stats}\t${share_delta}\t${reject_delta}\t${today_best}\t${lifetime_best}\t${total_count}\t${valid_count}"
}

# =============================================
# COLLECT PER-MINER STATS
# =============================================
declare -A MINER_DATA
ANY_DATA=false

for m in "${MINERS[@]}"; do
    MINER_DATA[$m]=$(parse_miner "$m")
    vc=$(echo "${MINER_DATA[$m]}" | cut -f12)
    [[ "$vc" -gt 0 ]] && ANY_DATA=true
done

# --- No data anywhere → send "No Data" embed and exit ---
if [[ "$ANY_DATA" == "false" ]]; then
    MSG="No BTC mining data found for ${TARGET_DATE}. Fleet may have been offline or monitor wasn't running."
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "=== 💎 BTC Fleet — No Data | ${TARGET_DATE} ==="
        echo "$MSG"
    else
        NO_DATA_JSON=$(jq -n --arg msg "$MSG" --arg date "$TARGET_DATE" '{
            username: "Daily Mining Summary",
            embeds: [{
                title: "💎 BTC Fleet — No Data",
                description: $msg,
                color: 16711680,
                footer: { text: ("Daily Mining Summary | " + $date) }
            }]
        }')
        curl -s -o /dev/null -X POST "$DISCORD_WEBHOOK" \
            -H "Content-Type: application/json" -d "$NO_DATA_JSON"
    fi
    exit 0
fi

# =============================================
# COMPUTE FLEET TOTALS
# =============================================
FLEET_HASH_AVG=0; FLEET_HASH_MIN=0; FLEET_HASH_MAX=0
FLEET_POWER_AVG=0; FLEET_KWH=0
FLEET_SHARES=0; FLEET_REJECTS=0
FLEET_VALID=0; FLEET_EXPECTED=0
MIN_VALID=$EXPECTED_POLLS

for m in "${MINERS[@]}"; do
    IFS=$'\t' read -r ha hi hx t pa kwh sd rd tb lb tc vc <<< "${MINER_DATA[$m]}"
    FLEET_HASH_AVG=$(awk -v a="$FLEET_HASH_AVG" -v b="$ha" 'BEGIN{printf "%.1f", a+b}')
    FLEET_HASH_MIN=$(awk -v a="$FLEET_HASH_MIN" -v b="$hi" 'BEGIN{printf "%.1f", a+b}')
    FLEET_HASH_MAX=$(awk -v a="$FLEET_HASH_MAX" -v b="$hx" 'BEGIN{printf "%.1f", a+b}')
    FLEET_POWER_AVG=$(awk -v a="$FLEET_POWER_AVG" -v b="$pa" 'BEGIN{printf "%.0f", a+b}')
    FLEET_KWH=$(awk -v a="$FLEET_KWH" -v b="$kwh" 'BEGIN{printf "%.2f", a+b}')
    FLEET_SHARES=$((FLEET_SHARES + sd))
    FLEET_REJECTS=$((FLEET_REJECTS + rd))
    FLEET_VALID=$((FLEET_VALID + vc))
    FLEET_EXPECTED=$((FLEET_EXPECTED + EXPECTED_POLLS))
    [[ "$vc" -gt 0 && "$vc" -lt "$MIN_VALID" ]] && MIN_VALID=$vc
done

FLEET_UPTIME=$(awk -v v="$FLEET_VALID" -v e="$FLEET_EXPECTED" 'BEGIN{if(e>0)printf "%.1f", v/e*100; else print "0"}')
DAILY_COST=$(awk -v k="$FLEET_KWH" -v r="$POWER_RATE" 'BEGIN{printf "%.2f", k*r}')

# GH/s → TH/s for the fleet display
FH_AVG_TH=$(awk -v g="$FLEET_HASH_AVG" 'BEGIN{printf "%.2f", g/1000}')
FH_MIN_TH=$(awk -v g="$FLEET_HASH_MIN" 'BEGIN{printf "%.2f", g/1000}')
FH_MAX_TH=$(awk -v g="$FLEET_HASH_MAX" 'BEGIN{printf "%.2f", g/1000}')

# Monthly projection: scale partial → full day, then × 30
MONTHLY_KWH=$(awk -v k="$FLEET_KWH" -v v="$MIN_VALID" -v e="$EXPECTED_POLLS" 'BEGIN{
    if(v>0) printf "%.1f", k * (e/v) * 30
    else print "0"
}')
MONTHLY_COST=$(awk -v k="$MONTHLY_KWH" -v r="$POWER_RATE" 'BEGIN{printf "%.2f", k*r}')

# =============================================
# COLOR LOGIC
# =============================================
EMBED_COLOR=3066993  # Green
ANY_LOW_UPTIME=false
for m in "${MINERS[@]}"; do
    vc=$(echo "${MINER_DATA[$m]}" | cut -f12)
    up_pct=$(awk -v v="$vc" -v e="$EXPECTED_POLLS" 'BEGIN{if(e>0)printf "%.0f", v/e*100; else print "0"}')
    [[ "$up_pct" -lt 90 ]] && ANY_LOW_UPTIME=true
done
[[ "$FLEET_REJECTS" -gt 0 ]] && EMBED_COLOR=16744448      # Orange
[[ "$ANY_LOW_UPTIME" == "true" ]] && EMBED_COLOR=16711680  # Red

# =============================================
# BUILD PER-MINER FIELD VALUES
# =============================================
declare -A FIELD_VALUES
for m in "${MINERS[@]}"; do
    IFS=$'\t' read -r ha hi hx t pa kwh sd rd tb lb tc vc <<< "${MINER_DATA[$m]}"

    up_pct=$(awk -v v="$vc" -v e="$EXPECTED_POLLS" 'BEGIN{if(e>0)printf "%.0f", v/e*100; else print "0"}')

    if [[ "$vc" -eq 0 ]]; then
        FIELD_VALUES[$m]="❌ **Offline all day**"
        continue
    fi

    ha_th=$(awk -v g="$ha" 'BEGIN{printf "%.2f", g/1000}')
    miner_cost=$(awk -v k="$kwh" -v r="$POWER_RATE" 'BEGIN{printf "%.2f", k*r}')
    shares_fmt=$(fmt_num "$sd")

    # Today's best — "—" when undetermined (no restart + no improvement)
    if [[ "$tb" -gt 0 ]]; then
        today_fmt=$(fmt_diff "$tb")
    else
        today_fmt="—"
    fi
    lifetime_fmt=$(fmt_diff "$lb")

    FIELD_VALUES[$m]="⚡ ${ha_th} TH/s avg"$'\n'"🌡️ ${t}°C avg"$'\n'"🔋 ${pa}W | ${kwh} kWh | \$${miner_cost}"$'\n'"📈 ${shares_fmt} accepted | ${rd} rejected"$'\n'"🎯 Today: ${today_fmt}"$'\n'"🏆 Lifetime: ${lifetime_fmt}"$'\n'"📊 Uptime: ${up_pct}%"
done

# =============================================
# BUILD FLEET TOTAL FIELD
# =============================================
FLEET_SHARES_FMT=$(fmt_num "$FLEET_SHARES")
FLEET_VALUE="⚡ **Hash:** Avg ${FH_AVG_TH} TH/s | Peak ${FH_MAX_TH} TH/s | Low ${FH_MIN_TH} TH/s"$'\n'"🔋 **Power:** Avg ${FLEET_POWER_AVG}W | Total ${FLEET_KWH} kWh | Cost \$${DAILY_COST} CAD"$'\n'"📈 **Shares:** ${FLEET_SHARES_FMT} accepted | ${FLEET_REJECTS} rejected"$'\n'"📊 **Fleet Uptime:** ${FLEET_UPTIME}%"

PROJECTION_VALUE="~${MONTHLY_KWH} kWh | ~\$${MONTHLY_COST} CAD"

# =============================================
# BUILD EMBED JSON (jq handles escaping)
# =============================================
EMBED_JSON=$(jq -n \
    --arg title "💎 BTC Fleet — Daily Mining Summary" \
    --arg date "$TARGET_DATE" \
    --argjson color "$EMBED_COLOR" \
    --arg fleet "$FLEET_VALUE" \
    --arg m1n "${MINERS[0]}" --arg m1v "${FIELD_VALUES[${MINERS[0]}]}" \
    --arg m2n "${MINERS[1]}" --arg m2v "${FIELD_VALUES[${MINERS[1]}]}" \
    --arg m3n "${MINERS[2]}" --arg m3v "${FIELD_VALUES[${MINERS[2]}]}" \
    --arg proj "$PROJECTION_VALUE" \
    '{
        username: "Daily Mining Summary",
        embeds: [{
            title: $title,
            color: $color,
            fields: [
                { name: "📊 Fleet Total", value: $fleet, inline: false },
                { name: $m1n, value: $m1v, inline: true },
                { name: $m2n, value: $m2v, inline: true },
                { name: $m3n, value: $m3v, inline: true },
                { name: "💰 Monthly Projection", value: $proj, inline: false }
            ],
            footer: { text: ("Daily Mining Summary | " + $date + " | Power E01 @ 15.476¢/kWh") }
        }]
    }')

# =============================================
# OUTPUT
# =============================================
if [[ "$DRY_RUN" == "true" ]]; then
    echo "=== 💎 BTC Fleet — Daily Mining Summary ==="
    echo "Date: ${TARGET_DATE}"
    case "$EMBED_COLOR" in
        3066993)  echo "Color: GREEN (clean day)" ;;
        16744448) echo "Color: ORANGE (rejected shares present)" ;;
        16711680) echo "Color: RED (uptime issues)" ;;
    esac
    echo ""
    echo "--- Fleet Total ---"
    echo "$FLEET_VALUE" | sed 's/\*\*//g'
    echo ""
    for m in "${MINERS[@]}"; do
        echo "--- $m ---"
        echo "${FIELD_VALUES[$m]}" | sed 's/\*\*//g'
        echo ""
    done
    echo "--- Monthly Projection ---"
    echo "$PROJECTION_VALUE"
    echo ""
    echo "(dry run — not sent to Discord)"
else
    curl -s -o /dev/null -X POST "$DISCORD_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$EMBED_JSON"
fi

exit 0
