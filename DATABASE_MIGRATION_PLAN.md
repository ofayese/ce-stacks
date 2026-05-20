# Database Migration Plan: Tier 1 & 2 Stacks to Shared NAS MariaDB

**Target:** Consolidate Zabbix, Code-Server, SearXNG, and Remotely onto `10.0.1.15:3306` (shared NAS MariaDB)
**Benefits:**
- Free ~768MB (Zabbix PostgreSQL) + ~1GB (Code-Server MySQL) = ~1.8GB RAM
- Single database endpoint for all state
- Simplified backups (one MariaDB instance vs. multiple container DBs)
- HA-ready (MariaDB already running on NAS host)

---

## Phase 1: Pre-Migration Validation

### 1.1 Verify NAS MariaDB is Ready
```bash
# SSH to NAS
ssh admin@10.0.1.15

# Check MariaDB is running and accessible
mysql -h 10.0.1.15 -u root -p -e "SELECT VERSION();"

# Create migration database user (if not exists)
mysql -h 10.0.1.15 -u root -p -e "
  CREATE USER IF NOT EXISTS 'stack-user'@'%' IDENTIFIED BY 'strong-password-here';
  GRANT ALL PRIVILEGES ON *.* TO 'stack-user'@'%';
  FLUSH PRIVILEGES;
"
```

### 1.2 Create Databases for Each Stack
```bash
mysql -h 10.0.1.15 -u stack-user -p -e "
  CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE DATABASE IF NOT EXISTS code_server CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE DATABASE IF NOT EXISTS searxng CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE DATABASE IF NOT EXISTS remotely CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
"
```

---

## Phase 2: Zabbix Migration (PostgreSQL → MariaDB)

### 2.1 Export Current Zabbix Data
```bash
# SSH to NAS, enter zabbix stack
cd /volume2/docker/ce-stacks/stacks/zabbix

# Dump current PostgreSQL database
docker exec Zabbix-Postgres pg_dump -U zabbix zabbix > zabbix_postgres_backup.sql

# Backup Zabbix data volume (historical data, configurations)
sudo tar -czf zabbix_data_backup.tar.gz /volume2/docker/ce-stacks/stacks/zabbix/data
```

### 2.2 Import Zabbix Schema to MariaDB
```bash
# Zabbix provides MySQL schema files
# Option A: Use Zabbix's official MySQL init script
mysql -h 10.0.1.15 -u stack-user -p zabbix < /path/to/zabbix/create_mysql.sql

# Option B: Migrate PostgreSQL dump to MySQL (requires pg2mysql tool or manual conversion)
# PostgreSQL syntax differs from MySQL (SERIAL, specific functions)
# Recommend: Start with fresh Zabbix MySQL schema, then re-add historical data

# Initialize fresh Zabbix MySQL database
mysql -h 10.0.1.15 -u stack-user -p zabbix -e "
  -- Zabbix will auto-initialize on first web UI access
  -- Or download schema from: https://github.com/zabbix/zabbix/tree/master/database
"
```

### 2.3 Update Zabbix Compose
**File:** `stacks/zabbix/compose.yaml`

Remove the `postgres:` service entirely, update `zabbix-server:` and `zabbix-web:`:

```yaml
  zabbix-server:
    container_name: Zabbix-Server
    image: zabbix/zabbix-server-mysql:alpine-7.4.10  # Changed from -pgsql
    environment:
      - DB_SERVER_HOST=10.0.1.15
      - DB_SERVER_PORT=3306
      - MYSQL_DATABASE=zabbix
      - MYSQL_USER=${ZABBIX_DB_USER}
      - MYSQL_PASSWORD=${ZABBIX_DB_PASSWORD}
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
    depends_on: []  # Remove postgres dependency

  zabbix-web:
    container_name: Zabbix-Web
    image: zabbix/zabbix-web-nginx-mysql:alpine-7.4.10  # Changed from -pgsql
    environment:
      - DB_SERVER_HOST=10.0.1.15
      - DB_SERVER_PORT=3306
      - MYSQL_DATABASE=zabbix
      - MYSQL_USER=${ZABBIX_DB_USER}
      - MYSQL_PASSWORD=${ZABBIX_DB_PASSWORD}
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
```

### 2.4 Update Zabbix .env
**File:** `stacks/zabbix/.env`

```env
# Remove POSTGRES_* variables, add:
MYSQL_ROOT_PASSWORD=<your-root-password>
ZABBIX_DB_USER=zabbix
ZABBIX_DB_PASSWORD=<your-zabbix-user-password>
ZABBIX_SERVER_PORT=10051
ZABBIX_WEB_PORT=8532
ZBX_HOSTNAME=zabbix-agent
```

### 2.5 Deploy & Verify
```bash
cd /volume2/docker/ce-stacks/stacks/zabbix
docker compose down
# Delete old PostgreSQL volume to force clean start
sudo rm -rf /volume2/docker/ce-stacks/stacks/zabbix/db
docker compose up -d

# Watch logs for successful connection
docker logs -f Zabbix-Server
docker logs -f Zabbix-Web

# Verify web UI is accessible: http://10.0.1.15:8532
# Log in with default admin/zabbix credentials
```

---

## Phase 3: Code-Server Migration (Internal MySQL → Shared MariaDB)

### 3.1 Export Current Code-Server Database
```bash
cd /volume2/docker/ce-stacks/stacks/code-server

# Dump internal MySQL database
docker exec CodeServerDB mysqldump -uroot -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} > code_server_backup.sql

# Backup the workspace volumes
sudo tar -czf code_server_config_backup.tar.gz /volume2/docker/ce-stacks/stacks/code-server/config
```

### 3.2 Import to Shared MariaDB
```bash
# Import code-server database schema and data
mysql -h 10.0.1.15 -u stack-user -p code_server < code_server_backup.sql

# Verify tables imported
mysql -h 10.0.1.15 -u stack-user -p code_server -e "SHOW TABLES;"
```

### 3.3 Update Code-Server Compose
**File:** `stacks/code-server/compose.yaml`

Remove the `db:` service entirely, update `code-server:` environment:

```yaml
services:
  code-server:
    # ... existing config ...
    environment:
      # Add database connection (code-server uses environment for DB config)
      - DATABASE_URL=mysql://code_user:password@10.0.1.15:3306/code_server
      # ... other vars ...

  # Remove db: service entirely
  # Remove phpmyadmin: service (can access via db-tools stack instead)
```

### 3.4 Update Code-Server .env
**File:** `stacks/code-server/.env`

```env
MYSQL_ROOT_PASSWORD=<your-root-password>
MYSQL_DATABASE=code_server
MYSQL_USER=code_user
MYSQL_PASSWORD=<code-server-user-password>
PMA_CONTROLUSER=pma_user
PMA_CONTROLPASS=<phpmyadmin-password>
```

### 3.5 Deploy & Verify
```bash
cd /volume2/docker/ce-stacks/stacks/code-server
docker compose down
# Keep volumes (code-server config, workspace)
sudo rm -rf /volume2/docker/ce-stacks/stacks/code-server/data  # Only remove old DB data

docker compose up -d

# Verify code-server is accessible: https://10.0.1.15:8377
# Verify workspace and settings persist
```

---

## Phase 4: SearXNG Optional MariaDB (New Setup)

### 4.1 Create SearXNG Database
```bash
mysql -h 10.0.1.15 -u stack-user -p -e "
  CREATE DATABASE IF NOT EXISTS searxng CHARACTER SET utf8mb4;
  CREATE USER 'searxng_user'@'%' IDENTIFIED BY 'searxng-password';
  GRANT ALL ON searxng.* TO 'searxng_user'@'%';
  FLUSH PRIVILEGES;
"
```

### 4.2 Update SearXNG Compose
**File:** `stacks/searxng/compose.yaml`

Add environment variables to enable MariaDB caching:

```yaml
  searxng:
    # ... existing config ...
    environment:
      # ... existing vars ...
      - SEARXNG_DB_URL=mysql+pymysql://searxng_user:searxng-password@10.0.1.15:3306/searxng
      - SEARXNG_CACHE=mysql
```

### 4.3 Deploy
```bash
cd /volume2/docker/ce-stacks/stacks/searxng
docker compose up -d

# Verify SearXNG is accessible and caching to MariaDB
```

---

## Phase 5: Remotely Optional MariaDB (New Setup)

### 5.1 Create Remotely Database
```bash
mysql -h 10.0.1.15 -u stack-user -p -e "
  CREATE DATABASE IF NOT EXISTS remotely CHARACTER SET utf8mb4;
  CREATE USER 'remotely_user'@'%' IDENTIFIED BY 'remotely-password';
  GRANT ALL ON remotely.* TO 'remotely_user'@'%';
  FLUSH PRIVILEGES;
"
```

### 5.2 Check Remotely Compose for DB Support
```bash
cd /volume2/docker/ce-stacks/stacks/remotely
grep -i "database\|mysql\|postgres" compose.yaml
```

If Remotely supports databases:

### 5.3 Update Remotely Compose
```yaml
  remotely:
    # ... existing config ...
    environment:
      # ... existing vars ...
      - DATABASE_URL=mysql://remotely_user:remotely-password@10.0.1.15:3306/remotely
```

### 5.4 Deploy
```bash
cd /volume2/docker/ce-stacks/stacks/remotely
docker compose up -d
```

---

## Phase 6: Post-Migration Validation

### 6.1 Verify All Connections
```bash
# Check each stack's logs for database connection success
docker logs Zabbix-Server | grep -i "database\|connected"
docker logs CodeServer | grep -i "database\|connected"
docker logs searxng | grep -i "database\|cache"
docker logs remotely | grep -i "database\|connected"
```

### 6.2 Test Functionality
- **Zabbix:** Verify agents still report metrics, dashboards load
- **Code-Server:** Create a file, restart container, verify it persists
- **SearXNG:** Search and verify results cache between requests
- **Remotely:** Create session, verify it persists

### 6.3 Monitor Resource Usage
```bash
docker stats --no-stream
# Should show ~1.8GB freed from removed Postgres + internal MySQL containers
```

### 6.4 Update Git
```bash
cd /volume2/docker/ce-stacks
git add stacks/zabbix/compose.yaml stacks/zabbix/.env
git add stacks/code-server/compose.yaml stacks/code-server/.env
git add stacks/searxng/compose.yaml stacks/searxng/.env
git add stacks/remotely/compose.yaml stacks/remotely/.env

git commit -m "feat: migrate Tier 1/2 stacks to shared NAS MariaDB

- Zabbix: PostgreSQL → MySQL (10.0.1.15:3306)
- Code-Server: Internal MySQL sidecar → shared MariaDB
- SearXNG: Added MariaDB backing for result caching
- Remotely: Added MariaDB backing for session persistence
- Frees ~1.8GB RAM on DS723+ (removes internal DB containers)
- Consolidates all application state into single NAS database"
```

---

## Phase 7: Cleanup & Rollback Plan

### 7.1 If Migration Fails
Each backup can be restored:
```bash
# Restore Zabbix from PostgreSQL dump (requires pg2mysql)
# Restore Code-Server from MySQL dump
mysql code_server < code_server_backup.sql
```

### 7.2 Clean Old Volumes (After Validation)
```bash
docker volume rm code-server_mysql_data
docker volume rm zabbix_postgres_db
```

---

## Summary

| Stack | Action | RAM Freed | Priority |
|-------|--------|-----------|----------|
| **Zabbix** | PostgreSQL → MySQL | ~768MB | TIER 1 |
| **Code-Server** | MySQL sidecar → shared | ~1GB | TIER 1 |
| **SearXNG** | Add MySQL caching | 0 (optional) | TIER 2 |
| **Remotely** | Add MySQL persistence | 0 (optional) | TIER 2 |
| **TOTAL** | Consolidate 4 stacks | **~1.8GB** | — |

**Estimated Duration:** 1-2 hours (mostly waiting for Zabbix to initialize)
**Risk Level:** Low (all changes are reversible with backups)
