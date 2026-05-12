#!/bin/bash
# Optional split-horizon helper: dnsmasq address= overrides (NOT BIND Views).
#
# Preferred path: DSM → DNS Server → Primary zone → Forward zone (internal
# authoritative forward DNS). This script only applies dnsmasq drop-ins if your
# DSM build still honors /etc/dnsmasq.d/ for the DNS Server package — verify on
# a non-production NAS or DSM minor version first.
#
# DSM 6 vs 7: restart path differs (synopkg / synosystemctl / synoservice). This
# script tries multiple methods and fails loudly if none succeed.
#
# Run on Synology as admin with sudo.

set -euo pipefail

CONF_NAME="split-horizon.conf"
CONF_DIR="/etc/dnsmasq.d"
CONF_PATH="${CONF_DIR}/${CONF_NAME}"

dsm_major=""
if [[ -r /etc.defaults/VERSION ]]; then
	# shellcheck disable=SC1091
	. /etc.defaults/VERSION || true
	dsm_major="${majorversion:-}"
fi

restart_dns_server() {
	if command -v synopkg &>/dev/null; then
		if sudo synopkg restart DNSServer; then
			return 0
		fi
	fi
	if command -v synosystemctl &>/dev/null; then
		if sudo synosystemctl restart pkgctl-DNSServer 2>/dev/null; then
			return 0
		fi
		if sudo synosystemctl restart dnsmasq 2>/dev/null; then
			return 0
		fi
	fi
	if command -v synoservice &>/dev/null; then
		if sudo synoservice --restart dnsmasq 2>/dev/null; then
			return 0
		fi
	fi
	return 1
}

echo "== Synology split-horizon dnsmasq overrides (optional) =="
if [[ -n "$dsm_major" ]]; then
	echo "Detected DSM major version: ${dsm_major}"
else
	echo "WARN: could not read DSM version from /etc.defaults/VERSION" >&2
fi

if ! command -v synopkg &>/dev/null && ! command -v synoservice &>/dev/null && ! command -v synosystemctl &>/dev/null; then
	echo "ERROR: no synopkg/synoservice/synosystemctl — run this script on Synology DSM." >&2
	exit 1
fi

if ! sudo mkdir -p "$CONF_DIR"; then
	echo "ERROR: could not create ${CONF_DIR}" >&2
	exit 1
fi

if ! sudo tee "$CONF_PATH" >/dev/null <<'EOF'; then
# Split-horizon — dnsmasq address= overrides (see docs/hive/SYNOLOGY_DNS_VIEWS.md)
address=/ots.olutechsys.com/10.0.1.15
address=/.ots.olutechsys.com/10.0.1.15
address=/mft.olutechsys.com/10.0.1.24
address=/.mft.olutechsys.com/10.0.1.24
EOF
	echo "ERROR: failed to write ${CONF_PATH}" >&2
	exit 1
fi

echo "Wrote ${CONF_PATH}"

if restart_dns_server; then
	echo "DNS Server (or dnsmasq) restart succeeded."
else
	echo "ERROR: could not restart DNS Server. Fix from DSM → Package Center or review logs." >&2
	exit 1
fi

echo ""
echo "Smoke tests (127.0.0.1) — failures here do not undo the config file."
nslookup otsdrv.ots.olutechsys.com 127.0.0.1 || true
nslookup mftdrv.mft.olutechsys.com 127.0.0.1 || true

echo ""
echo "Next: hairpin preflight (docs), DHCP DNS1+DNS2, then: bash scripts/verify-dns-views.sh"
