# openresume

Self-hosted resume builder ([Open-Resume](https://github.com/xitanggg/open-resume), Next.js). Stateless — all resume data lives in the user's browser localStorage.

## Service

- **openresume** (8889) — Next.js production build
- **Container image:** compose pins **`yuihtt/open-resume@sha256:…`** (digest verified with `docker pull yuihtt/open-resume:latest` + `docker image inspect … RepoDigests[0]` on a trusted host — **2026-05-10**). Re-pin after upgrades using the **same** image name only; never copy a digest from `xitanggg/`, `itsnoted/`, or another namespace unless `docker manifest inspect` proves an identical manifest (it almost never does). See **`docs/hive/COMPOSE_IMAGE_PIN_POLICY.md`**.

## Public hostname

`resume.otsorundscore.olutechsys.com` (via HAProxy stretch when ready; resolved via `extra_hosts` today).

## Health

HTTP 200 on `/`.

## Rollback

```bash
git checkout -- openresume/compose.yaml
docker compose -f openresume/compose.yaml up -d
```

## Note

No persistent state on the server side. Container restarts are zero-data-loss; users keep their drafts in the browser.
