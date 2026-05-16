# HAProxy Reverse Proxy Configuration

## Overview

HAProxy is installed as a **bare-metal service** on the Synology NAS (not containerized). It acts as the reverse proxy for all ce-stacks services, terminating SSL/TLS and routing traffic to backend containers.

## Configuration

### Main Config File

**Location**: `/var/packages/haproxy/var/haproxy.cfg`

**Key Sections**:

1. **Global settings** - timeouts, logging, SSL defaults
2. **Frontend sections** - listen on port 8280 (HTTP redirect) / 8281 (HTTPS), 8282 (stats)
3. **Backend sections** - upstream targets (container IPs/ports); routing via `maps/host.map`

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

**Certificates** deployed by `stacks/acme-sh/scripts/deploy_certs.sh` to `/var/packages/haproxy/var/crt/` (PEM bundles = fullchain + key, one file per cert profile).

**Binding HTTPS**:

```
frontend https-in
    bind 10.0.1.15:8281 ssl crt /var/packages/haproxy/var/crt/ alpn h2,http/1.1
    mode http
```

**Force HTTP → HTTPS**:

```
frontend http-redirect
    bind 10.0.1.15:8280
    redirect scheme https code 301
```

---

## Common Tasks

### Add a New Backend Service

1. **Edit HAProxy config**:

   ```bash
   sudo nano /var/packages/haproxy/var/haproxy.cfg
   ```

2. **Add backend section**:

   ```
   backend my_service
       mode http
       server service 10.0.1.15:9090
   ```

3. **Add ACL + route in frontend**:

   ```
   frontend https_in
       acl my_service_req hdr(host) -i my-service.domain.com
       use_backend my_service if my_service_req
   ```

4. **Validate config**:

   ```bash
   sudo /volume1/@appstore/haproxy/sbin/haproxy -c -f /var/packages/haproxy/var/haproxy.cfg
   ```

5. **Restart**:

   ```bash
   bash stacks/_haproxy/haproxy-restart.sh
   ```

### Update SSL Certificate

When `acme-sh` renews certificates:

1. **Verify new cert exists**:

   ```bash
   ls -la /var/packages/haproxy/var/crt/
   ```

2. **Restart HAProxy** (automatically reloads certs):

   ```bash
   bash stacks/_haproxy/haproxy-restart.sh
   ```

### Check HAProxy Status

```bash
# View logs
tail -f /var/log/haproxy.log

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

# View system logs
tail -50 /var/log/haproxy.log
dmesg | tail -20

# Check port availability
ss -pltn | grep 8280
ss -pltn | grep 8281
```

**Common causes**:

- Port 8280/8281 already in use (check with `ss -pltn`)
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
# Backup to repo
cp /var/packages/haproxy/var/haproxy.cfg \
   stacks/_haproxy/haproxy.cfg.bak

# Keep in version control (git)
git add stacks/_haproxy/haproxy.cfg.bak
```

### Monitor Certificate Expiration

```bash
# Check certificate validity
openssl x509 -in /volume2/certs/acme/wildcard/fullchain.pem -noout -dates

# acme-sh should auto-renew, but verify cron
crontab -l | grep acme
```

### Update HAProxy (via App Store)

Synology App Store will notify of updates. **After updating**:

```bash
# Verify version
haproxy -v

# Restart with new binary
bash stacks/_haproxy/haproxy-restart.sh

# Check logs for any issues
tail -20 /var/log/haproxy.log
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
