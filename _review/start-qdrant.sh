#!/bin/bash
# Start Qdrant database and MCP server for Kilo/Continue extension

COMPOSE_FILE="$HOME/.docker/compose/docker-compose.qdrant.yml"
ENV_FILE="$HOME/.docker/compose/.env"

# Load API key from .env if present
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

QDRANT_API_KEY="${QDRANT_API_KEY:-qdrant-key-123}"

# Wait for Docker Desktop to be available (important when run at login)
echo "Waiting for Docker to be ready..."
docker_attempts=0
until docker info > /dev/null 2>&1; do
  docker_attempts=$((docker_attempts + 1))
  if [ $docker_attempts -gt 30 ]; then
    echo "✗ Docker did not become available after 60s — aborting"
    exit 1
  fi
  sleep 2
done
echo "✓ Docker is ready"

echo "Starting Qdrant database..."
docker compose -f "$COMPOSE_FILE" up -d

if [ $? -ne 0 ]; then
  echo "✗ Failed to start Qdrant"
  exit 1
fi

# Wait for Qdrant to be healthy
echo "Waiting for Qdrant to be ready..."
max_attempts=30
attempt=0
until curl -s http://localhost:6333/health > /dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ $attempt -gt $max_attempts ]; then
    echo "✗ Qdrant failed to start after $max_attempts attempts"
    exit 1
  fi
  echo "Qdrant not ready yet, waiting... ($attempt/$max_attempts)"
  sleep 2
done

echo "✓ Qdrant is running (container: qdrant-db)"
echo "✓ API Key: ${QDRANT_API_KEY}"
echo "✓ REST API: http://localhost:6333"
echo "✓ gRPC API: http://localhost:6334"

# Check if mcp-server-qdrant image exists, if not warn user
if ! docker image inspect mcp-server-qdrant > /dev/null 2>&1; then
  echo ""
  echo "⚠ Warning: mcp-server-qdrant Docker image not found"
  echo "  Pull it with: docker pull mcp-server-qdrant"
else
  echo "✓ mcp-server-qdrant image available"
fi

echo ""
echo "Ready for Continue/Kilo to use Qdrant MCP server"
