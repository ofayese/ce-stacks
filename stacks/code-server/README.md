# code-server

Browser-based VS Code (`code-server`) with adjacent MySQL (`db`) and phpMyAdmin (`phpmyadmin`).

## Services

- **code-server** (8377) — IDE; mounts host `docker.sock` (rw) and project paths
- **db** (3307) — MySQL 8.3, project-scoped data via named volume `mysql_data`
- **phpmyadmin** (8378) — DB admin UI; depends on `db` healthcheck

## Startup order

**phpmyadmin** waits on **`db`** being **healthy**. See **`docs/hive/NAS_DEPLOYMENT.md`** → **Dockge stack lifecycle (Compose v2)**.

## Required env (`.env`)

- `CODE_SERVER_PASSWORD` — code-server login password (kept in local gitignored `.env`)
- `MYSQL_ROOT_PASSWORD`
- `PMA_CONTROLPASS` (also used as `MYSQL_PASSWORD` for the appuser)
- `PMA_BLOWFISH_SECRET` — 32-char random; `openssl rand -hex 16`
- (optional) `PUID`, `PGID`, `TZ`, `DOCKER_USER`, `MYSQL_DATABASE`, `MYSQL_USER`, `PMA_*`

See `.env.example` for the full set.

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

This stack runs its own MySQL alongside the separate `databases/` stack (mariadb + postgres + adminer). They are intentionally distinct (project DB vs admin DB); see `docs/hive/proposals/code-server/PROPOSAL.md` open question 1 for the consolidation question.
