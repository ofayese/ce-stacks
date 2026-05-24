#!/usr/bin/env bash
# init-nas.sh
# Single-command bootstrap for the ce-stacks repo after git clone or git pull.
#
# What it does (in order):
#   1. Resolve STACK_ROOT and write it into the repo-root .env
#   2. Write STACK_ROOT into the repo-root .env
#   3. Create bind-mount volume directories for all stacks
#   4. Seed per-stack .env files from .env.example (via bootstrap-env.sh --apply)
#   5. Fix bind-mount ownership (fix-permissions.sh, root only)
#   6. Create the ce-internal Docker backbone network (idempotent)
#   7. Sync REPO_ROOT/dockhand/ -> /volume2/docker/dockhand/ (merge, never overwrites .env/data/secrets)
#
# PREFERRED - run as your admin user (no sudo):
#   bash scripts/init-nas.sh
#
# Use sudo only if fix-permissions.sh needs to chown volume dirs, or if your
# user lacks write access to /volume2/docker/:
#   sudo bash scripts/init-nas.sh
#   (dockhand sync files are re-owned back to $SUDO_USER automatically)
#
# Re-run after every git pull -- fully idempotent.
#
# Manifest exhaustiveness (BSD-safe; no grep -oP):
#   diff <(grep -E '^\s*"[^"]+:' scripts/init-nas.sh | sed -E 's/^[[:space:]]*"([^"]+):.*/\1/' | sort -u) \
#        <(ls stacks/ | grep -vE '^portainer$|^agents_gateway_data$|^db-tools$|^it-tools$|^mcp-tools-config$|^openresume$|^watchtower$|^docker-model-runner$' | sort)
# Left: unique stack names from STACK_MANIFEST (sort -u: traefik-ots / traefik-mft each listed twice for config+data).
# Right: stack dirs excluding MANIFEST_EXEMPT (same as grep -vE list). _haproxy stays on both sides.

set -euo pipefail

LIST_ONLY=0
IF_CHANGED_MODE=0

# Detect the real (non-root) user when the script is invoked via sudo.
# Used to restore ownership on files created by root so the operator can
# still edit them without sudo.
REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
REAL_GROUP="$(id -gn "${REAL_USER}" 2>/dev/null || echo "${REAL_USER}")"
[[ "${1:-}" == "--list-expected-dirs" ]] && LIST_ONLY=1

# -- 1. Resolve repo root and STACK_ROOT ------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ENV="${REPO_ROOT}/.env"
STACKS_IN_REPO="${REPO_ROOT}/stacks"

# Synology non-interactive SSH does not include /usr/local/bin in PATH.
# Resolve docker binary once; caller can override via DOCKER=/path/to/docker.
DOCKER="${DOCKER:-$(command -v docker 2>/dev/null || echo /usr/local/bin/docker)}"

# Prefer stacks inside this repo (this layout). Else sibling ../stacks next to the
# clone parent. Else STACK_ROOT_OVERRIDE or /volume2/docker/stacks.
# IMPORTANT: STACK_ROOT points to the stacks/ subdirectory, NOT the repo root.
# All compose volume paths use ${STACK_ROOT}/<stack-name>/... notation.
if [[ -d "${STACKS_IN_REPO}" ]]; then
	STACK_ROOT="${STACKS_IN_REPO}"
	[[ "${LIST_ONLY}" -eq 0 ]] && echo "Auto-detected STACK_ROOT (repo stacks/): ${STACK_ROOT}"
else
	CANDIDATE_STACKS="$(cd "${REPO_ROOT}/.." && pwd)/stacks"
	if [[ -d "${CANDIDATE_STACKS}" ]]; then
		STACK_ROOT="${CANDIDATE_STACKS}"
		[[ "${LIST_ONLY}" -eq 0 ]] && echo "Auto-detected STACK_ROOT (sibling stacks/): ${STACK_ROOT}"
	else
		# Default includes /stacks suffix - STACK_ROOT is the stacks/ dir, not repo root.
		STACK_ROOT="${STACK_ROOT_OVERRIDE:-/volume2/docker/stacks}"
		if [[ "${LIST_ONLY}" -eq 0 ]]; then
			echo "Using default STACK_ROOT: ${STACK_ROOT}"
			echo "(Override with: STACK_ROOT_OVERRIDE=/your/path sudo bash scripts/init-nas.sh)"
		fi
	fi
fi

# Format: "stack-name:sub1[,sub2]" - keep aligned with compose bind mounts under ${STACK_ROOT}/<stack>/...
STACK_MANIFEST=(
	# Sub-folder rules:
	#   data   -> default for all stacks with host bind mounts
	#   db     -> add only when a DB engine has its own host bind mount
	#   config -> add only when a non-db service writes runtime config
	# Never add a folder speculatively.
	# portainer: OPERATOR EXCEPTION - exempt from this manifest.
	#   State path fixed at /volume2/docker/portainer in compose.yaml (outside STACK_ROOT).

	# -- data only -----------------------------------------------------
	"acme-sh:data"
	"dozzle:data"
	"influxdb:data"
	# ollama: data/ollama (model storage) and data/open-webui must exist as subdirs.
	"ollama:data/ollama,data/open-webui"
	# remotely: SQLite DB + generated agent installers/download payloads
	"remotely:data"

	# -- data,config ---------------------------------------------------
	"code-server:data,config"
	"github-desktop:config" # KasmVNC GUI - /config only, no data dir
	"homepage:data,config"
	"searxng:data,config"
	"synology-api-bridge:data"
	# grafana-prom: data/grafana, data/prometheus, and data/alertmanager must exist as
	# subdirs before deploy. Synology does not auto-create leaf bind-mount paths.
	"grafana-prom:data/grafana,data/prometheus,data/alertmanager,config"

	# -- data,db -------------------------------------------------------
	"codex-docs:data,db"
	# databases: mariadb + postgres engine data dirs both under db/ (no separate app data layer).
	# Subdirs db/mariadb and db/postgres must exist before deploy: Synology Docker (Container
	# Manager) does not auto-create leaf bind-mount source paths and fails with
	# "Bind mount failed: '<path>' does not exist". mkdir -p handles slashes here.
	"databases:db/mariadb,db/postgres"
	"zabbix:data,db"
	# -- Omit (no ${STACK_ROOT} dirs in manifest) - audit trail only ---
	# agents_gateway_data: docker.sock only - no ${STACK_ROOT} dirs needed.
	# docker-model-runner: no host volume binds.
	# it-tools: no volumes.
	# mcp-tools-config: catalog only - no runtime dirs.
	# openresume: no volumes.
	# watchtower: docker.sock only - no ${STACK_ROOT} dirs needed.
	#   Absent from manifest intentionally. Listed here for audit trail.

	# -- New stacks: add entry here before first deploy -----------------
	"otspsu:data"
	# HAProxy bind-mount assets (certs + host map); not a Docker compose stack - see stacks/_haproxy/README.txt
	"_haproxy:certs,maps"
)

# Stacks intentionally absent from STACK_MANIFEST.
# These have no persistent host bind mounts under ${STACK_ROOT}.
# Listed here so the manifest exhaustiveness check can account
# for them without requiring a dummy entry. (Not read by this script -
# see scripts/verify-stack-manifest.sh for the exhaustiveness check.)
# shellcheck disable=SC2034
MANIFEST_EXEMPT=(
	"agents_gateway_data" # docker.sock only
	"db-tools"            # stateless (Adminer) -- no volumes
	"it-tools"            # no volumes
	"mcp-tools-config"    # catalog only
	"openresume"          # no volumes
	"watchtower"          # docker.sock only
	"docker-model-runner" # no host volume binds
)

# -- Manifest-derived expected directory list -------------------------
# Usage: bash scripts/init-nas.sh --list-expected-dirs
# Prints paths init-nas.sh would create under STACK_ROOT, without mkdir or .env writes.
if [[ "${LIST_ONLY}" -eq 1 ]]; then
	for entry in "${STACK_MANIFEST[@]}"; do
		[[ "${entry}" =~ ^[[:space:]]*# ]] && continue
		[[ -z "${entry// /}" ]] && continue
		entry="${entry//\"/}"
		stack="${entry%%:*}"
		sub_folders="${entry##*:}"
		[[ -z "${sub_folders}" ]] && continue
		IFS=',' read -ra folders <<<"${sub_folders}"
		for folder in "${folders[@]}"; do
			[[ -z "${folder}" ]] && continue
			echo "${STACK_ROOT}/${stack}/${folder}"
		done
	done
	exit 0
fi

# -- --if-changed: skip if init-nas.sh itself has not changed ---------
# Hash is written only after a successful full init (end of script).
if [[ "${1:-}" == "--if-changed" ]]; then
	HASH_FILE="${REPO_ROOT}/.manifest-hash"
	if command -v md5 &>/dev/null; then
		CURRENT_HASH=$(md5 -q "$0")
	else
		CURRENT_HASH=$(md5sum "$0" | cut -d' ' -f1)
	fi
	STORED_HASH=$(cat "${HASH_FILE}" 2>/dev/null || echo "")
	if [[ "${CURRENT_HASH}" == "${STORED_HASH}" ]]; then
		echo "init-nas.sh: unchanged - skipping directory creation."
		exit 0
	fi
	IF_CHANGED_MODE=1
	echo "init-nas.sh: changed - running full init."
fi

# Replace STACK_ROOT= line without sed interpolation of path (handles / & & safely; GNU + BSD awk).
replace_stack_root_in_file() {
	local target="$1"
	local tmp
	tmp="$(mktemp "${target}.XXXXXX")" || return 1
	STACK_ROOT_VALUE="${STACK_ROOT}" awk '
		/^STACK_ROOT=/ { print "STACK_ROOT=" ENVIRON["STACK_ROOT_VALUE"]; next }
		{ print }
	' "${target}" >"${tmp}" || {
		rm -f "${tmp}"
		return 1
	}
	mv "${tmp}" "${target}"
}

# -- 2. Write STACK_ROOT into repo-root .env ---------------------------
if [[ -f "${REPO_ENV}" ]]; then
	if grep -q '^STACK_ROOT=' "${REPO_ENV}" 2>/dev/null; then
		replace_stack_root_in_file "${REPO_ENV}"
		echo "Updated STACK_ROOT in ${REPO_ENV}"
	else
		echo "STACK_ROOT=${STACK_ROOT}" >>"${REPO_ENV}"
		echo "Appended STACK_ROOT to ${REPO_ENV}"
	fi
else
	if [[ -f "${REPO_ROOT}/.env.example" ]]; then
		cp "${REPO_ROOT}/.env.example" "${REPO_ENV}"
		if grep -q '^STACK_ROOT=' "${REPO_ENV}" 2>/dev/null; then
			replace_stack_root_in_file "${REPO_ENV}"
		else
			echo "STACK_ROOT=${STACK_ROOT}" >>"${REPO_ENV}"
		fi
		echo "Created ${REPO_ENV} from .env.example with resolved STACK_ROOT"
	else
		echo "STACK_ROOT=${STACK_ROOT}" >"${REPO_ENV}"
		echo "Created minimal ${REPO_ENV}"
	fi
fi

# Ensure PUID/PGID exist in repo .env (non-destructive append).
for kv in "PUID=0" "PGID=0"; do
	key="${kv%%=*}"
	if ! grep -q "^${key}=" "${REPO_ENV}" 2>/dev/null; then
		echo "${kv}" >>"${REPO_ENV}"
	fi
done

# -- 3. Create volume directories for all stacks -----------------------
echo ""
echo "Creating volume directories under ${STACK_ROOT} ..."

for entry in "${STACK_MANIFEST[@]}"; do
	# Skip comments and blank lines
	[[ "${entry}" =~ ^[[:space:]]*# ]] && continue
	[[ -z "${entry// /}" ]] && continue
	# Strip quotes if present
	entry="${entry//\"/}"
	stack="${entry%%:*}"
	sub_folders="${entry##*:}"
	# Trailing "stack:" with no sub-folders - omit stack: create nothing under STACK_ROOT.
	[[ -z "${sub_folders}" ]] && continue
	IFS=',' read -ra folders <<<"${sub_folders}"
	for folder in "${folders[@]}"; do
		[[ -z "${folder}" ]] && continue
		dir="${STACK_ROOT}/${stack}/${folder}"
		mkdir -p "${dir}"
		echo "  [OK] staged: ${dir}"
	done
done

# -- 4. Seed per-stack .env files from .env.example -------------------
# Delegates to bootstrap-env.sh so the logic stays in one place.
# --apply skips any stack that already has a .env (idempotent / safe to re-run).
# Operators must still edit each .env with real credentials before deploying.
echo ""
echo "Seeding per-stack .env files ..."
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/bootstrap-env.sh"
if [[ -f "${BOOTSTRAP_SCRIPT}" ]]; then
	bash "${BOOTSTRAP_SCRIPT}" --apply
else
	echo "  WARN: ${BOOTSTRAP_SCRIPT} not found -- skipping .env seeding" >&2
fi

# -- 5. Run fix-permissions.sh -----------------------------------------
echo ""
echo "Fixing permissions ..."
if [[ "$(id -u)" -eq 0 ]]; then
	bash "${SCRIPT_DIR}/fix-permissions.sh" "${STACK_ROOT}"
else
	echo "WARN: not root; run: sudo bash ${SCRIPT_DIR}/fix-permissions.sh ${STACK_ROOT}" >&2
fi

# -- 6. Create shared Docker networks ----------------------------------
# ce-internal: cross-stack backbone used by grafana-prom, databases,
#              ollama, and synology-api-bridge. Idempotent.
echo ""
echo "Creating shared Docker networks ..."
if [[ -x "${DOCKER}" ]]; then
	if "${DOCKER}" network inspect ce-internal &>/dev/null; then
		echo "  [OK] ce-internal already exists - skipping"
	else
		"${DOCKER}" network create \
			--driver bridge \
			--subnet 172.26.0.0/24 \
			--gateway 172.26.0.1 \
			ce-internal
		echo "  [OK] created: ce-internal (172.26.0.0/24)"
	fi
else
	echo "  WARN: docker not found at ${DOCKER} - create manually after Docker starts:"
	echo "    /usr/local/bin/docker network create --driver bridge --subnet 172.26.0.0/24 --gateway 172.26.0.1 ce-internal"
fi

# -- 7. Sync dockhand repo dir -> /volume2/docker/dockhand --------------
# Dockhand lives inside the repo (REPO_ROOT/dockhand/) but must run from
# /volume2/docker/dockhand/ because Dockhand/Container Manager uses that fixed
# path as its working directory.
#
# Strategy: push repo changes outward on every init-nas.sh run, but never
# overwrite live runtime state.  rsync is preferred; falls back to a manual
# loop when rsync is absent (busybox DSM builds).
#
# Protected (never touched):
#   .env          - operator credentials
#   data/         - runtime state (job history, DB, etc.)
#   secrets/      - Docker secret files
echo ""
echo "Syncing dockhand repo -> /volume2/docker/dockhand ..."

DOCKHAND_SRC="${REPO_ROOT}/dockhand"
DOCKHAND_DST="/volume2/docker/dockhand"

if [[ ! -d "${DOCKHAND_SRC}" ]]; then
	echo "  WARN: ${DOCKHAND_SRC} not found - skipping dockhand sync" >&2
elif [[ "$(cd "${DOCKHAND_SRC}" 2>/dev/null && pwd)" == "$(cd "${DOCKHAND_DST}" 2>/dev/null && pwd)" ]]; then
	echo "  [OK] Dockhand is already at its runtime path -- skipping sync"
else
	mkdir -p "${DOCKHAND_DST}"

	if command -v rsync &>/dev/null; then
		rsync \
			--archive \
			--exclude='.env' \
			--exclude='data/' \
			--exclude='secrets/' \
			"${DOCKHAND_SRC}/" \
			"${DOCKHAND_DST}/"
		echo "  [OK] rsync complete (protected: .env, data/, secrets/)"
	else
		# rsync not available - manual merge with cp -n (no-clobber) for protected files
		# and forced copy for everything else.
		echo "  rsync not found - using cp fallback"
		find "${DOCKHAND_SRC}" -maxdepth 1 -mindepth 1 | while IFS= read -r item; do
			name="$(basename "${item}")"
			case "${name}" in
				.env|data|secrets)
					# Protected - copy only if destination doesn't yet exist
					if [[ ! -e "${DOCKHAND_DST}/${name}" ]]; then
						cp -r "${item}" "${DOCKHAND_DST}/${name}"
						echo "  [OK] seeded (new):  ${DOCKHAND_DST}/${name}"
					else
						echo "  skip (protected): ${DOCKHAND_DST}/${name}"
					fi
					;;
				*)
					# Repo-owned file - always sync
					cp -r "${item}" "${DOCKHAND_DST}/${name}"
					echo "  [OK] updated: ${DOCKHAND_DST}/${name}"
					;;
			esac
		done
	fi

	# Ensure .env exists at destination (seed from .env.example if not yet present)
	if [[ ! -f "${DOCKHAND_DST}/.env" && -f "${DOCKHAND_SRC}/.env.example" ]]; then
		cp "${DOCKHAND_SRC}/.env.example" "${DOCKHAND_DST}/.env"
		echo "  [OK] seeded .env from .env.example - edit ${DOCKHAND_DST}/.env before starting"
	fi

	# When run via sudo, the files above were written as root. Re-own them back to
	# the invoking user (SUDO_USER) so they can be edited without sudo.
	# Protected dirs (.env, data/, secrets/) are intentionally excluded - they
	# keep whatever ownership was set when they were first created.
	if [[ "$(id -u)" -eq 0 && "${REAL_USER}" != "root" ]]; then
		find "${DOCKHAND_DST}" -maxdepth 1 -mindepth 1 \
			! -name '.env' \
			! -name 'data' \
			! -name 'secrets' \
			-exec chown -R "${REAL_USER}:${REAL_GROUP}" {} +
		echo "  [OK] ownership restored to ${REAL_USER}:${REAL_GROUP} (repo-owned files only)"
	fi

	echo "  src: ${DOCKHAND_SRC}"
	echo "  dst: ${DOCKHAND_DST}"
fi

echo ""
echo "----------------------------------------"
echo "Init complete."
echo "STACK_ROOT = ${STACK_ROOT}"
echo "Now open Dockhand/Container Manager and deploy your stacks."
echo "----------------------------------------"

# -- Write hash after successful full init (--if-changed runs only) ---
if [[ "${IF_CHANGED_MODE:-0}" -eq 1 ]]; then
	echo "${CURRENT_HASH}" >"${HASH_FILE}"
	echo "init-nas.sh: hash updated for next --if-changed run."
fi
