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
    "gold2": [GOLD[1]], "gold4": [GOLD[3]], "gold": GOLD,
    "recovery": RECOVERY, "interaction": INTERACTION,
    "all": GOLD + RECOVERY + INTERACTION,
}
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
    for index, testcase in enumerate(cases_for_suite(args.suite), start=1):
        assert SAFE_CASE.fullmatch(testcase)
        name = f"{index:02d}-{testcase.replace('.', '-')}"
        output = args.output / name
        output.mkdir()
        entry = {"test": testcase, "status": "INFRA_ERROR", "evidence": name}
        report["cases"].append(entry)
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
            rc = run(cmd, log=log, timeout=720)
            lines = diagnostic_lines(log)
            saw_test_failure = any("Test Case" in line and "failed" in line or
                                   "XCTAssert" in line for line in lines)
            entry["status"] = "PASS" if rc == 0 else (
                "FAIL" if saw_test_failure else "INFRA_ERROR")
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
        except (RuntimeError, OSError, subprocess.TimeoutExpired, Exception) as error:
            # Preserve infra failures separately from product assertions.
            entry["status"] = "INFRA_ERROR"
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
    report["outcome"] = "FAIL" if failed else "PASS"
    write_json(args.output / "simulator-report.json", report)
    print(f"SIMULATOR_VERIFICATION_{report['outcome']} source={args.source_sha} "
          f"harness={args.harness_sha} suite={args.suite}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
