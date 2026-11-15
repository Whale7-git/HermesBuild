#!/usr/bin/env bash
# Sole GPT branch build entry point: no Release, SSH, self-hosted runner or Bark.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mode="${1:-}"
case "$mode" in source|offline|ipa) ;; *)
  echo "Usage: bash scripts/gpt-cloud-build.sh {source|offline|ipa}" >&2; exit 2 ;;
esac

require_gpt_branch() {
  local head branch_name
  head="$(git rev-parse HEAD)"
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    [[ "${GITHUB_REPOSITORY:-}" == "Whale7-git/HermesBuild" ]] || {
      echo "ERROR: unexpected GitHub repository" >&2; exit 2;
    }
    [[ "${GITHUB_EVENT_NAME:-}" == "push" &&
       "${GITHUB_REF:-}" == refs/heads/gpt/* ]] || {
      echo "ERROR: GPT build only accepts pushes to refs/heads/gpt/*" >&2; exit 2;
    }
    [[ "$head" == "${GITHUB_SHA:-}" ]] || {
      echo "ERROR: checkout SHA differs from push event SHA" >&2; exit 2;
    }
  else
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
    python3 -m unittest discover -s tests/gptcloud -p 'test_*.py' -v
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
    for tool in xcodebuild xcodegen xcrun sw_vers python3 zip shasum git; do
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
    bash scripts/gpt-cloud-toolchain.sh
    bash scripts/github-build-ipa.sh
    (cd release && shasum -a 256 -c SHA256SUMS.txt)
    python3 scripts/gpt-cloud-verify.py release "$PR_HEAD_SHA"
    echo "GPT_CANDIDATE_IPA_READY release/"
    echo "GPT_CANDIDATE_NOT_PUBLISHED"
    ;;
esac
