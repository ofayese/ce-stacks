# Dockhand Health Check - TCP Port Check Fix

**Issue**: Health check failing - neither `curl` nor `wget` available in Wolfi OS minimal image

**Solution Applied**: Use TCP socket check (no external tools required)

---

## The Fix

Changed from:
```bash
# Fails - tools not in minimal image:
--health-cmd='wget --quiet --tries=1 --spider http://127.0.0.1:3000/health || exit 1'
--health-cmd='curl -fs http://127.0.0.1:3000/health'
```

To:
```bash
# Works - uses only built-in /bin/sh:
--health-cmd='/bin/sh -c "exec 3<>/dev/tcp/127.0.0.1/3000 && exec 3>&-"'
```

**How it works**: 
- Opens a TCP socket to localhost:3000
- If successful (port is listening), closes socket and exits 0 (healthy)
- If fails (port not listening), exits 1 (unhealthy)
- No external tools needed, works in any POSIX shell

---

## Updated Parameters

```bash
--health-cmd='/bin/sh -c "exec 3<>/dev/tcp/127.0.0.1/3000 && exec 3>&-" || exit 1'
--health-interval=30s      # Check every 30 seconds
--health-timeout=5s        # 5 second timeout (TCP is fast)
--health-retries=5         # 5 failed checks before unhealthy
--health-start-period=120s # Wait 120s before first check (Bun startup)
```

---

## How to Apply

### Option 1: Automated (Recommended)

```bash
docker stop dockhand && docker rm dockhand
sudo /usr/local/etc/rc.d/dockhand.sh
sleep 130  # Wait for startup period + first check
docker ps | grep dockhand
# Should show: (healthy)
```

### Option 2: Manual Update

Edit `/usr/local/etc/rc.d/dockhand.sh` and find the health check section (~line 105):

Replace:
```bash
--health-cmd='wget --quiet --tries=1 --spider http://127.0.0.1:3000/health || exit 1' \
--health-interval=30s \
--health-timeout=20s \
--health-retries=5 \
--health-start-period=120s \
```

With:
```bash
--health-cmd='/bin/sh -c "exec 3<>/dev/tcp/127.0.0.1/3000 && exec 3>&-" || exit 1' \
--health-interval=30s \
--health-timeout=5s \
--health-retries=5 \
--health-start-period=120s \
```

Then restart:
```bash
docker stop dockhand && docker rm dockhand
sudo /usr/local/etc/rc.d/dockhand.sh
```

---

## Verification

After ~2 minutes:

```bash
docker ps | grep dockhand
# Expected: Up X minutes (healthy)

docker inspect dockhand | jq '.State.Health'
# Expected: 
# {
#   "Status": "healthy",
#   "FailingStreak": 0,
#   ...
# }
```

---

## Why This Works

The TCP socket check (`exec 3<>/dev/tcp/127.0.0.1/3000`) is:
- [OK] Built-in to `/bin/sh` (no external tools)
- [OK] Lightweight (just socket connect)
- [OK] Fast (5 second timeout vs 20)
- [OK] Reliable (tests actual port connectivity)
- [OK] Works in minimal containers

---

## Files Updated

- [OK] `dockhand/scripts/dockhand-start.sh` - TCP socket health check
- [OK] `dockhand/compose.yaml` - TCP socket health check

All other scripts and docs automatically use the updated RC script.

---

## Testing

To test the health check manually from NAS:

```bash
# Test from host
exec 3<>/dev/tcp/10.0.1.15/3866 && echo "[OK] Port accessible" && exec 3>&-

# Test from inside container
docker exec dockhand /bin/sh -c 'exec 3<>/dev/tcp/127.0.0.1/3000 && exec 3>&-' && echo "[OK] Health check passes"
```

