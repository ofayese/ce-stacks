# Stack: remotely

Remote IT support platform providing remote control, remote scripting, and a rich
auto-complete shell for maximising IT support efficiency. Both the service and
remote-control components use **outgoing** WebSocket connections over SSL/TLS --
no inbound firewall ports are required beyond the web UI.

## Services

| Service  | Container | Internal | Host           | Image                   |
| -------- | --------- | -------- | -------------- | ----------------------- |
| remotely | remotely  | 5000     | 10.0.1.15:5371 | immybot/remotely@sha256:9bdff2d8f7a9926731fe8394d9b0292eb5679153b1da7f3b80ecd9fa9823b89b |

## Prerequisites

- HAProxy or DSM Reverse Proxy serving HTTPS for the public URL
- **WebSocket enabled** in the reverse proxy (see below -- required for remote sessions)

## WebSocket requirement (critical)

Remotely uses SignalR over WebSocket for both the management plane and remote control
sessions. Without WebSocket support in the reverse proxy, sessions will fail silently
once an HTTPS connection is established.

**HAProxy:** Add `timeout tunnel 1h` in the `defaults` section (already set in `stacks/_haproxy/haproxy.cfg`) and ensure the backend entry uses `option http-server-close` -- no extra WebSocket headers are needed at the HAProxy layer for this service.

**DSM Reverse Proxy (alternative):**

1. Control Panel -> Login Portal -> Advanced -> Reverse Proxy
2. Select the Remotely proxy rule -> Edit
3. Custom Header tab -> Create -> select **WebSocket**
   (auto-adds `Upgrade: websocket` and `Connection: Upgrade` headers)
4. Save

## Environment variables

| Variable               | Required | Default                                         | Description                                   |
| ---------------------- | -------- | ----------------------------------------------- | --------------------------------------------- |
| `REMOTELY_SERVER_URL`  | Yes      | `https://remotely.olutechsys.com`               | Public HTTPS URL for agent download links     |
| `REMOTELY_KNOWN_PROXY` | Yes      | `10.0.1.15`                                     | Reverse proxy LAN IP -- trusts X-Forwarded-For |
| `TZ`                   | No       | `America/New_York`                              | Timezone for log timestamps                   |

## Port reference

| Port           | Protocol | Notes                                                         |
| -------------- | -------- | ------------------------------------------------------------- |
| 10.0.1.15:5371 | HTTP     | Web UI + API + WebSocket hub. Terminate TLS at reverse proxy. |

## First deploy

```bash
sudo mkdir -p "${STACK_ROOT}/remotely/data"
cd "${STACK_ROOT}/remotely"
cp .env.example .env
# Edit .env: set REMOTELY_SERVER_URL to your actual public HTTPS hostname
sudo docker compose up -d
```

## First login

Navigate to `http://10.0.1.15:5371` (or your HTTPS proxy URL).
The **first account registered is automatically granted Admin**.
Register immediately after deploy to secure the instance.

Go to **Organization** -> **Settings** -> set **Server URL** to match `REMOTELY_SERVER_URL`.
This is used to build agent installer download links.

## Health meaning

The healthcheck probes `http://localhost:5000/` -- a 200 response confirms the
ASP.NET Core host is up and accepting requests.

## Image pinning

`immybot/remotely` does not publish semver tags. The stack is currently digest-pinned; refresh the digest when needed:

```bash
sudo docker pull immybot/remotely:latest
sudo docker inspect immybot/remotely:latest \
  --format '{{index .RepoDigests 0}}'
# Update compose.yaml with the new digest: immybot/remotely@sha256:<digest>
```

## Rollback

```bash
sudo docker compose down
# Data persists in ${STACK_ROOT}/remotely/data/
```

To restore from backup, copy the data directory contents back and `docker compose up -d`.

## HAProxy routing

Add to `stacks/_haproxy/haproxy.cfg` and `stacks/_haproxy/maps/host.map` to expose Remotely via HAProxy:

```
# haproxy.cfg
backend remotely-be
    option httpchk GET /
    server remotely 10.0.1.15:5371 check

# maps/host.map
remotely.olutechsys.com	remotely-be
remotely.olutech.systems	remotely-be
# legacy LAN aliases -- retain until DNS audit confirms no devices still resolving sub-subdomain names
# remotely.otsorundscore.olutechsys.com	remotely-be
# remotely.otsorundscore.olutech.systems	remotely-be
```

After editing: validate with `haproxy -c`, then restart HAProxy via **DSM -> Package Center -> HAProxy -> Action -> Restart**.
