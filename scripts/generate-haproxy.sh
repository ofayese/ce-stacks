#!/usr/bin/env bash
# =============================================================================
# generate-haproxy.sh -- generate haproxy.cfg + host.map from compose labels
# =============================================================================
# Reads haproxy.* labels from every stacks/*/compose.yaml, combines them with
# the static infrastructure template (haproxy.cfg.head) and the static host
# entries (host.map.static), then writes a complete haproxy.cfg and host.map
# ready for the operator to paste into DSM.
#
# Label convention (add to the proxied service in compose.yaml):
#
#   labels:
#     - haproxy.enable=true
#     - haproxy.host=svc.olutechsys.com,svc.olutech.systems
#     - haproxy.port=8080               # host port HAProxy connects to
#     - haproxy.backend=svc-be          # optional; defaults to <service>-be
#     - haproxy.check.path=/healthz     # optional; defaults to /
#     - haproxy.check.method=GET        # optional; defaults to GET
#     - haproxy.ssl=false               # optional; true = ssl verify none (Synology native HTTPS)
#
# Usage:
#   bash scripts/generate-haproxy.sh              # write cfg + map, print paste instructions
#   bash scripts/generate-haproxy.sh --dry-run    # print generated content, no writes
#   bash scripts/generate-haproxy.sh --help
#
# Files produced:
#   stacks/_haproxy/haproxy.cfg       <- paste into DSM -> HAProxy -> Edit configuration -> Validate -> Apply
#   stacks/_haproxy/maps/host.map     <- already on the NAS live path; live-reload via haproxy-reload-map.sh
#
# Operator workflow after running this script:
#   1) DSM -> Package Center -> HAProxy -> Edit configuration
#   2) Select all, paste content of stacks/_haproxy/haproxy.cfg
#   3) Click "Validate" — confirm no errors
#   4) Click "Apply"
#   5) Action -> Restart  (first run: Action -> Stop, then Start)
#   6) For host.map-only changes (no backend changes): skip steps 1-5,
#      just run:  bash scripts/haproxy-reload-map.sh
#
# Requires: python3 (stdlib only — no third-party packages needed)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate repo root
# ---------------------------------------------------------------------------
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${_SCRIPT_DIR}"
while [[ ! -f "${ROOT}/README.md" && "${ROOT}" != "/" ]]; do
    ROOT="$(dirname "${ROOT}")"
done
[[ -f "${ROOT}/README.md" ]] || {
    echo "generate-haproxy: ERROR: could not find repo root (README.md)" >&2
    exit 1
}

STACKS_DIR="${ROOT}/stacks"
HAPROXY_DIR="${STACKS_DIR}/_haproxy"
HEAD_FILE="${HAPROXY_DIR}/haproxy.cfg.head"
STATIC_MAP="${HAPROXY_DIR}/maps/host.map.static"
OUT_CFG="${HAPROXY_DIR}/haproxy.cfg"
OUT_MAP="${HAPROXY_DIR}/maps/host.map"

NAS_IP="10.0.1.15"
DRY_RUN=0

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "${arg}" in
        --dry-run)  DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,42p' "$0"
            exit 0
            ;;
        *)
            echo "generate-haproxy: unknown argument: ${arg}" >&2
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
[[ -f "${HEAD_FILE}" ]] || {
    echo "generate-haproxy: ERROR: head template not found: ${HEAD_FILE}" >&2
    exit 1
}
[[ -f "${STATIC_MAP}" ]] || {
    echo "generate-haproxy: ERROR: static map not found: ${STATIC_MAP}" >&2
    exit 1
}
# ---------------------------------------------------------------------------
# Python: parse labels, emit backends + host.map entries (stdlib only — no pyyaml)
# ---------------------------------------------------------------------------
_GENERATED=$(python3 - "${STACKS_DIR}" "${NAS_IP}" <<'PYEOF'
#!/usr/bin/env python3
"""
Parse haproxy.* labels from stacks/*/compose.yaml.
Stdlib only — no pyyaml required. Uses an indentation-aware line parser
that handles both list-style (- key=value) and dict-style (key: value) labels.

Outputs two blocks separated by sentinel lines:
  === BACKENDS ===
  <backend stanzas>
  === HOSTMAP ===
  <host.map lines>
"""
import re, sys
from pathlib import Path

STACKS_DIR = Path(sys.argv[1])
NAS_IP     = sys.argv[2]

# Resolve ${VAR:-default} / ${VAR} patterns
_env_re = re.compile(r'\$\{([^}:]+)(?::-(.*?))?\}')

def resolve(val):
    def sub(m):
        default = m.group(2)
        return default if default is not None else m.group(1)
    return _env_re.sub(sub, str(val))

def indent_of(line):
    return len(line) - len(line.lstrip(' '))

def extract_labels(filepath):
    """
    Minimal Docker Compose label extractor (no external deps).
    Returns: dict mapping service_name -> {label_key: label_value}
    Handles list-style labels (- key=value) and dict-style (key: value).
    """
    try:
        lines = filepath.read_text().splitlines()
    except Exception as e:
        print(f"# WARNING: cannot read {filepath}: {e}", file=sys.stderr)
        return {}

    services     = {}
    in_services  = False
    current_svc  = None
    svc_indent   = None
    in_labels    = False
    lbl_item_ind = None
    current_lbls = {}

    for raw in lines:
        line    = raw.rstrip()
        stripped = line.strip()

        if not stripped or stripped.startswith('#'):
            continue

        ind = indent_of(line)

        # ── top-level keys (indent 0) ──────────────────────────────────────
        if ind == 0 and stripped.endswith(':'):
            if stripped == 'services:':
                in_services = True
            else:
                if current_svc is not None:
                    services[current_svc] = dict(current_lbls)
                in_services = False
                current_svc = None
                in_labels   = False
            continue

        if not in_services:
            continue

        # ── service name (indent 2, ends with ':') ─────────────────────────
        if ind == 2 and stripped.endswith(':') and not stripped.startswith('-'):
            if current_svc is not None:
                services[current_svc] = dict(current_lbls)
            current_svc  = stripped[:-1]
            svc_indent   = ind
            in_labels    = False
            lbl_item_ind = None
            current_lbls = {}
            continue

        if current_svc is None:
            continue

        # ── 'labels:' key (indent svc+2 = 4) ──────────────────────────────
        if ind == svc_indent + 2 and stripped == 'labels:':
            in_labels    = True
            lbl_item_ind = ind + 2   # list/dict items expected at indent 6+
            continue

        # exit labels block when we return to service-property level
        if in_labels and ind <= svc_indent + 2 and stripped != 'labels:':
            in_labels = False

        if not in_labels:
            continue

        if ind < lbl_item_ind:
            in_labels = False
            continue

        # list-style:  - haproxy.enable=true   or  - "haproxy.host=a,b"
        if stripped.startswith('-'):
            item = stripped[1:].strip().strip('"\'')
            if '=' in item:
                k, _, v = item.partition('=')
                current_lbls[k.strip()] = v.strip()
        # dict-style:  haproxy.enable: true
        elif ':' in stripped:
            k, _, v = stripped.partition(':')
            current_lbls[k.strip()] = v.strip().strip('"\'')

    if current_svc is not None:
        services[current_svc] = dict(current_lbls)

    return services

# ── main: walk stacks ───────────────────────────────────────────────────────
backends = {}   # be_name -> {port, ssl, method, path, hosts, stack, svc}

for compose_file in sorted(STACKS_DIR.glob("*/compose.yaml")):
    stack = compose_file.parent.name
    if stack.startswith("_"):
        continue

    for svc_name, labels in extract_labels(compose_file).items():
        if labels.get("haproxy.enable", "").lower() not in ("true", "1", "yes"):
            continue

        host_str = labels.get("haproxy.host", "").strip()
        raw_port = labels.get("haproxy.port", "").strip()
        port     = resolve(raw_port)

        if not host_str or not port:
            print(
                f"# WARNING: {stack}/{svc_name}: haproxy.enable=true "
                f"but missing haproxy.host or haproxy.port — skipped",
                file=sys.stderr,
            )
            continue

        try:
            int(port)
        except ValueError:
            print(
                f"# WARNING: {stack}/{svc_name}: haproxy.port '{raw_port}' "
                f"resolved to non-numeric '{port}' — skipped",
                file=sys.stderr,
            )
            continue

        be_name = labels.get("haproxy.backend", f"{svc_name}-be").strip()
        ssl     = labels.get("haproxy.ssl", "false").lower() in ("true", "1", "yes")
        method  = labels.get("haproxy.check.method", "GET").strip().upper()
        path    = labels.get("haproxy.check.path", "/").strip()
        hosts   = [h.strip() for h in host_str.split(",") if h.strip()]

        if be_name in backends:
            backends[be_name]["hosts"].extend(hosts)
        else:
            backends[be_name] = {
                "port":   port,
                "ssl":    ssl,
                "method": method,
                "path":   path,
                "hosts":  hosts,
                "stack":  stack,
                "svc":    svc_name,
            }

# ── emit ────────────────────────────────────────────────────────────────────
print("=== BACKENDS ===")
for be_name in sorted(backends):
    be  = backends[be_name]
    ssl = " ssl verify none" if be["ssl"] else ""
    print(f"backend {be_name}")
    print(f"    # {be['stack']}/{be['svc']} — auto-generated from haproxy.* labels")
    print(f"    option httpchk {be['method']} {be['path']}")
    server = be_name.replace("-be", "")
    print(f"    server {server} {NAS_IP}:{be['port']}{ssl} check")
    print()

print("=== HOSTMAP ===")
for be_name in sorted(backends):
    for host in backends[be_name]["hosts"]:
        print(f"{host}\t{be_name}")

PYEOF
)

# ---------------------------------------------------------------------------
# Split Python output into two sections
# ---------------------------------------------------------------------------
_BACKENDS=$(echo "${_GENERATED}" | awk '/=== BACKENDS ===/,/=== HOSTMAP ===/' | grep -v "^=== ")
_HOSTMAP=$(echo  "${_GENERATED}" | awk '/=== HOSTMAP ===/,0'                   | grep -v "^=== ")

BACKEND_COUNT=$(echo "${_BACKENDS}" | grep -c "^backend " || true)
HOSTMAP_COUNT=$(echo "${_HOSTMAP}"  | grep -c "^[^#]"     || true)

echo "generate-haproxy: found ${BACKEND_COUNT} Docker backends, ${HOSTMAP_COUNT} host.map entries"

# ---------------------------------------------------------------------------
# Assemble haproxy.cfg = head + generated backends
# ---------------------------------------------------------------------------
_CFG=$(cat "${HEAD_FILE}"; echo; echo "${_BACKENDS}"; echo "# eof")

# ---------------------------------------------------------------------------
# Assemble host.map = static entries + generated entries
# ---------------------------------------------------------------------------
_MAP=$(
    grep -v "^#" "${STATIC_MAP}" | grep -v "^$"
    echo ""
    echo "# Docker service entries (auto-generated)"
    echo "${_HOSTMAP}"
)

# ---------------------------------------------------------------------------
# Dry-run: print and exit
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo ""
    echo "========== haproxy.cfg (would write to ${OUT_CFG}) =========="
    echo "${_CFG}"
    echo ""
    echo "========== host.map (would write to ${OUT_MAP}) =========="
    echo "${_MAP}"
    echo ""
    echo "generate-haproxy: DRY RUN complete — no files written"
    exit 0
fi

# ---------------------------------------------------------------------------
# Write files
# ---------------------------------------------------------------------------
echo "${_CFG}" > "${OUT_CFG}"
echo "${_MAP}"  > "${OUT_MAP}"
echo "generate-haproxy: wrote ${OUT_CFG}"
echo "generate-haproxy: wrote ${OUT_MAP}"

# ---------------------------------------------------------------------------
# Validate using existing validate-haproxy-proposal.sh
# ---------------------------------------------------------------------------
VALIDATE_SCRIPT="${ROOT}/scripts/validate-haproxy-proposal.sh"
if [[ -x "${VALIDATE_SCRIPT}" ]]; then
    echo "generate-haproxy: running validate-haproxy-proposal.sh..."
    bash "${VALIDATE_SCRIPT}"
    echo "generate-haproxy: validation PASSED"
else
    echo "generate-haproxy: WARNING: validate-haproxy-proposal.sh not found/executable — skipping"
fi

echo "generate-haproxy: done"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Operator: paste the generated config into DSM HAProxy GUI"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Config file (select all + copy):"
echo "    ${OUT_CFG}"
echo ""
echo "  Steps:"
echo "    1) DSM -> Package Center -> HAProxy -> Edit configuration"
echo "    2) Select all, paste the content of the file above"
echo "    3) Click  Validate  — confirm no errors"
echo "    4) Click  Apply"
echo "    5) Action -> Restart  (or Stop + Start on first deploy)"
echo ""
echo "  host.map is already at its live path — no GUI action needed."
echo "  For map-only changes (no new backends): skip steps 1-5 and run:"
echo "    bash scripts/haproxy-reload-map.sh"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
