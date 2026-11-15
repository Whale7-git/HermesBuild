#!/usr/bin/env python3
"""Capture the macOS toolchain used by a HermesBuild candidate."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BASELINE = ROOT / "ci" / "toolchain-baseline.json"


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def normalized_version(value: str, label: str) -> str:
    match = re.search(r"(?<!\d)(\d+)\.(\d+)(?:\.(\d+))?", value)
    if match is None:
        raise ValueError(f"cannot parse {label} version from {value!r}")
    return ".".join(str(int(part or 0)) for part in match.groups())


def version_tuple(value: str, label: str) -> tuple[int, int, int]:
    match = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", value)
    if match is None:
        raise ValueError(f"cannot parse {label} version from {value!r}")
    return tuple(int(part or 0) for part in match.groups())


def capture(baseline: dict) -> dict:
    macos_version = run("sw_vers", "-productVersion")
    macos_build = run("sw_vers", "-buildVersion")
    xcode = run("xcodebuild", "-version")
    swift = run("xcrun", "swift", "--version")
    sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-version")
    xcodegen = run("xcodegen", "--version")
    architecture = run("uname", "-m")

    current = {
        "macos": macos_version,
        "macos_build": macos_build,
        "xcode": xcode,
        "xcode_version": normalized_version(xcode, "Xcode"),
        "xcodegen": normalized_version(xcodegen, "XcodeGen"),
        "xcodegen_raw": xcodegen,
        "iphoneos_sdk": sdk,
        "swift": swift,
        "architecture": architecture,
    }
    drift = {
        key: {"expected": baseline.get(key), "actual": value}
        for key, value in current.items()
        if key in baseline and baseline[key] != value
    }

    xcode_major = version_tuple(xcode, "Xcode")[0]
    sdk_major = version_tuple(sdk, "iPhoneOS SDK")[0]
    xcodegen_version = version_tuple(xcodegen, "XcodeGen")
    if xcode_major != 26 or sdk_major != 26:
        raise ValueError("HermesBuild requires Xcode and iPhoneOS SDK major version 26")
    if xcodegen_version < (2, 42, 0):
        raise ValueError("HermesBuild requires XcodeGen 2.42.0 or newer")

    return {
        "schema_version": 1,
        **current,
        "baseline": baseline,
        "drift": drift,
        "compatible": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    args = parser.parse_args()
    try:
        baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
        if baseline.get("schema_version") != 1:
            raise ValueError("unsupported toolchain baseline schema")
        report = capture(baseline)
        args.destination.parent.mkdir(parents=True, exist_ok=True)
        args.destination.write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"TOOLCHAIN_CAPTURE_FAILED: {error}", file=sys.stderr)
        return 1
    if report["drift"]:
        changed = ", ".join(sorted(report["drift"]))
        print(f"::warning::Toolchain differs from the verified baseline: {changed}")
    print(
        f"TOOLCHAIN_CAPTURED xcode={report['xcode'].splitlines()[0]} "
        f"sdk={report['iphoneos_sdk']} xcodegen={report['xcodegen']} "
        f"drift={len(report['drift'])}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
