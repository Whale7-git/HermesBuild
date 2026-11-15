#!/usr/bin/env python3
"""Compare cold/warm cache benchmark records and fail on unsafe results."""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


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

    if cold["source_sha"] != warm["source_sha"]:
        raise SystemExit("source SHA differs between cold and warm runs")
    if cold["toolchain"] != warm["toolchain"]:
        raise SystemExit("Xcode toolchain differs between cold and warm runs")
    if cold["iphoneos_sdk"] != warm["iphoneos_sdk"]:
        raise SystemExit("iPhoneOS SDK differs between cold and warm runs")
    if cold["payload_sha256"] != warm["payload_sha256"]:
        raise SystemExit("cold and warm bundled resources differ")

    cold_seconds = float(cold["build_seconds"])
    warm_seconds = float(warm["build_seconds"])
    net_seconds = cold_seconds - save_seconds - restore_seconds - warm_seconds
    ratio = warm_seconds / cold_seconds if cold_seconds else 0.0
    payload_matches = cold["payload_sha256"] == warm["payload_sha256"]

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
        f"| Bundled resource SHA-256 | `{cold['payload_sha256']}` |",
        f"| Cold IPA SHA-256 | `{cold['ipa_sha256']}` |",
        f"| Warm IPA SHA-256 | `{warm['ipa_sha256']}` |",
        "",
        "This is one same-commit pilot on separate hosted runners. It is not yet evidence that a later source commit benefits.",
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
