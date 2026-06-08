# dgb_miners_monitor.sh

Polls a fleet of DGB-mining ASICs every 5 minutes and writes normalized status lines to a log file. Handles two device types simultaneously: AxeOS miners over HTTP (NerdQAxe family) and Canaan CGMiner miners over TCP (Avalon Nano 3S, Avalon Q). No alerting — pure data collection to feed `daily_dgb_summary.sh`.

GSSM (the miner dashboard) already handles real-time miner alerts. This script exists only to give the daily summary script clean structured data across both miner types.

---

## How It Works

Every 5 minutes (via cron), the script:

1. Iterates over the configured list of miners
2. For each miner, calls the right poller based on type:
   - `axeos` → HTTP GET to `http://{ip}/api/system/info`
   - `canaan` → TCP socat to `{ip}:4028` (CGMiner API)
3. Parses the response and writes a single normalized `STATUS` line per miner
4. Logs `UNREACHABLE` if a poll fails, so the summary script can compute accurate uptime %

### Why Two Code Paths?

AxeOS and Canaan use completely different APIs:

| Aspect | AxeOS (NerdQAxe3) | Canaan (Nano 3S, Avalon Q) |
|---|---|---|
| Protocol | HTTP REST on port 80 | TCP socket on port 4028 |
| Format | JSON | Pipe-separated text with `Field[value]` brackets |
| Best share | Lifetime + session counters separately | Single lifetime counter only |
| Field path | Single endpoint returns everything | Requires two commands: `stats` + `summary` |

The script abstracts this so the log format is identical regardless of miner type — the summary script doesn't need to know which kind of miner it's parsing.

### Two CGMiner Commands for Canaan

The Canaan path makes two API calls per poll:

- **`stats`** — returns hashrate, temps, fan, power, uptime, workmode (bracket syntax: `GHSspd[3501.4]`)
- **`summary`** — returns Accepted, Rejected, Best Share (comma key=value syntax: `Accepted=116,Best Share=5932201`)

The `stats` command alone doesn't expose share counters on the Nano 3S. The `summary` command does, but uses a different syntax. The poller normalizes both into the same log line.

---

## Configuration

Edit the variables at the top of the script:

```bash
# Format: "DisplayName:Type:IP"
# Type is 'axeos' (HTTP /api/system/info) or 'canaan' (TCP CGMiner stats+summary)
MINERS=(
    "NerdQaxe3:axeos:192.168.0.93"
    "Nano3S:canaan:192.168.0.162"
)

LOG_FILE="/home/ubuntu/dgb_miners_monitor.log"
HTTP_TIMEOUT=8           # seconds for AxeOS HTTP calls
TCP_TIMEOUT=10           # seconds for Canaan socat calls
CANAAN_API_PORT=4028     # standard CGMiner port
```

To add miners, append another `"DisplayName:Type:IP"` entry. The summary script picks up whatever names appear in the log.

---

## Log Format

One line per miner per poll. Both device types produce a normalized format.

**AxeOS example (NerdQaxe3):**

```
2026-06-07 18:09:00 | STATUS | NerdQaxe3 | Host:192.168.0.93 Type:axeos Hash:5528.9GH/s H1m:5521.8 H10m:5521.7 Temp:60.0C VRTemp:54C Power:109W Fan:43% RPM:1890 Accepted:34008 Rejected:0 BestDiff:45091723569 BestSession:844355894 Uptime:429980 FW:v1.0.37.1 PoolConn:true
```

**Canaan example (Nano 3S):**

```
2026-06-07 18:09:00 | STATUS | Nano3S | Host:192.168.0.162 Type:canaan Hash:3495.4GH/s Temp:82.0C TAvg:79C Power:62W Fan:15% RPM:660 Mode:Eco Uptime:2713 Accepted:128 Rejected:0 BestDiff:5932201 BestSession:-
```

**Unreachable:**

```
2026-06-07 18:09:00 | STATUS | NerdQaxe3 | Host:192.168.0.93 Type:axeos UNREACHABLE
```

### Field Reference

Common fields (both types):

| Field | Notes |
|-------|-------|
| `Type` | `axeos` or `canaan` — disambiguates which fields are populated |
| `Hash` | Current GH/s (normalized — AxeOS native, Canaan converted from `GHSspd`) |
| `Temp` | ASIC chip temp, °C |
| `Power` | Watts (rounded) |
| `Fan` / `RPM` | % duty + RPM (Canaan reports max of available fans) |
| `Uptime` | Seconds since last reboot |
| `Accepted` / `Rejected` | Share counters (session-cumulative on both) |
| `BestDiff` | Best share difficulty |
| `BestSession` | Session best — **set to `-` for Canaan** (CGMiner exposes only one lifetime counter, not session) |

AxeOS-only fields:

| Field | Notes |
|-------|-------|
| `H1m` / `H10m` | Moving-average hashrates |
| `VRTemp` | Voltage regulator temp |
| `FW` | Firmware version |
| `PoolConn` | Pool connectivity boolean |

Canaan-only fields:

| Field | Notes |
|-------|-------|
| `TAvg` | Average chip temp (vs `Temp` which is `TMax`) |
| `Mode` | `Eco` / `Standard` / `Super` — decoded from `WORKMODE` integer |

---

## Install

```bash
# Copy script to your monitoring server
cp dgb_miners_monitor.sh /home/ubuntu/
chmod +x /home/ubuntu/dgb_miners_monitor.sh

# Edit the MINERS array with your miner IPs and types
nano /home/ubuntu/dgb_miners_monitor.sh

# Test it
/home/ubuntu/dgb_miners_monitor.sh
cat /home/ubuntu/dgb_miners_monitor.log

# Add to cron (every 5 minutes)
crontab -e
```

Add this line:

```
*/5 * * * * /home/ubuntu/dgb_miners_monitor.sh
```

### Requirements

- `curl` — AxeOS HTTP requests
- `socat` — Canaan CGMiner TCP communication
- `jq` — JSON parsing for AxeOS
- `awk` / `grep` — number and field extraction

```bash
sudo apt install curl jq socat
```

---

## Log Rotation

Add a separate cron job to trim the log nightly:

```
0 0 * * * tail -24000 /home/ubuntu/dgb_miners_monitor.log > /home/ubuntu/dgb_miners_monitor.log.tmp && mv /home/ubuntu/dgb_miners_monitor.log.tmp /home/ubuntu/dgb_miners_monitor.log
```

24,000 lines = 288 polls × 2 miners × ~42 days.

---

## Known Quirks

**Canaan `FanR[%]` formatting differs by model:**
- Avalon Q returns `FanR[15]` (number only)
- Nano 3S returns `FanR[15%]` (number with `%` inside brackets)

The script strips the trailing `%` with `${fan_pct%\%}` so the log shows `Fan:15%` cleanly in both cases.

**Nano 3S `litestats` is sparse — `stats` is required:**
The Avalon Q's `litestats` command returns rich data (TMax, MPO, Elapsed, etc.). The Nano 3S's `litestats` is sparse. The script uses `stats` (full bracket-syntax output) for Canaan devices to get full coverage.

**Canaan share counters aren't in `stats`:**
Accepted/Rejected/Best Share are only exposed via the `summary` command, which uses a different output syntax (`Field=value,`) than `stats` (`Field[value]`). The poller makes two calls and parses each output differently.

---

## Troubleshooting

**Canaan miner showing `UNREACHABLE` but pingable:** CGMiner API may not be enabled. On Avalon devices, check that port 4028 is open (`nc -zv {ip} 4028`). Some firmware versions disable the API by default.

**AxeOS miner showing `UNREACHABLE`:** Same diagnostic as `btc_fleet_monitor.sh` — usually weak WiFi or extender issue.

**`Accepted:-` and `BestDiff:-` on Canaan:** The `summary` call failed but `stats` succeeded. Check that the miner's CGMiner version supports the `summary` command (4.x+ does). Older firmware or non-standard CGMiner builds may not.

**Fields appearing as `0`:** Canaan field name mismatch. Different Canaan models expose slightly different field names. Add a new `canaan_field` call in `poll_canaan()` if you see a missing-but-expected field.

---

## Adapting for Other Hardware

**Adding another AxeOS miner:** Just add a `"Name:axeos:IP"` line to the `MINERS` array. No code changes.

**Adding another Canaan miner:** Same — `"Name:canaan:IP"`. Hashrate normalization assumes `GHSspd` is in GH/s (true for Avalon Q ~80,000 and Nano 3S ~3,700). Other Canaan models follow the same convention.

**Other ASIC brands:** Add a third type (e.g., `bitmain`) and write a `poll_bitmain()` function that produces the same normalized `STATUS` line format. The dispatch logic in the main loop just needs a new `case` entry. Summary script doesn't need to change.
