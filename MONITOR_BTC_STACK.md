# monitor_btc_stack.sh

Monitors a Start9-based BTC solo mining stack: Start9 OS reachability (ping) and DATUM Gateway stratum health (protocol-level probe). Fires Discord alerts on state changes — when something goes down, and when it comes back up.

---

## How It Works

Every 1 minute (via cron), the script checks two things:

1. **Start9 OS** — is the machine reachable on the LAN? (ping)
2. **DATUM Gateway** — is stratum actually serving work to miners? (protocol probe on port 23334)

If Start9 is unreachable, everything is down. If Start9 is up but DATUM isn't responding, miners have likely failed over to backup pools.

### Why Not Just a TCP Check?

Start9 keeps port 23334 open at the proxy layer even when DATUM is stopped. A simple `nc -z` or `ss` check would say "port open, all good" when DATUM is actually dead and your miners have no work.

This script sends an actual stratum `mining.subscribe` request and checks for `mining.notify` in the response. If DATUM is really running, you get a valid subscription result. If it's just the Start9 proxy holding the port open, you get nothing useful back.

### Implicit Bitcoin Knots Check

The script doesn't directly check Bitcoin Knots because Start9 doesn't expose its RPC on the LAN. But if DATUM is responding with valid stratum work, Knots is necessarily running — DATUM can't serve block templates without it.

---

## Configuration

Edit the variables at the top of the script:

```bash
START9_IP="YOUR_START9_IP"              # Start9 LAN IP (e.g. 192.168.0.189)
DATUM_STRATUM_PORT="23334"              # DATUM Gateway stratum port

PING_TIMEOUT=5                          # Seconds before ping gives up
STRATUM_TIMEOUT=5                       # Seconds before stratum probe gives up
```

---

## State Tracking

The script only alerts on **state transitions** (up → down, down → up), not on every poll. This prevents your Discord channel from getting spammed every minute while something is down.

State files are stored in `~/.btc_monitor/`:

- `~/.btc_monitor/start9` — `up` or `down`
- `~/.btc_monitor/datum` — `up` or `down`

If you want to force a re-alert (e.g., after fixing something and wanting to verify the recovery alert fires), delete the state files:

```bash
rm -rf ~/.btc_monitor/
```

---

## Install

```bash
# Copy script to your monitoring server
cp monitor_btc_stack.sh /home/ubuntu/
chmod +x /home/ubuntu/monitor_btc_stack.sh

# Edit configuration (set your Start9 IP)
nano /home/ubuntu/monitor_btc_stack.sh

# Make sure the Discord webhook file exists (see README.md for setup)
cat ~/Discord_Webhook.txt

# Test it
/home/ubuntu/monitor_btc_stack.sh
cat /home/ubuntu/btc_monitor.log

# Add to cron (every 1 minute)
crontab -e
```

Add this line:

```
*/1 * * * * /home/ubuntu/monitor_btc_stack.sh
```

### Requirements

- `curl` — Discord webhook calls
- `netcat` (`nc`) — stratum probe
- `ping` — Start9 reachability

```bash
sudo apt install curl netcat-openbsd
```

---

## Example Discord Alerts

**DATUM down (Start9 still reachable):**

> **🚨 DATUM Gateway — DOWN**
> DATUM stratum on port 23334 is not responding.
>
> Your BTC miners have likely failed over to backup pools.
>
> Start9 OS is reachable. DATUM may have stopped.
>
> Action: Check Start9 dashboard.

**Start9 unreachable (everything down):**

> **🚨 Start9 OS — UNREACHABLE**
> Cannot reach Start9.
>
> All BTC mining is likely down:
> - Bitcoin Knots unreachable
> - DATUM Gateway unreachable
> - BTC miners have likely failed over to backup pools
>
> Action: Check physical Start9 hardware and network.

**DATUM recovery:**

> **✅ DATUM Gateway — Back Online**
> DATUM stratum on port 23334 is responding.
> Miners should reconnect automatically.

**Start9 recovery:**

> **✅ Start9 OS — Back Online**
> Start9 is reachable again.

---

## Log Format

```
2026-05-28 14:30:00 RECOVERY: DATUM Gateway stratum is responding
2026-05-28 15:22:00 ALERT: DATUM Gateway stratum is NOT responding on port 23334
2026-05-28 15:25:00 RECOVERY: DATUM Gateway stratum is responding
```

Log rotation is built in — keeps the last 1000 lines, trims to 500 when it overflows.

---

## Adapting for Other Stratum Software

The stratum probe works with any stratum v1 endpoint that responds to `mining.subscribe`. Change the IP and port and it should work for CKPool, Braiins, or any other stratum server. The `mining.notify` check in the response is standard stratum v1 — not DATUM-specific.

If your stratum server uses a different port or subscription response format, adjust the `check_datum_stratum()` function and the grep pattern accordingly. 
