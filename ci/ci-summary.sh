#!/usr/bin/env bash
# 写 GitHub Step Summary。
set -uo pipefail

LOGDIR="${RUNNER_LOGDIR:-/root/runner-home/logs}"
LOG="$LOGDIR/build.log"

{
  echo "## xtool IPA build (self-hosted)"
  echo ""
  echo "| item | value |"
  echo "|---|---|"
  echo "| commit | \`${GITHUB_SHA:-}\` |"
  echo "| branch | \`${GITHUB_REF_NAME:-}\` |"
  echo "| runner | self-hosted xtool |"
  if [ -f "$LOG" ]; then
    while IFS= read -r line; do
      echo "| ${line%%=*} | \`${line#*=}\` |"
    done < <(grep -E '^(RELEASE_IPA_READY|BUILD_SECONDS|IPA_SIZE|IPA_SHA256|IPA_NAME)=' "$LOG" 2>/dev/null || true)
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

echo "SUMMARY_WRITTEN"
