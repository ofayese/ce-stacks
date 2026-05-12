# watchtower

Scheduled image-update agent. Updates only containers labeled `com.centurylinklabs.watchtower.enable=true` (opt-in).

## Service

- **watchtower** — runs continuously; cron-driven update sweeps; reads host `docker.sock` (`:ro`)
- **HTTP API + Prometheus metrics** — `WATCHTOWER_HTTP_API_UPDATE`, `WATCHTOWER_HTTP_API_PERIODIC_POLLS`, and `WATCHTOWER_HTTP_API_METRICS` are enabled. Bearer auth uses the Docker secret backed by [`../grafana-prom/secrets/watchtower_bearer_token.txt`](../grafana-prom/secrets/watchtower_bearer_token.txt) (see [`../grafana-prom/secrets/README.md`](../grafana-prom/secrets/README.md)). The API (including `/v1/metrics`) is published on **`10.0.1.15:18787`** → container `8080`.

## Networking

This stack does **not** attach to Docker’s default `bridge` network. Compose’s default **project** network is a user-defined bridge (service DNS, healthchecks, and modern Compose all expect that). Mapping `external: true` to the literal `bridge` network caused `network-scoped alias is supported only for containers in user defined networks` on some engines.

## `.env` file syntax

Compose parses `watchtower/.env` as `KEY=value` lines or `#` comments. A **bare path** (for example a line that is only `../grafana-prom/secrets/watchtower_bearer_token.txt`) is invalid and yields `unexpected character "/" in variable name` — delete it or prefix the whole line with `#`. The bearer token file is referenced only from `compose.yaml` under `secrets:`; it does not belong as a standalone line in `.env`.

## Schedule

Daily at 04:00 America/New_York (`WATCHTOWER_SCHEDULE=0 0 4 * * *`).
Cron format: `sec min hour dom mon dow`.

## Behavior

- Only opt-in containers (`WATCHTOWER_LABEL_ENABLE=true`)
- Cleans up old images after update (`WATCHTOWER_CLEANUP=true`)
- Skips stopped containers
- Notifies via `WATCHTOWER_NOTIFICATION_URL` — currently `logger://` (logs only). Change to a Discord/Slack webhook for real alerts.

## Pinning policy interaction

Watchtower will pull patch/minor updates for any opt-in image whose tag is itself rolling (e.g. `:latest`, `:lts`, `:main`). For digest-pinned images, Watchtower notifies but cannot update — upgrades are manual by changing the digest in compose.yaml.

Watchtower does **not** auto-update itself by label even with `watchtower.enable=true` set on its own container — by design (avoid the agent updating mid-run). Manual tag bumps remain the operator's job; see `docs/hive/proposals/watchtower/PROPOSAL.md`.

## Health

Scratch-based image: no `/bin/sh` or `wget`, so `CMD-SHELL` probes fail. Use exec-form `["CMD", "/watchtower", "--health-check"]` (matches upstream image `HEALTHCHECK`).

## Rollback

```bash
git checkout -- watchtower/compose.yaml
docker compose -f watchtower/compose.yaml up -d
```

No persistent state — Watchtower is stateless.
