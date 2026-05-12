#!/bin/sh
# =============================================================================
# Dockge startup script — Synology DSM rc.d replacement
# =============================================================================
# Drop this file at /usr/local/etc/rc.d/dockge.sh on the NAS and chmod +x it.
#
# Changes vs. original script:
#   1. Image: louislam/dockge:base  →  louislam/dockge:1  (production release;
#      :base is a builder layer, not the app).  Latest stable = 1.5.0.
#   2. Security: added --security-opt no-new-privileges:true
#   3. Resources: added --memory 512m --cpu-shares 512
#   4. Logging: added --log-driver json-file with size cap
#   5. Port: host 5571→container 5001 (louislam/dockge listens on 5001 inside the image).
#      Homepage/HAProxy backends must target host port 5571.
#   6. PUID/PGID: default root (0:0) for Synology bind-mount ownership; override if needed.
#   7. sleep 20 retained — required for Synology Docker daemon startup sequence.
#
# Default PUID/PGID are root (0:0), matching `HIVE_OBJECTIVE.md` NAS notes. Override only
# if a non-root owner is required for the stacks directory.
#
# App state: ${DOCKGE_ROOT}/data/ is bind-mounted at /app/data (dockge.db, etc.).
# Stacks stay at ${DOCKGE_ROOT}/stacks.
# =============================================================================

set -e

LOCK_FILE="/tmp/dockge-start.lock"

DOCKER="/usr/local/bin/docker"
NAME="Dockge"
IMAGE="louislam/dockge:1"
PUID="${PUID:-0}"
PGID="${PGID:-0}"
CE_STACKS_ROOT="${CE_STACKS_ROOT:-/volume2/docker/ce-stacks}"
DATA_DIR="${CE_STACKS_ROOT}/data"

sleep 20

mkdir -p "${DATA_DIR}"

exists() {
	$DOCKER ps -a --format '{{.Names}}' | grep -qx "$NAME"
}

current_image() {
	$DOCKER inspect -f '{{.Config.Image}}' "$NAME" 2>/dev/null || true
}

dockge_port_map_ok() {
	binds="$($DOCKER inspect -f '{{json .HostConfig.PortBindings}}' "$NAME" 2>/dev/null || echo '')"
	[ -n "$binds" ] || return 1
	echo "$binds" | grep -q '"5001/tcp"' || return 1
	echo "$binds" | grep -q '"HostPort":"5571"' || return 1
	return 0
}

dockge_data_mount_ok() {
	mounts="$($DOCKER inspect -f '{{json .Mounts}}' "$NAME" 2>/dev/null || echo '[]')"
	echo "$mounts" | grep -Fq "${DATA_DIR}" || return 1
	echo "$mounts" | grep -Fq '"/app/data"' || return 1
	return 0
}

create_container() {
	mkdir -p "${CE_STACKS_ROOT}/stacks" "${DATA_DIR}"
	$DOCKER run -d \
		--name="$NAME" \
		-p 5571:5001 \
		--restart=on-failure:5 \
		--security-opt no-new-privileges:true \
		--memory 512m \
		--cpu-shares 512 \
		--log-driver json-file \
		--log-opt max-size=10m \
		--log-opt max-file=3 \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v "${CE_STACKS_ROOT}/stacks:${CE_STACKS_ROOT}/stacks" \
		-v "${DATA_DIR}:/app/data" \
		-e "DOCKGE_STACKS_DIR=${CE_STACKS_ROOT}/stacks" \
		-e PUID="$PUID" \
		-e PGID="$PGID" \
		-e TZ=America/New_York \
		"$IMAGE"
}

$DOCKER pull "$IMAGE" || {
	echo "ERROR: Failed to pull $IMAGE" >&2
	exit 1
}

if ! mkdir "${LOCK_FILE}" 2>/dev/null; then
	echo "dockge-start: locked by another instance; aborting" >&2
	exit 0
fi
trap 'rmdir "${LOCK_FILE}" 2>/dev/null' EXIT

if exists; then
	CURR="$(current_image)"
	if [ "$CURR" != "$IMAGE" ] || ! dockge_port_map_ok || ! dockge_data_mount_ok; then
		if [ "$CURR" != "$IMAGE" ]; then
			echo "dockge-start: recreating ${NAME} (image: ${CURR:-none} -> ${IMAGE})"
		elif ! dockge_port_map_ok; then
			echo "dockge-start: recreating ${NAME} (host 5571 must map to container 5001)"
		else
			echo "dockge-start: recreating ${NAME} (/app/data must bind ${DATA_DIR}/)"
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
