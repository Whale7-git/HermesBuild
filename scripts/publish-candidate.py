#!/usr/bin/env python3
"""Promote one verified candidate artifact into an immutable GitHub Release."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("verify_candidate", ROOT / "scripts" / "verify-candidate.py")
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


def require(condition: object, message: str) -> None:
    if not condition:
        raise ValueError(message)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class GitHub:
    def __init__(self, repository: str):
        self.repository = repository

    def api(self, path: str, method: str = "GET", data: object = None, missing: bool = False):
        args = ["gh", "api", "--include", "--method", method, f"repos/{self.repository}/{path}"]
        if data is not None:
            args.extend(["--input", "-"])
        result = subprocess.run(
            args,
            input=json.dumps(data) if data is not None else None,
            text=True,
            capture_output=True,
        )
        header, separator, body = result.stdout.partition("\n\n")
        match = re.search(r"^HTTP/\S+ (\d+)", header)
        status = int(match.group(1)) if match else 0
        if status == 404 and missing:
            return None
        if result.returncode or not 200 <= status < 300 or not separator:
            raise RuntimeError(f"GitHub {method} {path} failed (HTTP {status})")
        return json.loads(body) if body.strip() else None

    def upload(self, tag: str, paths: list[Path]) -> None:
        subprocess.run(
            ["gh", "release", "upload", tag, "--repo", self.repository, *map(str, paths)],
            check=True,
        )

    def download(self, asset: dict, destination: Path) -> None:
        with destination.open("wb") as output:
            subprocess.run(
                [
                    "gh", "api", "-H", "Accept: application/octet-stream",
                    f"repos/{self.repository}/releases/assets/{asset['id']}",
                ],
                stdout=output,
                check=True,
            )


def verify_artifact(client: GitHub, selected: dict) -> None:
    artifact = client.api(f"actions/artifacts/{selected['artifact_id']}")
    require(artifact.get("name") == selected["artifact_name"], "artifact name changed")
    require(artifact.get("digest") == selected["artifact_digest"], "artifact digest changed")
    require(artifact.get("expired") is False, "candidate artifact expired")
    run = client.api(f"actions/runs/{selected['run_id']}")
    require(run.get("conclusion") == "success", "candidate workflow is not successful")
    require(run.get("head_sha") == selected["candidate_head_sha"],
            "candidate run head changed")
    require(run.get("path") == ".github/workflows/hermesshell-single-build.yml",
            "candidate workflow path changed")


def marker(selected: dict, candidate: dict) -> str:
    return "\n".join([
        f"Main commit: {selected['main_sha']}",
        f"Main tree: {selected['main_tree']}",
        f"PR head commit: {selected['candidate_head_sha']}",
        f"Candidate build commit: {candidate['commit']}",
        f"Candidate tree: {selected['candidate_tree']}",
        f"Producer run: {selected['run_id']}",
        f"Producer attempt: {selected['run_attempt']}",
        f"Artifact ID: {selected['artifact_id']}",
        f"Artifact digest: {selected['artifact_digest']}",
        f"Pull request: {selected['pr_number']}",
    ])


def preflight(
    client: GitHub,
    selected: dict,
    candidate: dict,
    candidate_dir: Path,
) -> dict | None:
    tag = selected["tag"]
    release = client.api(f"releases/tags/{quote(tag)}", missing=True)
    if release is None:
        require(client.api(f"git/ref/tags/{quote(tag)}", missing=True) is None,
                "release tag already exists")
        return None
    require(marker(selected, candidate) in (release.get("body") or ""),
            "release belongs to another candidate")
    if release.get("draft") is False:
        verify_remote(client, release, {
            path.name: path for path in candidate_dir.iterdir()
            if path.is_file() and path.name != "SHA256SUMS.txt"
        })
        ref = client.api(f"git/ref/tags/{quote(tag)}")
        obj = ref["object"]
        if obj.get("type") == "tag":
            obj = client.api(f"git/tags/{obj['sha']}")["object"]
        require(obj.get("type") == "commit" and obj.get("sha") == selected["main_sha"],
                "published release tag does not point to the selected main commit")
        return release
    require(release.get("target_commitish") == selected["main_sha"],
            "draft targets another main commit")
    return release


def verify_remote(client: GitHub, release: dict, paths: dict[str, Path]) -> None:
    assets = release.get("assets", [])
    require(len(assets) == len(paths) and {a["name"] for a in assets} == set(paths),
            "remote release assets are incomplete or unexpected")
    with tempfile.TemporaryDirectory(prefix="hermes-promote-") as temp:
        for asset in assets:
            original = paths[asset["name"]]
            require(asset.get("size") == original.stat().st_size, "remote asset size mismatch")
            downloaded = Path(temp) / asset["name"]
            client.download(asset, downloaded)
            require(digest(downloaded) == digest(original), "remote asset digest mismatch")


def publish(client: GitHub, selected: dict, candidate: dict, candidate_dir: Path) -> str:
    tag = selected["tag"]
    release = preflight(client, selected, candidate, candidate_dir)
    if release is None:
        body = (
            marker(selected, candidate)
            + "\n\nUnsigned iPhoneOS arm64 IPA promoted from the verified PR candidate. "
              "Formal publication did not recompile the app."
        )
        release = client.api(
            "releases",
            "POST",
            {
                "tag_name": tag,
                "target_commitish": selected["main_sha"],
                "name": tag,
                "draft": True,
                "prerelease": False,
                "body": body,
            },
        )
    elif release.get("draft") is False:
        return release["html_url"]

    paths = {
        path.name: path for path in candidate_dir.iterdir()
        if path.is_file() and path.name != "SHA256SUMS.txt"
    }
    existing = release.get("assets", [])
    require(len({asset["name"] for asset in existing}) == len(existing),
            "draft contains duplicate assets")
    require(all(asset["name"] in paths for asset in existing),
            "draft contains unexpected assets")
    verify_remote(client, release, {asset["name"]: paths[asset["name"]] for asset in existing})
    pending = [paths[name] for name in sorted(set(paths) - {a["name"] for a in existing})]
    if pending:
        client.upload(tag, pending)

    staged = client.api(f"releases/{release['id']}")
    require(staged.get("draft") is True and staged.get("target_commitish") == selected["main_sha"],
            "draft identity changed")
    verify_remote(client, staged, paths)
    client.api(f"releases/{release['id']}", "PATCH",
               {"draft": False, "prerelease": False, "make_latest": "legacy"})
    official = client.api(f"releases/{release['id']}")
    require(official.get("draft") is False and official.get("prerelease") is False,
            "release did not become official")
    ref = client.api(f"git/ref/tags/{quote(tag)}")
    obj = ref["object"]
    if obj.get("type") == "tag":
        obj = client.api(f"git/tags/{obj['sha']}")["object"]
    require(obj.get("type") == "commit" and obj.get("sha") == selected["main_sha"],
            "release tag does not point to the main commit")
    verify_remote(client, official, paths)
    return official["html_url"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("candidate_dir", type=Path)
    parser.add_argument("selection", type=Path)
    args = parser.parse_args()
    selected = json.loads(args.selection.read_text(encoding="utf-8"))
    require(os.environ.get("GITHUB_REPOSITORY") == "Whale7-git/HermesBuild",
            "promotion requires Whale7-git/HermesBuild")
    require(os.environ.get("GITHUB_EVENT_NAME") == "push"
            and os.environ.get("GITHUB_REF") == "refs/heads/main",
            "promotion requires a main push")
    require(os.environ.get("GITHUB_SHA") == selected["main_sha"],
            "workflow SHA differs from selected main commit")
    root_tree = subprocess.check_output(
        ["git", "rev-parse", "HEAD^{tree}"], text=True, cwd=ROOT
    ).strip()
    require(root_tree == selected["main_tree"], "checkout tree differs from selected main tree")
    result = VERIFY.verify_candidate(args.candidate_dir, selected["main_tree"])
    require((result["version"], result["build"]) == (selected["version"], selected["build"]),
            "candidate release identity mismatch")
    require(result["producer_run_id"] == selected["run_id"], "candidate producer run mismatch")
    require(result["producer_run_attempt"] == str(selected["run_attempt"]),
            "candidate producer run attempt mismatch")
    require(result["producer_event"] == "pull_request",
            "candidate was not produced by a pull request")
    client = GitHub(os.environ["GITHUB_REPOSITORY"])
    verify_artifact(client, selected)
    try:
        url = publish(client, selected, result, args.candidate_dir)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"CANDIDATE_PROMOTION_FAILED: {error}", file=sys.stderr)
        return 1
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
            stream.write(f"url={url}\n")
    print(f"RELEASE_PROMOTED version={selected['version']} build={selected['build']} url={url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
