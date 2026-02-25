#!/bin/bash
# wifi-watchdog.sh
#
# Monitors WiFi connectivity on this Raspberry Pi and attempts
# progressive recovery (nmcli reconnect → NM restart → reboot)
# before giving up and rebooting.
#
# ============================================================
# RUNS AS ROOT — must be installed in root's crontab only.
# Run `sudo crontab -e` to install, not `crontab -e`.
# Regular-user invocation will fail: nmcli down/up and reboot
# both require root privileges.
# ============================================================
#
# Cron entry (install with: sudo crontab -e):
#   */2 * * * * flock -n /run/wifi-watchdog/lock /home/rsi/wifi-watchdog/wifi-watchdog.sh >> /home/rsi/wifi-watchdog/log/wifi-watchdog.log 2>&1

GATEWAY=192.168.1.1
SCRIPT_DIR=/home/rsi/wifi-watchdog
LOG_FILE=$SCRIPT_DIR/log/wifi-watchdog.log
RUN_DIR=/run/wifi-watchdog          # tmpfs — cleared on reboot
STATE_DIR=/var/lib/wifi-watchdog    # persistent across reboots
FAIL_COUNT_FILE=$RUN_DIR/fail_count
FAIL_START_FILE=$RUN_DIR/fail_start
LAST_FIX_FILE=$RUN_DIR/last_fix
FC_FILE=$STATE_DIR/reboot_threshold
LOG_LEVEL=${LOG_LEVEL:-INFO}
LOG_MAX_BYTES=1048576               # 1 MB log cap

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_rank() {
    case $1 in
        WARN)  echo 1 ;;
        INFO)  echo 2 ;;
        DEBUG) echo 3 ;;
        *)     echo 99 ;;
    esac
}

log() {
    local level=$1; shift
    if [ "$(log_rank "$level")" -le "$(log_rank "$LOG_LEVEL")" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    fi
}

# ---------------------------------------------------------------------------
# Log rotation — keep newest half when file exceeds 1 MB
# ---------------------------------------------------------------------------

rotate_log() {
    [ -f "$LOG_FILE" ] || return 0
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null) || return 0
    if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
        local lines keep
        lines=$(wc -l < "$LOG_FILE")
        keep=$(( lines / 2 ))
        tail -n "$keep" "$LOG_FILE" > "${LOG_FILE}.tmp" \
            && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

read_int() {
    local file=$1 default=$2 val
    if [ -f "$file" ]; then
        val=$(cat "$file" 2>/dev/null)
        if [[ "$val" =~ ^[0-9]+$ ]]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}

elapsed_min() {
    # Minutes elapsed since the first failure of this episode
    if [ -f "$FAIL_START_FILE" ]; then
        local start now
        start=$(cat "$FAIL_START_FILE")
        now=$(date +%s)
        echo $(( (now - start) / 60 ))
    else
        echo "?"
    fi
}

reset_failure_state() {
    echo 0 > "$FAIL_COUNT_FILE"
    rm -f "$FAIL_START_FILE" "$LAST_FIX_FILE"
}

# ---------------------------------------------------------------------------
# Initialise state directories
# ---------------------------------------------------------------------------

mkdir -p "$RUN_DIR" "$STATE_DIR"
rotate_log

# ---------------------------------------------------------------------------
# Skip for the first 2 hours after boot (NFS/NM settle time)
# ---------------------------------------------------------------------------

uptime_sec=$(awk '{print int($1)}' /proc/uptime)
if [ "$uptime_sec" -lt 7200 ]; then
    log DEBUG "Uptime ${uptime_sec}s < 7200 — skipping"
    exit 0
fi

# ---------------------------------------------------------------------------
# Read persistent state
# ---------------------------------------------------------------------------

fail_count=$(read_int "$FAIL_COUNT_FILE" 0)
FC=$(read_int "$FC_FILE" 10)

# ---------------------------------------------------------------------------
# Ping the gateway
# ---------------------------------------------------------------------------

if ping -c 2 -W 5 "$GATEWAY" > /dev/null 2>&1; then

    # -------------------------------------------------------------------------
    # SUCCESS
    # -------------------------------------------------------------------------

    log DEBUG "Ping OK (fail_count=$fail_count FC=$FC)"

    if [ "$fail_count" -gt 0 ]; then
        elapsed=$(elapsed_min)
        last_fix=""
        [ -f "$LAST_FIX_FILE" ] && last_fix=$(cat "$LAST_FIX_FILE")
        if [ -n "$last_fix" ]; then
            log WARN "Gateway recovered after $fail_count failures (~${elapsed} min); last fix applied: $last_fix"
        else
            log WARN "Gateway recovered after $fail_count failures (~${elapsed} min); no fix applied"
        fi
        reset_failure_state
    fi

    if [ "$FC" -gt 10 ]; then
        FC=$(( FC - 1 ))
        echo "$FC" > "$FC_FILE"
        if [ "$FC" -eq 10 ]; then
            log INFO "Reboot threshold back to minimum (FC=10)"
        else
            log DEBUG "FC decremented to $FC"
        fi
    fi

    exit 0
fi

# ---------------------------------------------------------------------------
# FAILURE
# ---------------------------------------------------------------------------

fail_count=$(( fail_count + 1 ))
echo "$fail_count" > "$FAIL_COUNT_FILE"

if [ "$fail_count" -eq 1 ]; then
    date +%s > "$FAIL_START_FILE"
    log INFO "Gateway unreachable — monitoring (FC=$FC)"
fi

log DEBUG "Ping failed (fail_count=$fail_count FC=$FC)"

# ---------------------------------------------------------------------------
# Fix 1 at fail_count 5 (~10 min): nmcli connection down/up
# ---------------------------------------------------------------------------

if [ "$fail_count" -eq 5 ]; then
    wifi_conn=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null \
                | awk -F: '$2=="802-11-wireless"{print $1; exit}')
    if [ -n "$wifi_conn" ]; then
        log INFO "Attempting nmcli reconnect (connection: $wifi_conn)"
        nmcli connection down "$wifi_conn" 2>/dev/null || true
        nmcli connection up   "$wifi_conn" 2>/dev/null || true
        echo "nmcli-reconnect" > "$LAST_FIX_FILE"
        log DEBUG "Sleeping 40s after nmcli reconnect..."
        sleep 40
        if ping -c 1 -W 5 "$GATEWAY" > /dev/null 2>&1; then
            elapsed=$(elapsed_min)
            log WARN "nmcli reconnect succeeded after $fail_count failures (~${elapsed} min)"
            reset_failure_state
            exit 0
        fi
        log INFO "nmcli reconnect did not restore connectivity"
    else
        log INFO "No active WiFi connection found — skipping nmcli fix"
    fi
fi

# ---------------------------------------------------------------------------
# Fix 2 at fail_count 8 (~16 min): restart NetworkManager
# ---------------------------------------------------------------------------

if [ "$fail_count" -eq 8 ]; then
    log INFO "Attempting NetworkManager restart"
    systemctl restart NetworkManager 2>/dev/null || true
    echo "NM-restart" > "$LAST_FIX_FILE"
    log DEBUG "Sleeping 40s after NM restart..."
    sleep 40
    if ping -c 1 -W 5 "$GATEWAY" > /dev/null 2>&1; then
        elapsed=$(elapsed_min)
        log WARN "NetworkManager restart succeeded after $fail_count failures (~${elapsed} min)"
        reset_failure_state
        exit 0
    fi
    log INFO "NetworkManager restart did not restore connectivity"
fi

# ---------------------------------------------------------------------------
# Reboot if fail_count has reached the threshold
# ---------------------------------------------------------------------------

if [ "$fail_count" -ge "$FC" ]; then
    new_FC=$(( FC * 3 ))
    [ "$new_FC" -gt 720 ] && new_FC=720
    elapsed=$(elapsed_min)
    log WARN "REBOOTING after $fail_count failures (~${elapsed} min); FC $FC → $new_FC"
    echo "$new_FC" > "$FC_FILE"
    sync
    reboot
fi

exit 0
