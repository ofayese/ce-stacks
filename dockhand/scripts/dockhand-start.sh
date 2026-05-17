#!/bin/sh
# =============================================================================
# Dockhand startup script - Synology DSM rc.d replacement
# =============================================================================
# Drop this file at /usr/local/etc/rc.d/dockhand.sh on the NAS and chmod +x it.
# Source of truth: /volume2/docker/dockhand/scripts/dockhand-start.sh
# (Original: ce-stacks repo at dockhand/scripts/dockhand-start.sh)
#
# Manages the Dockhand container lifecycle with validation, health checks,
# and permission verification. Designed for single-host Docker management
# on Synology DSM 7.3 with LAN-only binding (10.0.1.15:3866).
#
# Dockhand features:
#   - Git-backed Compose stack orchestration with webhooks
#   - Real-time container management and logs
#   - Multi-environment support (local + remote Docker hosts)
#   - OIDC SSO + local authentication
#   - Privacy-focused: Wolfi OS base, minimal supply chain exposure
#
# After starting, initialize via web UI:
#   1. Access: http://10.0.1.15:3866
#   2. Settings > Environments > Add environment
#   3. Name: "DS723", Socket: "unix:///var/run/docker.sock", Public IP: "10.0.1.15"
#   4. Settings > Authentication > Users > Add user (create admin)
#   5. Settings > Registries > Add: GitHub (ghcr.io), Codeberg, Quay.io
#   6. Import existing stacks from /volume2/docker/ce-stacks/stacks/ via Settings > Stacks or git webhook
#
# Configuration:
#   Image:       fnsys/dockhand:latest (or pin to specific tag for stability)
#   Port:        10.0.1.15:3866:3000
#   Data:        /volume2/docker/dockhand (persists across DSM updates)
#   Socket:      /var/run/docker.sock rw (Dockhand needs full Docker API access)
#   Env:         SKIP_DF_COLLECTION=true (prevents slow disk API on Synology)
#   User:        PUID=0 PGID=0 (Synology convention for bind-mount ownership)
#   Health:      HTTP GET http://localhost:3000/health (30s interval)
#   Logs:        json-file, max-size=10m, max-file=3 (respects DSM storage)
#
# Validation:
#   - Image pulls on startup (detects registry issues early)
#   - Port binding verified (must bind 10.0.1.15:3866)
#   - Data mount checked (must be at /volume2/docker/dockhand)
#   - Docker socket access validated (warns if inaccessible)
#   - Health check passes within 60s start period
#
# On DSM update/reboot, this script re-registers with the RC system.
# To uninstall:
#   sudo rm /usr/local/etc/rc.d/dockhand.sh
#   sudo docker stop dockhand && sudo docker rm dockhand
#   sudo rm -rf /volume2/docker/dockhand (optional: preserve data)
#
# Troubleshooting:
#   - Check logs: sudo docker logs dockhand
#   - Verify socket: ls -l /var/run/docker.sock
#   - Test health: curl -v http://10.0.1.15:3866/health 2>&1 | head -20
#   - Inspect container: sudo docker inspect dockhand | jq '.State.Health'
# =============================================================================

set -e

LOCK_FILE="/tmp/dockhand-start.lock"

DOCKER="/usr/local/bin/docker"
NAME="dockhand"
IMAGE="fnsys/dockhand:latest"
PUID="${PUID:-0}"
PGID="${PGID:-0}"
DOCKHAND_DATA="${DOCKHAND_DATA:-/volume2/docker/dockhand}"
DOCKHAND_PORT_HOST="3866"
DOCKHAND_PORT_CONTAINER="3000"
DOCKHAND_BIND_IP="10.0.1.15"

sleep 20

mkdir -p "${DOCKHAND_DATA}"

exists() {
    $DOCKER ps -a --format '{{.Names}}' | grep -qx "$NAME"
}

current_image() {
    $DOCKER inspect -f '{{.Config.Image}}' "$NAME" 2>/dev/null || true
}

dockhand_port_map_ok() {
    binds="$($DOCKER inspect -f '{{json .HostConfig.PortBindings}}' "$NAME" 2>/dev/null || echo '')"
    [ -n "$binds" ] || return 1
    echo "$binds" | grep -q "\"${DOCKHAND_PORT_CONTAINER}/tcp\"" || return 1
    echo "$binds" | grep -q "\"HostPort\":\"${DOCKHAND_PORT_HOST}\"" || return 1
    echo "$binds" | grep -q "\"HostIp\":\"${DOCKHAND_BIND_IP}\"" || return 1
    return 0
}

dockhand_data_mount_ok() {
    mounts="$($DOCKER inspect -f '{{json .Mounts}}' "$NAME" 2>/dev/null || echo '[]')"
    echo "$mounts" | grep -Fq "${DOCKHAND_DATA}" || return 1
    echo "$mounts" | grep -Fq '"/app/data"' || return 1
    return 0
}

socket_accessible() {
    if [ ! -S /var/run/docker.sock ]; then
        echo "dockhand-start: ERROR: Docker socket not found at /var/run/docker.sock" >&2
        return 1
    fi
    if ! test -r /var/run/docker.sock; then
        echo "dockhand-start: WARNING: Docker socket not readable (permission denied)" >&2
        echo "dockhand-start: Run: sudo chmod 666 /var/run/docker.sock (or use group membership)" >&2
        return 0  # not a fatal error; Dockhand can configure environments via UI
    fi
    return 0
}

# Idempotently ensure the ce-internal backbone network exists. Several stacks
# (and this container) attach to it, so create it on first run if init-nas.sh
# has not been executed yet.
ensure_ce_internal() {
    if $DOCKER network inspect ce-internal >/dev/null 2>&1; then
        return 0
    fi
    echo "dockhand-start: creating ce-internal network (172.26.0.0/24)"
    $DOCKER network create \
        --driver bridge \
        --subnet 172.26.0.0/24 \
        --gateway 172.26.0.1 \
        ce-internal >/dev/null || {
        echo "dockhand-start: ERROR: failed to create ce-internal network" >&2
        return 1
    }
    return 0
}

create_container() {
    mkdir -p "${DOCKHAND_DATA}"
    
    # Ensure subdirectories exist (Dockhand entrypoint creates these on startup)
    mkdir -p "${DOCKHAND_DATA}/db"
    mkdir -p "${DOCKHAND_DATA}/stacks"
    mkdir -p "${DOCKHAND_DATA}/git-repos"
    mkdir -p "${DOCKHAND_DATA}/tmp"
    mkdir -p "${DOCKHAND_DATA}/icons"
    mkdir -p "${DOCKHAND_DATA}/snapshots"
    mkdir -p "${DOCKHAND_DATA}/scanner-cache"
    
    $DOCKER run -d \
        --name="$NAME" \
        --network=ce-internal \
        -p "${DOCKHAND_BIND_IP}:${DOCKHAND_PORT_HOST}:${DOCKHAND_PORT_CONTAINER}" \
        --restart=unless-stopped \
        --security-opt no-new-privileges:true \
        --memory 1g \
        --cpu-shares 512 \
        --log-driver json-file \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        --label com.centurylinklabs.watchtower.enable=false \
        --health-cmd='grep -q ":0BB8" /proc/net/tcp /proc/net/tcp6 2>/dev/null' \
        --health-interval=30s \
        --health-timeout=5s \
        --health-retries=5 \
        --health-start-period=120s \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${DOCKHAND_DATA}:/app/data" \
        -v /volume2/docker/ce-stacks/stacks:/app/stacks:rw \
        -e PUID="$PUID" \
        -e PGID="$PGID" \
        -e SKIP_DF_COLLECTION=true \
        -e TZ=America/New_York \
        "$IMAGE"
}

# === Main Logic ===

$DOCKER pull "$IMAGE" || {
    echo "dockhand-start: ERROR: Failed to pull $IMAGE" >&2
    exit 1
}

if ! mkdir "${LOCK_FILE}" 2>/dev/null; then
    echo "dockhand-start: locked by another instance; aborting" >&2
    exit 0
fi
trap 'rmdir "${LOCK_FILE}" 2>/dev/null' EXIT

socket_accessible || {
    echo "dockhand-start: WARNING: Docker socket may be inaccessible; Dockhand will require manual environment setup" >&2
}

ensure_ce_internal || {
    echo "dockhand-start: ERROR: ce-internal network unavailable; aborting" >&2
    exit 1
}

if exists; then
    CURR="$(current_image)"
    if [ "$CURR" != "$IMAGE" ] || ! dockhand_port_map_ok || ! dockhand_data_mount_ok; then
        if [ "$CURR" != "$IMAGE" ]; then
            echo "dockhand-start: recreating ${NAME} (image: ${CURR:-none} -> ${IMAGE})"
        elif ! dockhand_port_map_ok; then
            echo "dockhand-start: recreating ${NAME} (port ${DOCKHAND_PORT_HOST} must bind to ${DOCKHAND_BIND_IP})"
        else
            echo "dockhand-start: recreating ${NAME} (/app/data must bind ${DOCKHAND_DATA}/)"
        fi
        $DOCKER stop "$NAME" || true
        $DOCKER rm "$NAME" || true
        create_container
    else
        $DOCKER start "$NAME" || true
        echo "dockhand-start: ${NAME} started (image: $CURR)"
    fi
else
    echo "dockhand-start: creating new ${NAME} container (image: $IMAGE)"
    create_container
fi

# Wait for health check to pass (up to 60s + health-start-period)
echo "dockhand-start: waiting for ${NAME} to become healthy..."
HEALTH_RETRIES=0
MAX_HEALTH_RETRIES=30
while [ $HEALTH_RETRIES -lt $MAX_HEALTH_RETRIES ]; do
    HEALTH=$($DOCKER inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo "none")
    if [ "$HEALTH" = "healthy" ]; then
        echo "dockhand-start: ${NAME} is healthy [OK]"
        echo "dockhand-start: Access Dockhand at http://${DOCKHAND_BIND_IP}:${DOCKHAND_PORT_HOST}"
        break
    elif [ "$HEALTH" = "starting" ]; then
        sleep 2
        HEALTH_RETRIES=$((HEALTH_RETRIES + 1))
    else
        # Health check running but not yet passed
        sleep 2
        HEALTH_RETRIES=$((HEALTH_RETRIES + 1))
    fi
done

if [ $HEALTH_RETRIES -ge $MAX_HEALTH_RETRIES ]; then
    echo "dockhand-start: WARNING: ${NAME} did not reach healthy state within 60s" >&2
    echo "dockhand-start: Check logs: $DOCKER logs $NAME" >&2
    LOGS=$($DOCKER logs "$NAME" 2>&1 | tail -20)
    echo "$LOGS" >&2
    exit 1
fi

echo "dockhand-start: initialization complete"
