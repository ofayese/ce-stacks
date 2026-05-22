# OPERATOR QUICK CARD - Deploy in 25 Minutes

```
┌─────────────────────────────────────────────────────────────────┐
│ 🚀 GO-LIVE COMMANDS (Copy & Paste)                              │
└─────────────────────────────────────────────────────────────────┘
```

## Phase 1: Pull & Validate (5 min)

```bash
ssh root@10.0.1.15
cd /volume2/docker/ce-stacks
git pull
bash scripts/compose-validate.sh
# Expected: "All compose files validated OK"
```

## Phase 2: Restart Ollama (5 min)

```bash
cd /volume2/docker/ce-stacks/stacks/ollama
docker compose down
docker compose up -d
sleep 30
docker logs otsai | tail -10
# Expected: No errors, models loading
```

## Phase 3: Fix Dockhand (5 min)

```bash
sudo cp /volume2/docker/ce-stacks/dockhand/scripts/dockhand-start.sh /usr/local/etc/rc.d/dockhand.sh
sudo chmod +x /usr/local/etc/rc.d/dockhand.sh
sudo /usr/local/etc/rc.d/dockhand.sh
sleep 180
docker inspect dockhand | jq '.State.Health.Status'
# Expected: "healthy"
```

## Phase 4: Set Sysctls (optional, if OCI errors)

```bash
sysctl -w vm.overcommit_memory=1
sysctl -w net.core.somaxconn=512
sysctl -w net.ipv4.ping_group_range="0 65535"
```

## Phase 5: Verify (5 min)

```bash
docker ps | grep -E "(Dockhand|otsai|Prometheus)"
# All should show "Up X minutes (healthy)"

curl -s http://10.0.1.15:3866/health && echo "✓ Dockhand OK"
docker exec otsai curl -s http://localhost:11434/api/tags >/dev/null && echo "✓ Ollama OK"
```

---

## ⏱️ Timeline

| Phase | Duration | What Happens |
|-------|----------|--------------|
| 1. Pull & validate | 5 min | Download fixes, check everything |
| 2. Restart ollama | 5 min | Network subnet updates (172.27.0.0) |
| 3. Fix dockhand | 5 min + 3 min wait | Health check timeout increased |
| 4. Sysctls | 2 min | Kernel params (optional) |
| 5. Verify | 5 min | Confirm all running |
| **TOTAL** | **~25 min** | |

---

## ✅ Pass/Fail Criteria

| Component | Pass | Fail |
|-----------|------|------|
| Compose validation | "All validated OK" | "ERROR" or "FAIL" |
| Ollama restart | Containers running, no errors in logs | Error messages, containers not starting |
| Dockhand health | "healthy" | "starting" or "unhealthy" |
| Port access | `curl` returns data | Connection refused |
| Sysctl (optional) | `sysctl` shows `= 1` | Returns old value |

---

## 🆘 If Something Fails

### Validation fails

```bash
bash scripts/compose-validate.sh 2>&1 | grep -i "error\|fail"
# Then fix the specific issue or rollback
```

### Ollama won't start

```bash
cd stacks/ollama
docker compose logs
# Check for network or image pull errors
```

### Dockhand won't be healthy

```bash
docker logs dockhand | tail -100
# Look for "ERROR" lines
```

### Sysctls won't apply

```bash
# Verify you're running as root (you are from ssh root@...)
sysctl net.ipv4.ping_group_range
# If still old value, restart the container after setting
```

---

## 🔄 If You Need to Rollback

```bash
cd /volume2/docker/ce-stacks
git reset --hard HEAD~1
bash scripts/compose-validate.sh
cd stacks/ollama && docker compose down && docker compose up -d
sudo /usr/local/etc/rc.d/dockhand.sh
```

---

## 📋 Pre-Deployment Checklist

- [ ] Connected to NAS via SSH
- [ ] At `/volume2/docker/ce-stacks` directory
- [ ] Have write access to `/volume2` (should be automatic as root)
- [ ] Network access to all container ports
- [ ] Backup of any custom configs (optional but recommended)

---

## 🎯 What Gets Fixed

1. **Ollama network** - No more conflicts
2. **Port safety** - Consistent YAML quoting
3. **Dockhand startup** - Longer timeout for reliability
4. **OCI runtime** - Guide for kernel param errors
5. **Budget parsing** - Exact memory calculations
6. **Sync safety** - Better fallback handling
7. **Wireguard mount** - Clean compose files

---

## 📞 Documentation

| Doc | Use Case | Location |
|-----|----------|----------|
| This card | Quick reference | `OPERATOR_QUICK_CARD.md` |
| Operator guide | Detailed steps | `OPERATOR_DEPLOYMENT.md` |
| Fix summary | What changed | `FIX_SUMMARY.md` |
| OCI errors | Troubleshooting | `docs/OCI_RUNTIME_FIX.md` |

---

## ⚠️ Important Notes

- **Risk**: 🟢 LOW (all backward compatible)
- **Downtime**: ~10 min (ollama & dockhand restart)
- **Rollback**: Easy (single git command)
- **Testing**: All validation scripts pass ✅

---

## 🎉 Success

When you see this, deployment is complete:

```
docker inspect dockhand | jq '.State.Health.Status'
# Output: "healthy"
```

Monitor logs for 24h:

```bash
docker logs -f dockhand
```

---

**Estimated Total Time**: 25-30 minutes
**Difficulty Level**: 🟢 Easy (copy-paste commands)
**Support**: See OPERATOR_DEPLOYMENT.md for detailed help

Go ahead and deploy! 🚀
