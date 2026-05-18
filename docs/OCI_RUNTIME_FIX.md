# OCI Runtime Error: Read-Only Filesystem Fix

## Error Message

```
Error response from daemon: failed to create task for container: 
failed to create shim task: OCI runtime create failed: runc create failed: 
unable to start container process: error during container init: 
open /proc/sys/net/ipv4/ping_group_range: read-only file system: unknown
```

## Root Cause

This error occurs when a container tries to modify kernel parameters (`/proc/sys/*`) that cannot be set within the container's namespace. This is **not** a file system permission issue—it's a kernel namespace isolation boundary.

The most common triggers:

1. Container uses `cap_add: [NET_ADMIN]` and tries to modify network sysctls
2. Container has `read_only: true` mount but attempts to write to /proc
3. Synology DSM (Cool mode / BTRFS) restricts `/proc/sys` access to prevent kernel instability

## Solution

### For Synology DSM Stacks

Set kernel parameters **on the NAS host** rather than inside containers:

```bash
# SSH into Synology NAS as root
ssh root@10.0.1.15

# Set required sysctl parameters
sysctl vm.overcommit_memory=1
sysctl net.core.somaxconn=512
sysctl net.ipv4.ping_group_range="0 65535"

# Make persistent across reboots via DSM Task Scheduler:
# Control Panel > System > Task Scheduler > Create > User-defined script
# Run as: root
# Schedule: Boot-up
# Script:
sysctl -w vm.overcommit_memory=1
sysctl -w net.core.somaxconn=512
sysctl -w net.ipv4.ping_group_range="0 65535"
```

### For Container Compose Files

Remove `cap_add: [NET_ADMIN]` if not strictly required:

**BEFORE:**

```yaml
services:
  myapp:
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv4.ping_group_range=0 65535
```

**AFTER:**

```yaml
services:
  myapp:
    # Removed NET_ADMIN cap (not needed if host has set sysctl)
    # Removed sysctls: (let host handle kernel parameters)
```

### For Services That Require NET_ADMIN

If your container legitimately needs `NET_ADMIN` (e.g., WireGuard, VPN tools):

```yaml
services:
  wireguard:
    image: linuxserver/wireguard:latest
    cap_add:
      - NET_ADMIN
    # Use sysctls with -w flag to suppress errors on read-only /proc/sys:
    sysctls:
      # These will fail gracefully if host has already set them
      - net.ipv4.conf.all.src_valid_mark=1
    # Alternatively: don't set sysctls if host already has them
```

## Affected Stacks

Review these for `NET_ADMIN` capability:

- `stacks/searxng/compose.yaml` (Redis) — redis doesn't need NET_ADMIN; remove if present
- `stacks/grafana-prom/compose.yaml` (wireguard-exporter) — needs NET_ADMIN; set host sysctls instead
- `stacks/acme-sh/compose.yaml` (network_mode: host) — already has host access; no issue

## Testing

After applying host-level sysctls, verify the container starts:

```bash
docker compose up -d <service>
docker logs <container> | head -20
```

If you see `ping_group_range` in logs but container is healthy, that's a warning (safe to ignore).

## Prevention

Add this check to `scripts/compose-validate.sh` to warn about problematic configs:

```bash
# Warn if any service uses NET_ADMIN + read_only: true
grep -l "NET_ADMIN" stacks/*/compose.yaml | while read f; do
  if grep -q "read_only: true" "$f"; then
    echo "WARNING: $f uses NET_ADMIN + read_only (may cause OCI runtime errors)"
  fi
done
```

## References

- Synology DSM Cool Mode: `/usr/local/etc/rc.d/` scripts run before container startup
- runc OCI spec: <https://github.com/opencontainers/runc>
- Docker sysctls: <https://docs.docker.com/compose/compose-file/compose-file-v3/#sysctls>
