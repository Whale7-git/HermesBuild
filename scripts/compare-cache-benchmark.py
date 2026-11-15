#!/usr/bin/env python3
"""Compare cold/warm cache benchmark records and fail on unsafe results."""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

PHASE_LABELS = {
    "workflow_setup": "Checkout, runner and XcodeGen setup",
    "preflight": "Preflight checks",
    "source_gate": "Source integrity gate",
    "xcodegen": "Generate Xcode project",
    "info_plist": "Prepare CI Info.plist",
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


def main() -> int:
    if len(sys.argv) != 6:
        raise SystemExit(
            "usage: compare-cache-benchmark.py COLD.json WARM.json "
            "CACHE_BYTES SAVE_SECONDS RESTORE_SECONDS"
        )
    cold = load(sys.argv[1])
    warm = load(sys.argv[2])
    source_bytes = int(sys.argv[3])
    save_seconds = float(sys.argv[4])
    restore_seconds = float(sys.argv[5])

    mode = os.environ.get("CACHE_BENCHMARK_MODE", "same")
    if mode not in {"same", "adjacent"}:
        raise SystemExit(f"unsupported cache benchmark mode: {mode}")
    expected_cold = os.environ.get("EXPECTED_COLD_SHA")
    expected_warm = os.environ.get("EXPECTED_WARM_SHA")
    if expected_cold and cold["source_sha"] != expected_cold:
        raise SystemExit("cold source SHA differs from the expected seed")
    if expected_warm and warm["source_sha"] != expected_warm:
        raise SystemExit("warm source SHA differs from the expected candidate")
    if mode == "same":
        if cold["source_sha"] != warm["source_sha"]:
            raise SystemExit("source SHA differs between same-commit runs")
        if expected_cold and expected_warm and expected_cold != expected_warm:
            raise SystemExit("same mode requires identical expected SHAs")
    else:
        candidate = os.environ.get("CANDIDATE_SHA")
        seed = os.environ.get("SEED_SHA")
        if not candidate or not seed:
            raise SystemExit("adjacent mode requires candidate and seed SHAs")
        if cold["source_sha"] != seed or warm["source_sha"] != candidate:
            raise SystemExit("adjacent SHAs do not match seed and candidate")
        if cold["source_sha"] == warm["source_sha"]:
            raise SystemExit("adjacent mode requires distinct source SHAs")
    if cold["toolchain"] != warm["toolchain"]:
        raise SystemExit("Xcode toolchain differs between cold and warm runs")
    if cold["iphoneos_sdk"] != warm["iphoneos_sdk"]:
        raise SystemExit("iPhoneOS SDK differs between cold and warm runs")
    if mode == "same" and cold["payload_sha256"] != warm["payload_sha256"]:
        raise SystemExit("same-commit bundled resources differ")
    cold_phases = cold.get("phase_seconds")
    warm_phases = warm.get("phase_seconds")
    if not isinstance(cold_phases, dict) or not isinstance(warm_phases, dict):
        raise SystemExit("cold and warm results must both include phase_seconds")
    cold_phases = dict(cold_phases)
    warm_phases = dict(warm_phases)
    cold_setup = os.environ.get("COLD_SETUP_SECONDS")
    warm_setup = os.environ.get("WARM_SETUP_SECONDS")
    if cold_setup is not None or warm_setup is not None:
        if cold_setup is None or warm_setup is None:
            raise SystemExit("both cold and warm setup times are required")
        cold_phases["workflow_setup"] = float(cold_setup)
        warm_phases["workflow_setup"] = float(warm_setup)
    if cold_phases.keys() != warm_phases.keys():
        raise SystemExit("cold and warm phase names differ")

    cold_seconds = float(cold["build_seconds"])
    warm_seconds = float(warm["build_seconds"])
    net_seconds = cold_seconds - save_seconds - restore_seconds - warm_seconds
    ratio = warm_seconds / cold_seconds if cold_seconds else 0.0
    payload_matches = cold["payload_sha256"] == warm["payload_sha256"]

    phase_order = list(PHASE_LABELS)
    ordered_phases = [name for name in phase_order if name in cold_phases]
    ordered_phases.extend(sorted(cold_phases.keys() - set(phase_order)))
    phase_rows = []
    for name in ordered_phases:
        cold_phase = float(cold_phases[name])
        warm_phase = float(warm_phases[name])
        phase_rows.append(
            f"| {PHASE_LABELS.get(name, name)} | "
            f"{cold_phase:.3f}s | {warm_phase:.3f}s | "
            f"{warm_phase - cold_phase:+.3f}s |"
        )

    summary = [
        "### Cold/warm DerivedData benchmark",
        "",
        "| Measurement | Result |",
        "|---|---:|",
        f"| Cold build, package and IPA verification | {cold_seconds:.3f}s |",
        f"| Cache save wall time | {save_seconds:.3f}s |",
        f"| Cache restore wall time | {restore_seconds:.3f}s |",
        f"| Warm build, package and IPA verification | {warm_seconds:.3f}s |",
        f"| Net saving across cold+warm pair | {net_seconds:+.3f}s |",
        f"| Warm/cold build ratio | {ratio:.3f} |",
        f"| Restored DerivedData source size | {source_bytes} bytes |",
        f"| Bundled resources identical | {'yes' if payload_matches else 'no'} |",
        f"| Cold bundled resource SHA-256 | `{cold['payload_sha256']}` |",
        f"| Warm bundled resource SHA-256 | `{warm['payload_sha256']}` |",
        f"| Cold IPA SHA-256 | `{cold['ipa_sha256']}` |",
        f"| Warm IPA SHA-256 | `{warm['ipa_sha256']}` |",
        "",
        "#### Phase breakdown",
        "",
        "| Phase | Cold | Warm | Warm minus cold |",
        "|---|---:|---:|---:|",
        *phase_rows,
        "",
        (
            "This is one same-commit pilot on separate hosted runners."
            if mode == "same"
            else "This is one direct-parent pilot on separate hosted runners."
        ),
        "",
        "The warm run performed a complete build and independent IPA verification.",
    ]
    text = "\n".join(summary) + "\n"
    print(text)
    if target := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(target, "a", encoding="utf-8") as stream:
            stream.write(text)

    # This is evidence for the decision, not a release gate. A negative result
    # deliberately remains successful so the measurement is available.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
