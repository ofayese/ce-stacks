# Stack Bring-Up Runbook -- otsorundscore NAS

**Date:** 2026-05-16  
**Already running:** grafana-prom . acme-sh . influxdb . watchtower . dockhand

All commands run as your NAS user from `/volume2/docker/ce-stacks` unless noted.  
Deploy each stack via **Dockhand UI** after completing its setup steps below.

---

## Tier 1 -- Zero-Config (deploy immediately)

These stacks need only a `.env` copy. No secrets, no data dirs, no config files.

### it-tools

```bash
cp stacks/it-tools/.env.example stacks/it-tools/.env
```

Deploy -> verify at `http://10.0.1.15:<port>` (check compose.yaml for port).

---

### openresume

```bash
cp stacks/openresume/.env.example stacks/openresume/.env
```

Stateless -- resume data lives in the browser's localStorage. Deploy and done.

---

### db-tools (Adminer + PhpMyAdmin)

Targets the Synology native MariaDB package -- no database container.

```bash
cp stacks/db-tools/.env.example stacks/db-tools/.env
```

Deploy -> Adminer at `10.0.1.15:8895`, PhpMyAdmin at `10.0.1.15:8378`.

---

## Tier 2 -- Light Setup (one config step)

### dozzle

Dozzle reads container logs. An optional `users.yml` file enables auth (already in the repo).

```bash
cp stacks/dozzle/.env.example stacks/dozzle/.env
mkdir -p stacks/dozzle
```

If you want to add/change login users before deploying:

```bash
# Generate a user entry and append to users.yml
docker run --rm amir20/dozzle:latest generate <username> --password <password> \
  >> stacks/dozzle/users.yml
```

Deploy. Logs UI is available immediately -- no data dir needed.

---

### github-desktop

KasmVNC-based GitHub Desktop in a browser tab.

```bash
cp stacks/github-desktop/.env.example stacks/github-desktop/.env
nano stacks/github-desktop/.env   # set GITHUB_DESKTOP_USER and GITHUB_DESKTOP_PASSWORD

mkdir -p stacks/github-desktop/config
```

Deploy -> `http://10.0.1.15:3405`

---

### homepage

```bash
cp stacks/homepage/.env.example stacks/homepage/.env
nano stacks/homepage/.env   # set GRAFANA_USERNAME and GRAFANA_PASSWORD if using the Grafana widget

mkdir -p stacks/homepage/data
```

Config files (`services.yaml`, `bookmarks.yaml`, etc.) are already in `stacks/homepage/config/` in git.  
Deploy -> `http://10.0.1.15:7575`

> **Note:** `code-server/CodeServerPMA` (phpMyAdmin for the dev MySQL sidecar) runs on port **8379**. `db-tools/PhpMyAdmin` (native MariaDB) runs on **8378**. Deploy code-server before db-tools to avoid the earlier port conflict.

---

## Tier 3 -- Medium Setup (secrets or config file required)

### searxng

Requires a `settings.yml` with a generated `secret_key` -- intentionally gitignored.

```bash
cp stacks/searxng/.env.example stacks/searxng/.env

# Create settings.yml from the example template
cp stacks/searxng/config/settings.yml.example stacks/searxng/config/settings.yml

# Inject a real secret_key (replace the placeholder in the file)
SECRET=$(openssl rand -hex 32)
sed -i "s/secret_key:.*/secret_key: \"${SECRET}\"/" stacks/searxng/config/settings.yml

# Verify it's gitignored
git check-ignore -v stacks/searxng/config/settings.yml
```

Deploy -> `http://10.0.1.15:<port>` . public at `search.otsorundscore.olutechsys.com`

---

### zabbix

Requires a Postgres password before first start (database initialises from env on first run).

```bash
cp stacks/zabbix/.env.example stacks/zabbix/.env
nano stacks/zabbix/.env   # set POSTGRES_PASSWORD to output of: openssl rand -hex 32

mkdir -p stacks/zabbix/db stacks/zabbix/data
```

Deploy. Zabbix initialises its database schema on first start -- takes ~60 seconds.  
Web UI -> `http://10.0.1.15:8532` . default login: `Admin` / `zabbix` (change immediately).

---

## Tier 4 -- Heavy Setup

### ollama (otsai + otsai-webui)

Resource-intensive: model pulls take 15-60 min on first start. Plan accordingly.

```bash
cp stacks/ollama/.env.example stacks/ollama/.env

mkdir -p stacks/ollama/data/ollama stacks/ollama/data/open-webui
```

**To trim models before first run** (saves time/disk): edit `stacks/ollama/scripts/entrypoint.sh` and comment out Tier 2/3 entries, or set `MODELS=` in `.env` with a comma-separated subset (e.g. `MODELS=stablelm2:3b,nomic-embed-text`).

Deploy. `scripts/entrypoint.sh` starts `ollama serve`, then pulls any missing models in sequence -- all in the single `otsai` container. Watch progress:

```bash
docker logs -f otsai
```

Open-WebUI -> `http://10.0.1.15:8893` -- create your admin account on first visit.

**Model storage:** `stacks/ollama/data/ollama/` -- each 7B model is ~4-5 GB. Tier 1+2+3 combined is ~40 GB.

---

### otspsu (PowerShell Universal -- NOC dashboard)

Most complex stack. Read `stacks/otspsu/README.md` fully before deploying.  
Start with all dangerous operations **off** (defaults in `.env.example` are safe).

```bash
cp stacks/otspsu/.env.example stacks/otspsu/.env
nano stacks/otspsu/.env
```

**Minimum required values to fill in:**

| Variable | Where to get it |
|---|---|
| `STACK_MANAGER_USERNAME` | Dockhand UI login |
| `STACK_MANAGER_PASSWORD` | Dockhand UI login |
| `BRIDGE_SHARED_SECRET` | Match value in other stacks that use it |
| `NAS_REPO_ROOT` | `/volume2/docker/ce-stacks` (already defaulted) |
| `PSU_STACK_ROOT` | `/volume2/docker/ce-stacks/stacks` (already defaulted) |
| `ACME_CERT_ROOT` | `/volume2/certs/acme` (already defaulted) |

**Leave off for now** (set to `0` / blank): `PSU_REMEDIATION_ENABLED`, `PSU_ALLOW_STACK_RESTART`, `PSU_SAFE_MODE_ENABLED`, `PSU_GITOPS_ENABLED`, all SSH vars.

```bash
mkdir -p stacks/otspsu/data
```

Deploy -> PSU web UI at `http://10.0.1.15:5570`  
Default login: set on first visit (PSU prompts for admin credentials on fresh install).

**After first login:** go to Admin -> Security -> App Tokens, create a token, and set `NAS_PULL_APP_TOKEN` in `.env`, then redeploy.

**SSH remediation** (optional, enables `docker compose` over SSH from inside the container):  
See `stacks/otspsu/NAS_HOST_SSH_SETUP.md` -- generates a dedicated key pair and adds it to `~/.ssh/authorized_keys`.

---

## Deploy Order Recommendation

```
1. it-tools        <- stateless, instant
2. openresume      <- stateless, instant
3. db-tools        <- stateless, instant
4. dozzle          <- useful for watching other stack logs during bring-up
5. homepage        <- config already in git
6. github-desktop  <- set credentials first
7. searxng         <- settings.yml required
8. zabbix          <- DB init takes ~60s
9. ollama          <- start last; model pulls run in background
10. otspsu        <- after all other stacks are healthy (monitors them)
```

---

## Common Verification Commands

```bash
# Check all running containers and health status
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Watch logs for a specific stack
docker logs -f <ContainerName>

# Check a specific healthcheck
docker inspect --format='{{.State.Health.Status}}' <ContainerName>

# Validate all compose files in repo
bash scripts/compose-validate.sh

# Check repo layout invariants
bash scripts/verify-repo-layout.sh
```
