#!/usr/bin/env python3
"""Generate and validate the deterministic cache namespace."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import plistlib
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
    project_files = [
        project_dir / "project.pbxproj",
        *sorted(
            path
            for path in (project_dir / "xcshareddata").rglob("*")
            if path.is_file()
        ),
    ]
    if not all(path.is_file() for path in project_files):
        raise SystemExit(
            "prepared Xcode project is incomplete; run cache-benchmark-prepare.py first"
        )
    project_digest = digest_paths(project_files, root)
    manifest_path = Path(
        os.environ.get("RUNNER_TEMP", "")
    ) / "hermes-cache-input-sha256.txt"
    if not manifest_path.is_file():
        raise SystemExit(
            "cache input manifest is absent; run cache-benchmark-prepare.py first"
        )
    input_manifest = manifest_path.read_text(encoding="ascii").strip()
    if len(input_manifest) != 64:
        raise SystemExit("cache input manifest digest is malformed")
    prepared_plist = Path(os.environ["RUNNER_TEMP"]) / "HermesCI-Info.plist"
    if not prepared_plist.is_file():
        raise SystemExit("prepared CI Info.plist is absent")
    info = plistlib.loads(prepared_plist.read_bytes())
    release = plistlib.loads((root / "Resources" / "Info.plist").read_bytes())
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if info.get(key) != release.get(key):
            raise SystemExit(f"prepared CI Info.plist {key} differs from source")
    if info.get("CFBundleIdentifier") != "com.whale7.hermes":
        raise SystemExit("prepared CI Info.plist bundle identifier differs")
    fixed_epoch_ns = "946684800000000000"
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
    if project_digest != second:
        raise SystemExit("prepared Xcode project changed while computing identity")

    dependency_files = [root / "Package.swift", root / "Package.resolved"]
    if not all(path.is_file() for path in dependency_files):
        raise SystemExit("Package.swift and Package.resolved must both exist")
    dependency_files += [
        path
        for path in (root / "Vendor" / "Textual").rglob("*")
        if path.is_file() and not (
            "__pycache__" in path.parts or path.suffix == ".pyc"
        )
    ]
    deps = digest_paths(dependency_files, root)
    macos = command("sw_vers", "-productVersion", root=root)
    xcode = command("xcodebuild", "-version", root=root).replace("\n", "-")
    sdk = command("xcrun", "--sdk", "iphoneos", "--show-sdk-version", root=root)
    sdk_build = command(
        "xcrun", "--sdk", "iphoneos", "--show-sdk-build-version", root=root
    )
    architecture = command("uname", "-m", root=root)
    swift = command("xcrun", "swift", "--version", root=root).replace("\n", "-")
    xcodegen = command("xcodegen", "--version", root=root)
    image_os = os.environ.get("ImageOS", "unknown")
    image_version = os.environ.get("ImageVersion", "unknown")
    namespace = (
        f"hermes-derived-v2-macos{safe_component(macos)}"
        f"-xcode{safe_component(xcode)}-sdk{safe_component(sdk)}"
        f"-sdkbuild{safe_component(sdk_build)}-arch{safe_component(architecture)}"
        f"-swift{safe_component(swift)}-xcodegen{safe_component(xcodegen)}"
        f"-image{safe_component(image_os)}-imageversion{safe_component(image_version)}"
        f"-Release-mtime{fixed_epoch_ns}"
        f"-inputs{input_manifest}"
        f"-project{project_digest}-deps{deps}"
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
