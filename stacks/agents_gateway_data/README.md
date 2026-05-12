# agents_gateway_data — MCP gateway (DuckDuckGo)

**Dockge / default:** run **`compose.yaml`** in this directory only. The alternate layout under **`duckduckgo/compose.yaml`** is for a nested sample — do **not** run both stacks on the same host (**8812**) without changing ports.

Experimental **Docker MCP Gateway** wiring for DuckDuckGo search MCP. Uses the host Docker API.

## Ports

| Host (default) | Service            |
| -------------- | ------------------ |
| `8812` → `8811` | `mcp-gateway` HTTP (host **8812**, container **8811**) |

## Volumes

| Host path              | Container path         | Mode | Created by |
| ---------------------- | ---------------------- | ---- | ---------- |
| `/var/run/docker.sock` | `/var/run/docker.sock` | rw   | operator   |

No in-repo writable bind mount is declared. If future MCP gateway state is needed, place it under `${STACK_ROOT}/agents_gateway_data/` on the NAS and document the new bind before enabling it.

## Environment

Copy [`.env.example`](./.env.example) to `.env` if you add tunables. Defaults follow repo NAS policy: **`PUID`/`PGID` = 0** on Synology.

## Offline / outbound

Images pull from Docker Hub / GHCR; outbound **HTTPS (443)** required. No extra ports documented for runtime beyond MCP HTTP.

## Healthcheck

> Probe type: **A** — HTTP GET `/health` on container port **8811** (healthcheck runs inside the container; host publishes **8812**).
> Source: [docker/mcp-gateway upstream health example](https://raw.githubusercontent.com/docker/mcp-gateway/main/examples/health/compose.yaml).
> If the image is upgraded and the health endpoint changes, update the `healthcheck.test` line in `compose.yaml` accordingly.

## Related compose

- Root [`compose.yaml`](./compose.yaml) — primary stack file Dockge should run.
- [`duckduckgo/compose.yaml`](./duckduckgo/compose.yaml) — alternate layout; avoid running both on the same host port.
