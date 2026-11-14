"""Loopback GET-only fixtures. Never talks to deployed WebUI or uploads files."""
import http.server
import os
import subprocess
import threading
import time
import tempfile
from urllib.parse import parse_qs, urlsplit

# 客户端允许的两条同源路由：file/raw（workspace/会话附件）与 media（agent 产物）。
ALLOWED_PATHS = ("/p/default/api/file/raw", "/p/default/api/media")

class Handler(http.server.BaseHTTPRequestHandler):
    outside_requests = 0
    credential_leaks = 0
    raw_forbidden = 0

    def log_message(self, *_):
        pass

    def do_GET(self):
        parsed = urlsplit(self.path)
        external = parsed.path.startswith("/p/default/external-")
        if parsed.path not in ALLOWED_PATHS and not external:
            Handler.outside_requests += 1
        path = parse_qs(parsed.query).get("path", [""])[0]
        if external:
            path = "/" + parsed.path.rsplit("/", 1)[-1]
            if self.headers.get("Cookie") or self.headers.get("Authorization"):
                Handler.credential_leaks += 1
        media = parsed.path.endswith("/api/media")
        if parsed.path.endswith("/api/file/raw") and path in ("/media-denied", "/media-unauth", "/media-error", "/media-big", "/media-network"):
            Handler.raw_forbidden += 1
        if path == "/media-network":
            self.close_connection = True
            return
        status = 302 if path == "/redirect" else (401 if path == "/unauth" else 200)
        if path == "/media-denied":
            status = 403 if media else 200
        if path == "/media-only-image":
            status = 200 if media else 404
        if path == "/media-unauth":
            status = 401 if media else 200
        if path == "/media-error":
            status = 500 if media else 200
        if path == "/normalized-scope":
            status = 200 if parse_qs(parsed.query).get("session_id", [""])[0] == "scope-current" else 409
        if path.startswith("/fallback-"):
            status = int(path.rsplit("-", 1)[-1]) if media else 200
        if path == "/external-redirect":
            status = 302
        body = b"A" * 8192 if path == "/same-a" else (b"B" * 4096 if path == "/same-b" else bytes([1, 2, 3]))
        if path in ("/slow", "/external-slow"):
            body = b"s" * (1024 * 1024)
        self.send_response(status)
        self.send_header("Content-Type", "text/html" if path in ("/html", "/external-html") else "image/png")
        self.send_header("Connection", "close")
        if path not in ("/stream-big", "/chunked-small", "/external-stream-big", "/external-unknown"):
            large = path in ("/big", "/external-big") or (path == "/media-big" and media)
            self.send_header("Content-Length", str(20 * 1024 * 1024 + 1 if large else len(body)))
        if path in ("/redirect", "/external-redirect"):
            self.send_header("Location", "/outside")
        self.end_headers()
        try:
            if path in ("/stream-big", "/external-stream-big"):
                for _ in range(321):
                    self.wfile.write(b"x" * 65536)
            elif path in ("/slow", "/external-slow"):
                for start in range(0, len(body), 16384):
                    self.wfile.write(body[start:start + 16384])
                    self.wfile.flush()
                    time.sleep(0.02)
            else:
                if path in ("/same-a", "/same-b"):
                    time.sleep(0.05)
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
env = dict(os.environ, ATTACHMENT_FIXTURE_URL=f"http://127.0.0.1:{server.server_port}/p/default/")
binary = os.path.abspath(env.get("ATTACHMENT_TEST_BINARY", "./attachments-tests"))
try:
    with tempfile.TemporaryDirectory(prefix="hermes-attachment-fixture-") as scratch:
        env["TMPDIR"] = scratch
        result = subprocess.run(["stdbuf", "-oL", binary], env=env, cwd=scratch, timeout=60)
finally:
    server.shutdown()
    server.server_close()
assert Handler.outside_requests == 0, "Preview followed redirect outside approved endpoint"
assert Handler.credential_leaks == 0, "External image request leaked ambient credentials"
assert Handler.raw_forbidden == 0, "Auth/size/transport media failure triggered legacy fallback"
print("PASS: loopback observed zero out-of-scope/redirect requests", flush=True)
print("PASS: external images received zero cookies/authorization; protected media errors caused zero raw requests", flush=True)
raise SystemExit(result.returncode)
