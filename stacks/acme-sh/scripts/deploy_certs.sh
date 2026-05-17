#!/usr/bin/env bash
# Stage HAProxy PEM bundles (fullchain + privkey) from acme.sh output under HAPROXY_CERT_STAGE_DIR (default
# /var/packages/haproxy/var/crt/ - Synology HAProxy package cert directory). Does not reload or restart HAProxy.
# Host-run (preferred). See stacks/acme-sh/scripts/deploy_certs.sh header for ADR rationale.
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: deploy_certs.sh [--no-haproxy-check]

Environment:
  STACK_ROOT              Required - stacks root (e.g. /volume2/docker/ce-stacks/stacks)
  ACME_CERT_ROOT          Default /volume2/certs/acme - acme.sh PEM trees per profile
  HAPROXY_CERT_STAGE_DIR  Default /var/packages/haproxy/var/crt/ - HAProxy bundle output (created if missing)
                            This is the Synology HAProxy package cert directory; bundles are deployed here directly.
  LIVE_HAPROXY_CERT_DIR   Default /var/packages/haproxy/var/crt/ - if HAPROXY_CERT_STAGE_DIR equals this,
                            haproxy -c may run (see DO_HAPROXY_CHECK); otherwise -c is skipped (wrong paths in cfg)
  BUNDLE_SPECS            Optional "profile:out.pem" space-separated list. Default:
                            wildcard:olutechsys.com.pem otsorundscore:otsorundscore.olutechsys.com.pem misfitsds:misfitsds.olutechsys.com.pem
  ACME_PROFILE            Optional - when set and BUNDLE_SPECS is empty, builds one bundle:
                            wildcard      -> olutechsys.com.pem
                            otsorundscore -> otsorundscore.olutechsys.com.pem
                            misfitsds     -> misfitsds.olutechsys.com.pem
  HAPROXY_BIN             Default /volume1/@appstore/haproxy/sbin/haproxy (Synology package); must exist for -c
  HAPROXY_USER            Default sc-haproxy - owner applied to deployed PEM bundles
  HAPROXY_GROUP           Default synocommunity - group applied to deployed PEM bundles
  HAPROXY_CFG             Config for haproxy -c; default ${STACK_ROOT}/_haproxy/haproxy.cfg
  DISCORD_WEBHOOK_URL     Optional - notify on hard failures (same var name as acme-sh compose)

Flags:
  --no-haproxy-check Skip haproxy -c (still runs openssl checks on staged bundles)
USAGE
}

notify_discord() {
	local msg="$1"
	[[ -z "${DISCORD_WEBHOOK_URL:-}" ]] && return 0
	local payload
	payload="$(
		MESSAGE="${msg}" python3 -c 'import json, os; print(json.dumps({"content": "acme deploy_certs: " + os.environ["MESSAGE"]}))'
	)" || return 0
	curl -fsS -X POST "${DISCORD_WEBHOOK_URL}" -H 'Content-Type: application/json' -d "${payload}" || true
}

STACK_ROOT="${STACK_ROOT:?Set STACK_ROOT to your stacks directory (e.g. /volume2/docker/ce-stacks/stacks)}"
ACME_CERT_ROOT="${ACME_CERT_ROOT:-/volume2/certs/acme}"
DO_HAPROXY_CHECK=1
while [[ "${1:-}" == -* ]]; do
	case "$1" in
		--no-haproxy-check) DO_HAPROXY_CHECK=0 ;;
		-h | --help) usage; exit 0 ;;
		*) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

HAPROXY_BIN="${HAPROXY_BIN:-/volume1/@appstore/haproxy/sbin/haproxy}"
HAPROXY_USER="${HAPROXY_USER:-sc-haproxy}"
HAPROXY_GROUP="${HAPROXY_GROUP:-synocommunity}"
HAPROXY_CFG="${HAPROXY_CFG:-${STACK_ROOT}/_haproxy/haproxy.cfg}"
# Default to the Synology HAProxy package cert directory; bundles are deployed directly here.
LIVE_HAPROXY_CERT_DIR="${LIVE_HAPROXY_CERT_DIR:-/var/packages/haproxy/var/crt/}"
HAPROXY_CERT_STAGE_DIR="${HAPROXY_CERT_STAGE_DIR:-/var/packages/haproxy/var/crt/}"
CERT_DIR="${HAPROXY_CERT_STAGE_DIR}"
DEFAULT_SPECS="wildcard:olutechsys.com.pem otsorundscore:otsorundscore.olutechsys.com.pem misfitsds:misfitsds.olutechsys.com.pem"
SPECS="${BUNDLE_SPECS:-${DEFAULT_SPECS}}"
if [[ -n "${ACME_PROFILE:-}" && -z "${BUNDLE_SPECS:-}" ]]; then
	case "${ACME_PROFILE}" in
		wildcard)      SPECS="wildcard:olutechsys.com.pem" ;;
		otsorundscore) SPECS="otsorundscore:otsorundscore.olutechsys.com.pem" ;;
		misfitsds)     SPECS="misfitsds:misfitsds.olutechsys.com.pem" ;;
		*)
			echo "ERROR: ACME_PROFILE must be wildcard|otsorundscore|misfitsds or set BUNDLE_SPECS explicitly (got: ${ACME_PROFILE})" >&2
			exit 2
			;;
	esac
fi
read -r -a SPEC_LIST <<<"${SPECS}"

mkdir -p "${CERT_DIR}"

stage_one() {
	local profile="$1"
	local out_name="$2"
	local fc pk staged
	fc="${ACME_CERT_ROOT}/${profile}/fullchain.pem"
	pk="${ACME_CERT_ROOT}/${profile}/privkey.pem"
	if [[ ! -f "${fc}" || ! -f "${pk}" ]]; then
		echo "skip: missing ${fc} or ${pk}" >&2
		return 0
	fi
	staged="${CERT_DIR}/.${out_name}.staging.$$"
	rm -f "${staged}"
	# Concat fullchain + key (HAProxy bundle order)
	cat "${fc}" "${pk}" >"${staged}"
	openssl x509 -in "${staged}" -noout -subject -dates >/dev/null
	# pkey must read privkey.pem - combined bundle is cert-first; OpenSSL 3 decodes first PEM only.
	openssl pkey -in "${pk}" -noout -check >/dev/null
	local final="${CERT_DIR}/${out_name}"
	if [[ -f "${final}" ]]; then
		cp -a "${final}" "${final}.lkg"
	fi
	mv -f "${staged}" "${final}"
	chown "${HAPROXY_USER}:${HAPROXY_GROUP}" "${final}" || true
	chmod 0640 "${final}" || true
	echo "ok: ${final}"
}

for spec in "${SPEC_LIST[@]}"; do
	[[ -z "${spec}" ]] && continue
	profile="${spec%%:*}"
	out="${spec#*:}"
	if [[ "${profile}" == "${spec}" ]]; then
		echo "bad BUNDLE_SPECS entry (need profile:out.pem): ${spec}" >&2
		exit 2
	fi
	stage_one "${profile}" "${out}"
done

if [[ "${DO_HAPROXY_CHECK}" -eq 1 ]]; then
	if [[ "${CERT_DIR}" != "${LIVE_HAPROXY_CERT_DIR}" ]]; then
		echo "INFO: haproxy -c skipped (staged to ${CERT_DIR}; live cert dir is ${LIVE_HAPROXY_CERT_DIR}). Copy bundles to the path in haproxy.cfg then run haproxy -c manually." >&2
	elif [[ -x "${HAPROXY_BIN}" ]]; then
		if ! "${HAPROXY_BIN}" -c -f "${HAPROXY_CFG}"; then
			echo "haproxy -c failed - restoring .lkg bundles where present" >&2
			shopt -s nullglob
			for f in "${CERT_DIR}"/*.pem; do
				[[ -e "${f}" ]] || continue
				[[ "${f}" == *.lkg ]] && continue
				lkg="${f}.lkg"
				if [[ -f "${lkg}" ]]; then
					mv -f "${lkg}" "${f}"
				fi
			done
			shopt -u nullglob
			notify_discord "haproxy -c failed for ${HAPROXY_CFG}"
			exit 1
		fi
		echo "haproxy -c OK (${HAPROXY_CFG})"
	else
		echo "WARN: HAPROXY_BIN not executable (${HAPROXY_BIN}) - skipping haproxy -c (operator must validate on NAS)" >&2
	fi
fi

# HAProxy does not auto-reload on cert change.
# After this script completes: restart HAProxy via DSM -> Package Center -> HAProxy -> Action -> Restart
