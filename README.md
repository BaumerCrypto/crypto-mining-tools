# crypto-mining-tools

Monitoring and alerting scripts for ASIC miners and mining infrastructure. CGMiner API, Start9/DATUM Gateway, Discord webhooks.

I built these to monitor my own mining stack. They run on cron, track state to avoid alert spam, and push alerts to Discord when something goes wrong. Same cron + bash + Discord webhook pattern I use for my [DigiDollar oracle monitoring](https://github.com/BaumerCrypto/digidollar-oracle-tools).

---

## Tools

| Script | Docs | What It Monitors | Cron |
|--------|------|-----------------|------|
| `avalon_temp_monitor.sh` | [`AVALON_TEMP_MONITOR.md`](AVALON_TEMP_MONITOR.md) | Canaan Avalon Q ASIC — temps, fan health, hashboard errors, crash detection. Auto-switches work modes to protect hardware. Works with any CGMiner-compatible ASIC. | `*/5` |
| `monitor_btc_stack.sh` | [`MONITOR_BTC_STACK.md`](MONITOR_BTC_STACK.md) | Start9 OS + DATUM Gateway — ping check and stratum protocol probe. Catches DATUM outages that a simple TCP check would miss. | `*/1` |

---

## Requirements

Both scripts run on a Linux box on the same LAN as your mining hardware. They don't run on the miners themselves.

**System packages:**

```bash
# avalon_temp_monitor.sh needs: curl, socat
# monitor_btc_stack.sh needs: curl, netcat, ping
sudo apt install curl socat netcat-openbsd
```

---

## Discord Webhook Setup

Both scripts read the webhook URL from a shared file. This keeps the URL out of the scripts so the repo stays clean.

**1. Create a Discord webhook:**

Go to your Discord server → channel settings → Integrations → Webhooks → New Webhook. Copy the URL.

**2. Save it to a file on your monitoring server:**

```bash
echo "https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN" > ~/Discord_Webhook.txt
chmod 600 ~/Discord_Webhook.txt
```

**3. Test it:**

```bash
curl -s -H "Content-Type: application/json" \
  -d '{"content":"Test from mining monitor"}' \
  "$(cat ~/Discord_Webhook.txt)"
```

You should see the message appear in your Discord channel.

> **Note:** Both scripts default to reading from `/home/ubuntu/Discord_Webhook.txt`. If your username isn't `ubuntu`, update the `WEBHOOK_FILE` path at the top of each script.

---

## Related

- [digidollar-oracle-tools](https://github.com/BaumerCrypto/digidollar-oracle-tools) — My DigiDollar oracle monitoring, hardening guides, and deployment tools.
- [GSS/GSSM by MMFP Solutions](https://mmfpsolutions.com/) — Solo mining pool software and miner manager I run for DGB and BTC.
- [DATUM Gateway](https://github.com/OCEAN-xyz/datum_gateway) — Stratum proxy between Bitcoin Knots and miners on Start9.

---

## License

MIT — see [LICENSE](LICENSE). 
