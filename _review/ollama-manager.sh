#!/bin/bash

# Ollama Model Manager Script

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Set compose file path
COMPOSE_FILE="${HOME}/.docker/compose/docker-compose-ollama.yml"

# Container names — must match container_name fields in compose file
OLLAMA_CONTAINER="ollama-server"
PULLER_CONTAINER="ollama-model-puller"

# Check if compose file exists
if [ ! -f "$COMPOSE_FILE" ]; then
  echo -e "${RED}Error: Compose file not found at $COMPOSE_FILE${NC}"
  exit 1
fi

echo -e "${BLUE}=== Ollama Model Manager ===${NC}\n"

case "$1" in
  start)
    # Wait for Docker Desktop to be available (important when run at login)
    echo "Waiting for Docker to be ready..."
    docker_attempts=0
    until docker info > /dev/null 2>&1; do
      docker_attempts=$((docker_attempts + 1))
      if [ $docker_attempts -gt 30 ]; then
        echo -e "${RED}✗ Docker did not become available after 60s — aborting${NC}"
        exit 1
      fi
      sleep 2
    done
    echo -e "${GREEN}✓ Docker is ready${NC}"
    echo "Starting Ollama with model puller..."
    docker compose -f "$COMPOSE_FILE" up -d
    echo -e "${GREEN}✓ Ollama started. Models pulling in background...${NC}"
    echo "Check progress: $0 logs-puller"
    ;;

  stop)
    echo "Stopping Ollama..."
    docker compose -f "$COMPOSE_FILE" down
    echo -e "${GREEN}✓ Ollama stopped${NC}"
    ;;

  logs)
    echo "Ollama server logs:"
    if ! docker ps --format '{{.Names}}' | grep -q "^${OLLAMA_CONTAINER}$"; then
      echo -e "${RED}Ollama container not running. Start with: $0 start${NC}"
      exit 1
    fi
    docker logs "$OLLAMA_CONTAINER"
    ;;

  logs-puller)
    echo "Model puller logs:"
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${PULLER_CONTAINER}$"; then
      echo -e "${RED}Model puller container not found. Start with: $0 start${NC}"
      exit 1
    fi
    docker logs "$PULLER_CONTAINER"
    ;;

  models)
    echo "Available models:"
    curl -s http://localhost:11434/api/tags | jq '.models[] | {name: .name, size: .size}' 2>/dev/null || echo "Ollama not running"
    ;;

  pull)
    if [ -z "$2" ]; then
      echo "Usage: $0 pull <model-name>"
      echo "Examples:"
      echo "  $0 pull qwen2.5-coder-32b"
      echo "  $0 pull llama3"
      echo "  $0 pull deepseek-coder"
      exit 1
    fi
    if ! docker ps --format '{{.Names}}' | grep -q "^${OLLAMA_CONTAINER}$"; then
      echo -e "${RED}Ollama container not running. Start with: $0 start${NC}"
      exit 1
    fi
    echo "Pulling $2..."
    docker exec "$OLLAMA_CONTAINER" ollama pull "$2"
    echo -e "${GREEN}✓ Model $2 pulled${NC}"
    ;;

  rm)
    if [ -z "$2" ]; then
      echo "Usage: $0 rm <model-name>"
      exit 1
    fi
    if ! docker ps --format '{{.Names}}' | grep -q "^${OLLAMA_CONTAINER}$"; then
      echo -e "${RED}Ollama container not running. Start with: $0 start${NC}"
      exit 1
    fi
    echo "Removing $2..."
    docker exec "$OLLAMA_CONTAINER" ollama rm "$2"
    echo -e "${GREEN}✓ Model $2 removed${NC}"
    ;;

  status)
    if docker ps --format '{{.Names}}' | grep -q "^${OLLAMA_CONTAINER}$"; then
      echo -e "${GREEN}✓ Ollama is running (container: ${OLLAMA_CONTAINER})${NC}"
      MODEL_COUNT=$(curl -s http://localhost:11434/api/tags | jq '.models | length' 2>/dev/null)
      if [ -n "$MODEL_COUNT" ]; then
        echo "Models available: ${MODEL_COUNT}"
      else
        echo "Status: models loading..."
      fi
    else
      echo -e "${RED}✗ Ollama is not running${NC}"
      echo "Start with: $0 start"
    fi
    ;;

  *)
    echo "Usage: $0 {start|stop|status|logs|logs-puller|models|pull|rm} [args]"
    echo ""
    echo "Commands:"
    echo "  start              Start Ollama and auto-pull best models"
    echo "  stop               Stop Ollama"
    echo "  status             Check Ollama status"
    echo "  logs               View Ollama server logs"
    echo "  logs-puller        View model puller logs"
    echo "  models             List available models with sizes"
    echo "  pull <model>       Pull a specific model"
    echo "  rm <model>         Remove a model"
    echo ""
    echo "Recommended models (M4 Max 64GB optimised):"
    echo "  Embeddings (for Qdrant RAG):"
    echo "  - qwen3-embedding:8b   (Best quality embeddings)"
    echo "  - nomic-embed-text     (Tiny, fast fallback)"
    echo "  Fast / Lightweight:"
    echo "  - qwen3:4b             (Ultra-fast tool calls)"
    echo "  - phi4-mini            (Microsoft Phi 4)"
    echo "  - mistral              (Universal UI support)"
    echo "  General (64GB allows 14B-35B as everyday models):"
    echo "  - qwen3:14b            (Fast, high quality)"
    echo "  - qwen3.5:35b          (Best general + vision)"
    echo "  - gemma3:27b           (Google, great structured output)"
    echo "  Coding:"
    echo "  - qwen3-coder:30b      (Dedicated coding, agentic)"
    echo "  - codegemma:7b         (Fast code completion)"
    echo "  Reasoning:"
    echo "  - deepseek-r1:14b      (Deep analysis, shows thinking)"
    echo ""
    echo "Note: Claude Code local AI runs via MLX server (:4000) — not Ollama."
    echo "  claude-local  → MLX (free, private)"
    echo "  claude-cloud  → Anthropic API"
    exit 1
    ;;
esac
