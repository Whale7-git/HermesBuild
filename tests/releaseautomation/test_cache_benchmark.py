import importlib.util
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]


def module(filename, name):
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
        phases = {
            "preflight": 2.0,
            "source_gate": 5.0,
            "xcodegen": 0.1,
            "info_plist": 0.1,
            "xcodebuild": 140.0,
            "app_locate": 0.1,
            "package_ipa": 2.0,
            "build_info": 0.1,
            "ipa_verification": 8.0,
            "checksums": 0.1,
            "github_build_total": 158.4,
            "benchmark_build_wrapper": 160.0,
            "independent_ipa_verification": 8.0,
            "payload_extract": 1.0,
            "resource_hash": 2.0,
            "metadata": 1.0,
            "benchmark_total": 175.0,
        }
        data = {
            "mode": name,
            "source_sha": "a" * 40,
            "version": "2.27.0",
            "build": "169",
            "toolchain": "Xcode 26.6",
            "iphoneos_sdk": "26.2",
            "input_manifest_sha256": "c" * 64,
            "compiled_hermes_sources": 139,
            "compiled_textual_sources": 201,
            "base_directory_regenerated": 0,
            "build_seconds": 180.0,
            "phase_seconds": phases,
            "ipa_sha256": "b" * 64,
            "payload_sha256": "d" * 64,
            "ipa_bytes": 1000,
            "deriveddata_kib": 1000,
            "deriveddata_bytes": 1024000,
        }
        data.update(changes)
        path = self.root / f"{name}-{len(list(self.root.iterdir()))}.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def run_compare(self, cold, warm):
        compare = module("compare-cache-benchmark.py", "compare_cache_benchmark")
        old_argv = sys.argv
        try:
            sys.argv = ["compare", "same", str(cold), str(warm)]
            return compare.main()
        finally:
            sys.argv = old_argv

    def test_safe_identity_is_accepted(self):
        self.assertEqual(self.run_compare(self.record("cold"), self.record("warm")), 0)

    def test_missing_phase_breakdown_is_rejected(self):
        warm = json.loads(self.record("warm").read_text())
        warm.pop("phase_seconds")
        path = self.root / "warm-missing-phases.json"
        path.write_text(json.dumps(warm), encoding="utf-8")
        with self.assertRaises(SystemExit) as error:
            self.run_compare(self.record("cold"), path)
        self.assertIn("phase_seconds", str(error.exception))

    def test_identity_mismatches_are_rejected(self):
        for changes, message in [
            ({"source_sha": "e" * 40}, "source SHA differs"),
            ({"toolchain": "Xcode 26.7"}, "Xcode toolchain differs"),
            ({"iphoneos_sdk": "26.3"}, "iPhoneOS SDK differs"),
            ({"input_manifest_sha256": "e" * 64}, "input manifest differs"),
            ({"payload_sha256": "e" * 64}, "bundled resources differ"),
        ]:
            with self.assertRaises(SystemExit) as error:
                self.run_compare(self.record("cold"), self.record("warm", **changes))
            self.assertIn(message, str(error.exception))

    def test_compile_counts_and_regeneration_are_visible(self):
        compare = module("compare-cache-benchmark.py", "compare_cache_benchmark_output")
        old_argv = sys.argv
        try:
            sys.argv = [
                "compare",
                "same",
                str(self.record("cold")),
                str(
                    self.record(
                        "warm",
                        compiled_hermes_sources=2,
                        compiled_textual_sources=3,
                        base_directory_regenerated=0,
                        phase_seconds={
                            **json.loads(self.record("template").read_text())["phase_seconds"],
                            "xcodebuild": 10.0,
                        },
                    )
                ),
            ]
            with mock.patch("builtins.print") as output:
                self.assertEqual(compare.main(), 0)
            text = "\n".join(str(call.args[0]) for call in output.call_args_list)
            self.assertIn("HermesShell SwiftCompile tasks", text)
            self.assertIn("| xcodebuild | 140.000s | 10.000s | -130.000s |", text)
        finally:
            sys.argv = old_argv


class CacheIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_namespace_is_deterministic_and_uses_prepared_inputs(self):
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
        (project / "Resources").mkdir(exist_ok=True)
        (project / "Resources" / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleShortVersionString": "2.27.0",
                    "CFBundleVersion": "169",
                }
            )
        )
        (project / "HermesCI-Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleShortVersionString": "2.27.0",
                    "CFBundleVersion": "169",
                    "CFBundleIdentifier": "com.whale7.hermes",
                }
            )
        )
        (project / "hermes-cache-inputs.tsv").write_bytes(b"manifest\n")
        digest = __import__("hashlib").sha256(b"manifest\n").hexdigest()
        (project / "hermes-cache-input-sha256.txt").write_text(
            digest + "\n", encoding="ascii"
        )
        commands = mock.Mock(
            side_effect=[
                "26.7.2",
                "Xcode 26.6\nBuild version 17F42",
                "26.2",
                "26.2",
                "arm64",
                "Swift 6.4.2",
                "2.44.1",
            ] * 2
        )
        with (
            mock.patch.object(identity, "command", commands),
            mock.patch.dict(
                os.environ,
                {
                    "RUNNER_TEMP": str(self.root),
                    "ImageOS": "macos26",
                    "ImageVersion": "20261115.1",
                },
                clear=True,
            ),
        ):
            first = identity.identity(project)
            second = identity.identity(project)
        self.assertEqual(first, second)
        self.assertNotIn(" ", first)
        self.assertIn("hermes-derived-v2", first)
        self.assertIn("inputs" + digest, first)
        self.assertIn("mtime946684800000000000", first)
        self.assertIn("imageversion20261115.1", first)


class CacheWorkflowTests(unittest.TestCase):
    def test_workflow_is_manual_read_only_and_fails_closed(self):
        workflow = (
            ROOT / ".github" / "workflows" / "cache-benchmark.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("on:\n  workflow_dispatch:\n", workflow)
        self.assertNotIn("  push:\n", workflow)
        self.assertNotIn("actions: write", workflow)
        self.assertIn("inputs.require_reuse", workflow)
        self.assertNotIn("seed_sha", workflow)
        self.assertIn("fail-on-cache-miss: true", workflow)
        self.assertNotIn("restore-keys:", workflow)
        self.assertIn("python3 scripts/cache-benchmark-prepare.py", workflow)
        self.assertIn("hermes-cache-input-sha256.txt", workflow)
        self.assertIn("base_directory_regenerated", workflow)
        self.assertNotIn("HERMES_SOURCE_VERIFIED_SHA", workflow)
        self.assertIn("lookup-only: true", workflow)
        self.assertIn("Require an unused cache key", workflow)
        self.assertIn("Require the saved cache to be present", workflow)
        self.assertIn("--reuse-generated", workflow)
        self.assertLess(
            workflow.index("Restore exact producer cache"),
            workflow.index("Prepare restored inputs"),
        )
        self.assertLess(
            workflow.index("Prepare restored inputs"),
            workflow.index("Compare producer and consumer manifests"),
        )
        self.assertLess(
            workflow.index("Normalize the same inputs before same-runner build"),
            workflow.index("Verify same-runner inputs"),
        )
        self.assertLess(
            workflow.index("Freeze prepared inputs before the cold build"),
            workflow.index("Run cold build"),
        )
        self.assertIn("Validate cold baseline", workflow)
        self.assertIn("Compare producer and consumer manifests", workflow)
        self.assertIn("PRODUCER_WORKER", workflow)
        self.assertIn("CONSUMER_WORKER", workflow)
        self.assertIn("net_seconds", workflow)

    def test_benchmark_keeps_complete_verification_and_counts_compiles(self):
        script = (ROOT / "scripts" / "cache-benchmark.sh").read_text(encoding="utf-8")
        self.assertIn("env -u HERMES_SOURCE_VERIFIED_SHA", script)
        self.assertIn('actual_sha="$(git rev-parse HEAD)"', script)
        self.assertIn('PR_HEAD_SHA="$actual_sha"', script)
        self.assertIn('HERMES_REUSE_GENERATED_PROJECT=1', script)
        self.assertIn('HERMES_CI_INFO_PLIST="$RUNNER_TEMP/HermesCI-Info.plist"', script)
        self.assertIn("independent-validation.json", script)
        self.assertIn("compiled_hermes_sources", script)
        self.assertIn("compiled_textual_sources", script)
        self.assertIn("base_directory_regenerated", script)

        build_script = (ROOT / "scripts" / "github-build-ipa.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('phase_file="${HERMES_BUILD_PHASE_TIMINGS_FILE:-}"', build_script)
        self.assertIn('record_phase xcodebuild "$xcodebuild_started_ns"', build_script)
        self.assertIn('record_phase ipa_verification "$ipa_verification_started_ns"', build_script)
        self.assertIn("HERMES_REUSE_GENERATED_PROJECT", build_script)
        self.assertIn("HERMES_CI_INFO_PLIST", build_script)

    def test_prepare_normalizes_files_directories_and_hashes_content(self):
        script = (ROOT / "scripts" / "cache-benchmark-prepare.py").read_text(
            encoding="utf-8"
        )
        self.assertIn("git\", \"ls-files", script)
        self.assertIn("FIXED_EPOCH_NS", script)
        self.assertIn("stat.S_ISREG", script)
        self.assertIn("content_sha", script)
        self.assertIn("project.rglob(\"*\")", script)
        self.assertIn("--reuse-generated", script)


if __name__ == "__main__":
    unittest.main()
