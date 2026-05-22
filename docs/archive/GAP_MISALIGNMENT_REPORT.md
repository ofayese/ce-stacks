# Ce-Stacks: Gap & Misalignment Report

**Date**: 2026-05-22  
**Audited by**: Claude (Cowork agent)  
**Scope**: Full repo tree, docs/ folder, project links, stacks, DNS config, dockhand subdir

---

## Executive Summary

The repo is well-structured and most prior audit findings (from AUDIT_REPORT.md, FIX_SUMMARY.md, implementation_plan.md) have been resolved. However, **5 active gap categories** remain, spanning documentation staleness, DNS policy violations in committed config files, undocumented stacks and subnets, a project-links/docs mismatch, and a stale legacy zone file.

---

## GAP 1 — README Stacks Directory & Subnet Table Are Out of Date

**Severity**: MODERATE

### 1a. Stacks on disk NOT listed in README directory layout

| Stack | Status |
|---|---|
| `stacks/flowise/` | Present, has `compose.yaml`, subnet `172.30.1.0/24` — not in README |
| `stacks/db-tools/` | Present, has `compose.yaml`, no bridge network (host-bridged) — not in README |
| `stacks/n8n/` | Present, has `compose.yaml`, subnet `172.30.2.0/24` — not in README |
| `stacks/influxdb/` | Present, has `compose.yaml`, on `ce-internal` — not in README |
| `stacks/_dns-server/` | Present, has `RUNBOOK.md` + zone files, **no** `compose.yaml` — not in README |

The README directory tree still reflects the state before these stacks were added. The list shown to operators/agents is incomplete.

### 1b. Subnet registry table (README) is missing 8 entries

The README "Network Subnets" table lists 12 entries. Actual compose files define **19 subnets**. The following are unregistered:

| Subnet | Stack | Network name |
|---|---|---|
| `172.20.0.0/24` | `github-desktop` | `github-desktop-net` |
| `172.28.0.0/24` | `databases` (via `db-net`) | listed but `databases` stack has no compose.yaml on disk |
| `172.30.1.0/24` | `flowise` | `flowise-net` |
| `172.30.2.0/24` | `n8n` | `n8n-net` |
| `172.30.5.0/24` | `homepage` | `homepage-net` |
| `172.31.2.0/24`–`172.31.6.0/24` | Various stacks | Multiple unnamed |

**Risk**: subnet collision is possible for new stacks; operators pick "next available" without knowing the full registry.

### 1c. `databases` stack listed in README but has NO `compose.yaml`

`stacks/databases/` directory does not exist on disk. README and AUDIT_REPORT both reference it. The `db-net (172.28.0.0/24)` subnet belongs to something that isn't there. `db-tools` (Adminer) is the apparent replacement.

---

## GAP 2 — CRITICAL DNS Policy Violations in `_dns-server/named.conf.additions`

**Severity**: HIGH — direct conflict with `CLAUDE.md` safety constraints

### 2a. `.local` TLD Zone — BANNED

```
zone "otsorundscore.local" IN {
    type master;
    file "/var/packages/DNSServer/target/named/otsorundscore.local.zone";
    ...
```

**CLAUDE.md rule**: *"You MUST NOT use the `.local` top-level domain for forward zones. It is strictly reserved for Multicast DNS (mDNS/Bonjour) by RFC 6762 and breaks Synology Avahi/Apple device discovery. Use `.lan` instead."*

The zone files in `_dns-server/zones/` correctly use `lan.zone`. But `named.conf.additions` — the file an operator would actually paste into BIND — still declares `otsorundscore.local` as a master zone. This file needs to be corrected to reference `otsorundscore.lan` (matching the committed `lan.zone`).

### 2b. ACL uses `/16` instead of `/12` for Docker subnets

```conf
acl "trusted" {
    172.16.0.0/16;      # VPN / WireGuard peers
    172.30.0.0/24;      # zabbix-net bridge
};
```

**CLAUDE.md rule**: *"Limit source IP services to `172.16.0.0/12`, NOT `/16`."*

The ACL uses `/16` (covers only `172.16.x.x`) instead of `/12` (covers `172.16.x.x` through `172.31.x.x`). This means Docker containers on subnets `172.17–172.31.x.x` (grafana-net, prometheus-net, flowise-net, n8n-net, zabbix-net, homepage-net, agents-gateway-net, etc.) **cannot query the internal DNS server**. Services like Homepage, Grafana, Flowise, and n8n would fall back to public DNS instead of getting split-horizon resolution.

### 2c. Only `172.30.0.0/24` (zabbix-net) is explicitly allowed — all other Docker bridge subnets are blocked

The ACL specifies `172.30.0.0/24` as a one-off entry. This is redundant if `/12` is used (it would already be covered), and insufficient if `/16` is used (everything else is still blocked). Correct fix: replace both entries with `172.16.0.0/12`.

---

## GAP 3 — Legacy / Stale Zone File in `docs/otsorundscore_zonefile/`

**Severity**: MODERATE (confusion risk for operators)

`docs/otsorundscore_zonefile/zonefile/0.0.127.in-addr.arpa` is a legacy zone exported from an older DNS configuration. It contains:
- A `0.0.127.in-addr.arpa` reverse zone (127.x.x.x loopback range)
- PTR records pointing `1.0.0.127.in-addr.arpa` to `_msdcs.olutechsys.com.` (Active Directory artifact)
- Serial `5` (integer format, not date format)
- `allow-update-key="ots-sha512"` (TSIG key no longer referenced anywhere in the current config)

This file predates the current Synology DNS architecture. It conflicts with:
- The current `_dns-server/zones/` reference zone files (which are the current standard)
- The `_dns-server/RUNBOOK.md` and CLAUDE.md (neither references a loopback zone)
- The `zone.conf` in the same directory uses `serial_format="integer"` — the current architecture mandates **date format** (`2026052201`)

**Recommendation**: Archive to `docs/archive/` or delete; it adds confusion and cannot be applied without modification.

---

## GAP 4 — Project Links Added but Not Yet Wired to Stacks

**Severity**: LOW–MODERATE

The project has 6 reference links attached:

| Link | Relevance | Gap |
|---|---|---|
| `github.com/nicedreamzapp/claude-code-local` | Claude Code local setup | Not referenced in any stack or doc |
| `synocommunity.com/packages` | SynoCommunity packages | HAProxy, DNS Server from SynoCommunity — referenced in README but no install command or validation |
| `kb.synology.com/.../How_to_set_up_your_domain_with_Synology_DNS_Server` | Synology DNS setup | RUNBOOK.md exists but `_dns-server/RUNBOOK.md` doesn't link to this official KB |
| `docs.ollama.com/api` | Ollama REST API | `stacks/ollama/` exists; none of the compose env vars or docs cross-link the API reference |
| `docs.ollama.com/api/openai-compatibility` | Ollama OpenAI-compat endpoint | `agents_gateway_data` stack would benefit from this; not referenced |
| `developers.cloudflare.com/dns/zone-setups/full-setup/` | Cloudflare DNS | Correctly referenced in CLAUDE.md as "external boundary — direct users here" |

**Specific gaps**:
- `_dns-server/RUNBOOK.md` should link to the Synology KB article as the canonical UI walkthrough reference
- `stacks/ollama/` (or its README) should link to `docs.ollama.com/api` and the OpenAI-compat endpoint — especially given the `agents_gateway_data` stack which acts as an AI gateway
- The `nicedreamzapp/claude-code-local` link appears to be a dev-tool reference but is not wired to any setup doc or stack

---

## GAP 5 — Dockhand compose.yaml Still Uses `mem_limit` + `cpu_shares` (Compose v2 deprecated fields)

**Severity**: LOW

`dockhand/compose.yaml`:
```yaml
mem_limit: 1g
cpu_shares: 512
```

The `implementation_plan.md` calls for migrating all stacks to `deploy.resources.limits.memory` / `deploy.resources.reservations.memory` (Compose v2.20+ canonical form). A migration script `scripts/migrate-mem-limits-to-deploy.sh` was created for this purpose. The dockhand compose file was not migrated (it's outside `stacks/`), but is a legitimate compose file that should match the same standard.

Also: `dockhand/compose.yaml` declares `networks: ce-internal: external: true` — but dockhand is managed by the RC script (`docker run`), not `docker compose up`. The compose file is for "ad-hoc/dev use only" per its header comment. The RC script's `docker run` args may diverge from the compose file silently — there's no CI check enforcing parity.

---

## GAP 6 — `docs/implementation_plan_dockhand_drift.md` Pointer Is Broken

**Severity**: LOW

`docs/host-profile-otsorundscore.md` references:
```
[`docs/implementation_plan_dockhand_drift.md`](./implementation_plan_dockhand_drift.md)
```

But the file at `docs/implementation_plan_dockhand_drift.md` does **not exist** on disk. It's the old path that was superseded when `implementation_plan.md` was reorganised. The live plan is now `implementation_plan.md` at the repo root, but the pointer in `host-profile-otsorundscore.md` is a dead link.

---

## GAP 7 — `_dns-server/` Has No `compose.yaml` and Is Not Deployable via Dockhand

**Severity**: INFORMATIONAL (by design — but should be documented)

`stacks/_dns-server/` contains only:
- `RUNBOOK.md` (manual UI steps)
- `named.conf.additions` (BIND config snippet)
- `zones/` (reference zone files)

There is no `compose.yaml` because the Synology DNS Server is a native DSM package (`@appstore/DNSServer`), not a Docker container. However:
1. This is inconsistent with the rest of `stacks/` — all other entries have a `compose.yaml`
2. The README directory layout lists it nowhere, so its purpose is invisible to agents/operators
3. The `named.conf.additions` approach (manually pasting into `/var/packages/DNSServer/target/etc/named.conf`) bypasses Synology's DNS GUI, which could be reset on DSM package upgrades

**Recommendation**: Add a README.md to `stacks/_dns-server/` explicitly stating it is a non-Docker DSM package stack, and add a warning that manual `named.conf` edits may be overwritten by DSM package updates.

---

## Priority Action List

| Priority | Action | File(s) |
|---|---|---|
| 🔴 HIGH | Fix `named.conf.additions`: remove `.local` zone, replace ACL with `172.16.0.0/12` | `stacks/_dns-server/named.conf.additions` |
| 🔴 HIGH | Add all missing subnets to README Network Subnets table | `README.md` |
| 🟠 MODERATE | Add `flowise`, `db-tools`, `n8n`, `influxdb`, `_dns-server` to README directory layout | `README.md` |
| 🟠 MODERATE | Clarify/remove or archive `docs/otsorundscore_zonefile/` (legacy AD zone) | `docs/otsorundscore_zonefile/` |
| 🟠 MODERATE | Fix dead link: `implementation_plan_dockhand_drift.md` in host-profile doc | `docs/host-profile-otsorundscore.md` |
| 🟡 LOW | Add README.md to `stacks/_dns-server/` explaining non-Docker nature + DSM package upgrade risk | `stacks/_dns-server/README.md` |
| 🟡 LOW | Link project references (Ollama API, Synology KB) into relevant stack docs | `stacks/ollama/`, `stacks/_dns-server/RUNBOOK.md` |
| 🟡 LOW | Migrate `dockhand/compose.yaml` mem_limit → deploy.resources or add explicit exclusion comment | `dockhand/compose.yaml` |
| 🟡 LOW | Clarify `databases/` (listed in README but no compose.yaml on disk — replaced by `db-tools`?) | `README.md`, `stacks/` |
