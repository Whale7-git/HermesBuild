#!/usr/bin/env python3
"""Write a structured HermesBuild candidate report for success and failure paths."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
REDACTIONS = (
    (
        re.compile(
            r"(?i)(authorization\s*:\s*(?:bearer|basic)\s+)[^\s,;]+"
        ),
        r"\1[REDACTED]",
    ),
    (re.compile(r"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]+"), r"\1[REDACTED]"),
    (
        re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
        "[REDACTED_GITHUB_TOKEN]",
    ),
    (
        re.compile(r"(?i)(https?://)[^/\s:@]+:[^@\s/]+@"),
        r"\1[REDACTED]@",
    ),
    (
        re.compile(
            r"(?i)([?&](?:access_token|token|api_key|apikey|key|auth|"
            r"authorization|password|passwd|secret|signature|sig|"
            r"x-amz-signature|x-goog-signature)=)[^&#\s]+"
        ),
        r"\1[REDACTED]",
    ),
    (
        re.compile(
            r"(?i)\b(api[_-]?key|access[_-]?token|token|secret|password)"
            r"(\s*[=:]\s*)[^\s,;]+"
        ),
        r"\1\2[REDACTED]",
    ),
    (
        re.compile(r"/(?:Users|Volumes)/[^\s\"'<>]+"),
        "<runner-path>",
    ),
    (
        re.compile(
            r"/(?:private/(?:var|tmp)|var/folders|tmp)/[^\s\"'<>]+"
        ),
        "<runner-path>",
    ),
)


def sanitize_text(value: str) -> str:
    clean = ANSI.sub("", value)
    for pattern, replacement in REDACTIONS:
        clean = pattern.sub(replacement, clean)
    return clean


def export_sanitized_logs(diagnostics: Path, export: Path) -> None:
    for path in sorted(diagnostics.glob("*.log")):
        try:
            value = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        (export / path.name).write_text(sanitize_text(value), encoding="utf-8")


def export_sanitized_json(source: Path, destination: Path) -> None:
    value = source.read_text(encoding="utf-8")
    destination.write_text(sanitize_text(value), encoding="utf-8")


def load(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def read_lines(path: Path, pattern: str, limit: int) -> list[str]:
    try:
        text = sanitize_text(path.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return []
    found = []
    for line in text.splitlines():
        clean = " ".join(line.strip().split())[:300]
        if clean and re.search(pattern, clean, re.IGNORECASE) and clean not in found:
            found.append(clean)
    return found[-limit:]


def elapsed(start: Path, finish: Path) -> int | None:
    try:
        started = int(start.read_text(encoding="utf-8").strip())
        ended = int(finish.read_text(encoding="utf-8").strip()) if finish.is_file() else int(time.time())
        return max(0, ended - started)
    except (OSError, ValueError):
        return None


def outcome(value: str | None) -> str:
    return value if value in {"success", "failure", "cancelled", "skipped"} else "unknown"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("diagnostics", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("export", type=Path)
    args = parser.parse_args()
    diagnostics = args.diagnostics.resolve()
    candidate = args.candidate.resolve()
    export = args.export.resolve()
    diagnostics.mkdir(parents=True, exist_ok=True)
    export.mkdir(parents=True, exist_ok=True)
    export_sanitized_logs(diagnostics, export)

    release = load(ROOT / "release.json")
    build_info = load(candidate / "build-info.json")
    validation = load(candidate / "validation.json")
    manifest = load(candidate / "candidate-manifest.json")
    toolchain = load(diagnostics / "toolchain.json")
    build_log = diagnostics / "build.log"
    xcode_log = diagnostics / "xcodebuild.log"

    warnings = read_lines(xcode_log, r"\bwarning:", 20)
    errors = read_lines(build_log, r"\berror:|^ERROR:|_FAILED:|##\[error\]", 10)
    producer = manifest.get("producer") or {}
    files = manifest.get("files") or {}
    ipa_name = (manifest.get("release") or {}).get("ipa")
    ipa_sha256 = files.get(ipa_name) if isinstance(ipa_name, str) else None
    stages = {
        "setup": outcome(os.environ.get("HERMES_SETUP_RESULT")),
        "toolchain": outcome(os.environ.get("HERMES_TOOLCHAIN_RESULT")),
        "identity": outcome(os.environ.get("HERMES_IDENTITY_RESULT")),
        "build": outcome(os.environ.get("HERMES_BUILD_RESULT")),
        "enforce": outcome(os.environ.get("HERMES_ENFORCE_RESULT")),
        "candidate_verification": outcome(os.environ.get("HERMES_VERIFY_RESULT")),
        "candidate_upload": outcome(os.environ.get("HERMES_UPLOAD_RESULT")),
        "record": outcome(os.environ.get("HERMES_RECORD_RESULT")),
    }
    failed_stage = next(
        (name for name, value in stages.items() if value == "failure"),
        None,
    )
    if failed_stage is not None:
        status = "failure"
        failure = {
            "stage": failed_stage,
            "message": f"{failed_stage} did not succeed",
        }
    elif all(value in {"success", "skipped"} for value in stages.values()):
        status = "success"
        failure = None
    elif any(value == "unknown" for value in stages.values()):
        status = "unknown"
        failure = None
    else:
        status = "incomplete"
        failure = None

    result = {
        "schema_version": 1,
        "status": status,
        "failure": failure,
        "repository": os.environ.get("GITHUB_REPOSITORY", ""),
        "event": os.environ.get("GITHUB_EVENT_NAME", ""),
        "ref": os.environ.get("GITHUB_REF", ""),
        "run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
        "commit": os.environ.get("GITHUB_SHA", ""),
        "version": release.get("version"),
        "build": release.get("build"),
        "stages": stages,
        "timing_seconds": {
            "setup": elapsed(diagnostics / "setup.started", diagnostics / "setup.finished"),
            "build": elapsed(diagnostics / "build.started", diagnostics / "build.finished"),
        },
        "toolchain": toolchain,
        "compiler": {
            "warning_count": len(warnings),
            "warnings": warnings,
            "errors": errors,
        },
        "candidate": {
            "ipa": validation.get("ipa"),
            "ipa_sha256": validation.get("sha256") or ipa_sha256,
            "build_info_commit": build_info.get("head_commit"),
            "build_info_tree": build_info.get("head_tree"),
            "producer_run_id": producer.get("run_id"),
            "producer_run_attempt": producer.get("run_attempt"),
            "workflow_blob_sha": producer.get("workflow_blob_sha"),
            "artifact_name": os.environ.get("HERMES_ARTIFACT_NAME") or None,
            "artifact_id": os.environ.get("HERMES_ARTIFACT_ID") or None,
            "artifact_digest": os.environ.get("HERMES_ARTIFACT_DIGEST") or None,
        },
        "publication": "not_attempted",
        "device_acceptance": "not_performed",
    }
    destination = export / "build-report.json"
    destination.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    if toolchain:
        (export / "toolchain.json").write_text(
            json.dumps(toolchain, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    for name in (
        "build-info.json",
        "validation.json",
        "candidate-manifest.json",
        "SHA256SUMS.txt",
    ):
        source = candidate / name
        if source.is_file():
            export_sanitized_json(source, export / name)

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        lines = [
            "### Candidate diagnostics",
            "",
            f"- Status: `{result['status']}`",
            f"- Version/build: `{result['version']} / {result['build']}`",
            f"- Commit: `{result['commit']}`",
            f"- Stages: `{result['stages']}`",
            f"- Xcode: `{toolchain.get('xcode', 'unavailable')}`",
            f"- iPhoneOS SDK: `{toolchain.get('iphoneos_sdk', 'unavailable')}`",
            f"- XcodeGen: `{toolchain.get('xcodegen', 'unavailable')}`",
            f"- Compiler warnings: `{len(warnings)}`; error lines: `{len(errors)}`",
            f"- IPA SHA-256: `{result['candidate']['ipa_sha256'] or 'unavailable'}`",
            f"- Artifact digest: `{result['candidate']['artifact_digest'] or 'unavailable'}`",
            "- Release: not attempted; device acceptance: not performed",
        ]
        with open(summary_path, "a", encoding="utf-8") as stream:
            stream.write("\n".join(lines) + "\n")
    print(f"CANDIDATE_REPORT_READY path={destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
