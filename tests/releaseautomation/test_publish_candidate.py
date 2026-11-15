import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "publish_candidate", ROOT / "scripts" / "publish-candidate.py"
)
publish_candidate_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publish_candidate_module)

MAIN = "a" * 40
HEAD = "b" * 40
TREE = "c" * 40
SELECTED = {
    "main_sha": MAIN,
    "main_tree": TREE,
    "candidate_head_sha": HEAD,
    "candidate_tree": TREE,
    "run_id": 7,
    "run_attempt": 1,
    "artifact_id": 99,
    "artifact_digest": "sha256:" + "d" * 64,
    "pr_number": 9,
    "tag": "release-2.28.0-build170",
}
CANDIDATE = {
    "commit": "e" * 40,
}


class FakeGitHub:
    repository = "Whale7-git/HermesBuild"

    def __init__(self, release):
        self.release = release
        self.calls = []

    def api(self, path, method="GET", data=None, missing=False):
        self.calls.append((path, method, data))
        if path == "releases/tags/release-2.28.0-build170":
            return self.release
        if path == "git/ref/tags/release-2.28.0-build170":
            return {"object": {"type": "commit", "sha": MAIN}}
        raise AssertionError((path, method, data))

    def upload(self, tag, paths):
        raise AssertionError("published release must not upload again")


class PublishCandidateTests(unittest.TestCase):
    def test_selected_run_id_is_compared_as_manifest_string(self):
        selected = dict(SELECTED, run_id=43697060376)
        candidate = dict(
            CANDIDATE,
            version="2.28.0",
            build="170",
            producer_run_id="43697060376",
            producer_run_attempt="1",
            producer_event="pull_request",
        )
        self.assertEqual(candidate["producer_run_id"], str(selected["run_id"]))

    def test_matching_published_release_is_idempotent(self):
        release = {
            "id": 12,
            "draft": False,
            "prerelease": False,
            "html_url": "https://github.com/example/release",
            "target_commitish": MAIN,
            "body": publish_candidate_module.marker(SELECTED, CANDIDATE),
            "assets": [],
        }
        client = FakeGitHub(release)
        with tempfile.TemporaryDirectory() as temp:
            with mock.patch.object(publish_candidate_module, "verify_remote"):
                url = publish_candidate_module.publish(
                    client, SELECTED, CANDIDATE, Path(temp)
                )
        self.assertEqual(url, release["html_url"])
        self.assertFalse(any(method != "GET" for _, method, _ in client.calls))

    def test_matching_published_release_still_checks_remote_bytes(self):
        release = {
            "id": 12,
            "draft": False,
            "prerelease": False,
            "html_url": "https://github.com/example/release",
            "target_commitish": MAIN,
            "body": publish_candidate_module.marker(SELECTED, CANDIDATE),
            "assets": [],
        }
        client = FakeGitHub(release)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "asset").write_bytes(b"x")
            with mock.patch.object(publish_candidate_module, "verify_remote") as verify:
                publish_candidate_module.publish(client, SELECTED, CANDIDATE, root)
        verify.assert_called_once()


if __name__ == "__main__":
    unittest.main()
