# wifi-watchdog

Watches WiFi connectivity and attempts recovery before rebooting.
Motivated by a freeze on 2026-02-21 where the WiFi dropped, an NFS mount
hung all processes accessing it, and the Pi became unresponsive for ~4.5h.

## Context

- Pi 3B+ connected via WiFi only (eth0 has no carrier)
- NFS mount at 192.168.1.3 fixed with soft,timeo=30,retrans=2 on same date
- wpa_supplicant had brcmfmac/802.11r FT driver issue; NM connection locked
  to proto=rsn to prevent FT probing

## Files

| Path | Purpose |
|------|---------|
| wifi-watchdog.sh | Main script (to be created) |
| log/wifi-watchdog.log | Log file (gitignored) |
| root crontab (sudo crontab -e) | Runs script every 2 minutes |
| /run/wifi-watchdog/fail_count | Failure counter (tmpfs, resets on reboot) |
| /run/wifi-watchdog/lock | flock lockfile (tmpfs, prevents overlapping runs) |
| /var/lib/wifi-watchdog/reboot_threshold | Dynamic FC value (persistent) |

No logrotate - rotation handled inside the script (~1MB cap, trim oldest lines).

## Reboot threshold (FC)

Failure count required before rebooting. Stored in /var/lib/wifi-watchdog/reboot_threshold.

- Initial value: 10 (first reboot after ~20 min)
- On reboot: log current FC, then FC = min(FC * 3, 720)
- On successful ping: FC = max(FC - 1, 10)
- Range: [10, 720]

Rationale: two failure causes exist:
1. Internal Linux/WiFi driver issue (recoverable by reboot)
2. External network outage (rebooting is pointless)

Rapid repeated reboots indicate an external problem or persistent internal fault.
FC escalates quickly (3 reboots to cap) to suppress futile reboots, and recovers
gradually (~24h of stability at cap) to restore responsiveness once stable.

## Script logic

Every 2 min (root crontab, via flock):

  uptime < 2h? -> exit silently

  ping -c 2 -W 5 192.168.1.1
    success:
      fail_count > 0:
        log recovery (which fix worked, elapsed time)  [WARN]
        reset fail_count to 0
      FC > 10:
        decrement FC by 1, save
        if FC reached 10: log "FC reset to minimum"  [INFO]
      exit

    fail:
      increment fail_count
      fail_count == 1  -> log "Gateway unreachable - monitoring"  [INFO]
      fail_count == 5  (~10 min):
        apply nmcli connection down/up
        sleep 40s, ping once
        if restored: log "nmcli fix succeeded"  [WARN], reset fail_count, exit
        (not reapplied if unsuccessful)
      fail_count == 8  (~16 min):
        apply systemctl restart NetworkManager
        sleep 40s, ping once
        if restored: log "NM restart succeeded"  [WARN], reset fail_count, exit
        (not reapplied if unsuccessful)
      fail_count >= FC:
        log "REBOOTING after N failures (~X min), FC was Y -> now Z"  [WARN]
        update reboot_threshold (FC * 3, capped at 720), save
        sync && reboot

## Logging policy

Three levels (controlled by LOG_LEVEL env var, default INFO):

  WARN  - successful fixes or reboots (always logged)
  INFO  - first failure of an episode (default)
  DEBUG - every ping attempt

Silent during normal operation (no failures, no FC changes).
No repeated failure lines - only first failure and outcome (fix or reboot).
FC escalation/reset logged at INFO.

Log file: /home/rsi/wifi-watchdog/log/wifi-watchdog.log

## Language

Bash. All dependencies (ping, nmcli, systemctl, flock, awk, date) are native.

## State dirs (created by script on first run)

  mkdir -p /run/wifi-watchdog      # tmpfs, cleared on reboot
  mkdir -p /var/lib/wifi-watchdog  # persistent

## Cron entry (sudo crontab -e)

  */2 * * * * flock -n /run/wifi-watchdog/lock /home/rsi/wifi-watchdog/wifi-watchdog.sh >> /home/rsi/wifi-watchdog/log/wifi-watchdog.log 2>&1
