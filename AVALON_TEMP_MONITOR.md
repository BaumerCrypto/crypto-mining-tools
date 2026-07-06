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

# Timezone — used for local-hour math in the peak-heat window feature
TZ='America/Regina'                # Change to your local TZ

# Temperature thresholds (°C) — TMax = hottest ASIC chip
TEMP_ECO=93        # Switch to Eco mode at this temp
TEMP_SHUTDOWN=97   # Emergency: Eco first, then softoff if still hot
TEMP_RECOVER=78    # Switch back to Standard when cooled below this

# Cooldown lockout — stay in Eco this long before allowing Standard
LOCKOUT_SECONDS=18000   # 5 hours

# Peak-heat window — hold Eco during local-hour range even after 5hr expiry
ECO_WINDOW_ENABLED=1   # 1=on, 0=off (see Peak-Heat Window section below)
ECO_WINDOW_START=9     # Start hour (inclusive, 24hr local time)
ECO_WINDOW_END=19      # End hour (exclusive, 24hr local time)

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
    ├─ Manual eco-hold present → Hold Eco indefinitely (see Manual Eco-Hold below)
    │
    ├─ Peak-heat window active → Hold Eco until end-of-window (see Peak-Heat Window below)
    │
    └─ TMax ≤ 78°C + lockout expired + no hold + outside window → Switch back to Standard
```

The 5-hour lockout prevents the miner from bouncing between modes. Without it, it would hit 93°C, drop to Eco, cool to 78°C, switch back to Standard, overheat again — cycling endlessly.

**Precedence order** (top wins when multiple apply):

1. Emergency shutdown (TMax ≥ TEMP_SHUTDOWN in Eco)
2. Emergency Eco switch (TMax ≥ TEMP_SHUTDOWN in Standard/Super)
3. Hot trigger (TMax ≥ TEMP_ECO)
4. Manual eco-hold (blocks recovery)
5. Peak-heat window (blocks recovery)
6. Normal 5hr lockout (blocks recovery)
7. Recovery to Standard

---

## Manual Eco-Hold

Manually lock the miner in Eco mode indefinitely by creating a state file:

```bash
# Lock in Eco (suppresses auto-recovery to Standard)
touch ~/.avalon_eco_hold

# Release (resume normal auto-recovery)
rm ~/.avalon_eco_hold
```

**Common uses:**

- Hot weather stretches where you want to stay in Eco proactively
- Planned maintenance or physical inspection
- Manual thermal testing / calibration
- Ambient temperature exceeds what Standard mode can handle safely

**What still runs while held:**

- All health checks (fans, ECHU, ECMM, CRC, BOOTBY, crash detection)
- Emergency thermal protection — if TMax ≥ TEMP_SHUTDOWN (97°C), soft shutdown still fires
- Discord alerts for hardware faults, crashes, reboots
- STATUS log every poll (temps, hashrate, power)

**Behavior notes:**

- No Discord notification when hold is set or active — intentional silent Eco (you set it, you know)
- Each poll where TMax has cooled below TEMP_RECOVER, the script logs `ECO_HOLD | Manual eco-hold active — skipping Standard switch...` for visibility
- Hold takes precedence over the peak-heat window — hold overrides everything except emergency shutdown

---

## Peak-Heat Window

An optional feature that extends Eco lockouts during a configured local-hour range (typical use: hot summer afternoons). Prevents Standard→Eco→Standard thrashing where a morning 93°C trigger's 5hr lockout would otherwise expire mid-afternoon during peak heat, cause immediate re-trigger, and start a fresh 5hr lockout that runs well into the cool evening — wasting hashrate that could have run Standard for a couple of hours after sunset.

**How it works:**

- Only kicks in when a lockout was actually triggered (`~/.avalon_eco_lockout` file exists)
- When an existing lockout expires AND the current local hour is within `[ECO_WINDOW_START, ECO_WINDOW_END)`, the script holds Eco instead of recovering to Standard
- Fires a `WINDOW_EXTEND` log entry each 5-min poll while holding
- Recovers to Standard on the first poll where the window is inactive AND TMax is ≤ TEMP_RECOVER AND lockout has expired

**When it's invisible:**

If your ASIC never trips TEMP_ECO (cool climate, well-cooled setup, understretched miner), no `~/.avalon_eco_lockout` file ever gets created, and this feature never runs. Zero impact on your logs, Discord alerts, or behavior. Safe to leave enabled even if you don't need it.

**Cool day, hot day — same script:**

- Cool day: never trips 93°C → LOCKOUT_FILE never exists → window logic never fires → Standard runs all day
- Hot day: trips 93°C at 11am → lockout set → 5hr expires at 4pm → window active (`9 ≤ 16 < 19`) → held until 19:00 or until it re-trips inside Eco (unlikely at Eco power draw)

### Configuration table

| Setup / Climate | ENABLED | START | END | Rationale |
|---|---|---|---|---|
| Hot garage / summer (default) | `1` | `9` | `19` | Sunny garage warms 9am, cools after 7pm |
| Hot climate, all-day heat (Arizona home) | `1` | `8` | `20` | Longer heat curve, later cool-down |
| Cool climate (northern Europe, basement) | `0` | — | — | Rarely trips 93°C — feature irrelevant |
| Air-conditioned space (datacenter) | `0` | — | — | No thermal issues |
| Constant-temperature warehouse | `0` | — | — | No diurnal cycle to schedule against |
| Night-shift mining (all-day off) | `1` | `7` | `21` | Force Eco all day even if trips are rare |
| Solar-heated attic / hot roof | `1` | `10` | `18` | Peak solar heat window only |

Adjust `TZ` at the top of the script to your local timezone (see [IANA TZ list](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) — e.g. `America/Regina`, `Europe/London`, `Asia/Singapore`, `Australia/Sydney`). The script uses `date +%H` in that timezone for the hour check.

### Behavior comparison

Using `ECO_WINDOW_START=9` and `ECO_WINDOW_END=19` as the example:

| Situation | Trigger Time | Feature OFF (`ENABLED=0`) | Feature ON (window `9-19`) |
|---|---|---|---|
| Morning trigger | 11am | Eco → recovers ~4pm | Eco → holds to 7pm ✓ (fix applied) |
| Pre-window trigger | 8am | Eco → recovers ~1pm | Eco → holds to 7pm if still cool at 1pm ✓ |
| Mid-day trigger | 1pm | Eco → recovers ~6pm | Eco → holds to 7pm ✓ (small extend) |
| Late-window trigger | 5pm | Eco → recovers ~10pm | Same — 5hr already exceeds window |
| Evening trigger | 8pm | Eco → recovers ~1am | Same — window inactive |
| Overnight trigger | 3am | Eco → recovers ~8am | Same — window inactive |
| Cool day, no trigger | never | Standard all day | Standard all day (invisible) |

### Disabling

Set `ECO_WINDOW_ENABLED=0` to fall back to old behavior — trip at 93°C, 5hr lockout, recover at 78°C, repeat. No other changes needed. Existing lockouts continue to operate on the 5hr timer.

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

# Edit configuration (set your miner's IP + timezone at minimum)
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

Note: manual eco-hold and peak-heat window holds do **not** fire Discord alerts — they're intentional silent behaviors. Check the log for `ECO_HOLD` and `WINDOW_EXTEND` entries.

---

## Log Format

```
2026-05-28 14:30:00 | STATUS | Mode:Standard TMax:87°C TAvg:82°C HBOut:44°C Fan:80% Hash:83.2TH/s Power:1295W Fans:[4200 4150 4180 4190]
2026-05-28 14:35:00 | ACTION | TMax 94°C >= 93°C - Switching from Standard to Eco mode
2026-05-28 14:35:00 | ACTION | Eco mode applied instantly + 5hr lockout started
2026-05-28 14:40:00 | LOCKOUT | 295 minutes remaining before Standard mode allowed
2026-05-28 14:40:00 | STATUS | Mode:Eco TMax:89°C TAvg:84°C HBOut:42°C Fan:100% Hash:54.5TH/s Power:802W Fans:[5100 5050 5080 5090]
2026-07-04 03:23:00 | ECO_HOLD | Manual eco-hold active — skipping Standard switch (TMax 72°C, would otherwise recover)
2026-07-05 14:15:00 | WINDOW_EXTEND | Inside 9-19 window (hour=14) — holding Eco (TMax 76°C, lockout expired but window active)
```

State files:

| File | Purpose |
|------|---------|
| `/home/ubuntu/.avalon_eco_lockout` | Lockout timestamp (Unix epoch) |
| `/home/ubuntu/.avalon_softoff` | Soft shutdown marker (empty file) |
| `/home/ubuntu/.avalon_crash_count` | Consecutive zero-hashrate poll count |
| `/home/ubuntu/.avalon_eco_hold` | Manual Eco hold flag — `touch` to enable, `rm` to disable |
| `/home/ubuntu/.avalon_alerts/` | Alert state directory (per-condition rate-limiting, auto-managed) |

---

## Adapting for Other Hardware

**Other Canaan ASICs (A14 series, etc.):** The CGMiner API commands and field names are the same across Canaan miners. Temperature thresholds and hashrate/power values will differ — check your model's specs and adjust `TEMP_ECO`, `TEMP_SHUTDOWN`, and `TEMP_RECOVER` accordingly.

**Other ASIC brands (Bitmain, MicroBT, etc.):** The CGMiner API format varies by manufacturer. Bitmain uses a different API entirely. You'd need to rewrite the parser functions (`get_tmax`, `get_workmode`, etc.), but the alerting logic, temperature escalation pattern, lockout system, manual eco-hold, peak-heat window, and crash detection are all reusable.

**Different work modes:** If your miner has different mode numbers or names, update the `set_workmode` calls and the mode name mapping in the main logic section.

**Different timezones:** Set `TZ` at the top of the script to your local timezone. Peak-heat window hours are evaluated in that timezone.
