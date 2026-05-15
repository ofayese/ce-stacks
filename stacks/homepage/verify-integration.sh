#!/bin/bash

# ============================================================================
# Homepage Docker Socket Integration Validation Script
# ============================================================================
#
# PURPOSE
# Verify that Homepage can read container status from the Docker socket.
# Runs 5 diagnostic checks:
#   1. Homepage container is running
#   2. Docker socket is mounted
#   3. Socket is readable from inside container
#   4. All configured services have corresponding containers
#   5. No stale/missing container references
#
# USAGE
#   bash verify-integration.sh
#   (Run from: /volume2/docker/ce-stacks/stacks/homepage)
#
# EXIT CODES
#   0 = All checks passed
#   1 = One or more checks failed (warnings printed)
#
# ============================================================================

set -o pipefail

# Synology non-interactive SSH does not include /usr/local/bin in PATH.
# Resolve docker binary once; caller can override via DOCKER=/path/to/docker.
DOCKER="${DOCKER:-$(command -v docker 2>/dev/null || echo /usr/local/bin/docker)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="Homepage"
SOCKET_PATH="/var/run/docker.sock"
CONFIG_DIR="${SCRIPT_DIR}/config"
SERVICES_FILE="${CONFIG_DIR}/services.yaml"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# Helper functions
success() {
	echo -e "${GREEN}✓${NC} $1"
	((PASSED++))
}

error() {
	echo -e "${RED}✗${NC} $1"
	((FAILED++))
}

warning() {
	echo -e "${YELLOW}⚠${NC} $1"
	((WARNINGS++))
}

info() {
	echo "  $1"
}

section() {
	echo ""
	echo "============================================================================"
	echo "$1"
	echo "============================================================================"
}

# ============================================================================
# CHECK 1: Homepage Container is Running
# ============================================================================

section "CHECK 1: Homepage Container Status"

if "${DOCKER}" ps --filter "name=${CONTAINER_NAME}" --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
	success "Homepage container is running"
	CONTAINER_ID=$("${DOCKER}" ps --filter "name=${CONTAINER_NAME}" --format "{{.ID}}")
	info "Container ID: ${CONTAINER_ID}"
else
	error "Homepage container is not running"
	info "To start: docker compose -f compose.yaml up -d"
	exit 1
fi

# ============================================================================
# CHECK 2: Docker Socket is Mounted
# ============================================================================

section "CHECK 2: Docker Socket Mount"

if "${DOCKER}" inspect "${CONTAINER_NAME}" | grep -q "${SOCKET_PATH}"; then
	success "Docker socket is mounted into Homepage container"
	info "Mount point: ${SOCKET_PATH} (read-only)"
else
	error "Docker socket is NOT mounted into Homepage container"
	info "Verify compose.yaml contains: volumes: - /var/run/docker.sock:/var/run/docker.sock:ro"
	((FAILED++))
fi

# ============================================================================
# CHECK 3: Socket is Readable from Inside Container
# ============================================================================

section "CHECK 3: Socket Readability"

if "${DOCKER}" exec "${CONTAINER_NAME}" test -r "${SOCKET_PATH}" 2>/dev/null; then
	success "Docker socket is readable from inside Homepage"
	SOCKET_LS=$("${DOCKER}" exec "${CONTAINER_NAME}" ls -lah "${SOCKET_PATH}" 2>/dev/null)
	info "Socket details: $(echo "$SOCKET_LS" | awk '{print $1, $3, $4, $9}')"
else
	error "Docker socket is NOT readable from inside Homepage"
	info "This means Homepage cannot access container status"
	info "Check: docker exec ${CONTAINER_NAME} ls -la ${SOCKET_PATH}"
	((FAILED++))
fi

# ============================================================================
# CHECK 4: Parse services.yaml and Verify Containers Exist
# ============================================================================

section "CHECK 4: Services Configuration Validation"

if [ ! -f "${SERVICES_FILE}" ]; then
	error "services.yaml not found at ${SERVICES_FILE}"
	exit 1
fi

# Extract all container names from services.yaml (lines matching "container: ")
CONFIGURED_CONTAINERS=$(grep -E '^\s+container:' "${SERVICES_FILE}" |
	sed 's/.*container:[[:space:]]*//' |
	sort | uniq)

if [ -z "$CONFIGURED_CONTAINERS" ]; then
	error "No 'container:' entries found in services.yaml"
	((FAILED++))
else
	CONFIG_COUNT=$(echo "$CONFIGURED_CONTAINERS" | wc -l)
	info "Found $CONFIG_COUNT configured containers in services.yaml"

	# Check if each configured container exists
	FOUND_COUNT=0
	MISSING_CONTAINERS=""

	while IFS= read -r CONTAINER; do
		[ -z "$CONTAINER" ] && continue

		if "${DOCKER}" ps -a --format "{{.Names}}" | grep -q "^${CONTAINER}$"; then
			((FOUND_COUNT++))
			# Check if running or stopped
			if "${DOCKER}" ps --format "{{.Names}}" | grep -q "^${CONTAINER}$"; then
				info "  ✓ ${CONTAINER} (running)"
			else
				warning "  ⚠ ${CONTAINER} (stopped) - Status won't show in Homepage"
			fi
		else
			MISSING_CONTAINERS="${MISSING_CONTAINERS}${CONTAINER}\n"
			warning "  ⚠ ${CONTAINER} (not found - container may be stopped or misconfigured)"
		fi
	done <<<"$CONFIGURED_CONTAINERS"

	if [ "$FOUND_COUNT" -eq "$CONFIG_COUNT" ]; then
		success "All $CONFIG_COUNT configured containers found"
	else
		warning "$FOUND_COUNT/$CONFIG_COUNT configured containers found"
		info "Missing or stopped:"
		echo -e "$MISSING_CONTAINERS" | grep -v '^$' | sed 's/^/    - /'
	fi
fi

# ============================================================================
# CHECK 5: Verify socket.yaml and docker.yaml are Configured
# ============================================================================

section "CHECK 5: Docker Socket Configuration"

DOCKER_CONFIG="${CONFIG_DIR}/docker.yaml"

if [ ! -f "${DOCKER_CONFIG}" ]; then
	error "docker.yaml not found at ${DOCKER_CONFIG}"
	((FAILED++))
else
	if grep -q "my-docker:" "${DOCKER_CONFIG}"; then
		success "docker.yaml contains 'my-docker:' socket reference"
	else
		error "docker.yaml missing 'my-docker:' socket reference"
		((FAILED++))
	fi

	if grep -q "socket: ${SOCKET_PATH}" "${DOCKER_CONFIG}"; then
		success "Socket path is correctly configured: ${SOCKET_PATH}"
	else
		warning "Socket path may not be correctly configured"
		info "Check docker.yaml manually"
	fi
fi

# ============================================================================
# SUMMARY
# ============================================================================

section "SUMMARY"

TOTAL=$((PASSED + FAILED))
info "Check outcomes (pass + fail): ${TOTAL}"
info "Checks passed: ${GREEN}${PASSED}${NC}"
info "Checks failed: ${RED}${FAILED}${NC}"
info "Warnings: ${YELLOW}${WARNINGS}${NC}"

echo ""

if [ $FAILED -eq 0 ]; then
	echo -e "${GREEN}============================================================================${NC}"
	echo -e "${GREEN}All checks passed! Docker socket integration is working correctly.${NC}"
	echo -e "${GREEN}============================================================================${NC}"
	exit 0
else
	echo -e "${RED}============================================================================${NC}"
	echo -e "${RED}Some checks failed. See warnings above and refer to README.md troubleshooting.${NC}"
	echo -e "${RED}============================================================================${NC}"
	exit 1
fi
