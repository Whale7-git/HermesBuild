import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load_script(name):
    path = ROOT / "scripts" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_").removesuffix(".py"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ToolchainCaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_script("capture-candidate-toolchain.py")

    def test_matching_toolchain_has_no_drift(self):
        baseline = {
            "macos": "26.7.2",
            "macos_build": "25G332",
            "xcode": "Xcode 26.6\nBuild version 17F113",
            "xcode_version": "26.6.0",
            "xcodegen": "2.46.0",
            "iphoneos_sdk": "26.5",
            "swift": "Apple Swift version 6.3.3",
            "architecture": "arm64",
        }
        with mock.patch.object(self.module, "run", side_effect=[
            baseline["macos"],
            baseline["macos_build"],
            baseline["xcode"],
            baseline["swift"],
            baseline["iphoneos_sdk"],
            baseline["xcodegen"],
            baseline["architecture"],
        ]):
            result = self.module.capture(baseline)
        self.assertEqual(result["drift"], {})
        self.assertTrue(result["compatible"])
        self.assertNotIn("developer_dir", result)

    def test_changed_toolchain_is_reported_without_failing(self):
        baseline = {
            "xcode": "Xcode 26.6\nBuild version 17F113",
            "xcode_version": "26.6.0",
            "xcodegen": "2.46.0",
            "iphoneos_sdk": "26.5",
        }
        with mock.patch.object(self.module, "run", side_effect=[
            "26.7.2",
            "25G332",
            "Xcode 26.7\nBuild version 18A1",
            "Apple Swift version 6.4",
            "26.6",
            "Version: 2.47.0",
            "arm64",
        ]):
            result = self.module.capture(baseline)
        self.assertEqual(
            set(result["drift"]),
            {"xcode", "xcode_version", "xcodegen", "iphoneos_sdk"},
        )
        self.assertTrue(result["compatible"])

    def test_wrong_major_toolchain_is_rejected(self):
        with mock.patch.object(self.module, "run", side_effect=[
            "27.0",
            "26A1",
            "Xcode 27.0\nBuild version 19A1",
            "Apple Swift version 6.4",
            "27.0",
            "Version: 2.46.0",
            "arm64",
        ]):
            with self.assertRaisesRegex(ValueError, "major version 26"):
                self.module.capture({})


class CandidateReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_script("write-candidate-report.py")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.diagnostics = self.root / "diagnostics"
        self.candidate = self.root / "candidate"
        self.export = self.root / "export"
        self.diagnostics.mkdir()
        self.candidate.mkdir()
        (self.diagnostics / "toolchain.json").write_text(json.dumps({
            "xcode": "Xcode 26.6\nBuild version 17F113",
            "xcodegen": "Version: 2.46.0",
            "iphoneos_sdk": "26.5",
            "drift": {},
        }))
        (self.diagnostics / "xcodebuild.log").write_text(
            "warning: first warning\nwarning: second warning\nwarning: first warning\n"
        )
        (self.diagnostics / "build.log").write_text(
            "CANDIDATE_SOURCE commit=a tree=b\n"
        )
        (self.diagnostics / "setup.started").write_text("100")
        (self.diagnostics / "setup.finished").write_text("112")
        (self.diagnostics / "build.started").write_text("120")
        (self.diagnostics / "build.finished").write_text("155")
        (self.candidate / "build-info.json").write_text(json.dumps({
            "head_commit": "a" * 40,
            "head_tree": "b" * 40,
        }))
        (self.candidate / "validation.json").write_text(json.dumps({
            "ipa": "Hermes-2.28.0-build174-unsigned.ipa",
            "sha256": "f" * 64,
            "container_path": "/Users/runner/work/_temp/candidate/Hermes.ipa",
            "build_info": {
                "path": "/Users/runner/work/_temp/candidate/build-info.json",
            },
        }))
        (self.candidate / "candidate-manifest.json").write_text(json.dumps({
            "producer": {
                "run_id": "123",
                "run_attempt": "1",
                "workflow_blob_sha": "e" * 40,
            },
            "release": {
                "ipa": "Hermes-2.28.0-build174-unsigned.ipa",
            },
            "files": {
                "Hermes-2.28.0-build174-unsigned.ipa": "f" * 64,
            },
        }))
        (self.root / "release.json").write_text(json.dumps({
            "version": "2.28.0",
            "build": "174",
        }))

    def invoke(self, env):
        with mock.patch.dict(os.environ, env, clear=True), \
             mock.patch.object(self.module, "ROOT", self.root):
            self.module.main.__wrapped__ if False else None
            with mock.patch("sys.argv", [
                "write-candidate-report.py",
                str(self.diagnostics),
                str(self.candidate),
                str(self.export),
            ]):
                return self.module.main()

    def test_success_report_distinguishes_hashes_and_deduplicates_warnings(self):
        status = self.invoke({
            "GITHUB_REPOSITORY": "Whale7-git/HermesBuild",
            "GITHUB_EVENT_NAME": "pull_request",
            "GITHUB_RUN_ID": "123",
            "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_SHA": "a" * 40,
            "HERMES_SETUP_RESULT": "success",
            "HERMES_TOOLCHAIN_RESULT": "success",
            "HERMES_IDENTITY_RESULT": "success",
            "HERMES_BUILD_RESULT": "success",
            "HERMES_ENFORCE_RESULT": "success",
            "HERMES_VERIFY_RESULT": "success",
            "HERMES_UPLOAD_RESULT": "success",
            "HERMES_RECORD_RESULT": "success",
            "HERMES_ARTIFACT_DIGEST": "sha256:" + "d" * 64,
        })
        self.assertEqual(status, 0)
        report = json.loads((self.export / "build-report.json").read_text())
        self.assertEqual(report["status"], "success")
        self.assertIsNone(report["failure"])
        self.assertEqual(report["timing_seconds"], {"setup": 12, "build": 35})
        self.assertEqual(report["compiler"]["warning_count"], 2)
        self.assertEqual(report["candidate"]["ipa_sha256"], "f" * 64)
        self.assertEqual(
            report["candidate"]["artifact_digest"],
            "sha256:" + "d" * 64,
        )
        self.assertEqual(report["publication"], "not_attempted")
        self.assertEqual(
            (self.export / "candidate-manifest.json").read_bytes(),
            (self.candidate / "candidate-manifest.json").read_bytes(),
        )
        exported_validation = (self.export / "validation.json").read_text()
        self.assertNotIn("/Users/runner", exported_validation)
        self.assertIn("<runner-path>", exported_validation)

    def test_failure_report_is_written_when_candidate_files_are_absent(self):
        for path in self.candidate.iterdir():
            path.unlink()
        (self.diagnostics / "build.log").write_text(
            "error: one real compiler error\n##[error]Process completed with exit code 1\n"
        )
        status = self.invoke({
            "GITHUB_RUN_ID": "123",
            "GITHUB_RUN_ATTEMPT": "2",
            "HERMES_SETUP_RESULT": "success",
            "HERMES_TOOLCHAIN_RESULT": "success",
            "HERMES_IDENTITY_RESULT": "success",
            "HERMES_BUILD_RESULT": "failure",
            "HERMES_ENFORCE_RESULT": "skipped",
            "HERMES_VERIFY_RESULT": "skipped",
            "HERMES_UPLOAD_RESULT": "skipped",
            "HERMES_RECORD_RESULT": "skipped",
        })
        self.assertEqual(status, 0)
        report = json.loads((self.export / "build-report.json").read_text())
        self.assertEqual(report["status"], "failure")
        self.assertEqual(report["failure"]["stage"], "build")
        self.assertEqual(report["stages"]["build"], "failure")
        self.assertIsNone(report["candidate"]["ipa_sha256"])
        self.assertEqual(len(report["compiler"]["errors"]), 2)

    def test_identity_and_post_upload_failures_are_reported(self):
        common = {
            "HERMES_SETUP_RESULT": "success",
            "HERMES_TOOLCHAIN_RESULT": "success",
            "HERMES_IDENTITY_RESULT": "success",
            "HERMES_BUILD_RESULT": "success",
            "HERMES_ENFORCE_RESULT": "success",
            "HERMES_VERIFY_RESULT": "success",
            "HERMES_UPLOAD_RESULT": "success",
            "HERMES_RECORD_RESULT": "success",
        }
        for failed, expected_stage in (
            ("HERMES_IDENTITY_RESULT", "identity"),
            ("HERMES_ENFORCE_RESULT", "enforce"),
            ("HERMES_RECORD_RESULT", "record"),
        ):
            with self.subTest(failed=failed):
                status = self.invoke({**common, failed: "failure"})
                self.assertEqual(status, 0)
                report = json.loads((self.export / "build-report.json").read_text())
                self.assertEqual(report["status"], "failure")
                self.assertEqual(report["failure"]["stage"], expected_stage)

    def test_logs_and_compiler_excerpts_are_redacted(self):
        github_token = "ghp_" + "A" * 36
        (self.diagnostics / "build.log").write_text(
            "error: Authorization: Bearer " + github_token + "\n"
            "api_key=super-secret-value\n"
            "workspace=/Users/runner/work/HermesBuild/HermesBuild\n"
            "-I/Users/runner/work/_temp/DerivedData\n"
            "-F/private/var/tmp/framework\n"
        )
        status = self.invoke({
            "HERMES_SETUP_RESULT": "success",
            "HERMES_TOOLCHAIN_RESULT": "success",
            "HERMES_IDENTITY_RESULT": "success",
            "HERMES_BUILD_RESULT": "failure",
            "HERMES_ENFORCE_RESULT": "skipped",
            "HERMES_VERIFY_RESULT": "skipped",
            "HERMES_UPLOAD_RESULT": "skipped",
            "HERMES_RECORD_RESULT": "skipped",
        })
        self.assertEqual(status, 0)
        log = (self.export / "build.log").read_text()
        report = (self.export / "build-report.json").read_text()
        for value in (log, report):
            self.assertNotIn(github_token, value)
            self.assertNotIn("super-secret-value", value)
            self.assertNotIn("/Users/runner", value)
            self.assertNotIn("/private/var/tmp", value)
            self.assertIn("[REDACTED", value)
        self.assertIn(github_token, (self.diagnostics / "build.log").read_text())


if __name__ == "__main__":
    unittest.main()
