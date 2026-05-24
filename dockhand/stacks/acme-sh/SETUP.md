# acme.sh -- Let's Encrypt cert automation

Issues and auto-renews RSA certificates via Cloudflare DNS (`--keylength 2048`
by default). PEMs go to `/volume2/certs/acme/`; deploy scripts read from there
but do not auto-push. RSA orders use paths without the `_ecc` suffix (ECDSA
is not used).

For 4096-bit RSA, substitute `--keylength 4096` in every `--issue` block below
(same policy for all certs).

```text
/volume2/certs/acme/               (= /Volumes/certs/acme/ on Mac)
+--- wildcard/                      *.olutechsys.com + *.olutech.systems
+--- otsorundscore-sub/             apex + wildcards on both zones + optional `*.ots` / `*.mft` SANs (see SETUP)
+--- misfitsds-sub/                 apex + wildcards on both zones + optional `*.ots` / `*.mft` SANs (see SETUP)
+--- otsmbpro16/                    otsmbpro16.olutechsys.com
+--- hpdevcore/                     hpdevcore.olutechsys.com
+--- otsorundscore/                 HAProxy PEMs: `otsorundscore.olutechsys.com`, `otsorundscore.olutech.systems`, `*.otsorundscore.olutechsys.com`, `*.otsorundscore.olutech.systems`
+--- misfitsds/                     HAProxy PEMs: `misfitsds.olutechsys.com`, `misfitsds.olutech.systems`, `*.misfitsds.olutechsys.com`, `*.misfitsds.olutech.systems`
+--- haproxy/                       Combined PEM bundles from **`scripts/deploy_certs.sh`** (default **`HAPROXY_CERT_STAGE_DIR`**)
+--- deploy-otsorundscore.bash         legacy Mac staging (see archive/SETUP_LEGACY_2026-05-10.md)
+--- deploy-misfitsds.bash          legacy misfitsds deploy (see archive)
+--- deploy-otsmbpro16.bash         run on the Mac (PEMs -> ~/certs/otsmbpro16/)
+--- deploy-hpdevcore.bash          run on the laptop
+--- tests/                         `bash tests/run-all.bash` -- script checks
+--- daemon-tls.json                Docker TLS-only reference (`tlsverify: false`, **legacy/lab-only**, loopback default)
+--- daemon-mtls.json               Docker mTLS reference (`tlsverify: true`, **recommended when remote TCP is needed**, loopback default)
+--- docker-mtls-init-ca.bash       initialize Docker mTLS CA (isolated PKI)
+--- docker-mtls-issue-server.bash  issue daemon server cert (per daemon host)
+--- docker-mtls-issue-client.bash  issue client cert (per user/device)
+--- deploy-otsorundscore-mtls.bash    stage mTLS bundle for manual NAS upload
```

> **`*.asus.com` cannot be issued.** ASUSTeK owns that DNS zone.
> Use `olutechsys.com` or `olutech.systems` for device hostnames.

## Certificate layout: host-named primary vs optional / legacy paths

- **Primary (HAProxy + host-named services):** under **`${ACME_CERT_ROOT}`** (default `/volume2/certs/acme`), PEM trees **`otsorundscore/`** and **`misfitsds/`** -- HAProxy consumes combined bundles built from these by **`scripts/deploy_certs.sh`** (deployed to `/var/packages/haproxy/var/crt/`). Follow the **`--issue`** / **`--install-cert`** blocks for those dirs first when standing up TLS for the NAS fleet.
- **Optional / broader:** **`wildcard/`**, **`otsorundscore-sub/`**, **`misfitsds-sub/`** cover apex + multi-zone + optional extra SANs for operators who keep consolidated or overlapping orders; skip creating dirs you never issue for.
- **Legacy / lab / operator-specific:** historical **`*.ots.*`** / **`*.mft.*`** service hostnames are deprecated for **new** work (see root **`AGENTS.md`**). **`deploy-*.bash`** under **`${ACME_CERT_ROOT}`**, **`daemon-tls.json`** (TLS-only Docker), and similar assets remain documented for back-compat or laptop staging; for HAProxy bundles from NAS stacks prefer **`stacks/acme-sh/scripts/deploy_certs.sh`** with **`ACME_PROFILE`** / **`BUNDLE_SPECS`**.

## NAS hosts & LAN IPs (reference)

Use these for firewall rules, HAProxy/Traefik backends, split-DNS, or `/etc/hosts` -- **not** as Let's Encrypt certificate names.

| Role    | Hostname (examples)                             | Typical LAN IP  | Notes                                                                                           |
| ------- | ----------------------------------------------- | --------------- | ----------------------------------------------------------------------------------------------- |
| OTS NAS | `otsorundscore`, `otsorundscore.olutechsys.com` | **`10.0.1.15`** | Runs NAS stacks; HAProxy examples bind backends here; Docker narrow-TCP examples use this IP |
| MFT NAS | `misfitsds`, `misfitsds.olutechsys.com`         | **`10.0.1.24`** | Separate Synology; same DNS-01 / pem layout under `${ACME_CERT_ROOT}` after issue               |

Adjust IPs if your VLAN differs. Optionally mirror them as comments in `acme-sh/.env` (see `.env.example` -- compose does not consume those vars).

### Can I put NAS IPs on the Let's Encrypt cert?

**Not for private LAN addresses (e.g. `10.x`, `192.168.x`).** Let's Encrypt does not issue certificates whose SANs are **RFC1918/private IPs**. This stack validates with **Cloudflare DNS-01**, which proves control of **DNS names**, not arbitrary IP identifiers.

**What to do instead**

- Serve HTTPS by **hostname** (`*.otsorundscore....`, `*.misfitsds....`, etc.) and resolve those names on the LAN via **split DNS**, **`/etc/hosts`**, or your router -- the PEM from acme.sh stays valid for those names. (Historical `*.ots.*` / `*.mft.*` hostnames are deprecated for new work -- see root **`AGENTS.md`**.)
- Need TLS **to an IP** or **Docker daemon** identity? Use **hostname + DNS** for LE-backed services, or **private PKI** (e.g. mTLS scripts under your acme tree: `SAN_IPS=10.0.1.15` for daemon certs -- not the same as LE).

---

## Deploy acme-sh end-to-end (checklist)

Do this on **each Synology** that runs the acme-sh container (often **OTS only** if one NAS issues for all zones via Cloudflare).

### 1. Prerequisites

- Cloudflare API token (`Zone.DNS:Edit`) on **`olutechsys.com`** and **`olutech.systems`** (grey-cloud / DNS-only on wildcards you use for Synology DDNS is OK for issuance).
- Repo path on NAS: `${STACK_ROOT}/acme-sh` (e.g. `/volume2/docker/ce-stacks/stacks/acme-sh`).
- Parent dirs exist for **`${ACME_CERT_ROOT}`** (default `/volume2/certs/acme`).

### 2. Configure `.env`

```bash
cd /volume2/docker/ce-stacks/stacks/acme-sh
test -f .env || sudo cp .env.example .env
# Edit: CF_Token, STACK_ROOT, ACME_CERT_ROOT (if not default), optional DISCORD_WEBHOOK_URL
```

### 3. Start the stack

```bash
sudo docker compose up -d
sudo docker logs AcmeSh --tail 30
```

Expect daemon mode (cron); no HTTP port -- renewals run inside the container.

### 4. Create PEM output directories

```bash
sudo mkdir -p \
  /volume2/certs/acme/wildcard \
  /volume2/certs/acme/otsorundscore-sub \
  /volume2/certs/acme/misfitsds-sub \
  /volume2/certs/acme/otsorundscore \
  /volume2/certs/acme/misfitsds \
  /volume2/certs/acme/otsmbpro16 \
  /volume2/certs/acme/hpdevcore
```

(Omit dirs you never issue.)

### 5. Issue certificates

Run the **`--issue`** blocks in [Issue all certs](#issue-all-certs) that you need (DNS propagation ~1-2 minutes each). Watch logs:

```bash
sudo docker logs -f AcmeSh
```

### 6. Install PEMs to `${ACME_CERT_ROOT}`

Run matching **`--install-cert`** blocks in [Configure output paths](#configure-output-paths-run-once-per-cert-after-issue). Use each order's **primary** `-d` from:

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --list
```

### 7. Reload consumers (repo scripts + ADR)

After new or renewed PEMs under **`${ACME_CERT_ROOT}`** (profiles such as **`otsorundscore`**, **`misfitsds`** -- see the tree at the top of this file):

1. **HAProxy bundles (host-run, preferred):**  
   - Script: **`stacks/acme-sh/scripts/deploy_certs.sh`** -- builds combined PEMs and deploys them directly to **`HAPROXY_CERT_STAGE_DIR`** (default **`/var/packages/haproxy/var/crt/`** -- Synology HAProxy package cert directory; **`mkdir -p`** on run). Atomic replace + **`.lkg`** rollback applies when **`haproxy -c`** runs and fails. The script does **not** restart or reload HAProxy.  
   - **Single profile (optional):** with **`BUNDLE_SPECS` unset**, set **`ACME_PROFILE=otsorundscore`** or **`misfitsds`** to deploy **one** HAProxy bundle using the default filename mapping (see script header).  
   - **HAProxy validate:** when `HAPROXY_CERT_STAGE_DIR` matches `LIVE_HAPROXY_CERT_DIR` (both default to `/var/packages/haproxy/var/crt/`), **`haproxy -c`** runs against **`HAPROXY_CFG`** (default **`${STACK_ROOT}/_haproxy/haproxy.cfg`**) if **`HAPROXY_BIN`** is executable (Synology package default **`/volume1/@appstore/haproxy/sbin/haproxy`**).  
   - **HAProxy restart:** after successful **`haproxy -c`**, restart via **DSM -> Package Center -> HAProxy -> Action -> Restart**.  
   - Rationale: host-run vs in-container ADR (see `stacks/acme-sh/scripts/deploy_certs.sh` header).

2. **TLS edge verify:** **`stacks/acme-sh/scripts/verify_serving.sh`** -- requires **`CONNECT_HOST`**; set **`CONNECT_PORT`** (default **`8281`** -- HAProxy HTTPS), **`SNI`** (defaults to **`CONNECT_HOST`**), **`MIN_VALID_DAYS`** (default **21** for **`openssl x509 -checkend`**), optional **`EXPECTED_SUBJECT`**. On TLS / subject / expiry failure, posts to **`DISCORD_WEBHOOK_URL`** when set (same variable name as **`stacks/acme-sh/.env.example`**).

3. **Legacy bash deployers:** `deploy-otsorundscore.bash` / `deploy-misfitsds.bash` under `${ACME_CERT_ROOT}` remain operator-specific; prefer the repo **`deploy_certs.sh`** path above for HAProxy bundles.

#### DSM Control Panel -- manual certificate import (operator)

Importing DSM's **control panel** or **reverse-proxy** certificate is **manual** (DSM UI: *Control Panel -> Security -> Certificate* or the Login Portal / reverse-proxy certificate picker). **Do not** automate DSM certificate APIs from this repo without an explicit **pinned DSM major/minor** disclaimer, documented test matrix, and rollback -- DSM upgrades routinely overwrite nginx fragments and certificate store layouts.

### 8. Verify

```bash
openssl x509 -in /volume2/certs/acme/otsorundscore/fullchain.pem -noout -subject -dates 2>/dev/null || true
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --list
CONNECT_HOST=10.0.1.15 CONNECT_PORT=8281 SNI=psu.olutechsys.com MIN_VALID_DAYS=21 \
  bash "${STACK_ROOT}/acme-sh/scripts/verify_serving.sh"
```

---

## Deploy script tests

From a machine where the acme tree is available:

```bash
bash /Volumes/certs/acme/tests/run-all.bash
```

---

## Docker remote access profiles (SSH-first, narrow TCP only when needed)

Recommended posture, in order:

| Profile                       | `tlsverify` | Server auth     | Client auth                | When to use                                 |
| ----------------------------- | ----------- | --------------- | -------------------------- | ------------------------------------------- |
| **SSH context**               | n/a         | SSH host key    | SSH user key               | **Default -- admin access for everything**   |
| **mTLS context** (narrow TCP) | `true`      | Private CA      | Private CA                 | Only when remote TCP is explicitly required |
| TLS-only                      | `false`     | Public/LE chain | **none -- lab/legacy only** | Avoid; kept for back-compat                 |

> **SSH context is the recommended default.** It rides Docker's normal
> SSH transport over `unix:///var/run/docker.sock` on the daemon host, so
> it works without opening any TCP listener at all and is independent of
> `daemon.json` `hosts`. Reach for **mTLS** only when something genuinely
> requires `tcp://...:2376` (e.g., an integration that cannot speak Docker
> over SSH). TLS-only is **legacy/lab-only** -- encrypted wire, no client
> authentication; treat a reachable port as remote root.

**Reference `daemon-*.json` defaults (committed in this repo):** both
`daemon-tls.json` and `daemon-mtls.json` bind to **`tcp://127.0.0.1:2376`
(loopback only)** so the safe default cannot accidentally expose Docker
on the LAN. To allow narrow remote TCP, edit `hosts` to a single,
firewalled lab IP **before** merging -- for this lab that is
`tcp://10.0.1.15:2376` for otsorundscore (`10.0.1.15`); misfitsds is
`10.0.1.24` (no Docker daemon TLS bundle in this tree). For **private Docker mTLS**
certs only, add that IP to server SANs (`SAN_IPS` in the mTLS scripts) -- **not**
on Let's Encrypt DNS-01 certs (see [Can I put NAS IPs on the Let's Encrypt cert?](#can-i-put-nas-ips-on-the-lets-encrypt-cert)). Tighten the firewall to the trusted client subnet.

1. **SSH context (recommended default -- no TCP needed):**

```bash
docker context create otsorundscore-ssh --docker "host=ssh://YOUR_USER@otsorundscore"
docker --context otsorundscore-ssh info
```

This works regardless of the TCP listener state -- even if
`daemon.json` has no `tcp://...` entry at all. Use this as the primary
admin path; reach for mTLS only when SSH cannot satisfy the consumer.

1. **mTLS context (narrow TCP -- only when SSH is not enough):**
   - Daemon uses private CA + server cert + `tlsverify=true`
   - Client presents a cert signed by the same CA
   - Keeps Docker PKI isolated under `/volume2/certs/acme/docker-mtls/`
   - Client artifacts live under a **dedicated, per-context path**
     (`~/.docker/contexts/otsorundscore-mtls/`) so they cannot be clobbered by
     `deploy-otsmbpro16.bash`, which manages the default `~/.docker/ca.pem`,
     `cert.pem`, `key.pem` from the public LE chain.

```bash
mkdir -p "$HOME/.docker/contexts/otsorundscore-mtls"
docker context create otsorundscore-mtls --docker \
  "host=tcp://otsorundscore.olutechsys.com:2376,\
ca=$HOME/.docker/contexts/otsorundscore-mtls/ca.pem,\
cert=$HOME/.docker/contexts/otsorundscore-mtls/cert.pem,\
key=$HOME/.docker/contexts/otsorundscore-mtls/key.pem"
docker --context otsorundscore-mtls info
```

> **Per-context TLS files are the default pattern.** Keeping each
> context's PEMs under its own `~/.docker/contexts/<name>/` directory
> means an mTLS context cannot be silently overwritten by tools that
> manage the default `~/.docker/{ca,cert,key}.pem` (such as
> `deploy-otsmbpro16.bash`).
>
> **`DOCKER_CERT_PATH` is an optional alternative** for one-off, non-context
> flows: point Docker at any directory containing `ca.pem`/`cert.pem`/`key.pem`
> without registering a context -- for example,
> `DOCKER_HOST=tcp://otsorundscore.olutechsys.com:2376
DOCKER_TLS_VERIFY=1 DOCKER_CERT_PATH="$HOME/.docker/contexts/otsorundscore-mtls"
docker info`. Prefer `docker context` for anything persistent;
> `DOCKER_CERT_PATH` is for ad-hoc shells and CI jobs.

---

## Pitfalls / common gotchas

These are easy to get wrong and have bitten this stack before. Read
before editing `daemon.json` or restarting Docker.

### 1. Don't duplicate `hosts` between systemd and `daemon.json`

On Linux hosts that run Docker via systemd, the unit may pass `-H
fd://` or `-H tcp://...` to `dockerd`. **`daemon.json` must NOT also
declare `hosts`** in that case -- Docker refuses to start with
"unable to configure the Docker daemon with file /etc/docker/daemon.json:
the following directives are specified both as a flag and in the
configuration file: hosts". Pick exactly one source of truth:

- Edit the systemd drop-in (`/etc/systemd/system/docker.service.d/override.conf`)
  and remove `-H` flags from `ExecStart`, **or**
- Keep the systemd flags and remove `hosts` from `daemon.json`.

This trap does **not** apply to Synology Container Manager (no systemd
unit; the package launcher honors `daemon.json` `hosts` directly), but
will bite any Linux host you migrate this config to.

### 2. Synology Container Manager -- daemon path & restart semantics

DSM's Container Manager / Docker package uses a non-standard layout:

- The active config file is **`/volume1/docker/daemon.json`**, not
  `/etc/docker/daemon.json`. Edits to the latter are silently ignored.
- The correct restart command is **`sudo synopkg restart ContainerManager`**
  (older DSM: `sudo synopkg restart Docker`). `systemctl restart docker`
  does not exist.
- DSM package upgrades may rewrite or replace `daemon.json`. Always
  back it up before merging (`cp -n /volume1/docker/daemon.json
/volume1/docker/daemon.json.bak`) and re-apply your fragment after a
  package update if the diff disappears.
- `synoservicectl --reload nginx` is what reloads DSM's reverse proxy
  after replacing `cert.pem`/`chain.pem` in
  `/usr/syno/etc/certificate/system/default/`.

### 3. Always merge `daemon.json` atomically

Never do `jq ... daemon.json | sudo tee daemon.json` -- the same file is
both input and output of the pipeline and the read can race the
truncating write, leaving an empty `daemon.json` and a daemon that
won't start. Always go through a temp file:

```bash
TMP=$(sudo mktemp /volume1/docker/.daemon.json.XXXXXX)
sudo jq -s '.[0] * .[1]' \
  /volume1/docker/daemon.json \
  /volume2/certs/acme/daemon-mtls.json > "${TMP}"
sudo mv -f "${TMP}" /volume1/docker/daemon.json
```

`mv -f` within the same filesystem is atomic, so a reader either sees
the old file or the new one -- never a half-written file.

### 4. Per-context TLS, not shared `~/.docker/{ca,cert,key}.pem`

Always write mTLS client material under
`~/.docker/contexts/<context-name>/` so unrelated tooling that manages
the default `~/.docker/` files (e.g. `deploy-otsmbpro16.bash`, IDEs,
Docker Desktop) cannot clobber it. `DOCKER_CERT_PATH` is acceptable
for non-context shells and CI; do not set it as a permanent shell
default while you also have multiple contexts.

---

## Operator quick reference

Use **[Deploy acme-sh end-to-end](#deploy-acme-sh-end-to-end-checklist)** for `.env`, compose, directories, **`--issue` / `--install-cert`**, and **`scripts/deploy_certs.sh`**. Legacy **`deploy-*.bash`** staging, DSM / `daemon.json` merges, mTLS NAS apply steps, and the Mac cron example live in **[`archive/SETUP_LEGACY_2026-05-10.md`](archive/SETUP_LEGACY_2026-05-10.md)** (anchor **`#mtls-bundle-reference`** for mTLS).

## Migrating from ECDSA (`*_ecc`)

Older ECDSA certs live under `*_ecc/` in the acme.sh data volume. After
migration, PEMs stay at the same paths under `/volume2/certs/acme/`.

**Order:** backup -> remove ECC (step 2) -> issue RSA 2048 (step 3) ->
`--install-cert` (step 4) -> verify (step 5).

1. **Backup:** copy `/volume2/docker/ce-stacks/stacks/acme-sh/data` and optionally
   `/volume2/certs/acme/`.
2. **Remove ECDSA orders** before re-issue. Run the block; skip errors for
   names that were never ECC. Match `-d` to each ECC row's primary domain in
   `sudo docker exec AcmeSh /acme-sh-entrypoint.sh --list` if yours differ from these:

   ```bash
   sudo docker exec AcmeSh /acme-sh-entrypoint.sh --remove -d '*.olutechsys.com' --ecc
   sudo docker exec AcmeSh /acme-sh-entrypoint.sh --remove -d '*.otsorundscore.olutechsys.com' --ecc
   sudo docker exec AcmeSh /acme-sh-entrypoint.sh --remove -d '*.misfitsds.olutechsys.com' --ecc
   sudo docker exec AcmeSh /acme-sh-entrypoint.sh --remove -d 'otsmbpro16.olutechsys.com' --ecc
   sudo docker exec AcmeSh /acme-sh-entrypoint.sh --remove -d 'hpdevcore.olutechsys.com' --ecc
   ```

3. **Issue:** run each block in [Issue all certs](#issue-all-certs) (`--keylength 2048`).
4. **Install:** run each block in [Configure output paths](#configure-output-paths-run-once-per-cert-after-issue). Use the same primary `-d` as in `--issue`.
5. **Verify** RSA key material and chain trust:

   ```bash
   openssl x509 -in /volume2/certs/acme/wildcard/fullchain.pem -noout -text \
     | grep -E 'Public Key Algorithm|RSA Public-Key'
   openssl verify -CAfile /volume2/certs/acme/wildcard/chain.pem \
     /volume2/certs/acme/wildcard/cert.pem
   ```

   Repeat the `openssl` pair for other dirs (`otsorundscore-sub/`, etc.) as needed.

---

## Issue all certs

Run each block once (DNS ~1-2 min per cert). Default key is `--keylength 2048`.

Primary `-d` strings (for `--install-cert`, `--renew`, and non-`--ecc` remove):
`olutechsys.com` (wildcard), `otsorundscore.olutechsys.com` (otsorundscore-sub and otsorundscore/ HAProxy),
`misfitsds.olutechsys.com` (misfitsds-sub and misfitsds/ HAProxy),
`otsmbpro16.olutechsys.com`, `hpdevcore.olutechsys.com` -- confirm with
`acme.sh --list` if anything differs.

### wildcard -- \*.olutechsys.com + \*.olutech.systems

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --issue \
  -d 'olutechsys.com' \
  -d '*.olutechsys.com' \
  -d 'olutech.systems' \
  -d '*.olutech.systems' \
  --keylength 2048 \
  --dns dns_cf --server letsencrypt
```

**Re-issue after an older order used `*.olutechsys.com` as primary:** remove the old RSA order first, then issue again:

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --remove -d '*.olutechsys.com'
```

### otsorundscore-sub -- apex + `*.otsorundscore.*` (+ optional namespace wildcards)

First `-d` is the acme.sh order key (CN / "main" in many UIs); remaining `-d` values are SANs.

Optional `*.otsorundscore.olutechsys.com` and `*.misfitsds.olutechsys.com` duplicate coverage from dedicated
`otsorundscore/` and `misfitsds/` orders -- omit those two lines if you prefer separate cert rotation only.

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --issue \
  -d 'otsorundscore.olutechsys.com' \
  -d 'otsorundscore.olutech.systems' \
  -d '*.otsorundscore.olutechsys.com' \
  -d '*.otsorundscore.olutech.systems' \
  -d '*.otsorundscore.olutechsys.com' \
  -d '*.misfitsds.olutechsys.com' \
  --keylength 2048 \
  --dns dns_cf --server letsencrypt
```

**Re-issue after an older order used `*.otsorundscore.olutechsys.com` as primary:** remove the old RSA order first, then issue again (match `-d` from `acme.sh --list`):

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --remove -d '*.otsorundscore.olutechsys.com'
```

### misfitsds-sub -- apex + `*.misfitsds.*` (+ optional namespace wildcards)

Same optional SAN overlap note as otsorundscore-sub.

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --issue \
  -d 'misfitsds.olutechsys.com' \
  -d 'misfitsds.olutech.systems' \
  -d '*.misfitsds.olutechsys.com' \
  -d '*.misfitsds.olutech.systems' \
  -d '*.otsorundscore.olutechsys.com' \
  -d '*.misfitsds.olutechsys.com' \
  --keylength 2048 \
  --dns dns_cf --server letsencrypt
```

### otsmbpro16 -- MacBook

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --issue \
  -d 'otsmbpro16.olutechsys.com' \
  -d 'otsmbpro16.olutech.systems' \
  --keylength 2048 \
  --dns dns_cf --server letsencrypt
```

### hpdevcore -- Laptop

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --issue \
  -d 'hpdevcore.olutechsys.com' \
  -d 'hpdevcore.olutech.systems' \
  --keylength 2048 \
  --dns dns_cf --server letsencrypt
```

## Issue host-named HAProxy certs (`otsorundscore/` + `misfitsds/` dirs)

Dedicated `otsorundscore/` and `misfitsds/` PEM dirs are the source for HAProxy combined bundles (built by `scripts/deploy_certs.sh`). If you already included `*.otsorundscore.olutechsys.com` / `*.misfitsds.olutechsys.com` as extra SANs on **otsorundscore-sub** or **misfitsds-sub**, you can skip the duplicate orders below (same names on two certs = two independent renewals).

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --issue \
  -d 'otsorundscore.olutechsys.com' \
  -d 'otsorundscore.olutech.systems' \
  -d '*.otsorundscore.olutechsys.com' \
  -d '*.otsorundscore.olutech.systems' \
  --keylength 2048 \
  --dns dns_cf --server letsencrypt
```

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --issue \
  -d 'misfitsds.olutechsys.com' \
  -d 'misfitsds.olutech.systems' \
  -d '*.misfitsds.olutechsys.com' \
  -d '*.misfitsds.olutech.systems' \
  --keylength 2048 \
  --dns dns_cf --server letsencrypt
```

---

## Configure output paths (run once per cert after issue)

Run each block once; paths are persisted in the acme.sh data volume. `-d` must
match the RSA order's primary domain from `acme.sh --list` (same as `--issue`
unless the list shows otherwise).

Create dirs first (acme.sh does not create parents):

```bash
sudo mkdir -p \
  /volume2/certs/acme/wildcard \
  /volume2/certs/acme/otsorundscore-sub \
  /volume2/certs/acme/misfitsds-sub \
  /volume2/certs/acme/otsmbpro16 \
  /volume2/certs/acme/hpdevcore \
  /volume2/certs/acme/otsorundscore \
  /volume2/certs/acme/misfitsds
```

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --install-cert \
  -d 'olutechsys.com' \
  --cert-file      /volume2/certs/acme/wildcard/cert.pem \
  --key-file       /volume2/certs/acme/wildcard/privkey.pem \
  --ca-file        /volume2/certs/acme/wildcard/chain.pem \
  --fullchain-file /volume2/certs/acme/wildcard/fullchain.pem \
  --reloadcmd      "chmod 640 /volume2/certs/acme/wildcard/privkey.pem"
```

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --install-cert \
  -d 'otsorundscore.olutechsys.com' \
  --cert-file      /volume2/certs/acme/otsorundscore-sub/cert.pem \
  --key-file       /volume2/certs/acme/otsorundscore-sub/privkey.pem \
  --ca-file        /volume2/certs/acme/otsorundscore-sub/chain.pem \
  --fullchain-file /volume2/certs/acme/otsorundscore-sub/fullchain.pem \
  --reloadcmd      "chmod 640 /volume2/certs/acme/otsorundscore-sub/privkey.pem"
```

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --install-cert \
  -d 'misfitsds.olutechsys.com' \
  --cert-file      /volume2/certs/acme/misfitsds-sub/cert.pem \
  --key-file       /volume2/certs/acme/misfitsds-sub/privkey.pem \
  --ca-file        /volume2/certs/acme/misfitsds-sub/chain.pem \
  --fullchain-file /volume2/certs/acme/misfitsds-sub/fullchain.pem \
  --reloadcmd      "chmod 640 /volume2/certs/acme/misfitsds-sub/privkey.pem"
```

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --install-cert \
  -d 'otsmbpro16.olutechsys.com' \
  --cert-file      /volume2/certs/acme/otsmbpro16/cert.pem \
  --key-file       /volume2/certs/acme/otsmbpro16/privkey.pem \
  --ca-file        /volume2/certs/acme/otsmbpro16/chain.pem \
  --fullchain-file /volume2/certs/acme/otsmbpro16/fullchain.pem \
  --reloadcmd      "chmod 640 /volume2/certs/acme/otsmbpro16/privkey.pem"
```

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --install-cert \
  -d 'hpdevcore.olutechsys.com' \
  --cert-file      /volume2/certs/acme/hpdevcore/cert.pem \
  --key-file       /volume2/certs/acme/hpdevcore/privkey.pem \
  --ca-file        /volume2/certs/acme/hpdevcore/chain.pem \
  --fullchain-file /volume2/certs/acme/hpdevcore/fullchain.pem \
  --reloadcmd      "chmod 640 /volume2/certs/acme/hpdevcore/privkey.pem"
```

## Configure HAProxy cert output paths (otsorundscore + misfitsds)

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --install-cert \
  -d 'otsorundscore.olutechsys.com' \
  --cert-file      /volume2/certs/acme/otsorundscore/cert.pem \
  --key-file       /volume2/certs/acme/otsorundscore/privkey.pem \
  --ca-file        /volume2/certs/acme/otsorundscore/chain.pem \
  --fullchain-file /volume2/certs/acme/otsorundscore/fullchain.pem \
  --reloadcmd      "chmod 640 /volume2/certs/acme/otsorundscore/privkey.pem"
```

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --install-cert \
  -d 'misfitsds.olutechsys.com' \
  --cert-file      /volume2/certs/acme/misfitsds/cert.pem \
  --key-file       /volume2/certs/acme/misfitsds/privkey.pem \
  --ca-file        /volume2/certs/acme/misfitsds/chain.pem \
  --fullchain-file /volume2/certs/acme/misfitsds/fullchain.pem \
  --reloadcmd      "chmod 640 /volume2/certs/acme/misfitsds/privkey.pem"
```

---

## Legacy per-device deploy (archived)

For **HAProxy**, use **`scripts/deploy_certs.sh`** and **`scripts/verify_serving.sh`** after PEMs refresh on disk (see [Deploy acme-sh end-to-end](#deploy-acme-sh-end-to-end-checklist) step 7). Older **Mac-staged `deploy-otsorundscore.bash`**, **`deploy-misfitsds.bash`**, **`deploy-otsmbpro16.bash`**, **`deploy-hpdevcore.bash`**, DSM / **`daemon.json`** merges, mTLS staging, client-context installs, and optional **Mac cron** runbooks are preserved in **[`archive/SETUP_LEGACY_2026-05-10.md`](archive/SETUP_LEGACY_2026-05-10.md)** (anchor **`#mtls-bundle-reference`** for the on-NAS mTLS merge).

---

## Auto-renewal

acme.sh in `daemon` mode checks for renewals every 24 hours and auto-copies
updated certs to `/volume2/certs/acme/` via the configured `--install-cert`
paths. When bundles change, run **`scripts/deploy_certs.sh`** (and **`verify_serving.sh`**) so HAProxy reloads with valid PEMs. Optional legacy **`deploy-*.bash`** automation: **[`archive/SETUP_LEGACY_2026-05-10.md`](archive/SETUP_LEGACY_2026-05-10.md)**.

Check all managed certs and expiry:

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --list
```

Force renewal (RSA only; do not pass `--ecc`). Use each cert's primary `-d` from
`acme.sh --list` (see [Issue all certs](#issue-all-certs)):

```bash
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --renew -d 'olutechsys.com' --force
sudo docker exec AcmeSh /acme-sh-entrypoint.sh --renew -d 'hpdevcore.olutechsys.com' --force
```

Repeat for `otsorundscore.olutechsys.com`, `misfitsds.olutechsys.com`,
`otsmbpro16.olutechsys.com` etc. (each cert's primary `-d` from `acme.sh --list`).

---

## Migration notes -- TLS-only to mTLS

- Existing TLS-only mode remains supported with `daemon-tls.json`
  (`tlsverify: false`) but is **legacy/lab-only**: it does not authenticate
  clients. Both reference daemon configs default to the safe loopback
  bind **`tcp://127.0.0.1:2376`**. To allow remote LAN access on
  otsorundscore, edit `hosts` to the narrow lab bind
  **`tcp://10.0.1.15:2376`** before merge and combine it with mTLS plus
  a firewall rule pinning `:2376` to the trusted client subnet. Keep an
  **SSH context** working first -- that path does not depend on any TCP
  bind at all.
- mTLS mode is opt-in via `daemon-mtls.json` and `deploy-otsorundscore-mtls.bash`.
- Keep Docker mTLS PKI only under `/volume2/certs/acme/docker-mtls/`:
  - `ca/` (private CA, dir mode `0700`, key mode `0400`)
  - `servers/<daemon-host>/`
  - `clients/<client-name>/`
- Do not store Docker mTLS keys in existing ACME leaf folders (`wildcard/`,
  `*-sub/`, host leaf dirs), and do not use `~/.docker/{ca,cert,key}.pem`
  for the mTLS context -- those are managed by `deploy-otsmbpro16.bash`.

Safe migration sequence:

1. Keep an SSH context working first (`docker --context otsorundscore-ssh info`).
2. Generate CA/server/client certs (CA is now hardened -- see below).
3. Stage and apply `docker-daemon-mtls.json` merge using the temp-file
   pattern in [archive -- mTLS bundle reference](archive/SETUP_LEGACY_2026-05-10.md#mtls-bundle-reference).
4. Install client certs into `~/.docker/contexts/otsorundscore-mtls/` (see [Docker remote access profiles](#docker-remote-access-profiles-ssh-first-narrow-tcp-only-when-needed); full copy-paste flows including **negative test** commands are in [archive/SETUP_LEGACY_2026-05-10.md](archive/SETUP_LEGACY_2026-05-10.md)).
5. Validate the mTLS context (`docker --context otsorundscore-mtls version`), then optional negative test per archive **Docker client mTLS install** subsection.
6. Keep `daemon-tls.json` for rollback if needed; revert by re-merging it
   the same way and restarting `ContainerManager`.

---

## CA hardening rationale

`docker-mtls-init-ca.bash` enforces several defenses; understand why before
weakening any of them:

- **`umask 077` at the top of the script.** Every file the script creates
  (CSRs, extension configs, temp files) is `rw-------` by default. Without
  this, an interactive shell that ran `umask 022` earlier would leak the
  CA's intermediate working files world-readable.
- **`CA_DIR` chmod `0700`.** The CA private key (`ca-key.pem`) is the root
  of trust for every Docker daemon and client in this lab. If any other
  local user can read it, they can mint a valid client cert and connect to
  Docker as root. Closing the directory closes the directory traversal as
  well as the file.
- **`basicConstraints = critical, CA:TRUE, pathlen:0`.** Marks the cert as
  a CA (so OpenSSL accepts signatures from it), but `pathlen:0` forbids it
  from issuing **intermediate** CAs -- only end-entity (leaf) certs. This
  matches how the issue scripts use it and prevents accidental
  delegation.
- **`keyUsage = critical, keyCertSign, cRLSign`.** Restricts what the CA
  key can do at the X.509 layer: sign certs and sign CRLs only. No data
  signing, no key encipherment. Marking it `critical` means any client
  that doesn't understand `keyUsage` must reject the cert.
- **Random serial-number prefix.** The original script started serial at
  `1000` and incremented. Predictable serials make CRL-style revocation
  attacks marginally easier and reduce uniqueness across multiple labs.
  We seed serial with `openssl rand -hex 4`.

Pre-existing CAs created by the older script keep working; only
`FORCE=1` re-init writes the new format.

---

## Revocation / rotation runbook

This lab CA is intentionally minimal -- there is no OpenSSL `index.txt` CA
database, so a full CRL-based revocation flow is not in scope. For a
compromised client cert (laptop lost, key leaked, contractor offboarded),
the supported response is **rotation**: re-issue the affected leaves, or
in the worst case rotate the CA itself.

Choose the smallest blast radius:

### A. One client compromised (most common)

```bash
# 1. Revoke from the daemon's perspective by removing the offender from the
#    list of clients you trust -- the simplest control here is just to NOT
#    re-issue it. There is no per-leaf revocation without a CRL.
# 2. Re-issue a fresh cert for that client name with FORCE=1:
FORCE=1 CLIENT_NAME=otsmbpro16 \
  bash /volume2/certs/acme/docker-mtls-issue-client.bash
# 3. On the affected client, replace the cert in its dedicated context dir:
CTX_DIR="$HOME/.docker/contexts/otsorundscore-mtls"
install -m 0644 /Volumes/certs/acme/docker-mtls/clients/otsmbpro16/cert.pem "$CTX_DIR/cert.pem"
install -m 0400 /Volumes/certs/acme/docker-mtls/clients/otsmbpro16/key.pem  "$CTX_DIR/key.pem"
docker --context otsorundscore-mtls version
```

> **Limitation:** the _old_ client cert is still valid against the daemon
> until it expires (`DAYS=825` by default) because there is no published
> CRL. If the threat is real, follow path **C** (rotate the CA) -- the only
> ironclad way to invalidate every cert previously signed by this CA.

### B. Daemon server cert compromised

```bash
FORCE=1 HOSTNAME=otsorundscore.olutechsys.com SAN_IPS=10.0.1.15 \
  bash /volume2/certs/acme/docker-mtls-issue-server.bash
DOCKER_HOSTNAME=otsorundscore.olutechsys.com \
  bash /Volumes/certs/acme/deploy-otsorundscore-mtls.bash
# Then re-apply the daemon config on the NAS using the temp-file merge in
# archive/SETUP_LEGACY_2026-05-10.md#mtls-bundle-reference and restart ContainerManager.
```

Clients keep their old certs; only the server changed.

### C. CA private key compromised -- full rotation

This is the nuclear option and the only way to invalidate every cert this
CA ever signed.

```bash
# 1. (Recommended) Keep an SSH context working as a fallback so you can
#    still reach the daemon if mTLS breaks mid-rotation.
docker --context otsorundscore-ssh info

# 2. Re-init the CA from scratch (this writes a NEW key+cert with a new
#    subjectKeyIdentifier; everything signed by the old CA stops chaining).
FORCE=1 bash /volume2/certs/acme/docker-mtls-init-ca.bash

# 3. Re-issue the daemon server cert for every Docker host.
FORCE=1 HOSTNAME=otsorundscore.olutechsys.com SAN_IPS=10.0.1.15 \
  bash /volume2/certs/acme/docker-mtls-issue-server.bash

# 4. Re-issue every client cert (one per device/operator).
for c in otsmbpro16 hpdevcore; do
  FORCE=1 CLIENT_NAME="$c" \
    bash /volume2/certs/acme/docker-mtls-issue-client.bash
done

# 5. Stage and re-apply the mTLS daemon bundle on the NAS, then restart.
DOCKER_HOSTNAME=otsorundscore.olutechsys.com \
  bash /Volumes/certs/acme/deploy-otsorundscore-mtls.bash
# (see archive/SETUP_LEGACY_2026-05-10.md#mtls-bundle-reference for the on-NAS apply step)

# 6. On every client, re-install the new ca/cert/key under
#    ~/.docker/contexts/otsorundscore-mtls/. The daemon will reject the old
#    client certs immediately because the CA chain no longer matches.
```

### Emergency containment (no rotation yet)

If you can't rotate immediately and a leak is suspected, narrow the
network surface first -- that buys time:

```bash
# On otsorundscore: re-merge daemon-tls/mtls config with hosts pinned to
# 127.0.0.1 (no LAN listener), then restart. This breaks remote LAN
# Docker access entirely until rotation is complete.
TMP=$(sudo mktemp /volume1/docker/.daemon.json.XXXXXX)
sudo jq '.hosts = ["unix:///var/run/docker.sock", "tcp://127.0.0.1:2376"]' \
  /volume1/docker/daemon.json > "${TMP}"
sudo mv -f "${TMP}" /volume1/docker/daemon.json
sudo synopkg restart ContainerManager
```

---

## What this stack manages

| Component                              | Cert                                                              | Auto-renewed                  | Deployed by |
| -------------------------------------- | ----------------------------------------------------------------- | ----------------------------- | ----------- |
| DSM HTTPS -- otsorundscore              | `wildcard/` (`*.olutechsys.com`)                                  | acme.sh                       | DSM UI + optional legacy `deploy-otsorundscore.bash` ([archive](archive/SETUP_LEGACY_2026-05-10.md)) |
| DSM HTTPS -- misfitsds                  | `wildcard/` (`*.olutechsys.com`)                                  | acme.sh                       | DSM UI + optional legacy `deploy-misfitsds.bash` ([archive](archive/SETUP_LEGACY_2026-05-10.md)) |
| Docker daemon TLS -- otsorundscore      | `wildcard/fullchain.pem`                                          | acme.sh                       | Legacy `deploy-otsorundscore.bash` ([archive](archive/SETUP_LEGACY_2026-05-10.md)) |
| Docker daemon mTLS -- otsorundscore     | `docker-mtls/servers/otsorundscore.olutechsys.com/`               | local `docker-mtls-*` scripts | `deploy-otsorundscore-mtls.bash` ([archive](archive/SETUP_LEGACY_2026-05-10.md)) |
| DSM cert slot -- otsorundscore services | `otsorundscore-sub/`                                              | acme.sh                       | Legacy bash ([archive](archive/SETUP_LEGACY_2026-05-10.md)) |
| DSM cert slot -- misfitsds services     | `misfitsds-sub/`                                                  | acme.sh                       | Legacy bash ([archive](archive/SETUP_LEGACY_2026-05-10.md)) |
| MacBook (otsmbpro16)                   | `otsmbpro16/`                                                     | acme.sh                       | Legacy `deploy-otsmbpro16.bash` ([archive](archive/SETUP_LEGACY_2026-05-10.md)) |
| Laptop (hpdevcore)                     | `hpdevcore/`                                                      | acme.sh                       | Legacy `deploy-hpdevcore.bash` ([archive](archive/SETUP_LEGACY_2026-05-10.md)) |
| OTS HAProxy / edge services            | `otsorundscore/` (`otsorundscore.olutechsys.com`, `otsorundscore.olutech.systems`, `*.otsorundscore.{olutechsys.com,olutech.systems}`) | acme.sh | **`scripts/deploy_certs.sh`** -> `/var/packages/haproxy/var/crt/` |
| MFT HAProxy / edge services            | `misfitsds/` (`misfitsds.olutechsys.com`, `misfitsds.olutech.systems`, `*.misfitsds.{olutechsys.com,olutech.systems}`)                 | acme.sh | **`scripts/deploy_certs.sh`** -> `/var/packages/haproxy/var/crt/` |

The previous local CA codebase (`setup-docker-tls.bash`, `deploy-nas-cert.bash`)
has been retired and archived to `/volume2/certs/archives/scripts-2026-04-27/`.
Recommended posture, in order:

- **SSH context** -- preferred default for admin access. Works without any
  Docker TCP listener at all and is unaffected by `daemon.json` `hosts`.
- **mTLS** (`daemon-mtls.json`, `tlsverify: true`, client cert required) --
  use only when remote TCP is genuinely needed. Defaults to the safe
  loopback bind `tcp://127.0.0.1:2376`; widen to a narrow lab bind
  (e.g. `tcp://10.0.1.15:2376` for otsorundscore) only with a matching
  firewall rule.
- **TLS-only** (`daemon-tls.json`, `tlsverify: false`) -- **legacy/lab-only**,
  retained for back-compat. Same loopback default in the reference file;
  treat as remote root if a TCP listener is reachable without client
  auth. Prefer SSH or mTLS instead.
