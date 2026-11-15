#!/usr/bin/env python3
"""Independent GPT candidate identity check. No legacy builder or network calls."""
from __future__ import annotations

import hashlib
import json
import plistlib
import re
import sys
import zipfile
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    require(isinstance(value, dict), f"{path.name} is not an object")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_candidate(output: Path, source_sha: str) -> dict:
    output = Path(output)
    require(re.fullmatch(r"[0-9a-f]{40}", source_sha) is not None,
            "source SHA must be the full 40-character commit")
    release = read_json(output.parent / "release.json")
    version, build = release["version"], release["build"]
    require(isinstance(version, str) and isinstance(build, str),
            "release version/build must be strings")
    filename = f"Hermes-{version}-build{build}-unsigned.ipa"
    ipa = output / filename
    require(ipa.is_file(), f"expected IPA missing: {filename}")
    require([p.name for p in output.glob("*.ipa")] == [filename],
            "exactly one candidate IPA is required")
    info = read_json(output / "build-info.json")
    report = read_json(output / "validation.json")
    require(info.get("working_tree") == "clean", "build source was not clean")
    require(info.get("head_commit") == source_sha
            and info.get("source_head_commit") == source_sha,
            "build-info.json does not match source commit")
    require(info.get("version") == version and str(info.get("build")) == build,
            "build-info.json version/build mismatch")
    require(report.get("ipa") == filename and report.get("version") == version
            and str(report.get("build")) == build,
            "IPA validation identity mismatch")
    require(report.get("bundle") == "com.whale7.hermes"
            and report.get("arch") == "arm64"
            and report.get("unsigned") is True
            and report.get("min_os") == "18.0",
            "IPA validation bundle, platform, or signing mismatch")
    binary_hash = sha256(ipa)
    require(report.get("sha256") == binary_hash,
            "IPA bytes differ from validation.json digest")
    provenance = report.get("build_info")
    require(isinstance(provenance, dict)
            and provenance.get("head_commit") == source_sha
            and provenance.get("info_plist_git_sha") == source_sha,
            "validation.json lacks embedded source provenance")
    with zipfile.ZipFile(ipa) as archive:
        plist_entries = [name for name in archive.namelist()
                         if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        require(len(plist_entries) == 1, "IPA must have one app Info.plist")
        app = plistlib.loads(archive.read(plist_entries[0]))
    require(app.get("HermesGitSHA") == source_sha,
            "IPA embedded HermesGitSHA differs from pushed commit")
    require(app.get("CFBundleIdentifier") == "com.whale7.hermes"
            and app.get("CFBundleShortVersionString") == version
            and app.get("CFBundleVersion") == build,
            "IPA embedded identity or version mismatch")

    expected = {filename, "build-info.json", "validation.json"}
    lines = (output / "SHA256SUMS.txt").read_text(encoding="utf-8").splitlines()
    checksums = {}
    for line in lines:
        item = re.fullmatch(r"([0-9a-f]{64})  ([^\s/]+)", line)
        require(item is not None, "malformed SHA256SUMS entry")
        digest, name = item.groups()
        require(name not in checksums, "duplicate SHA256SUMS entry")
        checksums[name] = digest
    require(set(checksums) == expected, "SHA256SUMS file inventory mismatch")
    for name, digest in checksums.items():
        require(sha256(output / name) == digest, f"checksum mismatch: {name}")
    return {
        "commit": source_sha, "version": version, "build": build,
        "bundle": "com.whale7.hermes", "arch": "arm64",
        "unsigned": True, "ipa": filename, "sha256": binary_hash
    }


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("Usage: python3 scripts/gpt-cloud-verify.py release <full-commit-sha>", file=sys.stderr)
        return 2
    try:
        result = verify_candidate(Path(argv[1]), argv[2])
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(f"GPT_IPA_VERIFY_FAILED: {error}", file=sys.stderr)
        return 1
    print("GPT_IPA_PROVENANCE_PASS", result["commit"])
    print("GPT_IPA_SHA256", result["sha256"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
