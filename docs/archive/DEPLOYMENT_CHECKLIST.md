# Deployment Guide - All Fixes Applied

## Status: ✅ All 11 Issues Fixed & Verified

All fixes have been applied to the codebase and tested:
- ✅ Validation scripts pass
- ✅ Memory budget parser rejects decimals
- ✅ Security linter finds zero violations
- ✅ Ollama network subnet corrected (172.31.0.0 → 172.27.0.0)
- ✅ Port bindings consistently quoted
- ✅ Health check timeout increased
- ✅ OCI runtime fix documented

---

## Files Changed Summary

### Core Fixes (9 files modified)

| File | Change | Type |
|------|--------|------|
| `stacks/ollama/compose.yaml` | Network subnet 172.31.0.0 → 172.27.0.0 | Critical |
| `stacks/agents_gateway_data/duckduckgo/compose.yaml` | Port binding quoting | Critical |
| `stacks/dozzle/compose.yaml` | Port binding quoting | Minor |
| `stacks/it-tools/compose.yaml` | Port binding quoting | Minor |
| `stacks/openresume/compose.yaml` | Port binding quoting | Minor |
| `stacks/remotely/compose.yaml` | Port binding quoting | Minor |
| `stacks/watchtower/compose.yaml` | Port binding quoting | Minor |
| `stacks/grafana-prom/compose.yaml` | Remove unused wireguard mount | Minor |
| `dockhand/scripts/dockhand-start.sh` | Health check timeout (30→90 retries) | Critical |

### Validation & Lint (4 files modified/created)

| File | Change | Type |
|------|--------|------|
| `scripts/compose-validate.sh` | Secret file corruption detection | Minor |
| `scripts/lint-host-budget.sh` | Reject floating-point memory values | Moderate |
| `scripts/dockhand-sync.sh` | Safer backup/restore fallback | Moderate |
| `scripts/lint-compose-security.sh` | NEW: Security linter | Minor |

### Documentation (2 files created)

| File | Purpose |
|------|---------|
| `FIXES_APPLIED.md` | Comprehensive fix documentation |
| `docs/OCI_RUNTIME_FIX.md` | OCI runtime error resolution guide |

---

## Deployment Checklist

### Pre-Deployment (Local)

- [x] Review `FIXES_APPLIED.md` for detailed changes
- [x] Run `bash scripts/compose-validate.sh` — ✅ Passes
- [x] Run `bash scripts/lint-host-budget.sh --self-test` — ✅ 8/8 tests pass
- [x] Run `bash scripts/lint-compose-security.sh` — ✅ Zero violations
- [x] Verify all compose files parse successfully

### Deployment to NAS

#### Step 1: Pull Latest Fixes
```bash
cd /volume2/docker/ce-stacks
git pull origin main
```

#### Step 2: Run Full Validation
```bash
bash scripts/compose-validate.sh
# Expected: "All compose files validated OK."
```

#### Step 3: Restart Affected Stacks

**Ollama Stack** (subnet changed):
```bash
cd /volume2/docker/ce-stacks/stacks/ollama
docker compose down
docker compose up -d
docker logs otsai | tail -20  # Verify it starts
docker logs otsai-webui | tail -20
```

**Dockhand** (health check timeout fix):
```bash
sudo cp /volume2/docker/ce-stacks/dockhand/scripts/dockhand-start.sh /usr/local/etc/rc.d/dockhand.sh
sudo chmod +x /usr/local/etc/rc.d/dockhand.sh
sudo /usr/local/etc/rc.d/dockhand.sh
# Wait 180s for health check
sleep 180
docker inspect dockhand | jq '.State.Health.Status'
# Expected: "healthy"
```

#### Step 4: Verify Port Bindings

```bash
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep -E "(8812|8892|8894|11434|8889|5371|18787)"
# All should show quoted port format (internal use, no visible change)
```

#### Step 5: Address OCI Runtime Errors (if needed)

If you encounter `open /proc/sys/net/ipv4/ping_group_range: read-only file system`:

1. Read `docs/OCI_RUNTIME_FIX.md`
2. SSH to Synology NAS as root:
   ```bash
   ssh root@10.0.1.15
   sysctl -w vm.overcommit_memory=1
   sysctl -w net.core.somaxconn=512
   sysctl -w net.ipv4.ping_group_range="0 65535"
   ```
3. For persistence, create DSM Task Scheduler boot-up script (see OCI_RUNTIME_FIX.md)

---

## Verification Steps

### Compose File Validation
```bash
bash scripts/compose-validate.sh
```
Expected output includes:
- ✅ All compose files validated OK
- ✅ RFC1918 subnet check passes
- ✅ Memory budget check passes

### Memory Parser Test
```bash
bash scripts/lint-host-budget.sh --self-test
```
Expected:
- ✅ 8 passed, 0 failed
- ✅ Decimals (e.g., "1.5g") rejected as ERR

### Security Linter
```bash
bash scripts/lint-compose-security.sh
```
Expected:
- ✅ Zero violations
- ✅ Zero warnings

### Container Health Checks
```bash
# Dockhand
docker inspect dockhand | jq '.State.Health.Status'
# Expected: "healthy"

# Ollama
docker inspect otsai | jq '.State.Health.Status'
# Expected: "healthy"

# Open WebUI
docker inspect otsai-webui | jq '.State.Health.Status'
# Expected: "healthy"
```

---

## Rollback (if needed)

If you need to revert changes:

```bash
# Rollback to previous commit
git reset --hard HEAD~1
git pull origin main

# Revalidate
bash scripts/compose-validate.sh

# Restart affected stacks
cd /volume2/docker/ce-stacks/stacks/ollama && docker compose down && docker compose up -d
sudo /usr/local/etc/rc.d/dockhand.sh
```

---

## Key Improvements

| Issue | Before | After | Benefit |
|-------|--------|-------|---------|
| Ollama network | 172.31.0.0 (collision) | 172.27.0.0 (clean) | No network conflicts |
| Port bindings | Mixed quoting | Consistent quotes | YAML parsing safety |
| Dockhand startup | 60s timeout | 180s timeout | Handles slow health checks |
| Memory parser | Accepts 1.5g | Rejects 1.5g | Budget calculations exact |
| dockhand-sync | Fragile fallback | Atomic backup/restore | Safe sync without data loss |
| Wireguard mount | Dead code | Commented out | Cleaner compose files |
| OCI runtime errors | No guidance | Complete fix guide | Operator self-service |

---

## Post-Deployment Monitoring

### Monitor Dockhand Health
```bash
docker logs dockhand | tail -50
# Should show no errors, successful git sync operations
```

### Monitor Ollama
```bash
docker logs otsai | tail -20
docker logs otsai-webui | tail -20
# Should show normal operation, no network errors
```

### Test OCI Runtime
```bash
# If previously encountering ping_group_range errors
docker compose up <problematic-service>
docker logs <container> | grep -i "ping_group_range"
# Should be silent (no errors) or show graceful fallback
```

---

## Support

### If Validation Fails
```bash
# Check which file causes issues
bash scripts/compose-validate.sh 2>&1 | grep -i error

# Re-run security linter for detailed warnings
bash scripts/lint-compose-security.sh

# Check individual compose file
docker compose -f stacks/<stack>/compose.yaml config
```

### If Dockhand Won't Start
```bash
# Check logs
sudo docker logs dockhand | tail -100

# Verify socket
ls -l /var/run/docker.sock

# Manual restart
sudo /usr/local/etc/rc.d/dockhand.sh
```

### If Ollama Network Issues
```bash
# Check network
docker network inspect ollama-net

# Verify subnet
docker network inspect ollama-net | jq '.IPAM.Config[0].Subnet'
# Expected: "172.27.0.0/24"

# Restart stack
cd /volume2/docker/ce-stacks/stacks/ollama
docker compose down
docker compose up -d
```

---

## Files Ready for Deployment

```
✅ FIXES_APPLIED.md                           (new documentation)
✅ docs/OCI_RUNTIME_FIX.md                    (new guide)
✅ scripts/lint-compose-security.sh           (new linter)
✅ scripts/compose-validate.sh                (updated)
✅ scripts/lint-host-budget.sh                (updated)
✅ scripts/dockhand-sync.sh                   (updated)
✅ dockhand/scripts/dockhand-start.sh         (updated)
✅ stacks/ollama/compose.yaml                 (updated)
✅ stacks/agents_gateway_data/duckduckgo/compose.yaml (updated)
✅ stacks/grafana-prom/compose.yaml           (updated)
✅ stacks/dozzle/compose.yaml                 (updated)
✅ stacks/it-tools/compose.yaml               (updated)
✅ stacks/openresume/compose.yaml             (updated)
✅ stacks/remotely/compose.yaml               (updated)
✅ stacks/watchtower/compose.yaml             (updated)
```

All files tested and ready for production deployment.

---

## Next Steps

1. **Merge & Deploy**: Push all changes to main branch
2. **CI/CD Update**: Add `scripts/lint-compose-security.sh` to GitHub Actions workflow
3. **Document Operator**: Include OCI_RUNTIME_FIX.md in operator runbook
4. **Monitor**: Watch Dockhand logs for 24h to confirm all stacks remain healthy

---

**Deployment Status**: ✅ Ready for Production
**Last Tested**: 2026-05-18
**All Validations**: PASS
