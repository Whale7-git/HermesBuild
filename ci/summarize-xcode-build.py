#!/usr/bin/env python3
"""Emit privacy-preserving Xcode build metrics from xcresulttool's build log."""
import hashlib
import json
import os
import re
import sys
from pathlib import Path

def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))

def walk(node):
    if isinstance(node, dict):
        yield node
        for child in node.values():
            if isinstance(child, (dict, list)):
                yield from walk(child)
    elif isinstance(node, list):
        for child in node:
            if isinstance(child, (dict, list)):
                yield from walk(child)

def seconds(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None

def get_settings(path):
    values = {}
    active = False
    try:
        lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return values
    for line in lines:
        if line.startswith("Build settings for action") and "target HermesShell:" in line:
            active = True
            continue
        if line.startswith("Build settings for action") and "target HermesShell:" not in line:
            active = False
        if active:
            match = re.match(r"\s*(SWIFT_COMPILATION_MODE|SWIFT_OPTIMIZATION_LEVEL|SWIFT_VERSION|ENABLE_INCREMENTAL_COMPILATION|SWIFT_WHOLE_MODULE_OPTIMIZATION)\s*=\s*(.*?)\s*$", line)
            if match:
                values[match.group(1)] = match.group(2)
    return values

def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: summarize-xcode-build.py PHASE XCRESULT_LOG_JSON BUILD_SETTINGS")
    phase, json_path, settings_path = sys.argv[1:]
    try:
        data = load_json(json_path)
    except Exception as exc:
        print(f"XCODE_ACTIVITY_METRICS=unavailable reason={type(exc).__name__}")
        return 0

    tasks = []
    swift_files = {}
    counters = {}
    for item in walk(data):
        title = item.get("title")
        duration = seconds(item.get("duration"))
        step_type = str(item.get("detailStepType", ""))
        if isinstance(title, str) and duration is not None and duration > 0:
            tasks.append((duration, title, step_type))
            if ".swift" in title or "swiftCompilation" in step_type:
                basename_match = re.search(r"([^/\\\s]+\.swift)", title)
                if basename_match:
                    basename = basename_match.group(1)
                    key = hashlib.sha256(basename.encode("utf-8")).hexdigest()[:10]
                    swift_files[key] = max(swift_files.get(key, 0.0), duration)
        for attachment in item.get("attachments", []) if isinstance(item.get("attachments"), list) else []:
            if not isinstance(attachment, dict):
                continue
            uti = str(attachment.get("uniformTypeIdentifier", ""))
            if uti.endswith(".BuildOperationMetrics"):
                raw = attachment.get("data")
                if isinstance(raw, str):
                    try:
                        counters.update(json.loads(raw).get("counters", {}))
                    except (ValueError, TypeError):
                        pass

    duration = seconds(data.get("duration"))
    if duration is None and data.get("startTime") is not None and data.get("endTime") is not None:
        duration = seconds(data["endTime"]) - seconds(data["startTime"])

    settings = get_settings(settings_path)
    print(f"XCODE_{phase.upper()}_RESULT_DURATION_SECONDS={duration:.3f}" if duration is not None else "XCODE_RESULT_DURATION_SECONDS=unavailable")
    for key in ("SWIFT_COMPILATION_MODE", "SWIFT_OPTIMIZATION_LEVEL", "SWIFT_VERSION", "ENABLE_INCREMENTAL_COMPILATION", "SWIFT_WHOLE_MODULE_OPTIMIZATION"):
        if key in settings:
            print(f"XCODE_{key}={settings[key]}")
    print(f"XCODE_{phase.upper()}_ACTIVITY_TASKS={len(tasks)}")
    print(f"XCODE_{phase.upper()}_SWIFT_FILE_TASKS={len(swift_files)}")
    if swift_files:
        for key, value in sorted(swift_files.items(), key=lambda pair: pair[1], reverse=True)[:15]:
            print(f"XCODE_{phase.upper()}_SWIFT_FILE_HASH_{key}_SECONDS={value:.3f}")
    for key, value in sorted(counters.items()):
        if re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,80}", key) and isinstance(value, (str, int, float, bool)):
            print(f"XCODE_METRIC_{key}={value}")

    summary = [
        f"### Xcode build diagnostics — {phase}",
        "",
        f"- Xcode action duration: **{duration:.3f} s**" if duration is not None else "- Xcode action duration: unavailable",
        f"- Activity task records: **{len(tasks)}**",
        f"- Distinct Swift file task IDs: **{len(swift_files)}**",
    ]
    if settings:
        summary += [f"- {key}: '{value}'" for key, value in settings.items()]
    if swift_files:
        summary += ["", "Slowest Swift file task IDs (hashed to avoid publishing private source paths):", "", "| File ID | Task duration (s) |", "|---|---:|"]
        summary += [f"| '{key}' | {value:.3f} |" for key, value in sorted(swift_files.items(), key=lambda pair: pair[1], reverse=True)[:15]]
    if counters:
        summary += ["", "Build operation counters:", ""] + [f"- {key}: {value}" for key, value in sorted(counters.items()) if re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,80}", key)]
    summary_text = "\n".join(summary) + "\n"
    print(summary_text)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as output:
            output.write(summary_text)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
