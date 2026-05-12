#!/usr/bin/env bash
# Smoke-check Dockge HTTP on the NAS after dockge-start.sh (or before editing HAProxy).
# Usage: bash scripts/check-dockge-http.sh [host[:port]]
# Default: 127.0.0.1:5571
set -euo pipefail
addr="${1:-127.0.0.1:5571}"
code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 "http://${addr}/" || true)"
if [[ -z "${code}" || "${code}" == "000" ]]; then
	echo "check-dockge-http: FAIL no response from http://${addr}/" >&2
	exit 1
fi
echo "check-dockge-http: http://${addr}/ -> HTTP ${code}"
# POSIX-safe: avoid bash-only regex alternation edge cases across environments.
if [[ "${code}" != "200" && "${code}" != "301" && "${code}" != "302" && "${code}" != "303" && "${code}" != "304" ]]; then
	exit 1
fi
