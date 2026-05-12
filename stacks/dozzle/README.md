# dozzle

Real-time Docker log viewer. Reads the host `docker.sock` (`:ro`) and streams container logs to a web UI.

## Service

- **dozzle** (8892) — log viewer; auth via `users.yml` (mounted into `/data/users.yml`)

## Auth

`DOZZLE_AUTH_PROVIDER=simple` requires entries in `users.yml`. Generate users with:

```bash
docker run --rm amir20/dozzle:latest generate <username> --password <password>
```

Append the output to `dozzle/users.yml`. The file is mounted read-only into the container.

## Health

Shell-free probe (`/dozzle --version`) because current Dozzle images do not ship `/bin/sh` for `CMD-SHELL` healthchecks.

## RACI

This stack's worker is the **cross-cutting log-visibility owner** per HIVE_OBJECTIVE.md. The `logging:` driver/options on every other stack must be Dozzle-friendly (`json-file` with `max-size` / `max-file`). See `docs/hive/proposals/_baseline/PROPOSAL.md` §1 for the canonical block.

## Security note

`docker.sock` is mounted read-only — Dozzle enumerates and streams logs but cannot exec into containers or modify state.

## Rollback

```bash
git checkout -- dozzle/compose.yaml
docker compose -f dozzle/compose.yaml up -d
```

`users.yml` is preserved across restarts.
