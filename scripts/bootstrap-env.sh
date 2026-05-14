#!/usr/bin/env bash
# bootstrap-env.sh - copy .env.example → .env for every stack that has one.
#
# USAGE:
#   bash scripts/bootstrap-env.sh            # dry-run (show what would be copied)
#   bash scripts/bootstrap-env.sh --apply    # actually copy
#   bash scripts/bootstrap-env.sh --force    # overwrite existing .env files
#
# NOTES:
#   - By default (no flags) the script runs in dry-run mode and prints a plan.
#   - Without --force, existing .env files are NEVER overwritten - your live
#     credentials are safe even if you re-run the script after first deploy.
#   - Stacks with :? guards in their compose.yaml will fail on `docker compose up`
#     if the required variables are left at their placeholder values - edit .env
#     after running this script.

set -euo pipefail

# ── locate repo root ──────────────────────────────────────────────────────────
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${_script_dir}"
while [[ ! -f "${ROOT}/README.md" && "${ROOT}" != "/" ]]; do
    ROOT="$(dirname "${ROOT}")"
done
[[ -f "${ROOT}/README.md" ]] || {
    echo "ERROR: could not find repo root (README.md) above ${_script_dir}" >&2
    exit 1
}

# ── parse flags ───────────────────────────────────────────────────────────────
DRY_RUN=true
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --apply) DRY_RUN=false ;;
        --force) FORCE=true; DRY_RUN=false ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown flag: $arg  (use --apply or --force)" >&2
            exit 1
            ;;
    esac
done

# ── collect all .env.example files ───────────────────────────────────────────
# Looks in stacks/*/ and the repo root-level dockhand/ directory.
mapfile -t EXAMPLES < <(find "${ROOT}/stacks" "${ROOT}/dockhand" \
    -maxdepth 2 -name ".env.example" 2>/dev/null | sort)

if [[ ${#EXAMPLES[@]} -eq 0 ]]; then
    echo "No .env.example files found under ${ROOT}/stacks or ${ROOT}/dockhand"
    exit 0
fi

# ── header ────────────────────────────────────────────────────────────────────
if $DRY_RUN; then
    echo "=== bootstrap-env.sh - DRY RUN (pass --apply to execute) ==="
else
    if $FORCE; then
        echo "=== bootstrap-env.sh - APPLY + FORCE (existing .env files will be overwritten) ==="
    else
        echo "=== bootstrap-env.sh - APPLY (existing .env files will NOT be overwritten) ==="
    fi
fi
echo ""

COPIED=0; SKIPPED=0; WOULD_COPY=0; WOULD_SKIP=0

for example in "${EXAMPLES[@]}"; do
    dir="$(dirname "$example")"
    stack="$(basename "$dir")"
    target="${dir}/.env"
    rel_target="${target#"${ROOT}/"}"

    if [[ -f "$target" ]] && ! $FORCE; then
        if $DRY_RUN; then
            echo "  SKIP  ${rel_target}  (already exists - use --force to overwrite)"
            WOULD_SKIP=$((WOULD_SKIP + 1))
        else
            echo "  skip  ${rel_target}  (already exists)"
            SKIPPED=$((SKIPPED + 1))
        fi
    else
        if $DRY_RUN; then
            if [[ -f "$target" ]]; then
                echo "  COPY  ${rel_target}  ← ${stack}/.env.example  [would overwrite]"
            else
                echo "  COPY  ${rel_target}  ← ${stack}/.env.example"
            fi
            WOULD_COPY=$((WOULD_COPY + 1))
        else
            cp "$example" "$target"
            if [[ -f "$target" ]]; then
                echo "  ✓     ${rel_target}"
            fi
            COPIED=$((COPIED + 1))
        fi
    fi
done

echo ""

# ── summary ───────────────────────────────────────────────────────────────────
if $DRY_RUN; then
    echo "Dry-run complete: ${WOULD_COPY} would be copied, ${WOULD_SKIP} would be skipped."
    echo "Run with --apply to execute, or --force to overwrite existing files."
else
    echo "Done: ${COPIED} copied, ${SKIPPED} skipped."
    if [[ $COPIED -gt 0 ]]; then
        echo ""
        echo "Next steps:"
        echo "  1. Edit each new .env file - replace placeholder values with real credentials."
        echo "     Variables marked :? will cause 'docker compose up' to fail until set."
        echo "  2. chmod 600 stacks/*/.env dockhand/.env   (restrict read access)"
        echo "  3. Populate secrets/*.txt files where Docker file-based secrets are used"
        echo "     (code-server, acme-sh - see each stack's secrets/README.md)."
    fi
fi
