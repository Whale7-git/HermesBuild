"""Safeguard advisory Issue tracking without blocking personal IPA releases."""
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ReleaseDiagnosticsContractTests(unittest.TestCase):
    def test_release_does_not_gate_on_issue_or_test_matrix(self):
        workflow = (ROOT / ".github/workflows/verified-release-automerge.yml").read_text()
        self.assertNotIn("Missing changed full-batch acceptance matrix", workflow)
        self.assertNotIn("Batch matrix must enumerate every currently open Issue", workflow)
        self.assertNotIn("Required exact-head workflow incomplete or failing", workflow)
        self.assertNotIn("matrix.issues", workflow)
        self.assertIn("HermesBuild single-build candidate", workflow)
        self.assertIn("createWorkflowDispatch", workflow)

    def test_batch_issues_still_tracked_and_diagnostics_visible(self):
        guide = (ROOT / "AGENTS.md").read_text()
        self.assertIn("every** open Issue", guide)
        self.assertIn("nonblocking", guide.lower())
        diagnostic = (ROOT / ".github/workflows/hermes-offline-diagnostics.yml").read_text()
        self.assertIn("Swift offline", diagnostic)
        self.assertIn("shard: [core, recovery, interface, media]", diagnostic)

    def test_optional_batch_manifest_stays_well_formed(self):
        path = ROOT / "tests/release-batch-acceptance.json"
        if not path.exists():
            return
        matrix = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(matrix["schema"], 1)
        self.assertTrue(matrix["issues"])
        numbers = [item["number"] for item in matrix["issues"]]
        self.assertEqual(len(numbers), len(set(numbers)))


if __name__ == "__main__":
    unittest.main()
