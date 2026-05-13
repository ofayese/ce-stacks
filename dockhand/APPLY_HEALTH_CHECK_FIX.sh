#!/bin/bash
# Dockhand Health Check - Definitive Fix
# Run this on NAS to fix unhealthy status

set -e

echo "═══════════════════════════════════════════════════════════════════════════"
echo "DOCKHAND HEALTH CHECK - DEFINITIVE FIX"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# Step 1: Diagnose current state
echo "STEP 1: Checking current health check configuration..."
echo ""

echo "Current health check command:"
docker inspect dockhand | jq '.Config.Healthcheck.Test' 2>/dev/null || echo "Cannot read health check"

echo ""
echo "Last 3 health check results:"
docker inspect dockhand | jq '.State.Health.Log[-3:] | .[] | {Start: .Start, ExitCode: .ExitCode, Output: .Output}' 2>/dev/null || echo "Cannot read health log"

echo ""
echo "Does curl exist in container?"
if docker exec dockhand which curl >/dev/null 2>&1; then
    echo "✓ Yes - curl is available"
else
    echo "✗ No - curl NOT found (this is the problem!)"
fi

echo ""
echo "Does wget exist in container?"
if docker exec dockhand which wget >/dev/null 2>&1; then
    echo "✓ Yes - wget is available (we'll use this)"
else
    echo "✗ No - wget not found either"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "STEP 2: Applying fix..."
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

echo "Stopping and removing old container..."
docker stop dockhand || true
docker rm dockhand || true

echo "Updating RC script with fixed health check..."
sudo cp /volume2/docker/ce-stacks/dockhand/dockhand-start.sh /usr/local/etc/rc.d/dockhand.sh
sudo chmod +x /usr/local/etc/rc.d/dockhand.sh

echo "Restarting Dockhand with fixed RC script..."
sudo /usr/local/etc/rc.d/dockhand.sh

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "STEP 3: Waiting for startup (120 seconds)..."
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

for i in {1..12}; do
    echo "Wait ${i}0 seconds... (Press Ctrl+C to skip waiting)"
    sleep 10
done

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "STEP 4: Verifying health status..."
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

HEALTH=$(docker inspect dockhand | jq -r '.State.Health.Status' 2>/dev/null || echo "unknown")

echo "Current health status: $HEALTH"
echo ""

if [ "$HEALTH" = "healthy" ]; then
    echo "✓ SUCCESS! Dockhand is now HEALTHY"
    echo ""
    echo "Container status:"
    docker ps | grep dockhand
    echo ""
    echo "Full health info:"
    docker inspect dockhand | jq '.State.Health'
    echo ""
    echo "You can now access Dockhand at: http://10.0.1.15:3866"
else
    echo "⚠ Still showing as: $HEALTH"
    echo ""
    echo "Running diagnostics..."
    echo ""
    echo "Health check log:"
    docker inspect dockhand | jq '.State.Health.Log[-3:]'
    echo ""
    echo "Container logs (last 30 lines):"
    docker logs dockhand | tail -30
    echo ""
    echo "Troubleshooting:"
    echo "1. Check logs above for errors"
    echo "2. Try: docker exec dockhand wget --quiet --tries=1 --spider http://127.0.0.1:3000/health && echo 'Health check works' || echo 'Health check failed'"
    echo "3. Review: /volume2/docker/dockhand/HEALTH_CHECK_DEBUG.md"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Done!"
echo "═══════════════════════════════════════════════════════════════════════════"
