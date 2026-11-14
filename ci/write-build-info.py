#!/usr/bin/env python3
"""记录产物与源码的对应关系，生成 releases/build-info.json。

CI 不 bump 版本：version/build 一律来自源码里的 release.json，
这里只负责把「这份 IPA 是由哪个 commit 编译出来的」固化下来。

字段契约（tests/verify_ipa.py 的 check_build_info 与
ci/publish-direct-release.sh 都会校验，改动前先读这两处）：
  - version / build      必须与 release.json 一致
  - working_tree         必须为 "clean"
  - head_commit          非空；若 Info.plist 有 HermesGitSHA 必须相等
  - source_head_commit   发布脚本要求等于被验证的源码 commit
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone


def git(*args: str) -> str:
    """跑 git 并返回 stdout；失败返回空串（不抛异常）。"""
    try:
        out = subprocess.run(
            ["git", *args], capture_output=True, text=True, timeout=15, check=False,
        )
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def resolve_commit() -> tuple[str, str]:
    """返回 (commit, 来源标记)。CI 优先用 GITHUB_SHA。"""
    env_sha = os.environ.get("GITHUB_SHA", "").strip()
    if env_sha:
        return env_sha, "GITHUB_SHA"
    sha = git("rev-parse", "HEAD")
    if sha:
        return sha, "git-rev-parse (local run, not CI)"
    return "", "unavailable"


def resolve_working_tree() -> str:
    """已跟踪文件是否干净。发布门禁要求 'clean'。

    构建产物（.build/releases/xtool）不在版本控制内，git status --porcelain
    对它们默认会报 untracked，所以用 --untracked-files=no 只看已跟踪文件，
    否则任何一次构建都会被误判成 dirty。
    """
    porcelain = git("status", "--porcelain", "--untracked-files=no")
    return "clean" if porcelain == "" else "dirty"


def main() -> int:
    if len(sys.argv) != 5:
        print("usage: write-build-info.py <version> <build> <size> <sha256>", file=sys.stderr)
        return 2
    version, build, size, sha = sys.argv[1:5]

    commit, commit_source = resolve_commit()
    if not commit:
        print("::error::无法确定源码 commit，拒绝写出不完整的 build-info.json", file=sys.stderr)
        return 1

    working_tree = resolve_working_tree()

    info = {
        "version": version,
        "build": build,
        "head_commit": commit,
        "source_head_commit": commit,
        "head_commit_source": commit_source,
        "working_tree": working_tree,
        "head_branch": os.environ.get("GITHUB_REF_NAME", ""),
        "run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
        "repository": os.environ.get("GITHUB_REPOSITORY", ""),
        "ipa_filename": f"Hermes-{version}-build{build}-unsigned.ipa",
        "ipa_size_bytes": int(size),
        "ipa_sha256": sha,
        "builder": "self-hosted xtool",
        "workflow": "xtool-build.yml",
        "built_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    os.makedirs("releases", exist_ok=True)
    with open("releases/build-info.json", "w", encoding="utf-8") as fh:
        json.dump(info, fh, indent=2)
    print(json.dumps(info, indent=2))

    if working_tree != "clean":
        print("::error::工作树不干净，发布门禁会拒绝", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
