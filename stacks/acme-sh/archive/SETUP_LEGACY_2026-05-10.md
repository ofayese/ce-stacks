# Archived excerpts from `SETUP.md` (2026-05-10)

Material moved out of the live **[`../SETUP.md`](../SETUP.md)** because it duplicates the Dockge-first flow or documents **legacy per-host `deploy-*.bash`** paths. **Current operator path:** [Deploy acme-sh end-to-end](../SETUP.md#deploy-acme-sh-end-to-end-checklist) and **`../scripts/deploy_certs.sh`** per **`docs/hive/proposals/acme-sh/ACME_DEPLOY_HOOK_ADR.md`**.

Anchor for downstream links: **mTLS bundle section** → heading below (`<a id="mtls-bundle-reference"></a>`).

---

## Duplicate quickstart (removed from main `SETUP.md`)

The canonical checklist is **Deploy acme-sh end-to-end** in `SETUP.md`. The following was redundant.

## Prerequisites

1. Fill in `.env` (Cloudflare API token, Discord webhook)
2. Cloudflare API token: `Zone > DNS > Edit` for **both** `olutechsys.com`
   and `olutech.systems`
3. Container started at least once so the acme.sh data volume is initialised

---

## First-time setup duplicate (removed from main `SETUP.md`)

## First-time setup

### 1. Start the container

```bash
cd /volume1/​docker/dockge​/stacks/acme-sh
docker compose up -d
```

### 2. Enable Discord notifications

```bash
sudo docker exec AcmeSh acme.sh --set-notify --notify-hook discord
```


---

<a id="mtls-bundle-reference"></a>

## Deploy to each device

Run the relevant script from each device after the cert files appear in
`/volume1/certs/acme/`. Re-run these whenever you want to push a renewed cert.

### otsorundscore — stage on Mac, upload, apply on NAS

`deploy-otsorundscore.bash` **only builds** `otsorundscore-nas-upload/` under your acme tree
(e.g. `/Volumes/certs/acme/otsorundscore-nas-upload/`). It does not SSH into the NAS.

```bash
bash /Volumes/certs/acme/deploy-otsorundscore.bash
```

Zip or copy that folder to the NAS (File Station, `scp`, etc.), then as **root** on
otsorundscore: copy the staged `dsm-*` and `docker-tls/` PEMs into the DSM and Docker paths
shown in the script header, merge TLS into `/volume1/​docker/daemon.json`, reload nginx,
and restart Container Manager.

**First run only — apply the full Docker daemon config.** The bundled
`daemon-tls.json` binds Docker TCP to **`tcp://127.0.0.1:2376` (loopback
only)** by default — the safe, no-LAN-exposure posture. SSH context
access (`docker context … ssh://…`) uses the Unix socket on the NAS and
is unaffected by this bind. **If you actually need narrow LAN TCP** for
this otsorundscore host (and SSH is not enough), edit `hosts` to
`tcp://10.0.1.15:2376` **before** merge and pair it with mTLS plus a
firewall rule restricting `:2376` to the trusted client subnet. Use a
temp file and atomic `mv` to update `daemon.json`; piping
`jq ... | tee daemon.json` is unsafe because the same file is on both
sides of the pipeline.

```bash
# On otsorundscore, as root:
sudo cp -n /volume1/​docker/daemon.json /volume1/​docker/daemon.json.bak
TMP=$(sudo mktemp /volume1/​docker/.daemon.json.XXXXXX)
sudo jq -s '.[0] * .[1]' \
  /volume1/​docker/daemon.json \
  /volume1/certs/acme/daemon-tls.json > "${TMP}"
sudo mv -f "${TMP}" /volume1/​docker/daemon.json
sudo synopkg restart ContainerManager
```

If `daemon.json` doesn't exist yet:

```bash
sudo install -m 0644 /volume1/certs/acme/daemon-tls.json /volume1/​docker/daemon.json
sudo synopkg restart ContainerManager
```

### otsorundscore — Docker mTLS bundle (parallel path, non-destructive)

The TLS-only path above remains valid. For hardened mTLS, use the dedicated
`docker-mtls/` PKI subtree and mTLS daemon config.

**Input validation:** `docker-mtls-issue-*.bash` and `deploy-otsorundscore-mtls.bash`
validate **CLIENT_NAME**, **HOSTNAME** / **DOCKER_HOSTNAME**, and comma-separated
**SAN_DNS_EXTRA** / **SAN_IPS** (DNS labels or FQDNs; IPv4 literals only; no `/`,
`..`, whitespace, or control characters). Invalid values exit with an explicit
`ERROR:` message. Shared rules live in `docker-mtls-input-validate.bash` next to
the issue scripts.

**Single-threaded issuance (same CA):** `docker-mtls-issue-client.bash` and
`docker-mtls-issue-server.bash` both update the shared OpenSSL `-CAserial` file
under `docker-mtls/ca/serial`. **Do not run two issue scripts at the same time**
against the same `MTLS_DIR` / `docker-mtls/` tree. While signing, each script
acquires an exclusive `mkdir` lock at `docker-mtls/ca/.issue.lock` (portable on
macOS and Linux); a second process waits up to ~5 minutes, then exits with an
error instead of corrupting the serial. For batch issuance, run the commands
**sequentially** in one shell or a script — do not background multiple issue
invocations against one CA. The lock and serial bootstrap are implemented in
`docker-mtls-issue-common.bash` (sourced by both issue scripts).

1. Initialize a private CA once:

```bash
bash /volume1/certs/acme/docker-mtls-init-ca.bash
```

1. Issue one server cert per Docker daemon hostname:

```bash
HOSTNAME=otsorundscore.olutechsys.com \
  SAN_IPS=10.0.1.15 \
  bash /volume1/certs/acme/docker-mtls-issue-server.bash
```

1. Issue one client cert per user/device:

```bash
CLIENT_NAME=otsmbpro16 bash /volume1/certs/acme/docker-mtls-issue-client.bash
CLIENT_NAME=hpdevcore bash /volume1/certs/acme/docker-mtls-issue-client.bash
```

1. Stage NAS upload bundle (Mac or any mounted host):

```bash
DOCKER_HOSTNAME=otsorundscore.olutechsys.com \
  bash /Volumes/certs/acme/deploy-otsorundscore-mtls.bash
```

1. On otsorundscore (as root), apply mTLS daemon config (atomic temp-file
   merge — never `jq | tee daemon.json` against the same file):

```bash
mkdir -p /volume1/​docker/mtls
chmod 0700 /volume1/​docker/mtls
install -m 0644 /volume1/certs/acme/otsorundscore-nas-upload-mtls/docker-mtls/ca.pem          /volume1/​docker/mtls/ca.pem
install -m 0644 /volume1/certs/acme/otsorundscore-nas-upload-mtls/docker-mtls/server-cert.pem /volume1/​docker/mtls/server-cert.pem
install -m 0400 /volume1/certs/acme/otsorundscore-nas-upload-mtls/docker-mtls/server-key.pem  /volume1/​docker/mtls/server-key.pem

# docker-daemon-mtls.json updates tls/tlsverify/tlscacert/tlscert/tlskey only.
# It intentionally does NOT set `hosts`; existing listener values are preserved.
cp -n /volume1/​docker/daemon.json /volume1/​docker/daemon.json.bak
TMP=$(mktemp /volume1/​docker/.daemon.json.XXXXXX)
jq -s '.[0] * .[1]' \
  /volume1/​docker/daemon.json \
  /volume1/certs/acme/otsorundscore-nas-upload-mtls/docker-daemon-mtls.json > "${TMP}"
mv -f "${TMP}" /volume1/​docker/daemon.json
synopkg restart ContainerManager
```

> If you also need to enforce a specific `hosts` value from the reference file,
> merge `daemon-mtls.json` directly (or edit `daemon.json` manually) before restart.
> Example to enforce loopback-only:
>
> ```bash
> TMP=$(mktemp /volume1/​docker/.daemon.json.XXXXXX)
> jq -s '.[0] * .[1]' \
>   /volume1/​docker/daemon.json \
>   /volume1/certs/acme/daemon-mtls.json > "${TMP}"
> mv -f "${TMP}" /volume1/​docker/daemon.json
> synopkg restart ContainerManager
> ```
>
> The bundled `daemon-mtls.json` defaults to the same loopback bind
> (`tcp://127.0.0.1:2376`). With mTLS plus a narrow LAN bind
> (`tcp://10.0.1.15:2376`), only clients holding a cert signed by your
> lab CA can authenticate; still firewall `:2376` to trusted subnets.
> Prefer SSH context for admin access whenever possible. misfitsds
> (`10.0.1.24`) uses `deploy-misfitsds.bash` for DSM certs only — there
> is no Docker daemon TLS bundle for misfitsds in this tree unless you
> add one separately.

### misfitsds — SSH in, provide cert source

`deploy-misfitsds.bash` still runs **on misfitsds**. It needs `wildcard/` and
`misfitsds-sub/` under `SOURCE_DIR` — same layout as on the otsorundscore share or your Mac.
See the script header for the **Mac staging flow for otsorundscore** vs **misfitsds**
options (mount, rsync/scp placeholders).

```bash
ssh YOUR_USER@misfitsds

# Example: share already mounted at SOURCE_DIR
SOURCE_DIR=/mnt/your-acme-mount/acme bash /volume1/certs/acme/deploy-misfitsds.bash

# Example: copy dirs into /tmp/acme first, then run
SOURCE_DIR=/tmp/acme bash /volume1/certs/acme/deploy-misfitsds.bash
```

### otsmbpro16 — run on the Mac (NAS already mounted)

```bash
# From the acme directory so default SOURCE_DIR resolves to ./otsmbpro16/
cd /Volumes/certs/acme && bash ./deploy-otsmbpro16.bash
```

PEMs install to **`~/certs/otsmbpro16/`** by default (`DEST_DIR` override optional).
The script removes old `~/.docker/cert.pem` / `key.pem` and writes `~/.docker/ca.pem`
from `wildcard/chain.pem` (the Docker CLI still opens `ca.pem` when
`DOCKER_TLS_VERIFY=1`). After running, connect to Docker with:

```bash
# If otsorundscore.olutechsys.com is Cloudflare-proxied, public DNS points at CF
# (172.67.x.x) and :2376 times out — CF does not forward Docker TLS to the NAS.
#
# Best fix on the Mac: map the hostname to your NAS LAN IP (cert still matches), e.g.:
#   sudo sh -c 'echo "YOUR_NAS_LAN_IP otsorundscore.olutechsys.com" >> /etc/hosts'
# Then:
export DOCKER_HOST=tcp://otsorundscore.olutechsys.com:2376
export DOCKER_TLS_VERIFY=1
docker info
```

Using `DOCKER_HOST=tcp://YOUR_NAS_LAN_IP:2376` alone can fail TLS hostname checks (the
leaf is for `*.olutechsys.com`, not the raw IP). Prefer `/etc/hosts` or a
**DNS-only** (grey cloud) A record for a name that matches the cert.

Add both exports to `~/.zshrc` or `~/.bash_profile` to persist.

### Docker client mTLS install (otsmbpro16/hpdevcore)

Install client artifacts into a **dedicated, per-context path** so they
cannot be clobbered by `deploy-otsmbpro16.bash` (which writes the public
LE chain into `~/.docker/ca.pem`, `cert.pem`, `key.pem`).

```bash
# Example for otsmbpro16
CTX_DIR="$HOME/.docker/contexts/otsorundscore-mtls"
mkdir -p "$CTX_DIR"
chmod 0700 "$CTX_DIR"
install -m 0644 /Volumes/certs/acme/docker-mtls/ca/ca-cert.pem                "$CTX_DIR/ca.pem"
install -m 0644 /Volumes/certs/acme/docker-mtls/clients/otsmbpro16/cert.pem    "$CTX_DIR/cert.pem"
install -m 0400 /Volumes/certs/acme/docker-mtls/clients/otsmbpro16/key.pem     "$CTX_DIR/key.pem"
```

The matching `docker context create` command in [Docker remote access
profiles](../SETUP.md#docker-remote-access-profiles-ssh-first-narrow-tcp-only-when-needed) points the context at
`$CTX_DIR/{ca,cert,key}.pem`, so this never touches the default `~/.docker/`
files.

Then verify:

```bash
docker --context otsorundscore-mtls version
```

Negative test (expected fail without the client cert when the daemon has
`tlsverify=true`):

```bash
CTX_DIR="$HOME/.docker/contexts/otsorundscore-mtls"
mv "$CTX_DIR/cert.pem" "$CTX_DIR/cert.pem.bak"
mv "$CTX_DIR/key.pem"  "$CTX_DIR/key.pem.bak"
docker --context otsorundscore-mtls version || true
mv "$CTX_DIR/cert.pem.bak" "$CTX_DIR/cert.pem"
mv "$CTX_DIR/key.pem.bak"  "$CTX_DIR/key.pem"
```

### hpdevcore — run on the laptop

```bash
# Mount the NAS share first (adjust server, path, and user for your setup):
sudo mount -t cifs //YOUR_FILESERVER/certs /mnt/nas-certs -o user=YOUR_USER

SOURCE_DIR=/mnt/nas-certs/acme/hpdevcore \
  bash /mnt/nas-certs/acme/deploy-hpdevcore.bash
```


---

## Optional: automate legacy Mac deploy (cron)

### Optional: automate device deploys

Otsorundscore DSM/Docker PEMs are staged **on a Mac** with `deploy-otsorundscore.bash` after
acme.sh renews; schedule that (or a wrapper that uploads) on the machine that mounts
`/Volumes/certs/acme/`, not as an on-NAS cron that assumed the old in-place script.

```bash
# Example — Mac launchd/cron after renew: stage bundle (then upload manually or via your automation)
0 4 * * * bash /Volumes/certs/acme/deploy-otsorundscore.bash >>"$HOME/certs/deploy-otsorundscore.log" 2>&1
```
