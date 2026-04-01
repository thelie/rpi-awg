#!/bin/bash
set -e

CONF_SRC="/etc/amneziawg/awg0.conf"
CONF_RUNTIME="/tmp/awg0.conf"
WATCHDOG_INTERVAL=30
HANDSHAKE_MAX_AGE=180
MAX_FAILURES=3

echo "=== AmneziaWG Gateway ==="

# --- Verify IP forwarding is enabled (must be set on host) ---
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
    echo "ERROR: IP forwarding is not enabled on the host." >&2
    echo "Run on the RPi: sudo sysctl -w net.ipv4.ip_forward=1" >&2
    echo "To persist: echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-awg.conf" >&2
    exit 1
fi

# --- Cleanup on exit ---
cleanup() {
    echo "Shutting down..."
    awg-quick down "$CONF_RUNTIME" 2>/dev/null || true
    iptables -F 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
    # Restore default route via LAN gateway so host keeps network
    ip route add default via "$GATEWAY_IP" dev eth0 2>/dev/null || true
    echo "Cleanup complete."
    exit 0
}
trap cleanup SIGTERM SIGINT

# --- Prepare runtime config ---
if [ ! -f "$CONF_SRC" ]; then
    echo "ERROR: Config not found at $CONF_SRC" >&2
    echo "Mount your AmneziaWG config to /etc/amneziawg/fi.conf" >&2
    exit 1
fi

umask 077
sed -e '/^DNS\s*=/d' -e 's/, *::\/0//' -e 's/::\/0, *//' -e 's/::\/0//' "$CONF_SRC" > "$CONF_RUNTIME"
# Table = off prevents awg-quick from managing routes/rules/sysctls (we handle routing ourselves)
sed -i '/^\[Interface\]/a Table = off' "$CONF_RUNTIME"
chmod 600 "$CONF_RUNTIME"

echo "Config prepared (DNS stripped, IPv6 removed, Table=off)"

# --- Add static route for VPN endpoint ---
echo "Adding route for VPN endpoint $VPN_ENDPOINT_IP via $GATEWAY_IP"
ip route add "$VPN_ENDPOINT_IP/32" via "$GATEWAY_IP" 2>/dev/null || \
    echo "Route already exists or could not be added"

# --- Bring up tunnel ---
echo "Starting AmneziaWG tunnel..."
awg-quick up "$CONF_RUNTIME"

# Verify interface is up
if ! ip link show awg0 up > /dev/null 2>&1; then
    echo "ERROR: awg0 interface failed to come up" >&2
    exit 1
fi

# --- Set up routing (since Table=off, awg-quick won't do this) ---
# Replace default route with VPN tunnel, keep VPN endpoint routed via LAN
ip route del default 2>/dev/null || true
ip route add default dev awg0
echo "Default route set through awg0"

echo "Tunnel is UP"

# --- Apply iptables rules ---
source /scripts/postup.sh

# --- Start dnsmasq for domain-based bypass ---
echo "Starting dnsmasq for domain bypass..."
dnsmasq -C /scripts/dnsmasq.conf
echo "dnsmasq listening on port 5353"

echo "Gateway ready. Starting watchdog..."

# --- Watchdog loop ---
set +e
fail_count=0
restart_count=0
backoff_interval=$WATCHDOG_INTERVAL

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WATCHDOG: $1"
}

while true; do
    sleep "$backoff_interval" &
    wait $!

    # Check interface exists and is UP
    if ! ip link show awg0 up > /dev/null 2>&1; then
        log "awg0 interface is DOWN"
        fail_count=$((fail_count + 1))
    else
        # Check last handshake age
        last_handshake=$(awg show awg0 latest-handshakes 2>/dev/null | awk '{print $2}')
        now=$(date +%s)

        if [ -n "$last_handshake" ] && [ "$last_handshake" -gt 0 ] 2>/dev/null; then
            age=$((now - last_handshake))
            if [ "$age" -gt "$HANDSHAKE_MAX_AGE" ]; then
                log "Handshake stale (${age}s old), testing connectivity..."
                if ! ping -c1 -W5 -I awg0 100.64.0.1 > /dev/null 2>&1; then
                    log "Ping failed, tunnel unhealthy"
                    fail_count=$((fail_count + 1))
                else
                    fail_count=0
                    restart_count=0
                    backoff_interval=$WATCHDOG_INTERVAL
                fi
            else
                fail_count=0
                restart_count=0
                backoff_interval=$WATCHDOG_INTERVAL
            fi
        else
            # No handshake yet, try ping
            if ! ping -c1 -W5 -I awg0 100.64.0.1 > /dev/null 2>&1; then
                log "No handshake and ping failed"
                fail_count=$((fail_count + 1))
            else
                fail_count=0
                restart_count=0
                backoff_interval=$WATCHDOG_INTERVAL
            fi
        fi
    fi

    # Restart tunnel if unhealthy
    if [ "$fail_count" -gt 0 ]; then
        log "Failure count: $fail_count/$MAX_FAILURES"
        if [ "$fail_count" -ge "$MAX_FAILURES" ]; then
            restart_count=$((restart_count + 1))
            # Exponential backoff: 30s, 60s, 120s, 240s, max 300s (5min)
            backoff_interval=$((WATCHDOG_INTERVAL * (2 ** (restart_count - 1))))
            if [ "$backoff_interval" -gt 300 ]; then
                backoff_interval=300
            fi

            log "Restart attempt #$restart_count, restarting tunnel..."
            awg-quick down "$CONF_RUNTIME" 2>/dev/null || true
            sleep 2
            awg-quick up "$CONF_RUNTIME" 2>/dev/null || true

            if ip link show awg0 up > /dev/null 2>&1; then
                log "Tunnel restarted, next check in ${backoff_interval}s"
                source /scripts/postup.sh
            else
                log "Tunnel restart failed, retrying in ${backoff_interval}s"
            fi
            fail_count=0
        fi
    fi
done
