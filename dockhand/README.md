# Dockhand Configuration

This directory contains the Dockhand container orchestrator configuration for ce-stacks.

## Overview

**Dockhand** replaces Portainer CE as the primary stack management UI. Key differences:

- **Git-backed deployments**: Auto-sync stacks from GitHub via webhooks
- **Compose visual editor**: Intuitive UI for editing/creating stacks
- **Modern tech stack**: SvelteKit 5 frontend, Bun runtime backend
- **Privacy-focused**: Wolfi OS base, minimal supply chain exposure
- **OIDC SSO**: Enterprise-grade authentication support

## Deployment

### Via RC Script (Recommended for Synology DSM)

The RC script manages Dockhand lifecycle on DSM reboots:

```bash
sudo cp /volume2/docker/ce-stacks/dockhand/scripts/dockhand-start.sh /usr/local/etc/rc.d/dockhand.sh
sudo chmod +x /usr/local/etc/rc.d/dockhand.sh
sudo /usr/local/etc/rc.d/dockhand.sh
```

Dockhand will be available at `http://10.0.1.15:3866` after health check passes (60s).

### Via Docker Compose

For manual testing or development:

```bash
cd /volume2/docker/ce-stacks/dockhand
docker compose up -d
```

**Note**: This does NOT auto-start on DSM reboot. Use the RC script for production.

## Configuration

All configuration is stored in `/volume2/docker/dockhand/` (outside this repo):

```
/volume2/docker/dockhand/
+--- db/               # SQLite database (Dockhand state)
+--- stacks/           # Imported stack definitions
+--- git-repos/        # Cloned git repositories for stacks
+--- tmp/              # Temporary files
+--- icons/            # Container/stack icons
+--- snapshots/        # System snapshots
+--- scanner-cache/    # Container image scan cache
```

## Initial Setup

After deployment, access the web UI and configure:

1. **Authentication**: Create admin user (Settings > Users)
2. **Docker Environment**: Add "DS723" with Unix socket
3. **Registries**: Add ghcr.io, codeberg.org, quay.io
4. **Git Webhooks**: Register GitHub repo for auto-sync

See `/volume2/docker/ce-stacks/dockhand/docs/MIGRATION.md` for detailed setup guide.

## Git Webhook Integration

Dockhand auto-deploys stacks when you push to the ce-stacks repo.

### Register Webhook

1. Go to ce-stacks repo on GitHub
2. Settings > Webhooks > Add webhook
3. Payload URL: `http://10.0.1.15:3866/webhooks/<your-webhook-key>`
4. Content type: `application/json`
5. Trigger: `Push events`

### Test Webhook

```bash
cd /volume2/docker/ce-stacks

# Edit and push a compose file
echo "# test comment" >> stacks/it-tools/compose.yaml
git add stacks/it-tools/compose.yaml
git commit -m "test webhook"
git push origin main

# Check GitHub webhook delivery status
# Repo > Settings > Webhooks > Recent Deliveries
```

## Label Passthrough Validation

Dockhand preserves Docker labels from compose.yaml files, including:

- `com.centurylinklabs.watchtower.enable` -- prevents accidental DB upgrades
- `com.example.app-version` -- custom application labels
- `security.apparmor` -- AppArmor profiles

Verify labels after deployment:

```bash
docker inspect <container-name> | jq '.Config.Labels'
```

## Troubleshooting

### Dockhand won't start

```bash
# Check RC script logs
sudo docker logs dockhand | tail -50

# Verify socket permissions
ls -l /var/run/docker.sock

# Manually restart
sudo /usr/local/etc/rc.d/dockhand.sh
```

### Git webhook not triggering

```bash
# Verify webhook endpoint is accessible
curl -v http://10.0.1.15:3866/health

# Check GitHub webhook delivery status
# Repo > Settings > Webhooks > select webhook > Recent Deliveries

# Test webhook manually
curl -X POST http://10.0.1.15:3866/webhooks/<key> \
  -H "Content-Type: application/json" \
  -d '{"repository":{"name":"ce-stacks"}}'
```

### Stack labels not preserved

```bash
# Check what Dockhand stored
docker inspect <container-name> | jq '.Config.Labels'

# Compare with compose.yaml
grep -A5 "labels:" /volume2/docker/ce-stacks/stacks/<stack>/compose.yaml

# Re-deploy via Dockhand UI with corrected compose
```

## Related Documentation

- **Full Migration Guide**: `/volume2/docker/ce-stacks/dockhand/docs/MIGRATION.md`
- **DSM Boot Persistence**: `/volume2/docker/ce-stacks/dockhand/docs/DSM_BOOT_PERSISTENCE.md`
- **Validation Script**: `/volume2/docker/ce-stacks/dockhand/scripts/dockhand-validate.sh`
- **Historical Portainer->Dockhand Migration Script**: `/volume2/docker/ce-stacks/dockhand/scripts/dockhand-migration.sh`
- **RC Startup Script**: `/volume2/docker/ce-stacks/dockhand/scripts/dockhand-start.sh`
- **Re-sync helper**: `/volume2/docker/ce-stacks/scripts/dockhand-sync.sh`
- **Official Docs**: https://dockhand.pro/manual

## Rollback / disable Dockhand without affecting running stacks

Dockhand is just the UI -- your stacks run as independent containers managed by
the Docker engine. Stopping Dockhand never stops them.

```bash
# Stop and remove Dockhand
sudo docker stop dockhand && sudo docker rm dockhand

# (Optional) prevent it from coming back on next reboot/run
sudo rm -f /usr/local/etc/rc.d/dockhand.sh

# All other containers continue running. Re-deploy Dockhand later with:
sudo cp /volume2/docker/ce-stacks/dockhand/scripts/dockhand-start.sh /usr/local/etc/rc.d/dockhand.sh
sudo chmod +x /usr/local/etc/rc.d/dockhand.sh
sudo /usr/local/etc/rc.d/dockhand.sh
```

> Note: Portainer is no longer part of this topology. The historical
> `dockhand-migration.sh` script under `dockhand/scripts/` is retained only as a
> reference for the original Portainer->Dockhand migration and is not part of
> the current deploy flow.
