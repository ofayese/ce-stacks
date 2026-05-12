#!/usr/bin/env bash
# fix-permissions.sh
# Resets ownership and permissions for all Dockge stack data directories.
# Idempotent — safe to run multiple times.
# Usage: sudo bash scripts/fix-permissions.sh [stacks-root]
# With no argument: reads STACK_ROOT from repo-root .env if present, else /volume2/docker/ce-stacks.
# Called automatically by init-nas.sh.

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${_script_dir}"
while [[ ! -f "${ROOT}/HIVE_OBJECTIVE.md" && "${ROOT}" != "/" ]]; do
	ROOT="$(dirname "${ROOT}")"
done
[[ -f "${ROOT}/HIVE_OBJECTIVE.md" ]] || {
	echo "ERROR: could not find repo root (HIVE_OBJECTIVE.md) above ${_script_dir}" >&2
	exit 1
}

if [[ -n "${1:-}" ]]; then
	STACKS_ROOT="$1"
else
	REPO_ENV="${ROOT}/.env"
	if [[ -f "${REPO_ENV}" ]] && grep -q '^STACK_ROOT=' "${REPO_ENV}" 2>/dev/null; then
		STACKS_ROOT="$(grep '^STACK_ROOT=' "${REPO_ENV}" | tail -n1 | cut -d= -f2-)"
	else
		STACKS_ROOT="/volume2/docker/ce-stacks"
	fi
fi

if [[ ! -d "${STACKS_ROOT}" ]]; then
	echo "ERROR: ${STACKS_ROOT} does not exist. Run init-nas.sh first." >&2
	exit 1
fi

echo "Resetting ownership and permissions under ${STACKS_ROOT} ..."

while IFS= read -r -d '' stack_dir; do
	echo "  → ${stack_dir}"
	chown -R 0:0 "${stack_dir}"
	find "${stack_dir}" -type d -exec chmod 755 {} \;
	find "${stack_dir}" -type f -exec chmod 644 {} \;
done < <(find "${STACKS_ROOT}" -maxdepth 1 -mindepth 1 -type d -print0)

echo "Done."
