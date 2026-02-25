# wifi-watchdog

Monitors WiFi connectivity on this Raspberry Pi and attempts progressive
recovery before rebooting.

Motivated by a freeze on 2026-02-21 where the WiFi dropped, an NFS mount
hung all processes accessing it, and the Pi became unresponsive for ~4.5 h.

---

## > ROOT CRON JOB

> **This script runs under root's crontab, not the user crontab.**
> This is intentional and required — `nmcli connection down/up` and
> `reboot` both need root privileges.
>
> Install with **`sudo crontab -e`**, not `crontab -e`.

Cron entry:

```
*/2 * * * * flock -n /run/wifi-watchdog/lock /home/rsi/wifi-watchdog/wifi-watchdog.sh >> /home/rsi/wifi-watchdog/log/wifi-watchdog.log 2>&1
```

---

## Installation

```bash
# 1. Make the script executable
chmod +x /home/rsi/wifi-watchdog/wifi-watchdog.sh

# 2. Install in ROOT's crontab  ← note: sudo crontab, not crontab
sudo crontab -e
# Add the cron line above, save, and exit.

# 3. Verify it is in root's crontab (not the user crontab)
sudo crontab -l
```

---

## What it does

Runs every 2 minutes. On each run:

1. **Skip** if uptime < 2 h (allow NFS/NetworkManager to settle after boot).
2. **Ping** the gateway (`192.168.1.1`) twice.
3. **On success**: log recovery details if an outage was in progress; slowly
   lower the reboot threshold back toward the minimum.
4. **On failure**: increment a failure counter and escalate:

| fail\_count | Time into outage | Action |
|-------------|-----------------|--------|
| 1 | ~2 min | Log "Gateway unreachable — monitoring" |
| 5 | ~10 min | `nmcli connection down/up`; re-ping after 40 s |
| 8 | ~16 min | `systemctl restart NetworkManager`; re-ping after 40 s |
| ≥ FC | variable | Reboot |

---

## Reboot threshold (FC)

The failure count required before rebooting is stored persistently so it
survives reboots:

- **Initial value**: 10 (first reboot after ~20 min of continuous failure)
- **On reboot**: FC = min(FC × 3, 720); logged before rebooting
- **On each successful ping**: FC = max(FC − 1, 10) — recovers slowly
- **Range**: 10 – 720 (720 = ~24 h of failures before rebooting)

**Rationale**: failures have two causes — an internal Linux/WiFi driver issue
(reboot helps) or an external network outage (rebooting is pointless). FC
escalates quickly (3 reboots to reach the cap) to suppress futile reboots
during sustained outages, then recovers gradually once connectivity is stable.

---

## State files

| Path | Contents | Cleared on reboot? |
|------|----------|--------------------|
| `/run/wifi-watchdog/fail_count` | Current failure counter | Yes (tmpfs) |
| `/run/wifi-watchdog/fail_start` | Unix timestamp of first failure | Yes (tmpfs) |
| `/run/wifi-watchdog/last_fix` | Last fix attempted | Yes (tmpfs) |
| `/var/lib/wifi-watchdog/reboot_threshold` | Current FC value | No |

Both directories are created automatically on the first run.

---

## Log file

```
/home/rsi/wifi-watchdog/log/wifi-watchdog.log
```

Rotation is handled inside the script: when the file exceeds 1 MB the oldest
half is discarded. No external logrotate configuration needed.

### Log levels

Controlled by the `LOG_LEVEL` environment variable (default: `INFO`).

| Level | What is logged |
|-------|---------------|
| `WARN` | Successful fixes, reboots (always written) |
| `INFO` | First failure of an episode, fix attempts, FC milestones (default) |
| `DEBUG` | Every ping attempt, FC changes, sleep notices |

Silent during normal operation (no failures, no FC changes).

### Example log output

```
2026-02-25 03:14:01 [INFO]  Gateway unreachable — monitoring (FC=10)
2026-02-25 03:24:02 [INFO]  Attempting nmcli reconnect (connection: preconfigured)
2026-02-25 03:24:43 [INFO]  nmcli reconnect did not restore connectivity
2026-02-25 03:30:04 [INFO]  Attempting NetworkManager restart
2026-02-25 03:30:45 [WARN]  NetworkManager restart succeeded after 8 failures (~17 min)
```

---

## Context

- Pi 3B+ connected via WiFi only (eth0 has no carrier).
- NFS mount at `192.168.1.3` uses `soft,timeo=30,retrans=2` (fixed 2026-02-21)
  to prevent hung processes if the share disappears.
- `wpa_supplicant`/`brcmfmac` had an 802.11r FT driver issue; the NM
  connection is locked to `proto=rsn` to prevent FT probing.

---

## Manual operations

```bash
# Check current failure count
cat /run/wifi-watchdog/fail_count

# Check current reboot threshold
cat /var/lib/wifi-watchdog/reboot_threshold

# Tail the log
tail -f /home/rsi/wifi-watchdog/log/wifi-watchdog.log

# Run once manually with debug output (as root)
sudo LOG_LEVEL=DEBUG /home/rsi/wifi-watchdog/wifi-watchdog.sh

# View root's crontab
sudo crontab -l
```
