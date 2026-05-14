# warp-main Secrets

Docker secret files for the warp-main stack. Mounted into the container at
`/run/secrets/<name>` via the `secrets:` block in compose.yaml.

## Required

| File | Variable injected | Description |
|------|-------------------|-------------|
| `warp_api_key.txt` | `WARP_API_KEY` | Warp platform API key (Settings → Platform; starts with `wk-`) |

## Creating secret files

```bash
# On the NAS:
echo "wk-YOUR_WARP_API_KEY" > stacks/warp-main/secrets/warp_api_key.txt
chmod 600 stacks/warp-main/secrets/warp_api_key.txt
```

## Security notes

- Never commit these files — they are in `.gitignore`
- The `warp-agent-entrypoint.sh` wrapper reads the file and exports `WARP_API_KEY`
  inside the running process, so it does **not** appear in `docker inspect warp-agent-service` output
- Rotate the key in the Warp platform dashboard, then update `warp_api_key.txt`
  and restart: `docker compose restart warp-agent`
