#!/bin/bash
# =============================================================================
# cursor-remote-update.sh
# =============================================================================
# Downloads the Cursor remote server locally, then uploads and installs it on
# the OTS NAS (or any host defined in ~/.ssh/config).
#
# Run this script from your Mac (NOT on the NAS) — it requires the local
# Cursor CLI to detect the current version and commit hash.
#
# Usage:
#   bash scripts/cursor-remote-update.sh           # interactive confirmation
#   bash scripts/cursor-remote-update.sh --yes     # non-interactive (CI)
#
# Prerequisites:
#   - Cursor app installed locally (cursor CLI in PATH)
#   - ~/.ssh/config has a Host alias matching REMOTE_SSH_HOST
#   - curl, ssh, scp available on your Mac
#
# ~/.ssh/config entry used (example):
#   Host otsorundscore
#     HostName 10.0.1.15
#     Port 28
#     User laolufayese
#     IdentityFile ~/.ssh/id_ed25519
#     IdentitiesOnly yes
#
# After deployment, Cursor can connect remotely to the NAS without needing
# internet access on the NAS side for server installation.
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LOCAL_DOWNLOAD_DIR="${SCRIPT_DIR}/cursor_downloads"

# SSH host alias from ~/.ssh/config (Port, User, IdentityFile all resolved automatically)
REMOTE_SSH_HOST="otsorundscore"

# Remote OS — Cursor only supports linux for remote server
REMOTE_OS="linux"

# Remote architecture: "auto" (detect via uname -m) | "x64" | "arm64"
# OTS NAS confirmed x86_64 (x64) — auto is safe
REMOTE_ARCH="auto"

# Non-interactive mode flag
YES=0
for arg in "$@"; do
	case "$arg" in
	--yes | -y) YES=1 ;;
	--help)
		sed -n '3,20p' "$0" | sed 's/^# //'
		exit 0
		;;
	esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
print_message() {
	local color=$1 message=$2
	case "$color" in
	green) echo -e "\033[0;32m${message}\033[0m" ;;
	red) echo -e "\033[0;31m${message}\033[0m" ;;
	yellow) echo -e "\033[0;33m${message}\033[0m" ;;
	blue) echo -e "\033[0;34m${message}\033[0m" ;;
	*) echo "$message" ;;
	esac
}

check_command() {
	if ! command -v "$1" &>/dev/null; then
		print_message red "Error: '$1' not found — install it first."
		exit 1
	fi
}

# ── Step 1: Get Cursor version ─────────────────────────────────────────────────
get_cursor_version() {
	if ! command -v cursor &>/dev/null; then
		print_message red "Error: 'cursor' command not found. Is Cursor installed and in PATH?"
		print_message yellow "Try: open -a Cursor  (then add cursor to PATH from Cursor → Install 'cursor' CLI)"
		exit 1
	fi

	print_message blue "Detecting local Cursor version..."
	local version_info
	version_info="$(cursor --version)"

	CURSOR_VERSION="$(echo "$version_info" | sed -n '1p')"
	CURSOR_COMMIT="$(echo "$version_info" | sed -n '2p')"
	CURSOR_ARCH="$(echo "$version_info" | sed -n '3p')"

	print_message green "  Version:  $CURSOR_VERSION"
	print_message green "  Commit:   $CURSOR_COMMIT"
	print_message green "  Local arch: $CURSOR_ARCH"
}

# ── Step 2: Detect remote architecture ────────────────────────────────────────
detect_remote_arch() {
	if [[ "$REMOTE_ARCH" != "auto" ]]; then
		print_message blue "Remote arch forced: $REMOTE_ARCH"
		return 0
	fi

	print_message blue "Detecting remote architecture on ${REMOTE_SSH_HOST}..."
	local remote_uname
	remote_uname="$(ssh "$REMOTE_SSH_HOST" "uname -m" | tr -d '\r\n')"

	case "$remote_uname" in
	x86_64 | amd64) REMOTE_ARCH="x64" ;;
	aarch64 | arm64) REMOTE_ARCH="arm64" ;;
	*)
		print_message red "Unsupported remote architecture: $remote_uname"
		exit 1
		;;
	esac

	print_message green "  Remote arch: $remote_uname → $REMOTE_ARCH"
}

# ── Step 3: Download server archive ───────────────────────────────────────────
download_cursor_server() {
	print_message blue "Downloading Cursor remote server..."
	mkdir -p "$LOCAL_DOWNLOAD_DIR"

	DOWNLOAD_URL="https://cursor.blob.core.windows.net/remote-releases/${CURSOR_VERSION}-${CURSOR_COMMIT}/vscode-reh-${REMOTE_OS}-${REMOTE_ARCH}.tar.gz"
	DOWNLOAD_FILENAME="cursor-server-${CURSOR_VERSION}-${CURSOR_COMMIT}-${REMOTE_OS}-${REMOTE_ARCH}.tar.gz"
	DOWNLOAD_PATH="${LOCAL_DOWNLOAD_DIR}/${DOWNLOAD_FILENAME}"

	# Skip download if already present (same version+commit)
	if [[ -f "$DOWNLOAD_PATH" ]]; then
		print_message yellow "  Already downloaded: $DOWNLOAD_FILENAME (skipping)"
		return 0
	fi

	print_message yellow "  URL: $DOWNLOAD_URL"
	print_message yellow "  Saving to: $DOWNLOAD_PATH"

	if curl -fL "$DOWNLOAD_URL" -o "$DOWNLOAD_PATH"; then
		print_message green "  Download complete."
	else
		print_message red "  Download failed — check version/arch combination."
		exit 1
	fi
}

# ── Step 4: Upload and install on remote ──────────────────────────────────────
deploy_to_remote() {
	print_message blue "Deploying to ${REMOTE_SSH_HOST}..."

	# Quick connectivity test
	if ssh "$REMOTE_SSH_HOST" "echo 'SSH OK'" >/dev/null; then
		print_message green "  SSH connection OK"
	else
		print_message red "  SSH connection failed"
		exit 1
	fi

	local remote_install_dir=".cursor-server/cli/servers/Stable-${CURSOR_COMMIT}/server"
	local remote_install_path="\$HOME/${remote_install_dir}"

	print_message yellow "  Creating remote directory: ~/${remote_install_dir}"
	# shellcheck disable=SC2029 # CURSOR_COMMIT is expanded locally; $HOME expands on the remote.
	ssh "$REMOTE_SSH_HOST" "mkdir -p ${remote_install_path}"

	# Check if already installed on remote
	# shellcheck disable=SC2029 # CURSOR_COMMIT is expanded locally; $HOME expands on the remote.
	if ssh "$REMOTE_SSH_HOST" "test -d ${remote_install_path}/bin" 2>/dev/null; then
		print_message yellow "  Already installed at ~/${remote_install_dir}/bin — skipping upload."
		print_message green "  Deployment already complete for commit ${CURSOR_COMMIT}."
		return 0
	fi

	print_message yellow "  Uploading archive..."
	scp "$DOWNLOAD_PATH" "${REMOTE_SSH_HOST}:~/.cursor-server/cursor-server.tar.gz"

	print_message yellow "  Extracting on remote..."
	# shellcheck disable=SC2029 # CURSOR_COMMIT is expanded locally; $HOME expands on the remote.
	ssh "$REMOTE_SSH_HOST" \
		"tar -xzf ~/.cursor-server/cursor-server.tar.gz \
         -C ${remote_install_path} \
         --strip-components=1"

	print_message yellow "  Cleaning up remote archive..."
	ssh "$REMOTE_SSH_HOST" "rm -f ~/.cursor-server/cursor-server.tar.gz"

	print_message green "  Deployment complete."
	print_message green "  Remote path: ~/.cursor-server/cli/servers/Stable-${CURSOR_COMMIT}/server/"
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Guard: must run on Mac, not on NAS
if [[ "$(uname)" != "Darwin" ]]; then
	print_message red "This script must run on your Mac, not on the NAS."
	print_message yellow "It requires the local Cursor CLI and uploads over SSH to ${REMOTE_SSH_HOST}."
	exit 1
fi

check_command curl
check_command ssh
check_command scp

get_cursor_version
detect_remote_arch
download_cursor_server

echo ""
print_message blue "Ready to deploy:"
print_message blue "  Host:    ${REMOTE_SSH_HOST}"
print_message blue "  Version: ${CURSOR_VERSION} (${CURSOR_COMMIT})"
print_message blue "  Arch:    ${REMOTE_ARCH}"
echo ""

if [[ "$YES" -eq 0 ]]; then
	printf "Continue? [y/N] "
	read -r confirmation
	case "$confirmation" in
	y | Y | yes | YES) ;;
	*)
		print_message yellow "Canceled. Archive at: ${DOWNLOAD_PATH}"
		exit 0
		;;
	esac
fi

deploy_to_remote

echo ""
print_message green "Done! Open Cursor → File → Connect to Remote → Select 'otsorundscore'."
