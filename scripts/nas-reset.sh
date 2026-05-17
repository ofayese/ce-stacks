#!/bin/sh
# =============================================================================
# nas-reset.sh
# Location: /volume2/docker/nas-reset.sh  (NOT inside the ce-stacks repo)
# =============================================================================
# Usage:
#   sudo sh /volume2/docker/nas-reset.sh               # interactive
#   sudo sh /volume2/docker/nas-reset.sh --yes         # non-interactive
#   sudo sh /volume2/docker/nas-reset.sh --dry-run     # preflight only
#   sudo sh /volume2/docker/nas-reset.sh --yes --fix   # non-interactive + fix .env
#
# What it does:
#   1. Pre-flight checks (dirs, git, SSH key)
#   2. Backs up /volume2/docker/ce-stacks -> /volume2/docker/archive/ce-stacks-backup-<ts>
#   3. Clones fresh repo into /volume2/docker/ce-stacks
#   4. Calls scripts/restore-env.sh  - validates + restores .env files from backup
#   5. Calls scripts/init-nas.sh     - creates STACK_ROOT directories
#   6. Calls scripts/fix-permissions.sh - normalises stack data dir ownership
#   7. Fixes repo-level ownership
#   8. Prints next steps
# =============================================================================

set -eu

# -- Config --------------------------------------------------------------------
CE_STACKS_DIR="/volume2/docker/ce-stacks"
BACKUP_ROOT="/volume2/docker/archive"
REPO_URL="git@github.com:ofayese/ce-stacks.git"
# Use the operator's SSH key even when running as root
export GIT_SSH_COMMAND='ssh -i /var/services/homes/laolufayese/.ssh/id_ed25519 -o StrictHostKeyChecking=no'
OWNER="laolufayese"
GROUP="administrators"
YES=0
DRY_RUN=0
FIX_ENV=0

# -- Args ----------------------------------------------------------------------
for arg in "$@"; do
	case "$arg" in
	--yes | -y) YES=1 ;;
	--dry-run) DRY_RUN=1 ;;
	--fix) FIX_ENV=1 ;;
	--help)
		sed -n '3,14p' "$0" | sed 's/^# //'
		exit 0
		;;
	*)
		echo "Unknown argument: $arg"
		exit 1
		;;
	esac
done

# -- Helpers -------------------------------------------------------------------
fail() {
	echo ""
	echo "ERROR: $*" >&2
	exit 1
}
ok() { echo "  OK  $*"; }
info() {
	echo ""
	echo "==> $*"
}
warn() { echo "  WARN $*"; }

# -- Pre-flight ----------------------------------------------------------------
info "Pre-flight checks"

command -v git >/dev/null 2>&1 || fail "git not found - install via SynoCommunity"
ok "git: $(git --version)"

command -v bash >/dev/null 2>&1 || fail "bash not found - required for fix-permissions.sh"
ok "bash: $(bash --version | head -1)"

[ -d "${CE_STACKS_DIR}" ] || fail "${CE_STACKS_DIR} does not exist - nothing to back up"
ok "${CE_STACKS_DIR} exists"

[ -d "${BACKUP_ROOT}" ] || warn "${BACKUP_ROOT} does not exist - will create it"

SSH_TEST=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -T git@github.com 2>&1 || true)
if echo "${SSH_TEST}" | grep -qi "successfully authenticated"; then
	ok "GitHub SSH auth confirmed"
else
	warn "GitHub SSH auth not confirmed - output: ${SSH_TEST}"
fi

if [ "${DRY_RUN}" -eq 1 ]; then
	echo ""
	echo "==> Dry run complete - no changes made"
	echo "    Run without --dry-run to proceed"
	exit 0
fi

echo ""

# -- Confirmation --------------------------------------------------------------
if [ "${YES}" -eq 0 ]; then
	echo "  This will MOVE ${CE_STACKS_DIR} to a timestamped backup"
	echo "  and clone a fresh copy from GitHub."
	echo ""
	printf "  Continue? [y/N] "
	read -r answer
	case "$answer" in
	y | Y | yes | YES) ;;
	*)
		echo "Aborted."
		exit 0
		;;
	esac
fi

# -- Timestamp -----------------------------------------------------------------
TS=$(date +"%Y%m%d-%H%M%S")
BACKUP_DIR="${BACKUP_ROOT}/ce-stacks-backup-${TS}"

# -- Create archive root -------------------------------------------------------
if [ ! -d "${BACKUP_ROOT}" ]; then
	info "Creating backup root: ${BACKUP_ROOT}"
	mkdir -p "${BACKUP_ROOT}" || fail "Cannot create ${BACKUP_ROOT}"
fi

# -- Backup --------------------------------------------------------------------
info "Backing up ${CE_STACKS_DIR} -> ${BACKUP_DIR}"
mv "${CE_STACKS_DIR}" "${BACKUP_DIR}" || fail "mv failed - aborting before clone"
ok "Backup complete: ${BACKUP_DIR}"

# -- Clone (with rollback on failure) -----------------------------------------
info "Cloning ${REPO_URL} -> ${CE_STACKS_DIR}"
git clone "${REPO_URL}" "${CE_STACKS_DIR}" || {
	echo ""
	echo "ERROR: git clone failed - rolling back"
	mv "${BACKUP_DIR}" "${CE_STACKS_DIR}"
	fail "Clone failed. Backup restored to ${CE_STACKS_DIR}"
}
ok "Clone complete"

# -- git safe.directory --------------------------------------------------------
git config --global --add safe.directory "${CE_STACKS_DIR}" 2>/dev/null || true

# -- restore-env.sh -----------------------------------------------------------
# Auto-detects most recent backup under BACKUP_ROOT - picks up ${BACKUP_DIR} correctly.
RESTORE_SCRIPT="${CE_STACKS_DIR}/scripts/restore-env.sh"
info "Restoring .env files (scripts/restore-env.sh)"

if [ ! -f "${RESTORE_SCRIPT}" ]; then
	warn "${RESTORE_SCRIPT} not found - skipping .env restore"
	warn "Copy .env files manually from: ${BACKUP_DIR}"
else
	if [ "${FIX_ENV}" -eq 1 ]; then
		RESTORE_ARGS="--fix"
	else
		RESTORE_ARGS=""
	fi

	if [ -n "${RESTORE_ARGS}" ]; then
		if sh "${RESTORE_SCRIPT}" "${RESTORE_ARGS}"; then
			ok "restore-env.sh complete"
		else
			warn "restore-env.sh exited non-zero - check output above"
		fi
	else
		if sh "${RESTORE_SCRIPT}"; then
			ok "restore-env.sh complete"
		else
			warn "restore-env.sh exited non-zero - check output above"
		fi
	fi
fi

# -- init-nas.sh ---------------------------------------------------------------
INIT_SCRIPT="${CE_STACKS_DIR}/scripts/init-nas.sh"
info "Creating STACK_ROOT directories (scripts/init-nas.sh)"

if [ -f "${INIT_SCRIPT}" ]; then
	if bash "${INIT_SCRIPT}"; then
		ok "init-nas.sh complete"
	else
		warn "init-nas.sh exited non-zero - check output above"
	fi
else
	warn "${INIT_SCRIPT} not found - run manually after this script"
fi

# -- fix-permissions.sh --------------------------------------------------------
# Normalises ownership of stack data dirs. Must be called with bash (uses BASH_SOURCE).
FIX_PERMS_SCRIPT="${CE_STACKS_DIR}/scripts/fix-permissions.sh"
info "Normalising stack data dir permissions (scripts/fix-permissions.sh)"

if [ -f "${FIX_PERMS_SCRIPT}" ]; then
	if bash "${FIX_PERMS_SCRIPT}"; then
		ok "fix-permissions.sh complete"
	else
		warn "fix-permissions.sh exited non-zero - check output above"
	fi
else
	warn "${FIX_PERMS_SCRIPT} not found - skipping"
fi

# -- Repo-level ownership ------------------------------------------------------
# fix-permissions.sh handles stacks/data dirs only.
# This covers the repo root so the operator can run git pull without sudo.
info "Fixing repo ownership: ${OWNER}:${GROUP}"
chown -R "${OWNER}:${GROUP}" "${CE_STACKS_DIR}" ||
	warn "chown failed - run: sudo chown -R ${OWNER}:${GROUP} ${CE_STACKS_DIR}"
chmod -R u+rwX "${CE_STACKS_DIR}"
ok "Repo ownership set to ${OWNER}:${GROUP}"

# -- Summary -------------------------------------------------------------------
echo ""
echo "============================================"
echo " nas-reset.sh complete"
echo "============================================"
echo " Backup:  ${BACKUP_DIR}"
echo " Repo:    ${CE_STACKS_DIR}"
echo ""
echo " Next steps:"
echo "   1. sudo cp /volume2/docker/ce-stacks/dockhand/scripts/dockhand-start.sh \\"
echo "         /usr/local/etc/rc.d/dockhand.sh"
echo "   2. sudo chmod +x /usr/local/etc/rc.d/dockhand.sh"
echo "   3. sudo sh /usr/local/etc/rc.d/dockhand.sh"
echo "   4. Open Dockhand: http://10.0.1.15:3866"
echo "   5. Deploy stacks in order per README.md"
echo "============================================"
