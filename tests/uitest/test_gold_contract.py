"""Contract checks for precise admission and deterministic Gold4 SSE growth."""
import json
import threading
import time
import unittest

from test_mock_gateway import GatewayContractTests


class SimulatorGoldContractTests(GatewayContractTests):
    # Reuse fixture server only; inherited tests are also valid.
    def test_accepted_post_is_not_just_an_attempt(self):
        code, ledger = self.decoded("GET", "/__control/log")
        self.assertEqual(code, 200)
        self.assertEqual(ledger["accepted_runs"], [])
        status, _ = self.decoded("POST", "/v1/runs", {
            "session_id": "wrong-session", "input": "bad",
        })
        self.assertEqual(status, 400)
        _, ledger = self.decoded("GET", "/__control/log")
        attempts = [r for r in ledger["requests"]
                    if r["method"] == "POST" and r["path"] == "/v1/runs"]
        self.assertEqual(len(attempts), 1)
        self.assertEqual(len(ledger["accepted_runs"]), 0)
        status, result = self.decoded("POST", "/v1/runs", {
            "session_id": "ui-session-1", "input": "good",
        })
        self.assertEqual(status, 200)
        _, ledger = self.decoded("GET", "/__control/log")
        self.assertEqual(ledger["accepted_runs"],
                         [{"run_id": result["run_id"], "session_id": "ui-session-1"}])

    def test_sse_second_delta_waits_for_real_ui_pan_release(self):
        status, _ = self.decoded("POST", "/__control/stream-interval", {"delay_ms": 0})
        self.assertEqual(status, 200)
        status, _ = self.decoded("POST", "/__control/stream-grow", {"lines": 40})
        self.assertEqual(status, 200)
        status, _ = self.decoded("POST", "/__control/stream-pause",
                                 {"after_seq": "2"})
        self.assertEqual(status, 200)
        status, started = self.decoded("POST", "/v1/runs", {
            "session_id": "ui-session-1", "input": "pan",
        })
        self.assertEqual(status, 200)
        done = threading.Event()
        received = []

        def consume():
            code, body, _ = self.request(
                "GET", f'/v1/runs/{started["run_id"]}/events')
            received.append((code, body))
            done.set()

        worker = threading.Thread(target=consume, daemon=True)
        worker.start()
        try:
            for _ in range(100):
                _, ledger = self.decoded("GET", "/__control/log")
                if "2" in ledger["delivered_event_ids"]:
                    break
                time.sleep(0.02)
            self.assertIn("2", ledger["delivered_event_ids"])
            self.assertNotIn("3", ledger["delivered_event_ids"])
            self.assertFalse(done.is_set(), "stream cannot finish before pan")
        finally:
            status, _ = self.decoded("POST", "/__control/stream-resume", {})
            self.assertEqual(status, 200)
        worker.join(timeout=5)
        self.assertTrue(done.is_set())
        self.assertEqual(received[0][0], 200)
        self.assertIn("流式布局增长段 39".encode(), received[0][1])
        _, ledger = self.decoded("GET", "/__control/log")
        self.assertIn("3", ledger["delivered_event_ids"])
        self.assertEqual(len(ledger["accepted_runs"]), 1)


if __name__ == "__main__":
    unittest.main()
