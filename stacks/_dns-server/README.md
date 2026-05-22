# _dns-server — Synology DNS Server (DSM Native Package)

> **Not a Docker stack.** The DNS server on `otsorundscore` runs as a native
> DSM package (`@appstore/DNSServer`, BIND-backed) managed through the Synology
> web UI at `http://10.0.1.15:5010`. There is no `compose.yaml` here.

---

## What this directory contains

| File / Dir | Purpose |
|---|---|
| `RUNBOOK.md` | Step-by-step UI walkthrough for configuring all zones from scratch |
| `named.conf.additions` | BIND config snippet to paste into `/var/packages/DNSServer/target/etc/named.conf` |
| `zones/` | Reference copies of all zone files (single source of truth for zone content) |

The files in `zones/` are **reference copies** — the live zone data lives inside the DSM DNS Server package at `/var/packages/DNSServer/target/named/`. Keep these files in sync when you make UI changes.

---

## Architecture

```
Internet
   │
   ▼
Cloudflare  ←── public authoritative NS for olutechsys.com
   │
Router DHCP ──► hands out 10.0.1.15 as primary DNS for all LAN clients
   │
   ▼
Synology DNS (10.0.1.15)  ←── internal split-horizon
   ├── olutechsys.com        wildcard → 10.0.1.15 (HAProxy)
   ├── lan                   otsorundscore.lan → 10.0.1.15
   ├── 1.0.10.in-addr.arpa   PTR for 10.0.1.x LAN hosts
   └── 0.16.172.in-addr.arpa PTR for 172.16.0.x VPN/WireGuard peers
```

**Do not point public registrar NS records at 10.0.1.15.** It is RFC 1918
private — public resolvers cannot reach it. Cloudflare remains authoritative
for the public internet; the NAS DNS is internal only, directed via DHCP.

---

## Safety rules (enforced in CLAUDE.md)

| Rule | Detail |
|---|---|
| **No `.local` TLD zones** | `.local` is reserved for mDNS/Bonjour (RFC 6762). Use `.lan` instead. |
| **ACL must use `/12`** | `172.16.0.0/12` covers all Docker bridge subnets (`172.16–172.31.x.x`). Using `/16` blocks most containers from reaching the DNS server. |
| **Apex `@` record → `10.0.1.15`** | Never point `olutechsys.com` to `127.0.0.1` — that makes clients query themselves. |
| **No public glue records** | Never add `10.0.1.15` as an NS record at Cloudflare/Squarespace. |

---

## DSM package upgrade warning

Synology package updates for DNS Server **may overwrite**
`/var/packages/DNSServer/target/etc/named.conf`, resetting any manual BIND
configuration added from `named.conf.additions`. After every DSM DNS Server
package update:

1. Check whether `named.conf` was reset:
   ```bash
   grep "trusted" /var/packages/DNSServer/target/etc/named.conf
   ```
2. If missing, re-apply the additions:
   ```bash
   # Follow instructions at top of stacks/_dns-server/named.conf.additions
   named-checkconf /var/packages/DNSServer/target/etc/named.conf
   synoservicectl --reload named
   ```

---

## Validation

```bash
# 1. Apex domain → NAS (not localhost)
nslookup olutechsys.com 10.0.1.15
# Expected: 10.0.1.15

# 2. Wildcard subdomain → HAProxy
nslookup grafana.olutechsys.com 10.0.1.15
# Expected: 10.0.1.15

# 3. Internal .lan alias
nslookup otsorundscore.lan 10.0.1.15
# Expected: 10.0.1.15

# 4. Reverse PTR
nslookup -type=PTR 10.0.1.15 10.0.1.15
# Expected: otsorundscore.olutechsys.com
```

---

## Reference links

- [Synology KB — How to set up your domain with Synology DNS Server](https://kb.synology.com/en-us/DSM/tutorial/How_to_set_up_your_domain_with_Synology_DNS_Server)
- [Cloudflare DNS Full Setup](https://developers.cloudflare.com/dns/zone-setups/full-setup/) — for the public internet boundary (do not touch from the NAS)
