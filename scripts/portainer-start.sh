#!/bin/sh
# =============================================================================
# Portainer startup script - Synology DSM rc.d replacement
# =============================================================================
# Drop this file at /usr/local/etc/rc.d/portainer.sh on the NAS and chmod +x it.
# Source of truth: scripts/portainer-start.sh in the ce-stacks repo.
#
# Starts two containers:
#   1. portainer       - CE server (WebUI + API + stack management)
#   2. portainer_agent - Agent (host management, volume browsing, non-admin volumes)
#
# The Agent is required for:
#   - Host management features (browse host filesystem)
#   - Volume management for non-administrators
#   - /host bind-mount exposes the NAS root filesystem read/write inside agent
#
# After both containers are running, register the Agent environment once in
# the Portainer UI:
#   Environments → Add environment → Portainer Agent
#   Name: NAS Local   Agent URL: 10.0.1.15:9001
#   → Save → switch to the new environment
#
# TLS: disabled on the agent (LAN-only deployment, bound to 10.0.1.15).
# If TLS is required later, set PORTAINER_AGENT_TLS=1 and place cert.pem /
# key.pem under PORTAINER_CERT_ROOT before starting.
#
# Configuration:
#   CE image:    portainer/portainer-ce:2.41.0-alpine
#   Agent image: portainer/agent:2.41.0
#   CE ports:    10.0.1.15:9000 (HTTP API), 10.0.1.15:9443 (HTTPS WebUI)
#   Agent port:  10.0.1.15:9001
#   Data:        /volume2/docker/portainer (outside STACK_ROOT)
#   Socket:      /var/run/docker.sock rw (CE + Agent both need full API access)
#   Agent mounts: /volume2/@docker/volumes → /var/lib/docker/volumes
#                 / → /host  (host rootfs, required for host management)
#
# Note: Portainer state lives outside STACK_ROOT so it persists across repo
# resets. Portainer CE cannot manage its own container; this RC script owns
# the lifecycle exclusively.
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
# TLS is disabled by default (LAN-only, bound to 10.0.1.15).
# Set PORTAINER_AGENT_TLS=1 and place cert.pem/key.pem under
# PORTAINER_CERT_ROOT to enable TLS on the agent endpoint.
PORTAINER_AGENT_TLS="${PORTAINER_AGENT_TLS:-0}"
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
        --network=ce-internal \
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
    # Build the docker run command; conditionally add TLS mounts/env.
    set -- \
        --name="$AGENT_NAME" \
        --network=ce-internal \
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
        -e PUID="$PUID" \
        -e PGID="$PGID" \
        -e AGENT_CLUSTER_ADDR=0.0.0.0 \
        -e TZ=America/New_York

    if [ "${PORTAINER_AGENT_TLS:-0}" = "1" ]; then
        set -- "$@" \
            -v "${PORTAINER_CERT_ROOT}:/certs:ro" \
            -e AGENT_TLS_CERT=/certs/cert.pem \
            -e AGENT_TLS_KEY=/certs/key.pem
        echo "portainer-start: agent TLS enabled (certs from ${PORTAINER_CERT_ROOT})"
    else
        echo "portainer-start: agent TLS disabled (LAN-only; set PORTAINER_AGENT_TLS=1 to enable)"
    fi

    $DOCKER run -d "$@" "$AGENT_IMAGE"
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
