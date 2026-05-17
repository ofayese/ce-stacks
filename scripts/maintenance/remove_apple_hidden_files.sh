#!/usr/bin/env bash
# Remove Apple SMB / Finder metadata files under operator-chosen paths.
# Safe-by-default: DRY_RUN=1 (no deletes). Use Task Scheduler only after dry-run review.
#
# Always removes DSM Search indexer junk under each scan root -- directories named @eaDir and files
# *@SynoEAStream / *@SynoResource -- including under Docker stack bind mounts (most stacks have no .git).
# Under .git/refs the same junk breaks git (e.g. fatal: bad object refs/.../@eaDir/...). Disable DSM
# indexing on /volume2/docker for a permanent fix.
#
# Concepts adapted (not verbatim) from hwdbk/synology-scripts:
#   - ea-file-bundle-handling: stray @SynoEAStream/@SynoResource files whose primary path no longer exists
#     are removable clutter (cleanup_SynoFiles-style parent check only -- no xattr/binary tooling).
#   - mac-nfd-conversion: Mac vs Synology UTF-8 normalization can make sibling paths disagree if Samba
#     "Mac compatibility" / NFD handling is off -- pair-based ._ cleanup may skip stubs until names align.
#
# Usage:
#   Single tree (repo NAS root -- one find covers stacks/*, .git/refs, and all bind data):
#     DRY_RUN=1 APPLE_CLEANUP_ROOT=/volume2/docker/ce-stacks bash scripts/maintenance/remove_apple_hidden_files.sh
#   Every stack folder only (.../stacks/<name>/ each as root -- does NOT walk the repo .git or files
#   directly under the repo root outside stacks/; use APPLE_CLEANUP_ROOT for that):
#     DRY_RUN=1 APPLE_CLEANUP_STACKS_ROOT=/volume2/docker/ce-stacks/stacks bash scripts/maintenance/remove_apple_hidden_files.sh
#   Both (e.g. git corruption at repo root plus per-stack pass; repo root walk also covers stacks, stacks pass is redundant):
#     DRY_RUN=1 APPLE_CLEANUP_ROOT=/volume2/docker/ce-stacks APPLE_CLEANUP_STACKS_ROOT=/volume2/docker/ce-stacks/stacks bash scripts/maintenance/remove_apple_hidden_files.sh
#   Explicit path list:
#     DRY_RUN=0 APPLE_CLEANUP_PATHS_FILE=/path/to/paths.list bash scripts/maintenance/remove_apple_hidden_files.sh
#
# paths.list: one absolute directory path per line; # comments and blank lines ignored.
set -euo pipefail

DRY_RUN="${DRY_RUN:-1}"
APPLE_CLEANUP_ROOT="${APPLE_CLEANUP_ROOT:-}"
APPLE_CLEANUP_PATHS_FILE="${APPLE_CLEANUP_PATHS_FILE:-}"
# If set, each immediate subdirectory of this path is used as a scan root (stacks/ layout).
APPLE_CLEANUP_STACKS_ROOT="${APPLE_CLEANUP_STACKS_ROOT:-}"
# Max size (bytes) for ._* resource-fork stubs; larger files are never candidates.
MAX_DOT_UNDERSCORE_BYTES="${MAX_DOT_UNDERSCORE_BYTES:-65536}"
# 1 = also delete tiny orphan ._ files when no sibling exists (stray stub). Default 0 = paired stubs only.
APPLE_CLEANUP_ORPHAN_DOT_UNDERSCORE="${APPLE_CLEANUP_ORPHAN_DOT_UNDERSCORE:-0}"
# 1 = remove stray *@SynoEAStream / *@SynoResource under @eaDir when parent file/dir is missing (no bogus-xattr pass).
APPLE_CLEANUP_STRAY_SYNO_SIDECARS="${APPLE_CLEANUP_STRAY_SYNO_SIDECARS:-0}"

usage() {
	cat <<'USAGE'
remove_apple_hidden_files.sh -- prune .DS_Store, paired/small ._* stubs, .AppleDouble dirs; optional stray Syno sidecars

  DRY_RUN=1|0           default 1 -- print actions only
  APPLE_CLEANUP_ROOT   single directory root (optional if PATHS_FILE or STACKS_ROOT set)
  APPLE_CLEANUP_STACKS_ROOT  parent of stack dirs -- each .../stacks/<child>/ is scanned only (not the repo .git root)
  APPLE_CLEANUP_PATHS_FILE  file with one absolute path per line
  MAX_DOT_UNDERSCORE_BYTES  default 65536 (find -size -Nc)
  APPLE_CLEANUP_ORPHAN_DOT_UNDERSCORE  default 0 -- set 1 to delete tiny orphan ._ when sibling missing
  APPLE_CLEANUP_STRAY_SYNO_SIDECARS    default 0 -- set 1 to delete stray @SynoEAStream/@SynoResource (parent missing)

Prunes descent into: .git, node_modules, @eaDir for .DS_Store / ._ / .AppleDouble passes (those passes do not delete @eaDir).
Always removes every @eaDir directory tree and *@SynoEAStream / *@SynoResource files anywhere under each root (stacks, repo, .git/refs).
Stray Syno pass (opt-in) walks trees (prune .git/node_modules) for sidecar files whose primary path does not exist.

No compiled helpers required -- pure bash + find (no find -delete).
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && {
	usage
	exit 0
}

trim_ws() {
	local s="$1"
	s="${s%%$'\r'}"
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "${s}"
}

collect_roots() {
	local roots=()
	if [[ -n "${APPLE_CLEANUP_PATHS_FILE}" ]]; then
		if [[ ! -f "${APPLE_CLEANUP_PATHS_FILE}" ]]; then
			echo "ERROR: APPLE_CLEANUP_PATHS_FILE is not a file: ${APPLE_CLEANUP_PATHS_FILE}" >&2
			exit 2
		fi
		while IFS= read -r line || [[ -n "${line}" ]]; do
			line="$(trim_ws "${line}")"
			[[ -z "${line}" || "${line:0:1}" == '#' ]] && continue
			roots+=("${line}")
		done <"${APPLE_CLEANUP_PATHS_FILE}"
	fi
	if [[ -n "${APPLE_CLEANUP_ROOT}" ]]; then
		roots+=("${APPLE_CLEANUP_ROOT}")
	fi
	if [[ -n "${APPLE_CLEANUP_STACKS_ROOT}" ]]; then
		if [[ ! -d "${APPLE_CLEANUP_STACKS_ROOT}" ]]; then
			echo "ERROR: APPLE_CLEANUP_STACKS_ROOT is not a directory: ${APPLE_CLEANUP_STACKS_ROOT}" >&2
			exit 2
		fi
		local child
		for child in "${APPLE_CLEANUP_STACKS_ROOT}"/*; do
			[[ -e "${child}" ]] || continue
			[[ -d "${child}" ]] || continue
			roots+=("${child}")
		done
	fi
	if [[ "${#roots[@]}" -eq 0 ]]; then
		echo "ERROR: Set APPLE_CLEANUP_ROOT, APPLE_CLEANUP_STACKS_ROOT, and/or APPLE_CLEANUP_PATHS_FILE" >&2
		exit 2
	fi
	printf '%s\n' "${roots[@]}"
}

delete_file() {
	local f="$1"
	if [[ "${DRY_RUN}" == "1" ]]; then
		printf 'DRY_RUN rm -f -- %q\n' "${f}"
		return 0
	fi
	rm -f -- "${f}"
}

delete_dir() {
	local d="$1"
	if [[ "${DRY_RUN}" == "1" ]]; then
		printf 'DRY_RUN rm -rf -- %q\n' "${d}"
		return 0
	fi
	rm -rf -- "${d}"
}

# Primary path for .../@eaDir/<name>@SynoEAStream or .../@eaDir/<name>@SynoResource -> .../<name>
syno_sidecar_to_primary() {
	local f="$1"
	local p="${f/@eaDir\/}"
	case "${f}" in
		*@SynoEAStream) p="${p%@SynoEAStream}" ;;
		*@SynoResource) p="${p%@SynoResource}" ;;
		*) printf ''; return 1 ;;
	esac
	printf '%s' "${p}"
}

process_root() {
	local root="$1"
	if [[ ! -d "${root}" ]]; then
		echo "WARN: skip (not a directory): ${root}" >&2
		return 0
	fi
	echo "==> ${root} (DRY_RUN=${DRY_RUN})"

	while IFS= read -r -d '' f; do
		delete_file "${f}"
	done < <(
		find "${root}" \( -name .git -o -name node_modules -o -name '@eaDir' \) -prune -o \
			-name '.DS_Store' -type f -print0 2>/dev/null
	)

	# AppleDouble ._ stubs: never delete every small ._ via a single unscoped rm/find -delete.
	# Prefer paired stubs (sibling data fork exists); optional orphan removal when APPLE_CLEANUP_ORPHAN_DOT_UNDERSCORE=1.
	local size_arg="-${MAX_DOT_UNDERSCORE_BYTES}c"
	while IFS= read -r -d '' f; do
		local dir base sibling_suffix sibling
		dir="$(dirname -- "${f}")"
		base="$(basename -- "${f}")"
		[[ "${base}" == '._' ]] && continue
		[[ "${base}" != ._?* ]] && continue
		sibling_suffix="${base#._}"
		[[ -z "${sibling_suffix}" ]] && continue
		sibling="${dir}/${sibling_suffix}"
		local remove=false
		if [[ -e "${sibling}" ]]; then
			remove=true
		elif [[ "${APPLE_CLEANUP_ORPHAN_DOT_UNDERSCORE}" == "1" ]]; then
			remove=true
		fi
		if [[ "${remove}" == "true" ]]; then
			delete_file "${f}"
		fi
	done < <(
		find "${root}" \( -name .git -o -name node_modules -o -name '@eaDir' \) -prune -o \
			-name '._*' -type f -size "${size_arg}" -print0 2>/dev/null
	)

	while IFS= read -r -d '' d; do
		delete_dir "${d}"
	done < <(
		find "${root}" \( -name .git -o -name node_modules -o -name '@eaDir' \) -prune -o \
			-depth -type d -name '.AppleDouble' -print0 2>/dev/null
	)

	# Synology DSM Search: @eaDir trees and *@Syno* sidecars anywhere under root (stack data, .git/refs, etc.).
	local syno_dirs=0 syno_files=0
	while IFS= read -r -d '' d; do
		delete_dir "${d}"
		syno_dirs=$((syno_dirs + 1))
	done < <(
		find "${root}" -depth -type d -name '@eaDir' -print0 2>/dev/null
	)
	while IFS= read -r -d '' f; do
		delete_file "${f}"
		syno_files=$((syno_files + 1))
	done < <(
		find "${root}" -type f \( -name '*@SynoEAStream' -o -name '*@SynoResource' \) -print0 2>/dev/null
	)
	echo "    Synology indexer junk under ${root}: ${syno_dirs} @eaDir dir(s), ${syno_files} sidecar file(s)"

	if [[ "${APPLE_CLEANUP_STRAY_SYNO_SIDECARS}" == "1" ]]; then
		while IFS= read -r -d '' f; do
			local prim
			prim="$(syno_sidecar_to_primary "${f}")" || continue
			if [[ ! -e "${prim}" ]]; then
				delete_file "${f}"
			fi
		done < <(
			find "${root}" \( -name .git -o -name node_modules \) -prune -o \
				-type f \( -name '*@SynoEAStream' -o -name '*@SynoResource' \) -print0 2>/dev/null
		)
	fi
}

_roots=()
while IFS= read -r line; do
	[[ -z "${line}" ]] && continue
	_roots+=("${line}")
done < <(collect_roots | sort -u)
for r in "${_roots[@]}"; do
	process_root "${r}"
done

echo "Done."
