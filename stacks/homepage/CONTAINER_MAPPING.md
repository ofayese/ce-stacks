# Container Mapping Reference

This document maps each Homepage service reference to its actual Docker container name and compose file source. Use this as a single source of truth when adding, removing, or troubleshooting services.

**Last Updated:** April 2025
**Stack:** olutechsys Homelab (DS723+)
**Reference:** https://gethomepage.dev/configs/services/

---

## Mapping Table

| Homepage Service            | Container Name      | Compose File                                              | Service Name               | Widget Support     | Notes                                                              |
| --------------------------- | ------------------- | --------------------------------------------------------- | -------------------------- | ------------------ | ------------------------------------------------------------------ |
| **Infrastructure**          |                     |                                                           |                            |                    |                                                                    |
| Portainer                   | `portainer`         | `portainer/compose.yaml`                                  | `portainer`                | ✓ Portainer widget | Requires API key in services.yaml                                  |
| Portainer Agent             | `portainer_agent`   | `portainer/compose.yaml`                                  | `portainer_agent`          | —                  | Remote agent for edge nodes                                        |
| Dockge                      | `Dockge`            | Synology startup script (`/usr/local/etc/rc.d/dockge.sh`) | `docker run --name=Dockge` | ✓ Dockge widget    | Port **5571**→5001; image `louislam/dockge:1`; not compose-managed |
| Watchtower                  | `Watchtower`        | `watchtower/compose.yaml`                                 | `watchtower`               | —                  | Auto-update daemon                                                 |
| **Management**              |                     |                                                           |                            |                    |                                                                    |
| Dozzle                      | `Dozzle`            | `dozzle/compose.yaml`                                     | `dozzle`                   | —                  | Real-time log viewer                                               |
| Adminer                     | `Adminer`           | `databases/compose.yaml`                                  | `adminer`                  | —                  | Multi-DB admin UI                                                  |
| phpMyAdmin                  | `CodeServerPMA`     | `code-server/compose.yaml`                                | `phpmyadmin`               | —                  | MySQL admin for dev DB                                             |
| Synology DSM                | —                   | —                                                         | —                          | —                  | NAS control panel, external                                        |
| **Development**             |                     |                                                           |                            |                    |                                                                    |
| Code-Server                 | `CodeServer`        | `code-server/compose.yaml`                                | `code-server`              | —                  | VS Code browser IDE                                                |
| MySQL (Code-Server)         | `CodeServerDB`      | `code-server/compose.yaml`                                | `db`                       | —                  | Dev database, port 3307                                            |
| MariaDB                     | `MariaDB`           | `databases/compose.yaml`                                  | `mariadb`                  | —                  | Shared app database                                                |
| PostgreSQL                  | `PostgreSQL`        | `databases/compose.yaml`                                  | `postgres`                 | —                  | Shared app database                                                |
| **Productivity**            |                     |                                                           |                            |                    |                                                                    |
| Codex Docs                  | `CodexDocs`         | `codex-docs/compose.yaml`                                 | `codex-docs`               | —                  | Documentation wiki                                                 |
| Codex MongoDB               | `CodexDocs-MongoDB` | `codex-docs/compose.yaml`                                 | `mongodb`                  | —                  | Backing database for Codex                                         |
| OpenResume                  | `OpenResume`        | `openresume/compose.yaml`                                 | `openresume`               | —                  | Resume builder                                                     |
| **AI**                      |                     |                                                           |                            |                    |                                                                    |
| Open WebUI                  | `otsai-webui`       | `ollama/compose.yaml`                                     | `open-webui`               | —                  | LLM chat interface                                                 |
| Ollama                      | `otsai-server`      | `ollama/compose.yaml`                                     | `ollama`                   | ✓ Ollama widget    | Local inference server                                             |
| **Search & Tools**          |                     |                                                           |                            |                    |                                                                    |
| SearXNG                     | `SearXNG`           | `searxng/compose.yaml`                                    | `searxng`                  | ✓ SearXNG widget   | Private metasearch                                                 |
| SearXNG Redis               | `SearXNG-Redis`     | `searxng/compose.yaml`                                    | `redis`                    | —                  | Cache for SearXNG                                                  |
| IT-Tools                    | `IT-Tools`          | `it-tools/compose.yaml`                                   | `it-tools`                 | —                  | Utility toolkit                                                    |
| **Certificates & Security** |                     |                                                           |                            |                    |                                                                    |
| acme.sh                     | `AcmeSh`            | `acme-sh/compose.yaml`                                    | `acme-sh`                  | —                  | Let's Encrypt automation                                           |

---

## How to Use This Reference

### Adding a New Service

1. Deploy the new service in its compose.yaml file with an explicit `container_name: MyService`
2. Get the exact container name: `docker ps --filter "name=MyService" --format "{{.Names}}"`
3. Add an entry to this table
4. Add the service to `services.yaml` with:
   ```yaml
   - My Service:
       container: MyService # MUST match container_name exactly (case-sensitive)
       server: my-docker # Always reference the docker socket from docker.yaml
       siteMonitor: http://10.0.1.15:PORT/ # If service exposes a health endpoint
       # Optional widget (if Homepage has a plugin for this service)
       widget:
         type: your-widget-type
         url: http://container-name:PORT
   ```
5. Run `homepage/verify-integration.sh` to confirm the new service appears

### Updating Container Names

If you rename a container:

1. Update the `container_name:` in the compose.yaml
2. Update this table
3. Update `services.yaml` to match
4. Restart the Homepage container: `docker compose -f homepage/compose.yaml restart`

### Troubleshooting Missing Status Indicators

If a service shows in Homepage but no status (green/red dot) appears:

1. Verify the `container:` value in services.yaml matches this table exactly (case-sensitive)
2. Run `docker ps | grep <ContainerName>` to confirm the container is running
3. Run `homepage/verify-integration.sh` for detailed diagnostics

---

## Widget Support Matrix

The following services support real-time widgets in Homepage:

| Service   | Widget Type | Config Location                    | Example                                     |
| --------- | ----------- | ---------------------------------- | ------------------------------------------- |
| Portainer | `portainer` | services.yaml → Portainer → widget | Requires `env: <id>` and `key: <api_token>` |
| Ollama    | `ollama`    | services.yaml → Ollama → widget    | Shows model count, queue depth              |
| SearXNG   | `searxng`   | services.yaml → SearXNG → widget   | Displays search statistics                  |

Other services (Dozzle, Code-Server, MariaDB, etc.) show status only (running/stopped) but no real-time metrics.

---

## Synology DS723+ Specifics

- **Docker Socket:** `/var/run/docker.sock` (mounted read-only in Homepage container)
- **Ownership:** bind mounts should be `root:root` on NAS (`fix-permissions.sh`); Homepage does not set linuxserver-style PUID in compose.
- **All containers use label:** `com.centurylinklabs.watchtower.enable=true` (for auto-updates)
- **All containers are on the same `bridge` network** (defined externally in root compose files)

---

## References

- Homepage Documentation: https://gethomepage.dev/configs/services/
- Docker Compose Reference: https://docs.docker.com/compose/compose-file/
- Synology Marius Hosting Guide: https://mariushosting.com/how-to-install-homepage-on-your-synology-nas/
