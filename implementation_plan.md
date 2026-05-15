# Implementation Plan

[Overview]
Reconcile every inconsistency between the ce-stacks repository (cloned to `/volume2/docker/ce-stacks`) and the runtime Dockhand install (copied to `/volume2/docker/dockhand`) so the documented deploy flow works end-to-end without manual corrections.

The repo currently advertises a `git clone … && cp dockhand /volume2/docker/dockhand` workflow, but several docs and scripts predate the relocation of Dockhand from `stacks/dockhand/` to the repo root, and predate the `scripts/`+`docs/` reorganization inside `dockhand/`. Three classes of defects exist: (1) stale path references that 404 or copy-fail when followed verbatim; (2) configuration drift between `dockhand/compose.yaml`, `dockhand/scripts/dockhand-start.sh`, and `dockhand/.env.example` (Watchtower label value, `STACK_ROOT` semantics, data mount path); and (3) operational gaps (no DSM Task-Scheduler boot instructions, RC script doesn't self-heal `ce-internal`, Portainer rollback artifacts still referenced). This plan corrects all three classes in one coherent pass with no behavior change to already-running stacks. The plan also leaves `dockhand/scripts/dockhand-migration.sh` intact as a historical reference and explicitly relabels it so future readers do not assume Portainer is still part of the topology.

[Types]
No code types are introduced; the only "type-like" change is the codification of three canonical contracts that all docs and scripts must honor.

- `STACK_ROOT` ALWAYS points to the `stacks/` directory itself, i.e. `/volume2/docker/ce-stacks/stacks`. This matches `scripts/init-nas.sh`. `dockhand/.env.example` and `dockhand/compose.yaml` must conform.
- `DOCKHAND_DATA` ALWAYS points to `/volume2/docker/dockhand` (runtime root, outside the repo). It is the bind-mount source for `/app/data` inside the Dockhand container.
- Dockhand RC-script source-of-truth lives at `dockhand/scripts/dockhand-start.sh` in the repo → synced to `/volume2/docker/dockhand/scripts/dockhand-start.sh` on the NAS → installed at `/usr/local/etc/rc.d/dockhand.sh`. No other path is valid; every doc and script must use these three paths consistently.

Watchtower-on-Dockhand policy: `com.centurylinklabs.watchtower.enable=false`. Rationale: `fnsys/dockhand` only publishes the floating `latest` tag, and the compose.yaml comment already explicitly warns against auto-update. The RC script must be brought into alignment with the compose.yaml value (not the other way around).

[Files]
File changes are split into edits, new files, and one historical relabel.

Files to modify (existing):
- `README.md` — fix line 104 (`/volume2/docker/ce-stacks/dockhand/dockhand-start.sh` → `/volume2/docker/ce-stacks/dockhand/scripts/dockhand-start.sh`); fix the broken link near line 121 (`./stacks/dockhand/README.md` → `./dockhand/README.md`); remove the stale `portainer-start.sh` entry from the directory layout (around line 41–42) and replace with `dockhand/scripts/dockhand-start.sh`; add a new "DSM boot persistence" subsection under "Getting Started" linking to the new `dockhand/docs/DSM_BOOT_PERSISTENCE.md`; add a short "Architecture & Design" section linking `solution-architect.md`.
- `DOCKHAND_MIGRATION.md` — replace every `stacks/dockhand/` with `dockhand/`; fix the example `sudo cp …/dockhand-start.sh` path on line 29 to include `scripts/`; rewrite the rollback paragraph so it no longer assumes Portainer scripts exist (replace with "Dockhand is just the UI — stopping it does not stop your stacks").
- `dockhand/README.md` — fix the manual `docker compose up -d` cwd on line 34 (`/volume2/docker/ce-stacks/stacks/dockhand` → `/volume2/docker/ce-stacks/dockhand`); fix every entry in the "Related Documentation" block to point at `dockhand/docs/MIGRATION.md`, `dockhand/scripts/dockhand-validate.sh`, `dockhand/scripts/dockhand-migration.sh`, and `dockhand/scripts/dockhand-start.sh`; rewrite the "Rollback to Portainer" section as "Rollback / disable Dockhand without affecting running stacks".
- `dockhand/compose.yaml` — change `${STACK_ROOT}/dockhand/data:/app/data:rw` to `${DOCKHAND_DATA:-/volume2/docker/dockhand}:/app/data:rw`; change the hardcoded `/volume2/docker/ce-stacks/stacks:/app/stacks:rw` to `${STACK_ROOT:-/volume2/docker/ce-stacks/stacks}:/app/stacks:rw`; keep the Watchtower label as `enable=false` (already correct); add an inline comment that this compose file is for ad-hoc/dev use and the RC script is canonical for production lifecycle.
- `dockhand/.env.example` — change the commented `STACK_ROOT` example value from `/volume2/docker/ce-stacks` to `/volume2/docker/ce-stacks/stacks`; add a commented `DOCKHAND_DATA=/volume2/docker/dockhand` example for symmetry; add a sentence clarifying that this file is consumed only by `docker compose` runs (not by the RC script, which has its own defaults).
- `dockhand/STRUCTURE.md` — remove the phantom root-level `DEPLOYMENT.md` line (around line 11, "DEPLOYMENT.md ← Deployment instructions (root)"); the file only exists under `docs/`. Verify the rest of the file matches reality after other edits.
- `dockhand/scripts/dockhand-start.sh` — change `--label com.centurylinklabs.watchtower.enable=true` to `--label com.centurylinklabs.watchtower.enable=false` to match the policy decision; add a new `ensure_ce_internal()` helper that idempotently creates the `ce-internal` bridge (`172.26.0.0/24`, gateway `172.26.0.1`) if absent; invoke `ensure_ce_internal` before `create_container` in the main logic block.
- `dockhand/scripts/health-check-fix.sh` — fix the printed instruction on line 74 (`/volume2/docker/dockhand/dockhand-start.sh` → `/volume2/docker/dockhand/scripts/dockhand-start.sh`).
- `dockhand/scripts/dockhand-migration.sh` — prepend a header banner clearly labeling it "Historical: Portainer → Dockhand migration helper. Retained for reference. Not part of the current deploy flow." No logic changes.
- `dockhand/docs/HEALTH_CHECK_SOLUTION.md` — fix line 94 (`/volume2/docker/dockhand/health-check-fix.sh` → `/volume2/docker/dockhand/scripts/health-check-fix.sh`); fix line ~122 (`dockhand/dockhand-start.sh` → `dockhand/scripts/dockhand-start.sh`).
- `dockhand/docs/HEALTH_CHECK_DEBUG.md` — fix the `RC Script` path reference around line 392 to include `scripts/`.
- `dockhand/docs/HEALTH_CHECK_FIX.md` — sweep for any remaining `/volume2/docker/dockhand/dockhand-start.sh` (no `scripts/`) references and correct them.
- `dockhand/docs/DEPLOYMENT.md` — add a clarifying note that the raw `cp -r ce-stacks/dockhand /volume2/docker/dockhand` is destructive on re-run; recommend `bash scripts/init-nas.sh` (or the new `scripts/dockhand-sync.sh`) as the canonical, idempotent sync path that preserves runtime `.env`, `data/`, and `secrets/`.
- `AUDIT_REPORT.md` — append a "Resolution status (2026-05-15)" section noting which audit items are closed by this plan (Issues #2, #3, #9 are now addressed by `init-nas.sh` + this reconciliation).
- `QUICK_FIX_CHECKLIST.md` — same: cross out items now obsoleted by `scripts/bootstrap-env.sh --apply` (already invoked by `init-nas.sh`) and by this plan.

Files to create (new):
- `implementation_plan.md` (repo root) — this plan, persisted for the implementation agent (this file itself).
- `dockhand/docs/DSM_BOOT_PERSISTENCE.md` — short note covering: DSM 7.3 does **not** auto-execute `/usr/local/etc/rc.d/*.sh` on boot; create a Task Scheduler "Triggered Task → Boot-up → root → `bash /usr/local/etc/rc.d/dockhand.sh`" task; include verification steps (`sudo /usr/local/etc/rc.d/dockhand.sh` returns 0, then `docker ps | grep dockhand` shows healthy) and a one-line uninstall.
- `scripts/dockhand-sync.sh` — thin wrapper that re-runs only Section 7 of `init-nas.sh` (the rsync `REPO_ROOT/dockhand/ → /volume2/docker/dockhand/` step, excluding `.env`, `data/`, `secrets/`) for operators who want to update Dockhand-only files without a full bootstrap. Same fallback semantics as `init-nas.sh` (rsync if available, else `cp` with no-clobber for protected paths). Exit non-zero if `dockhand/scripts/dockhand-start.sh` is not found in the source tree.

Files to delete:
- None. `dockhand/scripts/dockhand-migration.sh` is relabeled (see above), not deleted, so git history of the migration decision is preserved.

[Functions]
One new function and one in-place modification, all in `dockhand/scripts/dockhand-start.sh`.

New functions:
- `ensure_ce_internal()` in `dockhand/scripts/dockhand-start.sh` — runs `$DOCKER network inspect ce-internal >/dev/null 2>&1`; if exit code is non-zero, runs `$DOCKER network create --driver bridge --subnet 172.26.0.0/24 --gateway 172.26.0.1 ce-internal` and logs "dockhand-start: created ce-internal (172.26.0.0/24)". Returns 0 on success or already-present, non-zero only if create itself fails. Invoked once between the `socket_accessible` check and the `exists`/`create_container` branch.

Modified functions:
- `create_container()` in `dockhand/scripts/dockhand-start.sh` — no signature change; the only edit is the `--label com.centurylinklabs.watchtower.enable=true` line becomes `--label com.centurylinklabs.watchtower.enable=false` so the RC script and `dockhand/compose.yaml` agree.

Removed functions: none.

[Classes]
N/A — this is a shell/markdown/compose codebase with no classes.

[Dependencies]
No new runtime dependencies. The plan reduces effective dependency surface by retiring references to a `portainer-start.sh` script that no longer ships.

- Docker Compose v2 (already required).
- `rsync` (already used by `init-nas.sh`; the new `scripts/dockhand-sync.sh` re-uses the same `command -v rsync && … || cp` fallback pattern).
- No new container images, no version bumps, no registry changes, no package installs.

[Testing]
Validation is script-based and local; no new test framework is introduced.

- Run `bash scripts/compose-validate.sh` after edits — must continue to pass for every `stacks/*/compose.yaml`. Then run `docker compose -f dockhand/compose.yaml config -q` once explicitly (the validator scopes itself to `stacks/`, so this is an extra one-off check).
- Run `bash scripts/verify-repo-layout.sh` — must still report OK (no root-level duplicates of stack directory names).
- The new `scripts/dockhand-sync.sh` asserts the existence of `dockhand/scripts/dockhand-start.sh` in the source tree at startup; manually verify by deleting the source temporarily in a scratch clone and confirming the script exits non-zero with an explicit error.
- Manual on-NAS verification (documented, not automated): `bash /volume2/docker/dockhand/scripts/dockhand-validate.sh` followed by `curl -fs http://10.0.1.15:3866/health` must return 200.
- Doc-link sanity check (run from repo root): `grep -rn "stacks/dockhand\|/volume2/docker/dockhand/dockhand-start\|/volume2/docker/dockhand/health-check-fix" .` must return zero matches outside `implementation_plan.md` and `.git/`.

[Implementation Order]
The sequence below minimizes the risk that an intermediate state breaks a currently-deployed NAS.

1. Path-only fixes (lowest risk, zero behavior change): edit `README.md`, `DOCKHAND_MIGRATION.md`, `dockhand/README.md`, `dockhand/STRUCTURE.md`, `dockhand/scripts/health-check-fix.sh`, `dockhand/docs/HEALTH_CHECK_SOLUTION.md`, `dockhand/docs/HEALTH_CHECK_DEBUG.md`, `dockhand/docs/HEALTH_CHECK_FIX.md`.
2. `STACK_ROOT` / `DOCKHAND_DATA` alignment: update `dockhand/.env.example` and `dockhand/compose.yaml` to the canonical values. Run `docker compose -f dockhand/compose.yaml config -q` locally to confirm interpolation succeeds.
3. Watchtower-label reconciliation: change `--label com.centurylinklabs.watchtower.enable=true` to `…=false` in `dockhand/scripts/dockhand-start.sh`. The compose.yaml is already `false` — no edit there.
4. Add `ensure_ce_internal()` to `dockhand/scripts/dockhand-start.sh` and invoke it in the main flow so the script is safe to run before `init-nas.sh` on a fresh NAS.
5. Relabel `dockhand/scripts/dockhand-migration.sh` header as historical.
6. Create `dockhand/docs/DSM_BOOT_PERSISTENCE.md` and add links to it from `README.md` and `dockhand/README.md`.
7. Create `scripts/dockhand-sync.sh`, then add a "Re-sync without full bootstrap" pointer in `dockhand/docs/DEPLOYMENT.md`.
8. Sweep `AUDIT_REPORT.md` and `QUICK_FIX_CHECKLIST.md` to mark resolved items.
9. Final validation pass:
   - `bash scripts/compose-validate.sh`
   - `bash scripts/verify-repo-layout.sh`
   - `docker compose -f dockhand/compose.yaml config -q`
   - `grep -rn "stacks/dockhand\|/volume2/docker/dockhand/dockhand-start\|/volume2/docker/dockhand/health-check-fix" . | grep -v implementation_plan.md | grep -v .git` returns empty.
10. Commit as a single coherent change: `docs+infra: reconcile dockhand path/config drift, add DSM boot-persistence guide`.
