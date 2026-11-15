"""Synthetic IPA provenance tests; no Xcode, network, or real app payload needed."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("gpt_candidate_verify", ROOT / "scripts/gpt-cloud-verify.py")
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)
SHA = "a" * 40


class CandidateVerifyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="gpt-candidate-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.output = self.root / "release"
        self.output.mkdir()
        (self.root / "release.json").write_text(json.dumps({"version": "2.28.0", "build": "170"}))
        self.filename = "Hermes-2.28.0-build170-unsigned.ipa"
        self.info = {
            "version": "2.28.0", "build": "170",
            "head_commit": SHA, "source_head_commit": SHA, "working_tree": "clean"
        }
        self.build_ipa(SHA)
        self.write_reports()

    def build_ipa(self, sha):
        plist = {
            "HermesGitSHA": sha, "CFBundleIdentifier": "com.whale7.hermes",
            "CFBundleShortVersionString": "2.28.0", "CFBundleVersion": "170"
        }
        with zipfile.ZipFile(self.output / self.filename, "w") as archive:
            archive.writestr("Payload/HermesShell.app/Info.plist", plistlib.dumps(plist))

    def write_reports(self):
        (self.output / "build-info.json").write_text(json.dumps(self.info))
        validation = {
            "ipa": self.filename, "sha256": VERIFY.sha256(self.output / self.filename),
            "version": "2.28.0", "build": "170",
            "bundle": "com.whale7.hermes", "arch": "arm64",
            "unsigned": True, "min_os": "18.0",
            "build_info": {"head_commit": self.info["head_commit"],
                           "info_plist_git_sha": SHA}
        }
        (self.output / "validation.json").write_text(json.dumps(validation))
        self.write_manifest()

    def write_manifest(self):
        names = [self.filename, "build-info.json", "validation.json"]
        data = "".join(f"{VERIFY.sha256(self.output / name)}  {name}\n" for name in names)
        (self.output / "SHA256SUMS.txt").write_text(data)

    def test_valid_candidate(self):
        self.assertEqual(VERIFY.verify_candidate(self.output, SHA)["sha256"],
                         VERIFY.sha256(self.output / self.filename))

    def test_rejects_wrong_build_source(self):
        self.info["source_head_commit"] = "b" * 40
        self.write_reports()
        with self.assertRaisesRegex(ValueError, "source commit"):
            VERIFY.verify_candidate(self.output, SHA)

    def test_rejects_bad_embedded_commit(self):
        self.build_ipa("b" * 40)
        self.write_reports()
        with self.assertRaisesRegex(ValueError, "HermesGitSHA"):
            VERIFY.verify_candidate(self.output, SHA)

    def test_rejects_missing_manifest_item(self):
        (self.output / "SHA256SUMS.txt").write_text("")
        with self.assertRaisesRegex(ValueError, "inventory mismatch"):
            VERIFY.verify_candidate(self.output, SHA)

    def test_rejects_modified_ipa_bytes(self):
        with (self.output / self.filename).open("ab") as stream:
            stream.write(b"not in signed manifest")
        with self.assertRaisesRegex(ValueError, "validation.json digest"):
            VERIFY.verify_candidate(self.output, SHA)

    def test_rejects_signature_flag_mismatch(self):
        path = self.output / "validation.json"
        data = json.loads(path.read_text())
        data["unsigned"] = False
        path.write_text(json.dumps(data))
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "signing mismatch"):
            VERIFY.verify_candidate(self.output, SHA)


if __name__ == "__main__":
    unittest.main()
