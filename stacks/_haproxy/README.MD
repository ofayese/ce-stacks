# HAProxy Reverse Proxy Configuration

## Overview

HAProxy is installed as a **bare-metal service** on the Synology NAS (not containerized). It acts as the reverse proxy for all ce-stacks services, terminating SSL/TLS and routing traffic to backend containers.

> **IMPORTANT -- Configuration Deployment**
>
> Always apply `haproxy.cfg` changes through the **DSM Package Center GUI editor**, never via `sudo cp` from SSH.
> Direct file copy outside of DSM's control corrupts the package state and triggers a "repair required" loop.
> See [Applying Configuration Changes](#applying-configuration-changes) below.

---

## Configuration

### Main Config File

**Repo source of truth**: `stacks/_haproxy/haproxy.cfg`
**Live location (managed by DSM)**: `/var/packages/haproxy/var/haproxy.cfg`

**Key Sections**:

1. **Global settings** -- timeouts, logging, SSL defaults
2. **Frontend sections** -- listen on port 8280 (HTTP redirect) / 8281 (HTTPS) / 8282 (stats)
3. **Backend sections** -- upstream targets (container IPs/ports); routing via `maps/host.map`

### Typical Backend Entry

```
backend services
    mode http
    server docker_app 10.0.1.15:8080
```

- `docker_app` -- service name/label
- `10.0.1.15` -- LAN IP (NAS IP)
- `8080` -- container exposed port

### SSL/TLS Configuration

**Certificates** deployed by `stacks/acme-sh/scripts/deploy_certs.sh` to `/var/packages/haproxy/var/crt/` (PEM bundles = fullchain + key, one file per cert profile).

**Binding HTTPS**:

```
frontend https-in
    bind 10.0.1.15:8281 ssl crt /var/packages/haproxy/var/crt/ alpn h2,http/1.1
    mode http
```

**Force HTTP -> HTTPS**:

```
frontend http-redirect
    bind 10.0.1.15:8280
    redirect scheme https code 301
```

---

## Applying Configuration Changes

### Standard update procedure (GUI route)

1. **Edit the repo file** -- make all changes in `stacks/_haproxy/haproxy.cfg`.

2. **Validate locally via SSH** (read-only, safe):

   ```bash
   sudo /volume1/@appstore/haproxy/sbin/haproxy -c -f /var/packages/haproxy/var/haproxy.cfg
   ```

   *(This reads the current live file. To pre-validate before applying, save to a temp path and point `-f` at it.)*

3. **Open DSM Package Center** -> HAProxy -> click **Open**.

4. In the HAProxy web UI, click **Configuration** (or the edit/pencil icon for the config file).

5. **Select all and paste** the full contents of `stacks/_haproxy/haproxy.cfg`.

6. Click **Apply** / **Save**. DSM validates and restarts HAProxy within its own lifecycle -- no manual restart needed.

7. **Verify TLS** from SSH:

   ```bash
   CONNECT_HOST=10.0.1.15 CONNECT_PORT=8281 \
     SNI=psu.olutechsys.com MIN_VALID_DAYS=21 \
     bash /volume2/docker/ce-stacks/stacks/acme-sh/scripts/verify_serving.sh
   ```

8. **Commit** the repo change:

   ```bash
   git add stacks/_haproxy/haproxy.cfg
   git commit -m "fix(_haproxy): <description of change>"
   ```

> **Why not `sudo cp`?**
> The Synology HAProxy package (`synopkg`) maintains internal state metadata. Writing the config file directly via SSH bypasses DSM's lifecycle hooks, causing a state mismatch that forces a package repair on next restart. The `start-stop-status` restart script also requires environment variables injected only by `synopkg` -- calling it from a plain sudo shell always fails with "Environment variables are not set."

---

## Common Tasks

### Add a New Backend Service

1. **Edit the repo config** -- `stacks/_haproxy/haproxy.cfg`:

   Add a backend section:

   ```
   backend my_service-be
       mode http
       option httpchk GET /
       server service 10.0.1.15:9090 check
   ```

   Add the hostname entry to `maps/host.map`:

   ```
   my-service.olutechsys.com    my_service-be
   ```

2. **Apply via DSM GUI** -- follow the [Applying Configuration Changes](#applying-configuration-changes) steps above.

3. **Verify**:

   ```bash
   curl -sk https://my-service.olutechsys.com/ -o /dev/null -w "%{http_code}\n"
   ```

### Update SSL Certificates

When `acme-sh` renews certificates:

1. **Deploy PEM bundles** (SSH is safe here -- cert dir write does not affect package state):

   ```bash
   sudo bash -c 'STACK_ROOT=/volume2/docker/ce-stacks/stacks \
     bash /volume2/docker/ce-stacks/stacks/acme-sh/scripts/deploy_certs.sh'
   ```

2. **Restart HAProxy via DSM GUI** -- Package Center -> HAProxy -> Action -> Restart.
   *(HAProxy does not hot-reload certs; a restart is required.)*

3. **Verify**:

   ```bash
   CONNECT_HOST=10.0.1.15 CONNECT_PORT=8281 \
     SNI=olutechsys.com MIN_VALID_DAYS=21 \
     bash /volume2/docker/ce-stacks/stacks/acme-sh/scripts/verify_serving.sh
   ```

### Check HAProxy Status

```bash
# View access logs
tail -f /var/packages/haproxy/var/http-access.log

# Active connections
ss -pltn | grep haproxy

# Validate config syntax (safe, read-only)
sudo /volume1/@appstore/haproxy/sbin/haproxy -c -f /var/packages/haproxy/var/haproxy.cfg
```

---

## Troubleshooting

### HAProxy Shows "Repair Required" in DSM

**Cause**: Config file was modified directly via SSH (`sudo cp`) outside DSM's control.
**Fix**: Let the DSM repair complete, then re-apply the config via the GUI editor.

### HAProxy Won't Start After GUI Apply

```bash
# Validate config syntax
sudo /volume1/@appstore/haproxy/sbin/haproxy -c -f /var/packages/haproxy/var/haproxy.cfg

# Check cert files exist and are owned correctly
ls -la /var/packages/haproxy/var/crt/

# Re-deploy certs if missing or wrong ownership (must be sc-haproxy:synocommunity 640)
sudo bash -c 'STACK_ROOT=/volume2/docker/ce-stacks/stacks \
  bash /volume2/docker/ce-stacks/stacks/acme-sh/scripts/deploy_certs.sh'
```

**Common causes**:

- Port 8280/8281 already in use -- `ss -pltn | grep 828`
- Certificate file missing or unreadable (must be `sc-haproxy:synocommunity`, mode `640`)
- Config syntax error -- run the `-c` check above

### HAProxy Serving `haproxy-default` Self-Signed Cert

**Cause**: No readable PEM bundles in `/var/packages/haproxy/var/crt/`, or bundles owned `root:root`.
**Fix**:

```bash
sudo bash -c 'STACK_ROOT=/volume2/docker/ce-stacks/stacks \
  bash /volume2/docker/ce-stacks/stacks/acme-sh/scripts/deploy_certs.sh'
ls -la /var/packages/haproxy/var/crt/
# Then: DSM Package Center -> HAProxy -> Action -> Restart
```

### Backend Service Unreachable

1. Verify backend is running: `docker ps | grep <service>`
2. Test port directly: `curl http://10.0.1.15:<port>/`
3. Check logs: `tail -50 /var/packages/haproxy/var/http-access.log | grep <service>`
4. Verify `maps/host.map` has the correct hostname -> backend name mapping

### Performance / Slow Requests

Check timeout settings in `stacks/_haproxy/haproxy.cfg`:

```
defaults
    timeout connect 5s
    timeout client  50s
    timeout server  50s
    timeout tunnel  1h   # required for WebSocket / long-poll
```

For WebSocket services (e.g. code-server), ensure `timeout tunnel 1h` is set in defaults. If routing through DSM Application Portal as an additional hop, also enable custom headers (Upgrade, Connection) there.

---

## Maintenance

### Backup / Drift Check

The repo is the source of truth. After any GUI change, verify no drift:

```bash
diff /var/packages/haproxy/var/haproxy.cfg \
     /volume2/docker/ce-stacks/stacks/_haproxy/haproxy.cfg
```

If drift is found, copy the live config back to the repo, review, and commit.

### Monitor Certificate Expiration

```bash
# Check cert validity
openssl x509 -in /volume2/certs/acme/wildcard/fullchain.pem -noout -dates

# Verify acme-sh renewal schedule
docker exec AcmeSh /acme-sh-entrypoint.sh --list
```

### Update HAProxy (via App Store)

After Synology App Store updates HAProxy, the live config may be reset to the stock default. Re-apply from the repo via the GUI editor immediately after updating.

---

## Related Documentation

- **ce-stacks README.md** -> Network subnets, port bindings
- **acme-sh stack** -> Certificate generation, renewal, and deployment (`deploy_certs.sh`)
- **Homepage stack** -> Service portal routing examples
- **`maps/host.map`** -> Hostname -> backend routing table

---

**Last Updated**: 2026-05-16
