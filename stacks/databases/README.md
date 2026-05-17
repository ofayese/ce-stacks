# databases -- REMOVED (migrated to Synology native packages)

This stack has been retired. MariaDB and PostgreSQL are now managed as Synology
native packages via DSM Package Center, following the same platform-lifecycle
principle established for HAProxy.

## Migration summary

| Service    | Was                              | Now                                     |
|------------|----------------------------------|-----------------------------------------|
| MariaDB    | `mariadb:11.4.10` container      | Synology MariaDB package (DSM)          |
| PostgreSQL | `postgres:16-alpine` container   | Synology PostgreSQL package (DSM)       |
| Redis      | Not in this stack                | Valkey 8 sidecar in `stacks/searxng/`  |
| Adminer    | Container (db-net DNS)           | `stacks/db-tools/` -> `10.0.1.15:8895` |
| PhpMyAdmin | Not in this stack                | `stacks/db-tools/` -> `10.0.1.15:8378` |

## Why native packages

**Platform lifecycle** -- Synology services with their own package lifecycle work
best when DSM owns the start/stop/restart cycle (same principle as HAProxy).
Direct Docker management of services that have a native Synology equivalent
creates state mismatches and prevents Hyper Backup integration.

**Hyper Backup integration** -- DSM can snapshot database data natively; no
manual dump scripts required.

**Lower overhead** -- database processes run directly on the NAS kernel without
a container shim layer.

## Stack-specific databases are NOT affected

`stacks/zabbix/` has its own PostgreSQL 15 sidecar and `stacks/searxng/` has
its own Valkey 8 sidecar. These remain containerized because they are tightly
coupled to their stack's `depends_on: service_healthy` chain.

## Native package connection details

| Database   | Host      | Port |
|------------|-----------|------|
| MariaDB    | 10.0.1.15 | 3306 |
| PostgreSQL | 10.0.1.15 | 5432 |

Install via DSM -> Package Center -> search "MariaDB" / "PostgreSQL" (SynoCommunity).

## Data migration (if data exists in containers)

```bash
# 1. Export before stopping containers
docker exec MariaDB mysqldump -u root -p --all-databases > all_dbs_mariadb.sql
docker exec PostgreSQL pg_dumpall -U appuser > all_dbs_postgres.sql

# 2. Import into native packages after install
mysql -h 10.0.1.15 -u root -p < all_dbs_mariadb.sql
psql -h 10.0.1.15 -U postgres < all_dbs_postgres.sql

# 3. Stop and remove old containers
docker compose -f /volume2/docker/ce-stacks/stacks/databases/compose.yaml down -v
```

## GUI tools

See `stacks/db-tools/` -- Adminer and PhpMyAdmin, both pointing at native
package databases on `10.0.1.15`.
