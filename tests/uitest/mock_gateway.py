#!/usr/bin/env python3
"""Deterministic loopback-only Hermes Gateway, never a production network proxy.

Routes are grounded in GatewayRequests.swift and GatewayBackend.swift.
All test-control endpoints are loopback-only; request logging redacts secrets.
"""
from __future__ import annotations

import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import threading
import time
import zlib
import struct
from urllib.parse import parse_qs, urlsplit

HERE = Path(__file__).resolve().parent
PNG = base64.b64decode(
    # Valid 32x24 RGBA PNG, CRC-verified. The previous 1x1 fixture carried
    # an invalid IDAT CRC and failed iOS ImageIO despite the correct 200/MIME.
    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAYAAACbU/80"
    "AAAAL0lEQVR4nO3OQQEAMAjEsGPq5nHW8DJk8EkNNHVf/yx2NucAAAAAAAAAAAAAAEkyUhgC7m/qr4UAAAAASUVORK5CYII="
)
def validate_fixture_png(data: bytes):
    """Fail at mock startup, not 10 minutes into simulator image gestures."""
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("mock PNG signature invalid")
    offset = 8
    seen_idat = False
    seen_iend = False
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        end = offset + 12 + length
        if end > len(data):
            raise ValueError("mock PNG chunk truncated")
        payload = data[offset + 4:offset + 8 + length]
        expected = struct.unpack(">I", data[offset + 8 + length:end])[0]
        if zlib.crc32(payload) != expected:
            raise ValueError("mock PNG chunk CRC invalid")
        seen_idat |= payload[:4] == b"IDAT"
        seen_iend |= payload[:4] == b"IEND"
        offset = end
        if seen_iend:
            break
    if not (seen_idat and seen_iend and offset == len(data)):
        raise ValueError("mock PNG missing essential chunks")


validate_fixture_png(PNG)

SESSION_RE = re.compile(r"^/api/sessions/([A-Za-z0-9_-]+)$")
MESSAGES_RE = re.compile(r"^/api/sessions/([A-Za-z0-9_-]+)/messages$")
RUN_RE = re.compile(r"^/v1/runs/([A-Za-z0-9_-]+)$")
EVENTS_RE = re.compile(r"^/v1/runs/([A-Za-z0-9_-]+)/events$")
RUN_ACTION_RE = re.compile(r"^/v1/runs/([A-Za-z0-9_-]+)/(stop|steer|approval|clarify)$")
SESSION_ACTION_RE = re.compile(r"^/api/sessions/([A-Za-z0-9_-]+)/(model|fork)$")


def fixture(name: str):
    return json.loads((HERE / "fixtures" / name).read_text(encoding="utf-8"))


class GatewayState:
    def __init__(self):
        self.lock = threading.RLock()
        self.reset()

    def reset(self):
        with self.lock:
            self.sessions = fixture("sessions.json")["data"]
            self.history = fixture("history.json")["sessions"]
            self.events = fixture("stream.json")["events"]
            self.run_count = 0
            self.message_count = 1000
            self.runs = {}
            self.stubs = {}
            self.requests = []
            self.unknown = []
            self.finalization_lag_ms = 0
            self.stream_interval_ms = 30

    def remember(self, method, path, query, headers):
        # Never include credential values or user message contents in logs.
        authorization = headers.get("Authorization", "")
        entry = {
            "method": method, "path": path, "query": query,
            "authorization_present": bool(authorization),
            "authorization_scheme": authorization.split(" ", 1)[0] if authorization else None,
            "cookie_present": bool(headers.get("Cookie")),
            "content_type": headers.get("Content-Type", "").split(";", 1)[0],
        }
        with self.lock:
            self.requests.append(entry)

    def stub(self, method, path, behavior):
        with self.lock:
            self.stubs.setdefault((method, path), []).append(behavior)

    def take_stub(self, method, path):
        with self.lock:
            queue = self.stubs.get((method, path), [])
            if not queue:
                return None
            return queue.pop(0)

    def rows(self, session_id):
        return self.history.setdefault(session_id, [])

    def start_run(self, session_id, text):
        with self.lock:
            self.run_count += 1
            self.message_count += 1
            run_id = f"ui-run-{self.run_count}"
            self.rows(session_id).append({
                "id": self.message_count, "role": "user",
                "session_id": session_id, "content": text, "timestamp": 1795150001,
            })
            self.runs[run_id] = {
                "run_id": run_id, "session_id": session_id, "status": "running",
                "settled": False,
            }
            return run_id

    def finish_run(self, run_id, status="completed"):
        with self.lock:
            record = self.runs.get(run_id)
            if not record:
                return
            record["status"] = status
            if status != "completed" or record["settled"]:
                return
            record["settled"] = True
            self.message_count += 1
            text = "".join(e.get("delta", "") for e in self.events
                           if e.get("event") == "message.delta")
            self.rows(record["session_id"]).append({
                "id": self.message_count, "role": "assistant",
                "session_id": record["session_id"], "content": text,
                "timestamp": 1795150002,
            })


class GatewayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server: ThreadingHTTPServer

    def log_message(self, *_):
        # Caller uses /__control/log instead of noisy HTTP server logs.
        pass

    @property
    def state(self) -> GatewayState:
        return self.server.mock_state

    def json_response(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def body_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 2_000_000:
            raise ValueError("request exceeds 2MB test fixture limit")
        data = self.rfile.read(length) if length else b"{}"
        return json.loads(data)

    def handle_request(self, method):
        parsed = urlsplit(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)
        if path.startswith("/__control/"):
            return self.control(method, path)
        self.state.remember(method, path, query, self.headers)
        scripted = self.state.take_stub(method, path)
        if scripted is not None:
            delay = min(30_000, max(0, int(scripted.get("delay_ms", 0))))
            if delay:
                time.sleep(delay / 1000.0)
            if scripted.get("disconnect"):
                self.close_connection = True
                self.connection.shutdown(2)
                return
            return self.json_response(int(scripted.get("status", 500)), scripted.get(
                "body", {"error": {"message": "UI fixture forced error"}}))

        if method == "GET" and path == "/api/sessions":
            offset = max(0, int(query.get("offset", ["0"])[0]))
            limit = min(200, max(1, int(query.get("limit", ["100"])[0])))
            with self.state.lock:
                rows = [dict(row, message_count=len(self.state.history.get(row["id"], [])))
                        for row in self.state.sessions]
            return self.json_response(200, {
                "data": rows[offset:offset + limit],
                "has_more": offset + limit < len(rows),
            })

        if method == "POST" and path == "/api/sessions":
            payload = self.body_json()
            with self.state.lock:
                name = f"ui-session-{len(self.state.sessions) + 1}"
                row = {
                    "id": name, "title": payload.get("title", "UI New Chat"),
                    "started_at": 1795150000, "last_active": 1795150001,
                    "message_count": 0, "model": "hermes-ui-test",
                }
                self.state.sessions.insert(0, row)
                self.state.history[name] = []
            return self.json_response(200, {"id": name, "session_id": name})

        if method == "GET" and path == "/api/model/options":
            return self.json_response(200, {
                "model": "hermes-ui-test", "provider": "ui-mock",
                "providers": [{"name": "UI Mock", "slug": "ui-mock",
                               "models": ["hermes-ui-test"]}],
            })

        if method == "GET" and path == "/v1/models":
            return self.json_response(200, {"data": [{"id": "hermes-agent"}]})

        message_match = MESSAGES_RE.fullmatch(path)
        if method == "GET" and message_match:
            sid = message_match.group(1)
            with self.state.lock:
                if sid not in self.state.history:
                    return self.json_response(404, {"error": {"message": "unknown session"}})
                rows = list(self.state.rows(sid))
            offset = max(0, int(query.get("offset", ["0"])[0]))
            limit = min(200, max(1, int(query.get("limit", ["60"])[0])))
            order = query.get("order", ["latest"])[0]
            if order == "latest":
                rows.reverse()
            elif order != "oldest":
                return self.json_response(400, {"error": {"message": "unknown sort order"}})
            return self.json_response(200, {
                "session_id": sid, "data": rows[offset:offset + limit],
                "has_more": offset + limit < len(rows),
                "model": "hermes-ui-test",
            })

        session_match = SESSION_RE.fullmatch(path)
        if session_match and method in ("GET", "PATCH", "DELETE"):
            sid = session_match.group(1)
            with self.state.lock:
                row = next((r for r in self.state.sessions if r["id"] == sid), None)
                if row is None:
                    return self.json_response(404, {"error": {"message": "unknown session"}})
                if method == "PATCH":
                    payload = self.body_json()
                    row.update({k: payload[k] for k in ("title", "pinned", "archived")
                                if k in payload})
                if method == "DELETE":
                    self.state.sessions = [r for r in self.state.sessions if r["id"] != sid]
                    self.state.history.pop(sid, None)
                result = dict(row, session_id=sid,
                              message_count=len(self.state.history.get(sid, [])))
            # GatewayHistoryReader expects a nested session metadata object.
            return self.json_response(200, {"session": result} if method == "GET" else result)

        session_action = SESSION_ACTION_RE.fullmatch(path)
        if method == "POST" and session_action:
            sid, action = session_action.groups()
            if action == "model":
                self.body_json()
                return self.json_response(200, {"session_id": sid, "model": "hermes-ui-test"})
            if action == "fork":
                return self.json_response(200, {"id": sid, "session_id": sid})

        if method == "POST" and path == "/v1/runs":
            payload = self.body_json()
            sid, text = payload.get("session_id"), payload.get("input")
            if not isinstance(text, str) or sid not in self.state.history:
                return self.json_response(400, {"error": {"message": "invalid run input"}})
            run = self.state.start_run(sid, text)
            return self.json_response(200, {"run_id": run, "session_id": sid, "status": "running"})

        run_match = RUN_RE.fullmatch(path)
        if method == "GET" and run_match:
            with self.state.lock:
                run = self.state.runs.get(run_match.group(1))
                return self.json_response(200, dict(run)) if run else self.json_response(
                    404, {"error": {"message": "unknown run"}})

        events_match = EVENTS_RE.fullmatch(path)
        if method == "GET" and events_match:
            run_id = events_match.group(1)
            with self.state.lock:
                if run_id not in self.state.runs:
                    return self.json_response(404, {"error": {"message": "unknown run"}})
                frames = [dict(x) for x in self.state.events]
            last = query.get("last_seq", [self.headers.get("Last-Event-ID", "")])[0]
            if last.isdigit():
                frames = [x for x in frames if int(x["id"]) > int(last)]
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                for event in frames:
                    seq = event.pop("id")
                    payload = json.dumps(event, ensure_ascii=False)
                    self.wfile.write(f"id: {seq}\ndata: {payload}\n\n".encode("utf-8"))
                    self.wfile.flush()
                    with self.state.lock:
                        interval_ms = self.state.stream_interval_ms
                    time.sleep(interval_ms / 1000.0)
                with self.state.lock:
                    lag_ms = self.state.finalization_lag_ms
                if lag_ms:
                    time.sleep(lag_ms / 1000.0)
                self.state.finish_run(run_id)
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True
            return

        run_action = RUN_ACTION_RE.fullmatch(path)
        if method == "POST" and run_action:
            run_id, action = run_action.groups()
            if run_id not in self.state.runs:
                return self.json_response(404, {"error": {"message": "unknown run"}})
            if action == "stop":
                self.state.finish_run(run_id, "cancelled")
            if action != "stop":
                self.body_json()
            return self.json_response(200, {"run_id": run_id,
                                            "status": self.state.runs[run_id]["status"]})

        if method == "POST" and path == "/v1/files":
            count = int(self.headers.get("Content-Length", "0"))
            if count > 20_000_000:
                return self.json_response(413, {"error": {"message": "fixture upload too large"}})
            self.rfile.read(count)
            if "multipart/form-data" not in self.headers.get("Content-Type", ""):
                return self.json_response(415, {"error": {"message": "multipart required"}})
            return self.json_response(200, {
                "filename": "ui-image.png", "path": "/ui-test/ui-image.png",
                "bytes": len(PNG), "mime": "image/png", "is_image": True,
            })

        if method == "GET" and path == "/v1/files/by-path":
            # The image UI regression must prove it includes a Gateway Bearer,
            # not accidentally pass because the fixture accepts anonymous GET.
            if not self.headers.get("Authorization", "").startswith("Bearer "):
                return self.json_response(401, {"error": {"message": "missing bearer"}})
            requested = query.get("path", [""])[0]
            if requested != "/ui-test/ui-image.png":
                return self.json_response(404, {"error": {"message": "fixture image unavailable"}})
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(PNG)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(PNG)
            self.close_connection = True
            return

        with self.state.lock:
            self.state.unknown.append({"method": method, "path": path})
        return self.json_response(501, {
            "error": {"message": f"MOCK_UNKNOWN_ROUTE: {method} {path}"},
        })

    def control(self, method, path):
        if method == "GET" and path == "/__control/log":
            with self.state.lock:
                return self.json_response(200, {
                    "requests": list(self.state.requests),
                    "unknown": list(self.state.unknown),
                })
        if method == "POST" and path == "/__control/reset":
            self.state.reset()
            return self.json_response(200, {"reset": True})
        if method == "POST" and path == "/__control/finalization-lag":
            payload = self.body_json()
            delay = payload.get("delay_ms")
            if type(delay) is not int or not 0 <= delay <= 5000:
                return self.json_response(400, {"error": {"message": "invalid delay_ms"}})
            with self.state.lock:
                self.state.finalization_lag_ms = delay
            return self.json_response(200, {"delay_ms": delay})
        if method == "POST" and path == "/__control/stream-interval":
            payload = self.body_json()
            interval = payload.get("delay_ms")
            if type(interval) is not int or not 0 <= interval <= 2500:
                return self.json_response(400, {"error": {"message": "invalid stream interval"}})
            with self.state.lock:
                self.state.stream_interval_ms = interval
            return self.json_response(200, {"delay_ms": interval})
        if method == "POST" and path == "/__control/add-selection-text":
            # Place a short real assistant Markdown paragraph at the end of
            # history, so the native selection surface is actually visible.
            with self.state.lock:
                self.state.message_count += 1
                self.state.rows("ui-session-1").append({
                    "id": self.state.message_count,
                    "session_id": "ui-session-1",
                    "role": "assistant",
                    "content": "UI 手势冲突测试文本。长按选中这段文字并向右拖动选区时，侧栏应保持关闭。",
                    "timestamp": 1795150003,
                })
            return self.json_response(200, {"selection_text_added": True})
        if method == "POST" and path == "/__control/add-image":
            # Dedicated UI fixture: inject one authenticated uploaded-image
            # reference into existing history, never user files or credentials.
            with self.state.lock:
                self.state.message_count += 1
                self.state.rows("ui-session-1").append({
                    "id": self.state.message_count,
                    "session_id": "ui-session-1",
                    "role": "user",
                    "content": "UI 验收图片",
                    "timestamp": 1795150003,
                    "attachments": [{
                        "name": "ui-image.png",
                        "path": "/ui-test/ui-image.png",
                        "mime": "image/png",
                        "size": len(PNG),
                        "is_image": True,
                    }],
                })
            return self.json_response(200, {"image_added": True})
        if method == "POST" and path == "/__control/stub":
            payload = self.body_json()
            target_method = str(payload.get("method", "GET")).upper()
            target_path = urlsplit(str(payload.get("path", ""))).path
            if not target_path.startswith("/") or target_path.startswith("/__control/"):
                return self.json_response(400, {"error": {"message": "invalid stub path"}})
            behavior = {k: payload[k] for k in ("status", "body", "delay_ms", "disconnect")
                        if k in payload}
            if not behavior:
                return self.json_response(400, {"error": {"message": "missing stub behavior"}})
            self.state.stub(target_method, target_path, behavior)
            return self.json_response(200, {"stubbed": target_path, "method": target_method})
        return self.json_response(501, {"error": {"message": "MOCK_UNKNOWN_CONTROL_ROUTE"}})

    def do_GET(self):
        self.handle_request("GET")

    def do_POST(self):
        self.handle_request("POST")

    def do_PATCH(self):
        self.handle_request("PATCH")

    def do_DELETE(self):
        self.handle_request("DELETE")


def build_server(port=0):
    server = ThreadingHTTPServer(("127.0.0.1", port), GatewayHandler)
    server.daemon_threads = True
    server.mock_state = GatewayState()
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--port-file", type=Path)
    args = parser.parse_args()
    server = build_server(args.port)
    url = f"http://127.0.0.1:{server.server_port}"
    if args.port_file:
        args.port_file.write_text(str(server.server_port), encoding="utf-8")
    print(f"MOCK_GATEWAY_URL={url}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
