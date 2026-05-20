# Dockhand Migration Summary

This repository has been updated to support **Dockhand** as the primary Docker stack orchestrator, replacing Portainer CE.

## What Changed?

### New Files

- **`dockhand/`** - Dockhand stack configuration and migration tooling (repo root, NOT under `stacks/`)
  - `compose.yaml` -- Reference compose definition (managed by RC script in production)
  - `scripts/dockhand-start.sh` -- RC script for DSM startup (copy to `/usr/local/etc/rc.d/dockhand.sh`)
  - `docs/MIGRATION.md` -- Detailed step-by-step migration guide
  - `README.md` -- Dockhand configuration and troubleshooting
  - `.env.example` -- Environment variable reference

### Updated Files

- **`README.md`** -- Main repo documentation updated to reference Dockhand
  - Changed from Portainer CE to Dockhand
  - Updated deployment and setup instructions
  - Added links to Dockhand-specific documentation

## Quick Start

### Deploy Dockhand

```bash
# 1. Copy RC script to DSM system startup (after copying dockhand/ to /volume2/docker/dockhand/)
sudo cp /volume2/docker/dockhand/scripts/dockhand-start.sh /usr/local/etc/rc.d/dockhand.sh
sudo chmod +x /usr/local/etc/rc.d/dockhand.sh

# 2. Start Dockhand immediately
sudo /usr/local/etc/rc.d/dockhand.sh

# 3. Access web UI
# http://10.0.1.15:3866
```

### Full Migration

See **`/volume2/docker/dockhand/docs/MIGRATION.md`** for detailed, step-by-step instructions covering:

1. Pre-migration backup
2. Dockhand deployment
3. Web UI initialization
4. Git webhook setup
5. Stack import
6. Validation and rollback procedures

## Key Advantages

[OK] **Git-backed deployments** -- Auto-sync stacks on repo push via webhooks
[OK] **Modern UI** -- SvelteKit 5 frontend (faster than Portainer's Angular)
[OK] **Lighter footprint** -- Bun runtime vs Go (better for resource-constrained NAS)
[OK] **Privacy-focused** -- Wolfi OS base, minimal supply chain
[OK] **OIDC support** -- Enterprise-grade authentication

## Important Notes

- **All stacks continue running** during migration (containers are independent of orchestrator)
- **Data is preserved** -- All volumes and persistent data remain intact
- **Rollback available** -- Dockhand is just the UI; stopping it (`docker stop dockhand && docker rm dockhand`) does not affect running stacks.
- **Validation provided** -- Scripts to test label passthrough, watchtower compliance, socket access

## Reference

| Item | Value |
|---|---|
| **Orchestrator** | Dockhand (fnsys/dockhand:latest) |
| **Port** | 10.0.1.15:3866 (HTTP) |
| **Data** | /volume2/docker/dockhand |
| **RC Script** | /usr/local/etc/rc.d/dockhand.sh |
| **Features** | Git webhooks, Compose editor, multi-environment |
| **License** | BSL 1.1 (converts to Apache 2.0 Jan 2029) |

## Need Help?

1. **Getting Started**: Read `/volume2/docker/dockhand/README.md`
2. **Full Migration**: Follow `/volume2/docker/dockhand/docs/MIGRATION.md`
3. **Troubleshooting**: See "Troubleshooting" section in `/volume2/docker/dockhand/docs/MIGRATION.md`
4. **Official Docs**: https://dockhand.pro/manual

---

**Status**: Migration tools are ready. Deploy when you're prepared to migrate your infrastructure.
