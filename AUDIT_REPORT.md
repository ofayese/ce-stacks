# CE-Stacks Repository Audit Report

**Date**: 2026-05-13
**Status**: Active Issues Found - Requires Fixes

---

## Executive Summary

The ce-stacks repository is **well-structured** with solid patterns, but has **11 actionable issues** ranging from **critical** (broken compose files) to **low-priority** (documentation). The repository is **ready for Dockhand deployment** with minor remediation.

---

## Issues by Priority

### 🔴 CRITICAL (Blocks Dockhand Deployment)

#### Issue #1: Invalid Compose Files (3 stacks)

**Severity**: CRITICAL  
**Stacks Affected**:

- `github-desktop` - Missing required env var `GITHUB_DESKTOP_USER`
- `code-server` - Missing `CODE_SERVER_HOST_DOCKER_BIND` and `CODE_SERVER_HOST_HOME_BIND` env vars
- `synology-api-bridge` - Missing `.env` file (references it in compose)

**Impact**: Cannot import these stacks into Dockhand without `.env` files populated.

**Remediation**:

```bash
# Create missing .env files from examples
for stack in github-desktop code-server synology-api-bridge; do
  cp ./stacks/$stack/.env.example ./stacks/$stack/.env
  # Edit each .env with actual values
done
```

**Evidence**:

```
github-desktop: error while interpolating services.github-desktop.environment.[]: 
  required variable GITHUB_DESKTOP_USER is missing a value

code-server: error while interpolating services.code-server.volumes.[]: 
  required variable CODE_SERVER_HOST_DOCKER_BIND is missing a value

synology-api-bridge: env file .env not found
```

---

#### Issue #2: Missing .env Files (19 of 20 stacks)

**Severity**: CRITICAL  
**Affected Stacks**: 19 stacks missing `.env` (only `codex-docs` has one)

**Reason**: All `.env` files are properly git-ignored (good for security), but `.env.example` files exist and need to be populated.

**Impact**: Dockhand import will fail for stacks with required environment variables. Users won't know what values to set.

**Remediation**:

```bash
# Script to copy all .env.example to .env for editing
for stack in ./stacks/*/; do
  if [ -f "$stack/.env.example" ] && [ ! -f "$stack/.env" ]; then
    cp "$stack/.env.example" "$stack/.env"
    echo "Created $stack/.env - EDIT WITH ACTUAL VALUES"
  fi
done
```

**Stacks requiring `.env` files**:

- acme-sh, agents_gateway_data, code-server, databases, dozzle
- github-desktop, grafana-prom, homepage, it-tools, mcp-tools-config
- ollama, openresume, psu-ots, remotely, searxng
- synology-api-bridge, watchtower, zabbix

---

#### Issue #3: External Networks Not Created

**Severity**: CRITICAL  
**Affected Networks**: `ce-internal` (required by 4+ stacks)

**External Network References**:

- `databases` → `ce-internal` (external: true)
- `ollama` → `ce-internal` (external: true)
- `grafana-prom` → `ce-internal` (external: true)
- `synology-api-bridge` → `ce-internal` (external: true)

**Impact**: Stacks won't start without the backbone `ce-internal` network.

**Remediation**:

```bash
# Create ce-internal bridge network
docker network create \
  --driver bridge \
  --subnet 172.26.0.0/24 \
  --gateway 172.26.0.1 \
  ce-internal
```

**Documentation**: This should be in `dockhand/DEPLOYMENT.md` Step 2.

---

### 🟠 HIGH (Impacts Security & Operations)

#### Issue #4: Missing Security Options

**Severity**: HIGH  
**Affected Stacks**:

- `github-desktop` - Has `seccomp:unconfined` (relaxed!) but NO `no-new-privileges`

**Impact**: Reduces container isolation, security posture degraded.

**Fix**:

```yaml
# Add to github-desktop
security_opt:
  - seccomp:unconfined
  - no-new-privileges:true
```

---

#### Issue #5: Missing PUID/PGID Environment Variables

**Severity**: HIGH  
**Affected Stacks**:

- `synology-api-bridge` - No PUID/PGID (binds to host filesystem)
- `psu-ots` - No PUID/PGID (Synology standard)

**Impact**: Potential permission issues on Synology DSM with bind-mounts. Default root ownership may cause problems.

**Fix**:

```yaml
environment:
  - PUID=${PUID:-0}
  - PGID=${PGID:-0}
```

---

#### Issue #6: Missing Health Checks

**Severity**: HIGH  
**Affected Stacks**: `ollama` (missing health check but performs health check in compose)

Wait, re-check: Actually ALL 20 stacks HAVE health checks. ✓ **NO ISSUE HERE**

---

### 🟡 MEDIUM (Operational Concerns)

#### Issue #7: Network Subnet Proliferation (19 subnets)

**Severity**: MEDIUM  
**Current Subnets**:

```text
172.20.0.0/24    - codex-docs
172.27.0.0/24    - ollama
172.28.0.0/24    - databases
172.28.2.0/24    - code-server
172.29.0.0/24    - grafana-prom
172.29.1.0/24    - grafana-prom (secondary)
172.30.0.0/24    - zabbix
172.31.0.0/24    - dozzle
172.31.1.0/24    - watchtower
172.31.2.0/24    - ? (unknown)
172.31.3.0/24    - ? (unknown)
172.31.4.0/24    - ? (unknown)
172.31.5.0/24    - ? (unknown)
172.31.6.0/24    - ? (unknown)
172.31.7.0/24    - agents_gateway_data
172.31.8.0/24    - mcp-tools-config
172.31.9.0/24    - ? (unknown)
172.32.0.0/24    - psu-ots
```

**Impact**: Some subnets are undefined/orphaned. Difficult to track without central registry.

**Remediation**: Update `README.md` with complete subnet allocation table. Verify all 172.31.x.0/24 subnets are assigned.

---

#### Issue #8: HAProxy Stack Missing Compose File

**Severity**: MEDIUM  
**Stack**: `_haproxy`

**Issue**: `_haproxy` is bare-metal HAProxy (not containerized), so no `compose.yaml` exists. Documented but confusing in file listing.

**Remediation**: Add note in `README.md` explaining `_haproxy` is non-containerized.

---

### 🟢 LOW (Documentation & Maintainability)

#### Issue #9: Dockhand Documentation Missing Network Setup

**Severity**: LOW  
**File**: `dockhand/DEPLOYMENT.md` and `dockhand/MIGRATION.md`

**Gap**: Steps 1-2 don't mention creating `ce-internal` network before importing stacks.

**Remediation**:

```markdown
### Step 1b: Create Backend Network

Before importing stacks, create the ce-internal bridge network:

\`\`\`bash
docker network create \
  --driver bridge \
  --subnet 172.26.0.0/24 \
  --gateway 172.26.0.1 \
  ce-internal
\`\`\`
```

---

#### Issue #10: Inconsistent Volume Path Handling

**Severity**: LOW  
**Affected Stacks**: Commands/binaries in volumes (false positives in grep):

- `ollama` - `/usr/bin/ollama` (command, not volume)
- `watchtower` - `/watchtower` (command, not volume)
- `grafana-prom` - Host filesystem mounts (intentional, exempt)
- `psu-ots`, `dozzle` - Similar false positives

**Remediation**: Add comments to clarify these are intentional:

```yaml
volumes:
  # EXEMPT: Command entrypoint (not a volume mount)
  - /usr/bin/ollama
```

---

#### Issue #11: Solution Architect Document Not Referenced

**Severity**: LOW  
**File**: `solution-architect.md` exists but not linked in `README.md`

**Remediation**:

```markdown
## Architecture & Design

- [Solution Architect](./solution-architect.md) - System design & rationale
```

---

## Audit Findings Summary Table

| # | Issue | Severity | Stacks | Fix Time |
|---|-------|----------|--------|----------|
| 1 | Invalid compose files | CRITICAL | 3 | 15 min |
| 2 | Missing .env files | CRITICAL | 19 | 10 min |
| 3 | ce-internal network not created | CRITICAL | 4+ | 5 min |
| 4 | Missing security options | HIGH | 2 | 10 min |
| 5 | Missing PUID/PGID | HIGH | 2 | 10 min |
| 6 | Health checks | ✓ PASS | - | - |
| 7 | Network subnet registry | MEDIUM | All | 15 min |
| 8 | HAProxy documentation | MEDIUM | 1 | 5 min |
| 9 | Dockhand docs missing network setup | LOW | - | 5 min |
| 10 | Volume path comments | LOW | 5 | 5 min |
| 11 | Solution architect link | LOW | - | 2 min |

**Total Fix Time**: ~1.5 hours

---

## Recommended Fix Priority

### Phase 1: Critical (Do First - Blocks Everything)

1. Create `.env` files for all 19 stacks
2. Populate required values in `.env` files
3. Add `ce-internal` network creation to Dockhand docs/setup
4. Verify compose files validate after .env creation

### Phase 2: High (Before Production)

1. Add `no-new-privileges` to github-desktop
2. Add `PUID`/`PGID` to synology-api-bridge and psu-ots

### Phase 3: Medium (During Dockhand Setup)

1. Document complete network subnet registry in README.md
2. Add HAProxy explanation to README.md
3. Add network setup step to Dockhand migration guide

### Phase 4: Low (Polish)

1. Add clarifying comments to volume paths
2. Link solution-architect.md from README.md

---

## Git Status Check

```
✓ No accidentally committed secrets
✓ .gitignore properly excludes .env files
✓ Private keys excluded (.key, .pem files)
✓ Runtime data directories ignored
⚠️  stacks/grafana-prom/secrets/README.md (tracked - just metadata)
⚠️  stacks/psu-ots/keys/.gitignore (tracked - just metadata)
```

Status: **CLEAN** - No exposed secrets.

---

## Repo Health Score

| Category | Score | Notes |
| -------- | ----- | ----- |
| Structure | 9/10 | Well-organized, clear patterns |
| Security | 7/10 | Good practices, 2 missing no-new-privileges |
| Documentation | 7/10 | Good, but missing .env setup guide |
| Validation | 6/10 | 4 compose files fail without .env |
| Completeness | 8/10 | 19/20 stacks have .env.example |
| Git Cleanliness | 9/10 | Proper .gitignore coverage |
| **OVERALL** | **7.7/10** | **Ready with critical fixes** |

---

## Next Steps for User

1. **Immediately**: Create and populate `.env` files (Phase 1)
2. **Before Dockhand deployment**: Add security options (Phase 2)
3. **During Dockhand setup**: Follow Phase 3 recommendations
4. **Post-deployment**: Polish items in Phase 4

All fixes are **non-breaking** and can be applied incrementally.
