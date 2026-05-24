
# Claude Code / Agent Auxiliary Prompt: DNS & Network Architecture

**Reference:** `09-auxiliary-prompts.md`, `03-safety-and-risk-assessment.md`

## 1. Agent Role & Purpose

You are the primary infrastructure agent managing the `ce-stacks` Synology DS723+ environment. Your single job in this context is to deploy, audit, and repair DNS settings for the `10.0.1.15` DNS server. You MUST strictly enforce the **Internal Split-Horizon DNS** architecture [5].

## 2. Missing Information Policy & Clarification

* **Strict Clarification Mode:** If the target environment variables, Docker bridge subnets, or host IPs are unspecified or ambiguous, you MUST stop and ask the user for clarification. Do not guess, assume, or hallucinate IP ranges [6-8].

## 3. Safety & Risk Constraints (CRITICAL)

You must evaluate all proposed changes against these hard constraints before taking action [3, 4]:

* **NO PUBLIC GLUE RECORDS FOR PRIVATE IPs:** You MUST NOT configure `10.0.1.15` (RFC 1918 private IP) as an authoritative nameserver or glue record at public registrars (Cloudflare/Squarespace). This breaks public resolution.
* **NO .LOCAL TLDs:** You MUST NOT use the `.local` top-level domain for forward zones. It is strictly reserved for Multicast DNS (mDNS/Bonjour) by RFC 6762 and breaks Synology Avahi/Apple device discovery. Use `.lan` instead.
* **NO LOCALHOST LOOPBACKS ON PUBLIC ZONES:** The `@` A record for `olutechsys.com` MUST resolve to `10.0.1.15`. Pointing it to `127.0.0.1` causes client machines to query themselves.
* **ALLOW DOCKER SUBNETS:** Docker bridge networks (e.g., Homepage's `172.30.x.x` and Grafana's `172.29.x.x`) MUST be allowed to query the DNS server. Limit source IP services to `172.16.0.0/12`, NOT `/16`.

## 4. Standard Operating Procedure: Clean Slate DNS Build

Execute the following ordered sequence to configure the Synology DNS Server (`http://10.0.1.15:5010`). Preserve existing behavior unless a behavior change is explicitly requested [7].

### Zone 1 — `olutechsys.com` (Forward/Master)

Intercepts local requests and routes securely to HAProxy without leaving the LAN.

**Create → Primary zone**

* **Domain type:** Forward zone
* **Domain name:** `olutechsys.com`
* **Primary DNS server:** `10.0.1.15`
* **Serial format:** Date (e.g., `2026052201`)
* **Limit zone transfer:** ✓ checked (leave rule list empty)
* **Limit source IP service:** ✓ checked
* **Limit zone updates:** ✓ checked

**Add/Edit Resource Records:**

| # | Type | Name / Host | Value | TTL | Action |
|---|---|---|---|---|---|
| 1 | **A** | `@` | `10.0.1.15` | 300 | Edit auto-created record (do NOT use 127.0.0.1) |
| 2 | **A** | `otsorundscore` | `10.0.1.15` | 300 | Create new |
| 3 | **A** | `*` | `10.0.1.15` | 300 | Create wildcard for all HAProxy subdomains |

### Zone 2 — `lan` (Forward/Master)

Creates safe local aliases without CNAME conflicts.

**Create → Primary zone**

* **Domain type:** Forward zone
* **Domain name:** `lan`
* **Primary DNS server:** `10.0.1.15`
* **Serial format:** Date (e.g., `2026052201`)

**Add Resource Records:**

| # | Type | Name / Host | Value | TTL |
|---|---|---|---|---|
| 1 | **A** | `otsorundscore` | `10.0.1.15` | 300 |
*(Creates `otsorundscore.lan` resolving to `10.0.1.15`)*

### Zone 3 — `1.0.10.in-addr.arpa` (Reverse)

Matches the physical NAS subnet (`10.0.1.x`).

**Create → Primary zone**

* **Domain type:** Reverse zone
* **Domain name:** `1.0.10`
* **Primary DNS server:** `10.0.1.15`
* **Serial format:** Date (e.g., `2026052201`)

**Add Resource Records:**

| # | Type | Reverse IP | Hostname | TTL |
|---|---|---|---|---|
| 1 | **PTR** | `15` | `otsorundscore.olutechsys.com` | 7200 |

### Global Settings & Security

**Settings → General → Allow DNS queries from:**
Check the following to ensure all physical LAN clients and internal Docker containers can resolve DNS:

```text
✓ LAN
✓ Custom  →  172.16.0.0/12
```

```text
Settings → Forwarders (Global Fallback):
10.0.1.1    (Local Router / Gateway)
1.1.1.1     (Cloudflare Public DNS)
8.8.8.8     (Google Public DNS)
```

## 5. Tool Execution & Completion Criteria (What "Done" Looks Like)

The task is only complete when the configuration is verified. Use your shell execution tool to run the following validation tests. If any test fails, you must patch the failing section and re-test.

```bash
# 1. Verify apex domain routes to NAS, not localhost
nslookup olutechsys.com 10.0.1.15
# Expected Address: 10.0.1.15

# 2. Verify wildcard subdomain routes to HAProxy
nslookup grafana.olutechsys.com 10.0.1.15
# Expected Address: 10.0.1.15

# 3. Verify internal alias avoids mDNS conflicts
nslookup otsorundscore.lan 10.0.1.15
# Expected Address: 10.0.1.15

# 4. Verify reverse IP lookup
nslookup -type=PTR 10.0.1.15 10.0.1.15
# Expected Name: otsorundscore.olutechsys.com
```

## 6. External Reference Links

If asked to configure the public internet boundary, direct the user to the following official documentation without executing changes:

- Cloudflare DNS Setup (Full Setup): https://developers.cloudflare.com/dns/zone-setups/full-setup/
- Cloudflare Tunnel (Secure Ingress): https://developers.cloudflare.com/tunnel/setup/

---

## 7. Compound Learnings (append new entries below)

### What Works

[2026-05-22] `stacks/_dns-server/zones/` as reference source of truth: keeping
zone files under git makes drift visible. After any UI change in Synology DNS
Server, manually update the matching file in `zones/` so the repo stays in sync.

[2026-05-22] ACL `172.16.0.0/12` (not `/16`) is the correct CIDR for the DNS
trusted ACL. The repo uses subnets across `172.20–172.31.x.x`; `/16` only covers
`172.16.x.x` and silently blocks all Docker bridge containers from internal DNS.
Always use `/12` in `named.conf.additions` and the Synology DNS UI → Settings →
General → Custom → `172.16.0.0/12`.

[2026-05-22] Removing a stack properly requires three steps: (1) delete the
`stacks/<name>/` directory, (2) remove from README directory layout, (3) remove
from README subnet table. Skipping any step leaves phantom references that
confuse future audits and agents.

### What Failed

[2026-05-22] `named.conf.additions` drifted from the zone files: the `.conf`
file still declared `zone "otsorundscore.local"` (banned .local TLD) while
`zones/lan.zone` had already been corrected to `.lan`. Always treat `named.conf.additions`
and `zones/` as a matched pair — edit both together or neither.

[2026-05-22] `stacks/databases/` was listed in README and the subnet table with
subnet `172.28.0.0/24` (`db-net`) but had no `compose.yaml` on disk (archived).
Synology ships MariaDB and PostgreSQL as native DSM packages — no container
needed. Removed the entry and retired the subnet allocation.

### Recurring Audit Triggers

[2026-05-22] When new stacks are added to `stacks/`, ALWAYS update:
  1. README "Directory Layout" tree
  2. README "Network Subnets" table (if the stack defines a bridge network)
  3. `.github/compose-ci.env` if the stack has required env vars with `:?` guards

[2026-05-22] `docs/otsorundscore_zonefile/` contains a legacy Active Directory
DNS export (loopback zone, `_msdcs` PTR records, integer serial). It is NOT
part of the current DNS architecture. Do not apply it. See
`docs/otsorundscore_zonefile/WARNING_LEGACY_DO_NOT_APPLY.md`.

[2026-05-22] Synology MariaDB 10 DSM package: the system config at
`/usr/local/mariadb10/etc/mysql/my.cnf` is read-only ("DO NOT EDIT"). Custom
overrides go in `/var/packages/MariaDB10/etc/my.cnf` (create if absent; included
via `!include` at the bottom of the system file). Restart with
`sudo synopkg stop MariaDB10 && sudo synopkg start MariaDB10`. Verified
`max_allowed_packet=128M` and `innodb_log_file_size=256M` survive restarts.

[2026-05-22] Zabbix 7.4.x seed data contains large image/icon INSERTs that
exceed the default 1 MB `max_allowed_packet`. The entrypoint sentinel checks for
the `dbversion` table — if it exists (even partially), schema import is skipped
entirely and Zabbix crashes on empty `users`. Always: (1) stop the container,
(2) drop + recreate the DB, (3) verify 0 tables before starting. Use
`--max_allowed_packet=128M` on the mysql client for the data INSERT pass.
Root cause fix: permanent server-side `max_allowed_packet=128M` in
`/var/packages/MariaDB10/etc/my.cnf` covers all stacks (zabbix, flowise, n8n,
grafana-prom) without per-command flags.

[2026-05-22] NAS hardware facts for stack planning: DS723+ is **aarch64**
(AMD Ryzen R1600 64-bit ARM-compatible). Official PyTorch Docker images are
x86_64 only. For PyTorch on this NAS, use `arm64v8/python:3.11-slim` base +
`pip install torch --index-url https://download.pytorch.org/whl/cpu`.
Ruby 3.0.2 (aarch64) and Redis are native DSM packages — both can be used
without Docker containers.

[2026-05-22] `172.16.0.0/12` covers `172.16.0.0–172.31.255.255`. Any new Docker
bridge subnet at `172.32.x.x` or above falls OUTSIDE this range and will be
silently blocked from the internal DNS. Allocate new subnets within
`172.16–172.31.x.x` only, or expand the ACL to `/11` (covers up to 172.47.x.x).

### Native DSM Packages (no Docker containers needed)

[2026-05-22] Confirmed native on the NAS — do not create Docker sidecars for:
  - MariaDB 10.11 (package: `MariaDB10-10.11.11-1551`)
  - phpMyAdmin 5.2.2
  - Ruby 3.0.2 (aarch64)
  - Redis (installed, version TBC)
  Use TCP `127.0.0.1:3306` for MariaDB from containers; Unix socket
  `/run/mysqld/mysqld10.sock` works only for containers that mount it.

[2026-05-23] Native DSM Redis config path: `/var/packages/redis/var/redis.conf`.
Reference config is in `stacks/_redis/redis.conf`. Two critical non-default settings:
  1. `protected-mode no` — `bind 0.0.0.0` + `nopass` default user + `protected-mode yes`
     (the Redis default) silently blocks ALL non-loopback clients including every Docker
     bridge container at `172.x.x.x`. Must be set to `no` on a private LAN.
  2. `maxmemory 512mb` + `maxmemory-policy allkeys-lru` — prevents unbounded growth
     on 32 GB NAS where Redis is used as a cache.
  Restart: `sudo synopkg stop redis && sudo synopkg start redis`

[2026-05-23] Prometheus cannot scrape Redis directly on port 6379 — it speaks HTTP
and Redis speaks its own wire protocol. Always use `redis_exporter` (oliver006/redis_exporter,
port 9121) as a sidecar in the grafana-prom stack. Pointing prom.yml at :6379 directly
logs connection errors and produces no metrics. The `searxng` stack runs its own Valkey
sidecar and does NOT use the native DSM Redis.
