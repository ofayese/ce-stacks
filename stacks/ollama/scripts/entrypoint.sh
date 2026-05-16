#!/usr/bin/env bash
# ollama entrypoint: start server then pull any missing models.
# Adapted from mariushosting.com pattern for Synology NAS.
#
# Models are hardcoded below. Override at runtime via MODELS env var
# (comma-separated) if you want a different set without editing this file.
#
# Models already present on disk are skipped (idempotent).
# Server stays running after pulls complete (PID 1 via wait).

set -euo pipefail

OLLAMA_BIN="${OLLAMA_BIN:-/usr/bin/ollama}"

# ── Default model list ────────────────────────────────────────────────────────
# Tier 1: baseline - small/fast, always needed
#   stablelm2:3b     ~1.9 GB  fast chat
#   nomic-embed-text ~270 MB  RAG embeddings (required for AnythingLLM/OpenWebUI)
#   llama3.2:3b      ~2.0 GB  fast general
# Tier 2: primary - workhorse models
#   stablelm2:7b     ~4.1 GB  code/reasoning
#   qwen2.5-coder:7b ~4.7 GB  code completion
#   llama3.1:8b      ~4.9 GB  general reasoning
# Tier 3: secondary - optional, comment out to save disk/RAM
#   deepseek-r1:7b   ~4.9 GB  chain-of-thought reasoning
#   mistral:7b       ~4.1 GB  general
#   qwen2.5:7b       ~4.7 GB  multilingual general
# Override by setting MODELS env var (comma-separated) in .env or compose.yaml.
# ─────────────────────────────────────────────────────────────────────────────
DEFAULT_MODELS="stablelm2:3b,nomic-embed-text,llama3.2:3b,stablelm2:7b,qwen2.5-coder:7b,llama3.1:8b,deepseek-r1:7b,mistral:7b,qwen2.5:7b"

# MODELS env var overrides the default list if set
MODELS="${MODELS:-${DEFAULT_MODELS}}"

# ── Start server ──────────────────────────────────────────────────────────────
echo "[entrypoint] Starting Ollama server..."
"${OLLAMA_BIN}" serve &
OLLAMA_PID=$!

# Wait for server to accept connections (max 5 min)
echo "[entrypoint] Waiting for Ollama to become ready..."
ATTEMPTS=0
until "${OLLAMA_BIN}" list >/dev/null 2>&1; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ "${ATTEMPTS}" -gt 60 ]; then
        echo "[entrypoint] ERROR: Ollama did not start within 5 minutes. Exiting."
        exit 1
    fi
    sleep 5
done
echo "[entrypoint] Ollama is ready."

# ── Pull models ───────────────────────────────────────────────────────────────
echo "[entrypoint] Pulling models: ${MODELS}"
for MODEL in $(echo "${MODELS}" | tr ',' ' '); do
    [ -z "${MODEL}" ] && continue
    BASE="${MODEL%%:*}"
    if "${OLLAMA_BIN}" list 2>/dev/null | grep -q "^${BASE}"; then
        echo "[entrypoint] SKIP  ${MODEL} (already present)"
    else
        echo "[entrypoint] PULL  ${MODEL} ..."
        "${OLLAMA_BIN}" pull "${MODEL}" \
            && echo "[entrypoint] OK    ${MODEL}" \
            || echo "[entrypoint] FAIL  ${MODEL} (network error - will retry on next restart)"
    fi
done

echo "[entrypoint] === Installed models ==="
"${OLLAMA_BIN}" list
echo "[entrypoint] Server running. Handing off to ollama serve (PID ${OLLAMA_PID})."

# Keep container alive; forward signals cleanly to ollama serve
wait "${OLLAMA_PID}"
