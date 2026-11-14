#!/usr/bin/env bash
# 运行构建并记录耗时/日志。失败时输出诊断尾部并透传退出码。
set -euo pipefail

WS="${CI_WORKSPACE:-/work/.hermes-ci-workspace}"
LOGDIR="${RUNNER_LOGDIR:-/root/runner-home/logs}"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/build.log"
: > "$LOG"

START=$(date +%s)
set +e
bash "$WS/ci/ci-build.sh" 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
set -e
END=$(date +%s)
DURATION=$((END - START))

echo "BUILD_SECONDS=$DURATION" | tee -a "$LOG"

if [ "$RC" -ne 0 ]; then
  echo "::error::构建失败 rc=$RC 用时 ${DURATION}s"
  echo "=== 诊断：最后 80 行 ==="
  tail -80 "$LOG"
  exit "$RC"
fi

if ! grep -qE '^RELEASE_IPA_READY' "$LOG"; then
  echo "::error::构建脚本未输出 RELEASE_IPA_READY（不能仅凭退出码判定成功）"
  tail -40 "$LOG"
  exit 1
fi

echo "BUILD_OK"
