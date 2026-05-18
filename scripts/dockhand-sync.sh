#!/usr/bin/env bash
# =============================================================================
# dockhand-sync.sh -- re-sync ce-stacks/dockhand/ -> /volume2/docker/dockhand/
# =============================================================================
# Wrapper around the same rsync/cp logic used by scripts/init-nas.sh, scoped
# to only the dockhand/ subtree. Use this when you've pulled new commits in
# ce-stacks and want to update the runtime Dockhand install without
# re-running the full bootstrap.
#
# Safety:
#   * Refuses to run unless dockhand/scripts/dockhand-start.sh exists in the
#     source tree (catches "wrong cwd" mistakes).
#   * Preserves runtime state -- never overwrites:
#       - /volume2/docker/dockhand/.env
#       - /volume2/docker/dockhand/data/
#       - /volume2/docker/dockhand/db/
#       - /volume2/docker/dockhand/stacks/
#       - /volume2/docker/dockhand/git-repos/
#       - /volume2/docker/dockhand/tmp/
#       - /volume2/docker/dockhand/icons/
#       - /volume2/docker/dockhand/snapshots/
#       - /volume2/docker/dockhand/scanner-cache/
#       - /volume2/docker/dockhand/secrets/
#   * Idempotent -- safe to re-run.
#
# Usage:
#   bash /volume2/docker/ce-stacks/scripts/dockhand-sync.sh
#   bash /volume2/docker/ce-stacks/scripts/dockhand-sync.sh --dry-run
#
# After sync, re-install the RC script if dockhand-start.sh changed:
#   sudo cp /volume2/docker/dockhand/scripts/dockhand-start.sh \
#           /usr/local/etc/rc.d/dockhand.sh
#   sudo chmod +x /usr/local/etc/rc.d/dockhand.sh
#   sudo /usr/local/etc/rc.d/dockhand.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${REPO_ROOT}/dockhand"
DST="${DOCKHAND_DEST:-/volume2/docker/dockhand}"

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,35p' "$0"
            exit 0
            ;;
        *)
            echo "dockhand-sync: unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

# ---- Preflight ---------------------------------------------------------------
if [ ! -d "${SRC}" ]; then
    echo "dockhand-sync: ERROR: source not found: ${SRC}" >&2
    echo "dockhand-sync: are you running from the correct ce-stacks clone?" >&2
    exit 1
fi

if [ ! -f "${SRC}/scripts/dockhand-start.sh" ]; then
    echo "dockhand-sync: ERROR: ${SRC}/scripts/dockhand-start.sh missing" >&2
    echo "dockhand-sync: refusing to sync an incomplete dockhand/ tree." >&2
    exit 1
fi

mkdir -p "${DST}"

echo "dockhand-sync: source: ${SRC}"
echo "dockhand-sync: dest:   ${DST}"
[ "$DRY_RUN" -eq 1 ] && echo "dockhand-sync: DRY RUN -- no files will be written"

# ---- Sync --------------------------------------------------------------------
# Excludes match the runtime/state-bearing paths created by Dockhand itself
# and any operator-managed secrets.
EXCLUDES=(
    --exclude=".env"
    --exclude="data/"
    --exclude="db/"
    --exclude="stacks/"
    --exclude="git-repos/"
    --exclude="tmp/"
    --exclude="icons/"
    --exclude="snapshots/"
    --exclude="scanner-cache/"
    --exclude="secrets/"
    --exclude=".DS_Store"
)

if command -v rsync >/dev/null 2>&1; then
    RSYNC_FLAGS=(-a --delete-excluded)
    [ "$DRY_RUN" -eq 1 ] && RSYNC_FLAGS+=(--dry-run --itemize-changes)
    rsync "${RSYNC_FLAGS[@]}" "${EXCLUDES[@]}" "${SRC}/" "${DST}/"
else
    echo "dockhand-sync: rsync not available; using safer cp fallback"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "dockhand-sync: (dry-run) would copy ${SRC}/ -> ${DST}/ (preserving runtime state)"
    else
        # Backup and preserve protected runtime paths before copy.
        for protected in data db stacks git-repos tmp icons snapshots scanner-cache secrets .env; do
            if [ -e "${DST}/${protected}" ]; then
                mv "${DST}/${protected}" "${DST}/${protected}.backup.$$" || {
                    echo "dockhand-sync: ERROR: failed to backup ${DST}/${protected}" >&2
                    exit 1
                }
            fi
        done
        # Now copy everything from source.
        cp -R "${SRC}/." "${DST}/" || {
            echo "dockhand-sync: ERROR: cp failed; restoring backups" >&2
            for protected in data db stacks git-repos tmp icons snapshots scanner-cache secrets .env; do
                [ -e "${DST}/${protected}.backup.$$" ] && mv "${DST}/${protected}.backup.$$" "${DST}/${protected}"
            done
            exit 1
        }
        # Restore protected paths from backups.
        for protected in data db stacks git-repos tmp icons snapshots scanner-cache secrets .env; do
            if [ -e "${DST}/${protected}.backup.$$" ]; then
                rm -rf "${DST}/${protected}"
                mv "${DST}/${protected}.backup.$$" "${DST}/${protected}"
            fi
        done
    fi
fi

chmod +x "${DST}/scripts/"*.sh 2>/dev/null || true
chmod +x "${DST}/"*.sh 2>/dev/null || true

echo "dockhand-sync: done."
echo "dockhand-sync: if scripts/dockhand-start.sh changed, re-install the RC script:"
echo "  sudo cp ${DST}/scripts/dockhand-start.sh /usr/local/etc/rc.d/dockhand.sh"
echo "  sudo chmod +x /usr/local/etc/rc.d/dockhand.sh"
echo "  sudo /usr/local/etc/rc.d/dockhand.sh"
