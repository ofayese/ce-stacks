#!/bin/sh
# =============================================================================
# [HISTORICAL] Dockhand Migration Script - Portainer -> Dockhand helper
# =============================================================================
# Retained for reference only. Portainer is no longer part of this topology
# and this script is NOT part of the current deploy flow. The canonical
# deployment path is:
#
#   1. git clone ... /volume2/docker/ce-stacks
#   2. bash /volume2/docker/ce-stacks/scripts/init-nas.sh
#      (or, for Dockhand-only updates) bash scripts/dockhand-sync.sh
#   3. sudo cp /volume2/docker/dockhand/scripts/dockhand-start.sh \
#        /usr/local/etc/rc.d/dockhand.sh && sudo chmod +x ...
#   4. sudo /usr/local/etc/rc.d/dockhand.sh
#
# Do not run this script on a fresh install. It assumes a live Portainer
# deployment exists at $PORTAINER_DATA. See dockhand/docs/MIGRATION.md and
# DOCKHAND_MIGRATION.md (repo root) for the current workflow.
#
# Original purpose (preserved verbatim below):
# This script prepares your ce-stacks for migration from Portainer to Dockhand.
#
# Usage: bash /volume2/docker/dockhand/scripts/dockhand-migration.sh [--export-only] [--test-import]
# Or from ce-stacks repo: bash dockhand/scripts/dockhand-migration.sh
#   1. Backup Portainer data (optional safeguard)
#   2. Verify all compose.yaml files are valid (docker compose config)
#   3. List stacks ready for import into Dockhand
#   4. Test import of one low-risk stack (optional: --test-import)
#   5. Generate migration checklist
# =============================================================================

set -e

DOCKER="/usr/local/bin/docker"
PORTAINER_DATA="${PORTAINER_DATA:-/volume2/docker/portainer}"
DOCKHAND_DATA="${DOCKHAND_DATA:-/volume2/docker/dockhand}"
STACK_ROOT="${STACK_ROOT:-/volume2/docker/ce-stacks}"
MIGRATION_LOG="/tmp/dockhand-migration-$(date +%s).log"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

export_only=false
test_import=false

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --export-only) export_only=true ;;
        --test-import) test_import=true ;;
    esac
done

echo "=== Dockhand Migration Script ==="
echo "Log: $MIGRATION_LOG"
echo ""

# === Backup Portainer Data ===
echo "[1/5] Backing up Portainer data..."
PORTAINER_BACKUP="/tmp/portainer-backup-$(date +%s).tar.gz"
if [ -d "$PORTAINER_DATA" ]; then
    echo "  Creating backup: $PORTAINER_BACKUP"
    tar -czf "$PORTAINER_BACKUP" -C "$(dirname "$PORTAINER_DATA")" "$(basename "$PORTAINER_DATA")" 2>/dev/null || true
    echo -e "  ${GREEN}[OK] Backup created${NC}"
    echo "  To restore: tar -xzf $PORTAINER_BACKUP -C /"
else
    echo -e "  ${YELLOW}[WARN] Portainer data not found at $PORTAINER_DATA${NC}"
fi
echo ""

# === Validate Compose Files ===
echo "[2/5] Validating all compose.yaml files..."
VALID_STACKS=0
INVALID_STACKS=0
STACKS_TO_MIGRATE=()

for stack_dir in "$STACK_ROOT"/stacks/*/; do
    stack_name=$(basename "$stack_dir")

    # Skip hidden directories and archives
    if [[ "$stack_name" == _* ]] || [ "$stack_name" = "archives" ]; then
        continue
    fi

    compose_file="$stack_dir/compose.yaml"
    if [ ! -f "$compose_file" ]; then
        continue
    fi

    # Validate compose syntax
    if $DOCKER compose -f "$compose_file" config >/dev/null 2>&1; then
        echo "  ${GREEN}[OK]${NC} $stack_name"
        STACKS_TO_MIGRATE+=("$stack_name")
        VALID_STACKS=$((VALID_STACKS + 1))
    else
        echo "  ${RED}[FAIL]${NC} $stack_name (INVALID SYNTAX)"
        INVALID_STACKS=$((INVALID_STACKS + 1))
    fi
done

echo ""
echo "  Summary: $VALID_STACKS valid, $INVALID_STACKS invalid"
echo ""

if [ $INVALID_STACKS -gt 0 ]; then
    echo -e "${RED}ERROR: Fix invalid compose files before migration${NC}"
    exit 1
fi

# === Export Stack Metadata ===
echo "[3/5] Exporting stack metadata..."
EXPORT_FILE="$STACK_ROOT/.dockhand-export-$(date +%s).json"

cat > "$EXPORT_FILE" << EOF
{
  "migration_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "stacks": [
EOF

for i in "${!STACKS_TO_MIGRATE[@]}"; do
    stack_name="${STACKS_TO_MIGRATE[$i]}"
    stack_dir="$STACK_ROOT/stacks/$stack_name"

    echo "    {" >> "$EXPORT_FILE"
    echo "      \"name\": \"$stack_name\"," >> "$EXPORT_FILE"
    echo "      \"path\": \"stacks/$stack_name/compose.yaml\"," >> "$EXPORT_FILE"
    echo "      \"has_env_file\": $([ -f "$stack_dir/.env.example" ] && echo 'true' || echo 'false')," >> "$EXPORT_FILE"
    echo "      \"has_secrets\": $([ -d "$stack_dir/secrets" ] && echo 'true' || echo 'false')" >> "$EXPORT_FILE"

    if [ $i -lt $((${#STACKS_TO_MIGRATE[@]} - 1)) ]; then
        echo "    }," >> "$EXPORT_FILE"
    else
        echo "    }" >> "$EXPORT_FILE"
    fi
done

cat >> "$EXPORT_FILE" << EOF
  ]
}
EOF

echo -e "  ${GREEN}[OK] Export created${NC}: $EXPORT_FILE"
echo ""

# === List Stacks Ready for Migration ===
echo "[4/5] Stacks ready for migration (${#STACKS_TO_MIGRATE[@]} total):"
echo ""
for stack in "${STACKS_TO_MIGRATE[@]}"; do
    echo "  * $stack"
done
echo ""

# === Optional: Test Import of Low-Risk Stack ===
if [ "$test_import" = true ]; then
    echo "[5/5] Testing import of low-risk stack (it-tools)..."

    if [ -f "$STACK_ROOT/stacks/it-tools/compose.yaml" ]; then
        echo "  Preparing test import..."
        # Copy to temp location for Dockhand import
        TEST_COMPOSE="/tmp/test-import-it-tools.yaml"
        cp "$STACK_ROOT/stacks/it-tools/compose.yaml" "$TEST_COMPOSE"

        echo "  Test compose file: $TEST_COMPOSE"
        echo "  Manual steps:"
        echo "    1. Access Dockhand: http://10.0.1.15:3866/stacks"
        echo "    2. Click 'Create Stack' > 'Upload Compose File'"
        echo "    3. Upload: $TEST_COMPOSE"
        echo "    4. Name: 'it-tools' | Environment: 'DS723'"
        echo "    5. Deploy and verify container starts"
        echo "    6. Check labels: docker inspect it-tools | grep -A5 Labels"
        echo ""
    fi
fi

# === Migration Checklist ===
echo "=== Migration Checklist ==="
echo ""
echo "Before migration:"
echo "  [ ] Stop and backup all Portainer data"
echo "  [ ] Verify Dockhand is running and healthy"
echo "  [ ] Test git webhook registration (see MIGRATION.md)"
echo ""
echo "During migration:"
echo "  [ ] Import stacks via Dockhand UI (one per stack)"
echo "  [ ] For each stack:"
echo "      [ ] Upload compose.yaml"
echo "      [ ] Create .env if needed (copy from .env.example)"
echo "      [ ] Deploy and verify container health"
echo "      [ ] Check labels: docker inspect <container> | jq .Config.Labels"
echo ""
echo "After migration:"
echo "  [ ] Verify all stacks running in Dockhand"
echo "  [ ] Test git webhook on repo push"
echo "  [ ] Confirm watchtower labels respected (docker labels)"
echo "  [ ] Stop Portainer: sudo /usr/local/etc/rc.d/portainer.sh stop"
echo "  [ ] Remove Portainer: docker rm portainer portainer_agent"
echo "  [ ] Delete Portainer RC script: sudo rm /usr/local/etc/rc.d/portainer.sh"
echo ""

echo -e "${GREEN}[OK] Migration preparation complete${NC}"
echo ""
echo "Next steps:"
echo "  1. Read MIGRATION.md for detailed instructions"
echo "  2. Set up git webhooks (GitHub repo > Settings > Webhooks)"
echo "  3. Import stacks via Dockhand UI or git webhook"
echo "  4. Validate each stack with: bash scripts/dockhand-validate.sh"
echo ""
