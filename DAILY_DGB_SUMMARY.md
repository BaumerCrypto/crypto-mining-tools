# daily_dgb_summary.sh

Generates a daily Discord summary of your DGB SmallMiners pool fleet (NerdQaxe3 + Nano 3S in the reference setup) by parsing the log from `dgb_miners_monitor.sh`. Runs nightly via cron and sends a single embed covering the previous 24 hours — fleet totals, per-miner stats with type-aware display, live pool context from GSS, and monthly projection.

Requires `dgb_miners_monitor.sh` to be running on cron, and GSS running locally with the pool API exposed.

---

## How It Works

At 00:03 daily (via cron), the script:

1. Greps the previous day's `STATUS` lines from `dgb_miners_monitor.log`
2. For each miner, extracts hashrate, temp, power, shares, and best diff
3. For Canaan miners, also extracts current work mode
4. Detects miner restarts and accumulates share deltas across sessions (AxeOS only — Canaan doesn't expose session boundaries)
5. Calculates power consumption (kWh) and CAD cost from actual watt readings
6. Sums fleet totals
7. Pulls **pool context** from the GSS API (`/api/v1/DGB/metrics/pool` — the SmallMiners pool)
8. Projects monthly energy/cost from the day's data
9. Sends a color-coded Discord embed:
   - 🟢 **Green** — clean day, all miners ≥90% uptime, no rejected shares
   - 🟠 **Orange** — any rejected shares
   - 🔴 **Red** — any miner uptime < 90%

### Type-Aware Display

Both AxeOS and Canaan miners use the same embed layout, but with two important differences:

| Field | AxeOS (NerdQaxe3) | Canaan (Nano 3S) |
|-------|-------------------|------------------|
| 🎯 **Today's Best** | Session-aware logic (see `DAILY_BTC_FLEET_SUMMARY.md`) | Always `—` — CGMiner exposes only one lifetime counter, no session split |
| 🏆 **Lifetime Best** | From `bestDiff` field (lifetime miner counter) | From `Best Share` field in CGMiner `summary` command |
| ⏱️ **Mode** | Not shown | Shown — current work mode (`Eco`/`Standard`/`Super`) |

The script reads the miner type from the `Type:` field in each log line and branches the display logic accordingly.

---

## Configuration

Edit the variables at the top of the script:

```bash
LOG_FILE="/home/ubuntu/dgb_miners_monitor.log"
WEBHOOK_FILE="/home/ubuntu/Discord_Webhook_Summary.txt"
POWER_RATE=0.15476       # $/kWh
POLL_INTERVAL=5
EXPECTED_POLLS=288

# Miner definitions — "DisplayName:Type" — names must match column 3 of STATUS lines
MINERS=("NerdQaxe3:axeos" "Nano3S:canaan")

# GSS API endpoint for the DGB SmallMiners pool
GSS_API_POOL="http://127.0.0.1:4004/api/v1/DGB/metrics/pool"
```

Each entry in `MINERS` is `DisplayName:Type` where type is `axeos` or `canaan`. The display name must match what's in column 3 of the poller's `STATUS` lines.

Uses the shared `~/Discord_Webhook_Summary.txt` so all 3 daily summaries post to the same channel.

---

## Install

```bash
# Copy script to your monitoring server
cp daily_dgb_summary.sh /home/ubuntu/
chmod +x /home/ubuntu/daily_dgb_summary.sh

# Edit MINERS array
nano /home/ubuntu/daily_dgb_summary.sh

# Dry run for today (no Discord post)
/home/ubuntu/daily_dgb_summary.sh --today --dry-run

# Live test for today
/home/ubuntu/daily_dgb_summary.sh --today

# Add to cron — 00:03, staggered after Avalon Q (00:01) and BTC Fleet (00:02)
crontab -e
```

Add this line:

```
3 0 * * * /home/ubuntu/daily_dgb_summary.sh
```

### Requirements

- `curl` — Discord webhooks + GSS API
- `jq` — JSON for both Discord embed construction and GSS pool data
- `grep` with `-P` (Perl regex) — log parsing
- `awk` — stats computation
- `dgb_miners_monitor.sh` actively logging
- GSS running locally with API accessible

```bash
sudo apt install curl jq
```

---

## Command Line Options

| Flag | Effect |
|------|--------|
| `--dry-run` | Print summary to terminal, don't send to Discord |
| `--date YYYY-MM-DD` | Generate for a specific date (default: yesterday) |
| `--today` | Generate for today (partial day) |
| `--help` | Show usage |

```bash
# Normal: yesterday, sent to Discord
./daily_dgb_summary.sh

# Test today's data without sending
./daily_dgb_summary.sh --today --dry-run

# Generate for a specific past date
./daily_dgb_summary.sh --date 2026-06-05
```

---

## Example Discord Embed

![DGB Nerd/Nano daily summary embed](screenshots/dgb-nerd-nano-daily-discord.jpg)

> The screenshot above shows the embed with a **red left border** because the DGB poller had only been running for a few minutes when this summary fired — uptime came in low. A full-day clean run would show green.

Embed structure:

| Field | Layout | Contents |
|-------|--------|----------|
| 📊 **Fleet Total** | Full width | Combined hashrate (avg/peak/low), total kWh, cost, total shares (from AxeOS only), fleet uptime % |
| Per-miner blocks | 2 inline columns | NerdQaxe3 + Nano 3S side by side |
| 🏊 **Pool Context (DGB SmallMiners)** | Full width | Live GSS API stats for the pool |
| 💰 **Monthly Projection** | Full width | 30-day kWh + cost extrapolation |

Per-miner column layout (both types use the same shape):

```
⚡ X.XX TH/s avg
🌡️ XX.X°C avg
🔋 XXW | X.XX kWh | $X.XX
📈 XXX accepted | 0 rejected
🎯 Today: XX.XXM   (axeos) or — (canaan, always)
🏆 Lifetime: XX.XXG
⏱️ Mode: Eco       (canaan only)
📊 Uptime: XX%
```

---

## Pool Context Section

The script makes one HTTP call to `http://127.0.0.1:4004/api/v1/DGB/metrics/pool` and extracts:

| Field | API path | Display |
|-------|----------|---------|
| Pool hashrate (15-min avg) | `.hashrate."15m"` | TH/s + % of network |
| Network share | `.network_comparison.pool_percentage` | percentage |
| Estimated time to block | `.network_comparison.estimated_time_to_block` | human-readable |
| Lifetime blocks found | `.blocks_found` | count |
| Active miners | `.active_miners` | count |

If the API call fails, the section shows `❌ Pool data unavailable` and everything else still renders. The script never aborts on pool context failure.

To target a different GSS pool, change `GSS_API_POOL` to point to its endpoint. For example, change `/api/v1/DGB/metrics/pool` to `/api/v1/DGB-BIGMINERS/metrics/pool` to target the BigMiners pool instead.

---

## What the Stats Mean

**Per-miner avg hashrate** — Computed from the `Hash:` field in every poll. GH/s in the log, converted to TH/s in the embed.

**Share counters (AxeOS)** — Restart-aware delta as described in `DAILY_BTC_FLEET_SUMMARY.md`. AxeOS `sharesAccepted` is session-cumulative; the script sums deltas across reboots.

**Share counters (Canaan)** — From the CGMiner `summary` command. Same restart-aware delta logic applies, but Canaan miners typically have longer uptimes so resets are rarer.

**🎯 Today's Best** — Always `—` for Canaan miners. CGMiner exposes only one lifetime `Best Share` value with no session boundaries, so there's no way to compute "best share submitted today" from CGMiner data. The AxeOS column uses the same session-aware logic described in the BTC Fleet doc.

**🏆 Lifetime Best** — For AxeOS, the `bestDiff` field (all-time miner counter). For Canaan, the `Best Share` field from CGMiner `summary` — also lifetime, just labeled differently.

**⏱️ Mode (Canaan only)** — Current work mode at the last poll of the target day. Useful for spotting whether the miner spent time in Eco vs Standard, though Canaan miners typically don't auto-switch the way the Avalon Q does.

**Fleet Uptime** — `(sum of valid polls across all miners) / (288 × number of miners) × 100`.

**Monthly Projection** — Extrapolates the day's energy use to 30 days, scaling up partial days.

---

## Color Logic

| Color | Trigger |
|-------|---------|
| 🟢 Green (`3066993`) | All miners ≥ 90% uptime, no rejected shares |
| 🟠 Orange (`16744448`) | Any miner has rejected shares for the day |
| 🔴 Red (`16711680`) | Any miner < 90% uptime |

Red takes precedence over orange.

---

## Troubleshooting

**Pool Context shows "Pool data unavailable":** GSS API isn't responding. Check:

```bash
curl -s http://127.0.0.1:4004/api/v1/DGB/metrics/pool | jq .
```

If this errors, GSS is down or the API endpoint changed. The rest of the embed will still render correctly.

**Canaan miner showing zeros for shares:** The `summary` command failed but `stats` succeeded — check the poller log. Older CGMiner builds (pre-4.x) may not support `summary`.

**Nano 3S "Today" always shows `—`:** That's correct behavior. CGMiner doesn't expose session-level best diff on Canaan devices, only a single lifetime counter. There's no way to compute "today's best" from CGMiner data.

**`Mode:` line missing on Canaan column:** The poller didn't capture a `Mode:` field. Check `dgb_miners_monitor.log` for the relevant `STATUS` lines — the `Mode:` field should appear for `Type:canaan` entries.

**jq error:** Install with `sudo apt install -y jq`.

---

## Related Scripts

- **`dgb_miners_monitor.sh`** — The poller that writes `dgb_miners_monitor.log`. Must be running on `*/5 * * * *` cron.
- **`daily_mining_summary.sh`** — Avalon Q daily summary. Fires at `1 0 * * *`.
- **`daily_btc_fleet_summary.sh`** — BTC fleet daily summary. Fires at `2 0 * * *`.

This script fires at `3 0 * * *` so it's the last of the three daily summaries to arrive each night.
