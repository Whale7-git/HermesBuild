#!/usr/bin/env python3
"""Compare two cache benchmark records and fail on unsafe differences."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys


PHASE_LABELS = {
    "preflight": "Preflight checks",
    "source_gate": "Source integrity gate",
    "xcodegen": "Prepared Xcode project",
    "info_plist": "Prepared CI Info.plist",
    "xcodebuild": "xcodebuild compile/link/dSYM",
    "app_locate": "Locate built app",
    "package_ipa": "Package unsigned IPA",
    "build_info": "Write build metadata",
    "ipa_verification": "Built-in IPA verification",
    "checksums": "Write checksum manifest",
    "github_build_total": "GitHub build script total",
    "benchmark_build_wrapper": "Benchmark build wrapper total",
    "independent_ipa_verification": "Independent IPA verification",
    "payload_extract": "Unpack IPA payload",
    "resource_hash": "Hash stable resources",
    "metadata": "Collect benchmark metadata",
    "benchmark_total": "Benchmark script total",
}


def load(path: str) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def require_identity(cold: dict, warm: dict) -> None:
    for field, message in (
        ("source_sha", "source SHA differs"),
        ("toolchain", "Xcode toolchain differs"),
        ("iphoneos_sdk", "iPhoneOS SDK differs"),
        ("input_manifest_sha256", "input manifest differs"),
        ("payload_sha256", "bundled resources differ"),
    ):
        if cold[field] != warm[field]:
            raise SystemExit(f"{message}: {cold[field]} != {warm[field]}")


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[1] != "same":
        raise SystemExit("usage: compare-cache-benchmark.py same COLD.json WARM.json")
    cold = load(sys.argv[2])
    warm = load(sys.argv[3])
    require_identity(cold, warm)

    cold_phases = cold.get("phase_seconds")
    warm_phases = warm.get("phase_seconds")
    if not isinstance(cold_phases, dict) or not isinstance(warm_phases, dict):
        raise SystemExit("both results must include phase_seconds")
    if cold_phases.keys() != warm_phases.keys():
        raise SystemExit("phase names differ")

    cold_seconds = float(cold["build_seconds"])
    warm_seconds = float(warm["build_seconds"])
    ratio = warm_seconds / cold_seconds if cold_seconds else 0.0
    cold_xcodebuild = float(cold_phases["xcodebuild"])
    warm_xcodebuild = float(warm_phases["xcodebuild"])

    rows = []
    ordered = [name for name in PHASE_LABELS if name in cold_phases]
    ordered.extend(sorted(cold_phases.keys() - set(PHASE_LABELS)))
    for name in ordered:
        cold_value = float(cold_phases[name])
        warm_value = float(warm_phases[name])
        rows.append(
            f"| {PHASE_LABELS.get(name, name)} | "
            f"{cold_value:.3f}s | {warm_value:.3f}s | "
            f"{warm_value - cold_value:+.3f}s |"
        )

    summary = [
        "### DerivedData cache comparison",
        "",
        "| Measurement | Cold | Warm | Warm minus cold |",
        "|---|---:|---:|---:|",
        f"| Build wrapper | {cold_seconds:.3f}s | {warm_seconds:.3f}s | "
        f"{warm_seconds - cold_seconds:+.3f}s |",
        f"| xcodebuild | {cold_xcodebuild:.3f}s | {warm_xcodebuild:.3f}s | "
        f"{warm_xcodebuild - cold_xcodebuild:+.3f}s |",
        f"| HermesShell SwiftCompile tasks | "
        f"{cold['compiled_hermes_sources']} | {warm['compiled_hermes_sources']} | "
        f"{warm['compiled_hermes_sources'] - cold['compiled_hermes_sources']:+d} |",
        f"| Textual SwiftCompile tasks | "
        f"{cold['compiled_textual_sources']} | {warm['compiled_textual_sources']} | "
        f"{warm['compiled_textual_sources'] - cold['compiled_textual_sources']:+d} |",
        f"| Build directory regenerated | "
        f"{cold['base_directory_regenerated']} | "
        f"{warm['base_directory_regenerated']} | "
        f"{warm['base_directory_regenerated'] - cold['base_directory_regenerated']:+d} |",
        "",
        f"Warm/cold wrapper ratio: **{ratio:.3f}**",
        "",
        f"Input manifest: `{cold['input_manifest_sha256']}`",
        "",
        f"Bundled resources identical: **{'yes' if cold['payload_sha256'] == warm['payload_sha256'] else 'no'}**",
        "",
        "#### Phase breakdown",
        "",
        "| Phase | Cold | Warm | Warm minus cold |",
        "|---|---:|---:|---:|",
        *rows,
    ]
    text = "\n".join(summary) + "\n"
    print(text)
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target:
        with open(target, "a", encoding="utf-8") as stream:
            stream.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
