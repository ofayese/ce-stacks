# NAS operator — strict gallery rollout (psu-ots)

Run on the **NAS** from the **git repo root** (e.g. `/volume2/docker/ce-stacks`), not only under `stacks/`.

## 1. Build the gallery image

```bash
cd /volume2/docker/ce-stacks
docker build -t psu-ots:gallery stacks/psu-ots/
```

## 2. Configure `.env`

Edit `stacks/psu-ots/.env` (create from `.env.example` if needed):

- `PSU_GALLERY_INSTALL=1`
- `PSU_GALLERY_INSTALL_STRICT=1`
- `PSU_GALLERY_OPTIONAL=0`

Point compose at the custom image: in `stacks/psu-ots/compose.yaml` (or Dockge YAML override), set `image: psu-ots:gallery` instead of the default digest-pinned Universal image when you are ready to run from this tag.

## 3. Deploy

```bash
cd "${STACK_ROOT}/psu-ots"
docker compose up -d --force-recreate
```

Compose already uses **`docker-gallery-entrypoint.sh`** as the container entrypoint (see `compose.yaml`).

## 4. Validate

```bash
docker compose logs -f
```

Confirm `Install-PSUGalleryModules.ps1` completes, then Universal.Server starts with **no** gallery import errors.

## References

- Full options and module list: [`README.md`](./README.md) (PSU Gallery section).
- Canonical rules: [`AGENTS.md`](../../AGENTS.md) (PSU gallery subsection).
