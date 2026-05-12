# Homepage — DS723+ Docker Dashboard

A customizable, real-time dashboard for the olutechsys homelab infrastructure. Automatically mirrors container status for stacks deployed under `${STACK_ROOT}`.

**Status:** Fully functional with Synology DS723+ socket integration
**Last Updated:** April 2025
**Reference:** https://mariushosting.com/how-to-install-homepage-on-your-synology-nas/

## Volumes

| Host path                       | Container path         | Mode | Created by    |
| ------------------------------- | ---------------------- | ---- | ------------- |
| `${STACK_ROOT}/homepage/config` | `/app/config`          | rw   | `init-nas.sh` |
| `${STACK_ROOT}/homepage/data`   | `/app/public/icons`    | rw   | `init-nas.sh` |
| `/var/run/docker.sock`          | `/var/run/docker.sock` | ro   | operator      |

> Run `sudo bash scripts/init-nas.sh` after cloning to create these
> directories. Without them, the container will fail to start.

---

## Quick Start

### Deploy the Stack

1. **Via Dockge UI:**

   - Open Dockge at http://10.0.1.15:5571
   - Create a new stack named `homepage`
   - Point it to `${STACK_ROOT}/homepage/compose.yaml`
   - Click "Deploy"

2. **Via command line:**
   ```bash
   cd "${STACK_ROOT}/homepage"
   docker compose up -d
   ```

### Access the Dashboard

Once running, Homepage will be available at:

- **Local:** http://10.0.1.15:7575
- **Remote:** http://otsorundscore.olutechsys.com:7575 (via `extra_hosts` in compose.yaml)

**First Load:** Files in `./config/` take precedence, so the dashboard will immediately reflect your stack configuration.

---

## File Structure

```
homepage/
├── compose.yaml              # Container definition + socket mount
├── README.md                 # This file
├── CONTAINER_MAPPING.md      # Service → Container cross-reference (new)
├── verify-integration.sh      # Socket validation script (new)
└── config/
    ├── docker.yaml           # Socket reference (explained below)
    ├── services.yaml         # 20+ services across 6 categories
    ├── settings.yaml         # Theme, layout, DS723+ optimization
    ├── widgets.yaml          # Dashboard gauges, datetime, weather
    ├── bookmarks.yaml        # Quick links to external tools/docs
    ├── kubernetes.yaml       # Disabled (Synology single-node only)
    ├── custom.css            # Optional CSS overrides
    └── custom.js             # Optional JavaScript customizations
```

| File                              | Purpose                                                                                                                                                                   |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `compose.yaml`                    | Container definition. Exposes 7575 → 3000, mounts config and Docker socket (read-only).                                                                                   |
| `config/services.yaml`            | 20 services grouped into 6 categories: Infrastructure, Management, Development, Productivity, AI, Search & Tools.                                                         |
| `config/docker.yaml`              | Single `my-docker:` socket entry enabling container status monitoring. See [Socket Integration Explained](#how-the-docker-socket-integration-works-synology-ds723) below. |
| `config/settings.yaml`            | Theme (dark/light), color scheme, layout optimization for DS723+ (4-column infrastructure sections).                                                                      |
| `config/widgets.yaml`             | Top-of-dashboard gauges: DS723+ CPU/Memory/Disk, search bar (SearXNG), datetime, weather (OpenMeteo).                                                                     |
| `config/bookmarks.yaml`           | Quick-access links: DSM, Cloudflare, reference docs, GitHub.                                                                                                              |
| `config/kubernetes.yaml`          | Explicitly disabled (Synology is single-node).                                                                                                                            |
| `config/custom.css` / `custom.js` | Optional personalization (dark mode tweaks, branding).                                                                                                                    |
| `CONTAINER_MAPPING.md`            | **NEW:** Master reference table mapping each Homepage service to its actual Docker container name and source compose file. Use when adding/removing services.             |
| `verify-integration.sh`           | **NEW:** One-command validation script to confirm socket mount, container status, and configuration consistency.                                                          |

---

## Post-Deployment Setup

### 1. Verify Docker Socket Integration

Run the validation script to confirm everything is connected:

```bash
cd "${STACK_ROOT}/homepage"
bash verify-integration.sh
```

Expected output:

```
✓ Homepage container is running
✓ Docker socket mounted: /var/run/docker.sock
✓ Socket is readable from inside container
✓ 20 services configured, 20 containers found
```

If you see warnings, see [Troubleshooting](#troubleshooting) below.

### 2. Add Portainer API Key (For Dashboard Widget)

1. Open Portainer at https://10.0.1.15:9443
2. Click your profile icon → **My Account**
3. Scroll to **Access Tokens** → **Create token**
4. Copy the token
5. In `stacks/homepage/.env` (not committed), set `PORTAINER_API_KEY=<token>` — the Portainer widget reads `key: ${PORTAINER_API_KEY}` from `config/services.yaml`.
6. Confirm `env: 1` matches your environment ID (Portainer → Endpoints → note the ID next to your edge agent)
7. Restart Homepage:
   ```bash
   docker compose -f compose.yaml restart
   ```

### 3. Optional: Set Weather Location

The OpenMeteo widget auto-detects your location but can be precise. To set manually:

1. Find your latitude/longitude (e.g., via https://www.latlong.net/)
2. Edit `config/widgets.yaml` and uncomment/add:
   ```yaml
   - openmeteo:
       label: Home
       latitude: YOUR_LAT
       longitude: YOUR_LONG
       timezone: America/New_York
       units: imperial
       cache: 5
   ```
3. Restart: `docker compose -f compose.yaml restart`

### 4. Add Custom Hostnames

If you access Homepage from a different hostname (e.g., a VPN client or second domain), add it to `compose.yaml`:

```yaml
environment:
  - HOMEPAGE_ALLOWED_HOSTS=10.0.1.15:7575,otsorundscore.olutechsys.com:7575,otsorundscore.olutech.systems:7575,your-other-hostname:7575
```

Then restart:

```bash
docker compose -f compose.yaml restart
```

---

## How the Docker Socket Integration Works (Synology DS723+)

### The Mechanism

Homepage displays **live container status** (green = running, red = stopped) by reading Docker events from the socket. Here's how it works:

1. **Socket Mount** (in `compose.yaml`):

   ```yaml
   volumes:
     - /var/run/docker.sock:/var/run/docker.sock:ro # Read-only
   ```

   This allows Homepage to query the Docker daemon without network overhead.

2. **Socket Reference** (in `config/docker.yaml`):

   ```yaml
   my-docker:
     socket: /var/run/docker.sock # Inside the Homepage container
   ```

3. **Service Mapping** (in `config/services.yaml`):
   ```yaml
   - Portainer:
       container: portainer # Must match compose.yaml exactly
       server: my-docker # References the socket above
   ```

### Why This Pattern?

- **No Docker Socket Proxy needed:** On a single-node Synology NAS, a proxy (like `tecnativa/docker-socket-proxy`) adds unnecessary complexity.
- **Direct socket access is safe:** The socket is confined to your NAS; it's not exposed to the network.
- **Lower latency:** Direct read is faster than proxy forwarding.
- **Fewer moving parts:** One less container to manage.

### Synology-Specific Notes

- **Read-only mount** (`:ro`): Homepage only reads container info; it cannot modify containers. Essential for security.
- **PUID/PGID:** Homepage image does not use linuxserver-style PUID; bind mounts rely on host ownership. Use **`scripts/fix-permissions.sh`** on the NAS so paths under `${STACK_ROOT}/homepage/` are `root:root` per `HIVE_OBJECTIVE.md`.
- **Watchtower labels:** All services include `com.centurylinklabs.watchtower.enable=true` for automatic updates.
- **External bridge network:** All stacks use a pre-created Docker network called `bridge` (defined at the NAS level).

### References

- Marius Hosting guide (the source of this pattern): https://mariushosting.com/how-to-install-homepage-on-your-synology-nas/
- Homepage documentation on Docker integration: https://gethomepage.dev/configs/services/
- Docker socket security: https://docs.docker.com/engine/security/

---

## Troubleshooting

### Container Status Not Showing (Green/Red Dots Missing)

**Symptom:** Services appear in Homepage but no status indicator.

**Diagnosis:**

```bash
# Check if container name matches exactly (case-sensitive)
docker ps --filter "name=MyContainer" --format "{{.Names}}"

# Check services.yaml for the exact match
grep -A2 'container:' config/services.yaml | grep -i "mycontainer"
```

**Fix:**

1. Get the exact container name: `docker ps | grep my-service`
2. Update `config/services.yaml` to match exactly (case-sensitive)
3. Reference `CONTAINER_MAPPING.md` for the authoritative list
4. Restart: `docker compose -f compose.yaml restart`
5. Run `verify-integration.sh` to confirm

### Socket Mount Not Working

**Symptom:** Homepage runs but no containers show any status.

**Diagnosis:**

```bash
# Check if socket is mounted inside the container
docker exec Homepage ls -la /var/run/docker.sock

# Check if socket is readable
docker exec Homepage test -r /var/run/docker.sock && echo "Readable" || echo "Not readable"
```

**Fix:**

1. Ensure `compose.yaml` includes the socket mount (it should)
2. Check Synology Container Manager logs: DSM → Container Manager → Docker Daemon → Log
3. Try restarting the Docker daemon: DSM → Control Panel → Services → Docker (stop, then start)
4. Run `verify-integration.sh` for detailed diagnostics

### Portainer Widget Not Showing Metrics

**Symptom:** Portainer service appears but widget area is blank.

**Possible causes:**

- API key not set or incorrect
- Environment ID (`env:`) doesn't match Portainer configuration
- Portainer HTTPS certificate issue

**Fix:**

1. Verify API key in `config/services.yaml` (see [Post-Deployment Setup](#post-deployment-setup) step 2)
2. Confirm environment ID:
   ```bash
   # In Portainer UI: Endpoints → find your edge agent → note the number (e.g., 1)
   # Update services.yaml: env: 1
   ```
3. If using HTTPS, ensure the certificate is valid (Portainer should auto-generate)
4. Restart Homepage: `docker compose -f compose.yaml restart`

### Adding a New Service Doesn't Appear

**Symptom:** You added a new service to `config/services.yaml` but it doesn't show.

**Diagnosis:**

1. Verify the container is running: `docker ps | grep my-new-service`
2. Verify the `container:` name matches exactly (case-sensitive)
3. Check the new service is on the same Docker network: `docker inspect my-new-service | grep -A5 NetworkSettings`
4. Run `verify-integration.sh` — it lists all configured vs. running containers

**Fix:**

1. Ensure the `container_name:` in the new service's `compose.yaml` is explicit
2. Add to `config/services.yaml` with the exact name
3. Update `CONTAINER_MAPPING.md` for future reference
4. Restart Homepage: `docker compose -f compose.yaml restart`
5. Verify: `verify-integration.sh`

### Port 7575 Already in Use

**Symptom:** `docker compose up -d` fails with port already bound.

**Fix:**

1. Check what's using the port: `sudo netstat -tlnp | grep 7575` (or use Synology UI)
2. If it's an old Homepage container: `docker rm -f Homepage`
3. If it's needed elsewhere, change the port in `compose.yaml`:
   ```yaml
   ports:
     - "7576:3000" # New external port
   ```

### All Widgets Fail to Load

**Symptom:** Homepage runs but all widgets show errors or are blank.

**Possible causes:**

- External network connectivity issue
- Weather service (OpenMeteo) temporarily unavailable
- DNS resolution failure

**Fix:**

1. Check network connectivity inside the container:
   ```bash
   docker exec Homepage wget -qO- https://api.open-meteo.com/v1/forecast\?latitude\=0\&longitude\=0 | head -20
   ```
2. Temporarily disable optional widgets in `config/widgets.yaml` (comment out `openmeteo`, etc.)
3. Check Synology's DNS settings (DSM → Control Panel → Network)
4. Review container logs: `docker logs Homepage | tail -50`

---

## Maintenance

### Updating Homepage

Watchtower automatically pulls the latest image daily (scheduled for 4 AM). To update manually:

```bash
cd "${STACK_ROOT}/homepage"
docker compose pull
docker compose up -d
```

### Backing Up Configuration

The `config/` directory contains all settings. Back it up regularly:

```bash
tar -czf homepage-backup-$(date +%Y%m%d).tar.gz config/
```

### Adding New Services to the Dashboard

1. Deploy the new service via compose or Dockge
2. Get its exact container name: `docker ps | grep new-service`
3. Add to `CONTAINER_MAPPING.md` (for documentation)
4. Add to `config/services.yaml` using the format in that file
5. Run `verify-integration.sh` to confirm it's detected
6. Restart Homepage: `docker compose -f compose.yaml restart`

---

## Port Reference

Homepage uses port **7575** because your existing stacks occupy:

- 8888 (SearXNG)
- 8889 (OpenResume)
- 8892–8896 (Dozzle, Adminer, phpMyAdmin, CodexDocs, IT-Tools)
- 8377–8378 (Code-Server, phpMyAdmin-dev)
- 9000–9001, 9443 (Portainer, Portainer Agent)
- 11434 (Ollama)
- 5571 (Dockge host port; container listens on 5001)
- 3307 (MySQL dev)

7575 is free and aligns with Homepage's upstream default.

---

## References

For more information:

- **Homepage Documentation:** https://gethomepage.dev/
- **Synology Setup Guide:** https://mariushosting.com/how-to-install-homepage-on-your-synology-nas/
- **Container Mapping Reference:** See `CONTAINER_MAPPING.md`
- **Validation Script:** Run `verify-integration.sh` for diagnostics

Feel free to ask if you need anything else!
