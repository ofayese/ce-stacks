#!/usr/bin/env bash
# Fail if stack assets or hive proposals are duplicated at repo root.
# Canonical: stacks/<name>/ and docs/hive/proposals/<name>/ only.
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
STACKS="${ROOT}/stacks"
cd "$ROOT"

if [[ -e "${ROOT}/hive" ]]; then
	echo "ERROR: root-level hive/ must not exist. Hive docs belong under docs/hive/." >&2
	exit 1
fi

if [[ -e "${STACKS}/docs" ]]; then
	echo "ERROR: stacks/docs/ must not exist. Hive docs belong at repo-root docs/hive/ (not under stacks/)." >&2
	exit 1
fi

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

echo "OK: repo layout (no root-level hive/ or stack-name duplicates)."
