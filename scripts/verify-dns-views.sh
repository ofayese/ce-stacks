#!/bin/bash
# Verify split-horizon DNS (Synology internal forward zones or dnsmasq) and Traefik HTTPS.
#
# Usage:
#   bash verify-dns-views.sh
#   bash verify-dns-views.sh --hairpin [hostname]
#   bash verify-dns-views.sh --help
# Env:
#   VERIFY_DNS_SERVER=127.0.0.1   # when running on the OTS NAS (queries local named)
#   OTS_NAS_IP / MFT_NAS_IP       # override if your LAN differs

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

OTS_NAS_IP="${OTS_NAS_IP:-10.0.1.15}"
MFT_NAS_IP="${MFT_NAS_IP:-10.0.1.24}"
OTS_HOST="${VERIFY_HAIRPIN_HOST:-otsdrv.otsorundscore.olutechsys.com}"
HAIRPIN_HOST="${VERIFY_HAIRPIN_HOST:-otsorundscore.olutechsys.com}"
MFT_HOST="mftdrv.misfitsds.olutechsys.com"

OTS_DNS_SERVER="${VERIFY_DNS_SERVER:-$OTS_NAS_IP}"

expected_traefik_ip_for_host() {
	local h="$1"
	case "$h" in
	*".misfitsds."*) echo "$MFT_NAS_IP" ;;
	*".otsorundscore."*) echo "$OTS_NAS_IP" ;;
	*) echo "$OTS_NAS_IP" ;;
	esac
}

# First A record returned (dig preferred; else nslookup heuristics).
resolve_a() {
	local host="$1"
	local via="${2:-}"
	if command -v dig &>/dev/null; then
		if [[ -n "$via" ]]; then
			dig +short "$host" @"$via" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1
		else
			dig +short "$host" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1
		fi
		return 0
	fi
	local out
	if [[ -n "$via" ]]; then
		out=$(nslookup "$host" "$via" 2>&1 || true)
	else
		out=$(nslookup "$host" 2>&1 || true)
	fi
	echo "$out" | awk '/^Address: / { ip=$2 } END { print ip }' | tail -1
}

https_ok() {
	local host="$1"
	local code
	code=$(curl -kI -o /dev/null -s -w '%{http_code}' --max-time 15 "https://$host" || echo "000")
	case "$code" in
	2[0-9][0-9] | 3[0-9][0-9]) return 0 ;;
	*) return 1 ;;
	esac
}

run_hairpin_probe() {
	local host="${1:-}"
	[[ -z "$host" ]] && host="$HAIRPIN_HOST"
	local traefik_lan
	traefik_lan=$(expected_traefik_ip_for_host "$host")

	echo -e "${BOLD}━━ Hairpin / split-horizon probe ━━${NC}"
	echo "Hostname: $host"
	echo "Expected Traefik LAN IP (heuristic): $traefik_lan"
	echo ""

	local def_ip nas_ip
	def_ip=$(resolve_a "$host" "") || true
	nas_ip=$(resolve_a "$host" "$OTS_NAS_IP") || true
	echo -e "${BOLD}[A] Default resolver (first A)${NC}"
	echo "${def_ip:-<none>}"
	echo ""
	echo -e "${BOLD}[B] Resolver @${OTS_NAS_IP} (first A)${NC}"
	echo "${nas_ip:-<none>}"
	echo ""
	echo -e "${BOLD}[C] HTTPS (curl -kI, uses default resolver / SNI)${NC}"
	local code
	code=$(curl -kI -o /dev/null -s -w '%{http_code}' --max-time 15 "https://$host" || echo "000")
	echo "HTTP status: $code"
	local curl_ok=false
	case "$code" in
	2[0-9][0-9] | 3[0-9][0-9]) curl_ok=true ;;
	esac

	echo ""
	echo -e "${CYAN}━━ Verdict ━━${NC}"
	if [[ "$nas_ip" =~ ^10\. ]] && [[ "$def_ip" != "$nas_ip" ]]; then
		echo -e "${GREEN}[SPLIT-DNS ACTIVE]${NC} NAS resolver returns LAN IP; public/default DNS differs."
	elif $curl_ok; then
		echo -e "${GREEN}[HAIRPIN OK]${NC} HTTPS works via the default resolver; split-DNS is optional for reachability."
	else
		echo -e "${YELLOW}[SPLIT-DNS NEEDED]${NC} HTTPS via default resolver failed; point clients at NAS DNS or fix hairpin/firewall."
	fi
	echo ""
	echo "SAN / cert: openssl s_client -servername $host -connect ${traefik_lan}:443 </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName"
	exit 0
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
fi

if [[ "${1:-}" == "--hairpin" ]]; then
	run_hairpin_probe "${2:-}"
fi

echo -e "${BOLD}━━ Split-horizon DNS verification ━━${NC}"
echo "Using DNS server: $OTS_DNS_SERVER (set VERIFY_DNS_SERVER=127.0.0.1 on the NAS)"
echo ""

echo -e "${BOLD}[Test 1] OTS NAS reachability${NC}"
if ping -c 1 -W 2 "$OTS_NAS_IP" &>/dev/null; then
	echo -e "${GREEN}✓${NC} OTS NAS ($OTS_NAS_IP) reachable"
else
	echo -e "${RED}✗${NC} OTS NAS ($OTS_NAS_IP) not reachable"
	exit 1
fi

echo ""
echo -e "${BOLD}[Test 2] OTS zone @ $OTS_DNS_SERVER${NC}"
if result=$(nslookup "$OTS_HOST" "$OTS_DNS_SERVER" 2>&1); then
	if echo "$result" | grep -q "$OTS_NAS_IP"; then
		echo -e "${GREEN}✓${NC} $OTS_HOST → $OTS_NAS_IP"
	else
		echo -e "${RED}✗${NC} Unexpected answer:"
		echo "$result" | tail -8
	fi
else
	echo -e "${RED}✗${NC} nslookup failed"
	echo "$result" | tail -8
fi

echo ""
echo -e "${BOLD}[Test 3] Wildcard OTS${NC}"
if result=$(nslookup "testhost.otsorundscore.olutechsys.com" "$OTS_DNS_SERVER" 2>&1); then
	if echo "$result" | grep -q "$OTS_NAS_IP"; then
		echo -e "${GREEN}✓${NC} Wildcard OK"
	else
		echo -e "${RED}✗${NC} Wildcard failed"
		echo "$result" | tail -6
	fi
fi

echo ""
echo -e "${BOLD}[Test 4] MFT (optional)${NC}"
if ping -c 1 -W 2 "$MFT_NAS_IP" &>/dev/null; then
	if result=$(nslookup "$MFT_HOST" "$OTS_DNS_SERVER" 2>&1); then
		if echo "$result" | grep -q "$MFT_NAS_IP"; then
			echo -e "${GREEN}✓${NC} $MFT_HOST → $MFT_NAS_IP"
		else
			echo -e "${YELLOW}⚠${NC} MFT zone missing/wrong"
			echo "$result" | tail -6
		fi
	fi
else
	echo -e "${YELLOW}⚠${NC} MFT host unreachable — skip"
fi

echo ""
echo -e "${BOLD}[Test 5] google.com forwarding${NC}"
if result=$(nslookup google.com "$OTS_DNS_SERVER" 2>&1); then
	if echo "$result" | grep -qE "Address: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"; then
		echo -e "${GREEN}✓${NC} Upstream OK"
	else
		echo -e "${RED}✗${NC} Upstream failed"
		echo "$result" | tail -6
	fi
fi

echo ""
echo -e "${BOLD}[Test 6] Traefik HTTPS${NC}"
curl -kI --max-time 15 "https://$OTS_HOST" 2>&1 | head -4 || echo -e "${YELLOW}⚠${NC} curl failed"

echo ""
echo -e "${BOLD}[Test 7] Client DNS hints${NC}"
if [[ -f /etc/resolv.conf ]]; then
	grep '^nameserver' /etc/resolv.conf | head -3 || true
elif command -v scutil &>/dev/null; then
	scutil --dns 2>/dev/null | grep -A1 'nameserver\[0\]' | head -6 || true
fi

echo ""
echo -e "${BOLD}Done.${NC}  Hairpin: bash scripts/verify-dns-views.sh --hairpin [hostname]"
