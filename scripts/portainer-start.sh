#!/bin/sh
# =============================================================================
# Portainer startup script - Synology DSM rc.d replacement
# =============================================================================
# Drop this file at /usr/local/etc/rc.d/portainer.sh on the NAS and chmod +x it.
# Source of truth: scripts/portainer-start.sh in the ce-stacks repo.
#
# Container Management UI for Docker. Portainer CE enables:
#   1. Container & image management (status, logs, exec, restart, remove)
#   2. Dashboard with resource usage (CPU, memory, network)
#   3. Stack / Compose v2 file viewer (supports compose.yaml natively)
#   4. Registry integration
#   5. REST API for automated stack provisioning (see scripts/portainer-provision.sh)
#
# Configuration:
#   - Image: portainer/portainer-ce:2.41.0-alpine (Compose v2, compose.yaml support)
#   - Port: host 9000 → container 9000 (HTTP WebUI + API, LAN-only binding)
#   - Port: host 9443 → container 9443 (HTTPS WebUI, LAN-only binding)
#   - Data: /volume2/docker/portainer (persistent state - outside STACK_ROOT)
#   - Socket: /var/run/docker.sock (rw - CE needs full API access for stack management)
#   - TZ: America/New_York (match NAS timezone)
#   - PUID/PGID: root (0:0) for socket access
#   - Restart: unless-stopped (keep UI running across system reboots)
#   - Watchtower label: com.centurylinklabs.watchtower.enable=true
#   - Healthcheck: HTTP query to /api/system/status on localhost:9000
#
# Note: Portainer state is stored outside STACK_ROOT to persist across
# repo resets. /volume2/docker/portainer is a separate, independent path.
# Portainer CE cannot manage its own container - this RC script owns its
# lifecycle exclusively. The stacks/portainer/ compose is archived for reference.
#
# After first boot, run: sudo bash /volume2/docker/ce-stacks/scripts/portainer-provision.sh
# to register all ce-stacks stacks into Portainer automatically.
# =============================================================================

set -e

LOCK_FILE="/tmp/portainer-start.lock"

DOCKER="/usr/local/bin/docker"
NAME="portainer"
IMAGE="portainer/portainer-ce:2.41.0-alpine"
AGENT_NAME="portainer_agent"
AGENT_IMAGE="portainer/agent:2.41.0"
PUID="${PUID:-0}"
PGID="${PGID:-0}"
PORTAINER_DATA="${PORTAINER_DATA:-/volume2/docker/portainer}"
PORTAINER_CERT_ROOT="${PORTAINER_CERT_ROOT:-/volume2/docker/portainer/certs}"

sleep 20

mkdir -p "${PORTAINER_DATA}"

exists() {
    $DOCKER ps -a --format '{{.Names}}' | grep -qx "$NAME"
}

current_image() {
    name="${1:-$NAME}"
    $DOCKER inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || true
}

portainer_port_map_ok() {
    binds="$($DOCKER inspect -f '{{json .HostConfig.PortBindings}}' "$NAME" 2>/dev/null || echo '')"
    [ -n "$binds" ] || return 1
    echo "$binds" | grep -q '"9000/tcp"' || return 1
    echo "$binds" | grep -q '"HostPort":"9000"' || return 1
    echo "$binds" | grep -q '"9443/tcp"' || return 1
    echo "$binds" | grep -q '"HostPort":"9443"' || return 1
    echo "$binds" | grep -q '"HostIp":"10.0.1.15"' || return 1
    return 0
}

portainer_data_mount_ok() {
    mounts="$($DOCKER inspect -f '{{json .Mounts}}' "$NAME" 2>/dev/null || echo '[]')"
    echo "$mounts" | grep -Fq "${PORTAINER_DATA}" || return 1
    echo "$mounts" | grep -Fq '"/data"' || return 1
    return 0
}

agent_data_mount_ok() {
    mounts="$($DOCKER inspect -f '{{json .Mounts}}' "$AGENT_NAME" 2>/dev/null || echo '[]')"
    echo "$mounts" | grep -Fq '/var/run/docker.sock' || return 1
    echo "$mounts" | grep -Fq '"/var/lib/docker/volumes"' || return 1
    echo "$mounts" | grep -Fq '"/host"' || return 1
    echo "$mounts" | grep -Fq "${PORTAINER_CERT_ROOT}" || return 1
    echo "$mounts" | grep -Fq '"/certs"' || return 1
    return 0
}

agent_port_map_ok() {
    binds="$($DOCKER inspect -f '{{json .HostConfig.PortBindings}}' "$AGENT_NAME" 2>/dev/null || echo '')"
    [ -n "$binds" ] || return 1
    echo "$binds" | grep -q '"9001/tcp"' || return 1
    echo "$binds" | grep -q '"HostPort":"9001"' || return 1
    echo "$binds" | grep -q '"HostIp":"10.0.1.15"' || return 1
    return 0
}

create_container() {
    mkdir -p "${PORTAINER_DATA}"
    $DOCKER run -d \
        --name="$NAME" \
        -p 10.0.1.15:9000:9000 \
        -p 10.0.1.15:9443:9443 \
        --restart=unless-stopped \
        --security-opt no-new-privileges:true \
        --memory 512m \
        --cpu-shares 512 \
        --log-driver json-file \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        --label com.centurylinklabs.watchtower.enable=true \
        --health-cmd='wget --no-verbose --tries=1 --spider http://127.0.0.1:9000/api/system/status' \
        --health-interval=30s \
        --health-timeout=10s \
        --health-retries=3 \
        --health-start-period=40s \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${PORTAINER_DATA}:/data" \
        -e PUID="$PUID" \
        -e PGID="$PGID" \
        -e TZ=America/New_York \
        "$IMAGE"
}

create_agent_container() {
    $DOCKER run -d \
        --name="$AGENT_NAME" \
        -p 10.0.1.15:9001:9001 \
        --restart=unless-stopped \
        --security-opt no-new-privileges:true \
        --memory 256m \
        --cpu-shares 256 \
        --log-driver json-file \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        --label com.centurylinklabs.watchtower.enable=true \
        --cap-drop=ALL \
        --cap-add=NET_RAW \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /volume2/@docker/volumes:/var/lib/docker/volumes \
        -v /:/host \
        -v "${PORTAINER_CERT_ROOT}:/certs:ro" \
        -e PUID="$PUID" \
        -e PGID="$PGID" \
        -e AGENT_CLUSTER_ADDR=0.0.0.0 \
        -e AGENT_TLS_CERT=/certs/cert.pem \
        -e AGENT_TLS_KEY=/certs/key.pem \
        -e TZ=America/New_York \
        "$AGENT_IMAGE"
}

$DOCKER pull "$IMAGE" || {
    echo "ERROR: Failed to pull $IMAGE" >&2
    exit 1
}

$DOCKER pull "$AGENT_IMAGE" || {
    echo "ERROR: Failed to pull $AGENT_IMAGE" >&2
    exit 1
}

if ! mkdir "${LOCK_FILE}" 2>/dev/null; then
    echo "portainer-start: locked by another instance; aborting" >&2
    exit 0
fi
trap 'rmdir "${LOCK_FILE}" 2>/dev/null' EXIT

if exists; then
    CURR="$(current_image)"
    if [ "$CURR" != "$IMAGE" ] || ! portainer_port_map_ok || ! portainer_data_mount_ok; then
        if [ "$CURR" != "$IMAGE" ]; then
            echo "portainer-start: recreating ${NAME} (image: ${CURR:-none} -> ${IMAGE})"
        elif ! portainer_port_map_ok; then
            echo "portainer-start: recreating ${NAME} (ports 9000,9443 must bind to 10.0.1.15)"
        else
            echo "portainer-start: recreating ${NAME} (/data must bind ${PORTAINER_DATA}/)"
        fi
        $DOCKER stop "$NAME" || true
        $DOCKER rm "$NAME" || true
        create_container
    else
        $DOCKER start "$NAME" || true
    fi
else
    create_container
fi

if $DOCKER ps -a --format '{{.Names}}' | grep -qx "$AGENT_NAME"; then
    CURR_AGENT="$(current_image "$AGENT_NAME")"
    if [ "$CURR_AGENT" != "$AGENT_IMAGE" ] || ! agent_port_map_ok || ! agent_data_mount_ok; then
        if [ "$CURR_AGENT" != "$AGENT_IMAGE" ]; then
            echo "portainer-start: recreating ${AGENT_NAME} (image: ${CURR_AGENT:-none} -> ${AGENT_IMAGE})"
        elif ! agent_port_map_ok; then
            echo "portainer-start: recreating ${AGENT_NAME} (port 9001 must bind to 10.0.1.15)"
        else
            echo "portainer-start: recreating ${AGENT_NAME} (agent mounts must match expected host bindings)"
        fi
        $DOCKER stop "$AGENT_NAME" || true
        $DOCKER rm "$AGENT_NAME" || true
        create_agent_container
    else
        $DOCKER start "$AGENT_NAME" || true
    fi
else
    create_agent_container
fi
