# Host Profile -- `otsorundscore`

Single source of truth for the live NAS this repository targets. Any number that contradicts this file is wrong.

## Identity

| Field | Value |
|---|---|
| Hostname | `otsorundscore` |
| FQDN | `otsorundscore.olutechsys.com` (also: `otsorundscore.olutech.systems`) |
| LAN IP | `10.0.1.15` |
| Owner / admin email | `ofayese@olutechsys.com` |
| Serial number | `2490TPRRB8926` |

## Hardware

| Field | Value | Notes |
|---|---|---|
| Model | Synology DS723+ | 2-bay Plus |
| CPU | AMD Ryzen R1600 @ 2.6 GHz | Zen-based, 2 cores / 4 threads, **no AVX-512**, has AVX2 |
| RAM | 32 GB | Maximum the DS723+ accepts |
| GPU | **None** | Ollama / inference must run CPU-only |
| Drive bays | 2 (BTRFS expected) | Docker root is on `/volume2/@docker` |
| Cooling profile | **Cool mode** | DSM throttles fan and CPU clock -- sustained heavy CPU loads (e.g. Ollama inference) will thermal-throttle |

## Software

| Field | Value |
|---|---|
| DSM build | `7.3.2-86009 Update 3` |
| Container Manager | Bundled Compose v2 plugin (`docker compose v2.27+`) |
| HAProxy | bare-metal (`@appstore/haproxy`) on `volume1` |
| Time source | `time.google.com` (NTP) |
| Timezone | `(GMT-05:00) Eastern Time (US & Canada)` -- `America/New_York` |
| Repo location | `/volume2/docker/ce-stacks` |
| Dockhand runtime | `/volume2/docker/dockhand` (outside repo) |

## Derived constraints

These are the **calculated** budgets the plan and the `scripts/lint-host-budget.sh` linter enforce:

| Budget | Value | Rationale |
|---|---|---|
| Total RAM | 32 GB | Physical |
| DSM kernel + Container Manager + BTRFS metadata cache | ~ 6 GB | Measured baseline on idle DS723+ |
| **Usable for stacks** (`HOST_MEM_BUDGET_MB`) | **26 GB (26 624 MB)** | Hard ceiling for Sum `mem_limit` across simultaneously-running stacks |
| Hard CPU cap per heavy service | `cpus: "1.5"` | 75 % of one core x 2 cores ~ never starve DSM |
| Hard CPU cap per sidecar | `cpus: "0.5"` | |
| Hard CPU cap per utility / log viewer | `cpus: "0.25"` | |

## Runtime profile

| Property | Value |
|---|---|
| Last observed uptime | `3 day(s) 19 hour(s) 54 minute(s) 15 second(s)` (as of `2026-05-15 19:45 ET`) |
| System status | `Normal` |
| Active fan profile | Cool mode |

## See also

- [`dsm-732-runtime-quirks.md`](./dsm-732-runtime-quirks.md) -- Container Manager / BTRFS / Cool-mode operational quirks
- [`implementation_plan_dockhand_drift.md`](./implementation_plan_dockhand_drift.md) -- prior, completed plan
- [`../implementation_plan.md`](../implementation_plan.md) -- current active plan (this file is referenced from there)
- [`../README.md`](../README.md) -- repo overview
