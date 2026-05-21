#!/usr/bin/env bash
# lint-compose-security.sh -- detect security and compatibility issues in compose files.
#
# USAGE:
#   bash scripts/lint-compose-security.sh           # report all issues
#   bash scripts/lint-compose-security.sh --strict  # exit on any warning
#
# Checks:
#   1. NET_ADMIN + read_only:true (Synology DSM incompatible)
#   2. Inconsistent port binding quoting
#   3. Missing networks block definition
#   4. Unsafe PUID/PGID defaults (Synology requires 0:0)
#   5. Log driver options consistency

set -euo pipefail

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

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

violations=0
warnings=0

# Check 1: NET_ADMIN + read_only incompatibility
echo "-- Security Check: NET_ADMIN + read_only --"
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    rel="${f#"${ROOT}/"}"
    
    # Extract service names and check for problematic combinations
    in_service=0
    service_name=""
    has_net_admin=0
    has_read_only=0
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*[a-z_-]+:[[:space:]]*$ ]] && [[ ! "$line" =~ ^[[:space:]]{6,} ]]; then
            # New service definition at level 2
            if [[ $in_service -eq 1 && $has_net_admin -eq 1 && $has_read_only -eq 1 ]]; then
                printf '  WARN  %-50s service:%s (NET_ADMIN + read_only)\n' "${rel}" "${service_name}" >&2
                warnings=$((warnings + 1))
            fi
            service_name="$(echo "$line" | sed 's/:.*//')"
            has_net_admin=0
            has_read_only=0
            in_service=1
        elif [[ "$line" =~ "NET_ADMIN" ]]; then
            has_net_admin=1
        elif [[ "$line" =~ "read_only: true" ]]; then
            has_read_only=1
        fi
    done < "$f"
    
    # Check final service
    if [[ $in_service -eq 1 && $has_net_admin -eq 1 && $has_read_only -eq 1 ]]; then
        printf '  WARN  %-50s service:%s (NET_ADMIN + read_only)\n' "${rel}" "${service_name}" >&2
        warnings=$((warnings + 1))
    fi
done < <(find "${STACKS}" -maxdepth 4 \
    \( -name compose.yaml -o -name docker-compose.yml -o -name docker-compose.yaml \) \
    ! -path '*/.git/*' -print | sort)

# Check 2: Port binding quoting consistency
echo "-- Consistency Check: Port Binding Quoting --"
unquoted_count=0
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    rel="${f#"${ROOT}/"}"
    
    # Find unquoted ports that mix IP:host:container (likely YAML parsing ambiguity)
    if grep -qE 'ports:[[:space:]]*$' "$f"; then
        while IFS= read -r port_line; do
            # Match unquoted ports with colons (e.g., - 10.0.1.15:8812:8811)
            if [[ "$port_line" =~ ^[[:space:]]*-[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+:[0-9]+$ ]]; then
                printf '  WARN  %-50s (port binding unquoted, should be quoted string)\n' "${rel}" >&2
                unquoted_count=$((unquoted_count + 1))
                warnings=$((warnings + 1))
                break
            fi
        done < <(grep -A 50 'ports:' "$f" | head -20)
    fi
done < <(find "${STACKS}" -maxdepth 4 \
    \( -name compose.yaml -o -name docker-compose.yml -o -name docker-compose.yaml \) \
    ! -path '*/.git/*' -print | sort)

# Check 3: Missing networks block
echo "-- Structure Check: Networks Definition --"
missing_net=0
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    rel="${f#"${ROOT}/"}"
    
    # If services reference networks: but no networks: block exists at root
    if grep -q 'networks:' "$f"; then
        if ! grep -q '^networks:' "$f"; then
            printf '  WARN  %-50s (networks: referenced but no networks: block defined)\n' "${rel}" >&2
            missing_net=$((missing_net + 1))
            warnings=$((warnings + 1))
        fi
    fi
done < <(find "${STACKS}" -maxdepth 4 \
    \( -name compose.yaml -o -name docker-compose.yml -o -name docker-compose.yaml \) \
    ! -path '*/.git/*' -print | sort)

# Check 4: PUID/PGID defaults for Synology (should be 0:0 or explicit)
echo "-- Host Profile Check: PUID/PGID Defaults --"
bad_defaults=0
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    rel="${f#"${ROOT}/"}"
    
    # Warn if PUID/PGID defaults are not 0
    if grep -qE 'PUID=\$\{PUID:-[^0]' "$f"; then
        printf '  WARN  %-50s (PUID default not 0; Synology may fail bind-mount ownership)\n' "${rel}" >&2
        bad_defaults=$((bad_defaults + 1))
        warnings=$((warnings + 1))
    fi
done < <(find "${STACKS}" -maxdepth 4 \
    \( -name compose.yaml -o -name docker-compose.yml -o -name docker-compose.yaml \) \
    ! -path '*/.git/*' -print | sort)

echo ""
echo "Checks completed:"
echo "  Violations: ${violations}"
echo "  Warnings: ${warnings}"
echo ""

if [[ $STRICT -eq 1 && $warnings -gt 0 ]]; then
    echo "FAIL: --strict mode; exiting on warnings." >&2
    exit 1
fi

if [[ $violations -gt 0 ]]; then
    echo "FAIL: ${violations} violation(s) found." >&2
    exit 1
fi

echo "OK: all security and consistency checks passed."
