#!/usr/bin/env bash
# =============================================================================
# audit-healthcheck-tools.sh
# =============================================================================
# Verifies which HTTP client tools (wget, curl, nc, sh) are available inside
# each image that has a healthcheck in this repo.
#
# Run from: Mac (Docker Desktop) OR NAS (sudo bash scripts/audit-healthcheck-tools.sh)
# Output:   Table of HAS_WGET / HAS_CURL / HAS_NC / HAS_SH per image
# =============================================================================

set -euo pipefail

DOCKER="${DOCKER:-docker}"
DOCKER_CMD=("$DOCKER")
# On Synology NAS the user may not be in the docker group
if ! "$DOCKER" info >/dev/null 2>&1; then
	DOCKER_CMD=(sudo "$DOCKER")
fi

probe() {
	local image="$1"
	local tool="$2"
	"${DOCKER_CMD[@]}" run --rm --pull=missing \
		--entrypoint="" \
		"$image" \
		sh -c "which $tool 2>/dev/null && echo YES || echo NO" 2>/dev/null |
		tail -1
}

probe_sh() {
	local image="$1"
	"${DOCKER_CMD[@]}" run --rm --pull=missing \
		--entrypoint="" \
		"$image" \
		sh -c "echo YES" 2>/dev/null | tail -1 || echo NO
}

check_image() {
	local label="$1"
	local image="$2"
	printf "  Pulling %-55s ... " "$image"
	"${DOCKER_CMD[@]}" pull --quiet "$image" >/dev/null 2>&1 && echo "done" || echo "PULL FAILED"

	local has_sh has_wget has_curl has_nc
	has_sh=$(probe_sh "$image")
	has_wget=$(probe "$image" wget)
	has_curl=$(probe "$image" curl)
	has_nc=$(probe "$image" nc)

	printf "  %-30s | SH:%-3s | WGET:%-3s | CURL:%-3s | NC:%-3s | %s\n" \
		"$label" "$has_sh" "$has_wget" "$has_curl" "$has_nc" "$image"
}

echo ""
echo "============================================================"
echo " OCI Healthcheck Tool Audit"
echo " Repo: ce-stacks"
echo " Date: $(date)"
echo "============================================================"
echo ""
echo "Checking images with non-trivial healthchecks..."
echo "(Scratch-based images with own binary probe are skipped)"
echo ""

# ── Images to probe ─────────────────────────────────────────────────────────
# FORMAT: check_image "<stack/service label>" "<image:tag>"

echo "--- CONFIRMED SCRATCH (no probe needed) ---"
echo "  traefik:v3                    SCRATCH — fix: CMD traefik healthcheck --ping"
echo "  containrrr/watchtower:latest  SCRATCH — fix: CMD /watchtower --health-check (already correct)"
echo ""

echo "--- ALPINE (busybox wget expected) ---"
check_image "portainer-ce" "portainer/portainer-ce:2.41.0-alpine"
check_image "portainer-agent" "portainer/agent:2.39.1"
check_image "valkey/SearXNG-Redis" "valkey/valkey:8-alpine"
check_image "postgres/databases" "postgres:16-alpine"
echo ""

echo "--- SUSPECT — verify wget/curl ---"
check_image "homepage" "ghcr.io/gethomepage/homepage:v1.12"
check_image "adminer/databases" "adminer:5.4.2-standalone"
check_image "otsai-webui" "ghcr.io/open-webui/open-webui:v0.9.2"
check_image "holyclaude" "coderluii/holyclaude:latest"
check_image "it-tools" "corentinth/it-tools:2024.10.22-7ca5933"
echo ""

echo "--- OWN BINARY / SHELL PROBE ---"
check_image "otsai-server/ollama" "ollama/ollama:0.22.0"
check_image "dozzle" "amir20/dozzle:v10.5.1"
check_image "mariadb/databases" "mariadb:11.4.10"
check_image "code-server" "codercom/code-server:4.117.0-39"
check_image "phpmyadmin" "phpmyadmin:5.2.2-apache"
echo ""

echo "============================================================"
echo " SUMMARY — Required fixes"
echo "============================================================"
echo ""
echo "  traefik-ots / traefik-mft:"
echo "    CHANGE: CMD wget → CMD traefik healthcheck --ping"
echo "    (scratch image — wget not present)"
echo ""
echo "  All other fixes depend on the results above."
echo "  Pass this output to the coder task for targeted changes."
echo ""
echo "AUDIT-PROBE: COMPLETE"
