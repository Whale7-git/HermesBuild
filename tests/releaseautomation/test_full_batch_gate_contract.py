"""Regression guards for the full-Issue batch release contract.

This is a source-level safety check; GitHub's trusted workflow enforces the
live Issue-set matrix and exact-head CI at execution time.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class BatchGateContractTests(unittest.TestCase):
    def test_trusted_gate_requires_live_issue_matrix(self):
        workflow = (ROOT / ".github/workflows/verified-release-automerge.yml").read_text()
        for token in (
            "tests/release-batch-acceptance.json",
            "Missing changed full-batch acceptance matrix",
            "Batch matrix must enumerate every currently open Issue",
            "Batch matrix does not match exact PR head/base/release",
            "External blocker lacks contract/failure evidence",
            "Required exact-head workflow incomplete or failing",
            "path === 'release.json'",
        ):
            with self.subTest(token=token):
                self.assertIn(token, workflow)

    def test_single_issue_autonomy_is_not_the_policy(self):
        guide = (ROOT / "AGENTS.md").read_text()
        skill = (ROOT / ".agents/skills/ios-quality-review/SKILL.md").read_text()
        self.assertNotIn("select one actionable Issue", guide)
        self.assertNotIn("select one actionable Issue", skill)
        self.assertIn("every** open Issue", guide)
        self.assertIn("full batch acceptance matrix", skill)

    def test_optional_release_batch_manifest_is_well_formed(self):
        # This maintenance branch has no manifest. Final product releases
        # deliberately add it: rejecting its existence would make every
        # subsequent release CI fail.
        path = ROOT / "tests/release-batch-acceptance.json"
        if not path.exists():
            return
        import json
        matrix = json.loads(path.read_text())
        release = json.loads((ROOT / "release.json").read_text())
        self.assertEqual(matrix["schema"], 1)
        self.assertEqual(matrix["version"], release["version"])
        self.assertEqual(int(matrix["build"]), int(release["build"]))
        self.assertTrue(matrix["base_sha"])
        self.assertTrue(matrix["issues"])
        numbers = [item["number"] for item in matrix["issues"]]
        self.assertEqual(len(numbers), len(set(numbers)))


if __name__ == "__main__":
    unittest.main()
