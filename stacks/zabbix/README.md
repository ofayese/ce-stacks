# Zabbix (server + web + PostgreSQL)

## Purpose

Network and host monitoring with Zabbix Server (PostgreSQL), nginx web frontend, and optional Agent 2. SNMPv3 on Synology DSM is the typical path for NAS metrics (see proposal).

## Ports

| Port                                     | Service                                    |
| ---------------------------------------- | ------------------------------------------ |
| `${ZABBIX_WEB_PORT:-8532}` (host)        | Zabbix web (HTTP inside container on 8080) |
| `${ZABBIX_SERVER_PUBLISH:-10051}` (host) | Zabbix server (trapper)                    |

## Environment

Copy `.env.example` to `.env` and set `POSTGRES_PASSWORD` to a strong value. `STACK_ROOT` is normally written by `scripts/init-nas.sh` at repo root.

## Volumes

| Host path                     | Container path             | Mode | Created by    |
| ----------------------------- | -------------------------- | ---- | ------------- |
| `${STACK_ROOT}/zabbix/db`     | `/var/lib/postgresql/data` | rw   | `init-nas.sh` |
| `${STACK_ROOT}/zabbix/data`   | `/var/lib/zabbix`          | rw   | `init-nas.sh` |
| `${STACK_ROOT}/zabbix/config` | `/etc/zabbix`              | rw   | `init-nas.sh` |

> Run `sudo bash scripts/init-nas.sh` after cloning to create these
> directories. Without them, the container will fail to start.

## Dependencies

- Docker Compose (Dockge) on Synology or generic Linux host.
- Outbound HTTPS for image pulls.

## Startup order

**Postgres → zabbix-server → zabbix-web** via **`condition: service_healthy`**. After `git pull`, use **`docker compose up -d`** from this directory; see **`docs/hive/NAS_DEPLOYMENT.md`** → **Dockge stack lifecycle (Compose v2)** for NAS steps and timing.

## Health

- Postgres: `pg_isready` against `POSTGRES_USER` / `POSTGRES_DB`.
- Server: `zabbix_server -R diaginfo`.
- Web: `curl -f http://localhost:8080/ping`.

## Rollback

`docker compose down` in this stack directory; data remains on `${STACK_ROOT}/zabbix/*` until deleted.

## Watchtower

Label `com.centurylinklabs.watchtower.enable=true` on long-running services. Pin or digest-upgrade Zabbix images deliberately in production.

## Security

- No Docker socket mount.
- Replace default DB password before exposing the UI.
- Restrict `10051` / web port at the firewall if the UI is fronted by a reverse proxy.

## Operator notes

- Default Zabbix UI login after first boot: **Admin** / **zabbix** — change immediately.
- For Synology SNMPv3 + community template steps, see `docs/hive/proposals/zabbix/proposal.md`.

## SNMPv3 (NAS hardware — no agent)

Synology **SNMPv3** + the DiskStation template is the primary path for NAS disks, RAID, temperature, fans, UPS, network, and volume usage. Zabbix Server **polls UDP 161** on the NAS. See the proposal doc for DSM steps.

## Agent options

### What SNMPv3 already covers (no agent needed)

The Synology DiskStation SNMPv3 template monitors disk health, RAID/storage pool status, volume usage, temperature, fan speeds, UPS status, network interface throughput, and system uptime. **No agent is installed on the NAS** for this path.

### How the native agent reaches the Zabbix Server container

The **zabbix-server** service publishes port **10051** on the NAS host. Any agent running **natively on DSM** can reach the server at:

- **`127.0.0.1:10051`** — active checks (agent pushes toward the server / trapper).
- **`127.0.0.1:10050`** — passive checks (server polls the agent on the NAS), once the native agent listens on 10050.

No Docker network membership is required for the native agent.

### Passive vs active checks

- **Passive:** Zabbix Server connects to the agent on **10050** and pulls items on demand.
- **Active:** The agent connects to the server on **10051** and pushes on its schedule (common for log/OS templates).

Both can be used together.

### Option 1 — SynoCommunity Zabbix Agent (recommended for OS-level)

Installs on DSM. Adds process monitoring, log tails, and custom user parameters that SNMP does not cover. Reports to the **same** Zabbix Server container on this NAS.

#### Before you start — NAS hostname

The agent should use **dynamic hostname detection** (`HostnameItem=system.hostname`) so the reported name matches DSM. You need that exact string for the **Host name** field in Zabbix UI.

```bash
ssh <user>@<nas-ip>
hostname
# Note the output exactly (example: orundscore)
```

After initial setup, if DSM is renamed the agent picks up the new hostname automatically on the next agent restart. Update the Zabbix UI **Host name** field to match when that happens.

#### Installation

1. Add SynoCommunity to Package Center (if needed).
2. Install **Zabbix Agent**.
3. Edit `/var/packages/zabbix-agent/target/etc/zabbix_agentd.conf` (path may vary by package version):

   ```text
   # Passive — server polls this agent
   Server=127.0.0.1

   # Active — agent connects to Zabbix Server container (port required)
   ServerActive=127.0.0.1:10051

   # Dynamic hostname — do NOT also set Hostname= (Hostname wins and disables HostnameItem)
   HostnameItem=system.hostname

   RefreshActiveChecks=120
   ```

4. Restart the Zabbix Agent service in Package Center.

#### Zabbix UI

5. **Configuration → Hosts → Create host**

   - **Host name:** must match `hostname` on the NAS **byte-for-byte**.
   - **Visible name:** any label you like.

6. **Interfaces:** add **SNMP** (NAS LAN IP, UDP **161**) if not already present from SNMPv3 setup; add **Agent** (**127.0.0.1**, **10050**).

7. **Templates:** link **Synology DiskStation SNMPv3** (hardware) and **Template OS Linux** (agent OS metrics).

#### Verify active checks

**Monitoring → Latest data** — active items show as **Zabbix agent (active)**. If items stay empty after a few minutes:

- Confirm **no** duplicate `Hostname=` line.
- Confirm UI **Host name** matches `hostname`.
- Confirm `zabbix-server` publishes **`10051:10051`** in `compose.yaml`.
- Inspect `/var/packages/zabbix-agent/target/var/zabbix_agentd.log` (path may vary).

### Option 2 — Docker Zabbix Agent2 (Docker metrics only)

The **`zabbix-agent2`** service is **commented out** in `compose.yaml`. Enable only if you need **per-container** CPU/memory/status in Zabbix. It does **not** replace SNMPv3 or the native agent for NAS health.

Uncomment only after reading the warnings in `compose.yaml` and documenting **privileged** mode in **`docs/hive/NAS_DEPLOYMENT.md`**.

### Monitoring architecture summary

| Goal                         | Method                      | Agent on NAS?   |
| ---------------------------- | --------------------------- | --------------- |
| Disks, RAID, temp, UPS, NICs | SNMPv3 template             | No              |
| Processes, logs, scripts     | SynoCommunity agent → 10051 | Yes (native)    |
| Docker container metrics     | Docker Agent2 (privileged)  | Yes (container) |

## Backup

| Directory                     | Hyper Backup      | Method                                                           |
| ----------------------------- | ----------------- | ---------------------------------------------------------------- |
| `${STACK_ROOT}/zabbix/data`   | Include           | File copy                                                        |
| `${STACK_ROOT}/zabbix/db`     | **Exclude**       | Postgres dump (see `docs/hive/NAS_DEPLOYMENT.md` → Hyper Backup) |
| `${STACK_ROOT}/zabbix/config` | Include (if used) | File copy                                                        |
