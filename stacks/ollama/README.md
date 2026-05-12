# ollama

Local LLM runtime (`ollama`) + open-webui front-end. CPU-only on this NAS — no GPU.

## Services

- **otsai-server** (11434) — Ollama REST API; models persist at `${STACK_ROOT}/ollama/data`
- **otsai-webui** (8893) — open-webui chat UI; depends on `ollama` healthcheck; app data under `${STACK_ROOT}/ollama/data/open-webui`

## Startup order

**otsai-webui** and **`ollama-model-init`** wait on **ollama** being **healthy**. Model pulls still use the script’s wait loop. NAS flow: **`docs/hive/NAS_DEPLOYMENT.md`** → **Dockge stack lifecycle (Compose v2)**.

## Volumes

| Host path                              | Container path      | Mode | Created by    |
| -------------------------------------- | ------------------- | ---- | ------------- |
| `${STACK_ROOT}/ollama/data/ollama`     | `/root/.ollama`     | rw   | `init-nas.sh` |
| `${STACK_ROOT}/ollama/data/open-webui` | `/app/backend/data` | rw   | `init-nas.sh` |

> Run `sudo bash scripts/init-nas.sh` after cloning to create these
> directories. Without them, the container will fail to start.

## Public hostname

`ai.otsorundscore.olutechsys.com` (referenced in `WEBUI_URL`; resolved via `extra_hosts`).

## Authentication

This stack’s compose wires **local Open WebUI login** (`WEBUI_AUTH=1`) only. For **Google → DSM** (NAS login portal), see [`docs/hive/GOOGLE_WORKSPACE_OAUTH_NAS_LOGIN.md`](../../docs/hive/GOOGLE_WORKSPACE_OAUTH_NAS_LOGIN.md). Optional **SSO inside Open WebUI** (OAuth/OIDC) is configured in the app or via extra env per [Open WebUI SSO](https://docs.openwebui.com/troubleshooting/sso/) — not via tracked compose here.

## Health

- ollama: `curl http://localhost:11434/api/tags` returns JSON
- open-webui: HTTP 200 on `/health` (or `/` as fallback in older versions)

## Models

`DEFAULT_MODELS=phi4:mini,qwen2.5-coder:7b,nomic-embed-text` — CPU-friendly defaults with the embedding model AnythingLLM needs at startup.

The one-shot `ollama-model-init` service pulls tiered models from `.env`:

| Tier   | Env var               | Default models                           |
| ------ | --------------------- | ---------------------------------------- |
| Tier 1 | `OLLAMA_TIER1_MODELS` | `phi4:mini nomic-embed-text llama3.2:3b` |
| Tier 2 | `OLLAMA_TIER2_MODELS` | `qwen2.5-coder:7b llama3.1:8b`           |
| Tier 3 | `OLLAMA_TIER3_MODELS` | `deepseek-r1:7b mistral:7b qwen2.5:7b`   |

Re-run the model puller after changing tiers:

```bash
docker compose --profile init up --force-recreate ollama-model-init
```

Pull an extra model manually:

```bash
docker exec otsai-server ollama pull <model>
```

## Resource ceiling

Without `mem_limit`, model loading can eat all NAS RAM. The compose enforces:

- ollama: 16g (room for 14B Q4_K_M models + KV cache + headroom)
- open-webui: 2g (web UI, uploads, and RAG-adjacent state)

If you regularly run larger models (e.g. `llama3.1:70b`), bump `ollama` mem_limit significantly.

## Rollback

```bash
git checkout -- compose.yaml
docker compose up -d
```

Models survive under `${STACK_ROOT}/ollama/data/ollama` when you do not delete the bind. Open Webui state survives under `${STACK_ROOT}/ollama/data/open-webui` when you do not delete the bind.
