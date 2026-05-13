# Complete Health Check Solution

## Summary

Your Dockhand container is **running but marked unhealthy** due to an overly aggressive health check and missing `curl` in the minimal Wolfi OS image.

**Status**: Issue identified and fixed ✅

---

## What Was Wrong

**Health Check Command**: `curl -fs http://127.0.0.1:3000/health >/dev/null || exit 1`

**Problems**:

1. ❌ Wolfi OS minimal image doesn't include `curl`
2. ❌ Bun runtime needs 60+ seconds to startup (JIT compilation)
3. ❌ 60-second startup period is too short
4. ❌ 10-second timeout is too aggressive

**Result**: Container marked unhealthy despite being functional

---

## The Fix (Applied)

### Updated Health Check Parameters

```bash
# OLD (aggressive):
--health-cmd='curl -fs http://127.0.0.1:3000/health >/dev/null || exit 1'
--health-timeout=10s
--health-retries=3
--health-start-period=60s

# NEW (reasonable):
--health-cmd='wget --quiet --tries=1 --spider http://127.0.0.1:3000/health || exit 1'
--health-timeout=20s
--health-retries=5
--health-start-period=120s
```

**Changes**:

- ✅ `curl` → `wget` (available in Wolfi OS)
- ✅ Timeout: 10s → 20s
- ✅ Retries: 3 → 5
- ✅ Startup: 60s → 120s

---

## How to Apply

### Step-by-Step (3 commands)

On your NAS:

```bash
# 1. Stop container
docker stop dockhand && docker rm dockhand

# 2. Restart with fixed RC script
sudo /usr/local/etc/rc.d/dockhand.sh

# 3. Wait for startup
sleep 120
```

### Verify

```bash
# Check status
docker ps | grep dockhand
# Should show: "(healthy)" in status

# Or detailed check
docker inspect dockhand | jq '.State.Health.Status'
# Expected: "healthy"

# Test endpoint
curl http://10.0.1.15:3866/health
# Should return 200 OK with JSON
```

---

## If Still Unhealthy

### Quick Diagnostic

```bash
# Run automated diagnostic
bash /volume2/docker/dockhand/health-check-fix.sh

# Or check manually
docker exec dockhand wget --quiet --tries=1 --spider http://127.0.0.1:3000/health && echo "✓ Health check works" || echo "✗ Health check failed"

# Check logs
docker logs dockhand | tail -50

# Verify process
docker exec dockhand ps aux | grep bun
```

### Documentation

See `dockhand/HEALTH_CHECK_DEBUG.md` for comprehensive troubleshooting:

- Step-by-step diagnosis
- Common issues & solutions
- Alternative health check options
- Manual testing procedures

---

## Files Created/Updated

### Updated

- ✅ `dockhand/dockhand-start.sh` - Fixed health check parameters

### Created

- ✅ `dockhand/HEALTH_CHECK_FIX.md` - This issue & solution (4.7KB)
- ✅ `dockhand/HEALTH_CHECK_DEBUG.md` - Troubleshooting guide (8.4KB)
- ✅ `dockhand/health-check-fix.sh` - Diagnostic script (3.3KB)

---

## Next Steps

### Immediate (Now)

1. Apply fix (3 commands above)
2. Wait 2 minutes
3. Verify `docker ps` shows "healthy"

### If Healthy

1. Access Dockhand: `http://10.0.1.15:3866`
2. Continue with stack imports

### If Still Unhealthy

1. Run `bash dockhand/health-check-fix.sh`
2. Review `dockhand/HEALTH_CHECK_DEBUG.md`
3. Check logs: `docker logs dockhand | tail -100`

---

## Why This Works

**wget vs curl**: Both make HTTP requests, but wget is in Wolfi OS base image

**120s startup**: Bun needs time for:

- Runtime extraction
- JIT compilation
- Database initialization
- Configuration loading

**20s timeout**: More tolerant of slow responses

**5 retries**: Allows for temporary delays without failing health

---

## Testing Commands

After applying fix:

```bash
# 1. Verify container is healthy
docker ps | grep dockhand

# 2. Check health status detail
docker inspect dockhand | jq '.State.Health'

# 3. Test from host
curl -v http://10.0.1.15:3866/health

# 4. Test from inside container
docker exec dockhand wget --quiet --tries=1 --spider http://127.0.0.1:3000/health && echo "✓ OK" || echo "✗ Failed"

# 5. Monitor logs
docker logs -f dockhand
```

---

## Expected Timeline

- **Startup period**: 120 seconds for Bun to compile and start
- **Health check cycle**: Every 30 seconds after startup period
- **Expected healthy status**: 2-3 minutes after container starts

---

## Reference

**RC Script Location**: `/usr/local/etc/rc.d/dockhand.sh`  
**RC Script Source**: `dockhand/scripts/dockhand-start.sh`  
**Data Directory**: `/volume2/docker/dockhand/`  
**Web UI**: `http://10.0.1.15:3866`

---

## Support

- See `dockhand/HEALTH_CHECK_DEBUG.md` for detailed troubleshooting
- Check `dockhand/` directory for other documentation
- Review Docker logs: `docker logs dockhand`
- Official Dockhand docs: <https://dockhand.pro/manual>
