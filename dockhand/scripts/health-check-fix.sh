#!/bin/bash
# Dockhand Health Check - Quick Fix Script
# Run this on your NAS to diagnose and fix the health check issue

set -e

# Synology non-interactive SSH does not include /usr/local/bin in PATH.
# Resolve docker binary once; caller can override via DOCKER=/path/to/docker.
DOCKER="${DOCKER:-$(command -v docker 2>/dev/null || echo /usr/local/bin/docker)}"

echo "=== DOCKHAND HEALTH CHECK QUICK FIX ==="
echo ""

# Step 1: Diagnosis
echo "STEP 1: Gathering diagnostics..."
echo ""

# Get container status
echo "Container Status:"
"${DOCKER}" ps | grep dockhand || echo "❌ Container not found"
echo ""

# Get health status
echo "Health Status:"
"${DOCKER}" inspect dockhand 2>/dev/null | jq '.State.Health.Status' 2>/dev/null || echo "❌ Cannot get health status"
echo ""

# Test health endpoint from host
echo "Testing health endpoint (from host at 10.0.1.15:3866):"
if curl -s -o /dev/null -w "%{http_code}" http://10.0.1.15:3866/health 2>/dev/null | grep -q "200"; then
    echo "✓ Health endpoint responds with 200"
else
    echo "❌ Health endpoint failed"
fi
echo ""

# Test inside container
echo "Testing health endpoint (from container at 127.0.0.1:3000):"
if "${DOCKER}" exec dockhand curl -s http://127.0.0.1:3000/health >/dev/null 2>&1; then
    echo "✓ Health endpoint responds from inside container"
else
    echo "❌ Health endpoint failed from inside container"
    echo ""
    echo "Checking if curl exists in container..."
    if "${DOCKER}" exec dockhand which curl >/dev/null 2>&1; then
        echo "✓ curl is installed"
    else
        echo "❌ curl NOT FOUND - this is likely the problem!"
        echo ""
        echo "Checking for wget instead..."
        if "${DOCKER}" exec dockhand which wget >/dev/null 2>&1; then
            echo "✓ wget is available - we can use this!"
        else
            echo "⚠️  neither curl nor wget found"
        fi
    fi
fi
echo ""

# Step 2: Show logs
echo "Recent logs (last 30 lines):"
"${DOCKER}" logs dockhand 2>/dev/null | tail -30 || echo "Cannot read logs"
echo ""

# Step 3: Provide fix options
echo "=== RECOMMENDED FIX ==="
echo ""
echo "The health check is likely failing because:"
echo "1. curl may not be installed in the minimal Wolfi OS image"
echo "2. Application startup takes longer than 60s"
echo ""
echo "SOLUTION: Update the RC script health check"
echo ""
echo "Edit: /volume2/docker/dockhand/scripts/dockhand-start.sh"
echo ""
echo "Find this line:"
echo "  --health-cmd='curl -fs http://127.0.0.1:3000/health >/dev/null || exit 1' \\"
echo ""
echo "Replace with ONE of these options:"
echo ""
echo "OPTION A (wget):"
echo "  --health-cmd='wget --quiet --tries=1 --spider http://127.0.0.1:3000/health || exit 1' \\"
echo ""
echo "OPTION B (extended timeout):"
echo "  --health-cmd='curl -fs http://127.0.0.1:3000/health >/dev/null || exit 1' \\"
echo "  --health-timeout=20s \\"
echo "  --health-start-period=120s \\"
echo ""
echo "OPTION C (netcat - if available):"
echo "  --health-cmd='/bin/sh -c \"nc -z 127.0.0.1 3000 || exit 1\"' \\"
echo ""
echo "=== APPLY FIX ==="
echo ""
echo "After editing the RC script:"
echo ""
echo "  1. Stop container:"
echo "     docker stop dockhand && docker rm dockhand"
echo ""
echo "  2. Restart via RC script:"
echo "     sudo /usr/local/etc/rc.d/dockhand.sh"
echo ""
echo "  3. Wait 2 minutes for startup:"
echo "     sleep 120"
echo ""
echo "  4. Check status:"
echo "     docker ps | grep dockhand"
echo "     docker inspect dockhand | jq '.State.Health.Status'"
echo ""
echo "Expected result: Status should change from 'unhealthy' to 'healthy'"
echo ""

