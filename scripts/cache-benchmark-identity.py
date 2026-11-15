#!/usr/bin/env python3
"""Generate and validate the deterministic cache namespace."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def digest_paths(paths: list[Path], root: Path = ROOT) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        data = path.read_bytes()
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


def command(*args: str, root: Path = ROOT) -> str:
    return subprocess.check_output(args, cwd=root, text=True).strip()


def safe_component(value: str) -> str:
    return "".join(
        character if character.isalnum() or character in "._-" else "-"
        for character in value
    ).strip("-")


def identity(root: Path = ROOT) -> str:
    project_dir = root / "HermesShellCI.xcodeproj"
    xcodegen = ["xcodegen", "generate", "--spec", "ios-ci-project.yml"]
    subprocess.run(xcodegen, cwd=root, check=True)
    first = digest_paths(
        [
            project_dir / "project.pbxproj",
            *sorted(
                path
                for path in (project_dir / "xcshareddata").rglob("*")
                if path.is_file()
            ),
        ],
        root,
    )
    subprocess.run(xcodegen, cwd=root, check=True)
    second = digest_paths(
        [
            project_dir / "project.pbxproj",
            *sorted(
                path
                for path in (project_dir / "xcshareddata").rglob("*")
                if path.is_file()
            ),
        ],
        root,
    )
    if first != second:
        raise SystemExit("XcodeGen output is not deterministic")

    dependency_files = [root / "Package.swift", root / "Package.resolved"]
    dependency_files += [
        path
        for path in (root / "Vendor" / "Textual").rglob("*")
        if path.is_file()
    ]
    deps = digest_paths(dependency_files, root)
    macos = command("sw_vers", "-productVersion", root=root)
    xcode = command("xcodebuild", "-version", root=root).replace("\n", "-")
    sdk = command("xcrun", "--sdk", "iphoneos", "--show-sdk-version", root=root)
    sdk_build = command(
        "xcrun", "--sdk", "iphoneos", "--show-sdk-build-version", root=root
    )
    architecture = command("uname", "-m", root=root)
    namespace = (
        f"hermes-derived-v1-macos{safe_component(macos)}"
        f"-xcode{safe_component(xcode)}-sdk{safe_component(sdk)}"
        f"-sdkbuild{safe_component(sdk_build)}-arch{safe_component(architecture)}"
        f"-Release"
        f"-project{first}-deps{deps}"
    )
    return namespace


def main() -> int:
    namespace = identity()
    expected = os.environ.get("EXPECTED_NAMESPACE")
    if expected is not None and expected != namespace:
        raise SystemExit(
            f"cache namespace differs: expected {expected}, got {namespace}"
        )

    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(f"namespace={namespace}\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as stream:
            stream.write(f"- Cache namespace: `{namespace}`\n")
    print(namespace)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
