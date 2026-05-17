#!/usr/bin/env bash
# lint-rfc1918.sh -- fail if any bridge `subnet:` declared in stacks/*/compose.yaml
# falls outside RFC1918 (10/8, 172.16/12, 192.168/16).
#
# USAGE:
#   bash scripts/lint-rfc1918.sh           # report all subnets, exit non-zero on first violation
#   bash scripts/lint-rfc1918.sh --quiet   # only print failures
#
# This is invoked by scripts/verify-repo-layout.sh and may also be run standalone.

set -euo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

# -- locate repo root -------------------------------------------------
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

# -- assert_rfc1918 ---------------------------------------------------
# Returns 0 if the CIDR (e.g. "172.31.10.0/24" or "172.31.10.0") is inside RFC1918.
# Returns 1 otherwise.
assert_rfc1918() {
    local cidr="$1"
    local ip="${cidr%%/*}"
    local o1 o2 _o3 _o4
    IFS='.' read -r o1 o2 _o3 _o4 <<< "${ip}"
    # Reject obviously malformed input
    [[ -z "${o1}" || -z "${o2}" ]] && return 1
    # 10.0.0.0/8
    if [[ "${o1}" == "10" ]]; then
        return 0
    fi
    # 172.16.0.0/12 -- second octet 16..31 inclusive
    if [[ "${o1}" == "172" ]] && (( o2 >= 16 && o2 <= 31 )); then
        return 0
    fi
    # 192.168.0.0/16
    if [[ "${o1}" == "192" && "${o2}" == "168" ]]; then
        return 0
    fi
    return 1
}

# -- walk every compose file under stacks/ ----------------------------
violations=0
checked=0

while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    # Extract every "subnet:" line in this compose file.
    # Tolerates quoting variations: 'subnet: 172.x.y.z/24' or 'subnet: "172.x.y.z/24"'.
    while IFS= read -r line; do
        # Strip comments, "subnet:" prefix, whitespace, and quote characters.
        # NOTE: \047 inside sed [...] is literal chars (\047), not octal -- use tr.
        cidr="$(echo "${line}" | sed -E 's/#.*$//; s/.*subnet:[[:space:]]*//' | tr -d $'[:space:]\042\047')"
        [[ -z "${cidr}" ]] && continue
        rel="${f#"${ROOT}/"}"
        checked=$((checked + 1))
        if assert_rfc1918 "${cidr}"; then
            [[ "${QUIET}" -eq 0 ]] && printf '  OK    %-50s %s\n' "${rel}" "${cidr}"
        else
            printf '  FAIL  %-50s %s   <- outside RFC1918\n' "${rel}" "${cidr}" >&2
            violations=$((violations + 1))
        fi
    done < <(grep -E '^[[:space:]]*-?[[:space:]]*subnet:' "${f}" || true)
done < <(find "${STACKS}" -maxdepth 4 \
    \( -name compose.yaml -o -name docker-compose.yml -o -name docker-compose.yaml \) \
    ! -path '*/.git/*' -print | sort)

echo ""
if [[ "${violations}" -gt 0 ]]; then
    echo "FAIL: ${violations} subnet(s) outside RFC1918 (of ${checked} checked)." >&2
    echo "RFC1918 ranges: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16" >&2
    exit 1
fi
echo "OK: ${checked} subnets inside RFC1918."
