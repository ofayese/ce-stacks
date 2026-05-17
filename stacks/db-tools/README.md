# db-tools

Lightweight database administration UI for the Synology DS723+ native package databases.

## Services

| Container | Image | Port | Purpose |
|-----------|-------|------|---------|
| `Adminer` | `adminer:5.4.2-standalone` | `10.0.1.15:8895` | Multi-DB admin UI (MariaDB + PostgreSQL) |

## Why Adminer only?

Adminer supports MariaDB, PostgreSQL, SQLite, and MongoDB in a single container. phpMyAdmin
(MySQL/MariaDB only) was removed — it's redundant with Adminer and caused a port conflict
with `code-server/CodeServerPMA` (port 8379), which is the correct home for a MySQL-focused
admin tool targeting the code-server dev database.

## Target databases

Both databases are Synology native packages — no Docker containers:

| Database   | Host       | Port |
|------------|------------|------|
| MariaDB    | 10.0.1.15  | 3306 |
| PostgreSQL | 10.0.1.15  | 5432 |

Install via DSM → Package Center → search "MariaDB" / "PostgreSQL" (SynoCommunity).

## Deploy

```bash
cp stacks/db-tools/.env.example stacks/db-tools/.env
# No data directories needed — stateless tool.
```

Deploy via Dockhand. Adminer is available immediately at `http://10.0.1.15:8895`.

At the Adminer login screen:
- **System**: MySQL (for MariaDB) or PostgreSQL
- **Server**: `10.0.1.15`
- **Username**: your DSM database user
- **Password**: your DSM database password

## Related

- `stacks/code-server` — contains `CodeServerPMA` (phpMyAdmin for the code-server MySQL sidecar on port 8379)
- `stacks/databases/README.md` — documents the migration from containerised MariaDB/PostgreSQL to native packages
