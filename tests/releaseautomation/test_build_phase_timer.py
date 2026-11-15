import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BUILD_SCRIPT = ROOT / "scripts" / "github-build-ipa.sh"


class BuildPhaseTimerTests(unittest.TestCase):
    def timer_prefix(self):
        script = BUILD_SCRIPT.read_text(encoding="utf-8")
        marker = '\nbuild_started_ns="$(now_ns)"\n'
        self.assertIn(marker, script)
        return script.split(marker, 1)[0]

    def run_harness(self, extra: str, environment: dict[str, str]):
        with tempfile.TemporaryDirectory() as temporary:
            harness = Path(temporary) / "timer.sh"
            harness.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                + self.timer_prefix()
                + "\n"
                + extra
                + "\n",
                encoding="utf-8",
            )
            harness.chmod(0o755)
            return subprocess.run(
                ["bash", str(harness)],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )

    def test_disabled_timer_never_runs_python_or_writes_a_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment = os.environ.copy()
            environment.pop("HERMES_BUILD_PHASE_TIMINGS_FILE", None)
            python_probe = Path(temporary) / "python3"
            python_probe.write_text("#!/bin/sh\nexit 97\n", encoding="utf-8")
            python_probe.chmod(0o755)
            environment["PATH"] = temporary + os.pathsep + environment["PATH"]
            result = self.run_harness(
                'started="$(now_ns)"\n'
                'record_phase xcodebuild "$started"\n'
                'printf "started=%s\\n" "$started"\n',
                environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "started=0")

    def test_enabled_timer_records_a_positive_phase(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "phases.env"
            environment = os.environ.copy()
            environment["HERMES_BUILD_PHASE_TIMINGS_FILE"] = str(output)
            python_directory = Path(temporary) / "python"
            python_directory.mkdir()
            wrapper = python_directory / "python3"
            wrapper.write_text(
                "#!/bin/sh\n"
                f"exec {shlex.quote(Path(sys.executable).as_posix())} \"$@\"\n",
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
            environment["PATH"] = (
                str(python_directory) + os.pathsep + environment["PATH"]
            )
            result = self.run_harness(
                'started="$(now_ns)"\n'
                'sleep 0.1\n'
                'record_phase xcodebuild "$started"\n'
                'cat "$HERMES_BUILD_PHASE_TIMINGS_FILE"\n',
                environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            name, raw_seconds = result.stdout.strip().split("=", 1)
            self.assertEqual(name, "xcodebuild")
            self.assertGreaterEqual(float(raw_seconds), 0.1)
            self.assertLess(float(raw_seconds), 2.0)
            self.assertEqual(output.read_text(encoding="utf-8").strip(), result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
