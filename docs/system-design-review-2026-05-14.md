# ce-stacks System Design Review
**Date:** 2026-05-14
**Scope:** All stacks under `/volume2/docker/ce-stacks/stacks/` on Synology DS723+
**Status:** 12 architectural gaps identified, prioritized below

---

## 1. System Context

`ce-stacks` is a self-hosted infrastructure repository running on a Synology DS723+ NAS
(AMD Ryzen R1600, 2 cores / 4 threads, 32 GB RAM). The stack provides:

- **AI inference** via Ollama (CPU-only, 14B-class models) with an Open-WebUI frontend
- **Agentic tooling** via Warp (terminal AI) and a Docker MCP gateway
- **Observability** via Prometheus + Grafana + SNMP exporter + cAdvisor + node-exporter
- **Shared databases** via MariaDB + PostgreSQL (with proper Docker secrets)
- **Dev environment** via code-server (VS Code in browser) with its own MySQL and phpMyAdmin
- **Cert management** via acme.sh (Cloudflare DNS-01 challenge, Let's Encrypt)
- **Ingress** via Cloudflare Tunnel (cloudflared native SynoCommunity package) and bare-metal HAProxy

The cross-stack backbone is the `ce-internal` external network (172.26.0.0/24). Services that need to
communicate across stacks join this network. Services that don't need cross-stack access remain
on their own isolated bridge networks.

---

## 2. Identified Gaps (Priority Order)

### GAP-01 -- cAdvisor is unreachable by Prometheus [CRITICAL]

**What's broken:** In `stacks/grafana-prom/compose.yaml`, `cadvisor` has **no `networks:` key**.
In Docker Compose, a service without an explicit network assignment joins the project's auto-created
`default` network (typically `grafana-prom_default`), not any of the named networks. Meanwhile,
Prometheus is on `prometheus-net`, which is where it tries to scrape `prometheus-cadvisor:8080`.

```yaml
# cadvisor -- MISSING networks block
cadvisor:
  image: gcr.io/cadvisor/cadvisor:v0.52.1
  # ...no networks key -- joins grafana-prom_default, NOT prometheus-net
```

**Effect:** Prometheus cannot resolve `prometheus-cadvisor` by DNS on `prometheus-net`. All
container CPU/memory/IO panels in Grafana are silently returning no data. The dependency
`prometheus: depends_on: cadvisor: condition: service_healthy` still passes because the
healthcheck runs on the cAdvisor container itself -- it does not verify Prometheus can reach it.

**Fix:** Add `networks: - prometheus-net` to the `cadvisor` service block.

```yaml
cadvisor:
  # ...existing config...
  networks:
    - prometheus-net
```

---

### GAP-02 -- MCP Gateway cannot reach Ollama [HIGH]

**What's broken:** `agents_gateway_data/compose.yaml` puts `mcp-gateway` on `agents-gateway-net`
(172.31.7.0/24) only. Ollama is on `ollama-net` + `ce-internal`. The `mcp-gateway` has no
membership in `ce-internal`.

```
mcp-gateway  ->  agents-gateway-net (172.31.7.x)   [FAIL] NO ce-internal
ollama       ->  ollama-net (172.27.x) + ce-internal (172.26.x)
```

**Effect:** Any agentic workflow that routes through the MCP gateway and needs local LLM inference
(e.g., tool calls that invoke Ollama models) will fail to resolve `http://ollama:11434`. The
gateway falls back to external API calls or errors silently.

**Fix:** Add `ce-internal` to the mcp-gateway's network list:

```yaml
# agents_gateway_data/compose.yaml
services:
  mcp-gateway:
    networks:
      - agents-gateway-net
      - ce-internal

networks:
  agents-gateway-net:
    name: agents-gateway-net
    driver: bridge
    # ...ipam...
  ce-internal:
    external: true
```

---

### GAP-03 -- Watchtower enabled on stateful databases [HIGH]

**What's broken:** `databases/compose.yaml` has `com.centurylinklabs.watchtower.enable=true` on
both `mariadb:11.4.10` and `postgres:16-alpine`. This means Watchtower can auto-upgrade these
images, including across major versions (e.g., MariaDB 11.4 -> 11.5+, or PostgreSQL 16 -> 17).
Database engines require explicit in-place upgrade procedures between major versions; a
cold-swap of the image with unchanged data files corrupts the catalog.

The same label is on `code-server`'s `mysql:8.3` container.

**Fix:** Pin stateful databases to digest and disable Watchtower:

```yaml
labels:
  - com.centurylinklabs.watchtower.enable=false  # NEVER auto-upgrade databases

image: mariadb:11.4.10  # pin to patch -- upgrade manually, following the upgrade guide
```

For databases, major version upgrades should follow the documented dump -> new container -> restore
path, not an image swap.

---

### GAP-04 -- No Alertmanager and No Alert Rules [HIGH]

**What's broken:** `prom.yml` has no `rule_files:` block and no `alerting:` block. Prometheus
collects 15-second interval metrics from the NAS, node-exporter, cAdvisor, SNMP, and Watchtower
-- but no alert rules are evaluated, and there is no Alertmanager to route notifications.

**Effect:** High disk usage, OOM pressure, service downtime, and certificate expiry go unnoticed
until the operator manually checks Grafana. This is a full monitoring stack with zero proactive
alerting.

**Fix (two parts):**

Part A -- add alert rules file:
```yaml
# stacks/grafana-prom/alerts/nas_alerts.yml
groups:
  - name: nas
    rules:
      - alert: HighMemoryPressure
        expr: (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) < 0.10
        for: 5m
        annotations:
          summary: "NAS available memory below 10%"
      - alert: DiskUsageCritical
        expr: (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) < 0.10
        for: 5m
        annotations:
          summary: "Root filesystem below 10% free"
      - alert: ContainerDown
        expr: up == 0
        for: 2m
        annotations:
          summary: "Scrape target {{ $labels.job }} is down"
```

Part B -- add Alertmanager service to `grafana-prom/compose.yaml` and wire a Discord webhook
(the webhook URL is already in `acme-sh/.env` as `DISCORD_WEBHOOK_URL`).

---

### GAP-05 -- Memory Overcommit Risk [HIGH]

**What's configured:** Explicit `mem_limit` values across running stacks:

| Stack / Service       | mem_limit |
|-----------------------|-----------|
| ollama                | 16 g      |
| open-webui            | 2 g       |
| code-server           | 4 g       |
| code-server mysql     | 2 g       |
| code-server pma       | 512 m     |
| grafana               | 512 m     |
| prometheus            | 1 g       |
| node-exporter         | 256 m     |
| snmp-exporter         | 256 m     |
| cadvisor              | 256 m     |
| mariadb               | 2 g       |
| postgres              | 1 g       |
| adminer               | 256 m     |
| mcp-gateway           | 512 m     |
| acme-sh               | 128 m     |
| warp (3 containers)   | unset     |
| dockhand              | unset     |
| watchtower            | unset     |
| **TOTAL (explicit)**  | **~30.4 g** |

DSM itself consumes 3-4 GB. Packages (cloudflared, HAProxy) add ~200 MB. Total potential
commit: **34-35 GB on a 32 GB machine.** With memory limits set per-container, the kernel's
OOM killer will shoot random containers rather than gracefully degrading. The risk is
highest when Ollama is actively loading a 14B model (~8.5 GB) concurrently with a VS Code
build in code-server.

**Fix (two parts):**

1. Reduce `ollama` mem_limit from 16g to 14g (sufficient for Q4_K_M 14B + KV cache, saves 2 GB headroom).
2. Add `mem_limit` to `warp`, `warp-agent`, `warp-claude-cli-sidecar`, `dockhand`, and `watchtower`
   (256m-512m each) to prevent unbounded growth.
3. Set `mem_reservation` (soft limit) on Ollama and code-server to give the kernel earlier signal:

```yaml
ollama:
  mem_limit: 14g
  mem_reservation: 8g  # trigger reclaim before hard limit
```

---

### GAP-06 -- Unauthenticated Ollama API on LAN [MEDIUM]

**What's broken:** `ollama/compose.yaml` binds port `10.0.1.15:11434:11434` on the LAN.
Ollama has no built-in auth mechanism -- any device on the 10.0.1.x subnet (or any VLAN
that can reach it) can:

- List and pull models (`ollama pull <arbitrary-model>`, filling the 16 GB volume)
- Delete models (`ollama rm`)
- Run arbitrary inference (consuming CPU and memory)

**Fix options (pick one):**

Option A -- Remove the host port binding entirely. Ollama is already accessible within `ce-internal`
by DNS name (`http://ollama:11434`). External UIs (Open-WebUI) that need it should also be on
`ce-internal`. This is the correct zero-trust approach.

Option B -- If DSM Application Portal or Cloudflare Tunnel needs to proxy requests to Ollama,
keep the port but add an `OLLAMA_API_KEY` environment variable (available since Ollama 0.1.24):

```yaml
environment:
  - OLLAMA_API_KEY=${OLLAMA_API_KEY:?Set OLLAMA_API_KEY in .env}
```

Then configure the Cloudflare access policy or Traefik middleware to forward the bearer token.

---

### GAP-07 -- warp-main Uses Wrong Image Architecture [MEDIUM]

**What's broken:** `warp-main/compose.yaml` uses `warpdotdev/warp:0.0.32`, which is the
**Docker Desktop extension** image -- a UI component designed to run inside Docker Desktop's
extensions runtime, not as a standalone server on a Synology NAS. The agent is configured to
reach `CLAUDE_API_HOST=host.docker.internal` at port 3000, which presupposes Claude Code (or a
compatible API proxy) is running as a local process on the NAS host at that port.

```yaml
warp-agent:
  environment:
    - CLAUDE_HOST=host.docker.internal   # expects Claude Code daemon on NAS host
    - CLAUDE_PORT=3000
```

**Effect:** The agent cannot connect to a Claude backend. The sidecar's healthcheck
(`curl -fs http://127.0.0.1:8080/`) may pass even though the connection chain is broken.

**Fix:** Determine the correct Warp server image for self-hosted deployment (check
[Warp Platform docs](https://docs.warp.dev/reference/cli/api-keys)) and update the compose.
If Warp is intended to reach Claude via the Anthropic API (not a local proxy), the environment
should point to `api.anthropic.com` with an `ANTHROPIC_API_KEY`, not `host.docker.internal:3000`.

---

### GAP-08 -- Secret Inconsistency Across Stacks [MEDIUM]

**What's broken:** Two incompatible secret patterns coexist:

| Stack            | Pattern                              | Security posture     |
|------------------|--------------------------------------|----------------------|
| `databases`      | Docker file secrets (`/run/secrets`) | [OK] Best practice      |
| `code-server`    | `.env` environment variables         | [FAIL] Visible in `docker inspect` |
| `grafana-prom`   | `.env` for SNMP credentials          | [FAIL] Visible in `docker inspect` |
| `acme-sh`        | `.env` for `CF_Token`                | [FAIL] Visible in `docker inspect` |
| `agents_gateway` | `.env` (no secrets used)             | --                    |

`docker inspect <container>` exposes all environment variables to any user with Docker socket
access, including `CODE_SERVER_PASSWORD`, `SUDO_PASSWORD`, `CF_Token`, and SNMP credentials.

**Fix:** Migrate all stacks to the Docker secrets pattern used in `databases/`:

```yaml
# acme-sh example
environment:
  - CF_Token_FILE=/run/secrets/cf_token    # use _FILE convention
secrets:
  - cf_token
secrets:
  cf_token:
    file: ${STACK_ROOT}/acme-sh/secrets/cf_token.txt
```

Note: not all images support `_FILE` suffix convention. For those (like acme.sh), use
Docker secrets mounted as a file and a startup wrapper that `export`s the value from the file.

---

### GAP-09 -- code-server MySQL is Isolated and Duplicates the Central DB Stack [MEDIUM]

**What's broken:** `code-server/compose.yaml` runs its own `mysql:8.3` container on port :3307
within `code-server-net` only -- it has no connection to `ce-internal` and no connection to
the `databases` stack. This means:

1. The central backup strategy (if any) cannot reach it via Docker network.
2. Secrets are duplicated: the code-server stack maintains its own `MYSQL_ROOT_PASSWORD`,
   `MYSQL_USER`, `MYSQL_PASSWORD` separate from the databases stack's secrets.
3. Two separate MySQL/MariaDB engines are running simultaneously, competing for memory
   (code-server MySQL: 2 GB + the central MariaDB: 2 GB).

**Fix options:**

Option A (preferred) -- Remove the MySQL container from code-server. Create a `code_server_dev`
database in the central MariaDB (already on `ce-internal`). Connect code-server to `ce-internal`
and configure the MySQL connection string to `mariadb:3306`. This consolidates ops, backup,
and secrets into one place.

Option B -- If isolation is intentional (e.g., the database is used for student/scratch work),
add a `watchtower.enable=false` label and document the isolation explicitly.

---

### GAP-10 -- No Documented Backup / Disaster Recovery Strategy [MEDIUM]

**What's at risk:** The following stateful volumes contain data that cannot be recreated:

| Volume / Path                        | Content                          | Approx Size |
|--------------------------------------|----------------------------------|-------------|
| `databases/db/mariadb`               | Application MariaDB data         | Variable    |
| `databases/db/postgres`              | Application PostgreSQL data      | Variable    |
| `code-server/config`                 | VS Code settings, extensions     | ~1-2 GB     |
| `ollama/data/ollama`                 | Downloaded models                | ~15-25 GB   |
| `ollama/data/open-webui`             | Chat history, user accounts      | Variable    |
| `grafana-prom/data/grafana`          | Dashboards, datasources          | ~100 MB     |
| `grafana-prom/data/prometheus`       | 60-day metric TSDB               | ~2-5 GB     |
| `acme-sh/data`                       | Certificates, account keys       | ~10 MB      |

No Hyper Backup jobs, `rsync` cron tasks, or backup containers (e.g., `duplicati`, `borgmatic`)
are present in any stack.

**Minimum viable backup plan:**

1. **Synology Hyper Backup:** Target `/volume2/docker/ce-stacks/stacks/` -> external USB or
   Synology C2. Exclude `ollama/data/ollama` (models can be re-pulled) and
   `grafana-prom/data/prometheus` (TSDB is ephemeral telemetry).
2. **Pre-backup hooks:** Stop MariaDB/PostgreSQL containers before Hyper Backup snapshot
   to ensure data-file consistency, or use `mysqldump` / `pg_dump` as a scheduled cron.
3. **Certificate safety:** `acme-sh/data` is the most critical small volume -- losing the
   Let's Encrypt account key requires domain re-validation. Back this up daily.

---

### GAP-11 -- HAProxy Bare-Metal: No Observability [LOW]

**What's broken:** `stacks/_haproxy/` manages a bare-metal HAProxy installation on the
Synology host. No Prometheus exporter (`haproxy_exporter`) is configured, so the
Grafana dashboard has zero visibility into:

- Frontend/backend connection counts
- Health check failures on upstream services
- Request rate and latency distribution

There is also no restart mechanism -- if HAProxy crashes (OOM, config error), DSM will not
restart it automatically (no Docker `restart: unless-stopped`).

**Fix:** Add `prom/haproxy-exporter` as a new container in the grafana-prom stack,
pointing at the HAProxy stats socket:

```yaml
haproxy-exporter:
  image: prom/haproxy-exporter:v0.15.0
  command:
    - "--haproxy.scrape-uri=unix:/var/run/haproxy/admin.sock"
  volumes:
    - /var/run/haproxy:/var/run/haproxy:ro  # bind-mount HAProxy socket
```

Then add a `haproxy` job to `prom.yml`.

---

### GAP-12 -- Second Undocumented SNMP Target [LOW]

**What's noted:** `prom.yml` contains a second SNMP scrape target:

```yaml
- targets: ["10.0.1.24:161"]
  labels:
    instance: misfitsds
```

`10.0.1.24` (labeled `misfitsds`) is a second NAS or network device that is not referenced
anywhere else in the repository -- no docs, no `.env.example` mention, no architecture diagram
annotation. If this device changes IP or goes offline, Prometheus will accumulate scrape errors
silently (job is `up=0` but no alert exists for it).

**Fix:** Document this device in `docs/` (what it is, why it's monitored here rather than
in a separate stack). Ensure the `ContainerDown` alert rule from GAP-04 also covers SNMP
targets by adding an `instance_down` rule for `job="nas"`.

---

## 3. Trade-off Analysis

| Gap        | Effort   | Risk if left unfixed         | Fix complexity |
|------------|----------|------------------------------|----------------|
| GAP-01     | XS       | Container metrics missing    | 3-line change  |
| GAP-02     | XS       | Agentic MCP->Ollama broken    | 5-line change  |
| GAP-03     | XS       | DB corruption on auto-update | Label change   |
| GAP-04     | M        | Blind to failures            | New service    |
| GAP-05     | S        | OOM kills random containers  | Config tuning  |
| GAP-06     | XS-S     | Model theft/abuse on LAN     | Port removal   |
| GAP-07     | M        | Warp agent non-functional    | Image research |
| GAP-08     | M        | Secrets visible in inspect   | Pattern change |
| GAP-09     | S        | MySQL isolated from backups  | Consolidation  |
| GAP-10     | L        | Permanent data loss on fault | New workflow   |
| GAP-11     | S        | HAProxy invisible            | New exporter   |
| GAP-12     | XS       | Silent scrape errors         | Documentation  |

---

## 4. Prioritized Remediation Plan

### Sprint 1 -- Immediate (< 1 hour, high impact)

1. **GAP-01:** Add `networks: - prometheus-net` to `cadvisor` in `grafana-prom/compose.yaml`.
   Restart the stack. Verify container panels populate in Grafana.

2. **GAP-02:** Add `ce-internal` network to `mcp-gateway` in `agents_gateway_data/compose.yaml`.
   Verify `docker exec mcp-gateway nslookup ollama` resolves.

3. **GAP-03:** Change `watchtower.enable=true` to `watchtower.enable=false` on `mariadb`,
   `postgres`, and code-server's `mysql`. These require manual, documented upgrade procedures.

### Sprint 2 -- This Week

4. **GAP-05:** Tune `mem_limit` on Ollama (16g -> 14g), add `mem_reservation`, add limits to
   `warp` containers and `watchtower`. Monitor via Grafana memory panel.

5. **GAP-06:** Remove the host port binding `10.0.1.15:11434:11434` from Ollama. Confirm
   Open-WebUI still connects via internal DNS. Update Cloudflare tunnel rules if any external
   inference is needed (add API key auth first).

6. **GAP-12:** Document the `misfitsds` (10.0.1.24) device. Add a `TargetDown` alert rule
   for SNMP targets (prerequisite for GAP-04's alerting sprint).

### Sprint 3 -- This Month

7. **GAP-04:** Deploy Alertmanager with Discord webhook. Write alert rules file covering
   memory, disk, service down, and certificate expiry.

8. **GAP-09:** Migrate code-server to use central MariaDB on `ce-internal`. Remove the
   isolated MySQL container. Consolidate secrets into the `databases` stack secrets directory.

9. **GAP-11:** Add `haproxy-exporter` sidecar and wire into Prometheus. Create a HAProxy
   Grafana dashboard (or import dashboard ID 12693).

### Backlog

10. **GAP-07:** Investigate correct Warp server image for NAS deployment. Until resolved,
    consider the warp-main stack non-functional and exclude it from monitoring expectations.

11. **GAP-08:** Migrate secrets to Docker file-based pattern across all stacks. This is a
    cross-stack refactor requiring coordinated `.env` + compose changes.

12. **GAP-10:** Implement Hyper Backup job covering all stateful volumes. Set up pre-backup
    DB dump hooks. Verify restore procedure quarterly.

---

## 5. Architecture Invariants to Preserve

These patterns are working correctly and should not be changed:

- `ce-internal` as the cross-stack backbone -- correct pattern, keep extending it
- Prometheus -> `prometheus-net` (private) + `ce-internal` (scrape targets) -- correct dual-network design
- Grafana -> `grafana-net` (isolated from scraping network) -- correct
- `databases` stack using Docker file secrets -- the gold standard for this repo; extend to all stacks
- `acme-sh` in `network_mode: host` -- required for Synology SNMP access and cert distribution
- All ports bound to `10.0.1.15:HOST:CONTAINER` (never `0.0.0.0`) -- correct, preserve this
- All services with `json-file` logging + `max-size`/`max-file` -- correct, all stacks have this
- `watchtower.enable=false` on Ollama (correct -- model state must survive updates)
- Prometheus 60-day retention -- appropriate for a NAS-scale deployment

---

*Review conducted 2026-05-14. Re-run `bash scripts/verify-repo-layout.sh` and
`bash scripts/compose-validate.sh` after applying each sprint.*
