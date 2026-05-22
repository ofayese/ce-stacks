# DNS Server Runbook — Synology DS723+ (10.0.1.15)

UI: <http://10.0.1.15:5010>  
Package: Synology DNS Server (BIND-backed)

---

## Architecture

```
Internet
   │
   ▼
Cloudflare  ←── public authoritative NS for olutechsys.com
   │             (keeps acme.sh DNS-01 cert renewals working)
   │
Router DHCP ──► hands out 10.0.1.15 as primary DNS for all LAN clients
   │
   ▼
Synology DNS (10.0.1.15)  ←── internal split-horizon
   ├── olutechsys.com        wildcard → 10.0.1.15 (HAProxy)
   ├── lan                   otsorundscore.lan → 10.0.1.15
   ├── 1.0.10.in-addr.arpa   PTR for 10.0.1.x LAN hosts
   └── 16.172.in-addr.arpa   PTR for 172.16.x.x VPN peers (optional)
```

**Do not point public registrar NS at the NAS.** `10.0.1.15` is RFC 1918
private — public resolvers cannot reach it. Cloudflare stays authoritative
for the public internet. The NAS DNS is internal only, directed via router DHCP.

---

## Zone inventory

| Zone | Type | Purpose |
|---|---|---|
| `olutechsys.com` | Forward/Master | Split-horizon; all hosts + wildcard → 10.0.1.15 |
| `lan` | Forward/Master | `otsorundscore.lan` → 10.0.1.15 (avoids `.local` mDNS conflict) |
| `1.0.10.in-addr.arpa` | Reverse/Master | PTR records for 10.0.1.0/24 LAN |
| `16.172.in-addr.arpa` | Reverse/Master | PTR records for 172.16.0.0/16 VPN peers |

---

## Ordered setup sequence

### Step 1 — Zone: `olutechsys.com`

**DNS Server → Zones → Create → Primary zone**

| Field | Value |
|---|---|
| Domain type | Forward zone |
| Domain name | `olutechsys.com` |
| Primary DNS server | `10.0.1.15` |
| Serial format | Date → `2026052201` |
| Limit zone transfer | ✓ (leave rule list empty) |
| Limit source IP service | ✓ |
| Limit zone updates | ✓ |

Save. Three auto-records appear (SOA, NS, A for `@`).

**Edit the auto-created `@` A record — do not add a duplicate:**

| # | Type | Name | Value | TTL |
|---|---|---|---|---|
| 1 | A (edit `@`) | `@` | `10.0.1.15` | 300 |
| 2 | A (add) | `otsorundscore` | `10.0.1.15` | 300 |
| 3 | A (add) | `*` | `10.0.1.15` | 300 |

The wildcard `*` record means every subdomain (`grafana.olutechsys.com`,
`search.olutechsys.com`, `dozzle.olutechsys.com`, etc.) automatically
resolves to `10.0.1.15` — HAProxy handles the rest. No per-subdomain A
records needed.

Save → Apply.

---

### Step 2 — Zone: `lan`

> **Why `lan` and not `local`?**  
> RFC 6762 strictly reserves `.local` for mDNS (Bonjour/Avahi). Synology
> DSM uses Avahi natively. Creating a unicast DNS zone named `local` will
> conflict with Apple device discovery and Avahi on the NAS itself. Use
> `.lan` (or `.home.arpa` / `.internal`) — no such reservation exists.

**Create → Primary zone**

| Field | Value |
|---|---|
| Domain type | Forward zone |
| Domain name | `lan` |
| Primary DNS server | `10.0.1.15` |
| Serial format | Date → `2026052201` |

Save. Add:

| # | Type | Name | Value | TTL |
|---|---|---|---|---|
| 1 | A | `otsorundscore` | `10.0.1.15` | 300 |

Save → Apply.

---

### Step 3 — Zone: `1.0.10.in-addr.arpa` (LAN reverse)

**Create → Primary zone**

| Field | Value |
|---|---|
| Domain type | Reverse zone |
| Domain name | `1.0.10` (Synology will expand to `1.0.10.in-addr.arpa`) |
| Primary DNS server | `10.0.1.15` |
| Serial format | Date → `2026052201` |

Save. Add:

| # | Type | Reverse IP (host field) | Hostname | TTL |
|---|---|---|---|---|
| 1 | PTR | `15` | `otsorundscore.olutechsys.com` | 7200 |

> For a /24 zone the host field is just the **last octet**: `10.0.1.15` → `15`.

Save → Apply.

---

### Step 4 — Zone: `0.16.172.in-addr.arpa` (VPN reverse, optional)

Only needed if WireGuard/VPN peers should have reverse DNS. Skip if not using.

**Create → Primary zone**

| Field | Value |
|---|---|
| Domain type | Reverse zone |
| Domain name | `0.16.172` (UI appends `.in-addr.arpa` automatically) |
| Primary DNS server | `10.0.1.15` |
| Serial format | Date → `2026052201` |

This is a **/24 zone** covering `172.16.0.0/24`. Host field = **last octet only**.

Save. Add PTRs as VPN peers are assigned fixed IPs in `172.16.0.x`:

| # | Type | Reverse IP (host field) | Hostname | TTL |
|---|---|---|---|---|
| — | PTR | `2` | `peer2.olutechsys.com` | 7200 |

> Host field is the last octet only:  
> `172.16.0.2` → host `2` | `172.16.0.15` → host `15`
>
> If peers are assigned addresses beyond `172.16.0.x`, add additional
> /24 zones: domain `1.16.172` for `172.16.1.x`, etc.

Save → Apply.

---

### Step 5 — Allow DNS queries from

**DNS Server → Settings → General**

Under "Limit DNS query source IP":

```
✓ LAN
✓ Custom  →  172.16.0.0/12
```

> `172.16.0.0/12` covers `172.16.0.0` through `172.31.255.255`, which
> includes:
>
> - `172.16.x.x` — VPN/WireGuard peers
> - `172.29.x.x` — Grafana/Prometheus bridge network
> - `172.30.x.x` — Zabbix bridge network
> - all other Docker bridge subnets in your stacks
>
> Using `/16` would block containers on `172.17`–`172.31` subnets.

Save.

---

### Step 6 — Forwarders (global fallback)

**DNS Server → Settings → Forwarders**

```
10.0.1.1    (router / gateway)
1.1.1.1     (Cloudflare)
8.8.8.8     (Google)
```

Anything not in a local zone gets forwarded upstream.

Save.

---

### Step 7 — Router DHCP

Update your router's DHCP settings to distribute `10.0.1.15` as the primary
DNS server for LAN clients. Secondary can be `1.1.1.1` as fallback if the
NAS is ever offline.

This is what directs LAN devices (laptops, phones, containers) to query the
NAS DNS. No registrar changes required or recommended.

---

## Verification

```bash
# All queries go to the NAS DNS server (10.0.1.15)

# Bare domain — should return 10.0.1.15
nslookup olutechsys.com 10.0.1.15

# Explicit subdomain
nslookup otsorundscore.olutechsys.com 10.0.1.15

# Wildcard subdomain (any service you haven't added explicitly)
nslookup grafana.olutechsys.com 10.0.1.15
nslookup dozzle.olutechsys.com  10.0.1.15

# .lan alias
nslookup otsorundscore.lan 10.0.1.15

# Reverse — LAN host
nslookup -type=PTR 10.0.1.15 10.0.1.15
# → otsorundscore.olutechsys.com

# Public resolution still works (Cloudflare, not NAS)
nslookup olutechsys.com 1.1.1.1
```

---

## File paths on the NAS (DSM 7.3 / DS723+)

> These paths were verified 2026-05-22. They differ from Synology documentation.

| Purpose | Path |
|---|---|
| BIND main config | `/var/packages/DNSServer/target/named/etc/named.conf` |
| Zone load file (edit this) | `/var/packages/DNSServer/target/named/etc/zone/zone.load.conf` |
| Zone declarations (managed by UI) | `/var/packages/DNSServer/target/named/etc/zone/data/<zonename>` |
| Zone master records (managed by UI) | `/var/packages/DNSServer/target/named/etc/zone/master/<zonename>` |

**Reload BIND after manual edits:**
```bash
sudo kill -HUP $(pgrep named)
```

> `synoservicectl` does **not** exist on DS723+ / DSM 7.3. `named-checkzone` is also
> not installed. Use the Synology DNS Server UI or direct file edits + HUP reload.

---

## BIND view structure

The DSM DNS Server creates three BIND views in `zone.load.conf`:

| View | `match-clients` | Purpose |
|---|---|---|
| `internal` | `10.0.0.0/22` | LAN clients — served olutechsys.com, lan, reverse |
| `wireguard` | `172.16.0.0/12` | Docker containers & VPN peers — same zones |
| `external` | `none` | Matches nobody — kept by DSM UI, effectively disabled |

**Critical:** zones added via the UI land in `data/` with an include only in the view
DSM chose (often `external` with `match-clients {none;}`). After adding a new zone via UI,
verify it is also included in `internal` and `wireguard` views in `zone.load.conf`,
otherwise LAN and Docker clients won't see it.

To add a zone to a view manually:
```bash
# Add include line to both internal and wireguard views
sudo nano /var/packages/DNSServer/target/named/etc/zone/zone.load.conf
# Then reload:
sudo kill -HUP $(pgrep named)
```

---

## Adding hosts / services

**New LAN device with a fixed IP:**

1. DNS Server → `olutechsys.com` → Resource Records → Create A record
2. DNS Server → `1.0.10.in-addr.arpa` → Resource Records → Create PTR
3. The wildcard already covers any subdomain; explicit A records only needed
   if the host has a unique IP different from `10.0.1.15`.

**New WireGuard VPN peer with fixed `172.16.0.y` IP:**

1. DNS Server → `0.16.172.in-addr.arpa` → Resource Records → Create PTR
2. Host field = last octet only: `172.16.0.5` → host `5`
3. Update `zones/172.16.0.rev.zone` in this repo.
4. If the peer is in `172.16.1.x` or higher, create a new /24 zone first.

---

## What NOT to do

- **Do not point the public registrar NS at the NAS.** Private IPs (`10.0.1.15`)
  cannot be used as public glue records. Doing so breaks `olutechsys.com`
  publicly and kills `acme.sh` DNS-01 renewals.
- **Do not create a zone named `local`.** It conflicts with mDNS/Avahi.
- **Do not restrict query ACL to `172.16.0.0/16`** — Docker subnets go up to
  `172.31.x.x` and will be blocked. Use `/12`.
