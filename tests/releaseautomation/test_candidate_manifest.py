import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_candidate", ROOT / "scripts" / "verify-candidate.py"
)
verify_candidate_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify_candidate_module)

SHA = "a" * 40
TREE = "b" * 40
VERSION = "2.28.0"
BUILD = "170"
IPA = f"Hermes-{VERSION}-build{BUILD}-unsigned.ipa"


class CandidateManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / IPA).write_bytes(b"ipa")
        (self.root / "build-info.json").write_text(json.dumps({
            "version": VERSION,
            "build": BUILD,
            "working_tree": "clean",
            "head_commit": SHA,
            "head_tree": TREE,
            "source_head_commit": SHA,
            "source_tree": TREE,
        }))
        (self.root / "validation.json").write_text(json.dumps({
            "ipa": IPA,
            "sha256": self.digest(IPA),
            "bundle": "com.whale7.hermes",
            "version": VERSION,
            "build": BUILD,
            "arch": "arm64",
            "unsigned": True,
        }))
        manifest = {
            "schema_version": 1,
            "repository": "Whale7-git/HermesBuild",
            "producer": {
                "event": "pull_request",
                "run_id": "123",
                "run_attempt": "1",
                "workflow_path": ".github/workflows/hermesshell-single-build.yml",
                "workflow_blob_sha": "e" * 40,
            },
            "source": {"commit": SHA, "tree": TREE, "working_tree": "clean"},
            "release": {
                "version": VERSION,
                "build": BUILD,
                "tag": f"release-{VERSION}-build{BUILD}",
                "ipa": IPA,
            },
            "files": {
                IPA: self.digest(IPA),
                "build-info.json": self.digest("build-info.json"),
                "validation.json": self.digest("validation.json"),
            },
        }
        (self.root / "candidate-manifest.json").write_text(json.dumps(manifest))
        self.write_checksums()

    def digest(self, name):
        return hashlib.sha256((self.root / name).read_bytes()).hexdigest()

    def write_checksums(self):
        names = [IPA, "build-info.json", "validation.json", "candidate-manifest.json"]
        (self.root / "SHA256SUMS.txt").write_text(
            "".join(f"{self.digest(name)}  {name}\n" for name in names)
        )

    def test_valid_candidate_and_expected_tree(self):
        result = verify_candidate_module.verify_candidate(self.root, TREE)
        self.assertEqual(result["version"], VERSION)
        self.assertEqual(result["build"], BUILD)
        self.assertEqual(result["tree"], TREE)

    def test_wrong_main_tree_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "does not match expected tree"):
            verify_candidate_module.verify_candidate(self.root, "c" * 40)

    def test_tampered_file_is_rejected(self):
        (self.root / IPA).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            verify_candidate_module.verify_candidate(self.root, TREE)

    def test_rehashed_manifest_with_wrong_identity_is_rejected(self):
        path = self.root / "candidate-manifest.json"
        manifest = json.loads(path.read_text())
        manifest["release"]["build"] = "171"
        path.write_text(json.dumps(manifest))
        self.write_checksums()
        with self.assertRaisesRegex(ValueError, "IPA name"):
            verify_candidate_module.verify_candidate(self.root, TREE)


if __name__ == "__main__":
    unittest.main()
