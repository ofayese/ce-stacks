#!/bin/sh
# Optional first-boot gallery install for psu-ots (PowerShell Universal).
# Default image entrypoint: run Universal.Server from /home (see ironmansoftware/universal-docker).

set -eu

if [ "${PSU_GALLERY_INSTALL:-0}" = "1" ]; then
  echo "docker-gallery-entrypoint.sh: PSU_GALLERY_INSTALL=1 — installing gallery modules..."
  pwsh -NoProfile -File /install/Install-PSUGalleryModules.ps1
fi

cd /home
exec ./Universal/Universal.Server "$@"
