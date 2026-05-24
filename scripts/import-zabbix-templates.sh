#!/usr/bin/env bash
# import-zabbix-templates.sh — Post-deploy Zabbix template import.
#
# Imports two templates into a running Zabbix 7.x instance via the JSON-RPC API:
#   1. Synology DiskStation SNMPv3  (community template)
#   2. Synology Hyper Backup        (lestoilfante integration)
#
# Idempotent: re-runs skip templates that are already present (matched by name).
#
# Usage:
#   bash scripts/import-zabbix-templates.sh
#
# Prerequisites: curl, jq, docker
# Env overrides (all optional — defaults match zabbix/compose.yaml .env.example):
#   ZABBIX_URL        API base URL, default http://10.0.1.15:${ZABBIX_WEB_PORT:-8532}
#   ZABBIX_ADMIN_USER Admin username, default Admin
#   ZABBIX_ADMIN_PASS Admin password,  default zabbix
#   ZABBIX_HOSTNAME   Host name to link templates to, default otsorundscore

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
ZABBIX_URL="${ZABBIX_URL:-http://10.0.1.15:${ZABBIX_WEB_PORT:-8532}}"
ZABBIX_ADMIN_USER="${ZABBIX_ADMIN_USER:-Admin}"
ZABBIX_ADMIN_PASS="${ZABBIX_ADMIN_PASS:-zabbix}"
ZABBIX_HOSTNAME="${ZABBIX_HOSTNAME:-otsorundscore}"

API="${ZABBIX_URL}/api_jsonrpc.php"
TIMEOUT=300          # max seconds to wait for API readiness
POLL_INTERVAL=10     # seconds between API health polls
IMPORTED=0
SKIPPED=0
FAILED=0

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[✗]${NC} $*"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
zabbix_rpc() {
  # $1 = method name, $2 = params JSON
  local method="$1" params="$2"
  curl -sf -X POST "${API}" \
    -H "Content-Type: application/json-rpc" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"auth\":\"${AUTH_TOKEN}\",\"id\":1}"
}

# ── 0. Sanity checks ─────────────────────────────────────────────────────────
command -v jq   >/dev/null 2>&1 || { fail "jq is required — install via synopkg or brew"; exit 1; }
command -v curl >/dev/null 2>&1 || { fail "curl is required"; exit 1; }

# ── 1. Wait for Zabbix API to be ready ────────────────────────────────────────
echo "Waiting for Zabbix API at ${API} ..."
elapsed=0
while [ "${elapsed}" -lt "${TIMEOUT}" ]; do
  if curl -sf -X POST "${API}" \
    -H "Content-Type: application/json-rpc" \
    -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' \
    | jq -re '.result' >/dev/null 2>&1; then
    ZABBIX_VERSION="$(curl -sf -X POST "${API}" \
      -H "Content-Type: application/json-rpc" \
      -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' \
      | jq -re '.result')"
    log "Zabbix API ready (version ${ZABBIX_VERSION})"
    break
  fi
  sleep "${POLL_INTERVAL}"
  elapsed=$((elapsed + POLL_INTERVAL))
  echo "  ... still waiting (${elapsed}s / ${TIMEOUT}s)"
done

if [ "${elapsed}" -ge "${TIMEOUT}" ]; then
  fail "Zabbix API did not become ready within ${TIMEOUT}s. Aborting."
  exit 1
fi

# ── 2. Authenticate ───────────────────────────────────────────────────────────
echo "Authenticating as ${ZABBIX_ADMIN_USER} ..."
AUTH_RESPONSE="$(curl -sf -X POST "${API}" \
  -H "Content-Type: application/json-rpc" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"username\":\"${ZABBIX_ADMIN_USER}\",\"password\":\"${ZABBIX_ADMIN_PASS}\"},\"id\":1}")"

AUTH_TOKEN="$(echo "${AUTH_RESPONSE}" | jq -re '.result // empty')"
if [ -z "${AUTH_TOKEN}" ]; then
  fail "Authentication failed — check ZABBIX_ADMIN_USER / ZABBIX_ADMIN_PASS"
  echo "  Response: ${AUTH_RESPONSE}" >&2
  exit 1
fi
log "Authenticated successfully"

# ── 3. Find the host ID ──────────────────────────────────────────────────────
echo "Looking up host '${ZABBIX_HOSTNAME}' ..."
HOST_RESPONSE="$(zabbix_rpc "host.get" "{\"output\":[\"hostid\",\"host\"],\"filter\":{\"host\":\"${ZABBIX_HOSTNAME}\"}}")"
HOST_ID="$(echo "${HOST_RESPONSE}" | jq -re '.result[0].hostid // empty')"

if [ -z "${HOST_ID}" ]; then
  fail "Host '${ZABBIX_HOSTNAME}' not found in Zabbix. Create the host first, then re-run."
  exit 1
fi
log "Found host ${ZABBIX_HOSTNAME} (ID: ${HOST_ID})"

# ── 4. Check already-linked templates ────────────────────────────────────────
EXISTING_TEMPLATES="$(zabbix_rpc "template.get" \
  "{\"output\":[\"name\"],\"hostids\":[\"${HOST_ID}\"]}")"
EXISTING_NAMES="$(echo "${EXISTING_TEMPLATES}" | jq -r '.result[].name')"

# ── 5. Define templates to import ────────────────────────────────────────────
# Each entry: URL → local temp file → template name (for idempotent skip)
declare -a TEMPLATE_URLS=(
  "https://raw.githubusercontent.com/zabbix/community-templates/main/Storage_Devices/Synology/template_synology_diskstation_snmpv3/6.0/template_synology_diskstation_snmpv3.yaml"
  "https://raw.githubusercontent.com/lestoilfante/zabbix-integrations/master/Synology/template_synology_hyperbackup.yaml"
)

declare -a TEMPLATE_NAMES=(
  "Synology DiskStation SNMPv3"
  "Synology Hyper Backup"
)

TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_WORK}"' EXIT

# ── 6. Import each template ──────────────────────────────────────────────────
for i in "${!TEMPLATE_URLS[@]}"; do
  URL="${TEMPLATE_URLS[$i]}"
  NAME="${TEMPLATE_NAMES[$i]}"
  FILE="${TMPDIR_WORK}/template_${i}.yaml"

  echo ""
  echo "── ${NAME} ──"

  # Idempotent skip
  if echo "${EXISTING_NAMES}" | grep -qF "${NAME}"; then
    warn "SKIP — template '${NAME}' already linked to ${ZABBIX_HOSTNAME}"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Download
  echo "  Downloading template ..."
  if ! curl -sfL "${URL}" -o "${FILE}"; then
    fail "Download failed for ${NAME} — check URL: ${URL}"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Import via API (Zabbix 7.x: configuration.import)
  # The source must be the raw YAML/JSON string, rules enable create/update for templates
  echo "  Importing into Zabbix ..."
  TEMPLATE_CONTENT="$(cat "${FILE}")"

  IMPORT_RESPONSE="$(zabbix_rpc "configuration.import" \
    "{\"format\":\"yaml\",\"source\":$(printf '%s' "${TEMPLATE_CONTENT}" | jq -Rs .),\"rules\":{\"templates\":{\"createMissing\":true,\"updateExisting\":true},\"templateDashboards\":{\"createMissing\":true,\"updateExisting\":true},\"items\":{\"createMissing\":true,\"updateExisting\":true},\"triggers\":{\"createMissing\":true,\"updateExisting\":true},\"graphs\":{\"createMissing\":true,\"updateExisting\":true},\"apps\":{\"createMissing\":true,\"updateExisting\":true}}}")"

  IMPORT_RESULT="$(echo "${IMPORT_RESPONSE}" | jq -re '.result // empty')"
  IMPORT_ERROR="$(echo "${IMPORT_RESPONSE}" | jq -re '.error.data // .error.message // empty')"

  if [ "${IMPORT_RESULT}" = "true" ]; then
    log "Template '${NAME}' imported successfully"
    IMPORTED=$((IMPORTED + 1))

    # Link the newly imported template to the host
    # Find the template ID by name (API returns the imported template name)
    TPL_RESPONSE="$(zabbix_rpc "template.get" "{\"output\":[\"templateid\"],\"filter\":{\"name\":\"${NAME}\"}}")"
    TPL_ID="$(echo "${TPL_RESPONSE}" | jq -re '.result[0].templateid // empty')"

    if [ -n "${TPL_ID}" ]; then
      LINK_RESPONSE="$(zabbix_rpc "massadd" \
        "{\"templates\":[{\"templateid\":\"${TPL_ID}\"}],\"hosts\":[{\"hostid\":\"${HOST_ID}\"}]}")"
      LINK_RESULT="$(echo "${LINK_RESPONSE}" | jq -re '.result // empty')"
      if [ -n "${LINK_RESULT}" ]; then
        log "Template '${NAME}' linked to ${ZABBIX_HOSTNAME}"
      else
        LINK_ERR="$(echo "${LINK_RESPONSE}" | jq -re '.error.message // empty')"
        warn "Could not auto-link '${NAME}': ${LINK_ERR:-unknown error}"
        warn "Link manually: Configuration → Hosts → ${ZABBIX_HOSTNAME} → Templates"
      fi
    else
      warn "Could not find template ID for '${NAME}' after import — link manually in UI"
    fi
  else
    fail "Import failed for '${NAME}': ${IMPORT_ERROR:-unknown error}"
    FAILED=$((FAILED + 1))
  fi
done

# ── 7. Summary ────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════"
echo "  Import complete"
echo "  Imported: ${IMPORTED}  |  Skipped: ${SKIPPED}  |  Failed: ${FAILED}"
echo "══════════════════════════════════════════════════"

if [ "${FAILED}" -gt 0 ]; then
  exit 1
fi
