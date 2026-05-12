#!/usr/bin/env bash
# Fail-closed TLS check (OpenSSL SNI). Optional Discord alert on failure.
# Validates certificate expiry window via openssl x509 -checkend.
set -euo pipefail

CONNECT_HOST="${CONNECT_HOST:?Set CONNECT_HOST (IP or hostname)}"
CONNECT_PORT="${CONNECT_PORT:-6443}"
SNI="${SNI:-}"
EXPECTED_SUBJECT="${EXPECTED_SUBJECT:-}"
MIN_VALID_DAYS="${MIN_VALID_DAYS:-21}"

usage() {
	cat <<'USAGE'
verify_serving.sh — OpenSSL client TLS probe

Required env:
  CONNECT_HOST   e.g. 10.0.1.15

Optional env:
  CONNECT_PORT   default 6443 (Traefik HTTPS edge — use 443 if HAProxy terminates TLS)
  SNI            -servername value (default: CONNECT_HOST if set, else none)
  EXPECTED_SUBJECT  substring required in openssl x509 -subject output
  MIN_VALID_DAYS   default 21 — openssl x509 -checkend threshold (fail if not valid that long)
  DISCORD_WEBHOOK_URL  POST JSON alert on failure (same name as acme-sh)
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && {
	usage
	exit 0
}

notify_discord() {
	local msg="$1"
	[[ -z "${DISCORD_WEBHOOK_URL:-}" ]] && return 0
	local payload
	payload="$(python3 -c 'import json, sys; print(json.dumps({"content": "verify_serving: " + sys.argv[1]}))' "${msg}")" || return 0
	curl -fsS -X POST "${DISCORD_WEBHOOK_URL}" -H 'Content-Type: application/json' -d "${payload}" || true
}

servername="${SNI}"
if [[ -z "${servername}" ]]; then
	servername="${CONNECT_HOST}"
fi

out="$(mktemp)"
pemtmp="$(mktemp)"
cleanup() {
	rm -f "${out}" "${pemtmp}"
}
trap cleanup EXIT

set +e
if [[ -n "${servername}" ]]; then
	echo | openssl s_client -servername "${servername}" -connect "${CONNECT_HOST}:${CONNECT_PORT}" 2>"${out}" | openssl x509 >"${pemtmp}" 2>/dev/null
else
	echo | openssl s_client -connect "${CONNECT_HOST}:${CONNECT_PORT}" 2>"${out}" | openssl x509 >"${pemtmp}" 2>/dev/null
fi
set -e

if [[ ! -s "${pemtmp}" ]]; then
	cat "${out}" >&2 || true
	notify_discord "openssl s_client failed ${CONNECT_HOST}:${CONNECT_PORT} sni=${servername}"
	exit 1
fi

subj="$(openssl x509 -in "${pemtmp}" -noout -subject 2>/dev/null || true)"
if [[ -z "${subj}" ]]; then
	notify_discord "could not parse cert subject ${CONNECT_HOST}:${CONNECT_PORT}"
	exit 1
fi

if [[ -n "${EXPECTED_SUBJECT}" && "${subj}" != *"${EXPECTED_SUBJECT}"* ]]; then
	echo "subject mismatch: want substring ${EXPECTED_SUBJECT} got: ${subj}" >&2
	notify_discord "TLS subject mismatch ${CONNECT_HOST}:${CONNECT_PORT}"
	exit 1
fi

checkend_secs=$((MIN_VALID_DAYS * 86400))
if ! openssl x509 -in "${pemtmp}" -checkend "${checkend_secs}" -noout 2>/dev/null; then
	echo "cert fails -checkend ${MIN_VALID_DAYS}d (expires too soon or already expired)" >&2
	dates="$(openssl x509 -in "${pemtmp}" -noout -dates 2>/dev/null || true)"
	echo "${dates}" >&2
	notify_discord "TLS cert expires within ${MIN_VALID_DAYS}d or checkend failed ${CONNECT_HOST}:${CONNECT_PORT}"
	exit 1
fi

echo "OK: ${CONNECT_HOST}:${CONNECT_PORT} sni=${servername}"
echo "${subj}"
openssl x509 -in "${pemtmp}" -noout -dates 2>/dev/null || true
