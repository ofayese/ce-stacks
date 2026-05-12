# ce-stacks

Production Docker stack infrastructure for a Synology DS723+ NAS running DSM 7.3. All stacks are managed via [Portainer CE](https://www.portainer.io/) and deployed under the canonical root `/volume2/docker/ce-stacks`.

## Architecture Overview

- **NAS**: Synology DS723+ · DSM 7.3 · Docker Engine via Container Manager
- **Stack root**: `/volume2/docker/ce-stacks`
- **Portainer data**: `/volume2/docker/portainer` (outside stack root, persists across repo resets)
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

### 2. Install Portainer via RC script

```bash
sudo cp /volume2/docker/ce-stacks/scripts/portainer-start.sh /usr/local/etc/rc.d/portainer.sh
sudo chmod +x /usr/local/etc/rc.d/portainer.sh
sudo /usr/local/etc/rc.d/portainer.sh
```

Portainer CE will be available at `https://10.0.1.15:9443` after first boot.

### 3. Populate secrets

Every stack that needs secrets has a `.env.example`. Copy and fill in each one before starting the stack:

```bash
# Example for synology-api-bridge
cd /volume2/docker/ce-stacks/stacks/synology-api-bridge
cp .env.example .env
nano .env   # fill in BRIDGE_SHARED_SECRET
```

### 4. Register stacks in Portainer

Add each stack via Portainer → Stacks → Add stack → Repository, pointing at this repo. Stacks read `compose.yaml` from their subdirectory.

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

| Stack | Network name | Subnet |
|---|---|---|
| warp-main | warp-network | 172.23.0.0/24 |
| zabbix | zabbix-net | 172.24.0.0/24 |
| psu-ots | psu-ots-net | 172.25.0.0/24 |

The Docker default bridge `172.17.0.0/16` is reserved and must not be re-used.

## Portainer CE Details

Portainer lifecycle is managed exclusively by the RC script — not by a compose stack.

- **Script**: `scripts/portainer-start.sh` → installed at `/usr/local/etc/rc.d/portainer.sh`
- **Image**: `portainer/portainer-ce:2.41.0-alpine` (supports `compose.yaml` natively)
- **Ports**: `10.0.1.15:9000` (HTTP API), `10.0.1.15:9443` (HTTPS WebUI)
- **Data**: `/volume2/docker/portainer` (outside this repo)

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
