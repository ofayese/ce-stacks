#!/usr/bin/env bash
# Generate docs/service-map.md from all stacks/*/compose.yaml port bindings.
#
# Usage:
#   bash scripts/generate-service-map.sh          # writes docs/service-map.md
#   bash scripts/generate-service-map.sh --stdout  # print to stdout only
#
# Run after adding, removing, or changing ports in any stack.
# Requires python3 + pyyaml (pip install pyyaml --break-system-packages).
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${_script_dir}"
while [[ ! -f "${ROOT}/README.md" && "${ROOT}" != "/" ]]; do
	ROOT="$(dirname "${ROOT}")"
done
[[ -f "${ROOT}/README.md" ]] || {
	echo "ERROR: could not find repo root (README.md) above ${_script_dir}" >&2
	exit 1
}

STDOUT_ONLY=0
[[ "${1:-}" == "--stdout" ]] && STDOUT_ONLY=1

OUT="${ROOT}/docs/service-map.md"

python3 - "${ROOT}" <<'PYEOF'
#!/usr/bin/env python3
"""Parse all stacks/*/compose.yaml and emit docs/service-map.md."""
import re, sys, yaml
from pathlib import Path
from datetime import date

ROOT       = Path(sys.argv[1])
STACKS_DIR = ROOT / "stacks"
LAN_IP     = "10.0.1.15"

# ── Protocol heuristics ───────────────────────────────────────────────────────
TCP_PORTS   = {3306, 3307, 3308, 5432, 5433, 10051}
HTTPS_PORTS = {443, 8443, 9443}

def proto(hp, cp):
    if cp in TCP_PORTS or hp in TCP_PORTS:  return "tcp"
    if cp in HTTPS_PORTS or hp in HTTPS_PORTS: return "https"
    return "http"

def fmt_url(hp, cp):
    p = proto(hp, cp)
    return "`tcp://` *(non-HTTP)*" if p == "tcp" else f"`http{'s' if p=='https' else ''}://{LAN_IP}:{hp}`"

# ── Human-readable descriptions ───────────────────────────────────────────────
DESCRIPTIONS = {
    "agents_gateway_data:mcp-gateway"       : "MCP tools gateway",
    "code-server:code-server"               : "VS Code in the browser (HTTPS)",
    "code-server:db"                        : "MySQL dev database (TCP only)",
    "code-server:phpmyadmin"                : "phpMyAdmin - MySQL admin UI",
    "codex-docs:codex-docs"                 : "Codex Docs - documentation platform",
    "databases:adminer"                     : "Adminer - shared MariaDB & Postgres admin UI",
    "dozzle:dozzle"                         : "Dozzle - Docker log viewer",
    "github-desktop:github-desktop"         : "GitHub Desktop (KasmVNC container)",
    "grafana-prom:grafana"                  : "Grafana - metrics dashboards",
    "homepage:homepage"                     : "Service portal / dashboard",
    "it-tools:it-tools"                     : "IT Tools - browser-based utility kit",
    "ollama:ollama"                         : "Ollama LLM inference API",
    "ollama:open-webui"                     : "Open WebUI - chat interface for Ollama",
    "openresume:openresume"                 : "OpenResume - resume builder",
    "psu-ots:universal"                     : "PowerShell Universal - NOC dashboard & automation",
    "remotely:remotely"                     : "Remotely - remote desktop / support tool",
    "searxng:searxng"                       : "SearXNG - privacy-first metasearch engine",
    "watchtower:watchtower"                 : "Watchtower - container image update API",
    "zabbix:zabbix-server"                  : "Zabbix server (agent/trap TCP port)",
    "zabbix:zabbix-web"                     : "Zabbix Web UI",
}

# ── Bare-metal / RC-script services (not in any compose.yaml) ─────────────────
BARE_METAL = [
    {"stack": "portainer", "service": "portainer-ce",
     "hp": 9443, "cp": 9443,
     "desc": "Portainer CE - Docker management WebUI (HTTPS)"},
    {"stack": "portainer", "service": "portainer-api",
     "hp": 9000, "cp": 9000,
     "desc": "Portainer CE - HTTP API"},
    {"stack": "dockhand", "service": "dockhand",
     "hp": 3866, "cp": 3000,
     "desc": "Dockhand - git-backed compose stack manager UI"},
]

# ── Resolve a port string that may contain ${VAR:-default} syntax ─────────────
_env_default = re.compile(r'\$\{[^}]+:-(\d+)\}')

def resolve_port(val):
    val = str(val).strip('"\'')
    m = _env_default.search(val)
    if m:
        return int(m.group(1))
    try:
        return int(val.split("/")[0])
    except ValueError:
        return None

# ── Parse compose files ───────────────────────────────────────────────────────
rows = []
for compose_file in sorted(STACKS_DIR.glob("*/compose.yaml")):
    stack = compose_file.parent.name
    if stack.startswith("_"):
        continue  # _haproxy is bare-metal, skip
    try:
        data = yaml.safe_load(compose_file.read_text())
    except Exception:
        continue
    if not data or "services" not in data:
        continue
    for svc_name, svc in (data["services"] or {}).items():
        if not svc or "ports" not in svc:
            continue
        for port in (svc["ports"] or []):
            if isinstance(port, dict):
                host_ip = str(port.get("host_ip", LAN_IP))
                hp = resolve_port(port.get("published", 0))
                cp = resolve_port(port.get("target", 0))
            else:
                parts = str(port).strip('"\'').split(":")
                if len(parts) == 3:
                    host_ip, hp_s, cp_s = parts
                elif len(parts) == 2:
                    host_ip, hp_s, cp_s = LAN_IP, parts[0], parts[1]
                else:
                    continue
                hp = resolve_port(hp_s)
                cp = resolve_port(cp_s)
                if hp is None or cp is None:
                    continue

            # Only include LAN-bound ports
            if host_ip and host_ip not in (LAN_IP, ""):
                continue

            key  = f"{stack}:{svc_name}"
            desc = DESCRIPTIONS.get(key, f"{svc_name} service")
            rows.append({"stack": stack, "service": svc_name,
                         "hp": hp, "cp": cp, "desc": desc, "bare_metal": False})

# ── Merge and sort by host port ───────────────────────────────────────────────
bm_rows = [dict(r, bare_metal=True) for r in BARE_METAL]
all_rows = sorted(bm_rows + rows, key=lambda x: x["hp"])

# ── Render markdown ───────────────────────────────────────────────────────────
lines = [
    "# NAS Service Map",
    "",
    f"> Generated by `scripts/generate-service-map.sh` - {date.today()}  ",
    f"> All URLs are LAN-only (`{LAN_IP}`) unless proxied via Cloudflare Tunnel.",
    "",
    "| Port | Stack | Service | URL | Description |",
    "|-----:|-------|---------|-----|-------------|",
]
for r in all_rows:
    bm  = " *(bare-metal)*" if r["bare_metal"] else ""
    url = fmt_url(r["hp"], r["cp"])
    lines.append(f"| {r['hp']} | {r['stack']}{bm} | {r['service']} | {url} | {r['desc']} |")

lines += [
    "",
    "## Notes",
    "",
    "**TCP-only services** (MySQL on 3307, Zabbix server on 10051) do not serve HTTP -",
    "connect with a native client or tunneled TCP.",
    "",
    "**Portainer** and **Dockhand** are managed by RC scripts (`/usr/local/etc/rc.d/`) and",
    "have no `compose.yaml`. They are included here for completeness.",
    "",
    "**Cloudflare Tunnel** (`cloudflared`, SynoCommunity package) exposes selected services",
    "publicly. All ingress rules must point to `http://10.0.1.15:PORT` - never `localhost`.",
    "",
    "**Regenerate** this file after adding, removing, or changing any port binding:",
    "```bash",
    "bash scripts/generate-service-map.sh",
    "```",
]
print("\n".join(lines))
PYEOF

# ── Write or print ─────────────────────────────────────────────────────────────
if [[ "${STDOUT_ONLY}" -eq 1 ]]; then
    python3 - "${ROOT}" <<'PYEOF'
# (already ran above; re-run for stdout path)
PYEOF
else
    mkdir -p "${ROOT}/docs"
    python3 - "${ROOT}" > "${OUT}"
    echo "Wrote ${OUT}"
fi
