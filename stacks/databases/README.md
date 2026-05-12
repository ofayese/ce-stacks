# databases

MariaDB + PostgreSQL + Adminer for any service that needs a shared DB. Distinct from `code-server`'s embedded MySQL (which is project-local).

## Services

- **mariadb** — file-based secrets at `/run/secrets/{mariadb_root_pw,mariadb_app_pw}`
- **postgres** — file-based secret at `/run/secrets/postgres_pw`
- **adminer** (8895) — UI; depends on both DBs being healthy

## Startup order

**adminer** starts after **mariadb** and **postgres** are **healthy**. NAS operator flow: **`docs/hive/NAS_DEPLOYMENT.md`** → **Dockge stack lifecycle (Compose v2)**.

## Volumes

| Host path                             | Container path             | Mode | Created by    |
| ------------------------------------- | -------------------------- | ---- | ------------- |
| `${STACK_ROOT}/databases/db/mariadb`  | `/var/lib/mysql`           | rw   | `init-nas.sh` |
| `${STACK_ROOT}/databases/db/postgres` | `/var/lib/postgresql/data` | rw   | `init-nas.sh` |

> Run `sudo bash scripts/init-nas.sh` after cloning to create these
> directories. Without them, the container will fail to start.

## Secrets (file-based, outside `.env`)

Create **gitignored** files under `${STACK_ROOT}/databases/secrets/` (mode `0600`):

- `${STACK_ROOT}/databases/secrets/mariadb_root_pw.txt`
- `${STACK_ROOT}/databases/secrets/mariadb_app_pw.txt`
- `${STACK_ROOT}/databases/secrets/postgres_pw.txt`

Verify with:

```bash
ls -la "${STACK_ROOT}/databases/secrets/"
git check-ignore "${STACK_ROOT}/databases/secrets/mariadb_root_pw.txt"   # expect: prints path = ignored
```

If any file is mode `0644` or worse: `chmod 0600 "${STACK_ROOT}/databases/secrets/"*.txt`.

## Health

- mariadb: `healthcheck.sh --connect --innodb_initialized`
- postgres: `pg_isready -U appuser -d appdb`
- adminer: HTTP 200 on `/`

## Rollback

```bash
git checkout -- compose.yaml
docker compose up -d
```

Data persists under `${STACK_ROOT}/databases/db/`. Back up before any major-version bump.

## Troubleshooting

### PostgreSQL — `invalid record length ... got 0` during startup

After `database system was not properly shut down`, PostgreSQL replays WAL. A line like `invalid record length at ... expected at least 24, got 0` at the **end** of redo is normal (end of WAL segment). If you then see **`database system is ready to accept connections`**, no action is required.

### MariaDB — `Bad magic header in tc log` / `Can't init tc log`

The **transaction coordinator** file `tc.log` under the MariaDB datadir is corrupted, usually from an **unclean shutdown** (NAS reboot, `docker kill`, power loss). InnoDB may be fine; only `tc.log` needs replacing.

1. **Stop** MariaDB (stack stop is fine):

   ```bash
   docker stop MariaDB
   ```

2. **Rename or remove** the bad file on the host (bind mount: `${STACK_ROOT}/databases/db/mariadb`):

   ```bash
   ts="$(date +%Y%m%d%H%M%S)"
   mv "${STACK_ROOT}/databases/db/mariadb/tc.log" "${STACK_ROOT}/databases/db/mariadb/tc.log.corrupt.${ts}"
   ```

   If `tc.log` is missing after `mv`, that is acceptable.

3. **Start** MariaDB again; it will recreate `tc.log`:

   ```bash
   docker compose up -d mariadb
   ```

On the NAS, set `STACK_ROOT` to your real path (e.g. `/volume2/docker/ce-stacks/stacks`) or use the absolute path under `.../databases/db/mariadb/tc.log`.

**Note:** This is safe for typical app workloads. If you knowingly use **XA two-phase commit** across external resources, verify transaction consistency after recovery.

**Other log noise:** `io_uring_queue_init() failed with ENOSYS` — falls back to libaio; expected on some Synology kernels / Docker seccomp. `memory.pressure not writable` — cgroup v2 quirk; informational unless you tune memory.

## Backup

| Directory                    | Hyper Backup | Method                                                                                          |
| ---------------------------- | ------------ | ----------------------------------------------------------------------------------------------- |
| `${STACK_ROOT}/databases/db` | **Exclude**  | Database dumps (`docker exec` → vendor tools; see `docs/hive/NAS_DEPLOYMENT.md` → Hyper Backup) |

There is no separate app-level `data/` bind for this stack; engine files live under **`db/`** only.

## Out of scope

Backup strategy lives in `docs/hive/proposals/_backups/PROPOSAL.md` (queen-led).
