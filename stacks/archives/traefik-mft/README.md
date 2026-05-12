# traefik-mft — Traefik v3 (Misfits / MFT NAS)

Traefik v3 runs on the **MFT** NAS and routes HTTPS for **`*.misfitsds.olutechsys.com`** and **`*.misfitsds.olutech.systems`**. Default TLS uses **`acme-sh`** PEMs (`misfitsds/`) via `config/tls.yaml`. A **`certificatesResolvers.cloudflare`** resolver (DNS-01, same token model as acme-sh) is also configured; internal split-horizon DNS is **not** used for ACME.

### Log messages (usually harmless)

- **`Failed to inspect container ... No such container`** — Stale Docker container ID after a service was removed or recreated; clears on refresh. Restart Traefik if noisy after bulk redeploys.
- **`Error checking new version` / `update.traefik.io`** — Disabled in `compose.yaml` via **`--global.checkNewVersion=false`** (avoids outbound check; NAS DNS timeouts otherwise).

### ACME storage permissions (`acme.json`)

Traefik expects **`${STACK_ROOT}/traefik-mft/data/acme.json`** at mode **600** once the file exists. If logs show `permissions 644 ... are too open, please use 600`:

```bash
chmod 600 "${STACK_ROOT}/traefik-mft/data/acme.json"
```

## Ports

Same pattern as `traefik-ots`: map host ports to **container** `:80` / `:443`, and map host `TRAEFIK_DASHBOARD_PORT` (default `9080`) to container `:8080` (see `traefik-ots/README.md`).

## Adding a service

1. Join the **`traefik-mft`** external network.
2. Add labels:

```yaml
labels:
  - traefik.enable=true
  - traefik.http.routers.<name>.rule=Host(`<subdomain>.misfitsds.olutechsys.com`)
  - traefik.http.routers.<name>.entrypoints=websecure
  - traefik.http.routers.<name>.tls=true
  - traefik.http.services.<name>.loadbalancer.server.port=<port>
```

## Files

- `compose.yaml` — Traefik service, mounts, healthcheck.
- `config/tls.yaml` — default certificate paths under `/certs/misfitsds/`.
