# Native DSM Redis — Reference Config

Redis is installed as a **native Synology DSM package**, not a Docker container.

| Property | Value |
|---|---|
| Package | Redis (SynoCommunity or Synology) |
| Config path | `/var/packages/redis/var/redis.conf` |
| Data path | `/volume1/@appdata/redis` |
| PID file | `/var/packages/redis/var/redis.pid` |
| Log file | `/var/packages/redis/var/redis.log` |
| Default port | `6379` |
| Bind | `0.0.0.0` (all interfaces) |
| Auth | None — **LAN-only, protected-mode disabled** (see below) |

## Why `protected-mode no`

Redis ships with `protected-mode yes`. When the default user has **no password** (which
is the case here — `user default on nopass`), protected-mode restricts connections to
**loopback only** (`127.0.0.1` / `::1`). This silently blocks every Docker bridge
container (`172.16.0.0/12`) from reaching Redis even though `bind 0.0.0.0` is set.

This NAS is **not directly internet-exposed** — it sits behind a router with no inbound
port-forwarding to 6379. Setting `protected-mode no` is the correct fix for a private LAN.

If the NAS were ever directly internet-exposed, you would set `requirepass <strong-password>`
instead and update all consumer stacks.

## Key Settings (non-default)

See `redis.conf` in this directory. The settings that differ from Redis defaults are:

| Setting | Value | Reason |
|---|---|---|
| `bind` | `0.0.0.0` | Listen on all interfaces (LAN + Docker bridge) |
| `protected-mode` | `no` | Allow Docker containers on `172.x.x.x` to connect |
| `maxmemory` | `512mb` | Cap Redis at 512 MB on the 32 GB NAS |
| `maxmemory-policy` | `allkeys-lru` | Evict LRU keys when limit hit (cache workload) |
| `daemonize` | `yes` | Native DSM service (not a container) |
| `loglevel` | `notice` | Production verbosity |
| `databases` | `16` | DSM default |
| `save` | `""` (disabled) | Eliminates unnecessary disk I/O for cache workload |
| `appendonly` | `no` | AOF off; Redis here is a cache, not a durable store |

## Applying Changes

```bash
# 1. Edit the live config
sudo vi /var/packages/redis/var/redis.conf

# 2. Apply the two key changes from this reference:
#    protected-mode no
#    maxmemory 512mb
#    maxmemory-policy allkeys-lru

# 3. Restart via DSM package manager
sudo synopkg stop redis
sudo synopkg start redis

# 4. Verify
redis-cli -h 127.0.0.1 ping          # Should return PONG
redis-cli -h 10.0.1.15 ping          # Should return PONG (LAN IP)
redis-cli info memory | grep used_memory_human
```

## Prometheus Monitoring

Redis metrics are exposed via `redis_exporter` in the `grafana-prom` stack
(`stacks/grafana-prom/compose.yaml`), which scrapes `10.0.1.15:6379` and translates
`INFO` output to Prometheus format on port `9121`.

> **Note:** Pointing a Prometheus scrape job *directly* at port `6379` does **not** work —
> Prometheus speaks HTTP and Redis speaks its own wire protocol. Always scrape the exporter.

## Consumers

| Stack | Connection | Notes |
|---|---|---|
| `grafana-prom` | `redis_exporter` service → `10.0.1.15:6379` | Metrics only |
| DSM packages (SSO, etc.) | `127.0.0.1:6379` | Native DSM internal use |

The `searxng` stack runs its **own Valkey sidecar** (`SearXNG-Redis`) and does **not**
use the native DSM Redis instance.
