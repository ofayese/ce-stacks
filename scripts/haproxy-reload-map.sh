#!/usr/bin/env bash
# =============================================================================
# haproxy-reload-map.sh -- live-reload host.map into running HAProxy
# =============================================================================
# Sends a Runtime API command to HAProxy to reload the host.map file from disk
# without a full restart. Zero downtime, no connection drops.
#
# HAProxy 3.x supports hot-reloading map files via the admin socket:
#   echo "set map <path>" | socat stdio <socket>
#
# Usage:
#   bash /volume2/docker/ce-stacks/scripts/haproxy-reload-map.sh
#   bash /volume2/docker/ce-stacks/scripts/haproxy-reload-map.sh --dry-run
#
# Wire this into git post-merge or Dockhand webhooks to auto-apply map changes:
#   # .git/hooks/post-merge
#   #!/bin/sh
#   if git diff-tree -r --name-only --no-commit-id ORIG_HEAD HEAD | grep -q '_haproxy/maps/'; then
#       bash /volume2/docker/ce-stacks/scripts/haproxy-reload-map.sh
#   fi
#
# Note: This reloads map entries only. Adding a new *backend* block still
# requires a full config paste + Stop/Start via DSM Package Center.
# =============================================================================

set -euo pipefail

SOCKET="/var/packages/haproxy/var/run/haproxy.sock"
MAP="/volume2/docker/ce-stacks/stacks/_haproxy/maps/host.map"
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "haproxy-reload-map: unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

# ---- Preflight ---------------------------------------------------------------

if [ ! -S "$SOCKET" ]; then
    echo "haproxy-reload-map: ERROR: socket not found at $SOCKET" >&2
    echo "haproxy-reload-map: is HAProxy running? Check DSM Package Center." >&2
    exit 1
fi

if [ ! -f "$MAP" ]; then
    echo "haproxy-reload-map: ERROR: map file not found at $MAP" >&2
    exit 1
fi

if ! command -v socat >/dev/null 2>&1; then
    echo "haproxy-reload-map: ERROR: socat not found" >&2
    echo "haproxy-reload-map: install via: sudo opkg install socat" >&2
    exit 1
fi

ENTRY_COUNT=$(grep -c '^[^#]' "$MAP" 2>/dev/null || echo 0)
echo "haproxy-reload-map: map: $MAP ($ENTRY_COUNT entries)"
echo "haproxy-reload-map: socket: $SOCKET"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "haproxy-reload-map: DRY RUN -- would run: echo 'set map $MAP' | socat stdio $SOCKET"
    exit 0
fi

# ---- Reload ------------------------------------------------------------------

RESULT=$(echo "set map $MAP" | socat stdio "$SOCKET" 2>&1 || true)

if [ -n "$RESULT" ]; then
    echo "haproxy-reload-map: ERROR: HAProxy returned: $RESULT" >&2
    exit 1
fi

echo "haproxy-reload-map: host.map reloaded OK ($ENTRY_COUNT entries active)"
