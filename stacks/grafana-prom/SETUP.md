# Synology Grafana + Prometheus Stack

This Docker Compose stack provides complete monitoring for Synology NAS using Grafana and Prometheus.

## Services Included

- **Grafana** (3340): Visualization and dashboarding platform
- **Prometheus** (9090): Metrics collection and time-series database
- **Node Exporter** (9100): System and OS metrics
- **SNMP Exporter** (9116): SNMP protocol metrics collector
- **cAdvisor** (8080): Container metrics
- **Watchtower**: Automatic Docker image updates with metrics

## Prerequisites

1. **UID and GID for Grafana/Prometheus processes** (see `.env.example`):

   - Repo default on NAS: **`SYNO_UID=0`** / **`SYNO_GID=0`** (root) per `HIVE_OBJECTIVE.md`.
   - Override only on non-NAS dev hosts if you must run processes as a non-root numeric user.

2. **Enable SNMP on your Synology NAS**:

   - Control Panel > Terminal & SNMP > SNMP tab
   - Enable SNMP service
   - Enable SNMPv3 service
   - Enable SNMP privacy
   - Use credentials from snmp.yml

3. **Configure firewall rules** (if enabled):
   - Allow traffic on ports: **3340** (Grafana), **9090** (Prometheus), **9116** (SNMP exporter relay), **9100** (node exporter), **8080** (cAdvisor), and **UDP 161** from the Prometheus container host to **each Synology SNMP target** (see **`prom.yml`** — default **`10.0.1.15`** OTS and **`10.0.1.24`** MFT).
   - Docker bridge subnets for this stack follow **`docs/hive/NAS_DEPLOYMENT.md` → Docker network subnet registry** (e.g. **`grafana-net`**, **`prometheus-net`** under **`172.22.x.0/24`**). **Do not** use **`192.168.x.x`** in compose networks; examples below that used **`192.168.50.0/24`** / **`192.168.51.0/24`** are **non-prod placeholders only** — replace with your LAN CIDRs when opening the host firewall to admins.

## Setup Instructions

### Step 1: Update Configuration Files

Edit `.env`:

```bash
SYNO_UID=0                  # Default root on NAS (see HIVE_OBJECTIVE.md)
SYNO_GID=0
TIMEZONE=America/New_York   # IANA TZ
NAS_IP=10.0.1.15            # Management LAN IP for SNMP targets
```

SNMP targets live in **`prom.yml`** (this repo ships **SNMPv3-first** via **`snmp.yml`** — treat **SNMPv2c** as legacy/lab-only if you enable it: community strings are trivially sniffable on LANs). After editing, reload the Prometheus container.

```yaml
# See stacks/grafana-prom/prom.yml — synology-nas job uses 10.0.1.15:161 and 10.0.1.24:161 with instance labels.
```

### Step 2: Create Required Directories

```bash
mkdir -p data/grafana
mkdir -p data/prometheus
```

### Step 3: Deploy the Stack

```bash
docker compose up -d
```

Check status:

```bash
docker compose ps
```

### Step 4: Access Grafana

1. Open browser: `http://YOUR_NAS_IP:3340`
2. Default credentials: `admin` / `admin`
3. Change password when prompted

### Step 5: Configure Prometheus Data Source

1. In Grafana: Left sidebar → Connections → Data sources
2. Click "Add new data source"
3. Select Prometheus
4. URL: `http://prometheus-server:9090`
5. Click "Save & test"

### Step 6: Import Synology Dashboard

1. Download the dashboard JSON from the Marius Hosting guides
2. In Grafana: Left sidebar → Dashboards → New → Import
3. Upload the JSON file or paste its content
4. Select Prometheus as the data source
5. Click "Import"

## Network Configuration

Two isolated networks are created (see **`compose.yaml`** — this stack uses **`172.22.0.0/24`** and **`172.22.1.0/24`** with gateways **`172.22.0.1`** / **`172.22.1.1`**, aligned with **`docs/hive/NAS_DEPLOYMENT.md` → Docker network subnet registry**). **Do not** use **`192.168.x.x`** in compose for this fleet.

- `grafana-net`: Grafana ↔ Prometheus
- `prometheus-net`: All exporters and Watchtower

## Health Checks

All services include health checks. Verify they're running:

```bash
docker compose exec prometheus wget --no-verbose --tries=1 --spider http://localhost:9090/
docker compose exec grafana wget --no-verbose --tries=1 --spider http://localhost:3000/api/health
docker compose exec node-exporter wget --no-verbose --tries=1 --spider http://localhost:9100/
docker compose exec snmp-exporter wget --no-verbose --tries=1 --spider http://localhost:9116/
```

## Troubleshooting

### Containers not starting

```bash
docker compose logs -f
docker compose logs prometheus
docker compose logs grafana
```

### SNMP not collecting data

- Verify SNMP is enabled on your NAS
- Update `snmp.yml` with correct credentials
- Ensure NAS IP in `prometheus.yml` is correct
- Check firewall allows SNMP (port 161)

### Grafana plugins fail to install

Comment out the plugin line in docker-compose.yml:

```yaml
# GF_INSTALL_PLUGINS: grafana-clock-panel,grafana-simple-json-datasource,natel-discrete-panel,grafana-piechart-panel
```

### cAdvisor exits with error

Verify `/var/run/docker.sock` permissions. May need to run with different UID/GID or use privileged mode.

## Important Notes

⚠️ **Watchtower will automatically update containers**. This may cause issues if an update has bugs.
→ Always maintain backups using Hyper Backup.

⚠️ **Change the Watchtower API token** in `.env` to something secure before production use.

📝 **Memory usage** is controlled with `mem_limit` and `mem_reservation` to prevent resource exhaustion.

🔄 **Update schedule** can be modified in `.env` (`WATCHTOWER_SCHEDULE`) using cron format.

## Useful Commands

```bash
# Start stack
docker compose up -d

# Stop stack
docker compose down

# View logs
docker compose logs -f

# Restart a service
docker compose restart prometheus

# Update all images
docker compose pull
docker compose up -d

# Clean up unused data
docker compose exec prometheus /bin/prometheus --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=60d
```

## Resource Requirements

| Service       | CPU   | Memory |
| ------------- | ----- | ------ |
| Grafana       | 512   | 512MB  |
| Prometheus    | 768   | 1GB    |
| Node Exporter | 512   | 256MB  |
| SNMP Exporter | 512   | 256MB  |
| cAdvisor      | 512   | 256MB  |
| Watchtower    | 256   | 128MB  |
| **Total**     | ~3600 | ~2.5GB |

Adjust `cpu_shares` and `mem_limit` based on your NAS capabilities.

## References

- Grafana: https://grafana.com/
- Prometheus: https://prometheus.io/
- Node Exporter: https://github.com/prometheus/node_exporter
- SNMP Exporter: https://github.com/prometheus/snmp_exporter
- cAdvisor: https://github.com/google/cadvisor
- Watchtower: https://containrrr.dev/watchtower/
- Original guides: https://mariushosting.com/
