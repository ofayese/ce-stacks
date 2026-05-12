# codex-docs

Internal documentation hub powered by codex.team's [codex.docs](https://github.com/codex-team/codex.docs) CMS, backed by MongoDB. The compose **`image:`** pins **`ghcr.io/codex-team/codex.docs@sha256:…`** (supply-chain); re-pin with `docker pull` + `docker image inspect` on your network.

## Services

- **mongodb** — data store, internal-only
- **codex-docs** (8896) — Node.js app; depends on `mongodb` healthcheck

## Startup order

**codex-docs** waits on **mongodb** being **healthy**. See **`docs/hive/NAS_DEPLOYMENT.md`** → **Dockge stack lifecycle (Compose v2)**.

## Required env (`.env`)

- `APP_SECRET` — random 64-char hex; rotate on compromise. Generate with `openssl rand -hex 32`.

See `.env.example` for the full set.

## Public hostname

`otsorundscore.olutechsys.com` (resolved via `extra_hosts` to `10.0.1.15`).

## Volumes

| Host path                       | Container path         | Mode | Created by    |
| ------------------------------- | ---------------------- | ---- | ------------- |
| `${STACK_ROOT}/codex-docs/db`   | `/data/db`             | rw   | `init-nas.sh` |
| `${STACK_ROOT}/codex-docs/data` | `/usr/src/app/uploads` | rw   | `init-nas.sh` |

> Run `sudo bash scripts/init-nas.sh` after cloning to create these
> directories. Without them, the container will fail to start.

## Health

- mongodb: `mongosh` admin ping
- codex-docs: HTTP 200 on `/`

## Rollback

```bash
git checkout -- codex-docs/compose.yaml
docker compose -f codex-docs/compose.yaml up -d
```

Mongo data persists at `${STACK_ROOT}/codex-docs/db`. Never `rm -rf` without a snapshot.

## Backup

| Directory                       | Hyper Backup | Method                                                                                       |
| ------------------------------- | ------------ | -------------------------------------------------------------------------------------------- |
| `${STACK_ROOT}/codex-docs/data` | Include      | File copy                                                                                    |
| `${STACK_ROOT}/codex-docs/db`   | **Exclude**  | `docker exec CodexDocs-MongoDB mongodump` (see `docs/hive/NAS_DEPLOYMENT.md` → Hyper Backup) |

## Status note

This stack historically shipped `APP_SECRET=REPLACE_WITH_RANDOM_SECRET` in compose.yaml. Verify the running container's `APP_SECRET` is a real random value before treating data as authoritative; see `docs/hive/proposals/codex-docs/PROPOSAL.md`.
