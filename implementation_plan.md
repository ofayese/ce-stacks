# Implementation Plan

[Overview]
Close every concrete gap that prevents the `ce-stacks` repository from running cleanly on the live NAS `otsorundscore` (Synology DS723+, AMD Ryzen R1600 2-core / 32 GB RAM / no GPU, DSM 7.3.2-86009 Update 3, Cool mode).

The repo is functionally correct in the abstract -- networks, env files, security_opt, PUID/PGID, healthchecks, and the dockhand-drift reconciliation tracked in [`docs/implementation_plan_dockhand_drift.md`](./docs/implementation_plan_dockhand_drift.md) are all closed. What is still broken on this *specific* host falls into five buckets: (1) resource over-commitment (the sum of declared `mem_limit` values is ~ 43 GB on a 32 GB box, with no hard CPU caps on a 2-core CPU); (2) a non-RFC1918 subnet (`172.32.0.0/24` on `otspsu`) that will mis-route through any future NAT or VPN; (3) DSM 7.3 / Container Manager runtime quirks the repo currently glosses over (legacy `mem_limit`/`cpu_shares` in Compose v2, `build:` on `synology-api-bridge:local`, `seccomp:unconfined` on `github-desktop`, BTRFS storage driver implications); (4) Ollama-on-CPU realities for a 2-core, no-GPU host with a floating `:latest` tag and 14 GB reservation; and (5) Watchtower / extra_hosts inconsistencies that surface only at runtime on `otsorundscore.olutechsys.com`. This plan fixes all five buckets in one coherent pass with the smallest possible change surface and zero impact on any stack that is already healthy.

The plan is additive where possible: where a fix involves changing existing values (e.g. lowering `mem_limit`, swapping a subnet), the new value is calibrated against the realistic free-memory budget on `otsorundscore` (DSM uses ~ 3 GB, BTRFS cache ~ 2 GB, kernel/Container Manager overhead ~ 1 GB -> ~ 26 GB usable for stacks). Watchtower exemptions are preserved on stateful services. Floating tags are pinned only where the upstream image is known-stable (Ollama is the one explicit exception, gated by a Watchtower exemption).

[Types]
This is a Compose/Bash/Markdown codebase; the only "types" are the canonical contracts every stack must honor on this NAS.

- **Memory budget contract.** Sum(`mem_limit`) across all simultaneously-running stacks must be <= 26 GB. Stacks that exceed this when stacked are mutually exclusive and must be documented as such in `README.md`.
- **CPU contract.** On a 2-core / 4-thread CPU, every long-running service must declare `cpus:` (hard cap) in addition to `cpu_shares` (relative weight). Recommended ceiling per service: `cpus: "1.5"` for the heaviest workload (Ollama / code-server / mysql / otspsu), `cpus: "0.5"` for sidecars, `cpus: "0.25"` for log viewers/utility services.
- **Subnet contract.** Every bridge subnet must lie inside RFC1918 (`10/8`, `172.16/12`, `192.168/16`). `172.32.0.0/24` is **outside** `172.16.0.0/12` and is reallocated to `172.31.10.0/24`.
- **Image-tag contract.** Stateful services (DBs, Ollama model store, PSU LiteDB) are pinned by digest **and** carry `com.centurylinklabs.watchtower.enable=false`. Stateless services may pin by semver tag and may opt into Watchtower. The single exception (`ollama/ollama:latest`) gets the Watchtower-exempt label.
- **Compose-field contract.** New service definitions use `deploy.resources.limits.{cpus,memory}` and `deploy.resources.reservations.memory` (Compose v2.20+ honors these outside Swarm). Existing `mem_limit` / `cpu_shares` lines are migrated only where the file is already being edited; a one-shot migration script handles the rest.
- **Hostname/extra_hosts contract.** Every web-facing stack that fronts on `otsorundscore.olutechsys.com` declares the same `extra_hosts: ["otsorundscore.olutechsys.com:10.0.1.15"]` block. The repo currently has it on 4 of ~ 8 candidate stacks -- this plan unifies.

[Files]
Edits are grouped by gap; new files are listed separately.

Files to modify (existing):

- `stacks/ollama/compose.yaml` -- pin `ollama/ollama:latest` -> `ollama/ollama:0.4.7` (or current stable digest at time of apply); lower `otsai-server.mem_limit` from `14g` to `10g` and `mem_reservation` from `8g` to `6g`; add `cpus: "1.5"`; add `OLLAMA_MAX_LOADED_MODELS=1` and `OLLAMA_NUM_PARALLEL=1` to the env block (CPU-only on 2 cores); add `com.centurylinklabs.watchtower.enable=false` label (Ollama models corrupt on mid-pull restart); on the `open-webui` service add `cpus: "0.75"` and lower `mem_limit` to `1g`.
- `stacks/dozzle/compose.yaml` -- lower `mem_limit` from `3g` to `256m`; add `cpus: "0.5"`. Dozzle tails Docker socket streams; 3 GB is a copy-paste artifact.
- `stacks/code-server/compose.yaml` -- keep `code-server.mem_limit: 4g` but add `cpus: "1.5"`; `db.mem_limit` (mysql:8.3) stays `2g` but add `cpus: "0.75"`; `phpmyadmin.mem_limit` stays `512m` but add `cpus: "0.25"`; add an `extra_hosts` block for `otsorundscore.olutechsys.com:10.0.1.15` on the `code-server` service.
- `stacks/databases/compose.yaml` -- add `cpus: "1.0"` (mariadb), `cpus: "0.75"` (postgres), `cpus: "0.25"` (adminer). Re-confirm digest pins on mariadb/postgres (already pinned by tag, no digest -- add `image: mariadb:11.4.10@sha256:...` and same for postgres; resolved at apply time).
- `stacks/grafana-prom/compose.yaml` -- add `cpus:` caps: grafana `0.5`, prometheus `1.0`, node-exporter / snmp-exporter / cadvisor `0.25` each, alertmanager `0.25`.
- `stacks/github-desktop/compose.yaml` -- keep `seccomp:unconfined` but add an inline comment linking to KasmVNC SECCOMP requirement so a future audit pass does not strip it; add `cpus: "1.0"`. Verify on DSM 7.3.2 U3 that AppArmor does not block `unconfined` (runtime check, documented in `docs/dsm-732-runtime-quirks.md`).
- `stacks/otspsu/compose.yaml` -- change subnet from `172.32.0.0/24` (non-RFC1918) -> `172.31.10.0/24` (gateway `172.31.10.1`); add `cpus: "1.5"`; verify the `${ACME_CERT_ROOT:-/volume2/certs/acme}` mount target exists on the host (referenced docs entry).
- `stacks/zabbix/compose.yaml` -- add `cpus: "0.75"` (zabbix-server-pgsql), `cpus: "0.5"` (postgres), `cpus: "0.5"` (web-nginx); already pinned, no image changes.
- `stacks/agents_gateway_data/compose.yaml` -- change docker.sock mount from `rw` to `ro` and document an optional `tecnativa/docker-socket-proxy` side-car alternative in the README; add `cpus: "0.5"`.
- `stacks/synology-api-bridge/compose.yaml` -- keep `build: .` but add an explicit warning comment that first-time deploy requires `docker compose -f stacks/synology-api-bridge/compose.yaml build` from SSH (DSM Container Manager UI does not always pick up local builds); pin Python base by digest (already done in `Dockerfile`); add `cpus: "0.25"`.
- `stacks/watchtower/compose.yaml` -- lower poll interval if currently set to default (3600 s) -> `21600` (6 h); add `WATCHTOWER_LABEL_ENABLE=true` so only labelled services are touched (defense-in-depth on top of the per-service `enable=false` labels); add `cpus: "0.25"`.
- `stacks/searxng/compose.yaml`, `stacks/homepage/compose.yaml`, `stacks/openresume/compose.yaml`, `stacks/codex-docs/compose.yaml`, `stacks/it-tools/compose.yaml`, `stacks/remotely/compose.yaml`, `stacks/acme-sh/compose.yaml`, `stacks/mcp-tools-config/compose.yaml` -- add `cpus:` caps per the [Types] ceiling (sidecars `0.5`, utilities `0.25`).
- `stacks/_haproxy/haproxy.cfg` -- no logic change; add a header comment noting it is invoked by the bare-metal HAProxy from `@appstore` and that `/volume2/certs/acme/` must be readable by the HAProxy uid; cross-reference `stacks/acme-sh` for cert renewal.
- `README.md` -- add a new "Host Profile: otsorundscore" section near the top documenting: CPU/RAM ceiling (32 GB / 2 core / no GPU), the 26 GB usable budget, the "stacks mutually exclusive under load" table (Ollama-heavy vs full monitoring vs full IDE stack), and a pointer to `docs/dsm-732-runtime-quirks.md`. Update the "Network Subnets" table to replace `172.32.0.0/24` with `172.31.10.0/24` for `otspsu`.
- `AUDIT_REPORT.md` -- append a "2026-05-15 host-profile reconciliation" section listing the new gaps (Issue #12 mem overcommit, #13 non-RFC1918 subnet, #14 Ollama floating tag, #15 docker.sock rw on gateway, #16 missing cpus caps, #17 dozzle mem outlier).
- `scripts/verify-repo-layout.sh` -- add two new assertions: (a) every `subnet:` line in `stacks/*/compose.yaml` falls inside an RFC1918 range; (b) Sum(`mem_limit`) across all stacks <= a configurable ceiling (default 26g).
- `scripts/compose-validate.sh` -- invoke the new `scripts/lint-host-budget.sh` after the existing per-stack `docker compose config` pass.

Files to create (new):

- `docs/dsm-732-runtime-quirks.md` -- concrete runbook for DSM 7.3.2-86009 U3 on a DS723+: Container Manager vs CLI deploy paths, BTRFS `@docker` storage driver quirks (`docker system prune -af --volumes` cadence), `seccomp:unconfined` verification, Cool-mode thermal throttling behavior under sustained CPU (Ollama), `rc.d` non-execution at boot (covered by the existing DSM Task Scheduler note), and the `volume1` (`@appstore` HAProxy) <-> `volume2` (Docker) cross-volume cert-path coordination.
- `docs/host-profile-otsorundscore.md` -- single source of truth for the host: hostname `otsorundscore`, FQDN `otsorundscore.olutechsys.com`, LAN IP `10.0.1.15`, NTP `time.google.com`, TZ `America/New_York`, CPU `Ryzen R1600` (Zen / AVX2 / no GPU), RAM 32 GB, DSM `7.3.2-86009 Update 3`, serial `2490TPRRB8926`, model `DS723+`. Pulled directly from the user-supplied facts. Linked from `README.md`.
- `scripts/lint-host-budget.sh` -- Bash script. For every `stacks/*/compose.yaml`, parses `mem_limit` (yq if available, else awk fallback), normalizes to MB, sums per stack and across all stacks, compares against `${HOST_MEM_BUDGET_MB:-26624}` (26 GB). Exits non-zero with a per-stack breakdown if total exceeds budget. Used by `scripts/compose-validate.sh` and runnable standalone (`bash scripts/lint-host-budget.sh`).
- `scripts/lint-rfc1918.sh` -- Bash script. Greps every `stacks/*/compose.yaml` for `subnet:` lines, parses each, fails if any subnet is outside `10.0.0.0/8`, `172.16.0.0/12`, or `192.168.0.0/16`. Called from `scripts/verify-repo-layout.sh`.
- `scripts/migrate-mem-limits-to-deploy.sh` -- one-shot, idempotent migration helper. Converts `mem_limit: X` + `cpu_shares: Y` blocks to the Compose-v2 canonical `deploy.resources.limits.memory` / `deploy.resources.reservations.memory` form, preserving comments. Default mode is `--dry-run`; `--apply` mutates files. Not run by CI -- manual cut-over only.
- `stacks/_haproxy/README.MD` (overwrite minor) -- currently `README.MD` (capitalized). Confirm casing on case-sensitive filesystems (Linux NAS is case-sensitive; macOS dev is usually case-insensitive). Rename to `README.md` for consistency with the rest of the repo. Adds a paragraph noting `volume1` vs `volume2` cross-volume operations.

Files to delete or move:

- `implementation_plan.md` (root) -- the previous dockhand-drift plan has been copied to `docs/implementation_plan_dockhand_drift.md` and this file now hosts the new host-profile plan. No deletion required.

[Functions]
The plan introduces three small shell functions; no application code.

New functions:

- `parse_mem_to_mb(value: string) -> int` in `scripts/lint-host-budget.sh` -- pure-Bash converter that accepts `128m`, `512m`, `1g`, `14g`, `2G`, etc. and emits an integer megabyte count. Backed by an `awk` one-liner; no `yq` dependency. Unit-tested inline at script bottom via a `_self_test` block guarded by `[[ "${1:-}" == "--self-test" ]]`.
- `assert_rfc1918(cidr: string) -> 0|1` in `scripts/lint-rfc1918.sh` -- strips the prefix length, splits the first two octets, and tests membership in {`10.*`, `172.16-31.*`, `192.168.*`}. Returns 0 if inside RFC1918, 1 otherwise. Called once per `subnet:` line.
- `migrate_block(file: path, service: string) -> 0|1` in `scripts/migrate-mem-limits-to-deploy.sh` -- locates the `mem_limit`/`cpu_shares` lines under a given service and rewrites them to the `deploy.resources` block. Uses `awk` for in-place rewrite; preserves the rest of the file byte-for-byte. Idempotent: skips a service that already has a `deploy:` block.

Modified functions:

- None (no application source touched).

Removed functions:

- None.

[Classes]
N/A -- no classes in this codebase.

[Dependencies]
No new runtime dependencies are introduced; the plan reduces operational risk by tightening tag pinning, not by adding packages.

- `bash 4+` (already required by every other script).
- `awk` (BSD or GNU; both supported by the same `awk` invocations already used in `scripts/init-nas.sh`).
- Optional: `yq` (v4+) -- only consulted by `scripts/lint-host-budget.sh` if present; the awk fallback covers DSM hosts that lack it.
- Optional: `crane` or `skopeo` -- used by the operator (not by CI) to resolve `mariadb:11.4.10` -> digest before pinning. Not a hard prereq.
- No new container images, no version bumps to existing images outside the pin/unpin changes listed in [Files], no compose-plugin version requirement above what DSM 7.3.2 already ships (`docker compose v2.27+`).

[Testing]
All validation is local shell + a small set of `docker compose config -q` runs; no test framework is introduced.

- `bash scripts/compose-validate.sh` -- must continue to pass for every `stacks/*/compose.yaml` after each edit.
- `bash scripts/verify-repo-layout.sh` -- must pass with the two new assertions (`lint-rfc1918.sh` and `lint-host-budget.sh`). The mem-budget assertion is configurable via `HOST_MEM_BUDGET_MB` so dev machines with > 26 GB do not false-flag.
- `bash scripts/lint-rfc1918.sh` -- standalone run; expected output: `OK: 19 subnets inside RFC1918`.
- `bash scripts/lint-host-budget.sh` -- standalone run; expected output: `OK: total mem_limit 26.x GB <= 26.0 GB budget` (after the dozzle / ollama / open-webui cuts).
- `bash scripts/migrate-mem-limits-to-deploy.sh --self-test --dry-run` -- must report parity for a known-good fixture (a copy of `stacks/acme-sh/compose.yaml`); apply mode is not exercised by CI.
- Manual on-NAS verification (documented in `docs/dsm-732-runtime-quirks.md`, not automated):
  1. `docker network inspect ce-internal` returns 200; `docker network inspect otspsu-net` confirms the new `172.31.10.0/24` subnet.
  2. `docker stats --no-stream` while ollama serves a 7B Q4 model -- actual RSS must stay below the new `10g` cap.
  3. `synoinfo --get system_status` should not show thermal throttling under sustained ollama inference (Cool mode + 2 cores).
  4. `curl -fs http://10.0.1.15:3866/health` (Dockhand) returns 200 after a reboot, confirming the DSM Task Scheduler "Boot-up" task (from the prior plan) still works.
- Doc-link sweep (run from repo root): `grep -rn "172\.32\.0\.0" .` must return zero matches outside `docs/implementation_plan_dockhand_drift.md` (archived) and `.git/`.

[Implementation Order]
The sequence below minimizes the risk that an intermediate state breaks any currently-running stack on `otsorundscore`.

1. **Snapshot first.** On the NAS, `docker compose ls` and `docker network ls` are captured into `/volume2/docker/_snapshots/$(date +%F)-pre-host-profile.txt` so the operator can roll back without guessing.
2. **Static files only, zero behavior change.** Create `docs/dsm-732-runtime-quirks.md` and `docs/host-profile-otsorundscore.md`. Link both from `README.md` (new "Host Profile: otsorundscore" section). Rename `stacks/_haproxy/README.MD` -> `stacks/_haproxy/README.md` (case fix). No service restart required.
3. **Linters before mutations.** Create `scripts/lint-rfc1918.sh` and `scripts/lint-host-budget.sh`. Wire them into `scripts/verify-repo-layout.sh` and `scripts/compose-validate.sh`. Run both -- they should fail with the *current* values (otspsu non-RFC1918, total mem 43 GB > 26 GB). This is the baseline against which fixes are measured.
4. **Subnet fix (low risk, single stack).** Edit `stacks/otspsu/compose.yaml` subnet -> `172.31.10.0/24`. Update the README network table. Rerun `lint-rfc1918.sh` -> must pass. Operator restarts otspsu only: `docker compose -f stacks/otspsu/compose.yaml up -d --force-recreate`.
5. **Memory / CPU caps -- sidecars first (lowest blast radius).** Apply `cpus:` caps and trim `mem_limit` on the cheapest stacks: `dozzle`, `mcp-tools-config`, `it-tools`, `acme-sh`, `watchtower`, `homepage`, `searxng`, `openresume`, `codex-docs`, `remotely`. Re-run `lint-host-budget.sh` after each edit -- totals fall monotonically. No restarts required (Compose change propagates next deploy).
6. **Memory / CPU caps -- medium stacks.** `agents_gateway_data` (also flips docker.sock to `:ro`), `synology-api-bridge`, `github-desktop`, `grafana-prom`, `zabbix`, `databases`. Re-run linters.
7. **Memory / CPU caps -- heavy stacks.** `code-server` (three services), `otspsu`, `ollama`. The ollama edit also pins the image and adds the Watchtower-exempt label and `OLLAMA_MAX_LOADED_MODELS=1`. Re-run linters -- total must now be <= 26 GB.
8. **Optional Compose-v2 migration.** Run `scripts/migrate-mem-limits-to-deploy.sh --dry-run`; review diff; run `--apply` only if the operator wants to retire the legacy `mem_limit`/`cpu_shares` fields. **Not** part of the critical path -- the legacy fields keep working on DSM 7.3.2.
9. **Final validation pass:**
   - `bash scripts/compose-validate.sh`
   - `bash scripts/verify-repo-layout.sh`
   - `bash scripts/lint-rfc1918.sh`
   - `bash scripts/lint-host-budget.sh`
   - `grep -rn "172\.32\.0\.0" . | grep -v docs/implementation_plan_dockhand_drift.md | grep -v .git` returns empty.
10. **Commit as one logical change:** `feat(host-profile): right-size mem/cpu for otsorundscore (DS723+ 32GB/2c), reallocate otspsu subnet to RFC1918, pin ollama, add DSM 7.3.2 quirks runbook`.
11. **Deploy on NAS in waves.** Apply the new compose values one stack at a time using `docker compose -f stacks/<stack>/compose.yaml up -d`. Verify `docker stats` matches the new caps. Ollama is applied last (largest behavioral change). Snapshot from Step 1 enables targeted rollback per stack.
