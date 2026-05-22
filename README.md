# ce-stacks

Production Docker stack infrastructure for a Synology DS723+ NAS running DSM 7.3. All stacks are managed via [Dockhand](https://dockhand.pro/) and deployed under the canonical root `/volume2/docker/ce-stacks`.

## Architecture Overview

- **NAS**: Synology DS723+ . DSM 7.3 . Docker Engine via Container Manager
- **Stack root**: `/volume2/docker/ce-stacks`
- **Dockhand data**: `/volume2/docker/dockhand` (outside stack root, persists across repo resets)
- **Network model**: All service ports bind to `10.0.1.15` (LAN IP) -- no `0.0.0.0` bindings
- **Compose format**: `compose.yaml` throughout (no `docker-compose.yml`)

## Host Profile

Live target NAS: **`otsorundscore`** (DSM 7.3.2-86009 U3, DS723+, AMD Ryzen R1600, 32 GB, Cool mode, CPU-only). Authoritative spec:

- [`docs/host-profile-otsorundscore.md`](./docs/host-profile-otsorundscore.md) -- identity, hardware, derived budgets
- [`docs/dsm-732-runtime-quirks.md`](./docs/dsm-732-runtime-quirks.md) -- Container Manager / BTRFS / Cool-mode operational quirks

Two linters enforce host-profile rules in CI (chained from `scripts/compose-validate.sh` and `scripts/verify-repo-layout.sh`):

| Linter | Rule | Override |
|---|---|---|
| `scripts/lint-rfc1918.sh` | Every bridge `subnet:` must live inside `10/8`, `172.16/12`, or `192.168/16`. | -- |
| `scripts/lint-host-budget.sh` | Sum `mem_limit` across all stacks <= `HOST_MEM_BUDGET_MB` (default 32 000 MB = physical RAM ceiling). | `HOST_MEM_BUDGET_MB=26000 bash scripts/lint-host-budget.sh` for stricter "leave headroom for DSM" mode. |

## Directory Layout

```
ce-stacks/
+--- stacks/                  # One subdirectory per stack
|   +--- _dns-server/         # DNS zone files + BIND config (DSM native package, not compose)
|   +--- _haproxy/            # HAProxy reverse proxy (bare-metal, not compose)
|   +--- acme-sh/             # Let's Encrypt certificate automation
|   +--- code-server/         # VS Code in the browser
|   +--- codex-docs/          # Documentation platform
|   +--- dozzle/              # Docker log viewer
|   +--- flowise/             # LLM workflow builder (FlowiseAI)
|   +--- github-desktop/      # GitHub Desktop (containerised)
|   +--- grafana-prom/        # Grafana + Prometheus monitoring
|   +--- homepage/            # Dashboard / service portal
|   +--- influxdb/            # Time-series DB (ntopng metrics → Grafana)
|   +--- it-tools/            # IT utility toolkit
|   +--- n8n/                 # Workflow automation (n8n)
|   +--- ollama/              # Local LLM inference (Ollama, CPU-only)
|   +--- openresume/          # Resume builder
|   +--- otspsu/              # PSU OTS application
|   +--- remotely/            # Remote desktop / support
|   +--- searxng/             # Privacy-respecting metasearch
|   +--- synology-api-bridge/ # Internal DSM HTTP shim (FastAPI)
|   +--- watchtower/          # Automated image update management
|   +--- zabbix/              # Infrastructure monitoring
|   +--- archives/            # Retired stacks (kept for reference)
|
|   Native DSM packages (no compose stack needed):
|     Adminer, MariaDB, PostgreSQL — managed via Synology Package Center
|
+--- scripts/                 # Operational scripts
|   +--- dockhand-sync.sh     # Re-sync dockhand/ -> /volume2/docker/dockhand
|   +--- compose-validate.sh  # Validate all compose.yaml files
|   +--- verify-repo-layout.sh # Check repo structure invariants
|   +--- init-nas.sh          # First-boot NAS initialisation
|   +--- nas-reset.sh         # Factory-reset helper
|   +--- fix-permissions.sh   # Repair bind-mount ownership
|   +--- restore-env.sh       # Restore .env from .env.example
|   +--- maintenance/         # Scheduled maintenance scripts
|
+--- docs/                    # (planned) Architecture and runbook docs
```

## Getting Started

### 1. Clone the repo onto the NAS

```bash
cd /volume2/docker
git clone https://github.com/ofayese/ce-stacks.git
```

### 2. Install Dockhand via RC script


### 0. Pre-Deployment Setup (One-Time)

Before deploying stacks for the first time, perform these one-time setup steps on the NAS:

1. Create the backbone network (required by several stacks):

```bash
docker network create \
  --driver bridge \
  --subnet 172.26.0.0/24 \
  --gateway 172.26.0.1 \
  ce-internal
```

Verify: `docker network inspect ce-internal`

2. Populate all `.env` files from `.env.example` (templates are intentionally provided but `.env` files are git-ignored):

```bash
# Create missing .env files from .env.example
find stacks/ -name .env.example -exec sh -c 'cp "$1" "${1%.example}"' _ {} \;
```

Edit each `.env` with actual values (passwords, API keys) -- do not commit `.env` files to git.

3. Validate all compose files prior to import:

```bash
bash /volume2/docker/ce-stacks/scripts/compose-validate.sh
```

(Then continue with Dockhand installation steps below.)

```bash
sudo cp /volume2/docker/ce-stacks/dockhand/scripts/dockhand-start.sh /usr/local/etc/rc.d/dockhand.sh
sudo chmod +x /usr/local/etc/rc.d/dockhand.sh
sudo /usr/local/etc/rc.d/dockhand.sh
```

Dockhand will be available at `http://10.0.1.15:3866` after health check passes (60s).

**First-time setup**: See [`dockhand/README.md`](./dockhand/README.md) for UI initialization and git webhook configuration.

**DSM boot persistence**: DSM 7.3 does **not** auto-execute `/usr/local/etc/rc.d/*.sh` on reboot. To make Dockhand start automatically, follow [`dockhand/docs/DSM_BOOT_PERSISTENCE.md`](./dockhand/docs/DSM_BOOT_PERSISTENCE.md) to create a DSM Task Scheduler "Boot-up" task.

### 3. Initialize Dockhand

Access the web UI at `http://10.0.1.15:3866` and:

1. Create admin user (Settings > Authentication > Users)
2. Add Docker environment (Settings > Environments > +Add: "DS723", Unix socket)
3. Register git webhook (Settings > Webhooks) for auto-sync on repo push

See [`dockhand/README.md`](./dockhand/README.md) for detailed steps.

### 4. Import Stacks

Dockhand auto-imports stacks from your ce-stacks repo via:

- **Git webhook**: Push to repo -> Dockhand auto-deploys (recommended)
- **Manual upload**: Dockhand UI -> Stacks -> Create Stack -> Upload compose.yaml

For each stack, populate `.env` from `.env.example` before deployment.

### 5. Validate after changes

```bash
bash /volume2/docker/ce-stacks/scripts/compose-validate.sh
bash /volume2/docker/ce-stacks/scripts/verify-repo-layout.sh
```

## Key Conventions

| Convention | Detail |
|---|---|
| Compose filename | Always `compose.yaml` (never `docker-compose.yml`) |
| Port bindings | `10.0.1.15:HOST_PORT:CONTAINER_PORT` -- LAN-only |
| UID/GID | Default `PUID=0 / PGID=0` for Synology bind-mount ownership |
| Database images | Version-pinned; `watchtower.enable=false` label to prevent auto-upgrade |
| Floating tags | Prohibited for stateful services; pinned semver required |
| Secrets | Never in `compose.yaml`; always via `.env` (excluded from git) |
| Log rotation | `json-file`, `max-size=10m`, `max-file=3` on all services |

## Network Subnets

All bridge networks use explicit `/24` subnets to prevent Docker's auto-assigned `/16` ranges from creating collisions. The DNS server ACL covers `172.16.0.0/12` to allow all Docker bridge subnets to resolve internal hostnames.

| Stack | Network name | Subnet | Notes |
|---|---|---|---|
| *(backbone)* | ce-internal | 172.26.0.0/24 | External; created by `init-nas.sh` |
| github-desktop | github-desktop-net | 172.20.0.0/24 | KasmVNC browser container |
| ollama | ollama-net | 172.27.0.0/24 | CPU-only inference |
| code-server | code-server-net | 172.28.2.0/24 | |
| grafana-prom | grafana-net | 172.29.0.0/24 | |
| grafana-prom | prometheus-net | 172.29.1.0/24 | |
| zabbix | zabbix-net | 172.30.0.0/24 | |
| flowise | flowise-net | 172.30.1.0/24 | LLM workflow builder |
| n8n | n8n-net | 172.30.2.0/24 | Workflow automation |
| homepage | homepage-net | 172.30.5.0/24 | Dashboard |
| dozzle | dozzle-net | 172.31.0.0/24 | |
| watchtower | watchtower-net | 172.31.1.0/24 | |
| otspsu | otspsu-net | 172.31.10.0/24 | |
| *(influxdb)* | ce-internal | 172.26.0.0/24 | Shares backbone; Grafana reaches influxdb:8086 |

The Docker default bridge `172.17.0.0/16` is reserved and must not be re-used.

**Retired stacks**: `databases`, `db-tools`, `agents_gateway_data`, and `mcp-tools-config` have been removed. MariaDB, PostgreSQL, and Adminer run as native DSM packages. Subnets `172.31.7.0/24` and `172.31.8.0/24` are now unallocated and available for new stacks.

## External vs Internal Networks

**Important**: `ce-internal` is the only external (pre-created) network and must be created manually before importing stacks.

- `ce-internal` (172.26.0.0/24) -- External backbone network shared by: grafana-prom, influxdb, ollama, synology-api-bridge. Create it once on the NAS using `docker network create` (see Pre-Deployment Setup).

- All other networks listed above are created by their respective stacks at `docker compose up` time (internal to the stack) and do not require manual creation.

Refer to the "Pre-Deployment Setup" section for commands and validation steps.

## Dockhand Details

Dockhand lifecycle is managed exclusively by the RC script -- not by a compose stack.

- **Script**: `dockhand/scripts/dockhand-start.sh` -> installed at `/usr/local/etc/rc.d/dockhand.sh`
- **Image**: `fnsys/dockhand:latest` (git-backed Compose orchestration)
- **Port**: `10.0.1.15:3866` (HTTP WebUI)
- **Data**: `/volume2/docker/dockhand` (outside this repo)
- **Features**: Git webhooks, Compose visual editor, multi-environment support

## Synology DSM Notes

- **Docker binary**: `/usr/local/bin/docker`
- **Docker root**: `/volume2/@docker`
- **Stack root**: `/volume2/docker/ce-stacks`
- **User home**: `/volume1/homes/laolufayese` (remains on volume1)
- **HAProxy**: installed at `/usr/local/etc/haproxy/` via `@appstore/haproxy` (volume1)
- Reverse proxy timeouts: set to 600s in DSM -> Application Portal to avoid WebSocket drops
- Stacks using HTTPS backends: configure DSM proxy as HTTPS->HTTPS to avoid 400 Bad Request

## Security Notes

- All `.env` files are excluded from git (see `.gitignore`)
- The `stacks/acme-sh/data/`, `stacks/ollama/data/`, and `stacks/github-desktop/config/ssl/` directories are gitignored - they contain runtime certificates, private keys, and SSH identity material
- Database Watchtower exemptions prevent accidental major-version upgrades that would corrupt data directories

## Architecture & Design

- [`docs/host-profile-otsorundscore.md`](./docs/host-profile-otsorundscore.md) -- NAS hardware spec, memory budget, and derived resource ceilings.
- [`stacks/_dns-server/RUNBOOK.md`](./stacks/_dns-server/RUNBOOK.md) -- DNS split-horizon setup, BIND view structure, and validation steps.
- [`stacks/_haproxy/README.md`](./stacks/_haproxy/README.md) -- HAProxy reverse proxy configuration, cert deployment, and DNS integration.
- [`docs/archive/`](./docs/archive/) -- superseded plans and audit reports (historical reference only).

## License

Private infrastructure repository. All rights reserved.
