#!/usr/bin/env python3
"""Run targeted real-iOS XCTest cases against an immutable product source SHA.

This is trusted harness code from main, never executed from a PR or comment.
The iOS simulator is erased between cases so drafts/Keychain cannot leak.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request

BOOTSTRAP = "HermesBootstrapUITests.testGatewaySetupPersistsAcrossRelaunch"
SETTINGS = "HermesSettingsNavigationUITests.testPushedSettingsPageCanDismissWithoutNativeBack"
GOLD = [
    "HermesGoldUITests.test01ConnectionAndSessionList",
    "HermesGoldUITests.test02SendStreamAndComplete",
    "HermesGoldUITests.test03ReaderProgressAdvancesOnSwipe",
    "HermesGoldUITests.test04StreamingManualReadingKeepsAnchor",
]
RECOVERY = ["HermesLongTaskRecoveryUITests.testFailedHistoryAutomaticallyRecoversWithoutManualCheck"]
INTERACTION = [
    "HermesChatSelectionGestureUITests.testTextDragDoesNotRevealDrawer",
    "HermesChatSelectionGestureUITests.testShortRightSwipeReturnsToVerticalScrolling",
    "HermesChatSelectionGestureUITests.testOrdinaryFullCardSwipeStillOpensDrawer",
    "HermesComposerStabilityUITests.testWrappedDraftSettlesWithoutHeightOscillation",
    "HermesAccessibilityUITests.test01SessionListAudit",
    "HermesAccessibilityUITests.test02HomeAudit",
    "HermesAccessibilityUITests.test03ChatAudit",
    "HermesRealChatDynamicTypeUITests.testChatNativeGlyphsGrowWithSystemSize",
    "HermesSentImagePreviewUITests.testUploadedHistoryImageLoadsAndOpens",
]
SUITES = {
    "bootstrap": [BOOTSTRAP],
    "settings": [SETTINGS],
    "gold1": [GOLD[0]], "gold2": [GOLD[1]], "gold3": [GOLD[2]],
    "gold4": [GOLD[3]],
    # Gold1 performs real Save, Keychain cold relaunch and the mock session GET.
    # A flaky, separately tracked Settings-navigation contract must not block
    # product assertions for all other Gold cases in an aggregate suite.
    "gold": GOLD,
    "recovery": RECOVERY, "interaction": INTERACTION,
    "all": GOLD + RECOVERY + INTERACTION,
}
# Settings includes an OS Passwords prompt on some iOS 26 simulators.
# Bound this single XCTest below the runner's observed 15-minute cancellation
# window so timeout evidence can still be uploaded as INFRA_ERROR.
SETTINGS_XCTEST_TIMEOUT_SECONDS = 300
SHA = re.compile(r"^[0-9a-f]{40}$")
SAFE_CASE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*\.test[A-Za-z0-9_]+$")


def cases_for_suite(suite: str) -> list[str]:
    if suite not in SUITES:
        raise ValueError(f"unknown suite: {suite}")
    return list(dict.fromkeys(SUITES[suite]))


def run(args: list[str], log: Path | None = None, timeout: int = 120) -> int:
    if log:
        with log.open("w", encoding="utf-8") as handle:
            return subprocess.run(args, stdout=handle, stderr=subprocess.STDOUT,
                                  check=False, timeout=timeout).returncode
    return subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
                          check=False, timeout=timeout).returncode


def fresh_simulator(udid: str) -> None:
    run(["xcrun", "simctl", "shutdown", udid], timeout=60)
    for args in (["xcrun", "simctl", "erase", udid],
                 ["xcrun", "simctl", "boot", udid],
                 ["xcrun", "simctl", "bootstatus", udid, "-b"]):
        rc = run(args, timeout=180)
        if rc:
            raise RuntimeError(f"simctl failed: {args[2]} (exit {rc})")


def reset_gateway() -> None:
    request = urllib.request.Request("http://127.0.0.1:8765/__control/reset",
                                     data=b"{}", method="POST",
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        if response.status != 200:
            raise RuntimeError("fixture reset did not return HTTP 200")


def diagnostic_lines(log: Path) -> list[str]:
    if not log.is_file():
        return []
    result = []
    for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
        if "error:" in line or ("Test Case" in line and " failed" in line):
            line = re.sub(r"(?i)(bearer|api[_-]?key|token|password)\s*[:= ]\s*\S+",
                          "[redacted]", line)
            line = re.sub(r"https?://\S+", "[url]", line)
            # Keep the assertion identity and failed stage, not merely the
            # final 350 bytes of an extended UIKit scroll trace.
            line = line.strip()
            if len(line) > 1000:
                line = line[:720] + " ... [truncated] ... " + line[-180:]
            result.append(line)
    return result[-5:]


def observed_selected_pass(log: Path, testcase: str) -> bool:
    """xcodebuild exit 0 without the requested XCTest is NOT a test PASS."""
    if not log.is_file():
        return False
    suite, method = testcase.split(".", 1)
    needle = f"Test Case '-[HermesUITests.{suite} {method}]' passed"
    return any(needle in line for line in
               log.read_text(encoding="utf-8", errors="replace").splitlines())


def classify_case(exit_code: int, diagnostics: list[str],
                  testcase: str) -> tuple[str, str | None]:
    """Distinguish a blocked common setup from an actual product assertion."""
    raw = "\n".join(diagnostics)
    match = re.search(r"stage=([a-zA-Z0-9_.:-]+)", raw)
    stage = match.group(1) if match else None
    if exit_code == 0:
        return "PASS", None
    # XCTFail prints a failing Test Case line even when the assertion line
    # does not mention XCTest by name.
    assertion = any(("Test Case" in line and " failed" in line) or
                    "XCTAssert" in line or " error: " in line
                    for line in diagnostics)
    if not assertion:
        return "INFRA_ERROR", stage or "infra.xcodebuild"
    if "SETUP_BLOCKED" in raw:
        return ("FAIL" if testcase == BOOTSTRAP else "BLOCKED",
                stage or "setup.unknown")
    return "FAIL", stage or "product.assertion"


def classify_timeout_case(diagnostics: list[str],
                          testcase: str) -> tuple[str, str]:
    """Preserve completed XCTest failure even if xcodebuild later hangs.

    A completed, selected Test Case failed line is stronger evidence than
    the subprocess timeout that happened during result-bundle finalization.
    Without that exact completion marker, a timeout stays infrastructure
    uncertainty rather than an invented app assertion.
    """
    suite, method = testcase.split(".", 1)
    selected_failure = (
        f"Test Case '-[HermesUITests.{suite} {method}]' failed"
    )
    if any(selected_failure in line for line in diagnostics):
        status, stage = classify_case(1, diagnostics, testcase)
        return status, stage or "product.assertion"
    return "INFRA_ERROR", "infra.xctest_timeout"


def write_json(path: Path, content: dict) -> None:
    path.write_text(json.dumps(content, ensure_ascii=False, indent=2),
                    encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", choices=sorted(SUITES), required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--xctestrun", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--harness-sha", required=True)
    args = parser.parse_args()
    if not SHA.fullmatch(args.source_sha) or not SHA.fullmatch(args.harness_sha):
        parser.error("expected exact 40-character SHA")
    if not args.xctestrun.is_file():
        parser.error("build-for-testing produced no .xctestrun")
    args.output.mkdir(parents=True, exist_ok=True)
    report = {
        "schema": 2, "run_id": os.environ.get("GITHUB_RUN_ID", "local"),
        "source_sha": args.source_sha, "harness_sha": args.harness_sha,
        "suite": args.suite, "cases": [],
    }
    write_json(args.output / "simulator-report.json", report)
    failed = False
    blocked_by = None
    for index, testcase in enumerate(cases_for_suite(args.suite), start=1):
        assert SAFE_CASE.fullmatch(testcase)
        name = f"{index:02d}-{testcase.replace('.', '-')}"
        output = args.output / name
        output.mkdir()
        entry = {"test": testcase, "status": "INFRA_ERROR", "evidence": name}
        report["cases"].append(entry)
        if blocked_by:
            # Never spend another simulator run on a downstream Gold when a
            # prerequisite failed. This is an unexecuted BLOCKED case, not a
            # second product FAIL and not an inferred PASS.
            entry.update(status="BLOCKED", failure_stage="prerequisite." + blocked_by,
                         diagnostics=["Blocked: prerequisite " + blocked_by + " not PASS"],
                         duration_seconds=0)
            print(f"SIMULATOR_CASE {testcase}: BLOCKED by {blocked_by}", flush=True)
            write_json(args.output / "simulator-report.json", report)
            failed = True
            continue
        write_json(args.output / "simulator-report.json", report)
        started = time.monotonic()
        try:
            fresh_simulator(args.device)
            reset_gateway()
            bundle = output / "HermesUITests.xcresult"
            log = output / "xcodebuild-ui.log"
            cmd = [
                "xcodebuild", "test-without-building",
                "-xctestrun", str(args.xctestrun.resolve()),
                "-destination", f"platform=iOS Simulator,id={args.device}",
                "-parallel-testing-enabled", "NO",
                "-resultBundlePath", str(bundle),
                f"-only-testing:HermesUITests/{testcase.replace('.', '/')}",
                "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-",
                "CODE_SIGNING_REQUIRED=YES",
            ]
            print(f"SIMULATOR_CASE_START {testcase} "
                  f"timeout={SETTINGS_XCTEST_TIMEOUT_SECONDS if testcase == SETTINGS else 720}s",
                  flush=True)
            rc = run(cmd, log=log, timeout=(
                SETTINGS_XCTEST_TIMEOUT_SECONDS if testcase == SETTINGS else 720))
            lines = diagnostic_lines(log)
            entry["status"], stage = classify_case(rc, lines, testcase)
            if rc == 0 and not observed_selected_pass(log, testcase):
                entry["status"] = "INFRA_ERROR"
                stage = "infra.no_test_executed"
                lines.append("Requested XCTest did not report a passed Test Case")
            if stage:
                entry["failure_stage"] = stage
            entry["exit_code"] = rc
            entry["diagnostics"] = lines
            for diagnostic in lines:
                print(f"SIMULATOR_DIAGNOSTIC {testcase}: {diagnostic}", flush=True)
            if bundle.is_dir():
                for label, command in (
                    ("xcresult-summary.json", ["get", "test-results", "summary"]),
                    ("xcresult-cases.json", ["get", "test-results", "tests"]),
                ):
                    run(["xcrun", "xcresulttool", *command,
                         "--path", str(bundle)], log=output / label, timeout=30)
                run(["xcrun", "xcresulttool", "export", "attachments",
                     "--path", str(bundle), "--output-path", str(output / "attachments"),
                     "--only-failures"], timeout=45)
        except subprocess.TimeoutExpired:
            # Run #45227799195 captured the exact failed XCTest (75.6s)
            # before xcodebuild stalled finalizing results (300s). Do not
            # erase authoritative XCTest failure_stage with a later timeout.
            diagnostics = diagnostic_lines(output / "xcodebuild-ui.log")
            entry["status"], entry["failure_stage"] = classify_timeout_case(
                diagnostics, testcase)
            entry["xcodebuild_timed_out"] = True
            entry["diagnostics"] = diagnostics[-3:]
            entry["diagnostics"].append(
                "xcodebuild exceeded bounded timeout after "
                + ("selected XCTest failure" if entry["status"] != "INFRA_ERROR"
                   else "no completed selected XCTest failure"))
            print(f"SIMULATOR_TIMEOUT {testcase}: {entry['status']} "
                  f"stage={entry['failure_stage']}", flush=True)
        except Exception as error:
            # Simulator management and Python execution faults must not be
            # misclassified as user-facing App defects.
            entry["status"] = "INFRA_ERROR"
            entry["failure_stage"] = "infra.simulator_or_test_runner"
            entry["diagnostics"] = [type(error).__name__ + ": " + str(error)[:200]]
        finally:
            entry["duration_seconds"] = round(time.monotonic() - started, 1)
            try:
                with urllib.request.urlopen("http://127.0.0.1:8765/__control/log",
                                            timeout=5) as response:
                    write_json(output / "mock-requests.json",
                               json.loads(response.read(1024 * 1024)))
            except Exception:
                pass
            write_json(args.output / "simulator-report.json", report)
            print(f"SIMULATOR_CASE {testcase}: {entry['status']}", flush=True)
            if entry["status"] != "PASS":
                failed = True
                if testcase == BOOTSTRAP:
                    blocked_by = "bootstrap"
                elif testcase == GOLD[0] and args.suite in {"gold", "all"}:
                    blocked_by = "gold1"
    report["outcome"] = "FAIL" if failed else "PASS"
    write_json(args.output / "simulator-report.json", report)
    print(f"SIMULATOR_VERIFICATION_{report['outcome']} source={args.source_sha} "
          f"harness={args.harness_sha} suite={args.suite}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
