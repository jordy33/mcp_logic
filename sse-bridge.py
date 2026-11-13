#!/usr/bin/env python3
"""stdio -> HTTP bridge for logic-pro-mcp.

Speaks both transports against the SAME upstream stdio process:

  * Streamable HTTP (2025-03-26):   POST /mcp   (JSON or SSE reply), GET /mcp (standalone SSE), DELETE /mcp
  * Legacy HTTP+SSE (2024-11-05):    GET  /sse    -> `endpoint` event, then POST /message?sessionId=...

Extra: GET /health.

The upstream server is unchanged: this process spawns `.build/release/LogicProMCP`
(the stdio server) and multiplexes JSON-RPC onto its stdin/stdout.

Usage:
    python3 sse-bridge.py --port 8765
    python3 sse-bridge.py --bin /path/to/LogicProMCP --port 8765 --log /tmp/logic-mcp.log
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DEFAULT_BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".build/release/LogicProMCP")
PROTOCOL_VERSION = "2025-03-26"
CLIENT_INFO = {"name": "logic-pro-mcp-sse-bridge", "version": "1.0"}
DEFAULT_TIMEOUT = float(os.getenv("LOGIC_MCP_REQUEST_TIMEOUT", "630.0"))


class Upstream:
    """Owns the stdio child and routes JSON-RPC by rewritten id."""

    def __init__(self, argv: list[str], log_path: str | None):
        self._stderr_fh = open(log_path, "ab", buffering=0) if log_path else None
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self._stderr_fh if self._stderr_fh else None,
            bufsize=0,
        )
        self._lock = threading.Lock()
        self._seq = 0
        self._pending: dict[str, tuple[queue.Queue, object]] = {}
        self._notify_sinks: set[queue.Queue] = set()
        threading.Thread(target=self._read_loop, name="upstream-read", daemon=True).start()

    def _read_loop(self) -> None:
        assert self.proc.stdout is not None
        for raw in self.proc.stdout:
            line = raw.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            rid = msg.get("id")
            with self._lock:
                entry = self._pending.pop(rid, None) if rid is not None else None
            if entry is not None:
                sink, original_id = entry
                msg["id"] = original_id  # undo bridge rewrite
                try:
                    sink.put_nowait(msg)
                except queue.Full:
                    pass
            else:
                for sink in list(self._notify_sinks):
                    try:
                        sink.put_nowait(msg)
                    except queue.Full:
                        self._notify_sinks.discard(sink)

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=100)
        self._notify_sinks.add(q)
        return q

    def unsubscribe(self, q: queue.Queue) -> None:
        self._notify_sinks.discard(q)

    def send(self, msg: dict, sink: queue.Queue | None) -> str | None:
        """Forward one JSON-RPC message. Returns the internal id when a reply is expected."""
        with self._lock:
            original_id = msg.get("id")
            if original_id is None:
                self._write(msg)
                return None
            self._seq += 1
            internal = f"bridge-{self._seq}"
            out = dict(msg)
            out["id"] = internal
            if sink is not None:
                self._pending[internal] = (sink, original_id)
            self._write(out)
            return internal

    def _write(self, msg: dict) -> None:
        assert self.proc.stdin is not None
        data = (json.dumps(msg, separators=(",", ":")) + "\n").encode()
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def request(self, msg: dict, timeout: float | None = None) -> dict:
        t = timeout if timeout is not None else DEFAULT_TIMEOUT
        q: queue.Queue = queue.Queue(maxsize=1)
        internal = self.send(msg, q)
        try:
            reply = q.get(timeout=t)
        except queue.Empty:
            with self._lock:
                self._pending.pop(internal, None)
            raise TimeoutError(f"no reply to {msg.get('method')!r} in {t}s")
        return reply

    def alive(self) -> bool:
        return self.proc.poll() is None

    def close(self) -> None:
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


class SSESession:
    def __init__(self) -> None:
        self.id = uuid.uuid4().hex
        self.queue: queue.Queue = queue.Queue(maxsize=1000)


class Bridge:
    def __init__(self, upstream: Upstream):
        self.upstream = upstream
        self.sessions: dict[str, SSESession] = {}
        self._lock = threading.Lock()
        self._init_result: dict | None = None

    def prime(self) -> None:
        """Perform the one-time handshake on behalf of all clients."""
        msg = {
            "jsonrpc": "2.0",
            "id": "bridge-initialize",
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": CLIENT_INFO,
            },
        }
        try:
            reply = self.upstream.request(msg, timeout=120.0)
        except Exception as exc:
            sys.stderr.write(f"[bridge] warning: upstream initialize failed: {exc}\n")
            return
        result = reply.get("result")
        if result is None:
            sys.stderr.write(f"[bridge] warning: upstream initialize rejected: {reply.get('error')}\n")
            return
        with self._lock:
            self._init_result = result
        self.upstream.send({"jsonrpc": "2.0", "method": "notifications/initialized"}, None)
        info = result.get("serverInfo") or {}
        sys.stderr.write(
            "[bridge] upstream initialized: %s %s (protocol %s)\n"
            % (info.get("name", "?"), info.get("version", ""), result.get("protocolVersion", "?"))
        )

    def initialize_reply(self, payload: dict) -> dict | None:
        """Answer a client `initialize` from the cached handshake, if primed."""
        with self._lock:
            if self._init_result is None:
                return None
            return {"jsonrpc": "2.0", "id": payload.get("id"), "result": self._init_result}

    def new_session(self) -> SSESession:
        s = SSESession()
        with self._lock:
            self.sessions[s.id] = s
        return s

    def get_session(self, sid: str) -> SSESession | None:
        with self._lock:
            return self.sessions.get(sid)

    def drop_session(self, sid: str) -> None:
        with self._lock:
            self.sessions.pop(sid, None)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "logic-pro-mcp-sse-bridge/1.0"
    bridge: Bridge  # injected

    def handle_one_request(self) -> None:
        try:
            super().handle_one_request()
        except (ConnectionResetError, BrokenPipeError):
            self.close_connection = True

    def finish(self) -> None:
        try:
            super().finish()
        except (ConnectionResetError, BrokenPipeError):
            pass

    def _check_security(self) -> bool:
        if "Origin" in self.headers:
            self.send_response(403)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b'{"error":"forbidden"}')))
            self.end_headers()
            self.wfile.write(b'{"error":"forbidden"}')
            return False
        host = (self.headers.get("Host") or "").split(":")[0].lower()
        if host not in ("127.0.0.1", "localhost", "::1", "::"):
            self.send_response(403)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b'{"error":"forbidden"}')))
            self.end_headers()
            self.wfile.write(b'{"error":"forbidden"}')
            return False
        return True

    def _json(self, code: int, payload: dict | None) -> None:
        body = json.dumps(payload).encode() if payload is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _sse_headers(self, close: bool = False) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache, no-transform")
        self.send_header("Connection", "close" if close else "keep-alive")
        if close:
            self.close_connection = True
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

    def _write_event(self, data: dict, event: str | None = None, event_id: str | None = None) -> None:
        if event_id is not None:
            self.wfile.write(f"id: {event_id}\n".encode())
        if event is not None:
            self.wfile.write(f"event: {event}\n".encode())
        self.wfile.write(b"data: " + json.dumps(data, separators=(",", ":")).encode() + b"\n\n")
        self.wfile.flush()

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _reply_mcp(self, reply: dict, wants_sse: bool) -> None:
        if wants_sse:
            self._sse_headers(close=True)
            self._write_event(reply, event="message", event_id=str(int(time.time() * 1000)))
            return
        body = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if self.headers.get("Mcp-Session-Id"):
            self.send_header("Mcp-Session-Id", self.headers["Mcp-Session-Id"])
        self.end_headers()
        self.wfile.write(body)

    def _pump_session(self, session: SSESession, initial: str | None = None) -> None:
        try:
            if initial is not None:
                self.wfile.write(f"event: endpoint\ndata: {initial}\n\n".encode())
                self.wfile.flush()
            while True:
                try:
                    msg = session.queue.get(timeout=15)
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    continue
                self._write_event(msg, event="message")
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.bridge.drop_session(session.id)

    def do_OPTIONS(self) -> None:  # noqa: N802
        if not self._check_security():
            return
        self.send_response(405)
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        if not self._check_security():
            return
        path = urlparse(self.path).path
        if path == "/health":
            self._json(200, {"ok": self.bridge.upstream.alive(), "transport": ["streamable-http", "sse"]})
            return
        if path == "/sse":
            session = self.bridge.new_session()
            self._sse_headers()
            self._pump_session(session, initial=f"/message?sessionId={session.id}")
            return
        if path == "/mcp":
            sink = self.bridge.upstream.subscribe()
            try:
                self._sse_headers()
                while True:
                    try:
                        msg = sink.get(timeout=15)
                    except queue.Empty:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
                        continue
                    self._write_event(msg, event="message")
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                self.bridge.upstream.unsubscribe(sink)
            return
        self._json(404, {"error": "not found", "paths": ["/health", "/sse", "/message", "/mcp"]})

    def do_POST(self) -> None:  # noqa: N802
        if not self._check_security():
            return
        parsed = urlparse(self.path)
        body = self._read_body()
        if not body:
            self._json(400, {"error": "empty body"})
            return
        try:
            payload = json.loads(body)
        except json.JSONDecodeError as exc:
            self._json(400, {"error": f"invalid JSON: {exc}"})
            return

        if parsed.path == "/message":
            sid = (parse_qs(parsed.query).get("sessionId") or [""])[0]
            session = self.bridge.get_session(sid)
            if session is None:
                self._json(404, {"error": "unknown sessionId"})
                return
            self.bridge.upstream.send(payload, session.queue)
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if parsed.path == "/mcp":
            if payload.get("id") is None:
                self.bridge.upstream.send(payload, None)
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            accept = (self.headers.get("Accept") or "").lower()
            wants_sse = "text/event-stream" in accept and "application/json" not in accept
            if payload.get("method") == "initialize":
                cached = self.bridge.initialize_reply(payload)
                if cached is not None:
                    self._reply_mcp(cached, wants_sse)
                    return
            try:
                reply = self.bridge.upstream.request(payload)
                if payload.get("method") == "initialize" and self.bridge._init_result is None:
                    result = reply.get("result")
                    if result is not None:
                        with self.bridge._lock:
                            if self.bridge._init_result is None:
                                self.bridge._init_result = result
            except TimeoutError as exc:
                self._json(504, {"jsonrpc": "2.0", "id": payload.get("id"), "error": {"code": -32000, "message": str(exc)}})
                return
            except Exception as exc:
                # Check if this was an initialize call failing with already initialized (-32600) and we have cache
                if payload.get("method") == "initialize":
                    cached = self.bridge.initialize_reply(payload)
                    if cached is not None:
                        self._reply_mcp(cached, wants_sse)
                        return
                self._json(502, {"jsonrpc": "2.0", "id": payload.get("id"), "error": {"code": -32000, "message": f"upstream error: {exc}"}})
                return
            self._reply_mcp(reply, wants_sse)
            return

        self._json(404, {"error": "not found"})

    def do_DELETE(self) -> None:  # noqa: N802
        if not self._check_security():
            return
        if urlparse(self.path).path == "/mcp":
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._json(404, {"error": "not found"})

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[bridge] %s - %s\n" % (self.address_string(), fmt % args))


def main() -> int:
    ap = argparse.ArgumentParser(description="stdio -> HTTP/SSE bridge for logic-pro-mcp")
    ap.add_argument("--bin", default=DEFAULT_BIN, help="LogicProMCP binary (stdio server)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--log", default=None, help="capture the child's stderr here (default: inherit)")
    ap.add_argument("--upstream-arg", action="append", default=[], help="extra arg for the child")
    args = ap.parse_args()

    if not os.access(args.bin, os.X_OK):
        sys.stderr.write(f"not executable: {args.bin}\n")
        return 2

    upstream = Upstream([args.bin, *args.upstream_arg], args.log)
    bridge = Bridge(upstream)
    Handler.bridge = bridge
    bridge.prime()
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.daemon_threads = True
    sys.stderr.write(
        f"[bridge] listening on http://{args.host}:{args.port}\n"
        f"[bridge]   Streamable HTTP: POST/GET/DELETE /mcp\n"
        f"[bridge]   legacy SSE     : GET /sse  ->  POST /message?sessionId=...\n"
        f"[bridge]   health         : GET /health\n"
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        upstream.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
