# ce-stacks

Production Docker stack infrastructure for a Synology DS723+ NAS running DSM 7.3. All stacks are managed via [Dockhand](https://dockhand.pro/) and deployed under the canonical root `/volume2/docker/ce-stacks`.

## Architecture Overview

- **NAS**: Synology DS723+ · DSM 7.3 · Docker Engine via Container Manager
- **Stack root**: `/volume2/docker/ce-stacks`
- **Dockhand data**: `/volume2/docker/dockhand` (outside stack root, persists across repo resets)
- **Network model**: All service ports bind to `10.0.1.15` (LAN IP) — no `0.0.0.0` bindings
- **Compose format**: `compose.yaml` throughout (no `docker-compose.yml`)

## Directory Layout

```
ce-stacks/
├── stacks/                  # One subdirectory per stack
│   ├── _haproxy/            # HAProxy reverse proxy (bare-metal, not compose)
│   ├── acme-sh/             # Let's Encrypt certificate automation
│   ├── agents_gateway_data/ # AI agent gateway + DuckDuckGo search
│   ├── code-server/         # VS Code in the browser
│   ├── codex-docs/          # Documentation platform
│   ├── databases/           # Shared database services
│   ├── dozzle/              # Docker log viewer
│   ├── github-desktop/      # GitHub Desktop (containerised)
│   ├── grafana-prom/        # Grafana + Prometheus monitoring
│   ├── homepage/            # Dashboard / service portal
│   ├── it-tools/            # IT utility toolkit
│   ├── mcp-tools-config/    # MCP tool configuration
│   ├── ollama/              # Local LLM inference (Ollama)
│   ├── openresume/          # Resume builder
│   ├── psu-ots/             # PSU OTS application
│   ├── remotely/            # Remote desktop / support
│   ├── searxng/             # Privacy-respecting metasearch
│   ├── synology-api-bridge/ # Internal DSM HTTP shim (FastAPI)
│   ├── warp-main/           # Cloudflare WARP proxy
│   ├── watchtower/          # Automated image update management
│   ├── zabbix/              # Infrastructure monitoring
│   └── archives/            # Retired stacks (kept for reference)
│
├── scripts/                 # Operational scripts
│   ├── portainer-start.sh   # Portainer CE RC startup script
│   ├── dockge-start.sh      # Dockge RC startup script (fallback UI)
│   ├── compose-validate.sh  # Validate all compose.yaml files
│   ├── verify-repo-layout.sh # Check repo structure invariants
│   ├── init-nas.sh          # First-boot NAS initialisation
│   ├── nas-reset.sh         # Factory-reset helper
│   ├── fix-permissions.sh   # Repair bind-mount ownership
│   ├── restore-env.sh       # Restore .env from .env.example
│   └── maintenance/         # Scheduled maintenance scripts
│
└── docs/                    # (planned) Architecture and runbook docs
```

## Getting Started

### 1. Clone the repo onto the NAS

```bash
cd /volume2/docker
git clone https://github.com/ofayese/ce-stacks.git
```

### 2. Install Dockhand via RC script

```bash
sudo cp /volume2/docker/ce-stacks/dockhand/dockhand-start.sh /usr/local/etc/rc.d/dockhand.sh
sudo chmod +x /usr/local/etc/rc.d/dockhand.sh
sudo /usr/local/etc/rc.d/dockhand.sh
```

Dockhand will be available at `http://10.0.1.15:3866` after health check passes (60s).

**First-time setup**: See [`dockhand/README.md`](./dockhand/README.md) for UI initialization and git webhook configuration.

### 3. Initialize Dockhand

Access the web UI at `http://10.0.1.15:3866` and:

1. Create admin user (Settings > Authentication > Users)
2. Add Docker environment (Settings > Environments > +Add: "DS723", Unix socket)
3. Register git webhook (Settings > Webhooks) for auto-sync on repo push

See [`stacks/dockhand/README.md`](./stacks/dockhand/README.md) for detailed steps.

### 4. Import Stacks

Dockhand auto-imports stacks from your ce-stacks repo via:

- **Git webhook**: Push to repo → Dockhand auto-deploys (recommended)
- **Manual upload**: Dockhand UI → Stacks → Create Stack → Upload compose.yaml

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
| Port bindings | `10.0.1.15:HOST_PORT:CONTAINER_PORT` — LAN-only |
| UID/GID | Default `PUID=0 / PGID=0` for Synology bind-mount ownership |
| Database images | Version-pinned; `watchtower.enable=false` label to prevent auto-upgrade |
| Floating tags | Prohibited for stateful services; pinned semver required |
| Secrets | Never in `compose.yaml`; always via `.env` (excluded from git) |
| Log rotation | `json-file`, `max-size=10m`, `max-file=3` on all services |

## Network Subnets

All bridge networks use explicit `/24` subnets to prevent Docker's auto-assigned `/16` ranges from creating collisions.

| Stack | Network name | Subnet | Notes |
|---|---|---|---|
| *(backbone)* | ce-internal | 172.26.0.0/24 | External; created by `init-nas.sh` |
| warp-main | warp-network | 172.25.0.0/24 | Moved from .23 (it-tools /16 collision) |
| ollama | ollama-net | 172.27.0.0/24 | |
| databases | db-net | 172.28.0.0/24 | |
| code-server | code-server-net | 172.28.2.0/24 | |
| grafana-prom | grafana-net | 172.29.0.0/24 | |
| grafana-prom | prometheus-net | 172.29.1.0/24 | |
| psu-ots | psu-ots-net | 172.32.0.0/24 | Moved from 172.25 (warp collision); 172.30 taken by zabbix |
| dozzle | dozzle-net | 172.31.0.0/24 | |
| watchtower | watchtower-net | 172.31.1.0/24 | |
| agents_gateway_data | agents-gateway-net | 172.31.7.0/24 | |
| mcp-tools-config | mcp-tools-net | 172.31.8.0/24 | |
| zabbix | zabbix-net | 172.30.0.0/24 | Moved from 172.24 (openresume /16 collision) |

The Docker default bridge `172.17.0.0/16` is reserved and must not be re-used.

## Dockhand Details

Dockhand lifecycle is managed exclusively by the RC script — not by a compose stack.

- **Script**: `scripts/dockhand-start.sh` → installed at `/usr/local/etc/rc.d/dockhand.sh`
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
- Reverse proxy timeouts: set to 600s in DSM → Application Portal to avoid WebSocket drops
- Stacks using HTTPS backends: configure DSM proxy as HTTPS→HTTPS to avoid 400 Bad Request

## Security Notes

- All `.env` files are excluded from git (see `.gitignore`)
- The `stacks/acme-sh/data/`, `stacks/ollama/data/`, and `stacks/github-desktop/config/ssl/` directories are gitignored — they contain runtime certificates, private keys, and SSH identity material
- Database Watchtower exemptions prevent accidental major-version upgrades that would corrupt data directories

## License

Private infrastructure repository. All rights reserved.
