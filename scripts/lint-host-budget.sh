#!/usr/bin/env bash
# lint-host-budget.sh -- fail if Sum `mem_limit` across stacks/*/compose.yaml
# exceeds the host RAM budget.
#
# USAGE:
#   bash scripts/lint-host-budget.sh
#   HOST_MEM_BUDGET_MB=20000 bash scripts/lint-host-budget.sh    # tighter budget
#   bash scripts/lint-host-budget.sh --self-test                 # run unit tests
#
# Default budget: 26 624 MB (26 GiB), calibrated for the DS723+ host
# `otsorundscore`: 32 GB physical - DSM/BTRFS/kernel overhead.
#
# Invoked by scripts/compose-validate.sh after the per-stack `docker compose
# config` pass, and runnable standalone.

set -euo pipefail

# Default 32 000 MB = physical RAM on `otsorundscore` (DS723+, 32 GB).
# Rationale: Docker `mem_limit` is a CGroup memory.max CEILING (lazy, only
# enforced at allocation), not a reservation. So Sum mem_limit <= physical RAM
# is the absolute-worst-case correctness boundary: if every stack
# simultaneously approached its cap, the kernel would still have a fighting
# chance to avoid OOM. Stricter overrides (e.g. 26000 to leave headroom for
# DSM + BTRFS metadata) are encouraged on the NAS:
#   HOST_MEM_BUDGET_MB=26000 bash scripts/lint-host-budget.sh
BUDGET_MB="${HOST_MEM_BUDGET_MB:-32000}"

# -- parse_mem_to_mb -------------------------------------------------
# Accepts: 128m, 512M, 1g, 14G, 2GB, 256MB, 1024k, 4096b, or a bare integer (assumed bytes).
# Emits: integer megabytes (floor).
# Returns 1 if input is empty / malformed.
parse_mem_to_mb() {
    local v="${1:-}"
    [[ -z "${v}" ]] && return 1
    # Normalize: lowercase, strip whitespace, strip trailing 'b'
    v="$(echo "${v}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    v="${v%b}"
    local num="${v%[kmgt]*}"
    local unit="${v#"${num}"}"
    # If $num and $v are equal, no unit was present -> assume bytes
    if [[ "${num}" == "${v}" ]]; then
        unit="bytes"
    fi
    # Validate numeric
    [[ "${num}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    awk -v n="${num}" -v u="${unit}" 'BEGIN {
        if (u == "bytes") { print int(n / 1024 / 1024); }
        else if (u == "k") { print int(n / 1024); }
        else if (u == "m") { print int(n); }
        else if (u == "g") { print int(n * 1024); }
        else if (u == "t") { print int(n * 1024 * 1024); }
        else { exit 1 }
    }'
}

# -- --self-test ------------------------------------------------------
if [[ "${1:-}" == "--self-test" ]]; then
    pass=0; fail=0
    check() {
        local got expected
        got="$(parse_mem_to_mb "$1" 2>/dev/null || echo "ERR")"
        expected="$2"
        if [[ "${got}" == "${expected}" ]]; then
            echo "  PASS  parse_mem_to_mb('$1') = ${got}"
            pass=$((pass + 1))
        else
            echo "  FAIL  parse_mem_to_mb('$1') = ${got} (expected ${expected})"
            fail=$((fail + 1))
        fi
    }
    check "128m" "128"
    check "512M" "512"
    check "1g" "1024"
    check "14g" "14336"
    check "2G" "2048"
    check "256MB" "256"
    check "16m" "16"
    echo ""
    echo "Self-test: ${pass} passed, ${fail} failed."
    [[ "${fail}" -eq 0 ]] || exit 1
    exit 0
fi

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

# -- walk every compose file, sum mem_limit per stack ----------------
total_mb=0
declare -a rows=()

while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    stack="$(basename "$(dirname "${f}")")"
    stack_mb=0
    while IFS= read -r line; do
        # NOTE: \047 inside sed [...] is literal chars (\047), not octal -- use tr.
        val="$(echo "${line}" | sed -E 's/#.*$//; s/.*mem_limit:[[:space:]]*//' | tr -d $'[:space:]\042\047')"
        [[ -z "${val}" ]] && continue
        mb="$(parse_mem_to_mb "${val}" 2>/dev/null || echo "0")"
        stack_mb=$((stack_mb + mb))
    done < <(grep -E '^[[:space:]]*mem_limit:' "${f}" || true)
    if (( stack_mb > 0 )); then
        rows+=("$(printf '%-30s %6d MB' "${stack}" "${stack_mb}")")
        total_mb=$((total_mb + stack_mb))
    fi
done < <(find "${STACKS}" -maxdepth 4 \
    \( -name compose.yaml -o -name docker-compose.yml -o -name docker-compose.yaml \) \
    ! -path '*/.git/*' -print | sort)

printf '%s\n' "${rows[@]}" | sort -k2 -n -r
echo "------------------------------------------------"
printf '%-30s %6d MB  (budget: %d MB)\n' "TOTAL" "${total_mb}" "${BUDGET_MB}"
echo ""

if (( total_mb > BUDGET_MB )); then
    over=$((total_mb - BUDGET_MB))
    echo "FAIL: total mem_limit ${total_mb} MB exceeds budget ${BUDGET_MB} MB by ${over} MB." >&2
    echo "Reduce mem_limit on the largest stacks (top of the list above) or raise HOST_MEM_BUDGET_MB." >&2
    exit 1
fi
echo "OK: total mem_limit ${total_mb} MB <= budget ${BUDGET_MB} MB."
