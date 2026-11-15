#!/usr/bin/env bash
# GPT-owned, branch-only build entry point for HermesBuild.
# No Release, tag, signing key, Bark notification, or private runner access.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  echo "Usage: bash scripts/gpt-cloud-build.sh {source|offline|ipa}" >&2
  exit 2
}
mode="${1:-}"
case "$mode" in source|offline|ipa) ;; *) usage ;; esac

require_gpt_branch() {
  local head
  head="$(git rev-parse HEAD)"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    [[ "${GITHUB_REPOSITORY:-}" == "Whale7-git/HermesBuild" ]] || {
      echo "ERROR: unexpected repository" >&2; exit 2;
    }
    [[ "${GITHUB_EVENT_NAME:-}" == "push" && "${GITHUB_REF:-}" == refs/heads/gpt/* ]] || {
      echo "ERROR: GPT build only accepts pushes to refs/heads/gpt/*" >&2; exit 2;
    }
    [[ "$head" == "${GITHUB_SHA:-}" ]] || {
      echo "ERROR: checkout SHA differs from event SHA" >&2; exit 2;
    }
  else
    local branch_name
    branch_name="$(git symbolic-ref --quiet --short HEAD || true)"
    [[ "$branch_name" == gpt/* ]] || {
      echo "ERROR: checkout a gpt/* development branch first" >&2; exit 2;
    }
  fi
  echo "GPT_BUILD_SOURCE_SHA=$head"
}
require_gpt_branch

case "$mode" in
  source)
    python3 tests/verify_source.py
    python3 tests/sourcegate/main.py
    python3 tests/check_swiftui_modifiers.py
    python3 tests/test_swiftui_modifiers.py
    python3 -m unittest discover -s tests/releaseautomation -p 'test_*.py' -v
    echo "GPT_SOURCE_GATE_PASS"
    ;;
  offline)
    command -v swiftc >/dev/null || { echo "ERROR: swiftc is required" >&2; exit 2; }
    swift --version
    bash tests/run_container.sh
    echo "GPT_OFFLINE_PASS"
    ;;
  ipa)
    [[ -z "$(git status --porcelain)" ]] || {
      echo "ERROR: IPA build requires a clean committed tree" >&2
      git status --short >&2
      exit 2
    }
    for tool in xcodebuild xcodegen python3 zip shasum; do
      command -v "$tool" >/dev/null || { echo "ERROR: missing $tool" >&2; exit 2; }
    done
    local_temp=""
    if [[ -z "${RUNNER_TEMP:-}" ]]; then
      local_temp="$(mktemp -d)"
      export RUNNER_TEMP="$local_temp"
    fi
    cleanup() {
      if [[ -n "$local_temp" ]]; then rm -rf "$local_temp"; fi
    }
    trap cleanup EXIT
    export GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$ROOT}"
    export PR_HEAD_SHA="$(git rev-parse HEAD)"
    python3 tests/verify_source.py
    export HERMES_SOURCE_VERIFIED_SHA="$PR_HEAD_SHA"
    echo "GPT_TOOLCHAIN:"
    sw_vers
    xcodebuild -version
    xcrun --sdk iphoneos --show-sdk-version
    bash scripts/github-build-ipa.sh
    (cd release && shasum -a 256 -c SHA256SUMS.txt)
    python3 - <<'PY'
import json
import pathlib
import subprocess
root = pathlib.Path("release")
release = json.loads(pathlib.Path("release.json").read_text())
info = json.loads((root / "build-info.json").read_text())
report = json.loads((root / "validation.json").read_text())
sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
assert info["head_commit"] == sha and info["source_head_commit"] == sha
assert info["working_tree"] == "clean"
assert info["version"] == report["version"] == release["version"]
assert info["build"] == report["build"] == release["build"]
assert report["bundle"] == "com.whale7.hermes"
assert report["arch"] == "arm64" and report["unsigned"] is True
assert report["ipa"] == f'Hermes-{release["version"]}-build{release["build"]}-unsigned.ipa'
print("GPT_IPA_PROVENANCE_PASS", sha)
PY
    echo "GPT_CANDIDATE_IPA_READY release/"
    echo "GPT_CANDIDATE_NOT_PUBLISHED"
    ;;
esac
