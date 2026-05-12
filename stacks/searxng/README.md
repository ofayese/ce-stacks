# searxng

Privacy-respecting metasearch engine, backed by Valkey (Redis fork) for caching.

## Services

- **redis** (Valkey) — ephemeral cache (`--save "" --appendonly no` → no on-disk persistence)
- **searxng** (8888) — uWSGI web frontend; depends on `redis` healthcheck

## Startup order

**searxng** starts after **redis** is **healthy**. See **`docs/hive/NAS_DEPLOYMENT.md`** → **Dockge stack lifecycle (Compose v2)**.

## Public hostname

`search.otsorundscore.olutechsys.com` (frontend; via HAProxy when ready).

## Required state

`/volume1/​docker/dockge​/stacks/searxng/config/settings.yml` — **not** in git (contains `secret_key`).

1. Copy the template:
   ```bash
   cp searxng/config/settings.yml.example searxng/config/settings.yml
   ```
2. Set `server.secret_key` to the output of `openssl rand -hex 32`.

Verify the real file is ignored:

```bash
git check-ignore -v searxng/config/settings.yml
```

## Health

- redis: `valkey-cli ping` returns `PONG`
- searxng: HTTP 200 on `/healthz` (with `/` fallback)

## Capability whitelist

searxng runs with `cap_drop: ALL` and only adds `CHOWN/SETGID/SETUID` — needed for first-run permission fixups. Do not narrow without testing; settings writes will fail otherwise.

## Rollback

```bash
git checkout -- searxng/compose.yaml
docker compose -f searxng/compose.yaml up -d
```

Cache is ephemeral; no data loss on restart. `config/settings.yml` stays local-only.
