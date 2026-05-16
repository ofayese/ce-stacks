# acme-sh

Containerized acme.sh in daemon mode — issues and renews TLS certificates via Cloudflare DNS-01.

## Operating posture

- `network_mode: host` (required for ACME challenges; do not change)
- `command: daemon` — runs `acme.sh --cron` indefinitely; renewals every 60 days by default

## Volumes

| Host path                                | Container path        | Mode | Created by    |
| ---------------------------------------- | --------------------- | ---- | ------------- |
| `${STACK_ROOT}/acme-sh/data`             | `/acme.sh`            | rw   | `init-nas.sh` |
| `${ACME_CERT_ROOT:-/volume2/certs/acme}` | `/volume2/certs/acme` | rw   | operator      |

> Run `sudo bash scripts/init-nas.sh` after cloning to create these
> directories. Without them, the container will fail to start.

Installed PEMs under `${ACME_CERT_ROOT:-/volume2/certs/acme}` are consumed by other stacks; **do not modify directly**.

## Post-issue deploy + verify (HAProxy)

- **`acme-sh/scripts/deploy_certs.sh`** — host-run: PEM → combined bundles deployed directly to **`HAPROXY_CERT_STAGE_DIR`** (default **`/var/packages/haproxy/var/crt/`** — Synology HAProxy package cert directory, created if missing); optional **`haproxy -c`** when that dir matches **`LIVE_HAPROXY_CERT_DIR`**. Does not reload HAProxy — operator must reload via DSM package UI after validation. See **`SETUP.md`** §7.
- **`acme-sh/scripts/verify_serving.sh`** — fail-closed OpenSSL SNI check (optional Discord on failure via **`DISCORD_WEBHOOK_URL`**).

## Required env (`.env`, gitignored)

- `STACK_ROOT` — absolute path to the stacks folder (same as repo `stacks/` on disk), e.g. `${STACK_ROOT}`
- `CF_Token` — Cloudflare API token with `Zone.DNS Edit` on `olutechsys.com` and `olutech.systems`
- `DISCORD_WEBHOOK_URL` — optional; renewal notifications

See `.env.example` for the full set.

### Where you run `docker compose` matters

Variable substitution for `compose.yaml` uses the **default `.env` in your shell’s current directory**, not automatically `acme-sh/.env` when you pass `-f acme-sh/compose.yaml` from the parent `stacks/` folder.

- **Recommended:** `cd "${STACK_ROOT}/acme-sh"` then `sudo docker compose up -d` (picks up `./.env` next to `compose.yaml`).
- **From `stacks/`:** `sudo docker compose --env-file acme-sh/.env -f acme-sh/compose.yaml up -d` (only after `acme-sh/.env` exists on that machine — see below)

A `.env` file that only exists under `acme-sh/` will still produce “not set” warnings if Compose never loads it (wrong cwd, no `--env-file`).

### “Couldn't find env file: …/acme-sh/.env”

That path is **not** created by `git pull`: `.env` is gitignored. On the NAS (or any host), create it once next to `compose.yaml`:

```bash
cd "${STACK_ROOT}/acme-sh"
test -f .env || cp .env.example .env || sudo cp .env.example .env
# edit .env (CF_Token, STACK_ROOT, etc.) — if the copy was done with sudo, see below
sudo docker compose up -d
```

If you passed `--env-file` to a path that does not exist yet, Compose fails hard — either create that file first or drop `--env-file` until you have copied and filled `.env`.

### Permission denied creating `.env` (`cp: cannot create regular file '.env'`)

If `ls -ld .` shows **`root`** (or another user) as owner and the mode is not group/world-writable, your account cannot create new files there. Use **`sudo cp`** — the command name is **`cp`**, not the source file:

```bash
sudo cp .env.example .env
sudo chown "$(id -un)":"$(id -gn)" .env   # optional: own the file so you can edit without sudo
```

Then edit `.env` and run `sudo docker compose up -d` as usual. (Parent `stacks/` may be yours while this folder was created or normalized as **`root`** — that mismatch is normal on DSM.)

## Health

No probe (host networking + daemon mode → no meaningful liveness probe). Verify health by:

- `docker logs AcmeSh --tail 50` — recent cron ticks
- `ls -la /volume2/certs/acme/<domain>/` — PEMs newer than 90 days
- `docker exec AcmeSh acme.sh --list` — issued certs and expiry dates

## Authoritative references

- [AGENTS.md](AGENTS.md) — local lessons learned (rename pattern, dockerized issue flow, validation)
- [SETUP.md](SETUP.md) — issue/install procedure; legacy `deploy-*.bash` runbooks in [`archive/`](archive/)
- README.md — repo-wide guardrails

## Rollback

```bash
git checkout -- compose.yaml   # run from inside acme-sh/
sudo docker compose up -d
```

Cert issuance state is on disk — survives container rebuild.
