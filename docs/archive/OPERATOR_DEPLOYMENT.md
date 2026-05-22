# 🚀 OPERATOR DEPLOYMENT GUIDE - Go Live Now

**Estimated Time**: 30-40 minutes | **Risk Level**: Low (backward compatible)

---

## ⚡ Quick Start (TL;DR)

```bash
# 1. SSH to NAS
ssh root@10.0.1.15

# 2. Pull latest fixes
cd /volume2/docker/ce-stacks && git pull

# 3. Validate everything works
bash scripts/compose-validate.sh

# 4. Restart ollama (network fix)
cd /volume2/docker/ce-stacks/stacks/ollama && docker compose down && docker compose up -d

# 5. Reinstall dockhand (health check fix)
sudo cp /volume2/docker/ce-stacks/dockhand/scripts/dockhand-start.sh /usr/local/etc/rc.d/dockhand.sh
sudo chmod +x /usr/local/etc/rc.d/dockhand.sh
sudo /usr/local/etc/rc.d/dockhand.sh

# 6. Wait for health check
sleep 180 && docker inspect dockhand | jq '.State.Health.Status'
# Expected: "healthy"

# 7. Fix OCI runtime errors (if you have them)
sysctl -w vm.overcommit_memory=1
sysctl -w net.core.somaxconn=512
sysctl -w net.ipv4.ping_group_range="0 65535"

# 8. Verify all running
docker ps | grep -E "(Dockhand|otsai|otsai-webui|Prometheus|Grafana)"
```

**Done!** All fixes are now live. ✅

---

## 📋 Detailed Steps (with explanations)

### Step 1: SSH into the NAS

```bash
ssh root@10.0.1.15
# Password: [your Synology root password]
```

### Step 2: Navigate to ce-stacks and pull latest

```bash
cd /volume2/docker/ce-stacks
git pull origin main
# Output should show: Already up to date OR list new commits pulled
```

### Step 3: Validate all compose files

```bash
bash scripts/compose-validate.sh
```

**Expected output:**
```
compose config: stacks/acme-sh/compose.yaml
compose config: stacks/agents_gateway_data/compose.yaml
... [many compose files] ...
All compose files validated OK.

-- RFC1918 subnet lint --
OK: 17 subnets inside RFC1918.

-- Host memory budget lint --
OK: total mem_limit 30032 MB <= budget 32000 MB.
```

**If you see ERRORS**, stop and review (see Troubleshooting section below).

---

### Step 4: Restart Ollama Stack (NETWORK SUBNET FIX)

This fixes the network collision (172.31.0.0 → 172.27.0.0).

```bash
cd /volume2/docker/ce-stacks/stacks/ollama

# Stop the stack
docker compose down
# Wait for containers to stop...

# Start the stack with new subnet
docker compose up -d

# Verify it's running
docker ps | grep otsai
# You should see: otsai, otsai-webui running

# Check logs (should be clean)
docker logs otsai | tail -20
docker logs otsai-webui | tail -20
```

**Expected logs**: No errors, models loading normally.

---

### Step 5: Reinstall Dockhand RC Script (HEALTH CHECK FIX)

This fixes the timeout race condition (30→90 retries).

```bash
# Copy the updated script to RC directory
sudo cp /volume2/docker/ce-stacks/dockhand/scripts/dockhand-start.sh /usr/local/etc/rc.d/dockhand.sh

# Make it executable
sudo chmod +x /usr/local/etc/rc.d/dockhand.sh

# Run the script (it will restart dockhand container)
sudo /usr/local/etc/rc.d/dockhand.sh
```

**Output:**
```
dockhand-start: pulled image: fnsys/dockhand:latest
dockhand-start: creating new dockhand container
dockhand-start: waiting for dockhand to become healthy...
dockhand-start: dockhand is healthy [OK]
dockhand-start: Access Dockhand at http://10.0.1.15:3866
```

---

### Step 6: Wait for Dockhand Health Check

The new code has a longer timeout (180s instead of 60s). Wait for it to fully start:

```bash
# Wait 3 minutes for health check to complete
sleep 180

# Verify it's healthy
docker inspect dockhand | jq '.State.Health.Status'
```

**Expected output**: `"healthy"`

**If you see**: `"starting"` - wait another 30 seconds and try again.

---

### Step 7: Address OCI Runtime Errors (IF YOU HAVE THEM)

If you're seeing errors like:
```
error during container init: open /proc/sys/net/ipv4/ping_group_range: read-only file system
```

**Set kernel parameters on the NAS host** (not in containers):

```bash
# These need to be run as root (you're already root from ssh)
sysctl -w vm.overcommit_memory=1
sysctl -w net.core.somaxconn=512
sysctl -w net.ipv4.ping_group_range="0 65535"

# Verify they were set
sysctl vm.overcommit_memory
# Expected: vm.overcommit_memory = 1
```

**For persistence** (survive reboot), create a DSM Task Scheduler entry:

1. **Web GUI**: DSM Control Panel > System > Task Scheduler
2. **Create** > User-defined script
3. **Task name**: `setup-sysctls`
4. **User**: `root`
5. **Schedule**: `Boot-up`
6. **Script**:
```bash
sysctl -w vm.overcommit_memory=1
sysctl -w net.core.somaxconn=512
sysctl -w net.ipv4.ping_group_range="0 65535"
```
7. **Save** and enable

---

### Step 8: Final Verification

```bash
# Check all critical containers are running
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "(Dockhand|otsai|Prometheus|Grafana|Alertmanager)"
```

**Expected:**
```
Dockhand           Up X minutes (healthy)
otsai              Up X minutes (healthy)
otsai-webui        Up X minutes (healthy)
Prometheus         Up X minutes (healthy)
Grafana            Up X minutes (healthy)
Alertmanager       Up X minutes (healthy)
```

---

## ✅ Verification Checklist

After deployment, verify each fix:

### Ollama Network Fix
```bash
docker network inspect ollama-net | jq '.IPAM.Config[0].Subnet'
# Expected: "172.27.0.0/24"
```

### Dockhand Health Check
```bash
docker inspect dockhand | jq '.State.Health.Status'
# Expected: "healthy"

# Check startup logs
docker logs dockhand | grep -i health
# Should show: health check passes
```

### Port Bindings (Internal Fix)
```bash
# Just verify no errors on port access
curl -s http://10.0.1.15:3866/health >/dev/null 2>&1 && echo "Dockhand port OK" || echo "ERROR"
```

### OCI Runtime Fix (if applicable)
```bash
# Try restarting a container that was failing
docker compose -f stacks/searxng/compose.yaml down
docker compose -f stacks/searxng/compose.yaml up -d

# Check logs for errors
docker logs SearXNG | head -10
```

---

## 🔄 Rollback Steps (If Needed)

If something goes wrong, rollback is simple:

```bash
cd /volume2/docker/ce-stacks

# Revert to previous commit
git reset --hard HEAD~1

# Revalidate
bash scripts/compose-validate.sh

# Restart affected stacks
cd stacks/ollama && docker compose down && docker compose up -d
sudo /usr/local/etc/rc.d/dockhand.sh
```

---

## 🚨 Troubleshooting

### Problem: `compose-validate.sh` shows errors

**Solution:**
```bash
# See which file has the error
bash scripts/compose-validate.sh 2>&1 | grep -i "error\|fail"

# If it's a missing .env file, generate it
cd /volume2/docker/ce-stacks
bash scripts/restore-env.sh

# Re-validate
bash scripts/compose-validate.sh
```

### Problem: Dockhand won't start after health check fix

**Solution:**
```bash
# Check what's wrong
docker logs dockhand | tail -100

# If image pull failed
docker pull fnsys/dockhand:latest

# Retry startup
sudo /usr/local/etc/rc.d/dockhand.sh
```

### Problem: Ollama containers can't communicate after network change

**Solution:**
```bash
# Verify new network
docker network inspect ollama-net | jq '.IPAM.Config[0].Subnet'
# Must be: 172.27.0.0/24

# Restart containers on new network
cd /volume2/docker/ce-stacks/stacks/ollama
docker compose down
docker compose up -d

# Test connectivity
docker exec otsai-webui curl -s http://otsai:11434/api/tags | jq '.models | length'
# Should show a number > 0
```

### Problem: OCI runtime error about ping_group_range

**Solution:**
```bash
# Set the kernel parameter
sysctl -w net.ipv4.ping_group_range="0 65535"

# Verify it took
sysctl net.ipv4.ping_group_range

# Try restarting the problematic container
docker restart <container_name>

# If it still fails, see detailed troubleshooting in:
cat /volume2/docker/ce-stacks/docs/OCI_RUNTIME_FIX.md
```

### Problem: Port bindings look weird in compose files

**This is not a problem!** Port quoting is now consistent. You can verify:
```bash
grep -r "ports:" stacks/*/compose.yaml | grep "10.0.1" | head -5
# All should show: "10.0.1.15:XXXX:YYYY" (quoted)
```

---

## 📊 What Changed (Summary)

| Component | Change | Effect |
|-----------|--------|--------|
| Ollama network | 172.31.0.0/24 → 172.27.0.0/24 | No more conflicts with dozzle/watchtower |
| Port bindings | Standardized quoting | YAML safety (no functional change) |
| Dockhand startup | 60s → 180s timeout | Handles slow health checks better |
| Memory parser | Rejects decimals | Budget calculations are exact |
| dockhand-sync | Added backup/restore | Safer sync fallback |
| OCI runtime | Documented solution | Operators can self-serve fixes |

---

## ⏱️ Deployment Timeline

| Step | Component | Time |
|------|-----------|------|
| 1 | SSH + git pull | 2 min |
| 2 | Validate compose | 5 min |
| 3 | Restart ollama | 5 min |
| 4 | Reinstall dockhand | 3 min |
| 5 | Wait for health check | 3 min |
| 6 | Set sysctl params | 2 min |
| 7 | Final verification | 5 min |
| **Total** | | **~25 min** |

---

## 📞 Need Help?

**All fixes are documented at**:
- `README_FIXES.md` - Overview & navigation
- `FIX_SUMMARY.md` - Executive summary
- `DEPLOYMENT_CHECKLIST.md` - Detailed checklist
- `docs/OCI_RUNTIME_FIX.md` - OCI runtime errors

**Location on NAS**:
```
/volume2/docker/ce-stacks/README_FIXES.md
/volume2/docker/ce-stacks/FIX_SUMMARY.md
/volume2/docker/ce-stacks/DEPLOYMENT_CHECKLIST.md
/volume2/docker/ce-stacks/docs/OCI_RUNTIME_FIX.md
```

---

## 🎯 Success Criteria

After deployment, you should see:

- ✅ Dockhand running and healthy
- ✅ Ollama on new network (172.27.0.0/24)
- ✅ All stacks stable and running
- ✅ No port binding errors
- ✅ No OCI runtime errors
- ✅ Logs clean (no warnings about sysctls)

---

## 🎉 You're Done!

All fixes are now live on your Synology NAS.

**Next**: Monitor logs for 24 hours to ensure stability.

```bash
# Watch dockhand logs in real-time
docker logs -f dockhand

# Or check periodically
docker logs dockhand | tail -50
```

**Questions?** See the detailed guides listed above.

---

**Deployment Status**: ✅ Ready to Go Live
**Risk Level**: 🟢 Low (all backward compatible)
**Estimated Uptime Impact**: ~10 min for ollama/dockhand restarts
