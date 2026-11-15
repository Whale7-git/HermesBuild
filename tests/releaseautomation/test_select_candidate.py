import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "select_candidate", ROOT / "scripts" / "select-candidate.py"
)
select_candidate_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(select_candidate_module)

MAIN = "a" * 40
HEAD = "b" * 40
TREE = "c" * 40
WORKFLOW = ".github/workflows/hermesshell-single-build.yml"


class FakeGitHub:
    def __init__(self):
        self.repository = "Whale7-git/HermesBuild"
        self.conclusion = "success"
        self.artifacts = [{
            "id": 99,
            "name": f"hermes-candidate-2.28.0-build170-tree{TREE}",
            "expired": False,
            "digest": "sha256:" + "d" * 64,
            "workflow_run": {"id": 7, "head_sha": HEAD},
        }]

    def api(self, path, missing=False):
        if path == f"git/commits/{MAIN}":
            return {"tree": {"sha": TREE}}
        if path == f"commits/{MAIN}/pulls":
            return [{
                "number": 9,
                "merged_at": "2026-11-15T08:00:00Z",
                "merge_commit_sha": MAIN,
                "base": {"ref": "main"},
                "head": {"sha": HEAD},
            }]
        if path == f"actions/runs?head_sha={HEAD}&per_page=100":
            return {"workflow_runs": [{
                "id": 7,
                "event": "pull_request",
                "path": WORKFLOW,
                "conclusion": self.conclusion,
                "head_sha": HEAD,
                "run_attempt": 1,
                "created_at": "2026-11-15T07:00:00Z",
            }]}
        if path == "actions/runs/7/artifacts?per_page=100":
            return {"artifacts": self.artifacts}
        raise AssertionError(path)


class SelectCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "release.json").write_text(json.dumps({
            "version": "2.28.0",
            "build": "170",
        }))

    def test_selects_exact_successful_pr_artifact(self):
        selected = select_candidate_module.select_candidate(FakeGitHub(), MAIN, self.root)
        self.assertEqual(selected["candidate_head_sha"], HEAD)
        self.assertEqual(selected["candidate_tree"], TREE)
        self.assertEqual(selected["artifact_id"], 99)
        self.assertEqual(selected["run_id"], 7)

    def test_rejects_ambiguous_merged_pull_requests(self):
        client = FakeGitHub()
        original = client.api

        def ambiguous(path, missing=False):
            value = original(path, missing)
            if path == f"commits/{MAIN}/pulls":
                return value + value
            return value

        client.api = ambiguous
        with self.assertRaisesRegex(ValueError, "expected one merged PR"):
            select_candidate_module.select_candidate(client, MAIN, self.root)

    def test_rejects_artifact_from_unsuccessful_run(self):
        for conclusion in ("failure", "cancelled", None):
            with self.subTest(conclusion=conclusion):
                client = FakeGitHub()
                client.conclusion = conclusion
                with self.assertRaisesRegex(ValueError, "no successful immutable candidate"):
                    select_candidate_module.select_candidate(client, MAIN, self.root)

    def test_rejects_non_pr_run(self):
        client = FakeGitHub()
        original = client.api

        def non_pr(path, missing=False):
            value = original(path, missing)
            if path == f"actions/runs?head_sha={HEAD}&per_page=100":
                value["workflow_runs"][0]["event"] = "workflow_dispatch"
            return value

        client.api = non_pr
        with self.assertRaisesRegex(ValueError, "no successful immutable candidate"):
            select_candidate_module.select_candidate(client, MAIN, self.root)

    def test_rejects_wrong_tree_artifact_name(self):
        client = FakeGitHub()
        client.artifacts[0]["name"] = "hermes-candidate-2.28.0-build170-tree" + "e" * 40
        with self.assertRaisesRegex(ValueError, "no successful immutable candidate"):
            select_candidate_module.select_candidate(client, MAIN, self.root)

    def test_rejects_duplicate_artifacts_in_one_run(self):
        client = FakeGitHub()
        client.artifacts.append(dict(client.artifacts[0], id=100))
        with self.assertRaisesRegex(ValueError, "duplicate immutable artifacts"):
            select_candidate_module.select_candidate(client, MAIN, self.root)


if __name__ == "__main__":
    unittest.main()
