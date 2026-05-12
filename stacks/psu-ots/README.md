# psu-ots — PowerShell Universal (NAS command center)

PowerShell Universal provides **scheduled jobs**, **API endpoints**, and a **NOC dashboard** over the Dockge monorepo bind (`/nas-repo`) and ACME PEMs (`/certs/acme`).

## Prerequisites

- **TLS:** Host-named wildcard PEMs under `${ACME_CERT_ROOT}/otsorundscore/` (OTS NAS) per [`docs/hive/SERVICE_MAP.md`](../../docs/hive/SERVICE_MAP.md). Traefik rule in compose: `psu.otsorundscore.olutechsys.com`.
- **Network:** `traefik-ots` stack must exist (external Docker network `traefik-ots`).
- **DNS:** Public + split-horizon records for `psu.otsorundscore.olutechsys.com` (and `.olutech.systems` if used).

## First deploy

```bash
cd "${STACK_ROOT}/psu-ots"
cp .env.example .env
# set DOCKGE_USERNAME / DOCKGE_PASSWORD for API checks; optional NAS_PULL_APP_TOKEN for future webhook
docker compose up -d
```

Admin UI: `https://psu.otsorundscore.olutechsys.com` (via Traefik) or publish host port temporarily for bootstrap.

## Repository layout

Versioned PSU config lives under **`data/Repository/`** on the NAS (`.universal/*.ps1`, `Scripts/`, `Apps/`). Runtime DB files under `data/` are gitignored.

**Git-tracked templates:** copy [`universal/`](./universal/) into `data/Repository/.universal/` after first deploy (root `.gitignore` ignores `stacks/**/data/`, so templates ship beside the stack instead of under `data/`).

## Authentication

Interactive PSU Admin login uses **PowerShell Universal defaults** from the image unless you configure auth inside PSU (e.g. OpenID in Admin) per [PowerShell Universal — OpenID Connect](https://docs.powershelluniversal.com/config/security/openid-connect). This repo’s tracked **`compose.yaml`** does **not** inject OIDC env. **Google Workspace → DSM** (NAS login portal only) is separate — see [`docs/hive/GOOGLE_WORKSPACE_OAUTH_NAS_LOGIN.md`](../../docs/hive/GOOGLE_WORKSPACE_OAUTH_NAS_LOGIN.md).

**APIs:** **`PSU_AUTH_TOKEN`**, **`DOCKGE_USERNAME`** / **`DOCKGE_PASSWORD`**, and **`NAS_PULL_APP_TOKEN`** power jobs, Dockge API, and webhooks — see **`universal/endpoints/dockge-api.ps1`**.

## Security notes

- **`/nas-repo` is `:ro` in compose** — change to `:rw` only if you implement `git pull` from PSU and accept NAS git hygiene rules ([`AGENTS.md`](../../AGENTS.md)).
- **`POST /api/v1/nas/pull`:** Ship as a follow-up in Admin (App Token + role). **`GET /api/v1/nas/health`** (Phase 2) is registered in `universal/endpoints/dockge-api.ps1` and returns the latest NAS + latency JSON reports (**Bearer `PSU_AUTH_TOKEN`** required).

## Automation

| Script                      | Purpose                                            |
| --------------------------- | -------------------------------------------------- |
| `NAS-Fix-Permissions`       | Runs `fix-permissions.sh` against `PSU_STACK_ROOT` |
| `NAS-Check-Dockge-Status`   | Runs `check-dockge-http.sh`                        |
| `NAS-Detect-Config-Drift`   | `git status` drift hints                           |
| `NAS-Validate-SSL-Certs`    | OpenSSL notAfter on `fullchain.pem`                |
| `NAS-Monitor-Dockge-Stacks` | Dockge API inventory (needs credentials)           |

### Phase 2 — templates under `universal/`

Git-tracked PowerShell templates (copy into `data/Repository/.universal/` on the NAS):

| Path | Role |
|------|------|
| `universal/scripts/dockge-jobs.ps1` | Background jobs **A–G** + backup + **`Invoke-PSUJob_AutoRemediation`** / **`Invoke-PSUJob_GitOpsSync`**. Each `Invoke-PSUJob_*` queues `Start-Job` and writes timestamped JSON under `PSU_REPORTS_ROOT` (default `/data/reports`) with **48h** retention. |
| `universal/endpoints/dockge-api.ps1` | Registers `/api/v1/*` routes; enforces **`Authorization: Bearer`** vs **`PSU_AUTH_TOKEN`**. Optional: `PSU_ALLOW_STACK_RESTART`, `PSU_REMEDIATION_ENABLED`, `PSU_GITOPS_ENABLED`. |
| `universal/endpoints/dockge-endpoints.ps1` | Dot-sources `dockge-api.ps1` (single entry for the `endpoints/` folder). |
| `universal/dashboards/dockge-compliance.ps1` | NOC panels **A–G** (UD auto-refresh) backed by the JSON reports above. |
| `universal/scripts/Import-PSUGalleryModules.ps1` | **Required** gallery import (throws unless `PSU_GALLERY_OPTIONAL=1`). |
| `universal/scripts/Install-PSUGalleryModules.ps1` | Downloads modules from PSGallery (`Install-PSResource` / `Install-Module`); used by **`PSU_GALLERY_INSTALL=1`** and **`Dockerfile`**. |
| `scripts/docker-gallery-entrypoint.sh` | Compose **entrypoint** wrapper: optional install, then `exec ./Universal/Universal.Server` (matches upstream image). |

**Operational notes:** the PSU container does **not** mount `docker.sock`. **`Invoke-PSUJob_AutoRemediation`** runs **`docker compose pull && up -d`** and **`docker image prune -a -f`** on the **NAS host over SSH** when **`NAS_HOST_IP`**, **`NAS_SSH_USER`**, **`SSH_KEY_PATH`**, and **`NAS_HOST_STACKS_ROOT`** are set (see **`NAS_HOST_SSH_SETUP.md`**). **Trivy** / **SMART** probes run only when those tools exist in the image or on the host bind. **`POST /api/v1/gitops/sync`** queues `Invoke-PSUJob_GitOpsSync` when **`PSU_GITOPS_ENABLED=1`** and `/nas-repo` is writable; **`POST /api/v1/provision/stack`** and **`POST /api/v1/restore/request`** remain **501** placeholders.

**Advanced remediation (optional env in `.env.example`):** when **`PSU_SAFE_MODE_ENABLED=1`**, degraded **`mdstat`** / btrfs uncorrectable signals in the latest **nas-health** JSON trigger **Safe Mode** (compose `stop` on **`PSU_SAFE_MODE_STOP_STACKS`**, optional **`Invoke-PSUJob_BackupSnapshot`** queue, webhooks via **`PSU_SAFE_MODE_WEBHOOK_URL`** / **`PSU_SAFE_MODE_DISCORD_WEBHOOK`**). When **`PSU_REMEDIATION_CPU_TRIAGE=1`** and load/memory thresholds breach, the job runs **`top`** + **`docker stats`** over **`Invoke-PSUHostSsh`** and may **`docker compose restart`** high-CPU compose services (**requires `PSU_ALLOW_STACK_RESTART=1`**). **`POST /api/v1/webhooks/nas-alert`** queues the same remediation job immediately for Synology-style outbound alerts (**`PSU_NAS_ALERT_WEBHOOK_TOKEN`** + `X-PSU-Nas-Alert-Token`, or Bearer, else **`PSU_AUTH_TOKEN`**). In-browser SSH triage: **`PSU_ADHOC_TERMINALS.md`**.

### PSU Gallery modules (required by default)

`Import-PSUGalleryModules` loads every module in **`Get-DockgePSUGalleryModuleNames`**. Unless **`PSU_GALLERY_OPTIONAL=1`**, a failed import **throws** (dashboard/endpoints/jobs fail fast). Use optional mode only while staging; do not leave it on in production if you rely on gallery behavior.

| Area | Modules (Linux set) |
|------|----------------------|
| Dashboard UX | `Universal.Utilities.Apps`, `Universal.Components.Loader` |
| Notifications / triggers | `Universal.Notifications`, `PowerShellUniversal.Triggers.Email`, `PowerShellUniversal.Triggers.Discord` |
| Monitoring / API | `PowerShellUniversal.API.Monitoring`, `PowerShellUniversal.API.System` |
| Health checks | `PowerShellUniversal.HealthCheck.InternetAccess`, `PowerShellUniversal.HealthCheck.ExcessiveRunspaces` |
| Network / certs | `Universal.Apps.NetworkUtilities`, `PowerShellUniversal.Apps.NetworkUtilities`, `PowerShellUniversal.Apps.LetsEncrypt` |
| DB / tests | `PowerShellUniversal.API.dbatools`, `PowerShellUniversal.Apps.Pester` |
| Utilities | `PowerShellUniversal.Scripts`, `PowerShellUniversal.Apps.Tools`, `PowerShellUniversal.API.PSResourceGet`, `PowerShellUniversal.Plaster`, `PowerShellUniversal.Apps.Cookbook`, `PowerShellUniversal.Apps.Random` |
| Identity | `Universal.Apps.ActiveDirectory`, `PowerShellUniversal.Roles.ActiveDirectory` |

**Windows-only add-ons** (set **`PSU_GALLERY_INCLUDE_WINDOWS=1`** for install/import lists): `PowerShellUniversal.Apps.TaskManager`, `PowerShellUniversal.Apps.Services`, `PowerShellUniversal.Apps.AutomatedLab`, `Universal.Apps.WindowsSystemInformation`.

**Three ways to satisfy strict import**

1. **Bake into an image** — from `stacks/psu-ots/`: `docker build -t psu-ots:gallery .` then point compose `image:` at `psu-ots:gallery` (see **`Dockerfile`**; uses the same digest as compose by default).
2. **Download on container start** — set **`PSU_GALLERY_INSTALL=1`** in `.env` (compose mounts **`scripts/docker-gallery-entrypoint.sh`** and runs **`Install-PSUGalleryModules.ps1`** before Universal.Server). Requires outbound HTTPS to PSGallery. **`PSU_GALLERY_INSTALL_STRICT=0`** allows partial install (import may still fail until all modules resolve).
3. **Manual / PSU Admin** — install the same module names under the PSU modules path, or set **`PSU_GALLERY_OPTIONAL=1`** only until (1) or (2) is done.

Ensure `chmod +x stacks/psu-ots/scripts/docker-gallery-entrypoint.sh` on the host so the bind-mounted script is executable.

**NAS rollout checklist:** [`GALLERY_ROLLOUT_NAS.md`](./GALLERY_ROLLOUT_NAS.md).

**API:** `GET /api/v1/psu/gallery-modules` (Bearer **`PSU_AUTH_TOKEN`**) returns import rows. **Jobs:** JSON reports include **`galleryModulesLoaded`** after a successful import in the worker.

**References:** [PowerShell Universal Gallery](https://powershelluniversal.com/gallery), [ironmansoftware/universal-modules](https://github.com/ironmansoftware/universal-modules). **Community templates:** GitHub search `powershell universal dashboard` / `ironmansoftware` for chart ideas (keep attribution if you vendor snippets).

## Image pin

Default: `ironmansoftware/universal@sha256:069b858b0f010d522144745ac918cc12c8ea022d516f011fe7e2596efc3a03c4` — tag `2026.1.6-ubuntu-24.04`. Re-resolve digest when upgrading. If you build **`Dockerfile`**, tag and pin that image instead.
