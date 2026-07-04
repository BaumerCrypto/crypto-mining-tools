#!/bin/bash
#=====================================================
# Daily DGB Nerd/Nano Mining Summary
#=====================================================
# Runs on: your monitoring server (Linux)
# Parses:  dgb_miners_monitor.log (from dgb_miners_monitor.sh)
# Sends:   Discord embed to #daily-mining-summary
# Author:  @BaumerCrypto2.0 | https://x.com/BaumerCrypto2_0 - July 2026
#
# Features:
#   - Per-miner type-aware display:
#       NerdQaxe3 (axeos): full — avg hashrate, temp, power,
#         24h share delta (restart-aware), today/lifetime best,
#         uptime%
#       Nano3S (canaan): reduced — avg hashrate, temp, power,
#         current mode, uptime% (CGMiner stats doesn't expose
#         per-share counters or best-diff)
#   - Fleet totals: hashrate sum, kWh, daily cost
#   - Pool context from GSS API (/api/v1/DGB/metrics/pool):
#       pool hashrate, % of network, estimated time to block,
#       blocks found lifetime, active miners
#   - Color: green = clean / orange = any rejected /
#            red = any miner uptime < 90%
#   - Monthly projection
#   - --dry-run, --date YYYY-MM-DD, --today flags
#
# Install: chmod +x /home/ubuntu/daily_dgb_summary.sh
#          crontab -e → 3 0 * * * /home/ubuntu/daily_dgb_summary.sh
#
# Updated: July 3, 2026 — Discord webhook hardened with --max-time 10 and
#          HTTP status logging on failure. See GitHub issue #1 (P1-3).
#=====================================================

# --- Configuration ---
LOG_FILE="/home/ubuntu/dgb_miners_monitor.log"
WEBHOOK_FILE="/home/ubuntu/Discord_Webhook_Summary.txt"
POWER_RATE=0.15476       # E01 in $/kWh
POLL_INTERVAL=5          # Minutes, matches dgb_miners_monitor.sh cron
EXPECTED_POLLS=288       # 24h * 60 / 5

# Miners: "DisplayName:Type" — must match column 3 of STATUS lines exactly
MINERS=("NerdQaxe3:axeos" "Nano3S:canaan")

# GSS API endpoint for DGB SmallMiners pool (port 3333) — where these miners live
GSS_API_POOL="http://127.0.0.1:4004/api/v1/DGB/metrics/pool"

# Timezone — adjust to your local timezone
TZ='America/Regina'
export TZ

# --- Discord webhook helper ---
# Send Discord webhook with --max-time and HTTP status check.
# Non-2xx responses logged to ~/daily_summary_errors.log for post-mortem.
send_webhook() {
    local payload="$1"
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST "$DISCORD_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)
    if [ "$http_code" != "204" ] && [ "$http_code" != "200" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') | $(basename "$0") | WARN: Discord webhook failed HTTP=${http_code}" >> "/home/ubuntu/daily_summary_errors.log"
        return 1
    fi
    return 0
}

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

fmt_diff() {
    awk -v d="$1" 'BEGIN{
        if (d >= 1e12) printf "%.2fT", d/1e12
        else if (d >= 1e9)  printf "%.2fG", d/1e9
        else if (d >= 1e6)  printf "%.2fM", d/1e6
        else if (d >= 1e3)  printf "%.2fK", d/1e3
        else printf "%d", d
    }'
}

fmt_num() {
    echo "$1" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'
}

# =============================================
# PARSE ONE MINER'S DAY
# =============================================
# Returns 12 tab-separated fields:
#   1 hash_avg  2 hash_min  3 hash_max
#   4 temp_avg
#   5 power_avg  6 power_kwh
#   7 share_delta  8 reject_delta
#   9 today_best  10 lifetime_best
#   11 total_polls  12 valid_polls
# Type-specific fields (shares/best) are 0 for canaan miners.
parse_miner() {
    local miner="$1"
    local type="$2"
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

    # Common fields (both types have these)
    local hashes temps powers
    hashes=$(echo "$valid_lines" | grep -oP 'Hash:\K[0-9.]+')
    temps=$(echo "$valid_lines"  | grep -oP 'Temp:\K[0-9.]+')
    powers=$(echo "$valid_lines" | grep -oP 'Power:\K[0-9]+')

    local hash_stats
    hash_stats=$(echo "$hashes" | awk '
        NR==1 { min=$1; max=$1 }
        { s+=$1; n++; if($1<min)min=$1; if($1>max)max=$1 }
        END { if(n>0) printf "%.1f\t%.1f\t%.1f", s/n, min, max; else printf "0\t0\t0" }
    ')

    local temp_avg
    temp_avg=$(echo "$temps" | awk '{ s+=$1; n++ } END { if(n>0) printf "%.1f", s/n; else print "0" }')

    local power_stats
    power_stats=$(echo "$powers" | awk -v interval="$POLL_INTERVAL" '
        { s+=$1; n++ }
        END {
            if(n>0) printf "%.0f\t%.2f", s/n, (s * interval / 60 / 1000)
            else printf "0\t0"
        }
    ')

    # Share + best diff tracking — applies to both axeos and canaan.
    # Canaan's BestSession is always "-" so the regex match yields empty string,
    # and the today_best awk gracefully returns 0 (displayed as "—").
    local share_delta=0 reject_delta=0 today_best=0 lifetime_best=0
    local accepteds rejecteds best_sessions best_diffs
    accepteds=$(echo "$valid_lines"     | grep -oP 'Accepted:\K[0-9]+')
    rejecteds=$(echo "$valid_lines"     | grep -oP 'Rejected:\K[0-9]+')
    best_sessions=$(echo "$valid_lines" | grep -oP 'BestSession:\K[0-9]+')
    best_diffs=$(echo "$valid_lines"    | grep -oP 'BestDiff:\K[0-9]+')

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

    # Today's best — axeos only (Canaan exposes only lifetime, no session-aware best).
    # For Canaan, today_best stays 0 → display layer shows "—".
    if [[ "$type" == "axeos" ]]; then
        # Session-start-today detection
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
                    if (current_segment_is_today) {
                        if (current_segment_max > today_best) today_best = current_segment_max
                    } else {
                        if (current_segment_max > first_bs && current_segment_max > today_best) today_best = current_segment_max
                    }
                    current_segment_is_today = 1
                    current_segment_max = bs
                } else {
                    if (bs > current_segment_max) current_segment_max = bs
                }
                prev_acc = acc
            }
            END {
                if (current_segment_is_today) {
                    if (current_segment_max > today_best) today_best = current_segment_max
                } else {
                    if (current_segment_max > first_bs && current_segment_max > today_best) today_best = current_segment_max
                }
                print today_best
            }
        ')
    fi

    # Lifetime best — both types: max of BestDiff column.
    # axeos: BestDiff is the all-time miner counter.
    # canaan: BestDiff column holds the "Best Share" value from summary command.
    lifetime_best=$(echo "$best_diffs" | awk 'BEGIN{m=0} {if($1>m)m=$1} END{print m}')

    echo -e "${hash_stats}\t${temp_avg}\t${power_stats}\t${share_delta}\t${reject_delta}\t${today_best}\t${lifetime_best}\t${total_count}\t${valid_count}"
}

# Get last-seen mode for a Canaan miner (helper for field building)
get_last_mode() {
    local miner="$1"
    local mode
    mode=$(grep "^${TARGET_DATE}" "$LOG_FILE" \
           | grep -F "| STATUS |" \
           | grep -F "| ${miner} |" \
           | grep -v "UNREACHABLE" \
           | grep -oP 'Mode:\K[A-Za-z]+' \
           | tail -n 1)
    [[ -z "$mode" ]] && mode="?"
    echo "$mode"
}

# =============================================
# COLLECT PER-MINER STATS
# =============================================
declare -A MINER_DATA
declare -A MINER_TYPES
ANY_DATA=false

for miner_def in "${MINERS[@]}"; do
    IFS=':' read -r name type <<< "$miner_def"
    MINER_DATA[$name]=$(parse_miner "$name" "$type")
    MINER_TYPES[$name]="$type"
    vc=$(echo "${MINER_DATA[$name]}" | cut -f12)
    [[ "$vc" -gt 0 ]] && ANY_DATA=true
done

# --- No data → send "No Data" embed and exit ---
if [[ "$ANY_DATA" == "false" ]]; then
    MSG="No DGB mining data found for ${TARGET_DATE}. Miners may have been offline or monitor wasn't running."
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "=== ⛏️ DGB Nerd/Nano — No Data | ${TARGET_DATE} ==="
        echo "$MSG"
    else
        NO_DATA_JSON=$(jq -n --arg msg "$MSG" --arg date "$TARGET_DATE" '{
            username: "Daily Mining Summary",
            embeds: [{
                title: "⛏️ DGB Nerd/Nano — No Data",
                description: $msg,
                color: 16711680,
                footer: { text: ("Daily Mining Summary | " + $date) }
            }]
        }')
        send_webhook "$NO_DATA_JSON"
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

for miner_def in "${MINERS[@]}"; do
    IFS=':' read -r name type <<< "$miner_def"
    IFS=$'\t' read -r ha hi hx t pa kwh sd rd tb lb tc vc <<< "${MINER_DATA[$name]}"
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

FH_AVG_TH=$(awk -v g="$FLEET_HASH_AVG" 'BEGIN{printf "%.2f", g/1000}')
FH_MIN_TH=$(awk -v g="$FLEET_HASH_MIN" 'BEGIN{printf "%.2f", g/1000}')
FH_MAX_TH=$(awk -v g="$FLEET_HASH_MAX" 'BEGIN{printf "%.2f", g/1000}')

# Per-miner monthly projection: each device scaled by its own valid polls, then summed
MONTHLY_KWH=0
for miner_def in "${MINERS[@]}"; do
    IFS=':' read -r name type <<< "$miner_def"
    IFS=$'\t' read -r ha hi hx t pa kwh sd rd tb lb tc vc <<< "${MINER_DATA[$name]}"
    miner_monthly=$(awk -v k="$kwh" -v v="$vc" -v e="$EXPECTED_POLLS" 'BEGIN{
        if(v>0) printf "%.2f", k * (e/v) * 30
        else print "0"
    }')
    MONTHLY_KWH=$(awk -v a="$MONTHLY_KWH" -v b="$miner_monthly" 'BEGIN{printf "%.1f", a+b}')
done
MONTHLY_COST=$(awk -v k="$MONTHLY_KWH" -v r="$POWER_RATE" 'BEGIN{printf "%.2f", k*r}')

# =============================================
# COLOR LOGIC
# =============================================
EMBED_COLOR=3066993  # Green
ANY_LOW_UPTIME=false
for miner_def in "${MINERS[@]}"; do
    IFS=':' read -r name type <<< "$miner_def"
    vc=$(echo "${MINER_DATA[$name]}" | cut -f12)
    up_pct=$(awk -v v="$vc" -v e="$EXPECTED_POLLS" 'BEGIN{if(e>0)printf "%.0f", v/e*100; else print "0"}')
    [[ "$up_pct" -lt 90 ]] && ANY_LOW_UPTIME=true
done
[[ "$FLEET_REJECTS" -gt 0 ]] && EMBED_COLOR=16744448
[[ "$ANY_LOW_UPTIME" == "true" ]] && EMBED_COLOR=16711680

# =============================================
# FETCH POOL CONTEXT FROM GSS API
# =============================================
POOL_VALUE="❌ Pool data unavailable"
POOL_JSON=$(curl -s --max-time 5 "$GSS_API_POOL" 2>/dev/null)
if [[ -n "$POOL_JSON" ]] && echo "$POOL_JSON" | jq empty 2>/dev/null; then
    POOL_HASH_15M=$(echo "$POOL_JSON" | jq -r '.hashrate."15m" // 0')
    POOL_PCT=$(echo "$POOL_JSON" | jq -r '.network_comparison.pool_percentage // 0')
    POOL_ETB=$(echo "$POOL_JSON" | jq -r '.network_comparison.estimated_time_to_block // "n/a"')
    POOL_BLOCKS=$(echo "$POOL_JSON" | jq -r '.blocks_found // 0')
    POOL_MINERS=$(echo "$POOL_JSON" | jq -r '.active_miners // 0')

    POOL_HASH_TH=$(awk -v h="$POOL_HASH_15M" 'BEGIN{printf "%.2f", h/1e12}')
    POOL_PCT_FMT=$(awk -v p="$POOL_PCT" 'BEGIN{printf "%.4f", p}')

    POOL_VALUE="⚡ **Hashrate (15m):** ${POOL_HASH_TH} TH/s (${POOL_PCT_FMT}% of network)"$'\n'"⛏️ **Blocks Found:** ${POOL_BLOCKS} (lifetime)"$'\n'"⏱️ **Est. Time to Block:** ${POOL_ETB}"$'\n'"👥 **Active Miners:** ${POOL_MINERS}"
fi

# =============================================
# BUILD PER-MINER FIELD VALUES
# =============================================
declare -A FIELD_VALUES
for miner_def in "${MINERS[@]}"; do
    IFS=':' read -r name type <<< "$miner_def"
    IFS=$'\t' read -r ha hi hx t pa kwh sd rd tb lb tc vc <<< "${MINER_DATA[$name]}"

    up_pct=$(awk -v v="$vc" -v e="$EXPECTED_POLLS" 'BEGIN{if(e>0)printf "%.0f", v/e*100; else print "0"}')

    if [[ "$vc" -eq 0 ]]; then
        FIELD_VALUES[$name]="❌ **Offline all day**"
        continue
    fi

    ha_th=$(awk -v g="$ha" 'BEGIN{printf "%.2f", g/1000}')
    miner_cost=$(awk -v k="$kwh" -v r="$POWER_RATE" 'BEGIN{printf "%.2f", k*r}')

    if [[ "$type" == "axeos" ]]; then
        # Full display — Today/Lifetime/Shares
        shares_fmt=$(fmt_num "$sd")
        if [[ "$tb" -gt 0 ]]; then
            today_fmt=$(fmt_diff "$tb")
        else
            today_fmt="—"
        fi
        lifetime_fmt=$(fmt_diff "$lb")
        FIELD_VALUES[$name]="⚡ ${ha_th} TH/s avg"$'\n'"🌡️ ${t}°C avg"$'\n'"🔋 ${pa}W | ${kwh} kWh | \$${miner_cost}"$'\n'"📈 ${shares_fmt} accepted | ${rd} rejected"$'\n'"🎯 Today: ${today_fmt}"$'\n'"🏆 Lifetime: ${lifetime_fmt}"$'\n'"📊 Uptime: ${up_pct}%"
    else
        # Canaan display — same layout as axeos, but:
        # - Today's best is always "—" (CGMiner exposes only lifetime "Best Share", no session split)
        # - Lifetime comes from "Best Share" field in summary command (logged into BestDiff column)
        # - Adds Mode line (Canaan-only useful field)
        mode_last=$(get_last_mode "$name")
        shares_fmt=$(fmt_num "$sd")
        lifetime_fmt=$(fmt_diff "$lb")
        FIELD_VALUES[$name]="⚡ ${ha_th} TH/s avg"$'\n'"🌡️ ${t}°C avg"$'\n'"🔋 ${pa}W | ${kwh} kWh | \$${miner_cost}"$'\n'"📈 ${shares_fmt} accepted | ${rd} rejected"$'\n'"🎯 Today: —"$'\n'"🏆 Lifetime: ${lifetime_fmt}"$'\n'"⏱️ Mode: ${mode_last}"$'\n'"📊 Uptime: ${up_pct}%"
    fi
done

# =============================================
# BUILD FLEET TOTAL FIELD
# =============================================
FLEET_SHARES_FMT=$(fmt_num "$FLEET_SHARES")
FLEET_VALUE="⚡ **Hash:** Avg ${FH_AVG_TH} TH/s | Peak ${FH_MAX_TH} TH/s | Low ${FH_MIN_TH} TH/s"$'\n'"🔋 **Power:** Avg ${FLEET_POWER_AVG}W | Total ${FLEET_KWH} kWh | Cost \$${DAILY_COST} CAD"$'\n'"📈 **Shares (NerdQaxe3):** ${FLEET_SHARES_FMT} accepted | ${FLEET_REJECTS} rejected"$'\n'"📊 **Fleet Uptime:** ${FLEET_UPTIME}%"

PROJECTION_VALUE="~${MONTHLY_KWH} kWh | ~\$${MONTHLY_COST} CAD"

# =============================================
# BUILD EMBED JSON
# =============================================
EMBED_JSON=$(jq -n \
    --arg title "⛏️ DGB Nerd/Nano — Daily Mining Summary" \
    --arg date "$TARGET_DATE" \
    --argjson color "$EMBED_COLOR" \
    --arg fleet "$FLEET_VALUE" \
    --arg m1n "${MINERS[0]%%:*}" --arg m1v "${FIELD_VALUES[${MINERS[0]%%:*}]}" \
    --arg m2n "${MINERS[1]%%:*}" --arg m2v "${FIELD_VALUES[${MINERS[1]%%:*}]}" \
    --arg pool "$POOL_VALUE" \
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
                { name: "🏊 Pool Context (DGB SmallMiners)", value: $pool, inline: false },
                { name: "💰 Monthly Projection", value: $proj, inline: false }
            ],
            footer: { text: ("Daily Mining Summary | " + $date + " | Power E01 @ 15.476¢/kWh") }
        }]
    }')

# =============================================
# OUTPUT
# =============================================
if [[ "$DRY_RUN" == "true" ]]; then
    echo "=== ⛏️ DGB Nerd/Nano — Daily Mining Summary ==="
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
    for miner_def in "${MINERS[@]}"; do
        IFS=':' read -r name type <<< "$miner_def"
        echo "--- $name ($type) ---"
        echo "${FIELD_VALUES[$name]}" | sed 's/\*\*//g'
        echo ""
    done
    echo "--- Pool Context (DGB SmallMiners) ---"
    echo "$POOL_VALUE" | sed 's/\*\*//g'
    echo ""
    echo "--- Monthly Projection ---"
    echo "$PROJECTION_VALUE"
    echo ""
    echo "(dry run — not sent to Discord)"
else
    send_webhook "$EMBED_JSON"
fi

exit 0
