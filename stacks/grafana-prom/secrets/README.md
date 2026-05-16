# Grafana / Prometheus secrets (local only)

## `watchtower_bearer_token.txt`

Single-line bearer token shared by:

- **Fleet Watchtower** (`watchtower/compose.yaml`) — `WATCHTOWER_HTTP_API_TOKEN` via Docker secret (file contents = token).
- **Prometheus** (`grafana-prom/docker-compose.yml`) — `bearer_token_file` for the `watchtower` scrape job in `prom.yml`.

Create on the NAS (never commit this file):

```bash
openssl rand -hex 32 | tr -d '\n' > /volume2/docker/ce-stacks/stacks/grafana-prom/secrets/watchtower_bearer_token.txt
chmod 600 /volume2/docker/ce-stacks/stacks/grafana-prom/secrets/watchtower_bearer_token.txt
```

Then redeploy Watchtower and the `grafana-prom` stack. Prometheus scrapes `http://10.0.1.15:18787/v1/metrics` (host-published Watchtower HTTP API).

## `influxdb_grafana_password.txt`

Read-only InfluxDB password for the `grafana` user. Used by the Grafana datasource
provisioning file (`provisioning/datasources/influxdb.yml`) via Grafana's
`$__file{}` secret interpolation — no env var required.

This password must match `INFLUXDB_GRAFANA_PASSWORD` in `stacks/influxdb/.env`
(which creates the `grafana` read-only user in InfluxDB on first start).

Create on the NAS (never commit this file):

```bash
# Use the same password you set for INFLUXDB_GRAFANA_PASSWORD in stacks/influxdb/.env
echo -n '<grafana-read-password>' > /volume2/docker/ce-stacks/stacks/grafana-prom/secrets/influxdb_grafana_password.txt
chmod 600 /volume2/docker/ce-stacks/stacks/grafana-prom/secrets/influxdb_grafana_password.txt
```

Then restart Grafana to pick up the new datasource:

```bash
cd /volume2/docker/ce-stacks/stacks/grafana-prom
docker compose restart grafana
```

## `discord_webhook_url.txt`

Discord webhook URL for Alertmanager notifications. Used by
`alertmanager.yml` via `webhook_url_file` — no env var required.

Get the URL from: Discord server → Settings → Integrations → Webhooks → Copy Webhook URL

Create on the NAS (never commit this file):

```bash
echo -n 'https://discord.com/api/webhooks/<id>/<token>' > /volume2/docker/ce-stacks/stacks/grafana-prom/secrets/discord_webhook_url.txt
chmod 600 /volume2/docker/ce-stacks/stacks/grafana-prom/secrets/discord_webhook_url.txt
```

Then restart Alertmanager:

```bash
cd /volume2/docker/ce-stacks/stacks/grafana-prom
docker compose restart alertmanager
```
