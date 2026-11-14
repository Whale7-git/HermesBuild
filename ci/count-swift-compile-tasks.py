#!/usr/bin/env python3
"""Count actual SwiftCompile task lines in Xcode stdout, no private paths published."""
import hashlib
import json
import re
import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit("usage: count-swift-compile-tasks.py XCODE_LOG METRICS_JSON")
log, metrics_path = map(Path, sys.argv[1:])
rows = log.read_text(encoding="utf-8", errors="replace").splitlines()
# Xcodebuild emits a task header when it executes a compilation task. This is
# intentionally distinct from xcresult activity labels (which can include
# previously cached task records).
executed = [line.strip() for line in rows
            if re.match(r"^\s*SwiftCompile\s+normal\s+", line)]
drivers = [line for line in rows
           if re.match(r"^\s*SwiftDriver\s+", line)]
emit_modules = [line for line in rows
                if re.match(r"^\s*SwiftEmitModule\s+", line)]
filenames = set()
for line in executed:
    # Xcode may group multiple Swift source files into a single compile task.
    for match in re.finditer(r"([A-Za-z0-9_+.-]+\.swift)(?=\b)", line):
        filenames.add(match.group(1))
metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
metrics["xcode_stdout_swiftcompile_task_headers"] = len(executed)
metrics["xcode_stdout_swiftdriver_task_headers"] = len(drivers)
metrics["xcode_stdout_swiftemitmodule_task_headers"] = len(emit_modules)
metrics["xcode_stdout_swift_filenames_from_task_headers"] = len(filenames)
metrics["xcode_stdout_swift_filename_hashes"] = [
    hashlib.sha256(name.encode("utf-8")).hexdigest()[:12]
    for name in sorted(filenames)
]
metrics["task_count_caveat"] = "Counts match executed xcodebuild SwiftCompile task headers; not xcresult cached activity records. A single task may compile multiple source files."
metrics_path.write_text(json.dumps(metrics, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(
    f"XCODE_SWIFT_EXECUTION mode={metrics['mode']} phase={metrics['phase']} "
    f"swiftcompile_tasks={len(executed)} swift_file_labels={len(filenames)} "
    f"swift_driver_tasks={len(drivers)} swift_emitmodule_tasks={len(emit_modules)}"
)
