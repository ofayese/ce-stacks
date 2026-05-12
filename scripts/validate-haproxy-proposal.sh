#!/usr/bin/env bash
# Syntax-check stacks/_haproxy/haproxy.cfg using a temp tree (dummy TLS + map copy).
# Resolves /volume2/docker/ce-stacks/_haproxy to a writable temp path so haproxy -c works off-NAS.
set -euo pipefail
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${_script_dir}"
while [[ ! -f "${ROOT}/HIVE_OBJECTIVE.md" && "${ROOT}" != "/" ]]; do
	ROOT="$(dirname "${ROOT}")"
done
cfg="${ROOT}/stacks/_haproxy/haproxy.cfg"
map_src="${ROOT}/stacks/_haproxy/maps/host.map"
if [[ ! -f "${cfg}" ]]; then
	echo "validate-haproxy-proposal: missing ${cfg}" >&2
	exit 1
fi
wrapper="${ROOT}/docs/hive/proposals/_haproxy/haproxy.cfg"
if [[ ! -f "${wrapper}" ]]; then
	echo "validate-haproxy-proposal: missing ${wrapper}" >&2
	exit 1
fi
if [[ ! -f "${map_src}" ]]; then
	echo "validate-haproxy-proposal: missing ${map_src}" >&2
	exit 1
fi

run_haproxy_check() {
	local haproxy_cfg="$1"
	if command -v haproxy >/dev/null 2>&1; then
		haproxy -c -f "${haproxy_cfg}"
		return
	fi
	if command -v docker >/dev/null 2>&1; then
		local cfg_dir
		cfg_dir="$(dirname "${haproxy_cfg}")"
		docker run --rm -v "${cfg_dir}:${cfg_dir}:ro" haproxytech/haproxy-alpine:3.0 \
			haproxy -c -f "${haproxy_cfg}"
		return
	fi
	echo "validate-haproxy-proposal: SKIP (need haproxy or docker in PATH)" >&2
	return 0
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/certs" "${TMP}/maps"
cp "${map_src}" "${TMP}/maps/host.map"
if ! command -v openssl >/dev/null 2>&1; then
	echo "validate-haproxy-proposal: SKIP (openssl not in PATH; cannot create dummy PEM)" >&2
	exit 0
fi
openssl req -x509 -nodes -newkey rsa:2048 -keyout "${TMP}/k.pem" -out "${TMP}/c.pem" -days 1 \
	-subj "/CN=haproxy-syntax-check" >/dev/null 2>&1
cat "${TMP}/c.pem" "${TMP}/k.pem" >"${TMP}/certs/_syntax-check.pem"
# DSM-merge globals use user sc-haproxy + ring httplog paths that do not exist off-NAS; strip for syntax-only -c.
sed "s|/volume2/docker/ce-stacks/_haproxy|${TMP}|g" "${cfg}" |
	sed -e '/^[[:space:]]*user sc-haproxy[[:space:]]*$/d' -e '/^[[:space:]]*daemon[[:space:]]*$/d' \
		-e 's|^[[:space:]]*log ring@httplog local0 info|    log stdout format raw local0|' |
	perl -0777 -pe 's/\nring httplog\n(?:[ \t].*\n)+/\n/gs' >"${TMP}/haproxy.cfg"

echo "validate-haproxy-proposal: haproxy -c -f ${TMP}/haproxy.cfg (DSM globals sanitized off-NAS; paths rewritten to temp)"
if ! run_haproxy_check "${TMP}/haproxy.cfg"; then
	echo "validate-haproxy-proposal: FAIL (stacks/_haproxy/haproxy.cfg)" >&2
	exit 1
fi

# Proposal wrapper must resolve to this canonical file (OSS HAProxy docker builds omit `include` — cannot smoke-test include via -c).
_wrapper_dir="$(cd "$(dirname "${wrapper}")" && pwd)"
_include_line="$(grep -E '^[[:space:]]*include[[:space:]]+' "${wrapper}" | head -1 || true)"
if [[ -z "${_include_line}" ]]; then
	echo "validate-haproxy-proposal: FAIL (no include line in ${wrapper})" >&2
	exit 1
fi
_include_rel="$(echo "${_include_line}" | awk '{print $2}')"
_resolved=""
if cd "${_wrapper_dir}"; then
	_resolved="$(realpath "${_include_rel}" 2>/dev/null || true)"
fi
_canonical="$(realpath "${cfg}" 2>/dev/null || echo "${cfg}")"
if [[ "${_resolved}" != "${_canonical}" ]]; then
	echo "validate-haproxy-proposal: FAIL (proposal include resolves to '${_resolved}', expected '${_canonical}')" >&2
	exit 1
fi
echo "validate-haproxy-proposal: OK (canonical cfg + proposal include path)"
exit 0
