#!/bin/bash
# Claude Code aliases — source this in ~/.zshrc
# Add: source ~/.docker/scripts/claude-aliases.sh

MLX_PORT="${MLX_PORT:-4000}"

# ── Core aliases ─────────────────────────────────────────────────────────────

# Route Claude Code to local MLX server (free, private, ~65 tok/s)
alias claude-local='ANTHROPIC_BASE_URL=http://localhost:'"${MLX_PORT}"' ANTHROPIC_API_KEY=sk-local claude'

# Route Claude Code to Anthropic cloud (full Claude quality)
alias claude-cloud='unset ANTHROPIC_BASE_URL; claude'

# Show which mode is active
claude-mode() {
  if [ -n "$ANTHROPIC_BASE_URL" ]; then
    echo "🖥️  LOCAL  → ${ANTHROPIC_BASE_URL}"
    _mlx_status
  else
    echo "☁️  CLOUD  → Anthropic API"
  fi
}

# ── MLX server helpers ────────────────────────────────────────────────────────

mlx-start() {
  launchctl start com.laolu.mlx.server
  echo "MLX server starting — check: mlx-logs"
}

mlx-stop() {
  launchctl stop com.laolu.mlx.server
  echo "MLX server stopped"
}

mlx-logs() {
  tail -f ~/.docker/logs/mlx-server.log
}

mlx-status() {
  if curl -s http://localhost:${MLX_PORT}/health > /dev/null 2>&1; then
    local model
    model=$(curl -s http://localhost:${MLX_PORT}/health | python3 -c "import sys,json; print(json.load(sys.stdin).get('model','unknown'))" 2>/dev/null)
    echo "✓ MLX server running — model: ${model}"
  else
    echo "✗ MLX server not responding on :${MLX_PORT}"
    echo "  Start with: mlx-start"
    echo "  Logs:       mlx-logs"
  fi
}

_mlx_status() {
  mlx-status
}

# ── Ollama helpers ────────────────────────────────────────────────────────────

ollama-models() {
  docker exec ollama-server ollama list 2>/dev/null || echo "Ollama not running"
}

ollama-pull() {
  [ -z "$1" ] && echo "Usage: ollama-pull <model>" && return 1
  docker exec ollama-server ollama pull "$1"
}

ollama-status() {
  if docker ps --format '{{.Names}}' | grep -q "^ollama-server$"; then
    echo "✓ Ollama running (:11434)"
    local count
    count=$(curl -s http://localhost:11434/api/tags | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('models',[])))" 2>/dev/null)
    echo "  Models loaded: ${count:-unknown}"
  else
    echo "✗ Ollama not running"
    echo "  Start with: ~/.docker/scripts/ollama-manager.sh start"
  fi
}

# ── Stack overview ────────────────────────────────────────────────────────────

ai-status() {
  echo "=== Local AI Stack ==="
  echo ""
  mlx-status
  echo ""
  ollama-status
  echo ""
  if curl -s http://localhost:6333/health > /dev/null 2>&1; then
    echo "✓ Qdrant running (:6333)"
  else
    echo "✗ Qdrant not running"
  fi
  echo ""
  claude-mode
}
