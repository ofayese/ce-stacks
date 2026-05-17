# Ollama Stack - Network Connection Fix

**Issue**: Open WebUI cannot connect to Ollama

```
Error: Cannot connect to host 10.0.1.15:11434 ssl:default [Connect call failed ('10.0.1.15', 11434)]
```

**Root Cause**: Network architecture mismatch

- Ollama was using `network_mode: host` (direct host network)
- Open WebUI was using `ollama-net` bridge network
- When open-webui tried to reach `10.0.1.15:11434` from bridge network, DNS resolution failed

**Solution**: Both services now use the same `ollama-net` bridge network

- Ollama: `network_mode: host` -> `networks: [ollama-net]` with `ports: [10.0.1.15:11434:11434]`
- Open WebUI: `OLLAMA_BASE_URL=http://10.0.1.15:11434` -> `OLLAMA_BASE_URL=http://otsai-server:11434`

---

## Changes Made to compose.yaml

### Ollama Service

**Before**:

```yaml
network_mode: "host"
```

**After**:

```yaml
ports:
  - 10.0.1.15:11434:11434
networks:
  - ollama-net
```

**Why**:

- Bridges the gap between services on same network
- Port 11434 still exposed to NAS LAN IP (10.0.1.15)
- Model pulls to registry.ollama.ai work fine from bridge networks
- Both services now use bridge DNS to communicate

### Open WebUI Service

**Before**:

```yaml
- OLLAMA_BASE_URL=http://10.0.1.15:11434
```

**After**:

```yaml
- OLLAMA_BASE_URL=http://otsai-server:11434
```

**Why**:

- `otsai-server` is the container hostname (matches `container_name: otsai-server`)
- Bridge network DNS resolves `otsai-server` to Ollama's internal IP
- More reliable than trying to reach external NAS IP from within bridge network

---

## How to Apply Fix

### On NAS, restart the stack

```bash
cd /volume2/docker/ce-stacks/stacks/ollama

# Pull latest compose (updated)
git pull origin main

# Restart stack
docker compose down
docker compose up -d

# Wait for startup (Ollama model pulls take time)
sleep 60

# Verify both are healthy
docker ps | grep otsai
# Both should show (healthy)

# Verify connection works
docker logs otsai-webui | grep -i "ollama\|connection"
```

---

## Verification

```bash
# Check if containers are healthy
docker ps | grep otsai
# Expected: Both Up, showing (healthy)

# Check open-webui logs for successful connection
docker logs otsai-webui | tail -30
# Should NOT show connection errors

# Test from open-webui UI
curl http://10.0.1.15:8893
# Should load without errors
```

---

## Why This Works

**Container Networking 101**:

- Services on the **same bridge network** can reach each other via container hostname
- `otsai-server` hostname resolves to Ollama's internal bridge IP (e.g., 172.27.0.2)
- Open WebUI at 172.27.0.3 can reach `http://otsai-server:11434`
- External clients still reach port 11434 via `10.0.1.15:11434` port binding

**Synology Docker DNS**:

- Broken: `127.0.0.11` (standard Docker daemon DNS) is unreachable on Synology
- Works: Internal bridge network DNS (resolved via `127.0.0.1:53` on the container)
- Outbound to internet (registry.ollama.ai) works fine from bridge networks

---

## Key Learnings

1. **network_mode: host** is useful when you need:
   - Host network access (model registry pulls)
   - Direct port exposure
   - But incompatible with containers on bridge networks

2. **Bridge networks** are better for inter-service communication:
   - Built-in DNS for container-to-container
   - Port bindings still work for external access
   - Safer isolation than host mode

3. **Synology quirk**: Docker's default DNS (127.0.0.11) doesn't work, but Synology's bridge DNS does.

---

## Related Documentation

- See `stacks/ollama/README.md` for Ollama architecture notes
- See `README.md` network subnets table for 172.27.0.0/24 allocation
- See compose.yaml comments for model memory calculations
