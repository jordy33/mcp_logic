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
                msg["id"] = original_id  # undo the bridge-N rewrite from send()
                sink.put(msg)
            else:
                for sink in list(self._notify_sinks):
                    sink.put(msg)

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=1000)
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

    def request(self, msg: dict, timeout: float = 300.0) -> dict:
        q: queue.Queue = queue.Queue(maxsize=1)
        internal = self.send(msg, q)
        try:
            reply = q.get(timeout=timeout)
        except queue.Empty:
            with self._lock:
                self._pending.pop(internal, None)  # type: ignore[arg-type]
            raise TimeoutError(f"no reply to {msg.get('method')!r} in {timeout}s")
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

    # ---------- helpers ----------

    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version, Last-Event-ID")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Expose-Headers", "Mcp-Session-Id")

    def _json(self, code: int, payload: dict | None) -> None:
        body = json.dumps(payload).encode() if payload is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _sse_headers(self, close: bool = False) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache, no-transform")
        self.send_header("Connection", "close" if close else "keep-alive")
        if close:
            # A one-shot SSE reply to POST has no Content-Length: EOF is the terminator.
            self.close_connection = True
        self.send_header("X-Accel-Buffering", "no")
        self._cors()
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

    def _pump_session(self, session: SSESession, initial: str | None = None) -> None:
        """Stream responses for one session until the client disconnects."""
        try:
            if initial is not None:
                # Legacy HTTP+SSE (2024-11-05): `data` is the bare endpoint URI,
                # not JSON -- clients do `messageEndpoint = event.data` directly.
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

    # ---------- verbs ----------

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self._cors()
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
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
            # Standalone server-initiated stream: notifications only.
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
            self._cors()
            self.end_headers()
            return

        if parsed.path == "/mcp":
            if payload.get("id") is None:
                # Notification (or response-less message): no reply will ever
                # arrive, so don't block on Upstream.request() -- just forward
                # it and acknowledge per the Streamable HTTP spec.
                self.bridge.upstream.send(payload, None)
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self._cors()
                self.end_headers()
                return
            accept = (self.headers.get("Accept") or "").lower()
            # Prefer a plain JSON reply: every client accepts it and curl can read it.
            # Only stream when the client asks for SSE *and* refuses JSON.
            wants_sse = "text/event-stream" in accept and "application/json" not in accept
            try:
                reply = self.bridge.upstream.request(payload)
            except TimeoutError as exc:
                self._json(504, {"jsonrpc": "2.0", "id": payload.get("id"), "error": {"code": -32000, "message": str(exc)}})
                return
            except Exception as exc:  # upstream died mid-call
                self._json(502, {"jsonrpc": "2.0", "id": payload.get("id"), "error": {"code": -32000, "message": f"upstream error: {exc}"}})
                return
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
            self._cors()
            self.end_headers()
            self.wfile.write(body)
            return

        self._json(404, {"error": "not found"})

    def do_DELETE(self) -> None:  # noqa: N802
        if urlparse(self.path).path == "/mcp":
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self._cors()
            self.end_headers()
            return
        self._json(404, {"error": "not found"})

    def log_message(self, fmt: str, *args) -> None:  # quieter
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
    Handler.bridge = Bridge(upstream)
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
