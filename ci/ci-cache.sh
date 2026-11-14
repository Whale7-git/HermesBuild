#!/usr/bin/env bash
# 播种 SwiftPM 依赖缓存。
# 只复制 repositories/checkouts（依赖源码），不复制 release/debug/out
# 等可变构建产物——陈旧对象文件会导致链接错误或产物与源码不一致。
set -euo pipefail

WS="${CI_WORKSPACE:-/work/.hermes-ci-workspace}"
SRC_CACHE="${CACHE_SOURCE:-/work/HermesShell/.build}"

if [ -d "$WS/.build/repositories" ]; then
  echo "缓存已存在，跳过播种"
elif [ -d "$SRC_CACHE/repositories" ]; then
  echo "首次构建：从 $SRC_CACHE 播种依赖缓存"
  mkdir -p "$WS/.build"
  cp -a "$SRC_CACHE/repositories" "$WS/.build/" 2>/dev/null || true
  if [ -d "$SRC_CACHE/checkouts" ]; then
    cp -a "$SRC_CACHE/checkouts" "$WS/.build/" 2>/dev/null || true
  fi
else
  echo "::warning::无可用依赖缓存，SwiftPM 将尝试联网拉取"
fi

# SwiftPM 在 git 仓库里会因 'dubious ownership' 拒用缓存，
# 进而退回联网克隆——容器内走代理，慢且可能失败。
git config --global --add safe.directory "$WS" 2>/dev/null || true
if [ -d "$WS/.build/repositories" ]; then
  for repo in "$WS"/.build/repositories/*; do
    [ -d "$repo" ] || continue
    git config --global --add safe.directory "$repo" 2>/dev/null || true
  done
fi

du -sh "$WS/.build" 2>/dev/null || echo "无 .build"
echo "CACHE_READY"
