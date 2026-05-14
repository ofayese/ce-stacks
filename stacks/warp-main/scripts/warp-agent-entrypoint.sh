#!/bin/sh
# warp-agent Docker secrets entrypoint wrapper (GAP-08)
# Reads WARP_API_KEY from a Docker secret file, keeping it out of
# `docker inspect` Env output.
#
# Populate on the NAS:
#   echo "wk-YOUR_WARP_API_KEY" > stacks/warp-main/secrets/warp_api_key.txt
#   chmod 600 stacks/warp-main/secrets/warp_api_key.txt

set -e

if [ -f /run/secrets/warp_api_key ]; then
    WARP_API_KEY="$(cat /run/secrets/warp_api_key | tr -d '[:space:]')"
    export WARP_API_KEY
    echo "[warp-entrypoint] WARP_API_KEY loaded from Docker secret (${#WARP_API_KEY} chars)"
else
    echo "[warp-entrypoint] ERROR: /run/secrets/warp_api_key not found" >&2
    echo "[warp-entrypoint] Create: echo 'wk-...' > stacks/warp-main/secrets/warp_api_key.txt" >&2
    exit 1
fi

# Delegate to the original image entrypoint.
# The warp-agent image uses its own entrypoint; use exec to replace this shell.
exec "$@"
