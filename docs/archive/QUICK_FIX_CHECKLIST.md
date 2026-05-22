# Quick Fix Checklist - Ce-Stacks Audit

Use this checklist to fix all identified issues before Dockhand deployment.

---

## 2026-05-15 -- Items now obsolete

The following items in this checklist are **automated** by
`scripts/init-nas.sh` (and `scripts/bootstrap-env.sh --apply`, which it
invokes) and by the RC-script changes from
[`implementation_plan.md`](./implementation_plan.md). You can skip the manual
shell snippets below and just run `bash scripts/init-nas.sh` on the NAS:

- ~~Fix #1: Create ce-internal Network~~ -- now created by both `init-nas.sh` and `dockhand/scripts/dockhand-start.sh::ensure_ce_internal()`.
- ~~Fix #2: Create All Missing .env Files~~ -- `scripts/bootstrap-env.sh --apply` materializes every `.env` from its `.env.example` (operator still edits real values).
- ~~Fix #3: Verify All Compose Files Now Validate~~ -- `scripts/compose-validate.sh` is the canonical check; run after editing `.env` values.
- ~~Fix #10: Link Solution Architect Document~~ -- added to `README.md` "Architecture & Design".

The High/Medium/Low items below (security_opt additions, PUID/PGID env
additions, subnet registry, HAProxy doc, etc.) remain manual.

---

## [RED] CRITICAL FIXES (Do These First!)

### Fix #1: Create ce-internal Network

#### Time: 5 minutes

```bash
# Run on NAS before importing stacks
docker network create \
  --driver bridge \
  --subnet 172.26.0.0/24 \
  --gateway 172.26.0.1 \
  ce-internal

# Verify
docker network ls | grep ce-internal
docker network inspect ce-internal
```

#### Add to Dockhand docs

Update `dockhand/MIGRATION.md` Step 1 to include this.

---

### Fix #2: Create All Missing .env Files

#### Time: 5 minutes

**Time: 5 minutes** (script provided)

```bash
#!/bin/bash
# Create all missing .env files from examples

cd /volume2/docker/ce-stacks

for stack in acme-sh agents_gateway_data code-server databases dozzle \
             github-desktop grafana-prom homepage it-tools mcp-tools-config \
             ollama openresume otspsu remotely searxng synology-api-bridge \
             watchtower zabbix; do
  
  if [ -f "stacks/$stack/.env.example" ] && [ ! -f "stacks/$stack/.env" ]; then
    cp "stacks/$stack/.env.example" "stacks/$stack/.env"
    echo "[OK] Created stacks/$stack/.env - EDIT WITH ACTUAL VALUES"
  fi
done

# DO NOT COMMIT .env files (git-ignored)
# Edit each .env with real values specific to your environment
```

#### Action After Script

**Action After Script**:

- [ ] Edit each `.env` file with actual values (passwords, API keys, etc.)
- [ ] Test compose file: `docker compose -f stacks/<stack>/compose.yaml config`
- [ ] Verify all 19 .env files are populated

#### Stacks to populate

**Stacks to populate**:

- acme-sh
- agents_gateway_data
- code-server (needs CODE_SERVER_HOST_DOCKER_BIND, CODE_SERVER_HOST_HOME_BIND)
- databases (needs MariaDB/PostgreSQL passwords)
- dozzle
- github-desktop (needs GITHUB_DESKTOP_USER)
- grafana-prom (needs Prometheus config)
- homepage
- it-tools
- mcp-tools-config
- ollama
- openresume
- otspsu
- remotely
- searxng
- synology-api-bridge (needs BRIDGE_SHARED_SECRET)
- watchtower
- zabbix

---

### Fix #3: Verify All Compose Files Now Validate

#### Time: 10 minutes

**Time: 10 minutes**

```bash
#!/bin/bash
# After creating .env files, validate all compose files

VALID=0
INVALID=0

for compose in $(find ./stacks -name "compose.yaml" -o -name "docker-compose.yml"); do
  STACK=$(dirname "$compose" | xargs basename)
  
  if docker compose -f "$compose" config >/dev/null 2>&1; then
    echo "[OK] $STACK"
    VALID=$((VALID + 1))
  else
    echo "[FAIL] $STACK - INVALID"
    docker compose -f "$compose" config 2>&1 | head -5
    INVALID=$((INVALID + 1))
  fi
done

echo ""
echo "Summary: $VALID valid, $INVALID invalid"
```

#### Expected Result

**Expected Result**: All 20 stacks should validate successfully.

---

## [ORANGE] HIGH PRIORITY FIXES (Do After Critical)

#### Time: 10 minutesing Security Options

**Time: 10 minutes**

#### github-desktop/compose.yaml

Add `no-new-privileges: true` to security_opt:

```yaml
security_opt:
  - seccomp:unconfined
  - no-new-privileges:true
```

#### Time: 10 minutesing PUID/PGID Environment Variables

**Time: 10 minutes**

#### synology-api-bridge/compose.yaml

Add to environment section:

```yaml
environment:
  - PUID=${PUID:-0}
  - PGID=${PGID:-0}
  # ... existing vars ...
```

#### otspsu/compose.yaml

Add to environment section:

```yaml
environment:
  - PUID=${PUID:-0}
  - PGID=${PGID:-0}
  # ... existing vars ...
```

---

## [YELLOW] MEDIUM PRIORITY FIXES (Nice to Have)

### Fix #6: Update README.md with Complete Network Subnet Registry

Add to `README.md` Network Subnets section:

```markdown
## Network Subnets

All bridge networks use explicit /24 subnets to prevent Docker's auto-assigned /16 ranges.

| Stack | Network name | Subnet | Status |
|---|---|---|---|
| (backbone) | ce-internal | 172.26.0.0/24 | External; created at setup |
| ollama | ollama-net | 172.27.0.0/24 | [OK] |
| databases | db-net | 172.28.0.0/24 | [OK] |
| code-server | code-server-net | 172.28.2.0/24 | [OK] |
| grafana-prom | grafana-net | 172.29.0.0/24 | [OK] |
| grafana-prom | prometheus-net | 172.29.1.0/24 | [OK] |
| zabbix | zabbix-net | 172.30.0.0/24 | [OK] |
| dozzle | dozzle-net | 172.31.0.0/24 | [OK] |
| watchtower | watchtower-net | 172.31.1.0/24 | [OK] |
| agents_gateway_data | agents-gateway-net | 172.31.7.0/24 | [OK] |
| mcp-tools-config | mcp-tools-net | 172.31.8.0/24 | [OK] |
| otspsu | otspsu-net | 172.32.0.0/24 | [OK] |
| codex-docs | codex-net | 172.20.0.0/24 | [OK] |
```

---

### Fix #7: Document HAProxy in README.md

Add to README:

```markdown
## Special Cases

### HAProxy (_haproxy)

The `_haproxy` directory contains bare-metal HAProxy configuration (not containerized).
It is managed separately via Synology's built-in HAProxy installation.
See `_haproxy/` directory for details.
```

---

### Fix #8: Update Dockhand Migration Docs - Add Network Setup

Update `dockhand/MIGRATION.md` Step 1:

```markdown
## Step 1: Pre-Migration Preparation

Your stacks are already in version control at `/volume2/docker/ce-stacks/stacks/`.

### 1a: Create Backend Network

The `ce-internal` network is required by several stacks. Create it first:

\`\`\`bash
docker network create \
  --driver bridge \
  --subnet 172.26.0.0/24 \
  --gateway 172.26.0.1 \
  ce-internal

# Verify
docker network inspect ce-internal
\`\`\`

### 1b: Verify Stacks & Git Status

\`\`\`bash
# Verify your stacks are in place
ls -la /volume2/docker/ce-stacks/stacks/

# Git status check
cd /volume2/docker/ce-stacks
git status  # ensure nothing uncommitted
\`\`\`
```

---

## [GREEN] LOW PRIORITY FIXES (Polish)

### Fix #9: Add Clarifying Comments to Volume Paths

Add comments where volumes contain commands (not actual mounts):

#### ollama/compose.yaml

```yaml
volumes:
  # EXEMPT: Command binary path (not a volume mount)
  - /usr/bin/ollama
  # ... actual volumes ...
```

#### watchtower/compose.yaml

```yaml
volumes:
  # EXEMPT: Command script (not a volume mount)
  - /watchtower
  # ... actual volumes ...
```

---

### Fix #10: Link Solution Architect Document

Update `README.md` to add:

```markdown
## Architecture & Design

- [Solution Architect](./solution-architect.md) - System design, conventions, and rationale
```

---

## Validation Checklist

After applying fixes, verify with these commands:

```bash
# 1. Network exists
docker network inspect ce-internal

# 2. All compose files validate
for compose in $(find ./stacks -name "compose.yaml"); do
  docker compose -f "$compose" config >/dev/null && echo "[OK] $(dirname $compose | xargs basename)" || echo "[FAIL] $(dirname $compose | xargs basename)"
done

# 3. Check security options
grep -l "no-new-privileges" ./stacks/*/compose.yaml | wc -l
# Should be >= 18 (all stacks)

# 4. Check PUID/PGID
grep -l "PUID=" ./stacks/*/compose.yaml | wc -l
# Should be >= 18 (all stacks)

# 5. No secrets in git
git ls-files | grep -E "\.env$|\.key$|\.pem$" | wc -l
# Should be 0
```

---

## Timeline to Fix Everything

- **Critical Fixes**: 20 minutes
- **High Priority Fixes**: 20 minutes
- **Medium Priority Fixes**: 15 minutes
- **Low Priority Fixes**: 10 minutes

#### Total

~1.5 hoursminutes

**Total**: ~1.5 hours

---

## After All Fixes

1. Run full validation
2. Commit all fixes to git:

   ```bash
   git add dockhand/ AUDIT_REPORT.md QUICK_FIX_CHECKLIST.md README.md stacks/*/compose.yaml stacks/*/security_opt
   git commit -m "fix: address audit findings (security, .env files, network setup)"
   git push origin main
   ```

3. Proceed with Dockhand deployment as documented in `dockhand/MIGRATION.md`
