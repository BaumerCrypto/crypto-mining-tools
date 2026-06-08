# btc_fleet_monitor.sh

Polls a fleet of BTC ASIC miners running AxeOS (Bitaxe, NerdQAxe family) every 5 minutes and writes normalized status lines to a log file. No alerting — pure data collection to feed `daily_btc_fleet_summary.sh`.

GSSM (the miner dashboard) already handles real-time miner alerts. This script exists only to give the daily summary script clean structured data to parse.

---

## How It Works

Every 5 minutes (via cron), the script:

1. Iterates over the configured list of miners
2. For each miner, GETs `http://{ip}/api/system/info` (AxeOS REST API on port 80)
3. Parses the JSON response with `jq`
4. Writes a single normalized `STATUS` line to the log per miner
5. If a miner is unreachable or returns invalid JSON, logs that fact explicitly so the summary script can compute accurate uptime %

No alerting fires from this script. GSSM owns that responsibility.

---

## Configuration

Edit the variables at the top of the script:

```bash
# Format: "DisplayName:IP" — display name MUST be unique per miner.
# The summary script groups by display name.
MINERS=(
    "NerdQaxe1:192.168.0.95"
    "NerdQaxe2:192.168.0.182"
    "NerdQX:192.168.0.109"
)

LOG_FILE="/home/ubuntu/btc_fleet_monitor.log"
HTTP_TIMEOUT=8     # seconds — keep tight so cron job finishes well under 5min
```

Adding miners is just appending another `"DisplayName:IP"` entry to the array. The summary script automatically picks up whatever names appear in the log.

---

## Log Format

One line per miner per poll. Example:

```
2026-06-07 18:09:00 | STATUS | NerdQaxe1 | Host:192.168.0.95 Hash:4768.4GH/s H1m:4775.0 H10m:4770.2 Temp:60.1C VRTemp:54C Power:88W Fan:42% RPM:1890 Accepted:312 Rejected:0 BestDiff:39328411 BestSession:25109933 Uptime:142500 FW:v1.0.37.1 PoolConn:true Stratum:datum.local:23334
```

When a miner is unreachable:

```
2026-06-07 18:09:00 | STATUS | NerdQaxe2 | Host:192.168.0.182 UNREACHABLE
```

When the response isn't valid JSON (rare — usually a firmware issue):

```
2026-06-07 18:09:00 | STATUS | NerdQaxe2 | Host:192.168.0.182 INVALID_JSON
```

### Field Reference

| Field | Source | Notes |
|-------|--------|-------|
| `Hash` | `hashRate` | Current GH/s |
| `H1m` / `H10m` | `hashRate_1m` / `hashRate_10m` | Moving averages |
| `Temp` | `temp` | ASIC chip temp, °C |
| `VRTemp` | `vrTemp` | Voltage regulator temp, °C |
| `Power` | `power` | Watts (rounded) |
| `Fan` / `RPM` | `fanspeed` / `fanrpm` | % duty + actual RPM |
| `Accepted` / `Rejected` | `sharesAccepted` / `sharesRejected` | **Session-cumulative** — resets to 0 on miner reboot |
| `BestDiff` | `bestDiff` | Lifetime best share difficulty |
| `BestSession` | `bestSessionDiff` | Session best (resets on reboot) |
| `Uptime` | `uptimeSeconds` | Used by the summary script to detect whether a session started today |
| `FW` | `version` | Firmware version |
| `PoolConn` | `stratum.pools[0].connected` | True if connected to primary pool |
| `Stratum` | `stratumURL:stratumPort` | Current pool endpoint |

---

## Install

```bash
# Copy script to your monitoring server
cp btc_fleet_monitor.sh /home/ubuntu/
chmod +x /home/ubuntu/btc_fleet_monitor.sh

# Edit the MINERS array with your miner IPs
nano /home/ubuntu/btc_fleet_monitor.sh

# Test it
/home/ubuntu/btc_fleet_monitor.sh
cat /home/ubuntu/btc_fleet_monitor.log

# Add to cron (every 5 minutes)
crontab -e
```

Add this line:

```
*/5 * * * * /home/ubuntu/btc_fleet_monitor.sh
```

### Requirements

- `curl` — HTTP requests to AxeOS API
- `jq` — JSON parsing
- `awk` — number formatting

```bash
sudo apt install curl jq
```

---

## Log Rotation

The script doesn't rotate its own log. Add a separate cron job to trim it nightly:

```
0 0 * * * tail -36000 /home/ubuntu/btc_fleet_monitor.log > /home/ubuntu/btc_fleet_monitor.log.tmp && mv /home/ubuntu/btc_fleet_monitor.log.tmp /home/ubuntu/btc_fleet_monitor.log
```

36,000 lines = 288 polls × 3 miners × ~42 days. Adjust if you have more miners or want a different retention window.

---

## Troubleshooting

**All miners showing `UNREACHABLE`:** Check network from the monitoring host to the miners (`ping` and `curl http://{ip}/api/system/info` manually). Firewall, VLAN routing, or a downed WiFi extender are common culprits.

**One miner intermittently UNREACHABLE:** Usually weak WiFi signal if the miner is on a hidden SSID via an extender. Try moving the extender or hardwiring the miner.

**`INVALID_JSON` lines:** AxeOS firmware bug — restart the affected miner. If persistent, check the firmware release notes for known issues at https://github.com/shufps/ESP-Miner-NerdQAxePlus/releases.

**`HTTP_TIMEOUT` too short:** If the cron job is overlapping with the next 5-minute run, bump `HTTP_TIMEOUT` down (not up) — a stuck miner should fail fast, not block the whole poll cycle.

---

## Adapting for Other AxeOS Miners

This works with any AxeOS-based miner: Bitaxe, NerdQAxe, NerdQAxe+, NerdQAxe++, NerdQX. All expose the same `/api/system/info` endpoint with identical field names.

For non-AxeOS BTC miners (Bitmain, MicroBT, etc.), you'd need to rewrite `poll_miner()` to speak their API format. The `STATUS` line format and the summary script's parser would stay the same — just normalize the field names you write to the log.
