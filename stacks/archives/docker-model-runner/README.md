# docker-model-runner - Docker Model Runner (GPU)

**Compose file:** this stack uses **`docker-compose.yml`** at the folder root (not `compose.yaml`) — see [`docs/hive/COMPOSE_FILENAMES.md`](../../docs/hive/COMPOSE_FILENAMES.md).

Runs **Docker Model Runner** CUDA images for local LLM endpoints (`devstral-small-2`, `ministral3`, `smollm3`) on the Synology LAN IP `10.0.1.15`.

## Ports

| Host   | Container | Service            |
| ------ | --------- | ------------------ |
| `8001` | `8000`    | `devstral-small-2` |
| `8003` | `8000`    | `ministral3`       |
| `8011` | `8000`    | `smollm3`          |

## Volumes

No persistent volumes - stateless.

## Environment

See [`.env.example`](./.env.example). **`TZ`** defaults to `America/New_York`.

## Synology / outbound

- Requires **NVIDIA** runtime on the host where applicable; DSM GPU support is operator-specific.
- First boot pulls large images - outbound **HTTPS 443** to registry mirrors required. No offline fallback beyond pre-pulled images.

## Compose file

[`docker-compose.yml`](./docker-compose.yml) - validated by `scripts/compose-validate.sh`.
