# DSM Boot Persistence for Dockhand

## Why this is needed

Synology DSM 7.x -- including DSM 7.3 -- **does not** automatically execute
scripts in `/usr/local/etc/rc.d/` on system boot. The directory exists and is
the documented historical convention, but DSM only runs those scripts when
*you* invoke them. After a reboot, `dockhand` (and any other RC-managed
container) stays down until something kicks it.

To make Dockhand survive a NAS reboot, register a DSM **Task Scheduler**
"Triggered Task" that runs the RC script at boot-up.

## One-time setup

### 1. Install the RC script

If you have not already, install the RC script from the repo:

```bash
sudo cp /volume2/docker/dockhand/scripts/dockhand-start.sh \
        /usr/local/etc/rc.d/dockhand.sh
sudo chmod +x /usr/local/etc/rc.d/dockhand.sh
```

Run it once manually to confirm Dockhand comes up healthy:

```bash
sudo /usr/local/etc/rc.d/dockhand.sh
docker ps | grep dockhand    # expect "(healthy)" within ~2 minutes
```

### 2. Create the DSM boot-up task

In DSM web UI:

1. **Control Panel -> Task Scheduler -> Create -> Triggered Task -> User-defined script**
2. **General**
   - Task: `dockhand boot`
   - User: `root`
   - Event: `Boot-up`
   - Enabled: [OK]
3. **Task Settings**
   - Run command:
     ```sh
     bash /usr/local/etc/rc.d/dockhand.sh >/var/log/dockhand-boot.log 2>&1
     ```
   - (Optional) Notify by email on abnormal exit
4. **Save** and acknowledge the root-password prompt.

### 3. Verify

Reboot the NAS (Control Panel -> Info Center -> Restart) and after it comes back
up:

```bash
docker ps | grep dockhand                  # container should be running
docker inspect dockhand | jq '.State.Health.Status'   # "healthy"
sudo tail -20 /var/log/dockhand-boot.log    # script output for the boot run
```

`curl -fs http://10.0.1.15:3866/health` should return HTTP 200.

## Uninstall

To stop Dockhand from auto-starting after reboot **without removing the
container**:

```bash
# Disable the DSM task: Task Scheduler -> "dockhand boot" -> Disable (or Delete)
sudo rm -f /usr/local/etc/rc.d/dockhand.sh
```

Already-running containers are untouched; the next reboot simply will not
re-create the Dockhand container.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Task never fires | Trigger set to wrong event | Edit task -> Event -> `Boot-up` |
| Task fires but Dockhand never appears | `/usr/local/bin/docker` not in `$PATH` for `root` | The RC script already pins `DOCKER="/usr/local/bin/docker"`; check `/var/log/dockhand-boot.log` for the actual error |
| Task fires but reports lock-file error | A previous run did not clean up `/tmp/dockhand-start.lock` | `sudo rm -rf /tmp/dockhand-start.lock && sudo /usr/local/etc/rc.d/dockhand.sh` |
| Dockhand starts but `ce-internal` missing | `init-nas.sh` was never run | The RC script now auto-creates `ce-internal` via `ensure_ce_internal()`; if it fails, run `docker network create --driver bridge --subnet 172.26.0.0/24 --gateway 172.26.0.1 ce-internal` |

## Related

- [`dockhand/scripts/dockhand-start.sh`](../scripts/dockhand-start.sh) -- the RC script itself
- [`dockhand/docs/DEPLOYMENT.md`](DEPLOYMENT.md) -- initial copy-to-NAS flow
- [`dockhand/docs/HEALTH_CHECK_DEBUG.md`](HEALTH_CHECK_DEBUG.md) -- health-check troubleshooting
