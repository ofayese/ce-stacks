# influxdb — Time-Series Database for ntopng

InfluxDB 1.8.10 is deployed as the time-series backend for ntopng network traffic metrics.
Grafana queries it directly as a second datasource alongside Prometheus.

## Data Flow

```
ntopng (native NAS package, port 3000)
    │  writes via InfluxDB line protocol
    ▼
InfluxDB 1.8.10 (container, 10.0.1.15:8086)
    │  queried by proxy datasource
    ▼
Grafana (container, 10.0.1.15:3340)
```

## First-time Setup

### 1. Create the data directory and environment file

```bash
cd /volume2/docker/ce-stacks/stacks/influxdb
mkdir -p data
cp .env.example .env
# Edit .env — fill in all passwords before starting the container
```

### 2. Start InfluxDB

```bash
docker compose up -d
# Verify health
docker inspect --format='{{.State.Health.Status}}' InfluxDB
# Expected: healthy (allow ~30s start_period)
```

InfluxDB creates the `ntopng` database, the `ntopng` write-only user, and the `grafana`
read-only user automatically on first start from the env vars in compose.yaml.

### 3. Configure ntopng to export to InfluxDB

In the ntopng DSM package web UI (`http://10.0.1.15:3000`):

1. Go to **Settings → Timeseries → Driver** → select **InfluxDB**
2. Set the following:

   | Field     | Value                             |
   |-----------|-----------------------------------|
   | Host      | `10.0.1.15`                       |
   | Port      | `8086`                            |
   | Database  | `ntopng`  *(must match INFLUXDB_DATABASE in .env)* |
   | User      | `ntopng`                          |
   | Password  | value of `INFLUXDB_NTOPNG_PASSWORD` from .env |

3. Click **Save** — ntopng will start writing flow metrics immediately.

### 4. Verify data is flowing

```bash
# Query the ntopng database (replace passwords)
docker exec -it InfluxDB influx \
  -username admin -password <INFLUXDB_ADMIN_PASSWORD> \
  -database ntopng \
  -execute "SHOW MEASUREMENTS"
# Should list ntopng measurement series after ~1 minute of traffic
```

### 5. Grafana datasource

The `grafana-prom` stack auto-provisions an InfluxDB datasource on Grafana startup
(`provisioning/datasources/influxdb.yml`). No manual Grafana UI steps are required,
but Grafana needs `INFLUXDB_GRAFANA_PASSWORD` in its environment — see
`stacks/grafana-prom/.env.example`.

## Ports

| Port | Protocol | Purpose                     |
|------|----------|-----------------------------|
| 8086 | HTTP     | InfluxDB API (read + write) |

Port 8086 is not routed through HAProxy — it is an internal data store only.

## Users Created on First Start

| Username | Permission  | Consumer                   |
|----------|-------------|----------------------------|
| admin    | Admin       | Management / CLI only      |
| ntopng   | Write (DB)  | ntopng export              |
| grafana  | Read (DB)   | Grafana datasource         |

## Changing Passwords After First Start

InfluxDB 1.8 ignores env vars after initial database creation. Use the CLI:

```bash
docker exec -it InfluxDB influx \
  -username admin -password <current-password> \
  -execute "SET PASSWORD FOR ntopng = '<new-password>'"
```

## Maintenance

```bash
# Check disk usage
du -sh /volume2/docker/ce-stacks/stacks/influxdb/data/

# View logs
docker logs InfluxDB --tail 50

# Manual backup
docker exec InfluxDB influxd backup -portable /tmp/backup
docker cp InfluxDB:/tmp/backup ./backup-$(date +%Y%m%d)
```

## Related

- `stacks/grafana-prom/` — Grafana + Prometheus stack
- `stacks/grafana-prom/provisioning/datasources/influxdb.yml` — auto-provisioned datasource
- ntopng SynoCommunity package — Settings → Timeseries → InfluxDB
