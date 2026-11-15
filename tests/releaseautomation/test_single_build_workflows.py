from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]


class SingleBuildWorkflowTests(unittest.TestCase):
    def test_candidate_workflow_builds_and_uploads_once(self):
        path = ROOT / ".github/workflows/hermesshell-single-build.yml"
        text = path.read_text()
        workflow = yaml.safe_load(text)
        self.assertIn("pull_request", workflow[True])
        self.assertIn("workflow_dispatch", workflow[True])
        self.assertEqual(list(workflow["jobs"]), ["source", "offline", "candidate"])
        self.assertEqual(text.count("bash scripts/github-build-ipa-main.sh"), 1)
        self.assertEqual(text.count("actions/upload-artifact@"), 1)
        self.assertIn("HERMES_WORKFLOW_BLOB_SHA", text)
        self.assertIn("needs: [source, offline]", text)
        self.assertNotIn("publish-candidate.py", text)
        self.assertNotIn("BARK_URL", text)
        self.assertNotIn("contents: write", text)

    def test_promotion_workflow_never_compiles(self):
        path = ROOT / ".github/workflows/hermesshell-single-promote.yml"
        text = path.read_text()
        workflow = yaml.safe_load(text)
        self.assertEqual(list(workflow[True]), ["push"])
        self.assertIn("promote", workflow["jobs"])
        self.assertIn("actions/download-artifact@", text)
        self.assertIn("actions/artifacts/${ARTIFACT_ID}/zip", text)
        self.assertNotIn("uses: actions/download-artifact@", text)
        self.assertIn("publish-candidate.py", text)
        self.assertNotIn("github-build-ipa", text)
        self.assertNotIn("xcodegen", text)
        self.assertNotIn("xcodebuild", text)

    def test_legacy_workflow_is_manual_only(self):
        path = ROOT / ".github/workflows/hermesshell-adaptive-release.yml"
        workflow = yaml.safe_load(path.read_text())
        self.assertEqual(list(workflow[True]), ["workflow_dispatch"])


if __name__ == "__main__":
    unittest.main()
