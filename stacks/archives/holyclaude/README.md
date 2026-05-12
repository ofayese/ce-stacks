# HolyClaude Stack

Dev-only HolyClaude workstation stack for Synology Dockge.

## Run

1. Copy `.env.example` to `.env` and fill values.
2. Start stack:
   - `docker compose -f compose.yaml up -d`
3. Open:

- `http://<nas-ip>:3001`

### WebSocket note (DSM reverse proxy)

HolyClaude UI behavior can degrade behind DSM reverse proxy if WebSocket headers are missing.
Enable WebSocket on the DSM reverse proxy rule:

1. DSM Control Panel → Login Portal → Advanced → Reverse Proxy
2. Edit HolyClaude rule
3. Custom Header → Create → WebSocket

DSM then adds `Upgrade: websocket` and `Connection: Upgrade`.

## Persistence

- Agent/workstation config:
  - `claude-home:/home/claude/.claude`
- Project workspace (host bind):
  - `${STACK_ROOT}/holyclaude/data:/workspace` — scoped stack data; see `compose.yaml`. If you previously relied on the entire stacks tree at `/workspace`, migrate any needed paths (for example `.claude-flow`) **into** `holyclaude/data/` on the host before recreating the container.
- CloudCLI persistent state (survives rebuild/recreate/down-up without `-v`):
  - `cloudcli-data:/home/claude/.cloudcli`

Important: `docker compose down -v` removes named volumes, including `cloudcli-data`.
This also removes `claude-home`.

## Notifications (Discord)

Set in local `.env`:

- `DISCORD_WEBHOOK_URL=...` (same secret style as `acme-sh`)
- `NOTIFY_DISCORD=discord://webhook_id/webhook_token`

Enable notifications inside container:

- `touch /home/claude/.claude/notify-on`

Disable:

- `rm /home/claude/.claude/notify-on`

Reference formats:

- `https://github.com/CoderLuii/HolyClaude/blob/master/docs/configuration.md`

## Baseline and HAProxy gate

This stack must pass baseline verification first (including `.claude-flow` read/write and persistence tests) before any HAProxy/TLS integration is proposed or applied.

## DSM API bridge gate (before lowering HolyClaude privileges)

The optional **`synology-api-bridge`** stack (`stacks/synology-api-bridge/`) exists so DSM HTTP calls can be bounded (timeouts, **`X-Bridge-Secret`**, loopback bind, **allowlisted** `api`/`method`/`version` only — **no** generic path proxy). **Do not merge** any PR that removes **`SYS_ADMIN`**, **`SYS_PTRACE`**, or **`seccomp:unconfined`** from HolyClaude until that bridge (or an equivalent audited DSM integration) is deployed, configured, and adopted in operator runbooks.

## Further tuning

See [`docs/hive/STACK_OPTIMIZATION_CUSTOMIZATION.md`](../../docs/hive/STACK_OPTIMIZATION_CUSTOMIZATION.md) for WebSocket-aware hardening context, API usage notes, and resource tuning alongside this README.

## Verification checklist

- `docker compose -f compose.yaml config` succeeds.
- Service is reachable on `http://<nas-ip>:3059`.
- Inside HolyClaude:
  - `ls /workspace/.claude-flow`
  - create and remove `/workspace/.claude-flow/holyclaude-write-test.txt`
- Persistence:
  - create `/home/claude/.cloudcli/persist-check.txt`
  - verify after rebuild/recreate/down-up cycles without `-v`.
