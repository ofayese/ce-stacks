# Dockhand Migration Guide for ce-stacks

This document describes the full migration from **Portainer CE** to **Dockhand** on your Synology DS723+ NAS.

## Overview

- **Current**: Portainer CE 2.41.0 manages all stacks via RC script + Portainer Agent
- **Target**: Dockhand (latest) manages stacks via RC script with git-backed deployments
- **Timeline**: 2-4 hours initial setup + validation, then ongoing management
- **Risk Level**: High (full orchestrator replacement) - with rollback options

## Why Migrate to Dockhand?

✅ **Advantages over Portainer CE**:

- Native git integration with webhooks (auto-sync on repo push)
- Modern UI (SvelteKit 5 + Svelte, vs Portainer's Angular)
- Lighter resource footprint (Bun runtime vs Go)
- Privacy-focused (Wolfi OS base layer, minimal supply chain)
- OIDC SSO support (more enterprise-ready auth)
- Better Compose visual editor

⚠️ **Trade-offs**:

- Smaller ecosystem (newer product, less battle-tested)
- No Agent layer (single monolith, no remote environment support for this setup)
- RBAC only in Enterprise version (not a concern for single-host)
- BSL 1.1 license (converts to Apache 2.0 in 2029; Portainer is Apache 2.0 now)

## Prerequisites

- ✅ Synology DSM 7.3 with Docker Engine via Container Manager
- ✅ `/volume2/docker/ce-stacks` repo cloned
- ✅ All 20+ stacks currently running under Portainer
- ✅ Network configured: `ce-internal` bridge exists, services bind to `10.0.1.15`
- ✅ Sufficient disk space: ~500MB for Dockhand data + backups

## Step 1: Pre-Migration Preparation

Your stacks are already in version control at `/volume2/docker/ce-stacks/stacks/`. No migration from Portainer needed.

```bash
# Verify your stacks are in place
ls -la /volume2/docker/ce-stacks/stacks/

# Git status check
cd /volume2/docker/ce-stacks
git status  # ensure nothing uncommitted
git log --oneline | head -5  # verify recent commits
```

## Step 2: Deploy Dockhand

### 2a. Create Dockhand data directory

```bash
sudo mkdir -p /volume2/docker/dockhand
sudo chmod 755 /volume2/docker/dockhand
```

### 2b. Install and start Dockhand RC script

```bash
# Copy the RC script to system startup
sudo cp /volume2/docker/dockhand/scripts/dockhand-start.sh /usr/local/etc/rc.d/dockhand.sh
sudo chmod +x /usr/local/etc/rc.d/dockhand.sh

# Start Dockhand immediately
sudo /usr/local/etc/rc.d/dockhand.sh
```

### 2c. Verify Dockhand is running

```bash
# Check container status
sudo docker ps | grep dockhand

# Expected output:
# dockhand   fnsys/dockhand:latest   ...   Up 30s (healthy)

# Check health
sudo docker inspect dockhand | jq '.State.Health.Status'
# Expected: "healthy"

# Test web UI
curl -v http://10.0.1.15:3866/health
# Expected: 200 OK
```

If not healthy within 60s, check logs:

```bash
sudo docker logs dockhand | tail -50
```

## Step 3: Initialize Dockhand Web UI

### 3a. Create admin user

1. Open browser: `http://10.0.1.15:3866`
2. First-time setup wizard
3. **Settings** > **Authentication** > **Users** > **+ Add user**
   - Username: `admin` (or your preferred name)
   - Password: (create strong password, 16+ chars)
   - Role: `Administrator`
4. Toggle **Authentication** from OFF → ON

### 3b. Configure local Docker environment

1. **Settings** > **Environments** > **+ Add environment**
   - Name: `DS723` (or identify your NAS model)
   - Type: **Unix socket**
   - Socket path: `/var/run/docker.sock`
   - Public IP: `10.0.1.15`
   - Click **+ Add**
2. Switch to the new environment (dropdown at top-left)

### 3c. Register container registries

1. **Settings** > **Registries** > **+ Add registry**
   - **GitHub**: URL `https://ghcr.io` (Public registry, no auth needed)
   - **Codeberg**: URL `https://codeberg.org` (Public registry)
   - **Quay.io**: URL `https://quay.io` (Public registry)
   - For private registries: add username/token if needed

### 3d. Clean default template (optional)

1. **Settings** > **General** > scroll down to "Templates"
2. Delete the default NGINX template (so new stacks start blank)
3. Click **Save template**

## Step 4: Validate Dockhand Setup

Run the validation script to ensure Dockhand is properly configured and can access Docker:

```bash
# Run health checks
bash /volume2/docker/dockhand/scripts/dockhand-validate.sh
```

## Step 5: Set Up Git Webhook for Auto-Sync

Dockhand can auto-deploy stacks when you push changes to your ce-stacks repo. This is optional but recommended.

### 5a. Generate webhook key in Dockhand (if available)

1. **Settings** > **Webhooks** (may require Enterprise version)
2. Note the webhook key provided

### 5b. Register webhook in GitHub (Optional)

1. Go to your ce-stacks repo on GitHub
2. **Settings** > **Webhooks** > **Add webhook**
   - Payload URL: `http://10.0.1.15:3866/webhooks/<your-webhook-key>`
   - Content type: `application/json`
   - Trigger on: `Push events` (select this only)
   - Active: ✓ checked
   - Click **Add webhook**

### 5c. Test webhook (Optional)

1. Make a minor edit to a compose file and push:

   ```bash
   cd /volume2/docker/ce-stacks
   echo "# test" >> stacks/it-tools/compose.yaml
   git add stacks/it-tools/compose.yaml
   git commit -m "test webhook trigger"
   git push origin main
   ```

2. Check GitHub webhook delivery status:
   - Repo > **Settings** > **Webhooks** > select webhook
   - View **Recent Deliveries** - should show successful (200 OK)

## Step 6: Import Stacks into Dockhand

Your stacks are already in `/volume2/docker/ce-stacks/stacks/`. Import them via Dockhand UI.

### Approach A: Import via Dockhand UI (Manual, Recommended)

For each stack in `/volume2/docker/ce-stacks/stacks/`, repeat:

1. **Stacks** > **+ Create Stack** > **Upload Compose File**
2. Navigate to `/volume2/docker/ce-stacks/stacks/<stack-name>/compose.yaml`
3. Fill in required fields:
   - **Name**: `<stack-name>` (must match your stack directory)
   - **Environment**: `DS723`
   - **Compose content**: (auto-populated from file)
4. Click **Create** (do NOT deploy yet)
5. Go to the stack detail view
6. If `.env` file is needed:
   - Download the `.env.example` from your repo
   - Edit locally, replace with actual values
   - Upload via Dockhand UI or copy paste into environment variables
7. Click **Deploy** to start the stack
8. Wait for container health check to pass
9. Verify container properties:

   ```bash
   sudo docker inspect <container-name> | jq .Config.Labels
   ```

   - Should show `com.centurylinklabs.watchtower.enable` label if present in compose.yaml

**Recommended import order** (low-risk to high-risk):

1. `it-tools` - simple, no state
2. `homepage` - simple UI
3. `dozzle` - log viewer, read-only
4. `watchtower` - auto-update manager
5. `databases` - stateful, important
6. `ollama` - large, stateful (models take time to pull)
7. `code-server` - high memory
8. All others

### Approach B: Import via Git Webhook (Automated, Optional)

If webhook is working:

1. Push all stacks to repo (ensure all `compose.yaml` files are committed)
2. Webhook fires automatically on push
3. Dockhand imports and deploys stacks
4. Monitor in **Stacks** view for deployment progress

**Note**: `.env` files are NOT auto-imported (git-ignored for security). You must manually create/upload `.env` for each stack.

## Step 7: Verify Stack Migration

For each imported stack, verify:

### 7a. Container running

```bash
sudo docker ps | grep <stack-name>
```

### 7b. Labels preserved

```bash
sudo docker inspect <container-name> | jq '.Config.Labels'

# Example output (watchtower label preserved):
{
  "com.centurylinklabs.watchtower.enable": "false",
  "app.ce-stacks.stack": "databases"
}
```

### 7c. Health check passing

```bash
sudo docker inspect <container-name> | jq '.State.Health.Status'
# Expected: "healthy" (after 30-60s)
```

### 7d. Security options applied

```bash
sudo docker inspect <container-name> | jq '.HostConfig.SecurityOpt'
# Should include "no-new-privileges:true" and others from compose.yaml
```

### 7e. Mounts correct

```bash
sudo docker inspect <container-name> | jq '.Mounts'
# Verify volumes match compose.yaml bindings and paths are correct
```

### 7f. Port bindings correct

```bash
sudo docker inspect <container-name> | jq '.NetworkSettings.Ports'
# Should show 10.0.1.15 bindings (not 0.0.0.0)
```

## Step 8: Monitor and Maintain

Once all stacks are verified in Dockhand:

### 8a. Verify stability (Week 1)

```bash
# Check all stacks are running
sudo docker ps | grep -E "it-tools|homepage|dozzle|watchtower|databases|ollama"

# Monitor Dockhand logs
sudo docker logs dockhand | tail -50
```

### 8b. Test git webhook (Optional)

If webhook is configured:

1. Make a change to a compose file
2. Commit and push to GitHub
3. Monitor webhook delivery in GitHub UI
4. Verify Dockhand updates the stack

### 8c. Verify watchtower compliance

```bash
# Check that watchtower respects database labels
sudo docker inspect mariadb | jq '.Config.Labels'
sudo docker inspect postgres | jq '.Config.Labels'
# Should show com.centurylinklabs.watchtower.enable=false

# Check watchtower logs for label filtering
sudo docker logs watchtower | grep -i label | tail -20
```

## Step 9: Commit and Document

### 9a. Commit changes to git

```bash
git add .
git commit -m "infra: deploy Dockhand for stack orchestration

Replace Portainer CE with Dockhand for improved git integration
and modern UI. All 20+ stacks imported and running.

Assisted-By: docker-agent" -m ""

git push origin main
```

## Rollback Plan

If issues arise, you can easily roll back:

### Quick Rollback (< 5 min)

If Dockhand UI has issues but containers are running:

```bash
# Dockhand is just the UI; containers keep running independently
# Stop/remove Dockhand without affecting running stacks
sudo docker stop dockhand
sudo docker rm dockhand

# Containers continue running from their compose definitions
# Redeploy Dockhand when ready
sudo /usr/local/etc/rc.d/dockhand.sh
```

### Full Rollback (if needed)

To completely stop all stacks:

```bash
# Stop all stacks
cd /volume2/docker/ce-stacks
sudo docker compose -f stacks/*/compose.yaml down

# Stop Dockhand
sudo docker stop dockhand && sudo docker rm dockhand
```

## Troubleshooting

### Dockhand won't start

```bash
# Check logs
sudo docker logs dockhand | tail -50

# Verify socket access
ls -l /var/run/docker.sock

# Verify data directory
ls -la /volume2/docker/dockhand/

# Manual restart
sudo /usr/local/etc/rc.d/dockhand.sh
```

### Stack doesn't import correctly

```bash
# Validate compose file syntax
sudo docker compose -f /volume2/docker/ce-stacks/stacks/<stack>/compose.yaml config

# Check if all referenced images exist
sudo docker images | grep <image-name>

# Re-import via Dockhand UI and check error message
```

### Labels not preserved

```bash
# Check what Dockhand stored
sudo docker inspect <container-name> | jq '.Config.Labels'

# Compare with source compose.yaml
grep -A5 "labels:" /volume2/docker/ce-stacks/stacks/<stack>/compose.yaml

# If mismatch, re-deploy via Dockhand with corrected compose
```

### Watchtower not respecting labels

```bash
# Verify label is set
sudo docker inspect watchtower | jq '.Config.Env[] | select(contains("WATCHTOWER"))'

# Check watchtower logs for label-based filtering
sudo docker logs watchtower | grep -i label | tail -20
```

### Git webhook not triggering

```bash
# Check GitHub webhook delivery
# Repo > Settings > Webhooks > select webhook > Recent Deliveries

# Verify Dockhand can reach GitHub
# From DSM: curl -v https://api.github.com

# Test webhook endpoint manually
curl -X POST http://10.0.1.15:3866/webhooks/<your-key> \
  -H "Content-Type: application/json" \
  -d '{"repository": {"name": "ce-stacks"}}'

# Check Dockhand logs for webhook events
sudo docker logs dockhand | grep -i webhook | tail -20
```

## FAQ

**Q: Do I need to recreate all stacks in Dockhand?**  
A: You need to import them, but they already exist in the repo. Just upload the compose.yaml files from `/volume2/docker/ce-stacks/stacks/` into Dockhand.

**Q: Will containers keep running during the migration?**  
A: Yes. Containers run independently of the orchestrator. Even if Dockhand crashes, all containers keep running.

**Q: What about persistent data?**  
A: All persistent data lives in volumes (`/volume2/docker/ce-stacks/stacks/*/data/`, databases, etc.). Orchestrator change doesn't affect data.

**Q: Does Dockhand support Docker Swarm?**  
A: No. Dockhand is Docker Compose only. Your setup is single-host, so this isn't a concern.

**Q: What if I push a broken compose.yaml to the repo?**  
A: The webhook will fail. Dockhand will log the error; stacks won't redeploy. Fix the compose and push again.

**Q: How do I update a stack after migration?**  
A: Edit the compose.yaml in `/volume2/docker/ce-stacks/stacks/<stack>/`, commit, and push. If webhooks are enabled, Dockhand auto-syncs. Otherwise, re-import the updated compose file in the UI.

## Next Steps

1. ✅ Deploy Dockhand (Step 1-4, quick)
2. ✅ Import stacks (Step 6, ~5 min per stack)
3. ✅ Validate all running (Step 7)
4. ✅ Monitor for stability (Step 8)
5. ✅ Commit & document (Step 9)

## Support

- **Dockhand Docs**: <https://dockhand.pro/manual>
- **Your Repo Docs**: `/volume2/docker/dockhand/docs/` on NAS or `dockhand/docs/` in ce-stacks repo
- **Dockhand GitHub**: <https://github.com/fnsys/dockhand>

---

**Migration completed**: Your ce-stacks infrastructure is now managed by Dockhand with git-backed deployments.
