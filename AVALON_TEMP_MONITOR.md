# avalon_temp_monitor.sh

ASIC temperature monitor and auto-switch script for Canaan Avalon miners via the CGMiner API. Monitors chip temps, fan health, hashboard diagnostics, and crash detection. Automatically switches work modes to protect hardware and fires Discord alerts on state changes.

Works with any CGMiner-compatible ASIC — see [Adapting for Other Hardware](#adapting-for-other-hardware) at the bottom.

---

## How It Works

Every 5 minutes (via cron), the script:

1. Queries the miner's CGMiner API using `socat` (sends `litestats` command to port 4028)
2. Parses the response for temperatures, hashrate, fan status, and hardware diagnostics
3. Runs health checks (fans, hashboard, control board, crash detection, boot reason)
4. Evaluates temperature thresholds and takes action if needed (mode switch, emergency shutdown)
5. Logs everything and fires Discord alerts on state changes

---

## Configuration

Edit the variables at the top of the script:

```bash
AVALON_IP="YOUR_MINER_IP"         # Miner LAN IP (e.g. 192.168.0.116)
API_PORT="4028"                    # CGMiner API port (default 4028)

# Temperature thresholds (°C) — TMax = hottest ASIC chip
TEMP_ECO=93        # Switch to Eco mode at this temp
TEMP_SHUTDOWN=97   # Emergency: Eco first, then softoff if still hot
TEMP_RECOVER=78    # Switch back to Standard when cooled below this

# Cooldown lockout — stay in Eco this long before allowing Standard
LOCKOUT_SECONDS=18000   # 5 hours

# Crash detection — consecutive 0-hashrate polls before alerting
CRASH_THRESHOLD=2
```

---

## Temperature Logic

The script follows a deliberate escalation pattern to protect hardware:

```
Normal operation (Standard mode, ~81-85 TH/s @ 1300W)
    │
    ▼ TMax ≥ 93°C
Switch to Eco mode (~54.5 TH/s @ 800W) + 5hr lockout
    │
    ├─ TMax ≥ 97°C in Eco → Emergency soft shutdown (standby)
    │
    └─ TMax ≤ 78°C + lockout expired → Switch back to Standard
```

The 5-hour lockout prevents the miner from bouncing between modes. Without it, it would hit 93°C, drop to Eco, cool to 78°C, switch back to Standard, overheat again — cycling endlessly.

---

## Work Modes (Avalon Q)

| Mode | Name | Hashrate | Power | API Command |
|------|------|----------|-------|-------------|
| 0 | Eco / Low | ~54.5 TH/s | ~800W | `ascset\|0,workmode,set,0` |
| 1 | Standard / Medium | ~81-85 TH/s | ~1300W | `ascset\|0,workmode,set,1` |
| 2 | Super / High | ~100 TH/s | ~1600W | `ascset\|0,workmode,set,2` |

Mode changes are instant (no reboot required). Soft shutdown has a 5-second delay. All API commands verified per Canaan docs.

---

## Health Checks

The script runs these checks every poll, before the temperature logic:

| Check | What It Catches | Alert |
|-------|----------------|-------|
| **FanErr** | Fan fault flag from firmware | 🌀 Discord alert |
| **Fan RPMs** | Individual dead fans (RPM = 0) | 🌀 Discord alert |
| **ECHU** | Hashboard errors — 128 = overheated, 513 = abnormal | 🔥 or ⚠️ Discord alert |
| **ECMM** | Control board fault or hashboard connection issue | 🔧 Discord alert |
| **CRC** | Communication errors (rising count = worsening problem) | Log warning only |
| **BOOTBY** | Why the miner last restarted (overheat, no shares, low hashrate, network, etc.) | Discord alert on concerning reasons |
| **Crash detection** | 0 TH/s for 2+ consecutive polls (10+ min) | 🔴 Discord alert |

### BOOTBY Codes

When the miner restarts, the script decodes the reason on the first poll after boot:

| Code | Meaning |
|------|---------|
| `0x01` | Hard power-on reboot |
| `0x02` / `0x0A` | Overheat shutdown |
| `0x03` | Network failure |
| `0x04` | Web interface reboot |
| `0x05` | API reboot |
| `0x11` | No shares for 5 minutes |
| `0x12` | Low hashrate (<70%) |
| `0x21` | Soft reboot (softon) |

---

## Install

```bash
# Copy script to your monitoring server
cp avalon_temp_monitor.sh /home/ubuntu/
chmod +x /home/ubuntu/avalon_temp_monitor.sh

# Edit configuration (set your miner's IP at minimum)
nano /home/ubuntu/avalon_temp_monitor.sh

# Make sure the Discord webhook file exists (see README.md for setup)
cat ~/Discord_Webhook.txt

# Test it
/home/ubuntu/avalon_temp_monitor.sh
cat /home/ubuntu/avalon_monitor.log

# Add to cron (every 5 minutes)
crontab -e
```

Add this line:

```
*/5 * * * * /home/ubuntu/avalon_temp_monitor.sh
```

### Requirements

- `curl` — Discord webhook calls
- `socat` — CGMiner API communication

```bash
sudo apt install curl socat
```

---

## Example Discord Alerts

**Temperature switch:**
> ⚠️ **Avalon Q Alert** (2026-05-28 14:30)
> 🌡️ TMax=94°C — switched from Standard to Eco + 5hr lockout.

**Recovery:**
> ⚠️ **Avalon Q Alert** (2026-05-28 19:35)
> ✅ Cooled to 76°C — switching back to Standard mode.

**Emergency shutdown:**
> ⚠️ **Avalon Q Alert** (2026-05-28 14:40)
> 🛑 EMERGENCY SHUTDOWN — TMax=98°C in Eco mode. Miner entering standby.

**Dead fan:**
> ⚠️ **Avalon Q Alert** (2026-05-28 14:30)
> 🌀 Dead fan(s): Fan3 — RPMs: F1=4200 F2=4150 F3=0 F4=4180

**Hashboard overheated:**
> ⚠️ **Avalon Q Alert** (2026-05-28 14:35)
> 🔥 Hashboard overheated! ECHU=128. TMax=96°C

**Miner crash:**
> ⚠️ **Avalon Q Alert** (2026-05-28 14:40)
> 🔴 Miner DOWN — 0 TH/s for 10 min! Fan:80% TMax:45°C. Check immediately.

**Overheat reboot detected:**
> ⚠️ **Avalon Q Alert** (2026-05-28 14:45)
> 🔥 Miner restarted due to OVERHEAT (BOOTBY=0x02)

---

## Log Format

```
2026-05-28 14:30:00 | STATUS | Mode:Standard TMax:87°C TAvg:82°C HBOut:44°C Fan:80% Hash:83.2TH/s Power:1295W Fans:[4200 4150 4180 4190]
2026-05-28 14:35:00 | ACTION | TMax 94°C >= 93°C - Switching from Standard to Eco mode
2026-05-28 14:35:00 | ACTION | Eco mode applied instantly + 5hr lockout started
2026-05-28 14:40:00 | LOCKOUT | 295 minutes remaining before Standard mode allowed
2026-05-28 14:40:00 | STATUS | Mode:Eco TMax:89°C TAvg:84°C HBOut:42°C Fan:100% Hash:54.5TH/s Power:802W Fans:[5100 5050 5080 5090]
```

State files are stored at:
- `/home/ubuntu/.avalon_eco_lockout` — lockout timestamp
- `/home/ubuntu/.avalon_softoff` — soft shutdown marker
- `/home/ubuntu/.avalon_crash_count` — consecutive zero-hashrate polls

---

## Adapting for Other Hardware

**Other Canaan ASICs (A14 series, etc.):** The CGMiner API commands and field names are the same across Canaan miners. Temperature thresholds and hashrate/power values will differ — check your model's specs and adjust `TEMP_ECO`, `TEMP_SHUTDOWN`, and `TEMP_RECOVER` accordingly.

**Other ASIC brands (Bitmain, MicroBT, etc.):** The CGMiner API format varies by manufacturer. Bitmain uses a different API entirely. You'd need to rewrite the parser functions (`get_tmax`, `get_workmode`, etc.), but the alerting logic, temperature escalation pattern, lockout system, and crash detection are all reusable.

**Different work modes:** If your miner has different mode numbers or names, update the `set_workmode` calls and the mode name mapping in the main logic section. 
