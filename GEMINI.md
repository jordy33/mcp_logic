# Logic Pro MCP - Project Instructions

## Architecture & Environment
- **Target DAW:** Logic Pro Creator Studio (`com.apple.mobilelogic`) version 13.0+.
- **MCP Transport:** SSE bridge via `sse-bridge.py` on `http://127.0.0.1:8765/sse`.
- **Client Configuration:** Registered in `~/.gemini/settings.json` under `mcpServers.logic-pro`.

## Startup Procedure
To start the server and SSE bridge:
```bash
./start-logic-pro-mcp.sh &
```
Verify health:
```bash
curl -s http://127.0.0.1:8765/health
```
