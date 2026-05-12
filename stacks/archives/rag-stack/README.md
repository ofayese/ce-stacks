# rag-stack

## Purpose

RAG pipeline: Qdrant vector DB + AnythingLLM + Open WebUI Pipelines. Connects to the **ollama** stack (`otsai-server` on **11434**) and extends **open-webui** (`otsai-webui`) with LangChain/LangGraph pipeline support.

## Services

| Service     | Container       | Internal  | Host bind (NAS)                | Image                             |
| ----------- | --------------- | --------- | ------------------------------ | --------------------------------- |
| qdrant      | rag-qdrant      | 6333/6334 | 10.0.1.15:6333, 10.0.1.15:6334 | qdrant/qdrant:v1.14.0             |
| anythingllm | rag-anythingllm | 3001      | 10.0.1.15:3002                 | mintplexlabs/anythingllm:1.7.6    |
| pipelines   | rag-pipelines   | 9099      | 10.0.1.15:9099                 | ghcr.io/open-webui/pipelines:main |

## Startup order

**anythingllm** and **pipelines** start after **qdrant** is **healthy**. NAS steps: **`docs/hive/NAS_DEPLOYMENT.md`** → **Dockge stack lifecycle (Compose v2)**.

## Prerequisites

- **ollama** stack (`otsai-server`) running on **11434**
- **open-webui** (`otsai-webui`) running on **8893**
- Pull embedding model: `docker exec otsai-server ollama pull nomic-embed-text`

## Required `.env` values

- `ANYTHINGLLM_JWT_SECRET` — generate: `openssl rand -hex 32`
- `PIPELINES_API_KEY` — set in Open WebUI → Settings → Connections → Pipelines
- `QDRANT_API_KEY` — optional; leave blank to disable API key auth on Qdrant

## Port reference

| Address        | Role                                                     |
| -------------- | -------------------------------------------------------- |
| 10.0.1.15:6333 | Qdrant REST API + web UI                                 |
| 10.0.1.15:6334 | Qdrant gRPC                                              |
| 10.0.1.15:3002 | AnythingLLM web UI + REST API (host → 3001 in container) |
| 10.0.1.15:9099 | Open WebUI Pipelines API                                 |

**Note:** HolyClaude uses host **3001** for its UI. AnythingLLM stays on **3001** inside the container but is published on host **3002** to avoid a port conflict. Always use **3002** from other stacks on the NAS LAN.

## Health meaning

- **rag-qdrant:** In-container **Perl** opens TCP **6333**, sends HTTP GET **`/readyz`**, expects **`200 OK`** in the response (the Qdrant image ships **perl** but not **curl**/**wget**/**nc**).
- **rag-anythingllm:** GET `/api/ping` returns **200** — API server ready.
- **rag-pipelines:** GET `/` returns **200** — pipeline server ready.

## First deploy

```bash
sudo mkdir -p "${STACK_ROOT}/rag-stack/data/qdrant" "${STACK_ROOT}/rag-stack/data/anythingllm" "${STACK_ROOT}/rag-stack/config/pipelines"
cp .env.example .env && nano .env
docker compose up -d
```

## Rollback

```bash
docker compose down
```

Data under `${STACK_ROOT}/rag-stack/data/` persists unless you remove those directories.
