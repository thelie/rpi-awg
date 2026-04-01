# rpi-awg

AmneziaWG v2 VPN gateway on Raspberry Pi 5 in Docker. Routes all home network traffic through an AmneziaWG tunnel with a kill switch.

## Network Topology

```
ISP → GL-iNet GL-AXT1800 (192.168.8.1) → LAN → RPi 5 (192.168.8.145)
         (AdGuard Home)                          (AmneziaWG gateway)
                                           └── WiFi clients
```

**Traffic flow:** WiFi Client → RPi (gateway) → awg0 → VPN server → Internet

**DNS flow:** WiFi Client → AdGuard (192.168.8.1) → upstream DoH/DoT (via RPi's VPN tunnel)

## Prerequisites

- Raspberry Pi 5 with static IP `192.168.8.145`
- Docker and Docker Compose installed on RPi
- AmneziaWG v2 config file (`.conf`) from your VPN provider

## Setup

### 0. Host sysctls (one-time)

```bash
printf 'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.disable_ipv6=1\nnet.ipv4.conf.all.src_valid_mark=1\n' | sudo tee /etc/sysctl.d/99-awg.conf
sudo sysctl --system
```

### 1. Clone and configure

```bash
git clone <repo-url> rpi-awg
cd rpi-awg

# Clone AmneziaWG source trees (built locally during Docker build)
git clone https://github.com/amnezia-vpn/amneziawg-go.git
git clone https://github.com/amnezia-vpn/amneziawg-tools.git

# Copy your AmneziaWG config (must be named awg0.conf)
cp /path/to/your.conf config/awg0.conf

# Create environment file
cp .env.example .env
# Edit .env if your network differs from defaults
```

### 2. Build and start

```bash
docker compose build
docker compose up -d
```

### 3. Configure router

On your GL-AXT1800:

1. **DHCP gateway**: Admin panel → Network → LAN → DHCP → set default gateway to `192.168.8.145`
2. **AdGuard upstream DNS**: AdGuard Home → Settings → DNS settings → set upstream to a DoH/DoT provider (e.g. `https://dns.google/dns-query` or `tls://1.1.1.1`). Since the router's gateway is the RPi, these queries exit through the VPN tunnel.
3. **Domain bypass DNS** (optional): To use split tunneling, add domain-specific upstream forwarding in AdGuard Home → DNS settings → Upstream DNS:
   ```
   [/ru/github.com/reddit.com/steampowered.com/]192.168.8.145:5353
   ```
   This forwards bypass domains to dnsmasq on the RPi, which resolves them and adds IPs to the bypass ipset for direct routing.

## Verify

```bash
# Check container is running and healthy
docker compose ps

# Check tunnel status
docker exec awg-client awg show awg0

# Check iptables rules
docker exec awg-client iptables -L -n

# Test VPN connectivity from RPi
docker exec awg-client ping -c3 -I awg0 1.1.1.1

# From a WiFi client, check your public IP
curl ifconfig.me
```

## Kill Switch

The gateway uses a strict kill switch:
- Default `DROP` policy on all iptables chains (`INPUT`, `OUTPUT`, `FORWARD`)
- Only VPN endpoint traffic and LAN communication are allowed outside the tunnel
- If `awg0` goes down, all forwarded traffic is blocked — no leaks

**Test the kill switch:**
```bash
# Bring tunnel down (traffic should stop for WiFi clients)
docker exec awg-client ip link set awg0 down

# Bring it back
docker exec awg-client awg-quick up /tmp/awg0.conf
```

## Domain Bypass (Split Tunneling)

Certain domains bypass the VPN and route directly through the LAN gateway. This is handled by dnsmasq + ipset + policy routing:

1. AdGuard forwards bypass domain queries to dnsmasq (port 5353)
2. dnsmasq resolves the domain and adds the IP to the `bypass_domains` ipset
3. iptables marks matching packets with fwmark 100
4. Policy routing sends marked packets via the LAN gateway (table 100)

Bypass domains are configured in `scripts/dnsmasq.conf`. Default list: `*.ru`, GitHub, Reddit, Steam, VK, Yandex, Apple captive portal.

## Watchdog

A built-in watchdog checks tunnel health every 30 seconds:
- Verifies `awg0` interface is UP
- Checks handshake freshness (< 180s)
- Pings through tunnel if handshake is stale (configurable via `PING_TARGET`)
- Auto-restarts tunnel after 3 consecutive failures
- Exponential backoff on repeated failures (30s → 60s → 120s → 240s → 300s max)

## Common Operations

```bash
# View logs
docker compose logs -f

# Restart
docker compose restart

# Stop (restores default iptables — traffic passes without VPN)
docker compose down

# Rebuild after updating Dockerfile
docker compose build --no-cache
docker compose up -d
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `LAN_SUBNET` | `192.168.8.0/24` | Your LAN network CIDR |
| `GATEWAY_IP` | `192.168.8.1` | Router/gateway IP |
| `VPN_ENDPOINT_IP` | — | VPN server IP from config |
| `VPN_ENDPOINT_PORT` | — | VPN server port from config |
| `PING_TARGET` | `100.64.0.1` | Watchdog ping target (VPN internal IP) |

## File Structure

```
rpi-awg/
├── amneziawg-go/            # AmneziaWG daemon source (clone separately)
├── amneziawg-tools/         # AWG CLI tools source (clone separately)
├── config/
│   └── awg0.conf            # Your AWG config (gitignored)
├── scripts/
│   ├── entrypoint.sh        # Tunnel setup + watchdog
│   ├── postup.sh            # iptables kill switch + NAT
│   └── dnsmasq.conf         # DNS-based bypass domain config
├── Dockerfile               # Multi-stage build (amneziawg-go ARM64)
├── docker-compose.yml
├── .env                     # Network settings (gitignored)
└── .env.example
```
