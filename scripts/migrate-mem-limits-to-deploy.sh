#!/usr/bin/env bash
# migrate-mem-limits-to-deploy.sh — convert legacy `mem_limit:` / `cpu_shares:`
# fields under each service into the canonical `deploy.resources.limits.{cpus,memory}`
# Compose v2 form, preserving comments and indentation.
#
# USAGE:
#   bash scripts/migrate-mem-limits-to-deploy.sh             # dry-run; show diff
#   bash scripts/migrate-mem-limits-to-deploy.sh --apply     # mutate files in place
#   bash scripts/migrate-mem-limits-to-deploy.sh --self-test # parse-only smoke check
#
# Idempotent: services that already declare a `deploy:` block are skipped.
# NOT part of the critical path — the legacy fields keep working on DSM 7.3.2.

set -euo pipefail

MODE="dry-run"
case "${1:-}" in
    --apply)     MODE="apply" ;;
    --dry-run|"") MODE="dry-run" ;;
    --self-test) MODE="self-test" ;;
    --help|-h)
        sed -n '2,12p' "$0" | sed 's/^# \?//'
        exit 0
        ;;
    *)
        echo "Unknown flag: ${1}" >&2
        exit 1
        ;;
esac

# ── locate repo root ─────────────────────────────────────────────────
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

if [[ "${MODE}" == "self-test" ]]; then
    echo "self-test: would parse ${STACKS}/*/compose.yaml; no mutations performed."
    find "${STACKS}" -maxdepth 4 -name compose.yaml | wc -l | awk '{ print "compose files scanned: " $1 }'
    exit 0
fi

# ── core logic ──────────────────────────────────────────────────────
# For each compose.yaml: find every service block. If a service has
# `mem_limit:` AND no `deploy:` block under it, append a `deploy:` block
# right after the last of {mem_limit, cpu_shares, mem_reservation} for that service.
#
# We use awk in two-pass mode: first pass indexes service start lines and the
# mem_limit / cpu_shares / mem_reservation lines under each; second pass emits
# the new YAML with appended `deploy:` blocks.

migrate_file() {
    local f="$1"
    local tmp
    tmp="$(mktemp "${f}.XXXXXX")"
    awk '
        BEGIN { in_services = 0; svc_indent = -1; svc_name = ""; svc_buf = ""; has_deploy = 0; }
        function flush_service(    deploy_indent, child_indent) {
            if (svc_name != "" && mem_limit_value != "" && has_deploy == 0) {
                # Indent: 2 deeper than the service-name line.
                deploy_indent = svc_indent + 2
                child_indent = deploy_indent + 2
                printf "%s%s\n", spaces(deploy_indent), "deploy:"
                printf "%s%s\n", spaces(deploy_indent + 2), "resources:"
                printf "%s%s\n", spaces(deploy_indent + 4), "limits:"
                printf "%s%s%s\n", spaces(deploy_indent + 6), "memory: ", mem_limit_value
                if (cpus_value != "") {
                    printf "%s%s%s\n", spaces(deploy_indent + 6), "cpus: \"", cpus_value "\""
                }
                if (mem_reservation_value != "") {
                    printf "%s%s\n", spaces(deploy_indent + 4), "reservations:"
                    printf "%s%s%s\n", spaces(deploy_indent + 6), "memory: ", mem_reservation_value
                }
            }
            svc_name = ""; mem_limit_value = ""; cpus_value = ""; mem_reservation_value = ""; has_deploy = 0
        }
        function spaces(n,   s, i) { s = ""; for (i = 0; i < n; i++) s = s " "; return s }
        function indent_of(line,    n) { n = 0; while (substr(line, n + 1, 1) == " ") n++; return n }

        /^services:[[:space:]]*$/ { in_services = 1; print; next }
        /^[a-zA-Z_]/ && in_services { in_services = 0 }

        in_services && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_-]*:[[:space:]]*$/ && indent_of($0) <= svc_indent + 2 {
            # New service definition — flush previous, capture this one.
            flush_service()
            svc_indent = indent_of($0)
            svc_name = $1
            print
            next
        }

        in_services && /[[:space:]]+mem_limit:[[:space:]]*/ {
            v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/[[:space:]]/, "", v); mem_limit_value = v
            print; next
        }
        in_services && /[[:space:]]+cpu_shares:[[:space:]]*/ {
            # Approximate translation: cpu_shares 1024 → cpus "1.0" baseline.
            v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/[[:space:]]/, "", v)
            cpus_value = sprintf("%.2f", v / 1024.0)
            print; next
        }
        in_services && /[[:space:]]+mem_reservation:[[:space:]]*/ {
            v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/[[:space:]]/, "", v); mem_reservation_value = v
            print; next
        }
        in_services && /[[:space:]]+deploy:[[:space:]]*$/ { has_deploy = 1; print; next }

        { print }
        END { flush_service() }
    ' "${f}" > "${tmp}"

    if [[ "${MODE}" == "apply" ]]; then
        mv "${tmp}" "${f}"
        echo "  applied: ${f#"${ROOT}/"}"
    else
        if ! diff -q "${f}" "${tmp}" >/dev/null 2>&1; then
            echo ""
            echo "=== ${f#"${ROOT}/"} ==="
            diff -u "${f}" "${tmp}" || true
        fi
        rm -f "${tmp}"
    fi
}

count=0
while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    migrate_file "${f}"
    count=$((count + 1))
done < <(find "${STACKS}" -maxdepth 4 -name compose.yaml ! -path '*/.git/*' | sort)

echo ""
if [[ "${MODE}" == "apply" ]]; then
    echo "Done: ${count} compose file(s) processed."
    echo "Run scripts/compose-validate.sh to confirm validity."
else
    echo "Dry-run complete: ${count} compose file(s) scanned."
    echo "Re-run with --apply to mutate."
fi
