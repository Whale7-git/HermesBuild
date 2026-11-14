#!/usr/bin/env bash
# 执行构建：调用仓库自带的 scripts/release-local.sh。
# CI uses HERMES_CI_COMPILE_ONLY=1 to defer full source/offline regression until
# after GitHub Release and Bark. Local/manual builds still run all tests by default.
# Build lock, toolchain, iPhoneOS compile, IPA validation and SHA256 remain mandatory.
#
# Supply an optional proxy through PROXY in the local runner environment.
# Machine identity and proxy URLs are never printed.
set -euo pipefail

WS="${CI_WORKSPACE:-/work/.hermes-ci-workspace}"
export HOME="${RUNNER_HOME:-/root/runner-home}"
export TMPDIR="${RUNNER_TMPDIR:-$HOME/tmp}"
export PROXY="${PROXY:-}"
mkdir -p "$TMPDIR"

echo "=== 构建环境 ==="
echo "Configured build workspace ready"
echo "--- SDK ---"
xtool sdk status 2>&1 | head -4
echo "--- 工具链 ---"
xtool --version
swift --version 2>&1 | head -2

echo "--- 代理连通性（SwiftPM 依赖更新需要）---"
if [[ -z "$PROXY" ]]; then
  echo "Using direct network access"
elif curl -s -m 12 --proxy "$PROXY" -o /dev/null -w 'github.com http=%{http_code} t=%{time_total}s\n' https://github.com/; then
  :
else
  echo "::warning::代理不可达，SwiftPM 若需联网将失败（缓存命中时不影响）"
fi

cd "$WS"

# xtool 检测 isatty，必须给真 PTY；script -e 让退出码透传。
# 注意：release-local.sh 内部会 flock /work/.hermes-ios-release.lock，
# 因此 CI 构建与人工构建天然互斥，不会互相破坏缓存。
# 透传的变量：
#  - HERMES_CI_COMPILE_ONLY：GitHub 正式构建时为 1，推迟完整回归。
#  - HERMES_CI_DETACH_TESTS：本地完整回归模式的可选 PTY 隔离开关。
#  - http(s)_proxy / no_proxy：SwiftPM 更新依赖时走代理，内网与 loopback 直连。
echo "=== 调用 release-local.sh ==="
exec script -qec "cd '$WS' && \
  export HOME='$HOME' TMPDIR='$TMPDIR' \
    HERMES_CI_COMPILE_ONLY='${HERMES_CI_COMPILE_ONLY:-0}' \
    HERMES_CI_DETACH_TESTS='${HERMES_CI_DETACH_TESTS:-}' \
    http_proxy='$PROXY' https_proxy='$PROXY' \
    HTTP_PROXY='$PROXY' HTTPS_PROXY='$PROXY' \
    no_proxy='localhost,127.0.0.1' \
    NO_PROXY='localhost,127.0.0.1' && \
  bash scripts/release-local.sh" /dev/null
