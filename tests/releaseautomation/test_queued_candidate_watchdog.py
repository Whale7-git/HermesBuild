"""Tests for queued-macOS cancellation/retry. No live API calls."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "watchdog", ROOT / "scripts/queued_candidate_watchdog.py")
watchdog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(watchdog)
SHA = "a" * 40
STAMP = "2026-11-18T00:00:00Z"
NOW = watchdog.timestamp(STAMP) + 200


def example(status="queued", attempt=1, pr_state="open", sha=SHA,
            source="success", offline="success", event="pull_request"):
    run = {
        "id": 77, "event": event, "run_attempt": attempt,
        "path": watchdog.WORKFLOW, "head_sha": SHA, "created_at": STAMP,
        "status": "in_progress",
        "repository": {"full_name": watchdog.REPO},
        "pull_requests": [{"number": 4}],
    }
    jobs = [
        {"name": watchdog.CANDIDATE, "status": status, "created_at": STAMP,
         "started_at": None if status == "queued" else STAMP},
        {"name": "Source and release plan",
         "status": "completed" if source else "in_progress", "conclusion": source},
        {"name": "Swift offline regression",
         "status": "completed" if offline else "in_progress", "conclusion": offline},
    ]
    pr = {
        "state": pr_state,
        "head": {"sha": sha, "repo": {"full_name": watchdog.REPO}},
        "base": {"ref": "main"},
    }
    return run, jobs, pr


class FakeGitHub:
    def __init__(self, run, jobs, pr, finish=True):
        self.run, self.jobs, self.pr = run, jobs, pr
        self.operations, self.finish = [], finish

    def api(self, path, method="GET"):
        if (path, method) == ("actions/runs/77", "GET"):
            return dict(self.run)
        if (path, method) == ("actions/runs/77/jobs?per_page=100", "GET"):
            return {"jobs": self.jobs}
        if (path, method) == ("pulls/4", "GET"):
            return self.pr
        if (path, method) == ("actions/runs/77/cancel", "POST"):
            self.operations.append("cancel")
            if self.finish:
                self.run.update(status="completed", conclusion="cancelled")
            return {}
        if (path, method) == ("actions/runs/77/rerun", "POST"):
            assert self.operations[-1] == "cancel", "rerun must follow cancellation"
            self.run.update(status="in_progress", conclusion=None,
                            run_attempt=self.run["run_attempt"] + 1)
            self.operations.append("rerun")
            return {}
        raise AssertionError((path, method))


def execute(**params):
    run, jobs, pr = example(**params)
    client = FakeGitHub(run, jobs, pr)
    clock = [NOW]
    result = watchdog.monitor(
        client, 77, now=lambda: clock[0],
        sleep=lambda seconds: clock.__setitem__(0, clock[0] + seconds))
    return result, client


class QueueWatchdogTests(unittest.TestCase):
    def test_queued_over_three_minutes_cancels_then_reruns(self):
        result, client = execute()
        self.assertTrue(result.startswith("alert:"))
        self.assertEqual(client.operations, ["cancel", "rerun", "cancel", "rerun"])

    def test_compilation_started_or_finished_does_nothing(self):
        for status in ("in_progress", "completed"):
            with self.subTest(status=status):
                result, client = execute(status=status)
                self.assertTrue(result.startswith("skip:"))
                self.assertFalse(client.operations)

    def test_second_attempt_and_manual_runs_never_retry(self):
        for params in ({"attempt": 2}, {"event": "workflow_dispatch"}):
            with self.subTest(params=params):
                result, client = execute(**params)
                self.assertTrue(result.startswith("skip:"))
                self.assertFalse(client.operations)

    def test_pr_closed_or_head_changed_is_safe(self):
        for params in ({"pr_state": "closed"}, {"sha": "b" * 40}):
            with self.subTest(params=params):
                result, client = execute(**params)
                self.assertIn("PR", result)
                self.assertFalse(client.operations)

    def test_failed_or_running_checks_never_cancel(self):
        for params in ({"source": "failure"}, {"offline": "failure"},
                       {"source": None}, {"offline": None}):
            with self.subTest(params=params):
                result, client = execute(**params)
                self.assertTrue(result.startswith("skip:"))
                self.assertFalse(client.operations)

    def test_threshold_180_seconds(self):
        jobs = example()[1]
        start = watchdog.timestamp(STAMP)
        self.assertFalse(watchdog.candidate_waiting(jobs, start + 179))
        self.assertTrue(watchdog.candidate_waiting(jobs, start + 180))

    def test_no_cancel_when_mac_starts_during_recheck(self):
        run, jobs, pr = example()
        client = FakeGitHub(run, jobs, pr)
        original = client.api
        calls = [0]

        def race(path, method="GET"):
            if path.endswith("/jobs?per_page=100"):
                calls[0] += 1
                if calls[0] == 2:
                    jobs[0].update(status="in_progress", started_at=STAMP)
            return original(path, method)

        client.api = race
        result = watchdog.monitor(client, 77, now=lambda: NOW,
                                  sleep=lambda _: None)
        self.assertIn("macOS started", result)
        self.assertFalse(client.operations)

    def test_rerun_requires_completed_cancelled(self):
        run, jobs, pr = example()
        client = FakeGitHub(run, jobs, pr, finish=False)
        result = watchdog.monitor(client, 77, now=lambda: NOW,
                                  sleep=lambda _: None)
        self.assertIn("did not finish", result)
        self.assertEqual(client.operations, ["cancel"])

    def test_third_window_alerts_exactly_once(self):
        run, jobs, pr = example()
        client = FakeGitHub(run, jobs, pr)
        clock = [NOW]
        signals = []
        result = watchdog.monitor(
            client, 77, now=lambda: clock[0],
            sleep=lambda seconds: clock.__setitem__(0, clock[0] + seconds),
            alert=lambda rid, reason: signals.append((rid, reason)))
        self.assertTrue(result.startswith("alert:"))
        self.assertEqual(len(signals), 1)
        self.assertEqual(signals[0][0], 77)
        self.assertEqual(client.run["run_attempt"], 3)
        self.assertEqual(client.operations, ["cancel", "rerun", "cancel", "rerun"])

    def test_bark_payload_without_exposing_secret(self):
        from unittest.mock import patch
        import json
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *a): return False
            def read(self): return json.dumps({"code": 200}).encode()
        with patch.object(watchdog.request, "urlopen", return_value=Response()) as post:
            self.assertTrue(watchdog.send_bark("https://example.com/secret", 77, "queue"))
        req = post.call_args.args[0]
        self.assertEqual(req.full_url, "https://example.com/secret")
        self.assertIn(b"actions%2Fruns%2F77", req.data)
        self.assertNotIn(b"secret", req.data)

    def test_repeated_attempt_is_not_initial_trigger(self):
        run, jobs, pr = example(attempt=2)
        client = FakeGitHub(run, jobs, pr)
        self.assertTrue(watchdog.monitor(client, 77).startswith("skip:"))
        self.assertFalse(client.operations)

    def test_trusted_trigger_and_token_permissions(self):
        yaml = (ROOT / ".github/workflows/hermes-candidate-queue-watchdog.yml").read_text()
        self.assertIn("types: [requested]", yaml)
        self.assertIn("actions: write", yaml)
        self.assertIn("ref: main", yaml)
        self.assertIn("scripts/queued_candidate_watchdog.py", yaml)
        self.assertIn("secrets.BARK_URL", yaml)
        self.assertIn("timeout-minutes: 21", yaml)
        self.assertNotIn("pull_request_target:", yaml)
        self.assertNotIn("scripts/github-build-ipa-main.sh", yaml)


if __name__ == "__main__":
    unittest.main()
