#!/usr/bin/env python3
"""Summarize a single Xcode Release build without exposing source paths."""
import hashlib
import json
import re
import sys
from pathlib import Path


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            if isinstance(child, (dict, list)):
                yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            if isinstance(child, (dict, list)):
                yield from walk(child)


def read_settings(path):
    values = {}
    active = False
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("Build settings for action"):
            active = "target HermesShell:" in line
            continue
        if active:
            match = re.match(
                r"\s*(SWIFT_COMPILATION_MODE|SWIFT_OPTIMIZATION_LEVEL|SWIFT_VERSION)\s*=\s*(.*?)\s*$",
                line,
            )
            if match:
                values[match.group(1)] = match.group(2)
    return values


def main():
    if len(sys.argv) != 7:
        raise SystemExit(
            "usage: summarize-incremental-release-experiment.py "
            "MODE PHASE SETTINGS XCRESULT_JSON WALL_SECONDS OUTPUT_JSON"
        )
    mode, phase, settings_path, result_path, wall_text, output_path = sys.argv[1:]
    settings = read_settings(settings_path)
    actual_mode = settings.get("SWIFT_COMPILATION_MODE")
    optimization = settings.get("SWIFT_OPTIMIZATION_LEVEL")
    if actual_mode != mode:
        raise SystemExit(
            f"effective SWIFT_COMPILATION_MODE mismatch: expected {mode}, got {actual_mode!r}"
        )
    if optimization != "-O":
        raise SystemExit(
            f"effective SWIFT_OPTIMIZATION_LEVEL mismatch: expected -O, got {optimization!r}"
        )

    data = json.loads(Path(result_path).read_text(encoding="utf-8"))
    records = []
    labels = {}
    for item in walk(data):
        title = item.get("title")
        detail_type = str(item.get("detailStepType", ""))
        try:
            duration = float(item.get("duration"))
        except (TypeError, ValueError):
            duration = 0.0
        if not isinstance(title, str) or duration <= 0:
            continue
        lower_title = title.lower()
        lower_type = detail_type.lower()
        if ".swift" not in lower_title and "swiftcompilation" not in lower_type and "swiftcompile" not in lower_title:
            continue
        match = re.search(r"([^/\\\s]+\.swift)", title)
        label = match.group(1) if match else title[:160]
        digest = hashlib.sha256(label.encode("utf-8")).hexdigest()[:10]
        records.append({"label_hash": digest, "duration_seconds": duration})
        labels[digest] = max(labels.get(digest, 0.0), duration)

    try:
        result_duration = float(data.get("duration"))
    except (TypeError, ValueError):
        result_duration = None

    output = {
        "mode": mode,
        "phase": phase,
        "swift_compilation_mode": actual_mode,
        "swift_optimization_level": optimization,
        "swift_version": settings.get("SWIFT_VERSION"),
        "xcodebuild_wall_seconds": float(wall_text),
        "xcresult_duration_seconds": result_duration,
        "swift_activity_records": len(records),
        "distinct_swift_activity_labels": len(labels),
        "top_swift_activity_hashes": [
            {"label_hash": key, "duration_seconds": value}
            for key, value in sorted(labels.items(), key=lambda pair: pair[1], reverse=True)[:12]
        ],
    }
    Path(output_path).write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print(
        "XCODE_EXPERIMENT "
        f"mode={mode} phase={phase} wall={output['xcodebuild_wall_seconds']:.3f}s "
        f"swift_activity_records={len(records)} "
        f"distinct_swift_labels={len(labels)} "
        f"optimization={optimization}"
    )


if __name__ == "__main__":
    main()
