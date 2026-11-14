#!/usr/bin/env bash
# CI 预检：确认 runner 身份、工具链、缓存源。只读，不修改任何状态。
set -euo pipefail

echo "=== runner 身份 ==="
echo "Checking configured xtool runner"

# HOME 必须指向 /root/runner-home（挂载卷），否则 xtool 找不到
# .swiftpm/swift-sdks/darwin.artifactbundle，会误判 SDK 未安装。
export HOME="${RUNNER_HOME:-/root/runner-home}"
# xtool 是 AppImage：解压目录取 TMPDIR，必须可写，
# 否则报 "mkdir_p error: Permission denied / Failed to extract AppImage"。
export TMPDIR="${RUNNER_TMPDIR:-$HOME/tmp}"
mkdir -p "$TMPDIR"
echo "Runner directories configured"

echo "=== Darwin SDK（必须 installed，否则 xtool 会尝试重建并失败）==="
xtool sdk status
if ! xtool sdk status 2>&1 | grep -q 'is installed'; then
  echo "::error::Darwin SDK 未安装，runner 无法编译 iPhoneOS 目标"
  echo "修复：确保 $HOME/.swiftpm/swift-sdks 存在（从 /root/.swiftpm 复制并 chown runner）"
  exit 1
fi

echo "=== 工具链 ==="
xtool --version
swift --version 2>&1 | head -2

# gh 是发布环节（gh release create）的硬依赖。缺了它必须在这里就退出：
# 否则会白跑一次约 5 分钟的编译，到 publish-direct-release.sh 才报 "Missing gh"。
echo "=== 发布必需工具（缺任一即退出，不进入编译）==="
for tool in gh python3 sha256sum flock script unzip tar; do
  printf '%-10s ' "$tool"
  if command -v "$tool" >/dev/null 2>&1; then
    echo OK
  else
    echo MISSING
    echo "::error::缺少必需工具 $tool，发布链无法完成，编译前退出"
    exit 1
  fi
done

echo "=== GitHub CLI（发布用）==="
command -v gh
gh --version

echo "=== 缓存源 ==="
if [ -d "${CACHE_SOURCE:-/work/HermesShell/.build}" ]; then
  du -sh "${CACHE_SOURCE}"
  echo "repositories=$(ls -1 "${CACHE_SOURCE}/repositories" 2>/dev/null | wc -l)"
  echo "checkouts=$(ls -1 "${CACHE_SOURCE}/checkouts" 2>/dev/null | wc -l)"
else
  echo "无缓存源（首次构建将全量拉取依赖）"
fi

echo "=== 现有工作区 ==="
if [ -d "${CI_WORKSPACE:-/work/.hermes-ci-workspace}" ]; then
  du -sh "${CI_WORKSPACE}"
else
  echo "工作区不存在，将由后续步骤创建"
fi
echo "PREFLIGHT_OK"
