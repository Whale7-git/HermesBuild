"""Run-degradation scenarios for mock_gateway.py.

Two deployed-Gateway facts drive these fixtures and must not be "fixed":

* the terminal set is {completed, failed, cancelled, interrupted};
* the stream retention (300s) is shorter than the status retention (3600s),
  so a real client can read ``status 200`` while ``/events`` is already 404.

Covered here: TTL skew (status 200 + events 404), permanent status loss
(status 404), terminal ``output`` on the status body, the
``resolve-unknown`` authority projection, and the status read latency switch.
"""
import json
import threading
import time
import unittest
import urllib.error
import urllib.request
from mock_gateway import TERMINAL_STATUSES, build_server


class ScenarioTestCase(unittest.TestCase):
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
            with urllib.request.urlopen(req, timeout=10) as response:
                return response.status, response.read(), response.headers
        except urllib.error.HTTPError as error:
            return error.code, error.read(), error.headers

    def decoded(self, method, path, payload=None, headers=None):
        status, body, _ = self.request(method, path, payload, headers)
        return status, json.loads(body)

    def scenario(self, **payload):
        status, applied = self.decoded("POST", "/__control/scenario", payload)
        self.assertEqual(status, 200, applied)
        return applied

    def start_run(self, text="scenario run"):
        status, started = self.decoded("POST", "/v1/runs", {
            "session_id": "ui-session-1", "input": text})
        self.assertEqual(status, 200, started)
        return started["run_id"]

    def drain_stream(self, run_id):
        status, _, headers = self.request("GET", f"/v1/runs/{run_id}/events")
        self.assertEqual(status, 200)
        self.assertIn("text/event-stream", headers["Content-Type"])

    def completed_run(self, text="scenario completed run"):
        run_id = self.start_run(text)
        self.drain_stream(run_id)
        return run_id

    # ---- TTL skew: status survives while the stream is already gone ----

    def test_status_200_and_events_404_coexist(self):
        run_id = self.completed_run()
        self.scenario(events_404=True, status_404=False)

        status, body = self.decoded("GET", f"/v1/runs/{run_id}")
        self.assertEqual(status, 200, body)
        self.assertEqual(body["status"], "completed")
        self.assertIn("output", body)

        events_status, events_body = self.decoded("GET", f"/v1/runs/{run_id}/events")
        self.assertEqual(events_status, 404)
        self.assertIn("error", events_body)

        # Reading them in the opposite order must produce the same split: the
        # two switches are independent, not a single "everything expired" flag.
        status, body = self.decoded("GET", f"/v1/runs/{run_id}")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "completed")
        events_status, _ = self.decoded("GET", f"/v1/runs/{run_id}/events")
        self.assertEqual(events_status, 404)

        _, log = self.decoded("GET", "/__control/log")
        self.assertEqual(log["scenario"]["events_404"], True)
        self.assertEqual(log["scenario"]["status_404"], False)

    def test_live_run_can_lose_only_its_stream(self):
        # A Run that never finished streaming is the other half of the window:
        # status still says "running" while the stream URL is gone for good.
        run_id = self.start_run("never consumed stream")
        self.scenario(events_404=True)
        status, body = self.decoded("GET", f"/v1/runs/{run_id}")
        self.assertEqual((status, body["status"]), (200, "running"))
        self.assertIsNone(body["output"])
        self.assertEqual(self.decoded("GET", f"/v1/runs/{run_id}/events")[0], 404)

    # ---- permanent status loss ----

    def test_status_ttl_expiry_is_404_and_does_not_fall_back(self):
        run_id = self.completed_run()
        self.scenario(status_404=True)
        for _ in range(2):
            status, body = self.decoded("GET", f"/v1/runs/{run_id}")
            self.assertEqual(status, 404, body)
            self.assertEqual(body["error"]["message"], "unknown run")
        # The stream switch is separate: expiring status does not fabricate a
        # stream 404 for a Run whose events are still retained.
        self.assertEqual(self.request("GET", f"/v1/runs/{run_id}/events")[0], 200)
        # Both retention windows lapsed: every Run read is gone.
        self.scenario(events_404=True)
        self.assertEqual(self.decoded("GET", f"/v1/runs/{run_id}")[0], 404)
        self.assertEqual(self.decoded("GET", f"/v1/runs/{run_id}/events")[0], 404)
        # History is never erased by a status TTL: the conversation still has
        # the user message and the settled assistant reply.
        status, history = self.decoded(
            "GET", "/api/sessions/ui-session-1/messages?order=oldest&offset=0&limit=20")
        self.assertEqual(status, 200)
        self.assertEqual(history["data"][-1]["role"], "assistant")

    # ---- terminal status carries the final reply ----

    def test_completed_status_carries_final_output(self):
        run_id = self.completed_run("output probe")
        status, body = self.decoded("GET", f"/v1/runs/{run_id}")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "completed")
        self.assertIn("output", body)
        self.assertIsInstance(body["output"], str)
        self.assertTrue(body["output"].strip())
        _, history = self.decoded(
            "GET", "/api/sessions/ui-session-1/messages?order=oldest&offset=0&limit=20")
        self.assertEqual(body["output"], history["data"][-1]["content"])
        # Identity fields the client validates before trusting the projection.
        self.assertEqual(body["run_id"], run_id)
        self.assertEqual(body["id"], run_id)
        self.assertEqual(body["session_id"], "ui-session-1")

    def test_non_terminal_output_is_null_and_overridable(self):
        run_id = self.start_run("no terminal yet")
        status, body = self.decoded("GET", f"/v1/runs/{run_id}")
        self.assertEqual(status, 200)
        self.assertIn("output", body)
        self.assertIsNone(body["output"])
        self.scenario(status="waiting_for_approval")
        status, body = self.decoded("GET", f"/v1/runs/{run_id}")
        self.assertEqual((status, body["status"]), (200, "waiting_for_approval"))
        self.assertIsNone(body["output"])
        # A settled Run replayed through a non-terminal override must drop the
        # output, otherwise a client could settle on a stale final reply.
        self.drain_stream(run_id)
        status, body = self.decoded("GET", f"/v1/runs/{run_id}")
        self.assertIsNone(body["output"])

    # ---- resolve-unknown ----

    def test_resolve_unknown_returns_authoritative_projection(self):
        run_id = self.start_run("lost execution")
        status, body = self.decoded(
            "POST", f"/v1/runs/{run_id}/resolve-unknown", {})
        self.assertEqual(status, 200, body)
        self.assertIn(body["status"], TERMINAL_STATUSES)
        self.assertEqual(body["status"], "completed")
        self.assertIsInstance(body["admission_id"], str)
        self.assertTrue(body["admission_id"])
        self.assertIs(type(body["execution_generation"]), int)
        self.assertEqual(body["execution_generation"], 1)
        self.assertIsInstance(body["output"], str)
        self.assertTrue(body["output"].strip())
        self.assertEqual((body["run_id"], body["id"], body["session_id"]),
                         (run_id, run_id, "ui-session-1"))

        # The authority answer becomes the canonical status read.
        status, canonical = self.decoded("GET", f"/v1/runs/{run_id}")
        self.assertEqual(status, 200)
        self.assertEqual(canonical["status"], "completed")
        self.assertEqual(canonical["output"], body["output"])
        self.assertEqual(canonical["admission_id"], body["admission_id"])
        self.assertEqual(canonical["execution_generation"], 1)

        # A second resolution is a new execution generation, not a new Run.
        status, again = self.decoded(
            "POST", f"/v1/runs/{run_id}/resolve-unknown", {})
        self.assertEqual((status, again["execution_generation"]), (200, 2))
        self.assertEqual(again["admission_id"], body["admission_id"])
        _, log = self.decoded("GET", "/__control/log")
        self.assertEqual([x["execution_generation"] for x in log["resolved_runs"]],
                         [1, 2])
        self.assertEqual(len(log["accepted_runs"]), 1)

    def test_resolve_unknown_honours_injected_terminal_state(self):
        self.scenario(status="failed", output="执行失败：工具超时")
        run_id = self.start_run("injected failure")
        status, body = self.decoded(
            "POST", f"/v1/runs/{run_id}/resolve-unknown", {})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["status"], "failed")
        self.assertEqual(body["output"], "执行失败：工具超时")
        status, canonical = self.decoded("GET", f"/v1/runs/{run_id}")
        self.assertEqual((status, canonical["status"]), (200, "failed"))
        self.assertEqual(canonical["output"], "执行失败：工具超时")

    def test_resolve_unknown_unknown_run_is_404(self):
        status, body = self.decoded(
            "POST", "/v1/runs/ui-run-missing/resolve-unknown", {})
        self.assertEqual(status, 404)
        self.assertEqual(body["error"]["message"], "unknown run")
        # Not an unimplemented route, and nothing was recorded as resolved.
        _, log = self.decoded("GET", "/__control/log")
        self.assertEqual(log["unknown"], [])
        self.assertEqual(log["resolved_runs"], [])
        self.assertEqual(log["accepted_runs"], [])

    def test_resolve_unknown_survives_status_ttl_loss(self):
        # The whole point of the endpoint: status read is gone, authority is
        # still able to answer with the terminal outcome.
        run_id = self.completed_run("status expired, authority alive")
        self.scenario(status_404=True, events_404=True)
        self.assertEqual(self.decoded("GET", f"/v1/runs/{run_id}")[0], 404)
        status, body = self.decoded(
            "POST", f"/v1/runs/{run_id}/resolve-unknown", {})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["status"], "completed")
        self.assertIsInstance(body["execution_generation"], int)
        self.assertIsInstance(body["admission_id"], str)

    # ---- status read latency ----

    def test_status_latency_is_really_delayed(self):
        run_id = self.start_run("latency probe")
        self.scenario(status_latency_ms=350)
        started = time.monotonic()
        status, body = self.decoded("GET", f"/v1/runs/{run_id}")
        elapsed = time.monotonic() - started
        self.assertEqual(status, 200, body)
        self.assertGreaterEqual(elapsed, 0.30, elapsed)
        self.assertLess(elapsed, 5.0, elapsed)
        # Latency is per read, not a one-shot delay.
        started = time.monotonic()
        self.assertEqual(self.decoded("GET", f"/v1/runs/{run_id}")[0], 200)
        self.assertGreaterEqual(time.monotonic() - started, 0.30)
        # Other routes stay fast: only the Run status read was slowed.
        self.scenario(status_latency_ms=0)
        started = time.monotonic()
        self.assertEqual(self.decoded("GET", f"/v1/runs/{run_id}")[0], 200)
        self.assertLess(time.monotonic() - started, 0.25)

    def test_latency_applies_to_the_expired_read_too(self):
        run_id = self.start_run("slow 404")
        self.scenario(status_404=True, status_latency_ms=250)
        started = time.monotonic()
        self.assertEqual(self.decoded("GET", f"/v1/runs/{run_id}")[0], 404)
        self.assertGreaterEqual(time.monotonic() - started, 0.20)

    # ---- scenario switch hygiene ----

    def test_scenario_rejects_bad_input_and_resets_cleanly(self):
        for payload in (
            {"unknown_key": True},
            {"status_404": "true"},
            {"events_404": 1},
            {"status_latency_ms": -1},
            {"status_latency_ms": 10_001},
            {"status_latency_ms": "300"},
            {"status": "done"},
            {"output": 5},
        ):
            with self.subTest(payload=payload):
                status, body = self.decoded("POST", "/__control/scenario", payload)
                self.assertEqual(status, 400, body)
        status, applied = self.decoded("GET", "/__control/scenario")
        self.assertEqual(status, 200)
        self.assertEqual(applied, {"status_404": False, "events_404": False,
                                   "status_latency_ms": 0, "status": None,
                                   "output": None})
        self.scenario(status_404=True, events_404=True, status_latency_ms=120,
                      status="running", output="注入文本")
        # A partially injected scenario only changes the keys it names.
        self.scenario(events_404=False)
        _, applied = self.decoded("GET", "/__control/scenario")
        self.assertEqual(applied, {"status_404": True, "events_404": False,
                                   "status_latency_ms": 120, "status": "running",
                                   "output": "注入文本"})
        self.scenario(status_404=False)
        run_id = self.start_run("injected running")
        status, body = self.decoded("GET", f"/v1/runs/{run_id}")
        self.assertEqual((status, body["status"], body["output"]),
                         (200, "running", "注入文本"))
        # reset clears every switch back to the healthy default.
        self.decoded("POST", "/__control/reset", {})
        _, applied = self.decoded("GET", "/__control/scenario")
        self.assertEqual(applied, {"status_404": False, "events_404": False,
                                   "status_latency_ms": 0, "status": None,
                                   "output": None})
        run_id = self.start_run("after reset")
        status, body = self.decoded("GET", f"/v1/runs/{run_id}")
        self.assertEqual((status, body["status"], body["output"]), (200, "running", None))


if __name__ == "__main__":
    unittest.main()
