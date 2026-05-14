#!/usr/bin/env bash
# Validate Compose files parse and interpolate (no pull / no run).
# Repo root = ancestor containing README.md; compose stacks live under stacks/.
set -euo pipefail
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${_script_dir}"
while [[ ! -f "${ROOT}/README.md" && "${ROOT}" != "/" ]]; do
	ROOT="$(dirname "${ROOT}")"
done
[[ -f "${ROOT}/README.md" ]] || {
	echo "ERROR: could not find repo root (README.md) above ${_script_dir}" >&2
	exit 1
}
STACKS="${ROOT}/stacks"
cd "$ROOT"

export COMPOSE_ENV_FILE="${ROOT}/.github/compose-ci.env"
# Host bind mounts use ${STACK_ROOT}/<stack>/… — CI resolves to the real stacks/ path.
export STACK_ROOT="${STACK_ROOT:-${STACKS}}"
# Validation-only: satisfy compose interpolation for stacks that reference these vars without
# requiring real secrets in the invoking environment (docker compose config -q).
export CODE_SERVER_PASSWORD="${CODE_SERVER_PASSWORD:-validation_dummy_pass}"
export WATCHTOWER_NOTIFICATION_URL="${WATCHTOWER_NOTIFICATION_URL:-discord://dummy_token@dummy_id}"

mkdir -p "${STACKS}/grafana-prom/secrets"
if [[ ! -s "${STACKS}/grafana-prom/secrets/watchtower_bearer_token.txt" ]]; then
	printf 'ci-watchtower-bearer-token\n' >"${STACKS}/grafana-prom/secrets/watchtower_bearer_token.txt"
fi

mkdir -p "${STACKS}/databases/secrets"
for f in mariadb_root_pw.txt mariadb_app_pw.txt postgres_pw.txt; do
	if [[ ! -s "${STACKS}/databases/secrets/${f}" ]]; then
		printf 'ci-dummy-db-secret\n' >"${STACKS}/databases/secrets/${f}"
	fi
done

mkdir -p /tmp/workspace 2>/dev/null || true
mkdir -p "${STACKS}/code-server/host-docker-bind" "${STACKS}/code-server/host-home-bind" 2>/dev/null || true

created_env_files=()
cleanup() {
	local status=$?
	if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
		for p in "${created_env_files[@]}"; do
			[[ -f "${p}" ]] && rm -f "${p}"
		done
	fi
	return "${status}"
}
trap cleanup EXIT

if [[ ! -f "${STACKS}/codex-docs/.env" ]]; then
	printf 'APP_SECRET=ci_dummy_app_secret_at_least_thirty_two_chars_long\n' >"${STACKS}/codex-docs/.env"
	created_env_files+=("${STACKS}/codex-docs/.env")
fi

# holyclaude stack was removed from the repo — skip .env creation if the directory
# does not exist (avoids "No such file or directory" error from cat redirect on set -e).
if [[ -d "${STACKS}/holyclaude" && ! -f "${STACKS}/holyclaude/.env" ]]; then
	cat >"${STACKS}/holyclaude/.env" <<EOF
PUID=0
PGID=0
DISCORD_WEBHOOK_URL=
NOTIFY_DISCORD=false
STACK_ROOT=${STACKS}
EOF
	created_env_files+=("${STACKS}/holyclaude/.env")
fi

if [[ ! -f "${STACKS}/code-server/.env" ]]; then
	cat >"${STACKS}/code-server/.env" <<EOF
STACK_ROOT=${STACKS}
CODE_SERVER_HOST_DOCKER_BIND=${STACKS}/code-server/host-docker-bind
CODE_SERVER_HOST_HOME_BIND=${STACKS}/code-server/host-home-bind
EOF
	created_env_files+=("${STACKS}/code-server/.env")
fi

# portainer stack was removed from the repo — skip if directory no longer exists.
if [[ -d "${STACKS}/portainer" && ! -f "${STACKS}/portainer/.env" ]]; then
	cat >"${STACKS}/portainer/.env" <<EOF
STACK_ROOT=${STACKS}
PORTAINER_DATA_ROOT=/volume2/docker/portainer
PORTAINER_CERT_ROOT=/volume2/docker/portainer/certs
EDGE_ID=
EDGE_KEY=
EOF
	created_env_files+=("${STACKS}/portainer/.env")
fi

if [[ ! -f "${STACKS}/synology-api-bridge/.env" ]]; then
	cat >"${STACKS}/synology-api-bridge/.env" <<EOF
BRIDGE_SHARED_SECRET=ci_dummy_bridge_secret
DSM_BASE_URL=
DSM_HTTP_TIMEOUT_SECONDS=5
EOF
	created_env_files+=("${STACKS}/synology-api-bridge/.env")
fi

while IFS= read -r f; do
	[[ -n "${f}" ]] || continue
	rel="${f#"${ROOT}"/}"
	dir="$(dirname "${f}")"
	base="$(basename "${f}")"
	echo "compose config: ${rel}"
	(
		cd "${dir}" || {
			echo "ERROR: could not cd to ${dir} (for ${rel})" >&2
			exit 1
		}
		docker compose --env-file "${COMPOSE_ENV_FILE}" -f "${base}" config -q
	) || {
		echo "ERROR: docker compose config failed for ${rel}" >&2
		exit 1
	}
	# docker-mcp.yaml is Docker Desktop MCP catalog YAML only — never validate as Compose.
	# Prune runtime bind-mount trees so NAS validate does not spam "Permission denied"
	# when Docker-owned dirs are unreadable to the invoking user (db/, data/, GUI config).
done < <(
	find "${STACKS}" -maxdepth 4 \
		\( -type d \( -name db -o -name data \) \) -prune -o \
		\( -type d -path '*/github-desktop/config' \) -prune -o \
		\( \( -name compose.yaml -o -name docker-compose.yml -o -name docker-compose.yaml \) \
		! -name docker-mcp.yaml ! -path '*/.git/*' \) -print | sort
)

echo "All compose files validated OK."
