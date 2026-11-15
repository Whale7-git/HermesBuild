#!/usr/bin/env python3
"""Validate one immutable HermesBuild candidate artifact directory."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition: object, message: str) -> None:
    if not condition:
        raise ValueError(message)


def verify_candidate(directory: Path, expected_tree: str | None = None) -> dict:
    require(directory.is_dir(), f"candidate directory not found: {directory}")
    manifest_path = directory / "candidate-manifest.json"
    require(manifest_path.is_file(), "candidate-manifest.json is required")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    require(manifest.get("schema_version") == 1, "unsupported candidate manifest schema")

    release = manifest.get("release") or {}
    version, build, ipa_name = release.get("version"), release.get("build"), release.get("ipa")
    require(isinstance(version, str) and re.fullmatch(r"\d+\.\d+\.\d+", version),
            "candidate version is invalid")
    require(isinstance(build, str) and re.fullmatch(r"[1-9]\d*", build),
            "candidate build is invalid")
    require(ipa_name == f"Hermes-{version}-build{build}-unsigned.ipa",
            "candidate IPA name does not match its release identity")
    expected_names = {
        ipa_name,
        "build-info.json",
        "validation.json",
        "candidate-manifest.json",
        "SHA256SUMS.txt",
    }
    actual_names = {path.name for path in directory.iterdir() if path.is_file()}
    require(actual_names == expected_names,
            f"candidate files differ: expected={sorted(expected_names)} actual={sorted(actual_names)}")
    require(not any(path.is_symlink() for path in directory.iterdir()),
            "candidate files must not be symlinks")

    source = manifest.get("source") or {}
    tree = source.get("tree")
    require(isinstance(tree, str) and re.fullmatch(r"[0-9a-f]{40}", tree),
            "candidate source tree is invalid")
    require(source.get("working_tree") == "clean", "candidate source tree was dirty")
    if expected_tree is not None:
        require(tree == expected_tree,
                f"candidate tree {tree} does not match expected tree {expected_tree}")

    build_info = json.loads((directory / "build-info.json").read_text(encoding="utf-8"))
    require(build_info.get("version") == version and build_info.get("build") == build,
            "build-info release identity mismatch")
    require(build_info.get("source_tree") == tree and build_info.get("head_tree") == tree,
            "build-info source tree mismatch")
    require(build_info.get("source_head_commit") == source.get("commit")
            and build_info.get("head_commit") == source.get("commit"),
            "build-info source commit mismatch")
    require(build_info.get("working_tree") == "clean", "build-info working tree was dirty")

    checksums: dict[str, str] = {}
    for line in (directory / "SHA256SUMS.txt").read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64}) [ *]([^/\\]+)", line)
        require(match is not None, "invalid SHA256SUMS entry")
        name, value = match.group(2), match.group(1)
        require(name not in checksums, f"duplicate checksum entry: {name}")
        checksums[name] = value
    require(set(checksums) == expected_names - {"SHA256SUMS.txt"},
            "SHA256SUMS must cover every candidate file except itself")
    for name, expected in checksums.items():
        require(digest(directory / name) == expected, f"checksum mismatch: {name}")

    declared = manifest.get("files") or {}
    expected_declared = {
        name: checksums[name]
        for name in (ipa_name, "build-info.json", "validation.json")
    }
    require(declared == expected_declared,
            "candidate manifest file digests do not match SHA256SUMS")

    producer = manifest.get("producer") or {}
    require(isinstance(producer.get("run_id"), str)
            and re.fullmatch(r"[1-9]\d*", producer["run_id"]) is not None,
            "candidate producer run ID is invalid")
    require(isinstance(producer.get("run_attempt"), str)
            and re.fullmatch(r"[1-9]\d*", producer["run_attempt"]) is not None,
            "candidate producer run attempt is invalid")
    require(producer.get("event") in {"pull_request", "workflow_dispatch"},
            "candidate producer event is invalid")
    require(producer.get("workflow_path") ==
            ".github/workflows/hermesshell-single-build.yml",
            "candidate producer workflow path is invalid")
    require(isinstance(producer.get("workflow_blob_sha"), str)
            and re.fullmatch(r"[0-9a-f]{40}", producer["workflow_blob_sha"]) is not None,
            "candidate producer workflow blob SHA is invalid")

    validation = json.loads((directory / "validation.json").read_text(encoding="utf-8"))
    require(validation.get("ipa") == ipa_name, "IPA validation name mismatch")
    require((validation.get("version"), validation.get("build")) == (version, build),
            "IPA validation release identity mismatch")
    require(validation.get("bundle") == "com.whale7.hermes", "IPA bundle ID mismatch")
    require(validation.get("arch") == "arm64" and validation.get("unsigned") is True,
            "IPA must be unsigned arm64")
    require(validation.get("sha256") == checksums[ipa_name], "IPA digest mismatch")

    return {
        "version": version,
        "build": build,
        "tag": release.get("tag"),
        "commit": source.get("commit"),
        "tree": tree,
        "ipa": ipa_name,
        "ipa_sha256": checksums[ipa_name],
        "producer_run_id": producer["run_id"],
        "producer_run_attempt": producer["run_attempt"],
        "producer_event": producer["event"],
        "producer_workflow_blob_sha": producer["workflow_blob_sha"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--expected-tree")
    args = parser.parse_args()
    try:
        result = verify_candidate(args.directory, args.expected_tree)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"CANDIDATE_VERIFICATION_FAILED: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
