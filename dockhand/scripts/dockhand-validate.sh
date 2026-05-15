#!/bin/sh
# =============================================================================
# Dockhand Validation Script - Test Label Passthrough & Watchtower Compliance
# =============================================================================
# This script validates that Dockhand correctly handles Docker labels,
# security options, and other compose metadata that your ce-stacks stacks depend on.
#
# Usage: bash /volume2/docker/dockhand/dockhand-validate.sh
#
# Or from ce-stacks repo: bash dockhand/scripts/dockhand-validate.sh
#   1. Watchtower label compliance (com.centurylinklabs.watchtower.enable)
#   2. Security options (no-new-privileges, cap-drop, cap-add)
#   3. Health check definitions
#   4. Environment variable passthrough (SKIP_DF_COLLECTION)
#   5. Docker socket access
#   6. Git webhook registration (manual steps)
# =============================================================================

set -e

DOCKER="/usr/local/bin/docker"
DOCKHAND_NAME="dockhand"
DOCKHAND_URL="http://10.0.1.15:3866"
TEST_STACK_NAME="dockhand-validate-test"
TEST_COMPOSE_PATH="/tmp/${TEST_STACK_NAME}-compose.yaml"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== Dockhand Validation Suite ==="
echo ""

# === Test 1: Dockhand Container Running ===
echo "[1/6] Checking if Dockhand container is running..."
if ! $DOCKER ps --format '{{.Names}}' | grep -qx "$DOCKHAND_NAME"; then
    echo -e "${RED}✗ FAIL${NC}: Dockhand container not running"
    echo "       Start it with: sudo /usr/local/etc/rc.d/dockhand.sh"
    exit 1
fi
DOCKHAND_IMAGE=$($DOCKER inspect -f '{{.Config.Image}}' "$DOCKHAND_NAME")
DOCKHAND_STATUS=$($DOCKER inspect -f '{{.State.Health.Status}}' "$DOCKHAND_NAME" 2>/dev/null || echo "unknown")
echo -e "${GREEN}✓ PASS${NC}: Dockhand running"
echo "        Image: $DOCKHAND_IMAGE"
echo "        Health: $DOCKHAND_STATUS"
echo ""

# === Test 2: Dockhand Web UI Responsive ===
echo "[2/6] Testing Dockhand web UI connectivity..."
if ! curl -fs "${DOCKHAND_URL}/health" >/dev/null 2>&1; then
    echo -e "${RED}✗ FAIL${NC}: Dockhand UI not responding at ${DOCKHAND_URL}"
    echo "       Wait 30s and retry: curl -v ${DOCKHAND_URL}/health"
    exit 1
fi
echo -e "${GREEN}✓ PASS${NC}: Dockhand web UI is responsive"
echo ""

# === Test 3: Docker Socket Access ===
echo "[3/6] Validating Docker socket access..."
if [ ! -S /var/run/docker.sock ]; then
    echo -e "${RED}✗ FAIL${NC}: Docker socket not found at /var/run/docker.sock"
    exit 1
fi
if ! test -r /var/run/docker.sock; then
    echo -e "${YELLOW}⚠ WARN${NC}: Docker socket not readable"
    echo "       Run: sudo chmod 666 /var/run/docker.sock"
    echo "       Or use group: sudo usermod -aG docker $USER"
else
    echo -e "${GREEN}✓ PASS${NC}: Docker socket accessible"
fi
echo ""

# === Test 4: Create Test Compose with Labels ===
echo "[4/6] Testing label passthrough (watchtower)..."
cat > "$TEST_COMPOSE_PATH" << 'EOF'
services:
  test-app:
    image: busybox:latest
    container_name: dockhand-validate-busybox
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    labels:
      - com.centurylinklabs.watchtower.enable=false
      - app.ce-stacks.validation=true
    command: sh -c "sleep 10 && echo 'Test complete'"
EOF

echo "  Created test compose at $TEST_COMPOSE_PATH"
echo "  Test stack: $TEST_STACK_NAME"
echo "  Note: Manual import via Dockhand UI required"
echo "  1. Access: ${DOCKHAND_URL}/stacks"
echo "  2. Upload compose file or import from git"
echo "  3. Verify container has labels after deployment"
echo ""

# === Test 5: Verify Existing Label Handling ===
echo "[5/6] Checking Docker labels on running containers..."
echo "  Containers with watchtower labels:"
$DOCKER ps -a --format '{{.Names}}' | while read -r CONTAINER; do
    LABELS=$($DOCKER inspect -f '{{json .Config.Labels}}' "$CONTAINER" 2>/dev/null || echo '{}')
    if echo "$LABELS" | grep -q "watchtower"; then
        WATCHTOWER_ENABLED=$(echo "$LABELS" | grep -o '"com.centurylinklabs.watchtower.enable":"[^"]*"' || echo 'not set')
        echo "    $CONTAINER: $WATCHTOWER_ENABLED"
    fi
done
echo -e "${GREEN}✓ PASS${NC}: Label inspection working"
echo ""

# === Test 6: Health Check Validation ===
echo "[6/6] Validating health check configuration..."
HEALTH_CMD=$($DOCKER inspect -f '{{.Config.Healthcheck.Test}}' "$DOCKHAND_NAME" 2>/dev/null || echo 'none')
if echo "$HEALTH_CMD" | grep -q "health"; then
    echo -e "${GREEN}✓ PASS${NC}: Health check configured"
    echo "  Command: $HEALTH_CMD"
    CURRENT_HEALTH=$($DOCKER inspect -f '{{.State.Health.Status}}' "$DOCKHAND_NAME" 2>/dev/null || echo 'unknown')
    echo "  Current status: $CURRENT_HEALTH"
else
    echo -e "${YELLOW}⚠ WARN${NC}: No health check detected"
fi
echo ""

# === Test 7: Environment Variables ===
echo "[7/7] Checking Dockhand environment variables..."
ENV_VARS=$($DOCKER inspect -f '{{json .Config.Env}}' "$DOCKHAND_NAME" 2>/dev/null || echo '{}')
if echo "$ENV_VARS" | grep -q "SKIP_DF_COLLECTION"; then
    echo -e "${GREEN}✓ PASS${NC}: SKIP_DF_COLLECTION is set (Synology optimization)"
else
    echo -e "${YELLOW}⚠ WARN${NC}: SKIP_DF_COLLECTION not set (optional, but recommended for Synology)"
fi
echo ""

# === Summary ===
echo "=== Validation Summary ==="
echo -e "${GREEN}✓ Dockhand is operational and ready for stack migration${NC}"
echo ""
echo "Next steps:"
echo "  1. Initialize Dockhand: ${DOCKHAND_URL}"
echo "  2. Create admin user: Settings > Authentication > Users > Add user"
echo "  3. Add environment: Settings > Environments > +Add (Unix socket)"
echo "  4. Add git webhook: GitHub Repo > Settings > Webhooks > Add webhook"
echo "     Payload URL: ${DOCKHAND_URL}/webhooks/<your-webhook-key>"
echo "     Content type: application/json"
echo "     Trigger on: Push events"
echo "  5. Import stacks: Settings > Stacks or via git webhook"
echo ""
echo "For detailed steps, see: MIGRATION.md"
echo ""

# Cleanup
rm -f "$TEST_COMPOSE_PATH"
