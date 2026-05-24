#!/bin/sh
# acme-sh Docker secrets entrypoint wrapper (GAP-08)
# Reads CF_Token and DISCORD_WEBHOOK_URL from Docker secret files before
# handing off to the real acme.sh process. This keeps credentials out of
# `docker inspect` Env output while still making them available to acme.sh.
#
# Secret files are mounted by Docker at /run/secrets/<name> with mode 0400.
# Populate them on the NAS:
#   echo "YOUR_CLOUDFLARE_TOKEN" > stacks/acme-sh/secrets/cf_token.txt
#   echo "YOUR_DISCORD_WEBHOOK"  > stacks/acme-sh/secrets/discord_webhook_url.txt
#   chmod 600 stacks/acme-sh/secrets/*.txt

set -e

if [ -f /run/secrets/cf_token ]; then
    # Strip trailing whitespace/newlines - common editor artifact
    CF_Token="$(cat /run/secrets/cf_token | tr -d '[:space:]')"
    export CF_Token
    echo "[entrypoint] CF_Token loaded from Docker secret (${#CF_Token} chars)"
else
    echo "[entrypoint] WARNING: /run/secrets/cf_token not found - CF_Token not set" >&2
fi

if [ -f /run/secrets/discord_webhook_url ]; then
    DISCORD_WEBHOOK_URL="$(cat /run/secrets/discord_webhook_url | tr -d '[:space:]')"
    export DISCORD_WEBHOOK_URL
    echo "[entrypoint] DISCORD_WEBHOOK_URL loaded from Docker secret"
else
    echo "[entrypoint] INFO: /run/secrets/discord_webhook_url not found - notifications disabled"
fi

# Intercept the 'daemon' command to run the Alpine cron daemon in the foreground.
# This replicates the official image behavior so renewals happen automatically.
if [ "$1" = "daemon" ]; then
    echo "[entrypoint] Starting crond in foreground for automatic renewals..."
    exec crond -f
else
    exec acme.sh "$@"
fi