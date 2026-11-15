from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def triggers(text):
    match = re.search(r"(?ms)^on:\s*\n(.*?)(?=^[A-Za-z][A-Za-z0-9_-]*:\s*$)", text)
    if match is None:
        raise AssertionError("workflow has no on trigger block")
    return {
        line.strip().removesuffix(":")
        for line in match.group(1).splitlines()
        if line.startswith("  ") and not line.startswith("    ")
    }


def jobs(text):
    match = re.search(r"(?ms)^jobs:\s*\n((?:  [A-Za-z0-9_-]+:\s*\n(?:    .*\n|      .*\n|        .*\n|          .*\n|            .*\n|              .*\n|                .*\n|                  .*\n|                    .*\n)*)+)", text)
    if match is None:
        raise AssertionError("workflow has no jobs block")
    return re.findall(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", match.group(1))


class SingleBuildWorkflowTests(unittest.TestCase):
    def test_candidate_workflow_builds_and_uploads_once(self):
        path = ROOT / ".github/workflows/hermesshell-single-build.yml"
        text = path.read_text()
        self.assertEqual(triggers(text), {"pull_request", "workflow_dispatch"})
        self.assertEqual(jobs(text), ["source", "offline", "candidate"])
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
        self.assertEqual(triggers(text), {"push"})
        self.assertIn("promote", jobs(text))
        self.assertIn("actions/download-artifact@", text)
        self.assertIn("actions/artifacts/${ARTIFACT_ID}/zip", text)
        self.assertNotIn("uses: actions/download-artifact@", text)
        self.assertIn("publish-candidate.py", text)
        self.assertNotIn("github-build-ipa", text)
        self.assertNotIn("xcodegen", text)
        self.assertNotIn("xcodebuild", text)

    def test_legacy_workflow_is_manual_only(self):
        path = ROOT / ".github/workflows/hermesshell-adaptive-release.yml"
        self.assertEqual(triggers(path.read_text()), {"workflow_dispatch"})


if __name__ == "__main__":
    unittest.main()
