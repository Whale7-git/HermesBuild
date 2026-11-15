"""GPT-only branch guards and isolation from former private build hosts."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / "scripts/gpt-cloud-build.sh"


class GPTBuildContractTests(unittest.TestCase):
    def check_rejection(self, **changes):
        env = os.environ.copy()
        env.update({
            "GITHUB_ACTIONS": "true",
            "GITHUB_REPOSITORY": "Whale7-git/HermesBuild",
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_REF": "refs/heads/gpt/cloud-build-bootstrap",
            "GITHUB_SHA": subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        })
        env.update(changes)
        result = subprocess.run(["bash", str(ENTRY), "source"], cwd=ROOT, env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        return result.stderr

    def test_rejects_main_branch(self):
        self.assertIn("only accepts pushes", self.check_rejection(GITHUB_REF="refs/heads/main"))

    def test_rejects_other_repository(self):
        self.assertIn("unexpected GitHub repository", self.check_rejection(GITHUB_REPOSITORY="other/repo"))

    def test_rejects_wrong_event(self):
        self.assertIn("only accepts pushes", self.check_rejection(GITHUB_EVENT_NAME="workflow_dispatch"))

    def test_rejects_forged_commit_sha(self):
        self.assertIn("checkout SHA differs", self.check_rejection(GITHUB_SHA="0" * 40))

    def test_rejects_tag_ref(self):
        self.assertIn("only accepts pushes", self.check_rejection(GITHUB_REF="refs/tags/gpt/fake"))

    def test_no_legacy_execution_or_release(self):
        workflow = (ROOT / ".github/workflows/gpt-cloud-build.yml").read_text()
        entry = ENTRY.read_text()
        source_gate = (ROOT / "tests/verify_source.py").read_text()
        self.assertIn("'gpt/**'", workflow)
        self.assertIn("needs: [source, offline]", workflow)
        for forbidden in ("self-hosted", "BARK_URL", "contents: write",
                          "scripts/release-local.sh", "scripts/build-on-9.ps1"):
            self.assertNotIn(forbidden, workflow)
        for forbidden in ("ssh ", "build-on-9.ps1", "release-local.sh",
                          "publish-candidate.py", "github-publish-release.sh"):
            self.assertNotIn(forbidden, entry)
        self.assertNotIn("build-on-9.ps1", source_gate)
        self.assertNotIn("release-local.sh", source_gate)


if __name__ == "__main__":
    unittest.main()
