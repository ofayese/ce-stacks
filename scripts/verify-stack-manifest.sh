#!/usr/bin/env bash
# Portable check: stack names in scripts/init-nas.sh STACK_MANIFEST match ls stacks/.
# (BSD grep lacks grep -oP; avoid matching unrelated "foo:bar" strings in echo lines.)
set -euo pipefail
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${_script_dir}"
while [[ ! -f "${ROOT}/HIVE_OBJECTIVE.md" && "${ROOT}" != "/" ]]; do
	ROOT="$(dirname "${ROOT}")"
done
[[ -f "${ROOT}/HIVE_OBJECTIVE.md" ]] || {
	echo "ERROR: could not find repo root" >&2
	exit 1
}
init_script="${ROOT}/scripts/init-nas.sh"
# shellcheck disable=SC2012
diff <(
	awk '
		/^STACK_MANIFEST=\(/ { inm=1; next }
		inm && /^\)/ { inm=0; next }
		inm && /^[[:space:]]*"/ {
			sub(/^[[:space:]]*"/, "")
			sub(/"[[:space:]]*,?$/, "")
			sub(/:.*$/, "")
			print
		}
	' "${init_script}" | sort -u
) <(ls "${ROOT}/stacks" | sort)
