# acme-sh Secrets

Docker secret files for the acme-sh stack. These are mounted into the
container at `/run/secrets/<name>` via the `secrets:` block in compose.yaml.

## Required

| File | Variable injected | Description |
|------|-------------------|-------------|
| `cf_token.txt` | `CF_Token` | Cloudflare API token with `Zone.DNS:Edit` scope |

## Optional

| File | Variable injected | Description |
|------|-------------------|-------------|
| `discord_webhook_url.txt` | `DISCORD_WEBHOOK_URL` | Discord webhook for acme.sh notifications |

## Creating secret files

```bash
# On the NAS (or locally before syncing):
echo "YOUR_CLOUDFLARE_TOKEN" > stacks/acme-sh/secrets/cf_token.txt
echo "https://discord.com/api/webhooks/..." > stacks/acme-sh/secrets/discord_webhook_url.txt
chmod 600 stacks/acme-sh/secrets/*.txt
```

## Security notes

- Never commit these files — they are in `.gitignore`
- The `docker-entrypoint.sh` wrapper reads these files and exports them as
  environment variables inside the container process, so they do **not** appear
  in `docker inspect AcmeSh` output
- Rotate the Cloudflare API token in the Cloudflare dashboard, then update
  `cf_token.txt` and restart: `docker compose restart acme-sh`
