#!/usr/bin/env python3
"""Select the immutable candidate produced for a merged HermesBuild PR."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys


REPOSITORY = "Whale7-git/HermesBuild"
WORKFLOW_PATH = ".github/workflows/hermesshell-single-build.yml"


class GitHub:
    def __init__(self, repository: str):
        self.repository = repository

    def api(self, path: str, missing: bool = False) -> object:
        result = subprocess.run(
            ["gh", "api", "--include", f"repos/{self.repository}/{path}"],
            text=True,
            capture_output=True,
        )
        header, separator, body = result.stdout.partition("\n\n")
        match = re.search(r"^HTTP/\S+ (\d+)", header)
        status = int(match.group(1)) if match else 0
        if status == 404 and missing:
            return None
        if result.returncode or not 200 <= status < 300 or not separator:
            raise RuntimeError(f"GitHub API {path} failed (HTTP {status})")
        return json.loads(body) if body.strip() else None


def require(condition: object, message: str) -> None:
    if not condition:
        raise ValueError(message)


def release_identity(root: Path) -> tuple[str, str, str]:
    meta = json.loads((root / "release.json").read_text(encoding="utf-8"))
    version, build = meta.get("version"), meta.get("build")
    require(isinstance(version, str) and re.fullmatch(r"\d+\.\d+\.\d+", version),
            "invalid release version")
    require(isinstance(build, str) and re.fullmatch(r"[1-9]\d*", build),
            "invalid release build")
    return version, build, f"release-{version}-build{build}"


def select_candidate(client: GitHub, main_sha: str, root: Path) -> dict:
    version, build, tag = release_identity(root)
    commit = client.api(f"git/commits/{main_sha}")
    main_tree = (commit.get("tree") or {}).get("sha")
    require(isinstance(main_tree, str), "main commit has no tree")

    pulls = client.api(f"commits/{main_sha}/pulls")
    merged = [
        pull for pull in pulls
        if pull.get("merged_at")
        and (pull.get("base") or {}).get("ref") == "main"
        and pull.get("merge_commit_sha") == main_sha
    ]
    require(len(merged) == 1, f"expected one merged PR for main commit, got {len(merged)}")
    pull = merged[0]
    head_sha = (pull.get("head") or {}).get("sha")
    require(isinstance(head_sha, str) and re.fullmatch(r"[0-9a-f]{40}", head_sha),
            "merged PR has no valid head SHA")
    runs_payload = client.api(
        f"actions/runs?head_sha={head_sha}&per_page=100"
    )
    expected_name = f"hermes-candidate-{version}-build{build}-tree{main_tree}"
    merged_at = pull["merged_at"]
    candidates = []
    for run in runs_payload.get("workflow_runs", []):
        if (run.get("event") != "pull_request"
                or run.get("path") != WORKFLOW_PATH or run.get("conclusion") != "success"
                or run.get("head_sha") != head_sha or run.get("created_at", "") > merged_at):
            continue
        artifacts = client.api(
            f"actions/runs/{run['id']}/artifacts?per_page=100"
        ).get("artifacts", [])
        matching = [
            artifact for artifact in artifacts
            if artifact.get("name") == expected_name
            and artifact.get("expired") is False
            and (artifact.get("workflow_run") or {}).get("head_sha") == head_sha
        ]
        if matching:
            require(len(matching) == 1,
                    "one candidate workflow run produced duplicate immutable artifacts")
            candidates.append((run, matching[0]))

    require(candidates, "no successful immutable candidate artifact found for merged PR")
    candidates.sort(key=lambda pair: (pair[0].get("created_at", ""), pair[0]["id"]))
    run, artifact = candidates[-1]
    artifact_digest = artifact.get("digest")
    require(isinstance(artifact_digest, str) and artifact_digest.startswith("sha256:"),
            "candidate artifact has no immutable digest")
    require(artifact.get("workflow_run", {}).get("id") == run["id"],
            "artifact workflow run mismatch")

    return {
        "repository": client.repository,
        "main_sha": main_sha,
        "main_tree": main_tree,
        "candidate_head_sha": head_sha,
        "candidate_tree": main_tree,
        "version": version,
        "build": build,
        "tag": tag,
        "pr_number": pull["number"],
        "merged_at": merged_at,
        "run_id": run["id"],
        "run_attempt": run.get("run_attempt"),
        "artifact_id": artifact["id"],
        "artifact_name": artifact["name"],
        "artifact_digest": artifact_digest,
    }


def main() -> int:
    repository = os.environ.get("GITHUB_REPOSITORY", REPOSITORY)
    require(repository == REPOSITORY, "candidate promotion requires Whale7-git/HermesBuild")
    main_sha = os.environ.get("GITHUB_SHA", "")
    require(re.fullmatch(r"[0-9a-f]{40}", main_sha) is not None,
            "GITHUB_SHA must be a full lowercase commit SHA")
    root = Path(__file__).resolve().parents[1]
    try:
        result = select_candidate(GitHub(repository), main_sha, root)
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"CANDIDATE_SELECTION_FAILED: {error}", file=sys.stderr)
        return 1
    output = Path(os.environ["GITHUB_OUTPUT"])
    with output.open("a", encoding="utf-8") as stream:
        for key, value in result.items():
            stream.write(f"{key}={value}\n")
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
