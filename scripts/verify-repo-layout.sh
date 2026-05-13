#!/usr/bin/env bash
# Fail if any stacks/<name>/ directory is duplicated at repo root.
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

err=0
while IFS= read -r -d '' stack_dir; do
	name="$(basename "${stack_dir}")"
	# Synology / macOS SMB: @eaDir is AppleDouble metadata, not a Dockge stack.
	[[ "${name}" == "@eaDir" ]] && continue
	if [[ -e "${ROOT}/${name}" ]]; then
		echo "ERROR: root-level duplicate path \"${ROOT}/${name}\" shadows stacks/${name}/ — remove or move under stacks/." >&2
		err=1
	fi
done < <(find "${STACKS}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

if [[ "${err}" -ne 0 ]]; then
	exit 1
fi

echo "OK: repo layout (no root-level stack-name duplicates)."
