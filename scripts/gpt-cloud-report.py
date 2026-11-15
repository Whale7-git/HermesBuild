#!/usr/bin/env python3
"""Write an Actions-readable GPT build report, even for partial macOS failures."""
from __future__ import annotations

import json
import os
import re
import shutil
import time
from pathlib import Path


def load(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def duration(logdir: Path, step: str) -> int | None:
    try:
        started = int((logdir / f"{step}.started").read_text().strip())
        finished = logdir / f"{step}.finished"
        ended = int(finished.read_text().strip()) if finished.exists() else int(time.time())
        return max(0, ended - started)
    except (OSError, ValueError):
        return None


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    temp = Path(os.environ["RUNNER_TEMP"])
    logdir = temp / "gpt-cloud"
    logdir.mkdir(parents=True, exist_ok=True)
    release = load(root / "release.json")
    source = load(root / "release" / "build-info.json")
    validation = load(root / "release" / "validation.json")
    toolchain = load(logdir / "toolchain.json")
    xcode_log = temp / "hermes-ios-release.log"
    build_log = logdir / "build.log"

    def entries(path: Path, pattern: str) -> list[str]:
        try:
            value = path.read_text(errors="replace")
        except OSError:
            return []
        return list(dict.fromkeys(line.strip()[:300] for line in value.splitlines()
                                  if re.search(pattern, line, re.IGNORECASE)))

    warnings = entries(xcode_log, r"\bwarning:")
    errors = entries(build_log, r"\berror:|^ERROR:|_FAILED:|##\[error\]")
    result = {
        "repo": os.environ.get("GITHUB_REPOSITORY", ""),
        "ref": os.environ.get("GITHUB_REF", ""),
        "commit": os.environ.get("GITHUB_SHA", ""),
        "run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
        "version": release.get("version"),
        "build": release.get("build"),
        "setup_outcome": os.environ.get("GPT_SETUP_RESULT", "unknown"),
        "build_outcome": os.environ.get("GPT_BUILD_RESULT", "unknown"),
        "setup_seconds": duration(logdir, "setup"),
        "build_seconds": duration(logdir, "build"),
        "toolchain": toolchain,
        "ipa": validation.get("ipa"),
        "ipa_sha256": validation.get("sha256"),
        "build_info_commit": source.get("head_commit"),
        "warnings": warnings,
        "errors": errors[-10:],
        "device_tested": False,
        "published_release": False
    }
    destination = logdir / "report.json"
    destination.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    ipa = root / "release" / str(result["ipa"] or "")
    if result["build_outcome"] == "success" and ipa.is_file():
        shutil.copyfile(destination, root / "release" / "gpt-cloud-report.json")

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        lines = [
            "### GPT cloud branch build (candidate only)",
            f"- Branch: `{result['ref']}`",
            f"- Commit: `{result['commit']}`",
            f"- App version/build: `{result['version']} / {result['build']}`",
            f"- Setup/build: `{result['setup_outcome']} / {result['build_outcome']}`",
            f"- Setup seconds: `{result['setup_seconds']}`; build seconds: `{result['build_seconds']}`",
            f"- Xcode: `{toolchain.get('xcode', 'unavailable')}`",
            f"- iPhoneOS SDK: `{toolchain.get('iphoneos_sdk', 'unavailable')}`",
            f"- IPA: `{result['ipa'] or 'none'}`",
            f"- IPA SHA256: `{result['ipa_sha256'] or 'none'}`",
            f"- Compiler warnings: {len(warnings)}; error lines: {len(errors)}",
            "- Signing: unsigned; physical-device tests: not performed; Release: not published",
            "- Diagnostic logs and the full report are uploaded separately even after failure.",
        ]
        with open(summary, "a", encoding="utf-8") as stream:
            stream.write("\n".join(lines) + "\n")
    print("GPT_BUILD_REPORT_READY", destination)


if __name__ == "__main__":
    main()
