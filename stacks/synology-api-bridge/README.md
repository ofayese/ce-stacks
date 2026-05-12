# synology-api-bridge

Internal **FastAPI** shim for **bounded** DSM HTTP calls. Binds **loopback only** (`127.0.0.1:8780→8000` by default) — **do not** publish on WAN.

## Security contract

- **`X-Bridge-Secret`** header required on **every** route except **`GET /health`** (must match **`BRIDGE_SHARED_SECRET`**).
- **No generic DSM proxy** — removed; only **allowlisted** Synology Web API tuples are implemented (see below).
- **`httpx`** uses **`DSM_HTTP_TIMEOUT_SECONDS`** on every outbound request.
- v1 **`POST /v1/file-station/list`** returns **501** until session-scoped File Station calls are designed and audited.

## Allowlisted routes (v1)

| Method | Path | DSM call |
|--------|------|----------|
| `GET` | `/health` | — |
| `GET` | `/v1/dsm/ping` | `GET ${DSM_BASE_URL}/` |
| `GET` | `/v1/syno-api/info` | `GET …/webapi/entry.cgi` with **`api=SYNO.API.Info`**, **`method=query`**, **`version=1`** only |

## Configure

1. Copy **`.env.example`** → **`.env`** (gitignored).
2. Set **`BRIDGE_SHARED_SECRET`** and **`DSM_BASE_URL`** (e.g. `https://10.0.1.15:5001`). **`DSM_BASE_URL`** is required for any allowlisted route that calls DSM; leaving it blank makes those calls fail or no-op.
3. Deploy from repo root context so **`${STACK_ROOT}`** resolves (binds **`${STACK_ROOT}/synology-api-bridge/data`** → `/data`).

```bash
cd "${STACK_ROOT}/synology-api-bridge"
docker compose up -d --build
curl -fsS -H "X-Bridge-Secret: $BRIDGE_SHARED_SECRET" http://127.0.0.1:8780/v1/syno-api/info
```

## HolyClaude gate

Do **not** remove **`SYS_ADMIN` / `SYS_PTRACE` / `seccomp:unconfined`** from HolyClaude until this bridge (or an equivalent audited path) is **deployed, verified, and adopted** — see **`stacks/holyclaude/README.md`**.
