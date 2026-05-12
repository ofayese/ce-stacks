#!/usr/bin/env bash
# Emit resolved `docker compose config` for every Compose file under stacks/
# (same discovery as compose-validate.sh). Run on the NAS from the repo clone
# so each stack's local .env is picked up automatically when present.
#
# WARNING: output often contains substituted secrets. Default output is under
# /tmp with mode 0700. Do not commit dumps to git.
#
# Usage:
#   bash scripts/dump-compose-effective.sh
#   bash scripts/dump-compose-effective.sh -o /path/to/outdir
#   bash scripts/dump-compose-effective.sh --concat /path/to/all-effective.yaml
#   bash scripts/dump-compose-effective.sh --use-compose-ci-env   # Mac/CI-style dummy .env (see compose-validate.sh)
#   bash scripts/dump-compose-effective.sh --json -o /path/to/outdir
#   bash scripts/dump-compose-effective.sh --strict   # exit 1 if any stack fails
#
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${_script_dir}"
while [[ ! -f "${ROOT}/HIVE_OBJECTIVE.md" && "${ROOT}" != "/" ]]; do
	ROOT="$(dirname "${ROOT}")"
done
[[ -f "${ROOT}/HIVE_OBJECTIVE.md" ]] || {
	echo "ERROR: could not find repo root (HIVE_OBJECTIVE.md) above ${_script_dir}" >&2
	exit 1
}

STACKS="${ROOT}/stacks"
OUT=""
CONCAT=""
FORMAT=""
USE_CI_ENV=0
STRICT=0

usage() {
	cat <<'USAGE'
Emit resolved `docker compose config` for every stacks/** compose file (same
discovery as compose-validate.sh). On the NAS, run without --use-compose-ci-env
so each stack directory's .env is used automatically.

Usage: bash scripts/dump-compose-effective.sh [options]

Options:
  -o DIR                 Output root (default: mktemp under /tmp, mode 0700)
  --concat FILE          Also write one concatenated file (# --- path --- headers)
  --json                 docker compose config --format json (per-file; concat is not one JSON doc)
  --use-compose-ci-env   Add --env-file .github/compose-ci.env (local/CI parity; not for NAS dumps)
  --strict               Exit 1 if any stack fails
  -h, --help             This help

WARNING: output may contain secrets. Do not commit dumps.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	-o)
		OUT="${2:?}"
		shift 2
		;;
	--concat)
		CONCAT="${2:?}"
		shift 2
		;;
	--json)
		FORMAT="json"
		shift
		;;
	--use-compose-ci-env)
		USE_CI_ENV=1
		shift
		;;
	--strict)
		STRICT=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "ERROR: unknown option: $1" >&2
		usage >&2
		exit 1
		;;
	esac
done

if [[ -z "${OUT}" ]]; then
	OUT="$(mktemp -d "${TMPDIR:-/tmp}/dockge-compose-effective.XXXXXX")"
	chmod 700 "${OUT}" 2>/dev/null || true
fi
mkdir -p "${OUT}"

ERR_LOG="${OUT}/_dump_errors.log"
MANIFEST="${OUT}/_manifest.txt"
: >"${ERR_LOG}"
{
	echo "dump-compose-effective.sh"
	echo "root=${ROOT}"
	echo "out=${OUT}"
	echo "format=${FORMAT:-yaml}"
	echo "use_compose_ci_env=${USE_CI_ENV}"
	date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date
	echo "---"
} >"${MANIFEST}"

COMPOSE_EXTRA_ARGS=()
if [[ "${USE_CI_ENV}" -eq 1 ]]; then
	COMPOSE_ENV_FILE="${ROOT}/.github/compose-ci.env"
	[[ -f "${COMPOSE_ENV_FILE}" ]] || {
		echo "ERROR: ${COMPOSE_ENV_FILE} not found" >&2
		exit 1
	}
	export STACK_ROOT="${STACK_ROOT:-${STACKS}}"
	COMPOSE_EXTRA_ARGS+=(--env-file "${COMPOSE_ENV_FILE}")
fi

if [[ -n "${CONCAT}" ]]; then
	mkdir -p "$(dirname "${CONCAT}")"
	: >"${CONCAT}"
	chmod 600 "${CONCAT}" 2>/dev/null || true
fi

any_fail=0

while IFS= read -r f; do
	[[ -n "${f}" ]] || continue
	rel="${f#"${ROOT}"/}"
	dir="$(dirname "${f}")"
	base="$(basename "${f}")"
	# Output path mirrors repo: OUT/stacks/foo/effective.compose.yaml
	safe_sub="${rel%/*}"
	out_dir="${OUT}/${safe_sub}"
	out_file="${out_dir}/effective.${base}"
	mkdir -p "${out_dir}"

	echo "config: ${rel}" >&2
	echo "config: ${rel}" >>"${MANIFEST}"
	status=0
	if [[ "${FORMAT}" == "json" ]]; then
		if ! (
			cd "${dir}" || exit 1
			docker compose "${COMPOSE_EXTRA_ARGS[@]}" -f "${base}" config --format json >"${out_file}.tmp"
		); then
			status=1
		fi
	else
		if ! (
			cd "${dir}" || exit 1
			docker compose "${COMPOSE_EXTRA_ARGS[@]}" -f "${base}" config >"${out_file}.tmp"
		); then
			status=1
		fi
	fi

	if [[ "${status}" -ne 0 ]]; then
		any_fail=1
		rm -f "${out_file}.tmp"
		echo "FAIL ${rel}" >>"${ERR_LOG}"
		echo "FAIL ${rel}" >>"${MANIFEST}"
		[[ "${STRICT}" -eq 1 ]] || true
		continue
	fi
	mv "${out_file}.tmp" "${out_file}"
	chmod 600 "${out_file}" 2>/dev/null || true
	echo "OK   ${rel} -> ${out_file#"${OUT}"/}" >>"${MANIFEST}"

	if [[ -n "${CONCAT}" ]]; then
		{
			echo "# --- ${rel} ---"
			cat "${out_file}"
			echo ""
		} >>"${CONCAT}"
	fi
done < <(
	find "${STACKS}" -maxdepth 4 \
		\( -type d \( -name db -o -name data \) \) -prune -o \
		\( -type d -path '*/github-desktop/config' \) -prune -o \
		\( \( -name compose.yaml -o -name docker-compose.yml -o -name docker-compose.yaml \) \
		! -name docker-mcp.yaml ! -path '*/.git/*' \) -print | sort
)

echo ""
echo "Wrote resolved configs under: ${OUT}"
echo "Manifest: ${MANIFEST}"
if [[ -s "${ERR_LOG}" ]]; then
	echo "Failures logged: ${ERR_LOG}"
fi
if [[ -n "${CONCAT}" ]]; then
	echo "Concatenated: ${CONCAT}"
fi
if [[ "${any_fail}" -ne 0 && "${STRICT}" -eq 1 ]]; then
	exit 1
fi
if [[ "${any_fail}" -ne 0 ]]; then
	echo "WARNING: one or more compose files failed (see ${ERR_LOG}). Re-run with --strict to exit non-zero." >&2
fi
