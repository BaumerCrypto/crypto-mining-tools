# daily_mining_summary.sh

Generates a daily Discord summary of your Avalon Q mining stats by parsing the log from `avalon_temp_monitor.sh`. Runs at midnight via cron and sends a single embed covering the previous 24 hours — hashrate, temperatures, power consumption, cost, mode split, uptime, and events.

Requires `avalon_temp_monitor.sh` to be running on cron and writing to its log file.

---

## How It Works

At midnight (via cron), the script:

1. Greps the previous day's entries from `avalon_monitor.log`
2. Extracts hashrate, TMax, power, fan, and mode from every STATUS line
3. Calculates averages, peaks, lows, and totals
4. Computes power consumption (kWh) from actual watt readings (not estimated from mode)
5. Calculates daily cost using your electricity rate
6. Counts events (mode switches, alerts, emergencies)
7. Projects monthly energy and cost
8. Sends a color-coded Discord embed (green = clean day, orange = events, red = emergencies)

---

## Configuration

Edit the variables at the top of the script:

```bash
LOG_FILE="/home/ubuntu/avalon_monitor.log"          # Path to avalon_temp_monitor.sh log
WEBHOOK_FILE="/home/ubuntu/Discord_Webhook_Summary.txt"  # Discord webhook for summary channel
POWER_RATE=0.15476      # Your electricity rate in $/kWh (default: SaskPower E01, 15.476¢/kWh)
POLL_INTERVAL=5         # Must match your avalon_temp_monitor.sh cron interval
EXPECTED_POLLS=288      # 24h * 60min / POLL_INTERVAL = expected polls per day
```

### Discord Webhook

This script uses a **separate webhook file** from the alert scripts, so the daily summary goes to its own channel. Set it up the same way:

```bash
echo "https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN" > ~/Discord_Webhook_Summary.txt
chmod 600 ~/Discord_Webhook_Summary.txt
```

### Electricity Rate

Update `POWER_RATE` to match your local rate. The default is SaskPower's E01 residential rate (15.476 ¢/kWh CAD, effective February 1, 2026). Find your rate on your power bill or your utility's website.

---

## Install

```bash
# Copy script to your monitoring server
cp daily_mining_summary.sh /home/ubuntu/
chmod +x /home/ubuntu/daily_mining_summary.sh

# Edit configuration (set your electricity rate if not SaskPower)
nano /home/ubuntu/daily_mining_summary.sh

# Test it (dry run — prints to terminal, doesn't send to Discord)
/home/ubuntu/daily_mining_summary.sh --today --dry-run

# Test for real (sends to Discord for today's partial data)
/home/ubuntu/daily_mining_summary.sh --today

# Add to cron (midnight daily)
crontab -e
```

Add this line:

```
0 0 * * * /home/ubuntu/daily_mining_summary.sh
```

### Requirements

- `curl` — Discord webhook calls
- `grep` with `-P` (Perl regex) — log parsing
- `awk` — stats computation
- `avalon_temp_monitor.sh` actively logging to `avalon_monitor.log`

All of these are already present if you're running `avalon_temp_monitor.sh`.

---

## Command Line Options

| Flag | What It Does |
|------|-------------|
| `--dry-run` | Print summary to terminal instead of sending to Discord |
| `--date YYYY-MM-DD` | Generate summary for a specific date (instead of yesterday) |
| `--today` | Generate summary for today (partial day — useful for testing) |
| `--help` | Show usage |

**Examples:**

```bash
# Normal run (summarizes yesterday, sends to Discord)
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

**Clean day (green):**

> **⛏️ Avalon Q — Daily Mining Summary**
>
> ⚡ **Hashrate:** Avg 78.4 TH/s | Peak 85.1 TH/s | Low 51.1 TH/s
> 🌡️ **Temperature (TMax):** High 91°C | Low 71°C | Avg 83°C
> 🔋 **Power:** Avg 1192W | Total 28.62 kWh | Cost $4.43 CAD
> ⏱️ **Mode Split:** Standard 80.2% (231) | Eco 19.8% (57)
> 🌀 **Fan Avg:** 87%
> 📊 **Uptime:** 100.0% (288 of 288 polls)
> ⚠️ **Events:** None — clean day ✅
> 💰 **Monthly Projection:** ~858.5 kWh | ~$132.87 CAD

**Day with events (orange):**

> **⛏️ Avalon Q — Daily Mining Summary**
>
> ⚡ **Hashrate:** Avg 62.3 TH/s | Peak 84.9 TH/s | Low 51.1 TH/s
> 🌡️ **Temperature (TMax):** High 94°C | Low 68°C | Avg 79°C
> 🔋 **Power:** Avg 985W | Total 23.64 kWh | Cost $3.66 CAD
> ⏱️ **Mode Split:** Standard 45.1% (130) | Eco 54.9% (158)
> 🌀 **Fan Avg:** 93%
> 📊 **Uptime:** 100.0% (288 of 288 polls)
> ⚠️ **Events:** 2 mode switches | 1 alerts
> 💰 **Monthly Projection:** ~709.2 kWh | ~$109.75 CAD

---

## What the Stats Mean

**Hashrate** — Parsed from actual `Hash:` values in the log. Avg reflects the blended rate across modes. If the miner spent time in Eco, the average will be lower than Standard-mode peak.

**Power kWh** — Calculated from the actual `Power:` readings in the log (not estimated from mode). Each 5-minute poll contributes its wattage × 5 minutes to the daily total. This is real measured power from the miner's PSU reporting, which is more accurate than multiplying nominal mode wattage by hours.

**Monthly Projection** — Extrapolates the day's energy use to a full 30-day month. If the day was partial (e.g., miner was off for some hours), the projection scales to a full 24h first, then multiplies by 30. This means a half-day of mining won't project a half-month — it assumes the rest of the day would have matched.

**Mode Split** — Shows what percentage of polls the miner was in each mode. High Eco % means the miner ran hot and the auto-switch kicked in frequently. Track this over time — if Eco % is climbing day over day, your cooling may need attention.

**Events** — Counts of ACTION (mode switches), ALERT (fan/hardware issues), EMERGENCY (shutdown sequences), and WARN (zero hashrate, CRC errors) log lines for the day.

---

## Adapting for Other Miners

The script parses this exact log format from `avalon_temp_monitor.sh`:

```
2026-06-05 20:15:01 | STATUS | Mode:Eco TMax:71°C TAvg:66°C HBOut:63°C Fan:100% Hash:51.1TH/s Power:800W Fans:[2863 2862 2957 2935]
```

If you adapt `avalon_temp_monitor.sh` for a different miner, this summary script will work automatically as long as the STATUS line format stays the same.
