# NAS host SSH setup (PSU auto-remediation)

`Invoke-PSUJob_AutoRemediation` can run **Docker on the Synology host** over **SSH** so the PSU container stays isolated (no `docker.sock` mount). Prerequisite: cryptographic trust and a user that can run `docker compose` non-interactively.

## 1. Generate a dedicated key pair

On your workstation or the NAS:

```bash
ssh-keygen -t ed25519 -f psu_remediation_key -N ""
```

Keep **`psu_remediation_key`** private; distribute only **`psu_remediation_key.pub`**.

## 2. Authorize the key on the NAS

Append the **public** key to the target user's `authorized_keys` (example user `laolufayese`):

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cat psu_remediation_key.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

**Docker group:** the same user must be able to run `docker` / `docker compose` **without sudo** (e.g. member of the `docker` group on DSM where that applies, or your documented NAS layout). Test:

```bash
ssh -i psu_remediation_key YOUR_USER@NAS_IP 'docker info >/dev/null && echo ok'
```

## 3. Provide the private key to PSU

### Option A - File mount (repo template)

1. Copy the private key onto the NAS (not into Git), e.g.  
   `/volume2/docker/ce-stacks/stacks/psu-ots/keys/psu_remediation_key`
2. Restrict permissions:

```bash
chmod 600 /volume2/docker/ce-stacks/stacks/psu-ots/keys/psu_remediation_key
```

1. Compose mounts **`${STACK_ROOT}/psu-ots/keys` → `/ssh-keys:ro`**. Set in **`stacks/psu-ots/.env`**:

- `SSH_KEY_PATH=/ssh-keys/psu_remediation_key`

The **`keys/`** directory is gitignored except for **`keys/.gitignore`** - **never** commit private material.

### Option B - PSU secret / variable

Store the private key material as a **Secret** in PSU (Platform → Variables), copy it into a file from a one-shot automation, and point **`SSH_KEY_PATH`** at that path. Prefer **0600** permissions and a RAM-backed path if your threat model requires it.

## 4. Container environment

In **`stacks/psu-ots/.env`** (then recreate the container):

| Variable | Example | Purpose |
|----------|---------|---------|
| `NAS_HOST_IP` | `10.0.1.15` | SSH target |
| `NAS_SSH_USER` | `laolufayese` | SSH login |
| `SSH_KEY_PATH` | `/ssh-keys/psu_remediation_key` | Private key path **inside** the container |
| `NAS_HOST_STACKS_ROOT` | `/volume2/docker/ce-stacks/stacks` | Host path used in `docker compose` over SSH |

If **`PSU_STACK_ROOT`** inside the container is **`/nas-repo/stacks`**, **`NAS_HOST_STACKS_ROOT` is required** so the remote script can `cd` to the real host directory.

Optional:

- **`NAS_SSH_KNOWN_HOSTS_FILE`** - override the default known_hosts file (default: `/data/reports/_psu_ssh_known_hosts`).

## 5. Enable remediation flags

- **`PSU_REMEDIATION_ENABLED=1`**
- Disk pressure + **`PSU_REMEDIATION_DOCKER_PRUNE=1`** → remote **`docker image prune -a -f`**
- Floating tags in latest **image-drift** report + **`PSU_ALLOW_STACK_RESTART=1`** → remote **`docker compose pull` + `up -d`** per stack

Recreate PSU after editing **`.env`**:

```bash
cd "${STACK_ROOT}/psu-ots"
docker compose up -d --force-recreate
```

## 6. Logs and dashboards

SSH **stdout** / **stderr** and exit codes are stored in the **`auto-remediation-*.json`** job output and, when possible, appended under **`remediationSshAppendix`** on the **latest** **`image-drift-*.json`** and **`nas-health-*.json`** reports so NOC panels can show recent host actions next to the scan that triggered them.

## Security notes

- Use a **dedicated** key with **minimal** rights (Docker + read on stack dirs only if you can constrain further).
- Prefer **LAN** SSH only; do not expose SSH to the WAN for this automation.
- First connection uses **`StrictHostKeyChecking=accept-new`**; review **`_psu_ssh_known_hosts`** after the first successful run.
