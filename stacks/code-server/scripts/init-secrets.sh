#!/bin/sh
# init-secrets.sh - linuxserver s6-overlay v3 custom-cont-init hook (GAP-08)
#
# HOW THIS WORKS:
#   linuxserver images with s6-overlay v3 execute all scripts under
#   /custom-cont-init.d/ *before* the supervised services start.
#   Writing a value to /var/run/s6/container_environment/<VAR_NAME>
#   causes s6 to export that variable into every supervised process,
#   including the code-server process - without ever appearing in
#   `docker inspect CodeServer` Env output.
#
# POPULATE ON NAS:
#   echo "YOUR_PASSWORD"      > stacks/code-server/secrets/code_server_password.txt
#   echo "YOUR_SUDO_PASSWORD" > stacks/code-server/secrets/sudo_password.txt
#   chmod 600 stacks/code-server/secrets/*.txt

set -e

S6_ENV_DIR="/var/run/s6/container_environment"

inject_secret() {
    local secret_name="$1"
    local env_var="$2"
    local secret_file="/run/secrets/${secret_name}"

    if [ -f "$secret_file" ]; then
        # Strip trailing whitespace/newlines - common editor artifact
        printf '%s' "$(cat "$secret_file" | tr -d '[:space:]')" > "${S6_ENV_DIR}/${env_var}"
        echo "[init-secrets] ${env_var} injected from Docker secret ($(wc -c < "${S6_ENV_DIR}/${env_var}") chars)"
    else
        echo "[init-secrets] WARNING: ${secret_file} not found - ${env_var} not injected" >&2
    fi
}

inject_secret "code_server_password" "PASSWORD"
inject_secret "sudo_password"        "SUDO_PASSWORD"
