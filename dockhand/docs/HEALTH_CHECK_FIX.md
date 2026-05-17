# Dockhand Health Check - Issue & Fix

**Issue**: Health check failing with `CMD-SHELL curl -fs http://127.0.0.1:3000/health >/dev/null || exit 1`

**Status**: Marked unhealthy despite container running

**Root Cause**: Wolfi OS minimal image may not have curl installed, and 60s startup period may be too short for Bun application initialization.

---

## [OK] Fix Applied

Updated `dockhand/scripts/dockhand-start.sh` health check with:

**Before:**

```bash
--health-cmd='curl -fs http://127.0.0.1:3000/health >/dev/null || exit 1' \
--health-interval=30s \
--health-timeout=10s \
--health-retries=3 \
--health-start-period=60s \
```

**After (More Robust):**

```bash
--health-cmd='wget --quiet --tries=1 --spider http://127.0.0.1:3000/health || exit 1' \
--health-interval=30s \
--health-timeout=20s \
--health-retries=5 \
--health-start-period=120s \
```

**Changes:**

- [OK] Use `wget` instead of `curl` (more likely available in Wolfi OS)
- [OK] Increased timeout from 10s to 20s
- [OK] Increased retries from 3 to 5
- [OK] Doubled startup period from 60s to 120s (Bun needs time to compile/start)

---

## How to Apply Fix

### Option 1: Quick Deploy (Recommended)

```bash
# On NAS:

# 1. Stop current container
docker stop dockhand && docker rm dockhand

# 2. Restart using updated RC script
sudo /usr/local/etc/rc.d/dockhand.sh

# 3. Wait for startup (120s minimum)
sleep 120

# 4. Check health status
docker ps | grep dockhand
# Should show: "(healthy)" instead of "(unhealthy)"

# 5. Verify with inspect
docker inspect dockhand | jq '.State.Health'
# Status should be "healthy"
```

### Option 2: Manual RC Script Update

If you want to update manually:

```bash
# 1. Edit the RC script
sudo nano /usr/local/etc/rc.d/dockhand.sh

# 2. Find this section (around line 75):
#   --health-cmd='curl -fs...
#   --health-timeout=10s...
#   --health-start-period=60s...

# 3. Replace with:
#   --health-cmd='wget --quiet --tries=1 --spider http://127.0.0.1:3000/health || exit 1' \
#   --health-timeout=20s \
#   --health-start-period=120s \

# 4. Save and exit (Ctrl+X, Y, Enter)

# 5. Restart container
docker stop dockhand && docker rm dockhand
sudo /usr/local/etc/rc.d/dockhand.sh
```

---

## Verification

After applying the fix:

```bash
# Check container status (should show healthy after 2-3 minutes)
docker ps | grep dockhand

# Verify health in detail
docker inspect dockhand | jq '.State.Health'

# Expected output:
{
  "Status": "healthy",
  "FailingStreak": 0,
  "Log": [
    {
      "Start": "2026-05-13T...",
      "End": "2026-05-13T...",
      "ExitCode": 0,
      "Output": ""
    }
  ]
}

# Test health endpoint manually
curl http://10.0.1.15:3866/health
# Should return JSON response with 200 OK
```

---

## Why This Fix Works

1. **wget vs curl**: Wolfi OS minimal image may ship with wget but not curl. wget is available in most Alpine/Wolfi-based images.

2. **Extended startup period**: Bun runtime needs time to:
   - Extract itself
   - Compile/JIT the application
   - Initialize database connections
   - Load configuration

   60 seconds is often not enough for a fresh start.

3. **Longer timeout**: If the application is under load or slow to respond, 10 seconds timeout is too aggressive. 20s is more forgiving.

4. **More retries**: With slower startup, allowing 5 retries instead of 3 prevents premature failure marking.

---

## If Still Unhealthy After Fix

Run the diagnostic script:

```bash
bash /volume2/docker/dockhand/scripts/health-check-fix.sh
```

Or check manually:

```bash
# 1. Verify endpoint from host
curl -v http://10.0.1.15:3866/health

# 2. Check inside container
docker exec dockhand wget --quiet --tries=1 --spider http://127.0.0.1:3000/health && echo "[OK] Health check works" || echo "[FAIL] Health check failed"

# 3. Check logs
docker logs dockhand | tail -50

# 4. Verify process is running
docker exec dockhand ps aux | grep bun

# 5. Check port is listening
docker exec dockhand ss -tlnp | grep 3000
```

---

## Files Updated

- [OK] `dockhand/scripts/dockhand-start.sh` - Updated health check parameters
- [OK] `dockhand/docs/HEALTH_CHECK_DEBUG.md` - Created comprehensive debugging guide
- [OK] `dockhand/scripts/health-check-fix.sh` - Created diagnostic script

---

## Documentation

Full debugging guide available at: `dockhand/docs/HEALTH_CHECK_DEBUG.md`

Contains:

- Step-by-step diagnosis procedures
- Common issues and solutions
- Manual testing commands
- Alternative health check options

---

## Next Steps

1. **Apply fix** using Option 1 above
2. **Wait 2-3 minutes** for container to startup
3. **Verify** with `docker ps` (should show "healthy")
4. **Test** with `curl http://10.0.1.15:3866/health`
5. **Monitor** logs: `docker logs -f dockhand`

---

## Support

If health check still fails after applying fix:

1. See `dockhand/HEALTH_CHECK_DEBUG.md` for detailed troubleshooting
2. Check `dockhand/` directory for additional documentation
3. Review Docker logs: `docker logs dockhand | tail -100`
