#!/bin/bash
set -e

# Validate required environment variables
validate_ip() {
    local ip="$1" name="$2"
    if ! echo "$ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        echo "ERROR: $name is not a valid IP address: $ip" >&2
        exit 1
    fi
}

validate_cidr() {
    local cidr="$1" name="$2"
    if ! echo "$cidr" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'; then
        echo "ERROR: $name is not a valid CIDR: $cidr" >&2
        exit 1
    fi
}

validate_port() {
    local port="$1" name="$2"
    if ! echo "$port" | grep -qE '^[0-9]{1,5}$' || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "ERROR: $name is not a valid port: $port" >&2
        exit 1
    fi
}

validate_cidr "$LAN_SUBNET" "LAN_SUBNET"
validate_ip "$VPN_ENDPOINT_IP" "VPN_ENDPOINT_IP"
validate_port "$VPN_ENDPOINT_PORT" "VPN_ENDPOINT_PORT"
validate_ip "$GATEWAY_IP" "GATEWAY_IP"

echo "Applying iptables rules..."

# --- IPSET for domain-based bypass ---
ipset create bypass_domains hash:ip timeout 86400 -exist
echo "ipset 'bypass_domains' ready (entries expire after 24h)"

# --- Policy routing for bypassed traffic ---
# Packets marked with fwmark 100 use routing table 100 (direct via LAN gateway)
ip rule add fwmark 100 table 100 2>/dev/null || true
ip route add default via "$GATEWAY_IP" table 100 2>/dev/null || true
echo "Bypass routing table configured (table 100 via $GATEWAY_IP)"

# Flush existing rules
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X 2>/dev/null || true

# Default policies: DROP everything
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# --- MANGLE: mark bypassed traffic ---
# Mark forwarded packets (from LAN clients) matching bypass ipset
iptables -t mangle -A PREROUTING -i eth0 -m set --match-set bypass_domains dst -j MARK --set-mark 100
# Mark locally-generated packets matching bypass ipset
iptables -t mangle -A OUTPUT -m set --match-set bypass_domains dst -j MARK --set-mark 100

# --- LOOPBACK ---
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# --- INPUT ---
# Allow established/related
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Allow LAN to RPi (gateway communication)
iptables -A INPUT -i eth0 -s "$LAN_SUBNET" -j ACCEPT
# Allow VPN return traffic
iptables -A INPUT -i awg0 -j ACCEPT

# --- OUTPUT ---
# Allow established/related
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Allow VPN endpoint (tunnel establishment) - must go direct via eth0
iptables -A OUTPUT -o eth0 -p udp -d "$VPN_ENDPOINT_IP" --dport "$VPN_ENDPOINT_PORT" -j ACCEPT
# Allow all traffic through VPN tunnel
iptables -A OUTPUT -o awg0 -j ACCEPT
# Allow LAN communication (DHCP, ARP, etc.)
iptables -A OUTPUT -o eth0 -d "$LAN_SUBNET" -j ACCEPT
# Allow DHCP client
iptables -A OUTPUT -o eth0 -p udp --dport 67 --sport 68 -j ACCEPT
# Allow bypassed traffic out via eth0
iptables -A OUTPUT -o eth0 -m mark --mark 100 -j ACCEPT
# Allow DNS resolution for dnsmasq (port 53 outbound)
iptables -A OUTPUT -o eth0 -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -o eth0 -p tcp --dport 53 -j ACCEPT
# ICMP only through VPN
iptables -A OUTPUT -o awg0 -p icmp -j ACCEPT

# --- FORWARD (kill switch + bypass) ---
# Allow bypassed traffic direct via eth0
iptables -A FORWARD -i eth0 -o eth0 -m mark --mark 100 -j ACCEPT
# Allow LAN → VPN
iptables -A FORWARD -i eth0 -o awg0 -s "$LAN_SUBNET" -j ACCEPT
# Allow VPN → LAN (established/related only)
iptables -A FORWARD -i awg0 -o eth0 -m state --state ESTABLISHED,RELATED -j ACCEPT
# Allow bypass return traffic
iptables -A FORWARD -i eth0 -o eth0 -m state --state ESTABLISHED,RELATED -j ACCEPT

# --- NAT ---
iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
# NAT for bypassed traffic going direct
iptables -t nat -A POSTROUTING -o eth0 -m mark --mark 100 -j MASQUERADE

echo "iptables rules applied. Kill switch active. Domain bypass enabled."
