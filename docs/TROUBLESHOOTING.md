# Troubleshooting Ce-Stacks

## Stack Health Issues

### Checking Stack Status

1. **Via Dockhand UI**
   - Open <http://10.0.1.15:3866>
   - Settings -> Stacks -> [Stack Name]
   - Check "Health" status (Green = healthy, Red = unhealthy)

2. **Via Docker CLI**

   ```bash
   docker ps --filter "status=exited"  # Show stopped containers
   docker logs <container_name>        # View container logs
   docker inspect <container_name>     # View detailed status
   ```

3. **Manual Health Check**

   ```bash
   # Example: test health check command
   docker exec <container_name> [health_test_command]
   ```

### Common Issues & Solutions

#### "Network ce-internal not found"

**Symptom**: Stacks won't start (agents_gateway_data, databases, grafana-prom, ollama, synology-api-bridge)

**Cause**: External network was not created before importing stacks

**Fix**:

```bash
docker network create \
  --driver bridge \
  --subnet 172.26.0.0/24 \
  --gateway 172.26.0.1 \
  ce-internal
```

**Verify**:

```bash
docker network inspect ce-internal
```

---

#### "required variable X is missing a value"

**Symptom**: Compose file fails validation or won't start

**Cause**: `.env` file missing or incomplete

**Fix**:

1. Check `.env` file exists: `ls stacks/<stack>/.env`
2. If missing, create from example: `cp stacks/<stack>/.env.example stacks/<stack>/.env`
3. Edit and populate all required variables
4. Test: `docker compose -f stacks/<stack>/compose.yaml config`

**Common required variables**:

- `code-server`: CODE_SERVER_HOST_DOCKER_BIND, CODE_SERVER_HOST_HOME_BIND
- `github-desktop`: GITHUB_DESKTOP_USER
- `databases`: MARIADB_ROOT_PASSWORD, POSTGRES_PASSWORD
- `acme-sh`: CF_Token (Cloudflare API token)

---

#### "Permission denied" on bind-mount paths

**Symptom**: Container crashes or can't write to volumes

**Cause**: Incorrect PUID/PGID or file ownership

**Fix**:

```bash
# Verify PUID/PGID in .env match NAS user
grep PUID stacks/<stack>/.env

# Fix ownership on bind-mount directories
bash scripts/fix-permissions.sh
```

---

#### Container keeps restarting (CrashLoopBackOff)

**Symptom**: `docker ps` shows "Restart count: X"

**Cause**: Health check failing, app crashing, or resource limits

**Debug**:

```bash
# Check logs for errors
docker logs <container_name> --tail 50

# Check health status
docker inspect <container_name> | grep -A 10 "Health"

# Check resource usage
docker stats <container_name>

# Check memory/CPU limits
docker inspect <container_name> | grep -E "(MemoryLimit|CpuShares)"
```

---

#### Health Check Fails (Status: Unhealthy)

**Symptom**: Stack running but health check failing

**Background**: Most stacks use HTTP or TCP health checks. See dockhand/docs/HEALTH_CHECK_SOLUTION.md for detailed troubleshooting.

**Quick Debug**:

```bash
# Test HTTP health check
docker exec <container_name> curl -f http://127.0.0.1:<port>/health || echo "Failed"

# Test TCP health check
docker exec <container_name> nc -z 127.0.0.1 <port> && echo "Healthy"

# View health check config
docker inspect <container_name> | grep -A 10 '"Health"'
```

---

### Network Connectivity Issues

#### Can't reach container from host (10.0.1.15)

**Cause**: Port binding or firewall rules

**Check**:

```bash
# Verify port binding
docker port <container_name>

# Test connectivity
curl -v http://10.0.1.15:<port>/

# Check DSM firewall
# Settings -> Security -> Firewall -> Edit rules
```

#### Containers can't reach each other

**Cause**: Wrong network or external network not created

**Debug**:

```bash
# Check which networks a container is on
docker inspect <container_name> | grep -A 5 '"Networks"'

# Test DNS resolution (if using service names)
docker exec <container_name> nslookup <service_name>

# Test connectivity
docker exec <container_name> ping <other_container_ip>
```

---

## Performance Issues

#### High CPU/Memory Usage

```bash
# Monitor resource usage
docker stats

# Check logs for errors/warnings
docker logs <container_name>

# Compare against memory limit in compose
grep mem_limit stacks/<stack>/compose.yaml
```

#### Slow Startup

**Check**:

1. `start_period` in health check (how long to wait before health checks)
2. Image size / pull time
3. NAS disk I/O (via DSM Resource Monitor)
4. Network latency to registries

---

## Dockhand Troubleshooting

### Dockhand won't start

```bash
# Check if container is running
docker ps | grep dockhand

# Check logs
docker logs dockhand

# Check if port 3866 is listening
nc -z 10.0.1.15 3866 && echo "Port open"

# Restart
sudo /usr/local/etc/rc.d/dockhand.sh stop
sudo /usr/local/etc/rc.d/dockhand.sh start
```

### Git webhook not triggering

**Setup**:

1. Dockhand UI -> Settings -> Webhooks
2. Copy webhook URL (e.g., <http://10.0.1.15:3866/webhook/>...)
3. GitHub repo -> Settings -> Webhooks -> Add webhook
4. Set URL to Dockhand webhook URL
5. Select "Pushes" as trigger event

**Debug**:

- Check Dockhand logs: `docker logs dockhand`
- Verify webhook delivery: GitHub -> Repo -> Settings -> Webhooks -> Recent Deliveries
- Check network routing (NAT from GitHub to internal IP)

---

## Validation & Testing

### Run Validation Locally

```bash
# Validate all compose files
bash scripts/compose-validate.sh

# Verify repo layout
bash scripts/verify-repo-layout.sh

# Test compose config (single stack)
docker compose -f stacks/<stack>/compose.yaml config
```

### Pre-Deployment Checklist

```bash
# [OK] Network exists
docker network inspect ce-internal

# [OK] All .env files populated
for stack in stacks/*/; do
  [ -f "$stack/.env" ] && echo "[OK] $(basename $stack)" || echo "[FAIL] $(basename $stack)"
done

# [OK] Validation passes
bash scripts/compose-validate.sh

# [OK] No secrets in git
git ls-files | grep -v ".example" | xargs grep -l "password\|token\|key" || echo "[OK] Clean"
```

---

## When to Check Dockhand Docs

The dockhand/docs/ directory has specialized guides:

- HEALTH_CHECK_SOLUTION.md -- Comprehensive health check troubleshooting
- HEALTH_CHECK_DEBUG.md -- Detailed debugging steps
- MIGRATION.md -- Migration from Portainer to Dockhand
- DEPLOYMENT.md -- Step-by-step deployment guide

---

## Support

1. Check this file (TROUBLESHOOTING.md)
2. Check dockhand/docs/ for Dockhand-specific issues
3. Check individual stack README.md files (in stacks/<name>/)
4. Review Docker logs: `docker logs <container_name>`
5. Consult [Docker documentation](https://docs.docker.com/)

---

**Last Updated**: 2026-05-14

# End of TROUBLESHOOTING.md
