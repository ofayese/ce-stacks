# Dockhand Directory Structure & File Locations

**Updated**: 2026-05-13
**Structure**: New organized layout with `scripts/` and `docs/` subdirectories

---

## Directory Layout

```
ce-stacks/dockhand/           <- Git-tracked reference (ce-stacks root)
+--- README.md                 <- Overview of Dockhand
+--- STRUCTURE.md              <- This file: directory layout & path map
+--- APPLY_HEALTH_CHECK_FIX.sh <- Automated health check fix script
+--- CHECKLIST.sh              <- Interactive migration checklist
+--- compose.yaml              <- Docker Compose definition
+--- .env.example              <- Environment variable template
|
+--- scripts/                  <- Executable scripts
|   +--- dockhand-start.sh     <- RC startup script (install to /usr/local/etc/rc.d/)
|   +--- dockhand-validate.sh  <- Validation & compliance testing
|   +--- dockhand-migration.sh <- Migration preparation script
|   +--- health-check-fix.sh   <- Diagnostic script for health checks
|
+--- docs/                     <- Documentation
    +--- DEPLOYMENT.md         <- How to copy & deploy to NAS
    +--- MIGRATION.md          <- 5-step migration guide
    +--- HEALTH_CHECK_SOLUTION.md    <- Health check issue & fix
    +--- HEALTH_CHECK_FIX.md         <- Detailed health check analysis
    +--- HEALTH_CHECK_DEBUG.md       <- Comprehensive troubleshooting
```

---

## On the NAS (/volume2/docker/dockhand/)

After copying from the repo, the NAS will have the same structure:

```
/volume2/docker/dockhand/     <- Runtime deployment on NAS
+--- README.md
+--- STRUCTURE.md
+--- APPLY_HEALTH_CHECK_FIX.sh
+--- CHECKLIST.sh
+--- compose.yaml
+--- .env.example
+--- db/                       <- Dockhand database (auto-created)
+--- stacks/                   <- Imported stacks metadata (auto-created)
+--- git-repos/                <- Cloned repos (auto-created)
|
+--- scripts/
|   +--- dockhand-start.sh
|   +--- dockhand-validate.sh
|   +--- dockhand-migration.sh
|   +--- health-check-fix.sh
|
+--- docs/
    +--- DEPLOYMENT.md
    +--- MIGRATION.md
    +--- HEALTH_CHECK_SOLUTION.md
    +--- HEALTH_CHECK_FIX.md
    +--- HEALTH_CHECK_DEBUG.md
```

---

## File Locations & Usage

| File | Git Path | NAS Path | Purpose | Used When |
|------|----------|----------|---------|-----------|
| **dockhand-start.sh** | `dockhand/scripts/` | `/usr/local/etc/rc.d/dockhand.sh` | RC startup script | DSM boot/manual restart |
| **compose.yaml** | `dockhand/` | `/volume2/docker/dockhand/` | Service definition | Reference/deployment |
| **README.md** | `dockhand/` | `/volume2/docker/dockhand/` | Setup guide | Initial setup |
| **DEPLOYMENT.md** | `dockhand/docs/` | `/volume2/docker/dockhand/docs/` | Deploy instructions | First-time copy to NAS |
| **MIGRATION.md** | `dockhand/docs/` | `/volume2/docker/dockhand/docs/` | 5-step guide | Stack import workflow |
| **HEALTH_CHECK_SOLUTION.md** | `dockhand/docs/` | `/volume2/docker/dockhand/docs/` | Health check fix | Unhealthy container |
| **dockhand-validate.sh** | `dockhand/scripts/` | `/volume2/docker/dockhand/scripts/` | Validation | Post-deployment testing |
| **health-check-fix.sh** | `dockhand/scripts/` | `/volume2/docker/dockhand/scripts/` | Diagnostic script | Troubleshooting health |
| **APPLY_HEALTH_CHECK_FIX.sh** | `dockhand/` | `/volume2/docker/dockhand/` | Automated fix | Fix unhealthy status |

---

## Quick Reference: On NAS

### Health Check Issues

```bash
# Run automated fix
bash /volume2/docker/dockhand/APPLY_HEALTH_CHECK_FIX.sh

# Or run diagnostic
bash /volume2/docker/dockhand/scripts/health-check-fix.sh

# Or read troubleshooting
cat /volume2/docker/dockhand/docs/HEALTH_CHECK_DEBUG.md
```

### Validation After Deploy

```bash
bash /volume2/docker/dockhand/scripts/dockhand-validate.sh
```

### Stack Migration

```bash
cat /volume2/docker/dockhand/docs/MIGRATION.md
# Then follow 5 steps
```

### Initial Deployment

```bash
# Copy from repo
cp -r /volume2/docker/ce-stacks/dockhand /volume2/docker/dockhand

# Install RC script
sudo cp /volume2/docker/dockhand/scripts/dockhand-start.sh /usr/local/etc/rc.d/dockhand.sh
sudo chmod +x /usr/local/etc/rc.d/dockhand.sh

# Start
sudo /usr/local/etc/rc.d/dockhand.sh
```

---

## In the Git Repo (ce-stacks/dockhand/)

### Documentation Hierarchy

1. **README.md** - Start here for overview
2. **docs/DEPLOYMENT.md** - How to copy to NAS
3. **docs/MIGRATION.md** - How to migrate stacks
4. **docs/HEALTH_CHECK_*.md** - Troubleshooting

### Scripts (in scripts/)

- `dockhand-start.sh` - Needs to be copied to `/usr/local/etc/rc.d/`
- `dockhand-validate.sh` - Run on NAS to validate setup
- `dockhand-migration.sh` - Prepare for migration
- `health-check-fix.sh` - Diagnose health issues

### Root-level Tools

- `APPLY_HEALTH_CHECK_FIX.sh` - Automated health fix (run on NAS)
- `CHECKLIST.sh` - Track migration progress (run on NAS)

---

## Path Updates Made

All scripts now reference `/volume2/docker/dockhand/` when deployed, not relative ce-stacks paths:

[OK] `dockhand-start.sh` - Updated source path in header comment
[OK] `APPLY_HEALTH_CHECK_FIX.sh` - Uses `/volume2/docker/dockhand/scripts/` paths
[OK] `docs/DEPLOYMENT.md` - References new `scripts/` subdirectory
[OK] `docs/MIGRATION.md` - References `/volume2/docker/dockhand/scripts/`
[OK] `docs/HEALTH_CHECK_FIX.md` - References new paths
[OK] `docs/HEALTH_CHECK_SOLUTION.md` - Updated references

---

## Symlink on RC System

After installing RC script on NAS:

```
/usr/local/etc/rc.d/dockhand.sh -> symlink to /volume2/docker/dockhand/scripts/dockhand-start.sh
```

(Or copy if symlinks not preferred on DSM)

---

## Key Principles

1. **Git repo is reference**: `ce-stacks/dockhand/` is source of truth for versioning
2. **NAS is runtime**: `/volume2/docker/dockhand/` runs the actual container
3. **Scripts are portable**: All scripts work when copied to NAS
4. **Paths are absolute**: No relative paths that break on NAS
5. **Docs are discoverable**: README -> DEPLOYMENT -> MIGRATION -> HEALTH_CHECK_*

---

## For Future Updates

When updating files:

1. Update in `ce-stacks/dockhand/` (git repo)
2. Push to GitHub
3. On NAS: `cd /volume2/docker && cp -r ce-stacks/dockhand/* dockhand/`
4. Re-apply RC script if needed: `sudo /usr/local/etc/rc.d/dockhand.sh`

---

## Support

- **Initial setup**: Read `dockhand/docs/DEPLOYMENT.md`
- **Migration**: Follow `dockhand/docs/MIGRATION.md`
- **Health issues**: See `dockhand/docs/HEALTH_CHECK_DEBUG.md`
- **Quick fix**: Run `bash /volume2/docker/dockhand/APPLY_HEALTH_CHECK_FIX.sh`
