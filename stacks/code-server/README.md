# code-server

Browser-based VS Code (`code-server`) with adjacent MySQL (`db`) and phpMyAdmin (`phpmyadmin`).

**Image:** `ghcr.io/linuxserver/code-server` (linuxserver.io)

## Services

- **code-server** (8377→8443) — IDE; mounts host `docker.sock` (rw) and project paths under `/config/workspace/`
- **db** (3307) — MySQL 8.3, project-scoped data via named volume `mysql_data`
- **phpmyadmin** (8378) — DB admin UI; depends on `db` healthcheck

## Startup order

**phpmyadmin** waits on **`db`** being **healthy** (`condition: service_healthy`).

## Required env (`.env`)

- `CODE_SERVER_PASSWORD` — code-server web UI login password
- `SUDO_PASSWORD` — sudo password for the coder user inside the container (linuxserver requirement)
- `MYSQL_ROOT_PASSWORD`
- `PMA_CONTROLPASS` (also used as `MYSQL_PASSWORD` for the appuser)
- `PMA_BLOWFISH_SECRET` — 32-char random; `openssl rand -hex 16`
- (optional) `PUID`, `PGID`, `TZ`, `PROXY_DOMAIN`, `MYSQL_DATABASE`, `MYSQL_USER`, `PMA_*`

See `.env.example` for the full set.

## Volume layout (linuxserver)

| Container path | Host path | Purpose |
|---|---|---|
| `/config` | `${STACK_ROOT}/code-server/config` | Unified config, extensions, settings |
| `/config/workspace/docker` | `${CODE_SERVER_HOST_DOCKER_BIND}` | Host Docker root (operator bind) |
| `/config/workspace/home` | `${CODE_SERVER_HOST_HOME_BIND}` | Operator home dir (operator bind) |

## DSM Reverse Proxy — WebSocket requirement

code-server requires WebSocket support. In DSM → Application Portal → Reverse Proxy, add **Custom Headers** for the code-server rule:

| Header | Value |
|---|---|
| `Upgrade` | `$http_upgrade` |
| `Connection` | `Upgrade` |

Timeout must be set to **600 seconds** to prevent idle connection drops.

## Health

- code-server: HTTP 200 on `/`
- db: `mysqladmin ping` succeeds
- phpmyadmin: HTTP 200 on `/`

## Rollback

```bash
git checkout -- code-server/compose.yaml
docker compose -f code-server/compose.yaml up -d
```

DB data persists in named volume `mysql_data` — survives stack rebuild but **not** `docker volume rm mysql_data`.

## Trust assumption

The IDE has rw access to `/var/run/docker.sock` and `/volume1/{docker,homes/ofayese}`. Effectively root on host. Acceptable for personal lab; flag if access model widens.

## Scope note

This stack runs its own MySQL alongside the separate `databases/` stack (mariadb + postgres + adminer). They are intentionally distinct: this MySQL is a project-scoped dev database; the `databases/` stack is a shared admin database. Consolidation is an open question — defer unless disk pressure or management overhead justifies it.
