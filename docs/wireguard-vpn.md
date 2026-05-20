# WireGuard VPN -- otsorundscore NAS

**Status:** Phase 4 -- kernel module confirmed loaded (`wireguard 155831 0`).
WireGuard runs as a **native host service** on the NAS (not containerized). Monitoring is
provided by `Prometheus-WireGuard-Exporter` in the `grafana-prom` stack.

---

## Prerequisites

- WireGuard kernel module: `lsmod | grep wireguard` must return a non-empty result.
- `wg-quick` must be installed: `which wg-quick` (installed via SynoCommunity WireGuard package or DSM package manager).
- UDP port `51820` must be port-forwarded on the upstream router to `10.0.1.15:51820`.
  Cloudflare Tunnel does **not** proxy UDP — this port requires a direct router NAT rule.
- The wildcard cert (`/volume2/certs/acme/wildcard/`) is not needed for WireGuard; TLS is
  handled by the WireGuard protocol itself.

---

## Interface Setup

### 1. Generate server keys (one-time)

```bash
# Run on the NAS as root
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key
cat /etc/wireguard/server_public.key   # share this with clients
```

### 2. Create `/etc/wireguard/wg0.conf`

```ini
[Interface]
PrivateKey = <contents of /etc/wireguard/server_private.key>
Address    = 10.200.0.1/24
ListenPort = 51820
# Optional: enable IP forwarding for LAN access from VPN clients
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
DNS      = 10.0.1.15

# --- Peers (one block per device) ---
# Name field is used by prometheus-wireguard-exporter for readable metric labels.

[Peer]
# Name = MacBook Pro (Laolu)
PublicKey  = <client-public-key>
AllowedIPs = 10.200.0.2/32

[Peer]
# Name = iPhone (Laolu)
PublicKey  = <client-public-key>
AllowedIPs = 10.200.0.3/32
```

**Address space:** `10.200.0.0/24` — avoids conflict with:
- LAN: `10.0.1.0/24`
- Docker subnets: all stacks use `172.x.x.0/24` ranges (see `host.map` and individual compose files)

### 3. Bring up the interface

```bash
wg-quick up wg0
wg show     # verify interface + peers
```

### 4. Persist across reboots (DSM Task Scheduler)

DSM does not run `rc.d` scripts at boot. Use Task Scheduler instead:

1. DSM → Control Panel → Task Scheduler → Create → Triggered Task → User-defined script
2. **Event:** Boot-up
3. **User:** root
4. **Task:** `wg-quick up wg0`
5. Save. The interface comes up automatically after each NAS restart.

---

## Client Configuration (example)

Generate a key pair on the client device:

```bash
wg genkey | tee client_private.key | wg pubkey > client_public.key
```

Client `wg0.conf`:

```ini
[Interface]
PrivateKey = <client_private.key>
Address    = 10.200.0.2/32
DNS        = 10.0.1.15

[Peer]
PublicKey  = <contents of /etc/wireguard/server_public.key>
Endpoint   = <your-public-IP-or-DDNS>:51820
AllowedIPs = 10.0.1.0/24, 10.200.0.0/24
PersistentKeepalive = 25
```

`PersistentKeepalive = 25` keeps the session alive through NAT — important for mobile devices.

---

## Monitoring

The `Prometheus-WireGuard-Exporter` container in the `grafana-prom` stack reads the WireGuard
kernel state via `CAP_NET_ADMIN` + `network_mode: host` and exports peer metrics on `9586`.

### Key metrics

| Metric | Description |
|---|---|
| `wireguard_peer_last_handshake_seconds` | Unix epoch of last successful handshake (0 = never) |
| `wireguard_peer_received_bytes_total` | Bytes received from peer |
| `wireguard_peer_transmitted_bytes_total` | Bytes sent to peer |

### Alert thresholds (in `alerts/nas_alerts.yml`)

| Alert | Condition | Severity |
|---|---|---|
| `WireGuardPeerStale` | `time() - last_handshake > 600s` AND last_handshake > 0 | warning |
| `WireGuardPeerNeverConnected` | `last_handshake == 0` for > 10 min | warning |
| `WireGuardTunnelDown` | Exporter unreachable for > 2 min | critical |
| `WireGuardNoPeersConfigured` | Exporter up but zero peer metrics | warning |

**600s threshold rationale:** WireGuard rekeys every 180s when a session is active.
600s (10 min) allows mobile peers on aggressive NAT to miss two rekey cycles before alerting —
reducing noise from cellular hand-offs without hiding genuine outages.

### Checking peer state manually

```bash
# On the NAS host:
wg show
# Example output:
# interface: wg0
#   public key: <server-pubkey>
#   listening port: 51820
#
# peer: <client-pubkey>
#   endpoint: <client-public-ip>:XXXXX
#   allowed ips: 10.200.0.2/32
#   latest handshake: 2 minutes, 15 seconds ago
#   transfer: 1.23 MiB received, 4.56 MiB sent
```

A `latest handshake` line older than ~10 minutes indicates the peer is likely offline.

### Deploying the exporter

The exporter starts with the grafana-prom stack. **wg0 must be up first:**

```bash
wg show                          # confirm interface is up
docker compose -f stacks/grafana-prom/compose.yaml up -d wireguard-exporter
docker logs Prometheus-WireGuard-Exporter --tail 20
curl -s http://10.0.1.15:9586/metrics | grep wireguard_peer
```

---

## Security Notes

- `/etc/wireguard/wg0.conf` is mounted `:ro` into the exporter container. The private key
  field is present in the file but the exporter only reads `[Interface]` Name and `[Peer]`
  Name/PublicKey fields for metric labelling — it does not transmit or log private keys.
- UDP 51820 is exposed directly to the internet via router port-forward. Ensure:
  - Only valid peer public keys are in `wg0.conf` (WireGuard drops packets from unknown peers)
  - DSM firewall allows `10.200.0.0/24` source for LAN service access from VPN clients
- The VPN address space (`10.200.0.x`) should not overlap with any Docker subnet in this repo.
  Confirm: `docker network ls --format '{{.Name}}' | xargs -I{} docker network inspect {} --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}}{{end}}'`
