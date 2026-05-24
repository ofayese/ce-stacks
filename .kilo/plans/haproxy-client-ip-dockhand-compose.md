# Plan: HAProxy X-Forwarded-For + Client IP Preservation + Dockhand Compose Fix + Observability Expansion

## Context

- **NAS**: DS723+, DSM 7.3.2, 10.0.1.15, AMD Ryzen R1600, 32 GB, aarch64
- HAProxy: 8280 (HTTPS frontend) / 8281 (stats)
- Cloudflare Tunnel (not yet deployed) will eventually terminate at 8280 — client IP must survive that hop
- Native DSM packages confirmed on NAS: **Ruby 3.0.2** (aarch64), **Redis**, **MariaDB 10.11** (`max_allowed_packet=128M` ✓)
- Zabbix 7.4.10 fully seeded and running; `zabbix-agent2` container already in compose

---

## Port Audit — All Stacks

| Stack | Host Port | Container Port | HAProxy Port | HAProxy Backend Server | Status |
|---|---|---|---|---|---|
| code-server | 8377 | **8443** | 8377 | `10.0.1.15:8377` | ⚠️ See note 1 |
| code-server (MySQL) | 3307 | 3306 | — | — | ✅ Intentional (avoids NAS MariaDB:3306) |
| code-server (pma) | 8379 | 80 | 8379 | `10.0.1.15:8379` | ✅ |
| codex-docs | 8896 | 3000 | 8896 | `10.0.1.15:8896` | ✅ |
| dozzle | 8892 | 8080 | 8892 | `10.0.1.15:8892` | ✅ |
| flowise | 8459 | 3000 | 8459 | `10.0.1.15:8459` | ✅ |
| github-desktop | 3405 | **3001** | 3405 | `10.0.1.15:3405` | ✅ Intentional (app listens on 3001) |
| grafana | 3340 | 3000 | 3340 | `10.0.1.15:3340` | ✅ |
| prometheus | 9090 | 9090 | — | — | ✅ No HAProxy (direct) |
| alertmanager | 9093 | 9093 | — | — | ✅ No HAProxy (direct) |
| homepage | 7575 | 3000 | 7575 | `10.0.1.15:7575` | ✅ |
| influxdb | 8086 | 8086 | — | — | ✅ No HAProxy (direct) |
| it-tools | 8894 | 80 | 8894 | `10.0.1.15:8894` | ✅ |
| n8n | 5678 | 5678 | 5678 | `10.0.1.15:5678` | ✅ |
| ollama | 11434 | 11434 | — | — | ✅ No HAProxy (direct) |
| open-webui | 8893 | 8080 | 8893 | `10.0.1.15:8893` | ✅ |
| pipelines | 9099 | 9099 | — | — | ✅ No HAProxy (direct) |
| openresume | 8889 | 3000 | 8889 | `10.0.1.15:8889` | ✅ |
| otspsu | 5570 | 5000 | 5570 | `10.0.1.15:5570` | ✅ |
| remotely | 5371 | 5000 | 5371 | `10.0.1.15:5371` | ✅ |
| searxng | 8888 | 8080 | 8888 | `10.0.1.15:8888` | ✅ |
| synology-api-bridge | 8780 | 8000 | — | — | ✅ No HAProxy label |
| watchtower | 18787 | 8080 | — | — | ✅ No HAProxy label |
| zabbix-server | 10051 | 10051 | — | — | ✅ No HAProxy (direct) |
| zabbix-web | 8532 | 8080 | 8532 | `10.0.1.15:8532` | ✅ |
| dockhand (bare-metal) | 3866 | n/a | — | `10.0.1.15:3866` | ⚠️ See note 2 |

### Port Audit Notes

**Note 1 — code-server:8377→8443 (HTTP/HTTPS mismatch):**
Container port 8443 indicates HTTPS mode. HAProxy backend `codeserver-be` hits `10.0.1.15:8377` in plain HTTP (no `ssl verify none` on the server line). Two options:
- Add `ssl verify none` to the `codeserver-be` server line in `haproxy.cfg`, OR
- Configure code-server to serve HTTP instead of HTTPS (safe since HAProxy handles TLS termination externally)
Confirm which is in use before touching — if it's working today, code-server may already be in HTTP mode on that port.

**Note 2 — Dockhand has no `stacks/dockhand/` directory:**
Dockhand runs as a bare-metal RC script on the NAS at port 3866 (per `haproxy.cfg` static comment). Plan A1 creates a new `stacks/dockhand/compose.yaml` to containerize it. After containerization:
- Port changes from `3866` → `10.0.1.15:3000:3000` (NOT `127.0.0.1` — see below)
- `stacks/otspsu/compose.yaml` has `STACK_MANAGER_URL=http://10.0.1.15:3866` — **must be updated to `http://10.0.1.15:3000`** or otspsu loses stack management
- HAProxy `dockhand-be` backend must change from `10.0.1.15:3866` → `10.0.1.15:3000`

**Note 3 — github-desktop:3405→3001:**
Container port 3001 is intentional — the github-desktop image listens on 3001 not 3000. HAProxy backend correctly hits `10.0.1.15:3405` → host forwards to container:3001. No issue.

---

## Part A — HAProxy + Dockhand

### A1 — Create `stacks/dockhand/compose.yaml` (containerize dockhand)

**Why:** Dockhand currently runs as a bare-metal RC script at port 3866. Containerizing it pins the version, adds restart policy, and aligns with the rest of the stack pattern.

**New file `stacks/dockhand/compose.yaml`:**

```yaml
name: dockhand

services:
  dockhand:
    container_name: Dockhand
    image: fnsys/dockhand:v1.0.29
    mem_limit: 256m
    cpu_shares: 256
    security_opt:
      - no-new-privileges:true
    restart: unless-stopped
    user: "0:0"
    ports:
      - "10.0.1.15:3000:3000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /volume2/docker/dockhand:/app/data
    environment:
      - DATA_DIR=/app/data
      - SKIP_DF_COLLECTION=true
      - DOCKER_API_VERSION=1.43
    labels:
      - com.centurylinklabs.watchtower.enable=false
      - haproxy.enable=true
      - haproxy.host=dockhand.olutechsys.com
      - haproxy.port=3000
      - haproxy.backend=dockhand-be
```

**Downstream changes required:**
1. `stacks/_haproxy/haproxy.cfg` `dockhand-be`: change `server dockhand 10.0.1.15:3866` → `10.0.1.15:3000`
2. `stacks/otspsu/compose.yaml`: change `STACK_MANAGER_URL` default from `3866` → `3000`
3. Before starting: stop the bare-metal dockhand RC script on the NAS to free port 3866

**Verify Docker API version on NAS before deploying:**
```bash
docker version --format '{{.Server.APIVersion}}'
```
If not `1.43`, update `DOCKER_API_VERSION` to match.

---

### A2 — Add `X-Forwarded-For` header (`https-in` frontend)

**Status:** Not yet applied. Add after existing `X-Real-IP` line in `https-in`:
```haproxy
http-request add-header X-Forwarded-For %[src]
```

---

### A3 — Trust CF Tunnel for `X-Real-IP`

**Status:** Not yet applied.

```haproxy
acl is_cf_tunnel src 172.16.0.0/12
http-request set-header X-Real-IP %[req.hdr(X-Forwarded-For),field(1)] if is_cf_tunnel
```

⚠️ **Known limitation:** `172.16.0.0/12` covers all Docker bridge networks. When CF Tunnel is deployed, narrow this ACL to the actual tunnel source IP/subnet to prevent internal container traffic being misidentified as tunnel traffic.

---

### A4 — No changes to `ollama/compose.yaml`

No action.

---

## Part B — Zabbix ✅ COMPLETE

| Item | Status |
|---|---|
| B1 — SNMPv3 template import + host link | ✅ Done |
| B2 — HyperBackup template import + macros | ✅ Done |
| B3 — `zabbixagt2` host object created | ✅ Done |
| B4 — WebSocket headers in `zabbix-be` | ✅ Done (applied to haproxy.cfg, deployed to NAS) |

---

## Part C — Loki + Alloy Log Pipeline

### C5 — Add `stacks/loki-alloy/` stack

**Subnet:** `172.31.7.0/24` (`loki-net`) — dozzle owns `172.31.0.0/24` (missed in earlier audit). Full 172.31.x map: 0=dozzle, 1=watchtower, 2=it-tools, 3=openresume, 4=searxng, 5=remotely, 6=codex-docs, 7=loki-alloy ✓, 10=otspsu.

**New file: `stacks/loki-alloy/compose.yaml`**

```yaml
name: loki-alloy

services:
  loki:
    image: grafana/loki:3.7.0
    container_name: Loki
    hostname: loki
    restart: unless-stopped
    mem_limit: 512m
    cpu_shares: 512
    security_opt:
      - no-new-privileges:true
    networks:
      - loki-net
      - ce-internal
    ports:
      - "10.0.1.15:3100:3100"
    volumes:
      - ${STACK_ROOT}/loki-alloy/config/loki:/mnt/config:ro
      - ${STACK_ROOT}/loki-alloy/data/loki:/loki:rw
    command: -config.file=/mnt/config/loki-config.yaml
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:3100/ready || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"
    labels:
      - com.centurylinklabs.watchtower.enable=false
      - haproxy.enable=false

  alloy:
    image: grafana/alloy:v1.8.3
    container_name: Alloy
    hostname: alloy
    restart: unless-stopped
    mem_limit: 256m
    cpu_shares: 256
    security_opt:
      - no-new-privileges:true
    user: "0:0"
    networks:
      - loki-net
    ports:
      - "10.0.1.15:12345:12345"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${STACK_ROOT}/loki-alloy/config/alloy:/etc/alloy:ro
    command:
      - run
      - /etc/alloy/config.alloy
      - --server.http.listen-addr=0.0.0.0:12345
    depends_on:
      loki:
        condition: service_healthy
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"
    labels:
      - com.centurylinklabs.watchtower.enable=false

networks:
  loki-net:
    name: loki-net
    driver: bridge
    ipam:
      config:
        - subnet: 172.31.0.0/24
          gateway: 172.31.0.1
  ce-internal:
    external: true
```

**`stacks/loki-alloy/config/loki/loki-config.yaml`:**
```yaml
auth_enabled: false
server:
  http_listen_port: 3100
common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
limits_config:
  retention_period: 30d
```

**`stacks/loki-alloy/config/alloy/config.alloy`:**
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

---

### C6 — Wire Prometheus datasource in Grafana (provisioning file)

**New file: `stacks/grafana-prom/provisioning/datasources/prometheus.yaml`:**
```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus-server:9090
    isDefault: true
    access: proxy
  - name: Loki
    type: loki
    url: http://loki:3100
    access: proxy
```

Note: Prometheus container hostname is `prometheus-server` (set via `hostname:` in compose), not `prometheus`. URL must use the hostname, not the service name, since they're on `ce-internal`.

**Edit `stacks/grafana-prom/compose.yaml`** — add provisioning mount to Grafana service volumes:
```yaml
- ${STACK_ROOT}/grafana-prom/provisioning:/etc/grafana/provisioning:ro
```
This replaces/extends the existing `provisioning` mount already defined at line 40.

---

## Part D — Pyroscope Continuous Profiling

### D7 — Add `stacks/pyroscope/` stack

**Subnet:** `172.28.0.0/24` (`pyroscope-net`) — within `172.16.0.0/12` DNS ACL ✓

**New file: `stacks/pyroscope/compose.yaml`:**
```yaml
name: pyroscope

services:
  pyroscope:
    image: grafana/pyroscope:1.13.0
    container_name: Pyroscope
    hostname: pyroscope
    restart: unless-stopped
    mem_limit: 512m
    cpu_shares: 512
    security_opt:
      - no-new-privileges:true
    networks:
      - pyroscope-net
      - ce-internal
    ports:
      - "10.0.1.15:4040:4040"
    volumes:
      - ${STACK_ROOT}/pyroscope/data:/data:rw
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:4040/ready || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"
    labels:
      - com.centurylinklabs.watchtower.enable=false
      - haproxy.enable=true
      - haproxy.host=pyroscope.olutechsys.com
      - haproxy.port=4040
      - haproxy.backend=pyroscope-be

networks:
  pyroscope-net:
    name: pyroscope-net
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/24
          gateway: 172.28.0.1
  ce-internal:
    external: true
```

**SDK integrations:**

| Stack | SDK | Integration method |
|---|---|---|
| `n8n` | `@pyroscope/nodejs` | Custom Docker entrypoint wrapper (NOT `N8N_CUSTOM_EXTENSIONS`) — see below |
| `flowise` | `@pyroscope/nodejs` | Same entrypoint wrapper approach |
| Ruby (NAS native) | `pyroscope` gem | `gem install pyroscope` then configure in app startup |

**n8n/flowise Pyroscope injection — correct approach:**
`N8N_CUSTOM_EXTENSIONS` loads custom nodes, not startup hooks. Use a custom entrypoint:
```dockerfile
# Dockerfile.n8n-pyroscope
FROM n8nio/n8n:latest
RUN npm install -g @pyroscope/nodejs
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```
```bash
# entrypoint.sh
node -e "require('@pyroscope/nodejs').init({ serverAddress: 'http://10.0.1.15:4040', appName: 'n8n' })"
exec /docker-entrypoint.sh "$@"
```
This is deferred — deploy Pyroscope server first, add SDK integration later.

---

## Part E — PyTorch / JupyterLab

### E8 — Add `stacks/pytorch/` stack

**Subnet:** `172.28.1.0/24` (`pytorch-net`) — within `172.16.0.0/12` DNS ACL ✓
**Port:** `8897` (8888 is taken by searxng)

**Architecture (aarch64):**
Official `pytorch/pytorch` images are x86_64 only. Use `arm64v8/python:3.11-slim` + pip install, or check `ghcr.io/pytorch/pytorch` for ARM builds at deploy time.

**New file: `stacks/pytorch/compose.yaml`:**
```yaml
name: pytorch

services:
  jupyter:
    image: arm64v8/python:3.11-slim
    container_name: PyTorch-Jupyter
    hostname: pytorch-jupyter
    restart: unless-stopped
    mem_limit: 4g
    cpu_shares: 1024
    security_opt:
      - no-new-privileges:true
    networks:
      - pytorch-net
    ports:
      - "10.0.1.15:8897:8888"
    volumes:
      - ${STACK_ROOT}/pytorch/notebooks:/notebooks:rw
      - ${STACK_ROOT}/pytorch/cache:/root/.cache:rw
    environment:
      - JUPYTER_TOKEN=${JUPYTER_TOKEN}
    command: >
      bash -c "pip install torch torchvision torchaudio
      --index-url https://download.pytorch.org/whl/cpu
      jupyter lab &&
      jupyter lab --ip=0.0.0.0 --port=8888 --no-browser
      --notebook-dir=/notebooks
      --ServerApp.token=$${JUPYTER_TOKEN}"
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8888/api || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 120s
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"
    labels:
      - com.centurylinklabs.watchtower.enable=false
      - haproxy.enable=true
      - haproxy.host=pytorch.olutechsys.com
      - haproxy.port=8897
      - haproxy.backend=pytorch-be

networks:
  pytorch-net:
    name: pytorch-net
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.1.0/24
          gateway: 172.28.1.1
```

**`stacks/pytorch/.env.example`:**
```dotenv
STACK_ROOT=/volume2/docker/ce-stacks/stacks
JUPYTER_TOKEN=<set-a-strong-token>
```

⚠️ `JUPYTER_TOKEN` must be set — JupyterLab is exposed via HAProxy with no other auth layer.

---

## Files to create/modify

| File | Action | Part |
|---|---|---|
| `stacks/dockhand/compose.yaml` | **Create** (new containerized dockhand) | A1 |
| `stacks/_haproxy/haproxy.cfg` | Edit: XFF header, CF ACL, dockhand port 3866→3000 | A2, A3 |
| `stacks/otspsu/compose.yaml` | Edit: `STACK_MANAGER_URL` default 3866→3000 | A1 dep |
| `stacks/loki-alloy/compose.yaml` | Create new stack | C5 |
| `stacks/loki-alloy/.env.example` | Create | C5 |
| `stacks/loki-alloy/config/alloy/config.alloy` | Create | C5 |
| `stacks/loki-alloy/config/loki/loki-config.yaml` | Create | C5 |
| `stacks/grafana-prom/provisioning/datasources/prometheus.yaml` | Create (includes Loki datasource) | C6 |
| `stacks/grafana-prom/compose.yaml` | Edit: ensure provisioning mount present | C6 |
| `stacks/pyroscope/compose.yaml` | Create new stack | D7 |
| `stacks/pyroscope/.env.example` | Create | D7 |
| `stacks/pytorch/compose.yaml` | Create new stack | E8 |
| `stacks/pytorch/.env.example` | Create | E8 |
| `README.md` | Add loki-alloy, pyroscope, pytorch to layout + subnet table | All |
| `CLAUDE.md` | Append compound learnings | All |

---

## Execution order

```
A1 (create dockhand compose + stop bare-metal, update otspsu URL, update haproxy dockhand-be port)
A2 → A3  (HAProxy XFF + CF ACL — haproxy.cfg edit, validate, deploy)
C5       (Loki + Alloy stack)
C6       (Prometheus + Loki datasources in Grafana provisioning)
D7       (Pyroscope server — SDK integrations deferred)
E8       (PyTorch/Jupyter — standalone)
```

---

## Validation steps

```bash
# 1. HAProxy syntax (after any haproxy.cfg edit)
sudo /volume1/@appstore/haproxy/sbin/haproxy -c -f /var/packages/haproxy/var/haproxy.cfg

# 2. Dockhand health (after containerization)
curl -s http://10.0.1.15:3000/api/health

# 3. Loki ready
curl -s http://10.0.1.15:3100/ready

# 4. Alloy UI
open http://10.0.1.15:12345

# 5. Pyroscope ready
curl -s http://10.0.1.15:4040/ready

# 6. Jupyter reachable
curl -s http://10.0.1.15:8897/api
```

---

## Rollback

- HAProxy: `git checkout -- stacks/_haproxy/haproxy.cfg` then re-deploy
- Dockhand: `docker compose -f stacks/dockhand/compose.yaml down` → restart bare-metal RC script
- New stacks: `docker compose -f stacks/<name>/compose.yaml down && rm -rf stacks/<name>/`
- otspsu URL: `git checkout -- stacks/otspsu/compose.yaml`
