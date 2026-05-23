# Plan: HAProxy X-Forwarded-For + Client IP Preservation + Dockhand Compose Fix + Observability Expansion

## Context

- **NAS**: DS723+, DSM 7.3.2, 10.0.1.15, AMD Ryzen R1600, 32 GB, aarch64
- HAProxy: 8280 (HTTPS frontend) / 8281 (stats)
- Cloudflare Tunnel (not yet deployed) will eventually terminate at 8280 — client IP must survive that hop
- Dockhand runs as `fnsys/dockhand:latest` (currently `v1.0.29`) on port 3866 proxied via HAProxy
- Native DSM packages confirmed on NAS: **Ruby 3.0.2** (aarch64), **Redis**, **MariaDB 10.11** (`max_allowed_packet=128M` ✓)
- Zabbix 7.4.10 fully seeded and running; `zabbix-agent2` container already in compose

---

## Part A — HAProxy + Dockhand (original 4 actions)

### A1 — Fix `stacks/dockhand/compose.yaml` (dockhand container)

**Why:** Current compose uses a named volume (`dockhand_data`) and binds port 3866 directly. Per dockhand.pro/manual, named volumes conflict with `user:` directive and relative compose paths in stacks. `SKIP_DF_COLLECTION` prevents slow DSM `/system/df` calls. `DOCKER_API_VERSION` pins the API to avoid auto-negotiation breaking on Docker 24.x.

**Changes:**

| Field | Current | New |
|---|---|---|
| image | `fnsys/dockhand:latest` | `fnsys/dockhand:v1.0.29` |
| ports | `"3866:3000"` | `"127.0.0.1:3000:3000"` (localhost-only; HAProxy terminates TLS externally) |
| volumes | `dockhand_data:/app/data` (named vol) | `/volume2/docker/dockhand:/volume2/docker/dockhand` (matching bind mount) |
| new env | — | `SKIP_DF_COLLECTION=true`, `DOCKER_API_VERSION=1.43`, `DATA_DIR=/volume2/docker/dockhand` |
| user | absent | `"0:0"` (root; acceptable on home NAS, bypasses socket GID issues) |

Also update `haproxy.cfg` `dockhand-be` backend port from `3866` → `3000`.

---

### A2 — Add `X-Forwarded-For` header in `stacks/_haproxy/haproxy.cfg` (`https-in` frontend)

**Why:** Current config sets `X-Real-IP %[src]` but does not append to the `X-Forwarded-For` chain.

**Change** (after existing `X-Real-IP` line):
```haproxy
http-request add-header X-Forwarded-For %[src]
```

---

### A3 — Trust CF Tunnel private subnet for `X-Real-IP`

**Changes (haproxy.cfg `https-in` frontend):**
```haproxy
acl is_cf_tunnel src 172.16.0.0/12
http-request set-header X-Real-IP %[req.hdr(X-Forwarded-For),field(1)] if is_cf_tunnel
```

---

### A4 — No changes to `ollama/compose.yaml`

Current stack content is already better than the fork. No action.

---

## Part B — Zabbix Template Imports (operator steps only, no compose changes)

### B1 — Import `template_synology_diskstation_snmpv3`

**Why:** SNMPv3-based hardware health for the DS723+: disks, fans, PSU, temperature, RAID, firmware, volume health. High value, low effort.

**Pre-requisite — Enable SNMPv3 on DSM:**
1. DSM Control Panel → Terminal & SNMP → SNMP tab
2. Enable SNMPv3, create user (e.g. `zabbixsnmp`), set auth SHA + priv AES
3. Note the credentials for Zabbix macros

**Import steps:**
1. Download: `https://github.com/zabbix/community-templates/raw/main/Storage_Devices/Synology/template_synology_diskstation_snmpv3/6.0/template_synology_diskstation_snmpv3.yaml`
2. Zabbix UI → Data collection → Templates → Import → upload YAML
3. Hosts → `10.0.1.15` → Templates tab → link `Template Synology DiskStation SNMPv3`
4. Hosts → `10.0.1.15` → Macros tab → add:
   - `{$SNMP.COMMUNITY}` → your SNMPv3 auth string
   - `{$SNMP_USER}` → `zabbixsnmp`

---

### B2 — Import `template_synology_hyperbackup`

**Why:** Monitors DSM HyperBackup task status via REST API. Gives alert triggers for failed/missed backup jobs.

**Import steps:**
1. Download: `https://raw.githubusercontent.com/lestoilfante/zabbix-integrations/main/Synology/hyper-backup/template_synology_hyperbackup.yaml`
2. Zabbix UI → Templates → Import
3. Link to host `10.0.1.15`, set host-level macros:
   - `{$SYNO.REST.USER}` → DSM admin username
   - `{$SYNO.REST.PASSWORD}` → DSM admin password
4. LLD discovery rule fires automatically — extend triggers per backup task as needed

---

### B3 — Register Zabbix Agent host object (`zabbixagt2`)

**Why:** `zabbix-agent2` container is already in `stacks/zabbix/compose.yaml` with `ZBX_HOSTNAME=zabbixagt2`. The Zabbix frontend Host object must be created to match — without it the agent connects but no checks run.

**Steps in Zabbix UI:**
1. Data collection → Hosts → Create host
2. **Host name:** `zabbixagt2` (must match `ZBX_HOSTNAME` exactly)
3. **Templates:** `Linux by Zabbix agent 2`
4. **Interfaces:** Agent → DNS: `zabbix-agent` (container name), port `10050`
5. Save — agent checks begin within 30 s

---

### B4 — Add WebSocket headers to HAProxy `zabbix-be` backend

**Why:** Zabbix UI uses WebSocket for real-time event streaming. Without `Connection: Upgrade` and `Upgrade: websocket` passthrough in HAProxy, the frontend breaks on live dashboards.

**Change to `stacks/_haproxy/haproxy.cfg` `zabbix-be` backend:**
```haproxy
backend zabbix-be
    # zabbix/zabbix-web — auto-generated from haproxy.* labels
    timeout tunnel 3600s
    http-request set-header Connection %[req.hdr(Connection)]
    http-request set-header Upgrade %[req.hdr(Upgrade)]
    server zabbix 10.0.1.15:8532 check
```

---

## Part C — Loki + Alloy Log Pipeline (new stack)

### C5 — Add `stacks/loki-alloy/` stack

**Why:** All Docker container logs currently go to stdout only (dozzle gives live view, no retention). Loki+Alloy adds structured storage, retention policy, and Grafana LogQL query across historical logs.

**New file: `stacks/loki-alloy/compose.yaml`**

Key design decisions:
- Loki `3.7.0` in single-binary mode (monolithic), port `3100`
- Alloy `latest` as unified collector: tails Docker socket logs + Zabbix app logs, pushes to Loki
- Both on a new bridge network `loki-net` (`172.31.0.0/24`) — add to DNS ACL if not already covered by `172.16.0.0/12` ✓ (172.31 is within /12)
- Loki data dir: `${STACK_ROOT}/loki-alloy/data/loki`
- Alloy config dir: `${STACK_ROOT}/loki-alloy/config/alloy`

**Minimum Alloy `.alloy` config (Docker log scrape):**
```alloy
logging {
  level  = "info"
  format = "logfmt"
}

discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

loki.source.docker "docker_logs" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.docker.containers.targets
  forward_to = [loki.write.default.receiver]
}

loki.write "default" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
```

**HAProxy label** (add to loki service for Grafana Loki datasource access):
```yaml
labels:
  - haproxy.enable=false   # internal only; access via Grafana datasource
```

**Subnet allocation:** `172.31.0.0/24` (`loki-net`) — update README subnet table.

---

### C6 — Wire Prometheus datasource in Grafana

**Why:** `nodeexporter-be` already runs at `:9100` on `prometheus-net`. Grafana is running but no datasource is configured — dashboards show "No data."

**Two options:**

**Option A — Grafana UI (2 minutes):**
1. Grafana → Connections → Data sources → Add → Prometheus
2. URL: `http://prometheus:9090` (within `prometheus-net`) or `http://10.0.1.15:9090`
3. Save & test → green

**Option B — Provisioning file (idempotent, gittracked):**
```yaml
# stacks/grafana-prom/config/provisioning/datasources/prometheus.yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090
    isDefault: true
    access: proxy
```
Mount into Grafana container at `/etc/grafana/provisioning/datasources/`.

**Recommendation:** Option B — add provisioning file + mount in `grafana-prom/compose.yaml`.

---

## Part D — Pyroscope Continuous Profiling (new stack)

### D7 — Add `stacks/pyroscope/` stack + SDK integrations

**Why:** No visibility into CPU/memory hotspots for n8n (Node.js), flowise (Node.js), or any future Python services. Pyroscope gives flame-graph profiles in Grafana with the Pyroscope datasource.

**NAS context:** Ruby 3.0.2 is installed (aarch64). Redis is installed. Both can push profiles to Pyroscope.

**New file: `stacks/pyroscope/compose.yaml`**
- Image: `grafana/pyroscope:latest`
- Port: `4040`
- Data: `${STACK_ROOT}/pyroscope/data`
- Network: `pyroscope-net` (`172.32.0.0/24`) — note: 172.32 is **outside** `172.16.0.0/12` (covers up to 172.31.255.255)

⚠️ **Subnet warning:** `172.32.x.x` falls outside the DNS ACL `172.16.0.0/12`. Either:
- Use a subnet inside `172.16–172.31.x.x` (e.g. reuse or sub-allocate from existing range), OR
- Expand DNS ACL to `172.16.0.0/11`

**SDK integrations per stack (no compose changes needed — add to app config/env):**

| Stack | SDK | Env var / config |
|---|---|---|
| `n8n` | `@pyroscope/nodejs` | Add to n8n custom node code or via N8N_CUSTOM_EXTENSIONS |
| `flowise` | `@pyroscope/nodejs` | Flowise custom node / startup hook |
| Ruby (NAS native) | `pyroscope` gem | `gem install pyroscope`; `Pyroscope.configure { \|c\| c.server_address = "http://10.0.1.15:4040" }` |

**HAProxy label** for Pyroscope UI:
```yaml
labels:
  - haproxy.enable=true
  - haproxy.host=pyroscope.olutechsys.com
  - haproxy.port=4040
  - haproxy.backend=pyroscope-be
```

---

## Part E — PyTorch Stack (new stack)

### E8 — Add `stacks/pytorch/` stack

**Why:** User explicitly requested. Enables local ML model training/inference on the NAS.

**Architecture consideration (aarch64):**
- `pytorch/pytorch:latest` official images are x86_64 only
- For aarch64 Synology, use: `arm64v8/python:3.11-slim` base + `pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu`
- Alternatively: `ghcr.io/pytorch/pytorch` ARM builds (check availability at time of deploy)

**New file: `stacks/pytorch/compose.yaml`**

Suggested layout:
- Service: `pytorch-jupyter` — JupyterLab with PyTorch preinstalled
- Port: `8888` (Jupyter) behind HAProxy at `pytorch.olutechsys.com`
- Volume: `${STACK_ROOT}/pytorch/notebooks` for persistent notebooks
- Memory: `mem_limit: 4g` (generous for model inference on 32GB NAS)
- Network: new `pytorch-net` (pick subnet from available range)

**HAProxy label:**
```yaml
labels:
  - haproxy.enable=true
  - haproxy.host=pytorch.olutechsys.com
  - haproxy.port=8888
  - haproxy.backend=pytorch-be
```

---

## Files to create/modify

| File | Action | Part |
|---|---|---|
| `stacks/dockhand/compose.yaml` | Rewrite | A1 |
| `stacks/_haproxy/haproxy.cfg` | Edit: XFF header, CF ACL, zabbix WS headers, dockhand port | A2, A3, B4 |
| `stacks/loki-alloy/compose.yaml` | Create new stack | C5 |
| `stacks/loki-alloy/.env.example` | Create | C5 |
| `stacks/loki-alloy/config/alloy/config.alloy` | Create | C5 |
| `stacks/loki-alloy/config/loki/loki-config.yaml` | Create | C5 |
| `stacks/grafana-prom/config/provisioning/datasources/prometheus.yaml` | Create | C6 |
| `stacks/grafana-prom/compose.yaml` | Edit: mount provisioning dir | C6 |
| `stacks/pyroscope/compose.yaml` | Create new stack | D7 |
| `stacks/pyroscope/.env.example` | Create | D7 |
| `stacks/pytorch/compose.yaml` | Create new stack | E8 |
| `stacks/pytorch/.env.example` | Create | E8 |
| `README.md` | Add loki-alloy, pyroscope, pytorch to layout + subnet table | All |
| `CLAUDE.md` | Append compound learnings | All |

---

## Execution order

```
A1 → A2 → A3 → A4   (HAProxy/dockhand, self-contained)
B3                    (Zabbix host object — operator UI steps only, no code)
B1 → B2              (Zabbix template imports — operator UI steps only)
B4                    (HAProxy websocket headers — part of haproxy.cfg edit)
C5 → C6              (Loki+Alloy, then wire Prometheus datasource)
D7                    (Pyroscope — after C5/C6 so Grafana datasource can be added)
E8                    (PyTorch — standalone, no dependencies)
```

---

## Validation steps

1. **HAProxy syntax** (run on NAS after any haproxy.cfg edit):
   ```bash
   sudo /volume1/@appstore/haproxy/sbin/haproxy -c -f /var/packages/haproxy/var/haproxy.cfg
   ```
2. **Dockhand health:**
   ```bash
   curl -s http://127.0.0.1:3000/api/health | head
   ```
3. **Loki health:**
   ```bash
   curl -s http://10.0.1.15:3100/ready
   ```
4. **Alloy UI (log scrape status):**
   ```
   http://10.0.1.15:12345
   ```
5. **Pyroscope health:**
   ```bash
   curl -s http://10.0.1.15:4040/ready
   ```
6. **Zabbix agent check:**
   ```bash
   docker exec Zabbix-Agent zabbix_agent2 -t agent.ping
   ```

---

## Rollback

- HAProxy/dockhand: `git checkout -- stacks/dockhand/compose.yaml stacks/_haproxy/haproxy.cfg`
- New stacks: `docker compose -f stacks/<name>/compose.yaml down && rm -rf stacks/<name>/`
- Grafana provisioning: remove mount from grafana-prom compose + delete datasource file
