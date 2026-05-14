# Pre-Migration: Copy dockhand/ to /volume2/docker/dockhand/

This directory is designed to be copied to `/volume2/docker/dockhand/` on your Synology NAS.

## What is this?

**dockhand/** is a **reference directory** at the root of your ce-stacks git repository. It contains:

- `dockhand-start.sh` - RC startup script for DSM
- `MIGRATION.md` - Complete migration guide
- `dockhand-validate.sh` - Validation script
- `dockhand-migration.sh` - Migration preparation script
- `compose.yaml` - Docker Compose definition (reference)
- `README.md` - Dockhand setup guide
- `.env.example` - Environment variable template
- `CHECKLIST.sh` - Migration tracker

## Deployment Flow

### Step 1: Copy to NAS

Before migration, copy the entire `dockhand/` directory to `/volume2/docker/dockhand/`:

```bash
# From your local ce-stacks repo
# (after git push to your NAS or via USB/SSH)

# SSH to NAS
ssh user@10.0.1.15

# Navigate to volume2/docker
cd /volume2/docker

# Copy the dockhand directory
# Option A: From the git repo
git clone https://github.com/yourusername/ce-stacks.git
cp -r ce-stacks/dockhand /volume2/docker/dockhand

# Option B: Direct copy if repo already exists
cp -r /volume2/docker/ce-stacks/dockhand /volume2/docker/dockhand

# Verify
ls -la /volume2/docker/dockhand/
# Should show: scripts/, docs/, README.md, .env.example, compose.yaml, etc.
```

### Step 2: Install RC Script

```bash
sudo cp /volume2/docker/dockhand/scripts/dockhand-start.sh /usr/local/etc/rc.d/dockhand.sh
sudo chmod +x /usr/local/etc/rc.d/dockhand.sh
```

### Step 3: Start Dockhand

```bash
sudo /usr/local/etc/rc.d/dockhand.sh
```

### Step 4: Follow Migration Guide

```bash
cat /volume2/docker/dockhand/MIGRATION.md
# Then follow all 9 steps in the guide
```

## After Migration

Once Dockhand is running on your NAS:

- **dockhand/** directory in ce-stacks repo becomes a reference/backup
- All active Dockhand data lives in `/volume2/docker/dockhand/` (outside the repo)
- The RC script persists across DSM reboots
- Git webhooks auto-sync stacks from `/volume2/docker/ce-stacks/` repo

## File Mapping

| File | Location | Purpose |
|---|---|---|
| `scripts/dockhand-start.sh` | `/usr/local/etc/rc.d/dockhand.sh` | DSM startup script |
| `docs/MIGRATION.md` | `/volume2/docker/dockhand/docs/MIGRATION.md` | Step-by-step guide |
| `scripts/dockhand-validate.sh` | `/volume2/docker/dockhand/scripts/dockhand-validate.sh` | Validation checks |
| `README.md` | `/volume2/docker/dockhand/README.md` | Configuration reference |
| `compose.yaml` | `/volume2/docker/dockhand/compose.yaml` | Reference definition |
| `.env.example` | `/volume2/docker/dockhand/.env.example` | Env var template |

## Why This Structure?

- **ce-stacks/dockhand/** is version-controlled in git (backup, history, team sharing)
- **/volume2/docker/dockhand/** is runtime data on the NAS (persists across reboots, excluded from git)
- RC script ensures Dockhand restarts automatically on DSM reboot
- All scripts reference `/volume2/docker/` paths (not ce-stacks paths)

## Next Steps

1. Push ce-stacks repo changes to GitHub
2. On NAS, copy dockhand/ → /volume2/docker/dockhand/
3. Install RC script
4. Follow MIGRATION.md (9 steps)

---

For questions, see `/volume2/docker/dockhand/MIGRATION.md` on the NAS or `dockhand/MIGRATION.md` in the repo.
