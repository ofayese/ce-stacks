# github-desktop

GitHub Desktop (LinuxServer.io image) in a **browser** via **KasmVNC** — useful when you want to clone, commit, and push the Dockge repo **without SSH** to the NAS.

## Overview

The container runs GitHub Desktop (Electron) inside KasmVNC. Persistent state lives only under **`${STACK_ROOT}/github-desktop/config`** (mapped to `/config`).

## Access

- Direct: `https://<NAS_IP>:3405` (or whatever you set **`GITHUB_DESKTOP_PORT`** in `.env`).
- Or put **Synology Reverse Proxy** / your edge TLS in front of that host port.

Copy **`.env.example`** → **`.env`** and set **`GITHUB_DESKTOP_USER`**, **`GITHUB_DESKTOP_PASSWORD`**, and optional **`GITHUB_DESKTOP_PORT`**.

## Volumes

| Host path                             | Purpose                                          |
| ------------------------------------- | ------------------------------------------------ |
| `${STACK_ROOT}/github-desktop/config` | All linuxserver / GitHub Desktop + KasmVNC state |

There is **no** separate `data/` bind in the default `compose.yaml`; manifest uses **`github-desktop:config`** only.

## Permissions

**`PUID` / `PGID`** default to **root (`0`/`0`)** on the NAS (same as other stacks). Override in `.env` for local Linux dev if needed.

**Security Advisor** will flag **`seccomp:unconfined`** and **`IPC_LOCK`** — both are **required** for Electron/KasmVNC and are **intentional**. This stack **does not** set **`no-new-privileges:true`**: Chromium/Electron relies on a setuid sandbox helper, which is blocked when `PR_NO_NEW_PRIVS` is set (common failure on Synology without user-namespace sandbox fallbacks). See **`docs/hive/NAS_DEPLOYMENT.md`** → **Security Advisor warnings**.

## Use case in this repo

Use this stack when you want to **work on the Dockge stacks repo from the NAS browser**: clone to `/config`-visible paths, commit, and **push** to your remote (e.g. GitHub) without opening an SSH session on the NAS.

## Healthcheck

**Type B — TCP** on **`127.0.0.1:3000`** inside the container (KasmVNC listener). **`start_period: 90s`** allows Electron cold start.

## Deploy

```bash
cp .env.example .env
# edit .env — set GITHUB_DESKTOP_USER, GITHUB_DESKTOP_PASSWORD
docker compose up -d
```

## Rollback

```bash
git checkout -- compose.yaml
docker compose down
```
