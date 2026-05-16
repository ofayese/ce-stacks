# HAProxy Reverse Proxy Configuration

## Overview

HAProxy is installed as a **bare-metal service** on the Synology NAS (not containerized). It acts as the reverse proxy for all ce-stacks services, terminating SSL/TLS and routing traffic to backend containers.

## Installation & Management

### Location

- **Config (live)**: `/var/packages/haproxy/var/haproxy.cfg`
- **Cert directory (live)**: `/var/packages/haproxy/var/crt/` (PEM bundles deployed by `deploy_certs.sh`)
- **Config (repo / source of truth)**: `stacks/_haproxy/haproxy.cfg` — copy to live path after validation
- **Binary**: `/volume1/@appstore/haproxy/sbin/haproxy`
- **Log buffer**: `/var/packages/haproxy/var/http-access.log`

### Installation Method

Installed via **Synology Package Manager** → App Store → HAProxy (`@appstore/haproxy`)

Persists on `/volume1/` (across Docker stack resets)

### Startup & Restart

**Check status**:

```bash
ps aux | grep haproxy
# or via DSM Package Center → HAProxy → Status
```

**Validate config before reload**:

```bash
sudo /volume1/@appstore/haproxy/sbin/haproxy -c -f /var/packages/haproxy/var/haproxy.cfg
```

**Reload HAProxy** (after successful `-c`):

Open **DSM → Package Center → HAProxy → Action → Restart** (or Stop then Start).

---

## Configuration

### Main Config File

**Location (live)**: `/var/packages/haproxy/var/haproxy.cfg`  
**Source of truth**: `stacks/_haproxy/haproxy.cfg` (validate then copy to live path)

**Key Sections**:

1. **Global settings** - timeouts, logging, SSL defaults
2. **Frontend sections** - listen on port 80/443, define ACLs
3. **Backend sections** - upstream targets (container IPs/ports)

### Typical Backend Entry

```
backend services
    mode http
    server docker_app 10.0.1.15:8080
```

- `docker_app` - service name/label
- `10.0.1.15` - LAN IP (NAS IP)
- `8080` - container exposed port

### SSL/TLS Configuration

**Certificates** are deployed to `/var/packages/haproxy/var/crt/` by `stacks/acme-sh/scripts/deploy_certs.sh` (combined fullchain + privkey PEM bundles, one file per domain profile).

**Binding HTTPS**:

```
frontend https-in
    bind 10.0.1.15:443 ssl crt /var/packages/haproxy/var/crt/ alpn h2,http/1.1
    mode http
```

**Force HTTP → HTTPS**:

```
frontend http_in
    bind *:80
    redirect scheme https
```

---

## Common Tasks

### Add a New Backend Service

1. **Edit the repo config**:

   ```bash
   nano stacks/_haproxy/haproxy.cfg
   ```

2. **Add backend section**:

   ```
   backend my_service
       option httpchk GET /
       server service 10.0.1.15:9090 check
   ```

3. **Add host.map entry** (`stacks/_haproxy/maps/host.map`):

   ```
   my-service.olutechsys.com	my_service
   ```

4. **Validate config**:

   ```bash
   sudo /volume1/@appstore/haproxy/sbin/haproxy -c -f stacks/_haproxy/haproxy.cfg
   ```

5. **Copy to live path and reload**:

   ```bash
   sudo cp stacks/_haproxy/haproxy.cfg /var/packages/haproxy/var/haproxy.cfg
   ```

   Then restart HAProxy: **DSM → Package Center → HAProxy → Action → Restart**.

### Update SSL Certificate

When `acme-sh` renews certificates:

1. **Run deploy_certs.sh** to build and deploy updated bundles:

   ```bash
   STACK_ROOT=/volume2/docker/ce-stacks/stacks bash stacks/acme-sh/scripts/deploy_certs.sh
   ```

   This deploys PEM bundles to `/var/packages/haproxy/var/crt/` and runs `haproxy -c` automatically.

2. **Restart HAProxy** after successful validation:

   Open **DSM → Package Center → HAProxy → Action → Restart**.

### Check HAProxy Status

```bash
# View access logs
tail -f /var/packages/haproxy/var/http-access.log

# Count connections
ss -pltn | grep haproxy

# Test config syntax
sudo /volume1/@appstore/haproxy/sbin/haproxy -c -f /var/packages/haproxy/var/haproxy.cfg
```

---

## Troubleshooting

### HAProxy Won't Start

```bash
# Check config syntax
sudo /volume1/@appstore/haproxy/sbin/haproxy -c -f /var/packages/haproxy/var/haproxy.cfg

# View access logs
tail -50 /var/packages/haproxy/var/http-access.log
dmesg | tail -20

# Check port availability
ss -pltn | grep 80
ss -pltn | grep 443
```

**Common causes**:

- Port 80/443 already in use
- Certificate file missing or unreadable
- Config syntax error

### Backend Service Unreachable

1. **Verify backend is running**:

   ```bash
   docker ps | grep <service>
   ```

2. **Test port binding**:

   ```bash
   curl http://10.0.1.15:<port>/
   ```

3. **Check HAProxy logs**:

   ```bash
   tail -50 /var/log/haproxy.log | grep <service_name>
   ```

4. **Verify ACL rules**:

   ```
   # In haproxy.cfg, check:
   - acl conditions match your hostname
   - use_backend points to correct backend
   ```

### Performance / Slow Requests

**Check timeout settings** in `/var/packages/haproxy/var/haproxy.cfg`:

```
defaults
    timeout client      30000      # Client timeout (ms)
    timeout server      30000      # Backend timeout (ms)
    timeout connect     4000       # Connection timeout
```

**For DSM app portal reverse proxy** (reverse proxy requests to HAProxy):

- Set **timeout** to 600s in DSM Settings → Application Portal
- Enable **custom headers** (Upgrade, Connection) for WebSocket support

---

## Maintenance

### Backup Configuration

```bash
# Live config → repo (review diffs before committing)
cp /var/packages/haproxy/var/haproxy.cfg \
   stacks/_haproxy/haproxy.cfg.bak
git add stacks/_haproxy/haproxy.cfg.bak
```

### Monitor Certificate Expiration

```bash
# Check cert bundles in the live cert dir
openssl x509 -in /var/packages/haproxy/var/crt/otsorundscore.olutechsys.com.pem -noout -dates

# acme-sh auto-renews; run deploy_certs.sh after renewal then reload HAProxy
```

### Update HAProxy (via App Store)

Synology App Store will notify of updates. **After updating**:

```bash
# Verify version
/volume1/@appstore/haproxy/sbin/haproxy -v

# Validate config with new binary
sudo /volume1/@appstore/haproxy/sbin/haproxy -c -f /var/packages/haproxy/var/haproxy.cfg

# Check logs for any issues
tail -20 /var/packages/haproxy/var/http-access.log
```

---

## Related Documentation

- **ce-stacks README.md** → Network subnets, port bindings
- **acme-sh stack** → Certificate generation & renewal
- **Homepage stack** → Service portal routing examples

---

## Support

For detailed HAProxy documentation, see [official HAProxy docs](https://www.haproxy.org/)

For Synology-specific questions, check [Synology forums](https://community.synology.com/)

---

**Last Updated**: 2026-05-14

# End of HAProxy README
