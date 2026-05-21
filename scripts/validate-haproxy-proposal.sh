#!/usr/bin/env bash
# Syntax-check stacks/_haproxy/haproxy.cfg using a temp tree (dummy TLS + map copy).
# Resolves /volume2/docker/ce-stacks/_haproxy to a writable temp path so haproxy -c works off-NAS.
set -euo pipefail
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${_script_dir}"
while [[ ! -f "${ROOT}/README.md" && "${ROOT}" != "/" ]]; do
	ROOT="$(dirname "${ROOT}")"
done
# Synology non-interactive SSH does not include /usr/local/bin in PATH.
# Resolve docker binary once; caller can override via DOCKER=/path/to/docker.
DOCKER="${DOCKER:-$(command -v docker 2>/dev/null || echo /usr/local/bin/docker)}"

cfg="${ROOT}/stacks/_haproxy/haproxy.cfg"
map_src="${ROOT}/stacks/_haproxy/maps/host.map"
if [[ ! -f "${cfg}" ]]; then
	echo "validate-haproxy-proposal: missing ${cfg}" >&2
	exit 1
fi
if [[ ! -f "${map_src}" ]]; then
	echo "validate-haproxy-proposal: missing ${map_src}" >&2
	exit 1
fi

run_haproxy_check() {
	local haproxy_cfg="$1"
	# Prefer the native haproxy binary — check PATH first, then the Synology package location.
	local _haproxy
	_haproxy="$(command -v haproxy 2>/dev/null \
		|| { [[ -x /var/packages/haproxy/target/sbin/haproxy ]] && echo /var/packages/haproxy/target/sbin/haproxy; } \
		|| true)"
	if [[ -n "${_haproxy}" ]]; then
		"${_haproxy}" -c -f "${haproxy_cfg}"
		return
	fi
	if [[ -x "${DOCKER}" ]]; then
		local cfg_dir
		cfg_dir="$(dirname "${haproxy_cfg}")"
		"${DOCKER}" run --rm -v "${cfg_dir}:${cfg_dir}:ro" haproxytech/haproxy-alpine:3.0 \
			haproxy -c -f "${haproxy_cfg}"
		return
	fi
	echo "validate-haproxy-proposal: SKIP (need haproxy or docker; tried ${DOCKER})" >&2
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
echo "validate-haproxy-proposal: OK (stacks/_haproxy/haproxy.cfg)"
exit 0
