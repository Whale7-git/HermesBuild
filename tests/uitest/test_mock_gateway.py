"""Self-contained HTTP contract and failure-injection tests for mock_gateway.py."""
import json
import threading
import unittest
import urllib.error
import urllib.request
from mock_gateway import build_server, PNG


class GatewayContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = build_server(0)
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"
        cls.worker = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.worker.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.worker.join(timeout=3)

    def setUp(self):
        self.request("POST", "/__control/reset", {})

    def request(self, method, path, payload=None, headers=None):
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            self.base + path, method=method, data=body,
            headers={"Content-Type": "application/json", **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=5) as response:
                return response.status, response.read(), response.headers
        except urllib.error.HTTPError as error:
            return error.code, error.read(), error.headers

    def decoded(self, method, path, payload=None, headers=None):
        status, body, _ = self.request(method, path, payload, headers)
        return status, json.loads(body)

    def test_sessions_history_and_pagination_are_client_compatible(self):
        code, result = self.decoded("GET", "/api/sessions?limit=200&offset=0",
                                    headers={"Authorization": "Bearer disposable-fixture"})
        self.assertEqual(code, 200)
        self.assertGreater(len(result["data"]), 0)
        self.assertEqual(result["data"][0]["id"], "ui-session-1")
        status, old = self.decoded(
            "GET", "/api/sessions/ui-session-1/messages?order=oldest&offset=0&limit=2")
        self.assertEqual(status, 200)
        self.assertEqual(old["session_id"], "ui-session-1")
        self.assertEqual(len(old["data"]), 2)
        self.assertEqual(old["data"][0]["role"], "user")
        self.assertGreater(len(old["data"][1]["content"].encode("utf-16-le")) // 2, 1000)
        status, last = self.decoded(
            "GET", "/api/sessions/ui-session-1/messages?order=oldest&offset=1&limit=1")
        self.assertEqual(status, 200)
        self.assertEqual(last["data"][0]["id"], old["data"][1]["id"])

    def test_session_detail_is_nested_for_history_reader(self):
        status, result = self.decoded("GET", "/api/sessions/ui-session-1")
        self.assertEqual(status, 200)
        self.assertEqual(result["session"]["id"], "ui-session-1")
        self.assertEqual(result["session"]["message_count"], 2)
        self.assertNotIn("message_count", result)
        code, _ = self.decoded("GET", "/api/sessions/unknown")
        self.assertEqual(code, 404)

    def test_start_stream_terminal_and_no_duplicate_post(self):
        status, started = self.decoded("POST", "/v1/runs", {
            "session_id": "ui-session-1", "input": "fixture text",
        })
        self.assertEqual(status, 200)
        run_id = started["run_id"]
        status, stream, headers = self.request("GET", f"/v1/runs/{run_id}/events")
        self.assertEqual(status, 200)
        self.assertIn("text/event-stream", headers["Content-Type"])
        self.assertIn(b'"event": "message.delta"', stream)
        self.assertIn(b'"event": "run.completed"', stream)
        status, finished = self.decoded("GET", f"/v1/runs/{run_id}")
        self.assertEqual(finished["status"], "completed")
        status, history = self.decoded("GET", "/api/sessions/ui-session-1/messages?order=oldest&offset=0&limit=20")
        self.assertEqual(history["data"][-1]["role"], "assistant")
        status, logs = self.decoded("GET", "/__control/log")
        self.assertEqual(sum(r["method"] == "POST" and r["path"] == "/v1/runs"
                             for r in logs["requests"]), 1)
        self.assertEqual(logs["unknown"], [])

    def test_terminal_frame_precedes_persisted_history(self):
        code, config = self.decoded("POST", "/__control/finalization-lag",
                                    {"delay_ms": 700})
        self.assertEqual((code, config["delay_ms"]), (200, 700))
        code, started = self.decoded("POST", "/v1/runs", {
            "session_id": "ui-session-1", "input": "delayed final history"})
        self.assertEqual(code, 200)
        finished = threading.Event()
        def consume():
            self.request("GET", f'/v1/runs/{started["run_id"]}/events')
            finished.set()
        worker = threading.Thread(target=consume, daemon=True)
        worker.start()
        # The server emits the terminal SSE before finish_run persists the
        # assistant row. GET can therefore return only the new user message.
        import time
        time.sleep(0.2)
        code, early = self.decoded("GET",
            "/api/sessions/ui-session-1/messages?order=oldest&offset=0&limit=20")
        self.assertEqual(code, 200)
        self.assertEqual(len(early["data"]), 3)
        self.assertEqual(early["data"][-1]["role"], "user")
        self.assertFalse(finished.is_set())
        worker.join(timeout=6)
        self.assertTrue(finished.is_set())
        code, later = self.decoded("GET",
            "/api/sessions/ui-session-1/messages?order=oldest&offset=0&limit=20")
        self.assertEqual(code, 200)
        self.assertEqual(later["data"][-1]["role"], "assistant")

    def test_force_429_then_normal_response(self):
        code, _ = self.decoded("POST", "/__control/stub", {
            "method": "GET", "path": "/api/sessions",
            "status": 429, "body": {"error": {"message": "UI probe rate limited"}},
        })
        self.assertEqual(code, 200)
        code, result = self.decoded("GET", "/api/sessions")
        self.assertEqual(code, 429)
        self.assertEqual(result["error"]["message"], "UI probe rate limited")
        code, _ = self.decoded("GET", "/api/sessions")
        self.assertEqual(code, 200)

    def test_all_unknown_routes_fail_loudly(self):
        status, result = self.decoded("GET", "/not-a-real-client-endpoint")
        self.assertEqual(status, 501)
        self.assertIn("MOCK_UNKNOWN_ROUTE", result["error"]["message"])
        _, logs = self.decoded("GET", "/__control/log")
        self.assertEqual(logs["unknown"], [{
            "method": "GET", "path": "/not-a-real-client-endpoint",
        }])

    def test_upload_and_binary_png_do_not_log_credentials(self):
        boundary = "UITestBoundary"
        raw = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
               "filename=\"ui-image.png\"\r\nContent-Type: image/png\r\n\r\n").encode(
                   "utf-8") + PNG + f"\r\n--{boundary}--\r\n".encode("utf-8")
        req = urllib.request.Request(
            self.base + "/v1/files", data=raw, method="POST", headers={
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Authorization": "Bearer disposable-fixture",
            })
        with urllib.request.urlopen(req, timeout=5) as response:
            self.assertEqual(json.loads(response.read())["mime"], "image/png")
        status, data, hdr = self.request("GET", "/v1/files/by-path?path=%2Fui-test%2Fui-image.png")
        self.assertEqual(status, 200)
        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertEqual(hdr["Content-Type"], "image/png")
        _, logs = self.decoded("GET", "/__control/log")
        upload = next(r for r in logs["requests"] if r["path"] == "/v1/files")
        self.assertTrue(upload["authorization_present"])
        self.assertEqual(upload["authorization_scheme"], "Bearer")
        self.assertNotIn("disposable-fixture", json.dumps(logs))

    def test_scripted_disconnect(self):
        self.decoded("POST", "/__control/stub", {
            "method": "GET", "path": "/api/sessions", "disconnect": True})
        with self.assertRaises((urllib.error.URLError, ConnectionError,
                                OSError, RuntimeError)):
            self.request("GET", "/api/sessions")
        status, _ = self.decoded("GET", "/api/sessions")
        self.assertEqual(status, 200)

    def test_control_rejects_self_stub(self):
        status, _ = self.decoded("POST", "/__control/stub", {
            "path": "/__control/log", "status": 200})
        self.assertEqual(status, 400)


if __name__ == "__main__":
    unittest.main()
