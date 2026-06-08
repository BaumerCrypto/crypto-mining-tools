# daily_mining_summary.sh

Generates a daily Discord summary of your Avalon Q mining stats by parsing the log from `avalon_temp_monitor.sh`. Runs nightly via cron and sends a single embed covering the previous 24 hours — hashrate, temperatures, power consumption, cost, mode split, uptime, events, lifetime best share, pool context, and monthly projection.

Requires `avalon_temp_monitor.sh` to be running on cron and writing to its log file. The pool context section also requires GSS (GoSlimStratum) running locally with the API exposed.

---

## How It Works

At 00:01 daily (via cron), the script:

1. Greps the previous day's entries from `avalon_monitor.log`
2. Extracts hashrate, TMax, power, fan, and mode from every `STATUS` line
3. Calculates averages, peaks, lows, and totals
4. Computes power consumption (kWh) from actual watt readings (not estimated from mode)
5. Calculates daily cost using your electricity rate
6. Counts events (mode switches, alerts, emergencies)
7. Pulls the **lifetime best share** and **pool context** from the GSS API (`/api/v1/DGB-BIGMINERS/metrics/pool`)
8. Projects monthly energy and cost
9. Sends a color-coded Discord embed:
   - 🟢 **Green** — clean day
   - 🟠 **Orange** — mode switches or alerts fired
   - 🔴 **Red** — emergencies

---

## Configuration

Edit the variables at the top of the script:

```bash
LOG_FILE="/home/ubuntu/avalon_monitor.log"               # Path to avalon_temp_monitor.sh log
WEBHOOK_FILE="/home/ubuntu/Discord_Webhook_Summary.txt"  # Discord webhook for summary channel
POWER_RATE=0.15476       # Your electricity rate in $/kWh (default: SaskPower E01)
POLL_INTERVAL=5          # Must match your avalon_temp_monitor.sh cron interval
EXPECTED_POLLS=288       # 24h * 60min / POLL_INTERVAL = expected polls per day

# GSS API endpoint for the pool your Avalon Q is on
GSS_API_POOL="http://127.0.0.1:4004/api/v1/DGB-BIGMINERS/metrics/pool"
```

### Discord Webhook

This script uses a **separate webhook file** from the alert scripts, so the daily summary goes to its own channel:

```bash
echo "https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN" > ~/Discord_Webhook_Summary.txt
chmod 600 ~/Discord_Webhook_Summary.txt
```

### Electricity Rate

Update `POWER_RATE` to your local rate. The default is 15.476 ¢/kWh CAD (SaskPower E01 residential rate, effective Feb 1, 2026). Find your rate on your power bill or your utility's website.

### Pool Context

If you don't run GSS or your pool doesn't expose the metrics API, the script degrades gracefully — the embed shows `❌ Pool data unavailable` for that section but everything else renders normally.

---

## Install

```bash
# Copy script to your monitoring server
cp daily_mining_summary.sh /home/ubuntu/
chmod +x /home/ubuntu/daily_mining_summary.sh

# Edit configuration (set your electricity rate and GSS endpoint if needed)
nano /home/ubuntu/daily_mining_summary.sh

# Test it (dry run — prints to terminal, doesn't send to Discord)
/home/ubuntu/daily_mining_summary.sh --today --dry-run

# Test for real (sends today's partial data to Discord)
/home/ubuntu/daily_mining_summary.sh --today

# Add to cron — fires at 00:01 nightly so all log rotations at 00:00 finish first
crontab -e
```

Add this line:

```
1 0 * * * /home/ubuntu/daily_mining_summary.sh
```

### Requirements

- `curl` — Discord webhook calls and GSS API requests
- `jq` — JSON parsing for pool context
- `grep` with `-P` (Perl regex) — log parsing
- `awk` — stats computation
- `avalon_temp_monitor.sh` actively logging to `avalon_monitor.log`

```bash
sudo apt install curl jq
```

---

## Command Line Options

| Flag | Effect |
|------|--------|
| `--dry-run` | Print summary to terminal instead of sending to Discord |
| `--date YYYY-MM-DD` | Generate for a specific date (default: yesterday) |
| `--today` | Generate for today (partial day — useful for testing) |
| `--help` | Show usage |

**Examples:**

```bash
# Normal: yesterday, sent to Discord (this is what cron runs)
./daily_mining_summary.sh

# Test without sending
./daily_mining_summary.sh --today --dry-run

# Generate for a specific past date
./daily_mining_summary.sh --date 2026-06-03

# Generate for a past date, dry run
./daily_mining_summary.sh --date 2026-06-03 --dry-run
```

---

## Example Discord Embed

![Avalon Q daily summary embed](screenshots/avalon-q-daily-discord.jpg)

The embed has 9 sections:

| Section | What's in it |
|---------|--------------|
| ⚡ **Hashrate** | Avg / Peak / Low across the day |
| 🌡️ **Temperature (TMax)** | Daily high / low / average chip temp |
| 🔋 **Power** | Avg watts, total kWh, daily cost in CAD |
| ⏱️ **Mode Split** | % of polls in each work mode |
| 🌀 **Fan Avg** | Average fan duty cycle |
| 📊 **Uptime** | Valid polls vs expected (288 for full day) |
| ⚠️ **Events** | Count of mode switches, alerts, emergencies |
| 🏆 **Lifetime Best** | Best share difficulty ever submitted to the pool |
| 🏊 **Pool Context** | Live pool stats from GSS API |
| 💰 **Monthly Projection** | Extrapolated 30-day kWh + cost |

---

## What the Stats Mean

**Hashrate** — Parsed from actual `Hash:` values in the log. Avg reflects the blended rate across modes. If the miner spent time in Eco, the average will be lower than Standard-mode peak.

**Power kWh** — Calculated from the actual `Power:` readings in the log (not estimated from mode). Each 5-minute poll contributes `wattage × 5 / 60 / 1000` kWh to the daily total. This is real measured power from the miner's PSU reporting, which is more accurate than multiplying nominal mode wattage by hours.

**Monthly Projection** — Extrapolates the day's energy use to a full 30-day month. If the day was partial (e.g., miner was off for some hours), the projection scales to a full 24h first, then multiplies by 30. A half-day of mining won't project a half-month — it assumes the rest of the day would have matched.

**Mode Split** — Shows what percentage of polls the miner was in each mode. High Eco % means the miner ran hot and the auto-switch kicked in frequently. Track this over time — if Eco % is climbing day over day, your cooling may need attention.

**Events** — Counts of `ACTION` (mode switches), `ALERT` (fan/hardware issues), `EMERGENCY` (shutdown sequences), and `WARN` (zero hashrate, CRC errors) log lines for the day.

**Lifetime Best** — Pulled live from GSS API (`pool_best_share` field). For a single-miner pool, this equals the miner's all-time best share. Formatted with `T/G/M/K` suffixes for readability.

---

## Pool Context Section

The script makes one HTTP call to `http://127.0.0.1:4004/api/v1/{POOL_NAME}/metrics/pool` and extracts:

| Field | API path | Display |
|-------|----------|---------|
| Pool hashrate (15-min avg) | `.hashrate."15m"` | TH/s + % of network |
| Network share | `.network_comparison.pool_percentage` | percentage |
| Estimated time to block | `.network_comparison.estimated_time_to_block` | human-readable |
| Lifetime blocks found | `.blocks_found` | count |
| Active miners | `.active_miners` | count |

If `jq` is missing or the API is unreachable, the section shows `❌ Pool data unavailable` and everything else still renders. The script never aborts on pool context failure.

To use a different pool, change `GSS_API_POOL` to point to your pool's API endpoint. GSS endpoints follow the pattern `/api/v1/{POOL_NAME}/metrics/pool` — for example, swapping `DGB-BIGMINERS` for `DGB` gives you the SmallMiners pool.

---

## Color Logic

| Color | Trigger |
|-------|---------|
| 🟢 Green (`3066993`) | No actions, no alerts, no emergencies |
| 🟠 Orange (`16744448`) | One or more `ACTION` (mode switches) or `ALERT` (hardware) events |
| 🔴 Red (`16711680`) | One or more `EMERGENCY` events (shutdown sequences) |

Red takes precedence over orange. A day with both alerts and an emergency shows red.

---

## Log Format Expected

The script parses this exact format from `avalon_temp_monitor.sh`:

```
2026-06-05 20:15:01 | STATUS | Mode:Eco TMax:71°C TAvg:66°C HBOut:63°C Fan:100% Hash:51.1TH/s Power:800W Fans:[2863 2862 2957 2935]
```

Other log lines (`ACTION`, `ALERT`, `EMERGENCY`, `WARN`, `LOCKOUT`, `BOOT`) are counted but not parsed for stats.

---

## Adapting for Other Miners

The script depends on the log format above. If you adapt `avalon_temp_monitor.sh` for a different miner brand, this summary script will work automatically as long as the `STATUS` line format stays the same — same field names (`Mode:`, `TMax:`, `Hash:`, `Power:`, `Fan:`).

For non-Canaan miners (Bitmain, MicroBT, AxeOS, etc.), use the matching summary in this repo instead:
- AxeOS fleet → `daily_btc_fleet_summary.sh`
- Mixed AxeOS + Canaan on DGB → `daily_dgb_summary.sh`

To support a brand-new format, the cleanest path is rewriting the field-extraction regex in this script while keeping the embed-building logic intact.
