# AmneziaWG v2 Docker Gateway on Raspberry Pi 5

## Overview
- Deploy AmneziaWG v2 client as a Docker container on RPi 5 to act as a VPN gateway for the entire home network
- All WiFi clients route through the RPi's VPN tunnel via DHCP gateway override on the GL-AXT1800 router
- AdGuard Home on the router handles DNS filtering, with upstream DNS (`100.64.0.1`) exiting through the VPN tunnel
- Kill switch ensures zero traffic leaks if the tunnel drops

## Context (from discovery)

**Network topology:**
```
ISP → GL-iNet GL-AXT1800 (192.168.8.1, AdGuard Home) → LAN → RPi 5 (192.168.8.145)
                                                         └── WiFi clients (192.168.8.0/24)
```

**Traffic flow:**
```
WiFi Client → RPi (default gw) → awg0 (MASQUERADE) → VPN server (66.234.150.50:9911) → Internet
DNS: Client → AdGuard (192.168.8.1:53) → upstream 100.64.0.1 (inside VPN tunnel)
```

**Files involved:**
- `fi.conf` — AmneziaWG v2 config with obfuscation params (Jc, Jmin, Jmax, S1, S2, H1-H4)
- VPN interface: `100.82.12.12/32`, endpoint: `66.234.150.50:9911`

**Key design decisions (from brainstorm):**
- Single container, host network mode, `NET_ADMIN` only (no `SYS_MODULE`)
- `amneziawg-go` userspace daemon built from source (ARM64)
- IPv6 fully disabled to prevent leaks
- Watchdog loop in entrypoint for tunnel health monitoring
- Config mounted read-only, runtime copy with restricted permissions

## Development Approach
- **Testing approach**: Manual — this is infrastructure (shell scripts, Dockerfile, iptables). No unit test framework applies. Validation is done via the test checklist in the final task.
- Complete each task fully before moving to the next
- Make small, focused changes
- Validate each script works syntactically before moving on (`bash -n` for scripts)
- **CRITICAL: update this plan file when scope changes during implementation**

## Progress Tracking
- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with + prefix
- Document issues/blockers with warning prefix
- Update plan if implementation deviates from original scope
- Keep plan in sync with actual work done

## Implementation Steps

### Task 1: Create project scaffolding and .gitignore

**Files:**
- Create: `.gitignore`
- Create: `.env.example`
- Create: `config/.gitkeep`

- [ ] Create `.gitignore` — exclude `*.conf`, `.env`, `config/*` (keep `.gitkeep`), secrets, logs
- [ ] Create `.env.example` with documented variables:
  ```
  LAN_SUBNET=192.168.8.0/24
  GATEWAY_IP=192.168.8.1
  VPN_ENDPOINT_IP=66.234.150.50
  VPN_ENDPOINT_PORT=9911
  ```
- [ ] Create `config/.gitkeep` so the directory is tracked
- [ ] Verify `fi.conf` is excluded by `.gitignore`

### Task 2: Create Dockerfile (multi-stage ARM64 build)

**Files:**
- Create: `Dockerfile`

- [ ] Stage 1 (`builder`): Alpine + Go, clone `amneziawg-go` and `amneziawg-tools` pinned to specific commits
- [ ] Build `amneziawg-go` binary (`make`) for ARM64
- [ ] Build `awg` and `awg-quick` tools
- [ ] Stage 2 (`runtime`): Alpine minimal — copy built binaries, install runtime deps (`iptables`, `iproute2`, `bash`, `curl`)
- [ ] Set entrypoint to `/scripts/entrypoint.sh`
- [ ] Validate with `docker build --check` or syntax review

### Task 3: Create postup.sh (iptables kill switch + NAT)

**Files:**
- Create: `scripts/postup.sh`

- [ ] Set `#!/bin/bash` and `set -e`
- [ ] Validate env vars (`LAN_SUBNET`, `VPN_ENDPOINT_IP`, `VPN_ENDPOINT_PORT`, `GATEWAY_IP`) — check format with regex, exit with error if malformed
- [ ] Set default policies: `FORWARD DROP`, `INPUT DROP`, `OUTPUT DROP`
- [ ] Allow loopback traffic
- [ ] Allow established/related connections on INPUT and OUTPUT
- [ ] Allow LAN (`$LAN_SUBNET`) → `awg0` forwarding (outbound VPN)
- [ ] Allow `awg0` → `eth0` established/related forwarding (return traffic)
- [ ] Allow VPN endpoint UDP traffic out `eth0` (`$VPN_ENDPOINT_IP:$VPN_ENDPOINT_PORT`)
- [ ] Allow LAN inbound to RPi (for gateway communication)
- [ ] Allow DHCP client traffic (UDP 67/68) on `eth0`
- [ ] MASQUERADE on `awg0` (NAT outbound)
- [ ] Restrict ICMP outbound to `awg0` only
- [ ] Validate syntax: `bash -n scripts/postup.sh`

### Task 4: Create entrypoint.sh (tunnel setup + watchdog)

**Files:**
- Create: `scripts/entrypoint.sh`

- [ ] Set `#!/bin/bash` and `set -e` (disable `set -e` before watchdog loop)
- [ ] SIGTERM/SIGINT trap: bring down `awg0`, flush iptables, exit cleanly
- [ ] Copy `/etc/amneziawg/fi.conf` → `/tmp/awg0.conf` with `umask 077` and `chmod 600`
- [ ] Strip `DNS =` line from runtime config (AdGuard handles DNS)
- [ ] Add static route for VPN endpoint via LAN gateway: `ip route add $VPN_ENDPOINT_IP/32 via $GATEWAY_IP`
- [ ] Bring up tunnel: `awg-quick up /tmp/awg0.conf`
- [ ] Source `postup.sh` to apply iptables rules
- [ ] Log tunnel status (interface UP, VPN IP assigned) — avoid logging private keys or endpoint details
- [ ] Watchdog loop (every 30s):
  - Check `awg0` interface exists and is UP
  - Check last handshake age < 180s
  - If handshake stale: attempt ping through tunnel (`ping -c1 -W5 -I awg0 100.64.0.1`)
  - If ping fails: increment failure counter, restart `awg0` (`awg-quick down/up`)
  - If 3 consecutive failures: log error, continue retrying (don't exit — `restart: unless-stopped` handles container-level restart)
  - On success: reset failure counter
- [ ] Validate syntax: `bash -n scripts/entrypoint.sh`

### Task 5: Create docker-compose.yml

**Files:**
- Create: `docker-compose.yml`

- [ ] Define `awg-client` service:
  ```yaml
  build: .
  container_name: awg-client
  cap_add:
    - NET_ADMIN
  network_mode: host
  sysctls:
    - net.ipv4.ip_forward=1
    - net.ipv6.conf.all.disable_ipv6=1
  volumes:
    - ./config:/etc/amneziawg:ro
  env_file: .env
  restart: unless-stopped
  healthcheck:
    test: ["CMD", "ping", "-c1", "-W3", "-I", "awg0", "1.1.1.1"]
    interval: 30s
    timeout: 5s
    retries: 3
  ```
- [ ] Verify compose file syntax: `docker compose config`

### Task 6: Validate full build and test checklist

**Files:**
- No new files

- [ ] Run `docker compose build` — verify multi-stage build completes on ARM64
- [ ] Copy `fi.conf` to `config/fi.conf`, create `.env` from `.env.example`
- [ ] Run `docker compose up -d` — verify container starts
- [ ] Verify `awg0` interface is UP: `docker exec awg-client ip link show awg0`
- [ ] Verify iptables rules applied: `docker exec awg-client iptables -L -n`
- [ ] Verify NAT rules: `docker exec awg-client iptables -t nat -L -n`
- [ ] Verify VPN connectivity: `docker exec awg-client ping -c3 -I awg0 1.1.1.1`
- [ ] Verify kill switch: `docker exec awg-client ip link set awg0 down && docker exec awg-client ping -c1 -W3 1.1.1.1` (should fail)
- [ ] Verify healthcheck: `docker inspect --format='{{.State.Health.Status}}' awg-client`

### Task 7: Update documentation

**Files:**
- Create: `README.md`

- [ ] Write README with: purpose, prerequisites (RPi 5, Docker, AmneziaWG config), setup steps, router configuration
- [ ] Document router changes:
  - GL-AXT1800: set DHCP default gateway to `192.168.8.145`
  - AdGuard Home: set upstream DNS to `100.64.0.1`
- [ ] Document common operations: start/stop, view logs, check status
- [ ] Move this plan to `docs/plans/completed/`

## Technical Details

**AmneziaWG v2 config parameters:**
- `Jc` (junk packet count), `Jmin`/`Jmax` (junk packet size range)
- `S1`/`S2` (init packet size padding)
- `H1`-`H4` (header obfuscation values)
- These are protocol-level obfuscation — handled by `amneziawg-go`, no special iptables treatment needed

**Runtime config modification:**
- Strip `DNS =` line because the RPi itself doesn't need DNS override (AdGuard on router handles all client DNS)
- `AllowedIPs = 0.0.0.0/0` stays — RPi routes all forwarded traffic through tunnel
- Static route for VPN endpoint prevents tunnel-inception (endpoint traffic must go direct via LAN gateway)

**iptables chain logic:**
```
FORWARD: DROP (default)
  ACCEPT: eth0 → awg0, src 192.168.8.0/24     (LAN to VPN)
  ACCEPT: awg0 → eth0, state ESTABLISHED,RELATED (VPN return)

OUTPUT: DROP (default)
  ACCEPT: udp, dst VPN_ENDPOINT_IP:PORT, -o eth0 (tunnel establishment)
  ACCEPT: -o awg0                                (all traffic through VPN)
  ACCEPT: -o lo                                  (loopback)
  ACCEPT: state ESTABLISHED,RELATED              (return traffic)
  ACCEPT: dst LAN_SUBNET, -o eth0               (LAN communication)
  ACCEPT: icmp, -o awg0                          (ICMP only through VPN)

INPUT: DROP (default)
  ACCEPT: src LAN_SUBNET, -i eth0               (LAN to RPi)
  ACCEPT: -i awg0, state ESTABLISHED,RELATED    (VPN return)
  ACCEPT: -i lo                                  (loopback)

NAT/POSTROUTING:
  MASQUERADE: -o awg0                            (NAT for forwarded traffic)
```

## Post-Completion

**Router configuration (manual):**
- GL-AXT1800 admin panel → Network → DHCP → set default gateway to `192.168.8.145`
- AdGuard Home admin panel → Settings → DNS → set upstream to `100.64.0.1`
- Verify from a WiFi client: `traceroute 1.1.1.1` should show RPi as first hop
- Verify DNS: `nslookup example.com` should resolve via AdGuard → VPN

**Verification from WiFi client:**
- Check public IP matches VPN exit (visit ip leak test site)
- Check DNS is not leaking (DNS leak test)
- Kill switch test: `docker exec awg-client ip link set awg0 down` — WiFi client should lose internet (no leak)
