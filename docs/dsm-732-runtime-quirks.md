# DSM 7.3.2-86009 U3 Runtime Quirks on DS723+

Concrete, hands-on notes for running this repo on `otsorundscore`. Every item here was either observed in production or is a documented Synology / Docker behavior that materially changes how you deploy.

Pair this with [`host-profile-otsorundscore.md`](./host-profile-otsorundscore.md).

---

## 1. Container Manager vs. CLI deploy paths

DSM 7.3 ships `docker compose v2` as a plugin used both by **Container Manager** (the DSM web UI) and the **CLI** (`/usr/local/bin/docker compose …`).

| Operation | Works in Container Manager UI? | Works on CLI / Dockhand? |
|---|---|---|
| `docker compose up -d` of a published-image stack | ✅ | ✅ |
| Stacks with `build: .` (local Dockerfile) | ⚠️ **Unreliable** — UI sometimes silently uses the previously-tagged local image and skips rebuild. | ✅ |
| Stacks with `extends:` | ⚠️ Container Manager does not always expand `extends` correctly. | ✅ |
| Stacks referencing `external: true` networks not yet created | ❌ Fails with "network not found". | ✅ (after `init-nas.sh` runs) |
| Secrets via `secrets:` `file:` | ✅ | ✅ |

**Rule of thumb:** any compose file in this repo that contains `build: .` (today: `stacks/synology-api-bridge`) must be **first-deployed from SSH**:

```bash
cd /volume2/docker/ce-stacks/stacks/synology-api-bridge
sudo /usr/local/bin/docker compose build
sudo /usr/local/bin/docker compose up -d
```

After the local image tag exists in the engine, Container Manager / Dockhand can manage it normally.

---

## 2. `/usr/local/etc/rc.d/*.sh` does **not** execute at boot

DSM 7.x silently dropped automatic execution of `rc.d` scripts. Dockhand will *not* come up after a reboot unless you wire a DSM Task Scheduler boot-up task. See [`../dockhand/docs/DSM_BOOT_PERSISTENCE.md`](../dockhand/docs/DSM_BOOT_PERSISTENCE.md) — already covered by the prior dockhand-drift plan.

Validation after every reboot:

```bash
curl -fs http://10.0.1.15:3866/health   # 200 if Dockhand auto-started
```

---

## 3. BTRFS `@docker` storage driver — prune cadence

`/volume2/@docker` is BTRFS. The `btrfs` Docker storage driver fragments aggressively when many small image layers are pulled (Watchtower churn). Synology's `btrfs` snapshots compound this.

**Operational cadence on a Cool-mode 32 GB host:**

```bash
# Weekly (low traffic hours):
sudo /usr/local/bin/docker system prune -af --volumes

# Monthly: also defragment Docker subvolume (read-write, safe):
sudo btrfs filesystem defragment -r -czstd /volume2/@docker
```

Symptoms that you waited too long: `docker pull` slows to <1 MB/s for layers it should already have, `docker volume ls` takes >5 s, DSM Storage Manager reports "Volume health: Warning".

---

## 4. `seccomp:unconfined` and AppArmor

`stacks/github-desktop` (KasmVNC) **requires** `security_opt: seccomp:unconfined`. DSM 7.3.2 ships an AppArmor profile (`docker-default`) that does not always honor `seccomp:unconfined` on first start.

Validation after deploy:

```bash
sudo docker inspect github-desktop --format '{{json .HostConfig.SecurityOpt}}'
# Expected: ["seccomp=unconfined","no-new-privileges:true"]

# If KasmVNC fails with "Operation not permitted" mounting tmpfs:
sudo aa-status | grep docker-default     # Confirms profile is loaded
sudo cat /sys/kernel/security/apparmor/profiles | grep docker
```

If KasmVNC fails to start with permission errors, temporarily disable AppArmor enforcement for that container (`sudo aa-complain /etc/apparmor.d/docker`) and re-test. **Never** remove the `seccomp:unconfined` line — KasmVNC will refuse to run.

---

## 5. Cool mode + 2-core CPU = thermal throttling under sustained load

Ryzen R1600 (Zen) at 2.6 GHz × 2 cores × Cool fan profile = roughly 30 W TDP envelope DSM will allow before clock-stepping the CPU down.

**Workloads that **will** throttle:**

- Ollama serving a 7B-Q4 model for > 5 minutes continuous tokens (sustained ~80 % CPU on both cores)
- `prom/cadvisor` + heavy `node-exporter` collectors during a scrape storm
- `code-server` running `npm install` of a large monorepo while MySQL ingests a dump

**Mitigations already in this plan:**

- Hard `cpus: "1.5"` cap on Ollama prevents both cores from sustaining 100 %.
- `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_FLASH_ATTENTION=1`.
- `cpus: "0.25"` on every exporter sidecar.

**Diagnose throttling:**

```bash
# CPU clock under load (should stay ≥ 2.0 GHz; below = throttling):
watch -n2 'cat /proc/cpuinfo | grep "cpu MHz"'

# DSM thermal log:
sudo cat /var/log/messages | grep -iE 'thermal|throttle|temperature'

# Synology system status:
sudo synosystemstatus get  # or DSM → Info Center → System Health
```

If sustained throttling is observed, switch DSM fan profile from "Cool" to "Full-speed" temporarily during the heavy workload, or reduce concurrent stacks per the budget tables in [`host-profile-otsorundscore.md`](./host-profile-otsorundscore.md).

---

## 6. `volume1` ↔ `volume2` cross-volume coordination

This NAS keeps:

- `/volume1/homes/laolufayese` — user home (DSM-managed)
- `/volume1/@appstore/haproxy/` — bare-metal HAProxy (Synology AppStore install)
- `/volume2/docker/ce-stacks` — this repo
- `/volume2/docker/dockhand` — Dockhand runtime
- `/volume2/certs/acme` — ACME cert output (consumed by HAProxy on volume1, **and** by `psu-ots` on volume2)

**Implication:** the HAProxy uid must be able to *read* `/volume2/certs/acme/*.pem`. Synology App Center installs HAProxy as user `haproxy:haproxy` (uid varies). Validate after each cert renewal:

```bash
sudo -u haproxy cat /volume2/certs/acme/otsorundscore.olutechsys.com.fullchain.pem >/dev/null
# Exit 0 = HAProxy can read; non-zero = chown / chmod fix needed
```

`stacks/acme-sh` writes certs to `${ACME_CERT_ROOT:-/volume2/certs/acme}`; never change the default unless you also update the HAProxy AppStore config and any consumer stacks (today: `psu-ots`).

---

## 7. Compose v2 `deploy.resources` vs. legacy `mem_limit` / `cpu_shares`

`docker compose v2.20+` (shipped with DSM 7.3.2) honors **both** the legacy top-level `mem_limit` / `cpu_shares` fields and the canonical `deploy.resources.limits.{cpus,memory}` block — but only outside Swarm mode. DSM Container Manager and Dockhand both run in non-Swarm mode, so both forms work.

This repo currently uses the legacy form. To migrate to the canonical form one stack at a time without behavior change, use the dry-run-by-default helper:

```bash
bash scripts/migrate-mem-limits-to-deploy.sh --dry-run
bash scripts/migrate-mem-limits-to-deploy.sh --apply    # only after reviewing diff
```

The legacy form keeps working; the migration is **not** part of the critical path.

---

## 8. Bridge subnet hygiene (RFC1918 only)

Any `subnet:` declared in a compose `networks:` block must live inside RFC1918 (`10/8`, `172.16/12`, `192.168/16`). DSM's NAT and any future VPN / WireGuard / Tailscale routing will mis-route traffic destined for non-RFC1918 ranges that happen to overlap with public space.

The repo currently uses `172.20–172.31` (RFC1918 ✓) for stack networks and `172.26.0.0/24` for `ce-internal`. `172.32.0.0/24` was previously assigned to `psu-ots` — that is **outside** `172.16.0.0/12` (which ends at `172.31.255.255`). It has been reallocated to `172.31.10.0/24` by this plan.

Run the linter after any subnet change:

```bash
bash scripts/lint-rfc1918.sh
```

---

## 9. Synology DSM time + NTP

NTP source: `time.google.com`. TZ: `America/New_York`. All compose files use `TZ=America/New_York` (or `${TZ:-America/New_York}`); this is already consistent. If DSM's TZ ever drifts (Control Panel → Regional Options), every container's timestamp in `/var/log` will shift by the offset until you restart the container.

Validate:

```bash
date
synodate --get_tz
docker exec -it Grafana date    # should match host within ± 2 s
```

---

## 10. Watchtower interaction matrix

| Service class | `watchtower.enable` label | Why |
|---|---|---|
| Databases (mariadb, postgres, mysql, mongodb) | `false` | Mid-write image swap corrupts data files |
| Stateful platforms (Ollama, PSU, Remotely) | `false` | LiteDB / model files / WAL corruption risk |
| Stateless web apps (homepage, it-tools, openresume, …) | `true` | Safe to auto-update |
| Image with floating `:latest` tag | `false` | Tag content shifts under your feet; pin first |

`stacks/watchtower/compose.yaml` runs with `WATCHTOWER_LABEL_ENABLE=1` so **only** containers carrying `enable=true` are touched. Any container without an explicit label is exempt by default.

---

## See also

- [`host-profile-otsorundscore.md`](./host-profile-otsorundscore.md)
- [`../README.md`](../README.md) — repo overview + network subnet table
- [`../implementation_plan.md`](../implementation_plan.md) — current plan
- [`../dockhand/docs/DSM_BOOT_PERSISTENCE.md`](../dockhand/docs/DSM_BOOT_PERSISTENCE.md)
