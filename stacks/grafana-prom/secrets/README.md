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
