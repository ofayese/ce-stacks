#!/bin/bash
# =============================================================================
# MLX Server Setup — Apple Silicon native AI for Claude Code
# Installs Python venv, MLX, downloads model, creates server + launchd agent
# Run ONCE: bash ~/.docker/scripts/setup-mlx.sh
#
# Re-runnable: already-completed steps are skipped automatically.
# To change model only: MLX_MODEL=<new-model> bash setup-mlx.sh --model-only
# =============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

MLX_DIR="${HOME}/.local/mlx-server"
SCRIPTS_DIR="${HOME}/.docker/scripts"
LOGS_DIR="${HOME}/.docker/logs"
MODEL_ONLY="${1:-}"

# ---------------------------------------------------------------------------
# Model selection — ordered by suitability for M4 Max 64GB alongside Ollama
# ---------------------------------------------------------------------------
# PRIMARY: Qwen3 30B MoE — only 3B active params at inference (~8GB RAM)
#   leaves plenty of room for Ollama models; ~80-100 tok/s on M4 Max
MLX_MODEL="${MLX_MODEL:-mlx-community/Qwen3-30B-A3B-4bit}"
#
# ALTERNATIVE: Qwen3 8B dense — fastest, ~5GB RAM, great for tool calls
# MLX_MODEL="mlx-community/Qwen3-8B-4bit"
#
# LARGE (tight alongside Ollama, use if you scale back Ollama models):
# MLX_MODEL="mlx-community/Qwen3-235B-A22B-4bit"

echo -e "${BLUE}=== MLX Server Setup ===${NC}"
echo "Model: ${MLX_MODEL}"
echo "Install dir: ${MLX_DIR}"
echo ""

# ── Skip straight to model download if --model-only ─────────────────────────
if [ "$MODEL_ONLY" = "--model-only" ]; then
  echo -e "${YELLOW}[model-only] Skipping venv/pip — downloading model only...${NC}"
  if [ ! -f "${MLX_DIR}/bin/python3" ]; then
    echo -e "${RED}✗ Venv not found at ${MLX_DIR} — run setup without --model-only first${NC}"
    exit 1
  fi
  goto_model=1
fi

if [ -z "$goto_model" ]; then

# ── 1. Check prerequisites ───────────────────────────────────────────────────
echo -e "${YELLOW}[1/6] Checking prerequisites...${NC}"

if ! python3 --version 2>/dev/null | grep -qE "3\.1[2-9]|3\.[2-9][0-9]"; then
  echo -e "${RED}✗ Python 3.12+ required. Install via: brew install python@3.12${NC}"
  exit 1
fi
echo "✓ Python $(python3 --version)"

if ! sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -q "Apple"; then
  echo -e "${RED}✗ Apple Silicon required for MLX${NC}"
  exit 1
fi
echo "✓ Apple Silicon confirmed"

# ── 2. HuggingFace authentication ────────────────────────────────────────────
echo -e "${YELLOW}[2/6] Checking HuggingFace authentication...${NC}"

HF_TOKEN_FILE="${HOME}/.cache/huggingface/token"
HF_TOKEN_ENV="${HF_TOKEN:-}"

if [ -n "$HF_TOKEN_ENV" ]; then
  echo "✓ HF_TOKEN set via environment"
elif [ -f "$HF_TOKEN_FILE" ] && [ -s "$HF_TOKEN_FILE" ]; then
  echo "✓ HuggingFace token found at ${HF_TOKEN_FILE}"
else
  echo ""
  echo -e "${YELLOW}HuggingFace token not found.${NC}"
  echo "Most mlx-community models are public but some require authentication."
  echo ""
  echo "Options:"
  echo "  1) Enter HF token now (get one free at https://huggingface.co/settings/tokens)"
  echo "  2) Skip — will attempt download without auth (works for public models)"
  echo ""
  read -rp "Enter HuggingFace token (or press Enter to skip): " hf_input
  if [ -n "$hf_input" ]; then
    mkdir -p "$(dirname "$HF_TOKEN_FILE")"
    echo -n "$hf_input" > "$HF_TOKEN_FILE"
    chmod 600 "$HF_TOKEN_FILE"
    echo "✓ Token saved to ${HF_TOKEN_FILE}"
  else
    echo "  Skipping — will try unauthenticated download"
  fi
fi

# ── 3. Create Python venv ────────────────────────────────────────────────────
echo -e "${YELLOW}[3/6] Setting up Python venv at ${MLX_DIR}...${NC}"

if [ -f "${MLX_DIR}/bin/python3" ]; then
  echo "✓ Venv already exists — skipping"
else
  python3 -m venv "${MLX_DIR}"
  "${MLX_DIR}/bin/pip" install --upgrade pip --quiet
  echo "✓ Venv created"
fi

# ── 4. Install MLX ───────────────────────────────────────────────────────────
echo -e "${YELLOW}[4/6] Installing MLX packages...${NC}"

if "${MLX_DIR}/bin/python3" -c "import mlx_lm" 2>/dev/null; then
  echo "✓ mlx-lm already installed — skipping"
else
  "${MLX_DIR}/bin/pip" install mlx-lm --quiet
  echo "✓ mlx-lm installed"
fi

fi  # end skip-for-model-only block

# ── 5. Download model (fault-tolerant) ───────────────────────────────────────
echo -e "${YELLOW}[5/6] Downloading model: ${MLX_MODEL}${NC}"
echo "  First-run download may be 8-30 GB. This is a one-time step."

# Check if already cached
CACHE_PATH="${HOME}/.cache/huggingface/hub"
MODEL_SLUG=$(echo "$MLX_MODEL" | tr '/' '--')
if ls "${CACHE_PATH}/models--${MODEL_SLUG}" 2>/dev/null | grep -q snapshots; then
  echo "✓ Model already in HuggingFace cache — skipping download"
  MODEL_READY=1
else
  echo "  Downloading..."
  # Use HF token if available
  HF_TOKEN_VAL=""
  if [ -f "${HOME}/.cache/huggingface/token" ]; then
    HF_TOKEN_VAL=$(cat "${HOME}/.cache/huggingface/token")
  fi

  if "${MLX_DIR}/bin/python3" - <<PYEOF
import os, sys
token = os.environ.get("HF_TOKEN", "")
if not token:
    token_file = os.path.expanduser("~/.cache/huggingface/token")
    if os.path.exists(token_file):
        with open(token_file) as f:
            token = f.read().strip()

kwargs = {"token": token} if token else {}
try:
    from mlx_lm.utils import load
    print("  Loading model — this will take a while on first run...")
    load("${MLX_MODEL}", **kwargs)
    print("  Model downloaded and cached.")
except Exception as e:
    print(f"  ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
  then
    echo "✓ Model ready"
    MODEL_READY=1
  else
    echo ""
    echo -e "${YELLOW}⚠ Model download failed — server files will still be written.${NC}"
    echo "  To retry the download later, run:"
    echo "    MLX_MODEL=${MLX_MODEL} bash ${SCRIPTS_DIR}/setup-mlx.sh --model-only"
    echo ""
    echo "  Common fixes:"
    echo "  • Add a HuggingFace token:  huggingface-cli login"
    echo "  • Try a smaller public model:"
    echo "      MLX_MODEL=mlx-community/Qwen3-8B-Instruct-4bit bash ${SCRIPTS_DIR}/setup-mlx.sh --model-only"
    MODEL_READY=0
  fi
fi

# ── 6. Write server files ────────────────────────────────────────────────────
echo -e "${YELLOW}[6/6] Writing server scripts and launchd agent...${NC}"

mkdir -p "${SCRIPTS_DIR}" "${LOGS_DIR}"

# ── mlx-server.py ────────────────────────────────────────────────────────────
cat > "${SCRIPTS_DIR}/mlx-server.py" << 'PYEOF'
#!/usr/bin/env python3
"""
MLX Native Server — Anthropic API compatible
Serves local model to Claude Code with zero proxy overhead.
"""

import json
import re
import time
import os
import sys
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%H:%M:%S"
)
log = logging.getLogger(__name__)

MODEL_NAME = os.environ.get(
    "MLX_MODEL",
    "mlx-community/Qwen3-30B-A3B-4bit"
)
PORT = int(os.environ.get("MLX_PORT", "4000"))
MAX_TOKENS = int(os.environ.get("MLX_MAX_TOKENS", "8192"))

# HuggingFace token (read from file if not in env)
hf_token = os.environ.get("HF_TOKEN", "")
if not hf_token:
    token_path = os.path.expanduser("~/.cache/huggingface/token")
    if os.path.exists(token_path):
        with open(token_path) as f:
            hf_token = f.read().strip()
if hf_token:
    os.environ["HF_TOKEN"] = hf_token

log.info(f"Loading model: {MODEL_NAME}")
try:
    from mlx_lm import load, generate
    model, tokenizer = load(MODEL_NAME)
    log.info("Model loaded — server ready")
except Exception as e:
    log.error(f"Failed to load model: {e}")
    log.error("Run setup-mlx.sh --model-only to download the model first")
    sys.exit(1)


def strip_think_tags(text: str) -> str:
    """Remove Qwen3 <think>...</think> reasoning blocks from output."""
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()


def messages_to_prompt(messages: list) -> str:
    """Convert Anthropic message format to a single prompt string."""
    parts = []
    for msg in messages:
        role = msg.get("role", "user")
        content = msg.get("content", "")
        if isinstance(content, list):
            content = " ".join(
                c.get("text", "") for c in content if c.get("type") == "text"
            )
        parts.append(f"<|im_start|>{role}\n{content}<|im_end|>")
    parts.append("<|im_start|>assistant\n")
    return "\n".join(parts)


class AnthropicHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        log.info(f"{self.address_string()} — {format % args}")

    def send_json(self, data: dict, status: int = 200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.send_json({"status": "ok", "model": MODEL_NAME})
        else:
            self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))

        if self.path == "/v1/messages":
            self._handle_messages(body)
        else:
            self.send_json({"error": "not found"}, 404)

    def _handle_messages(self, body: dict):
        messages = body.get("messages", [])
        system = body.get("system", "")
        max_tokens = body.get("max_tokens", MAX_TOKENS)

        if system:
            messages = [{"role": "system", "content": system}] + messages

        prompt = messages_to_prompt(messages)
        t0 = time.time()

        raw = generate(
            model,
            tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
            verbose=False,
        )

        text = strip_think_tags(raw)
        elapsed = time.time() - t0
        tokens = len(text.split())
        log.info(f"Generated {tokens} tokens in {elapsed:.1f}s ({tokens/elapsed:.0f} tok/s)")

        self.send_json({
            "id": f"msg_{int(time.time())}",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": text}],
            "model": MODEL_NAME,
            "stop_reason": "end_turn",
            "usage": {
                "input_tokens": len(prompt.split()),
                "output_tokens": tokens,
            },
        })


if __name__ == "__main__":
    log.info(f"Starting MLX server on :{PORT}")
    server = HTTPServer(("127.0.0.1", PORT), AnthropicHandler)
    log.info(f"Ready — claude-local routes to http://localhost:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Server stopped")
PYEOF

chmod +x "${SCRIPTS_DIR}/mlx-server.py"
echo "✓ mlx-server.py written"

# ── start-mlx-server.sh ───────────────────────────────────────────────────────
cat > "${SCRIPTS_DIR}/start-mlx-server.sh" << SHEOF
#!/bin/bash
# Start the MLX native AI server — called by launchd at login

MLX_DIR="\${HOME}/.local/mlx-server"
SCRIPTS_DIR="\${HOME}/.docker/scripts"

export MLX_MODEL="${MLX_MODEL}"
export MLX_PORT="4000"
export MLX_MAX_TOKENS="8192"

exec "\${MLX_DIR}/bin/python3" "\${SCRIPTS_DIR}/mlx-server.py"
SHEOF

chmod +x "${SCRIPTS_DIR}/start-mlx-server.sh"
echo "✓ start-mlx-server.sh written"

# ── launchd plist ─────────────────────────────────────────────────────────────
PLIST_PATH="${HOME}/Library/LaunchAgents/com.laolu.mlx.server.plist"

cat > "${PLIST_PATH}" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.laolu.mlx.server</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPTS_DIR}/start-mlx-server.sh</string>
  </array>
  <key>StandardOutPath</key>
  <string>${LOGS_DIR}/mlx-server.log</string>
  <key>StandardErrorPath</key>
  <string>${LOGS_DIR}/mlx-server-error.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>
</dict>
</plist>
PLIST

echo "✓ launchd plist written to ${PLIST_PATH}"

# Reload plist if it was already loaded
launchctl unload "${PLIST_PATH}" 2>/dev/null || true
launchctl load "${PLIST_PATH}" 2>/dev/null && echo "✓ launchd agent loaded" || echo "  launchd load failed — relogin to activate"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "${MODEL_READY:-0}" = "1" ]; then
  echo -e "${GREEN}=== Setup Complete ===${NC}"
  echo ""
  echo "Starting MLX server now..."
  launchctl start com.laolu.mlx.server 2>/dev/null && sleep 2
  if curl -s http://localhost:4000/health > /dev/null 2>&1; then
    MODEL_INFO=$(curl -s http://localhost:4000/health | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('model','unknown'))" 2>/dev/null)
    echo -e "${GREEN}✓ MLX server running — model: ${MODEL_INFO}${NC}"
  else
    echo "  Server starting (model loading takes ~30s on first boot)"
    echo "  Check: tail -f ${LOGS_DIR}/mlx-server.log"
  fi
else
  echo -e "${YELLOW}=== Partial Setup — Model Download Needed ===${NC}"
  echo ""
  echo "Server files are in place. Once you have the model, run:"
  echo "  MLX_MODEL=${MLX_MODEL} bash ${SCRIPTS_DIR}/setup-mlx.sh --model-only"
  echo ""
  echo "Or try a smaller public model (no auth required):"
  echo "  MLX_MODEL=mlx-community/Qwen3-8B-Instruct-4bit bash ${SCRIPTS_DIR}/setup-mlx.sh --model-only"
fi
echo ""
echo "Shell aliases (add to ~/.zshrc if not already):"
echo "  source ~/.docker/scripts/claude-aliases.sh"
echo ""
echo "Usage:"
echo "  claude-local    → MLX server (free, private)"
echo "  claude-cloud    → Anthropic API"
echo "  ai-status       → full stack health"
