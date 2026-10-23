#!/usr/bin/env bash
# Arranca logic-pro-mcp.
#
#   ./start-logic-pro-mcp.sh                -> puente HTTP/SSE en 127.0.0.1:8765
#   ./start-logic-pro-mcp.sh --stdio [...]  -> servidor MCP stdio puro (como antes)
#   ./start-logic-pro-mcp.sh --help
#
# El puente NO modifica el servidor: lanza el binario stdio y le habla por stdin/stdout,
# exponiendo el mismo sesión MCP por:
#   POST/GET/DELETE /mcp                    (Streamable HTTP, spec 2025-03-26)
#   GET /sse  +  POST /message?sessionId=…  (HTTP+SSE, spec 2024-11-05)
#   GET /health
#
# Variables de entorno:
#   LOGIC_MCP_HOST        default 127.0.0.1
#   LOGIC_MCP_PORT        default 8765
#   LOGIC_MCP_CHILD_LOG   si se define, la salida del servidor va a ese archivo
#                         (por defecto se ve en la terminal, como siempre)
#
set -euo pipefail

LOGIC_PRO_MCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGIC_PRO_MCP_BIN="$LOGIC_PRO_MCP_DIR/.build/release/LogicProMCP"
LOGIC_MCP_BRIDGE="$LOGIC_PRO_MCP_DIR/sse-bridge.py"

if [ ! -x "$LOGIC_PRO_MCP_BIN" ]; then
  echo "No se encontró el binario en $LOGIC_PRO_MCP_BIN" >&2
  echo "Compílalo con: cd \"$LOGIC_PRO_MCP_DIR\" && swift build -c release" >&2
  exit 1
fi

case "${1:-}" in
  --stdio)
    shift
    exec "$LOGIC_PRO_MCP_BIN" "$@"
    ;;
  -h|--help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

if [ ! -f "$LOGIC_MCP_BRIDGE" ]; then
  echo "No se encontró el puente en $LOGIC_MCP_BRIDGE" >&2
  exit 1
fi

HOST="${LOGIC_MCP_HOST:-127.0.0.1}"
PORT="${LOGIC_MCP_PORT:-8765}"

bridge_args=(--bin "$LOGIC_PRO_MCP_BIN" --host "$HOST" --port "$PORT")
if [ -n "${LOGIC_MCP_CHILD_LOG:-}" ]; then
  bridge_args+=(--log "$LOGIC_MCP_CHILD_LOG")
fi

exec python3 "$LOGIC_MCP_BRIDGE" "${bridge_args[@]}" "$@"
