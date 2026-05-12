# Extend pinned PowerShell Universal image with Dockge gallery modules baked in.
# Build (from repo stack folder):
#   docker build -t psu-ots:gallery --build-arg BASE_IMAGE=ironmansoftware/universal@sha256:069b858b0f010d522144745ac918cc12c8ea022d516f011fe7e2596efc3a03c4 .
# Compose: set image: psu-ots:gallery (or your registry path).

ARG BASE_IMAGE=ironmansoftware/universal@sha256:069b858b0f010d522144745ac918cc12c8ea022d516f011fe7e2596efc3a03c4
FROM ${BASE_IMAGE}

USER root
COPY universal/scripts/Import-PSUGalleryModules.ps1 /tmp/dockge-psu/
COPY universal/scripts/Install-PSUGalleryModules.ps1 /tmp/dockge-psu/

ENV PSU_GALLERY_OPTIONAL=0 \
    PSU_GALLERY_INSTALL_STRICT=1

RUN pwsh -NoProfile -Command "\
  Set-Location /tmp/dockge-psu; \
  & ./Install-PSUGalleryModules.ps1; \
  if (\$LASTEXITCODE -ne 0) { exit \$LASTEXITCODE }"

WORKDIR /home
