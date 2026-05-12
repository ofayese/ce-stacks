# Ad-hoc terminals (PowerShell Universal)

Use PSU’s **Ad-Hoc Terminals** so operators can open an in-browser shell from the Universal Admin UI instead of a desktop SSH client when triaging NAS alerts.

## Goals

- Terminal sessions run **as** a service account that can read `SSH_KEY_PATH` and reach `NAS_HOST_IP`.
- Operators authenticate to **PSU** (your IdP or local admin); the terminal inherits the configured **Run As** identity.

## Recommended setup

1. **Admin → Settings → Environment** (or **Platform → Settings**, depending on PSU build): enable **Ad-Hoc Terminals** if the toggle exists.
2. **Credentials / Run As**: create or reuse a **secret / credential** that maps to the Linux user inside the `psu-ots` container (or a dedicated sidecar) that:
   - Can read the mounted private key at `SSH_KEY_PATH` (e.g. `/ssh-keys/psu_remediation_key`, mode `600` on the host).
   - Has `ssh` in `PATH` and optional `ssh-agent` if you prefer agent forwarding over raw `-i`.
3. **Default terminal user**: set the Ad-Hoc Terminal profile to **Run As** that credential so every session starts with the right UID/GID for key access.
4. **Operator workflow**: open **Terminal** from the dashboard → `ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "${NAS_SSH_USER}@${NAS_HOST_IP}"` (fill from `.env`). Keep **StrictHostKeyChecking** aligned with remediation (`NAS_SSH_KNOWN_HOSTS_FILE` or accept-new policy you already use).

## Synology / NAS notes

- Prefer **non-interactive** SSH (`BatchMode=yes`) so the in-browser session does not hang on password prompts.
- If DSM blocks root SSH, use a **`NAS_SSH_USER`** that is in `docker` or can run `sudo docker`—match whatever you already validated in `NAS_HOST_SSH_SETUP.md`.

## Related

- Host SSH for jobs: `stacks/psu-ots/NAS_HOST_SSH_SETUP.md`
- Emergency webhook: `POST /api/v1/webhooks/nas-alert` (see `universal/endpoints/dockge-api.ps1`)
