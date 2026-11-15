#!/usr/bin/env python3
"""Prepare deterministic inputs for the manual macOS cache experiment."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys


FIXED_EPOCH_NS = 946684800_000_000_000  # 2000-01-01T00:00:00Z
IGNORED_DIRECTORIES = {
    ".git",
    ".build",
    ".bsp",
    "DerivedData",
    "HermesShellCI.xcodeproj",
    "outputs",
    "release",
    "releases",
    "xtool",
    "__pycache__",
}


def tracked_files(root: Path) -> list[Path]:
    output = subprocess.check_output(
        ["git", "ls-files", "-z"],
        cwd=root,
    )
    files: list[Path] = []
    for raw in output.split(b"\0"):
        if not raw:
            continue
        relative = Path(raw.decode("utf-8"))
        if any(part in IGNORED_DIRECTORIES for part in relative.parts):
            continue
        path = root / relative
        if path.is_file():
            files.append(path)
    return files


def prepared_project_files(project: Path) -> list[Path]:
    files = sorted(path for path in project.rglob("*") if path.is_file())
    if not files:
        raise SystemExit(f"generated Xcode project has no files: {project}")
    return files


def write_plist(root: Path, destination: Path) -> None:
    release = plistlib.loads((root / "Resources" / "Info.plist").read_bytes())
    info = dict(release)
    info.update(
        {
            "CFBundleIdentifier": "com.whale7.hermes",
            "CFBundleExecutable": "HermesShell",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "MinimumOSVersion": "18.0",
        }
    )
    destination.write_bytes(plistlib.dumps(info, sort_keys=False))


def prepare(root: Path) -> tuple[list[Path], Path, str]:
    runner_temp = Path(os.environ.get("RUNNER_TEMP", "")).resolve()
    if not runner_temp.is_dir():
        raise SystemExit("RUNNER_TEMP must name an existing directory")
    project = root / "HermesShellCI.xcodeproj"
    plist = runner_temp / "HermesCI-Info.plist"

    subprocess.run(
        ["xcodegen", "generate", "--spec", "ios-ci-project.yml"],
        cwd=root,
        check=True,
    )
    write_plist(root, plist)

    inputs = tracked_files(root)
    inputs.extend(prepared_project_files(project))
    inputs.append(plist)
    for path in inputs:
        mode = path.lstat().st_mode
        if not stat.S_ISREG(mode):
            raise SystemExit(f"benchmark input is not a regular file: {path}")
        os.utime(path, ns=(FIXED_EPOCH_NS, FIXED_EPOCH_NS), follow_symlinks=False)
    for directory in sorted(
        {path.parent for path in inputs}
        | {path for path in project.rglob("*") if path.is_dir()},
        key=lambda path: len(path.parts),
        reverse=True,
    ):
        os.utime(directory, ns=(FIXED_EPOCH_NS, FIXED_EPOCH_NS))
    os.utime(project, ns=(FIXED_EPOCH_NS, FIXED_EPOCH_NS))

    rows: list[str] = []
    for path in sorted(inputs, key=lambda item: str(item)):
        metadata = path.lstat()
        try:
            display = path.relative_to(root).as_posix()
        except ValueError:
            display = "<runner-temp>/" + path.name
        content_sha = hashlib.sha256(path.read_bytes()).hexdigest()
        rows.append(
            f"{display}\tfile\t{metadata.st_mode & 0o777:o}\t"
            f"{metadata.st_size}\t{metadata.st_mtime_ns}\t{content_sha}\n"
        )
    manifest = runner_temp / "hermes-cache-inputs.tsv"
    manifest.write_text("".join(rows), encoding="utf-8")
    digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
    (runner_temp / "hermes-cache-input-sha256.txt").write_text(
        digest + "\n",
        encoding="ascii",
    )
    return inputs, manifest, digest


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else Path.cwd()
    _, manifest, digest = prepare(root)
    print(f"CACHE_INPUT_MANIFEST={manifest}")
    print(f"CACHE_INPUT_SHA256={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
