# mcp-tools-config - Docker MCP catalog (reference)

This folder holds **reference YAML** for Docker Desktop MCP tooling.

## Files

| File                                            | Purpose                                                                                                                                                                                                                                     |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`compose.yaml`](./compose.yaml)                | **Minimal Dockge/CI Compose** - satisfies `scripts/compose-validate.sh`. One-shot `busybox` + `true`; safe to leave stopped after validation. Does **not** run MCP servers.                                                                 |
| [`docker-mcp.yaml`](./docker-mcp.yaml)          | **Docker MCP catalog** (metadata/registry entries). **Not** a Docker Compose file - validated only as YAML by editors/CI hooks, not `docker compose config` (see [`docs/hive/COMPOSE_FILENAMES.md`](../../docs/hive/COMPOSE_FILENAMES.md)). |
| `config.yaml`, `registry.yaml`, `tools.yaml`, … | Operator-edited MCP configuration fragments.                                                                                                                                                                                                |

## NAS / git

- **`compose.yaml`** is **CI / `compose-validate` only** (Busybox exits immediately). On Dockge you can leave this stack **down** if you only maintain **`docker-mcp.yaml`** as a catalog.
- Treat this directory as **config-only**; keep large or machine-generated artifacts out of git when possible.
- Prefer editing on a Mac/Linux checkout and **rsync** to the NAS per `HIVE_OBJECTIVE.md` → NAS Deployment Notes.

## Outbound

Catalog references remote README/tool URLs; runtime MCP servers still need **HTTPS 443** when pulled or invoked.
