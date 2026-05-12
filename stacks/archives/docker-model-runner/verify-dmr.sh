#!/usr/bin/env bash
set -euo pipefail
echo "== docker model status =="
docker model status
echo
echo "== TCP models (OpenAI-compatible) =="
curl -sS "http://localhost:12434/engines/v1/models" | head -c 1200
echo
echo
echo "OK if JSON lists models above."
