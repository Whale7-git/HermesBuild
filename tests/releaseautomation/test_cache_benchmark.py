import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def module(filename="compare-cache-benchmark.py", name="compare_cache_benchmark"):
    path = ROOT / "scripts" / filename
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


class CacheBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def record(self, name, **changes):
        data = {
            "mode": name,
            "source_sha": "a" * 40,
            "version": "2.26.1",
            "build": "167",
            "toolchain": "Xcode 26.6",
            "iphoneos_sdk": "26.2",
            "build_seconds": 180.0,
            "ipa_sha256": "b" * 64,
            "payload_sha256": "c" * 64,
            "ipa_bytes": 1000,
            "deriveddata_kib": 1000,
            "deriveddata_bytes": 1024000,
        }
        data.update(changes)
        path = self.root / f"{name}.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def test_safe_payload_identity_is_accepted(self):
        compare = module()
        old_argv = sys.argv
        old_environment = os.environ.copy()
        try:
            os.environ.pop("GITHUB_STEP_SUMMARY", None)
            os.environ["CACHE_BENCHMARK_MODE"] = "same"
            sys.argv = [
                "compare",
                str(self.record("cold")),
                str(self.record("warm")),
                "1024000",
                "10",
                "20",
            ]
            self.assertEqual(compare.main(), 0)
        finally:
            sys.argv = old_argv
            os.environ.clear()
            os.environ.update(old_environment)

    def test_different_payload_is_rejected(self):
        compare = module()
        old_argv = sys.argv
        old_environment = os.environ.copy()
        try:
            os.environ["CACHE_BENCHMARK_MODE"] = "same"
            sys.argv = [
                "compare",
                str(self.record("cold")),
                str(self.record("warm", payload_sha256="d" * 64)),
                "1024000",
                "10",
                "20",
            ]
            with self.assertRaises(SystemExit) as error:
                compare.main()
            self.assertIn("resources differ", str(error.exception))
        finally:
            sys.argv = old_argv
            os.environ.clear()
            os.environ.update(old_environment)

    def test_toolchain_and_source_mismatches_are_rejected(self):
        compare = module()
        old_argv = sys.argv
        old_environment = os.environ.copy()
        try:
            os.environ["CACHE_BENCHMARK_MODE"] = "same"
            for changes, message in [
                ({"source_sha": "d" * 40}, "source SHA differs"),
                ({"toolchain": "Xcode 26.7"}, "toolchain differs"),
                ({"iphoneos_sdk": "26.3"}, "SDK differs"),
            ]:
                sys.argv = [
                    "compare",
                    str(self.record("cold")),
                    str(self.record("warm", **changes)),
                    "1024000",
                    "10",
                    "20",
                ]
                with self.assertRaises(SystemExit) as error:
                    compare.main()
                self.assertIn(message, str(error.exception))
        finally:
            sys.argv = old_argv
            os.environ.clear()
            os.environ.update(old_environment)

    def test_adjacent_mode_accepts_parent_and_child(self):
        compare = module()
        old_argv = sys.argv
        old_environment = os.environ.copy()
        try:
            os.environ.update(
                {
                    "CACHE_BENCHMARK_MODE": "adjacent",
                    "EXPECTED_COLD_SHA": "a" * 40,
                    "EXPECTED_WARM_SHA": "b" * 40,
                    "SEED_SHA": "a" * 40,
                    "CANDIDATE_SHA": "b" * 40,
                }
            )
            sys.argv = [
                "compare",
                str(self.record("cold")),
                str(
                    self.record(
                        "warm",
                        source_sha="b" * 40,
                        payload_sha256="d" * 64,
                    )
                ),
                "1024000",
                "10",
                "20",
            ]
            self.assertEqual(compare.main(), 0)
        finally:
            sys.argv = old_argv
            os.environ.clear()
            os.environ.update(old_environment)

    def test_adjacent_mode_rejects_swapped_shas(self):
        compare = module()
        old_argv = sys.argv
        old_environment = os.environ.copy()
        try:
            os.environ.update(
                {
                    "CACHE_BENCHMARK_MODE": "adjacent",
                    "SEED_SHA": "a" * 40,
                    "CANDIDATE_SHA": "b" * 40,
                }
            )
            sys.argv = [
                "compare",
                str(self.record("cold", source_sha="b" * 40)),
                str(self.record("warm", source_sha="a" * 40)),
                "1024000",
                "10",
                "20",
            ]
            with self.assertRaises(SystemExit) as error:
                compare.main()
            self.assertIn("adjacent SHAs", str(error.exception))
        finally:
            sys.argv = old_argv
            os.environ.clear()
            os.environ.update(old_environment)


class CacheIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_namespace_is_deterministic_and_cache_key_safe(self):
        identity = module("cache-benchmark-identity.py", "cache_identity")
        project = self.root
        (project / "HermesShellCI.xcodeproj" / "xcshareddata").mkdir(parents=True)
        (project / "HermesShellCI.xcodeproj" / "project.pbxproj").write_text(
            "project\n", encoding="utf-8"
        )
        (project / "HermesShellCI.xcodeproj" / "xcshareddata" / "scheme.xcscheme").write_text(
            "scheme\n", encoding="utf-8"
        )
        (project / "Vendor" / "Textual").mkdir(parents=True)
        (project / "Package.swift").write_text("package\n", encoding="utf-8")
        (project / "Package.resolved").write_text("resolved\n", encoding="utf-8")
        (project / "Vendor" / "Textual" / "Package.swift").write_text(
            "vendor\n", encoding="utf-8"
        )
        commands = mock.Mock(
            side_effect=[
                "26.7.2",
                "Xcode 26.6\nBuild version 17F42",
                "26.2",
                "26.2",
                "arm64",
                "26.7.2",
                "Xcode 26.6\nBuild version 17F42",
                "26.2",
                "26.2",
                "arm64",
            ]
        )
        with (
            mock.patch.object(
                identity,
                "command",
                commands,
            ),
            mock.patch.object(identity.subprocess, "run"),
            mock.patch.object(identity.shutil, "rmtree"),
            mock.patch.dict(os.environ, {}, clear=True),
        ):
            first = identity.identity(project)
            second = identity.identity(project)
        self.assertEqual(first, second)
        self.assertNotIn(" ", first)
        self.assertNotIn("\n", first)
        self.assertIn("macos26.7.2", first)
        self.assertIn("xcodeXcode-26.6-Build-version-17F42", first)


class CacheWorkflowTests(unittest.TestCase):
    def test_workflow_cannot_skip_source_verification(self):
        workflow_path = ROOT / ".github" / "workflows" / "cache-benchmark.yml"
        workflow = workflow_path.read_text(encoding="utf-8")
        self.assertIn("on:\n  workflow_dispatch:\n", workflow)
        self.assertNotIn("  push:\n", workflow)
        self.assertNotIn("actions: write", workflow)
        self.assertIn("run${{ github.run_id }}-attempt${{ github.run_attempt }}", workflow)
        self.assertNotIn("HERMES_SOURCE_VERIFIED_SHA", workflow)
        self.assertIn("inputs.mode == 'same'", workflow)
        self.assertIn("inputs.mode == 'adjacent'", workflow)
        self.assertIn("ref: ${{ inputs.seed_sha }}", workflow)
        self.assertIn("ref: ${{ github.sha }}", workflow)
        self.assertIn('actual_sha="$(git rev-parse HEAD)"', workflow)
        self.assertIn("-adjacent-seed${expected_seed}-candidate${CANDIDATE_SHA}", workflow)

        script = (ROOT / "scripts" / "cache-benchmark.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("env -u HERMES_SOURCE_VERIFIED_SHA", script)
        self.assertIn('actual_sha="$(git rev-parse HEAD)"', script)
        self.assertIn('PR_HEAD_SHA="$actual_sha"', script)


if __name__ == "__main__":
    unittest.main()
