#!/usr/bin/env bash
# Stage HAProxy PEM bundles (fullchain + privkey) from acme.sh output under HAPROXY_CERT_STAGE_DIR (default
# /volume2/certs/acme/haproxy). Optionally restart one Traefik stack. Does not reload or restart HAProxy.
# Host-run (preferred). See docs/hive/proposals/acme-sh/ACME_DEPLOY_HOOK_ADR.md
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: deploy_certs.sh [--no-traefik] [--no-haproxy-check]

Environment:
  STACK_ROOT              Required — Dockge stacks root (e.g. /volume2/docker/ce-stacks/stacks)
  ACME_CERT_ROOT          Default /volume2/certs/acme — acme.sh PEM trees per profile
  HAPROXY_CERT_STAGE_DIR  Default /volume2/certs/acme/haproxy — HAProxy bundle output (created if missing)
  LIVE_HAPROXY_CERT_DIR   Default ${STACK_ROOT}/_haproxy/certs — if HAPROXY_CERT_STAGE_DIR equals this,
                            haproxy -c may run (see DO_HAPROXY_CHECK); otherwise -c is skipped (wrong paths in cfg)
  BUNDLE_SPECS            Optional "profile:out.pem" space-separated list. Default:
                            otsorundscore:otsorundscore.olutechsys.com.pem misfitsds:misfitsds.olutechsys.com.pem
  ACME_PROFILE            Optional — when set and BUNDLE_SPECS is empty, builds one bundle:
                            otsorundscore → otsorundscore.olutechsys.com.pem
                            misfitsds     → misfitsds.olutechsys.com.pem
  TRAEFIK_PROFILE         ots | mft — selects traefik-ots or traefik-mft for restart (unless TRAEFIK_STACK set)
  TRAEFIK_STACK           e.g. traefik-ots — overrides profile mapping; restart only this compose project name
  SKIP_TRAEFIK            If 1, never restart Traefik
  HAPROXY_BIN             Default /volume1/@appstore/haproxy/sbin/haproxy (Synology package); must exist for -c
  HAPROXY_CFG             Config for haproxy -c; default ${STACK_ROOT}/_haproxy/haproxy.cfg
  DISCORD_WEBHOOK_URL     Optional — notify on hard failures (same var name as acme-sh compose)

Flags:
  --no-traefik       Skip Traefik docker compose restart
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

STACK_ROOT="${STACK_ROOT:?Set STACK_ROOT to your Dockge stacks directory}"
ACME_CERT_ROOT="${ACME_CERT_ROOT:-/volume2/certs/acme}"
SKIP_TRAEFIK="${SKIP_TRAEFIK:-0}"
DO_TRAEFIK=1
DO_HAPROXY_CHECK=1
while [[ "${1:-}" == -* ]]; do
	case "$1" in
		--no-traefik) DO_TRAEFIK=0 ;;
		--no-haproxy-check) DO_HAPROXY_CHECK=0 ;;
		-h | --help) usage; exit 0 ;;
		*) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

HAPROXY_BIN="${HAPROXY_BIN:-/volume1/@appstore/haproxy/sbin/haproxy}"
HAPROXY_CFG="${HAPROXY_CFG:-${STACK_ROOT}/_haproxy/haproxy.cfg}"
LIVE_HAPROXY_CERT_DIR="${LIVE_HAPROXY_CERT_DIR:-${STACK_ROOT}/_haproxy/certs}"
HAPROXY_CERT_STAGE_DIR="${HAPROXY_CERT_STAGE_DIR:-/volume2/certs/acme/haproxy}"
CERT_DIR="${HAPROXY_CERT_STAGE_DIR}"
DEFAULT_SPECS="otsorundscore:otsorundscore.olutechsys.com.pem misfitsds:misfitsds.olutechsys.com.pem"
SPECS="${BUNDLE_SPECS:-${DEFAULT_SPECS}}"
if [[ -n "${ACME_PROFILE:-}" && -z "${BUNDLE_SPECS:-}" ]]; then
	case "${ACME_PROFILE}" in
		otsorundscore) SPECS="otsorundscore:otsorundscore.olutechsys.com.pem" ;;
		misfitsds) SPECS="misfitsds:misfitsds.olutechsys.com.pem" ;;
		*)
			echo "ERROR: ACME_PROFILE must be otsorundscore|misfitsds or set BUNDLE_SPECS explicitly (got: ${ACME_PROFILE})" >&2
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
	# pkey must read privkey.pem — combined bundle is cert-first; OpenSSL 3 decodes first PEM only.
	openssl pkey -in "${pk}" -noout -check >/dev/null
	local final="${CERT_DIR}/${out_name}"
	if [[ -f "${final}" ]]; then
		cp -a "${final}" "${final}.lkg"
	fi
	mv -f "${staged}" "${final}"
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
		echo "INFO: haproxy -c skipped (staged to ${CERT_DIR}; live cfg typically uses ${LIVE_HAPROXY_CERT_DIR}). Copy bundles to the path in haproxy.cfg then run haproxy -c, or set HAPROXY_CERT_STAGE_DIR=\${STACK_ROOT}/_haproxy/certs for in-place validate." >&2
	elif [[ -x "${HAPROXY_BIN}" ]]; then
		if ! "${HAPROXY_BIN}" -c -f "${HAPROXY_CFG}"; then
			echo "haproxy -c failed — restoring .lkg bundles where present" >&2
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
		echo "WARN: HAPROXY_BIN not executable (${HAPROXY_BIN}) — skipping haproxy -c (operator must validate on NAS)" >&2
	fi
fi

if [[ "${DO_TRAEFIK}" -eq 1 && "${SKIP_TRAEFIK}" != "1" ]]; then
	tstack="${TRAEFIK_STACK:-}"
	if [[ -z "${tstack}" ]]; then
		case "${TRAEFIK_PROFILE:-}" in
			ots) tstack="traefik-ots" ;;
			mft) tstack="traefik-mft" ;;
			*) tstack="" ;;
		esac
	fi
	if [[ -z "${tstack}" ]]; then
		echo "Traefik restart skipped: set TRAEFIK_PROFILE=ots|mft or TRAEFIK_STACK=traefik-ots|traefik-mft" >&2
	else
		proj="${STACK_ROOT}/${tstack}"
		if [[ ! -d "${proj}" ]]; then
			echo "ERROR: ${proj} not found" >&2
			exit 1
		fi
		(
			cd "${proj}" || exit 1
			if [[ -f .env ]]; then
				docker compose --env-file .env restart
			else
				docker compose restart
			fi
		)
		echo "restarted: ${tstack}"
	fi
fi
