"""Offline contract tests for trusted simulator-failure Issue triage."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / "scripts" / "triage_simulator_issues.py"
spec = importlib.util.spec_from_file_location("simulator_triage", MODULE)
triage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(triage)


class SimulatorIssueTriageTests(unittest.TestCase):
    def test_rejects_wrong_run_sha_and_untrusted_test_names(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root) / "hermes-ui-triage-123-chat"
            folder.mkdir()
            (folder / "simulator-report.json").write_text(json.dumps({
                "schema": 1, "run_id": "123", "sha": "a" * 40,
                "shard": "chat", "outcome": "failure",
                "failed_tests": ["GoldTests.testManualReading", "../malicious", "Foo.testBar"],
                "assertions": ["error: XCTAssertTrue failed"],
            }))
            reports = triage.load_reports(Path(root), "123", "a" * 40)
            self.assertEqual(len(reports), 1)
            self.assertEqual(reports[0]["failed_tests"],
                             ["GoldTests.testManualReading", "Foo.testBar"])
            self.assertFalse(triage.load_reports(Path(root), "124", "a" * 40))
            self.assertFalse(triage.load_reports(Path(root), "123", "b" * 40))

    def test_blocked_downstream_does_not_create_product_issue(self):
        report = {
            "source_sha": "a" * 40, "harness_sha": "b" * 40,
            "cases": [
                {"test": "HermesBootstrapUITests.testGatewaySetupPersistsAcrossRelaunch",
                 "status": "FAIL", "failure_stage": "setup.return_settings_root",
                 "diagnostics": ["SETUP_BLOCKED stage=setup.return_settings_root"]},
                {"test": "HermesGoldUITests.test01ConnectionAndSessionList",
                 "status": "BLOCKED", "failure_stage": "prerequisite.bootstrap",
                 "diagnostics": ["Blocked by bootstrap"]},
                {"test": "HermesGoldUITests.test02SendStreamAndComplete",
                 "status": "BLOCKED", "failure_stage": "prerequisite.bootstrap",
                 "diagnostics": ["Blocked by bootstrap"]},
            ],
        }
        with mock.patch.object(triage, "upsert") as upsert, \
             mock.patch.object(triage, "append_exact_issue") as exact:
            triage.triage_versioned("Whale7-git/HermesBuild", report,
                                  "4321", "https://example.invalid/run")
        self.assertEqual(upsert.call_count, 1)
        self.assertIn("HermesBootstrapUITests",
                      upsert.call_args.args[2])
        self.assertEqual(exact.call_count, 1)
        self.assertEqual(exact.call_args.args[1], 86)
        self.assertIn("prerequisite.bootstrap", exact.call_args.args[2])

    def test_failed_test_fingerprint_is_stable(self):
        import hashlib
        test = "HermesGoldUITests.test04StreamingManualReadingKeepsAnchor"
        self.assertEqual(
            hashlib.sha256(("test:" + test).encode()).hexdigest()[:20],
            hashlib.sha256(("test:" + test).encode()).hexdigest()[:20])

    def test_assertions_redact_secrets_and_links(self):
        value = triage.safe_assertion(
            "error: XCTAssertTrue failed token=secret123 https://example.org/a")
        self.assertNotIn("secret123", value)
        self.assertNotIn("example.org", value)
        self.assertIn("XCTAssert", value)

    def test_existing_issue_reuses_fingerprint_and_avoids_duplicate_comment(self):
        issue = {"number": 52, "body": "<!-- simulator-key:abcdef -->"}
        calls = []
        def stub(method, path, data=None):
            calls.append((method, path, data))
            if path.startswith("/search/issues"):
                return {"items": [issue]}
            if "/comments" in path and method == "GET":
                return [{"body": "already seen run 123"}]
            raise AssertionError((method, path))
        with mock.patch.object(triage, "api", side_effect=stub):
            triage.upsert("Whale7-git/HermesBuild", "abcdef", "test", "run 123", "123")
        self.assertFalse(any(method == "POST" for method, _, _ in calls))


if __name__ == "__main__":
    unittest.main()
