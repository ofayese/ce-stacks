# Dockhand Health Check - Debugging Guide

**Issue**: Health check failing with `CMD-SHELL curl -fs http://127.0.0.1:3000/health >/dev/null || exit 1`

**Status**: Container running but marked unhealthy

---

## Step 1: SSH to NAS and Verify Container Status

```bash
ssh user@10.0.1.15

# Check if container is running
docker ps | grep dockhand

# Expected output:
# dockhand   fnsys/dockhand:latest   ...   Up X minutes (unhealthy)
```

---

## Step 2: Check Health Status Details

```bash
# Get detailed health info
docker inspect dockhand | jq '.State.Health'

# Expected output (currently failing):
{
  "Status": "unhealthy",
  "FailingStreak": X,
  "Log": [
    {
      "Start": "2026-05-13T...",
      "End": "2026-05-13T...",
      "ExitCode": 1,
      "Output": "..."
    }
  ]
}
```

---

## Step 3: Check Container Logs

```bash
# View last 50 lines
docker logs dockhand | tail -50

# View with timestamps
docker logs --timestamps dockhand | tail -30

# Look for:
# - Startup errors
# - Port binding issues
# - Application errors
# - Warning messages about /health endpoint
```

---

## Step 4: Test Health Check Manually

The health check runs: `CMD-SHELL curl -fs http://127.0.0.1:3000/health >/dev/null || exit 1`

Test it inside the container:

```bash
# Option 1: Execute curl from host to container
curl -v http://10.0.1.15:3866/health

# Expected: HTTP 200 (not 127.0.0.1 - that's localhost in container)

# Option 2: Execute curl inside container
docker exec dockhand curl -fs http://127.0.0.1:3000/health

# Expected: HTTP 200 or JSON response

# Option 3: Test with verbose output
docker exec dockhand curl -v http://127.0.0.1:3000/health 2>&1

# Option 4: Check if curl is installed
docker exec dockhand which curl

# Option 5: Check if port is listening
docker exec dockhand netstat -tlnp | grep 3000
# or
docker exec dockhand ss -tlnp | grep 3000
```

---

## Step 5: Check Port Binding

```bash
# Verify port binding on host
netstat -tlnp | grep 3866
# or
ss -tlnp | grep 3866

# Expected:
# tcp  0  0  10.0.1.15:3866  0.0.0.0:*  LISTEN  <PID>/docker-proxy

# Verify from container networking
docker inspect dockhand | jq '.NetworkSettings.Ports'

# Expected:
{
  "3000/tcp": [
    {
      "HostIp": "10.0.1.15",
      "HostPort": "3866"
    }
  ]
}
```

---

## Step 6: Check Application Startup

```bash
# Verify Bun runtime started successfully
docker logs dockhand | grep -i "bun\|listening\|started\|server"

# Look for:
# - "Listening on" or similar server startup message
# - Any errors during initialization
# - Port conflicts

# Check if application is actually ready
docker exec dockhand ps aux | grep -i bun
# or
docker exec dockhand ps aux | grep -i node
```

---

## Step 7: Network Issues Diagnosis

```bash
# Check container network connectivity
docker exec dockhand ping 8.8.8.8

# Check DNS resolution
docker exec dockhand cat /etc/resolv.conf

# Verify ce-internal network attachment
docker inspect dockhand | jq '.NetworkSettings.Networks'

# Expected:
{
  "ce-internal": {
    "IPAMConfig": null,
    "Links": null,
    "Aliases": null,
    "NetworkID": "...",
    "EndpointID": "...",
    "Gateway": "172.26.0.1",
    "IPAddress": "172.26.x.x",
    "IPPrefixLen": 24,
    "IPv6Gateway": "",
    "IPv6Address": "",
    "MacAddress": "..."
  }
}
```

---

## Common Issues & Solutions

### Issue 1: Curl Not Found in Container
```bash
# Check if curl is available
docker exec dockhand which curl
# Output: (empty/not found)

# Solution: Change health check to use wget or built-in command
# Update compose.yaml or RC script health check
```

### Issue 2: Application Not Ready
```bash
# Check logs for startup time
docker logs dockhand | grep -E "startup|initialization|ready"

# Solution: Increase health-start-period in compose.yaml
# Current: 60s, try: 90s or 120s
```

### Issue 3: Port Not Listening
```bash
# Check if port 3000 is actually listening inside container
docker exec dockhand netstat -tlnp 2>/dev/null | grep 3000
# or try curl from inside
docker exec dockhand curl -s http://127.0.0.1:3000 2>&1

# If fails: app may not have started or crashed
docker logs dockhand | tail -100  # Check for errors
```

### Issue 4: Network Not Reachable
```bash
# Verify ce-internal network exists
docker network ls | grep ce-internal

# If missing: CREATE IT NOW
docker network create \
  --driver bridge \
  --subnet 172.26.0.0/24 \
  --gateway 172.26.0.1 \
  ce-internal

# Reconnect container to network
docker network connect ce-internal dockhand
```

### Issue 5: Health Check Timeout
```bash
# If curl is slow or hanging, increase timeout
# Current health check: 10 second timeout
# Try: 15 or 20 seconds

# In RC script (dockhand-start.sh):
# --health-timeout=10s  -> change to 20s
```

---

## Quick Diagnosis Script

Run this on NAS to get all relevant info:

```bash
#!/bin/bash

echo "=== DOCKHAND HEALTH CHECK DIAGNOSIS ==="
echo ""

echo "1. Container Status:"
docker ps | grep dockhand
echo ""

echo "2. Health Status:"
docker inspect dockhand | jq '.State.Health'
echo ""

echo "3. Last 20 Log Lines:"
docker logs dockhand | tail -20
echo ""

echo "4. Health Check Test (from host):"
curl -s -I http://10.0.1.15:3866/health || echo "FAILED"
echo ""

echo "5. Health Check Test (from container):"
docker exec dockhand curl -s http://127.0.0.1:3000/health | head -50 || echo "FAILED"
echo ""

echo "6. Port Binding:"
docker inspect dockhand | jq '.NetworkSettings.Ports'
echo ""

echo "7. Network Attachment:"
docker inspect dockhand | jq '.NetworkSettings.Networks | keys'
echo ""

echo "8. Process Inside Container:"
docker exec dockhand ps aux | grep -i "bun\|dockhand" || echo "No processes found"
echo ""

echo "9. Curl Availability:"
docker exec dockhand which curl || echo "curl NOT FOUND - this is the problem!"
```

---

## Most Likely Issues (In Order)

1. **Curl not installed** (Wolfi OS minimal image)
   - Fix: Use wget or different health check

2. **Application startup time** (Bun initialization)
   - Fix: Increase health-start-period to 90-120s

3. **Port not listening** (App crash on startup)
   - Fix: Check logs, verify all dependencies

4. **ce-internal network missing** (Required by compose)
   - Fix: Create network before importing stacks

5. **Health check timeout** (Slow response)
   - Fix: Increase health-timeout to 15-20s

---

## Solution: Fix Health Check

### Option A: Update RC Script (dockhand-start.sh)

Change the health check command to something available in Wolfi OS:

```bash
# Current (may fail - curl might not exist)
--health-cmd='curl -fs http://127.0.0.1:3000/health >/dev/null || exit 1' \

# Change to (wget - more likely to be available)
--health-cmd='wget --quiet --tries=1 --spider http://127.0.0.1:3000/health || exit 1' \

# Or use /bin/sh with nc (netcat)
--health-cmd='/bin/sh -c "nc -z 127.0.0.1 3000 || exit 1"' \

# Or longer timeout + retry
--health-cmd='curl -f --max-time 15 http://127.0.0.1:3000/health || exit 1' \
--health-timeout=20s \
--health-retries=5 \
--health-start-period=120s \
```

### Option B: Update compose.yaml

If using compose directly:

```yaml
healthcheck:
  test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://127.0.0.1:3000/health"]
  interval: 30s
  timeout: 15s
  retries: 5
  start_period: 120s
```

### Option C: Increase Timing (Quick Fix)

If curl exists but just slow:

```bash
--health-timeout=20s \
--health-retries=5 \
--health-start-period=120s \
```

---

## After Applying Fix

1. Stop container: `docker stop dockhand`
2. Remove container: `docker rm dockhand`
3. Update RC script with fix
4. Restart: `docker /usr/local/etc/rc.d/dockhand.sh`
5. Monitor: `docker ps -a; docker logs -f dockhand`
6. Wait 2-3 minutes for health status to change to "healthy"

---

## Validation

```bash
# Wait 120s (start period), then check
sleep 120

# Check status
docker inspect dockhand | jq '.State.Health.Status'
# Expected: "healthy"

# Check full health info
docker inspect dockhand | jq '.State.Health'
# FailingStreak should be 0
```

---

## If Still Unhealthy

After applying fixes, if still unhealthy:

1. Check logs: `docker logs dockhand | tail -100`
2. Test health endpoint: `curl -v http://10.0.1.15:3866/health`
3. Check inside container: `docker exec dockhand curl -v http://127.0.0.1:3000/health`
4. Verify port: `docker exec dockhand ss -tlnp`
5. Check process: `docker exec dockhand ps aux | grep bun`

---

## Support Information

**Dockhand Official**: https://dockhand.pro/manual
**Your Audit Report**: See AUDIT_REPORT.md for other issues
**RC Script**: `/volume2/docker/dockhand/scripts/dockhand-start.sh`
