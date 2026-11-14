#!/usr/bin/env bash
# 把 checkout 的源码严格同步到 CI 独立工作区。
# 关键约束：
#  - 绝不覆盖 /work/HermesShell（那是人工构建的固定目录）。
#  - 清掉过期源码，但显式保留 .build 缓存（增量编译依赖它）。
#  - 不用 rsync --delete（容器内可能没有 rsync，且 --delete 容易误删缓存）。
set -euo pipefail

SRC="${1:-src}"
WS="${CI_WORKSPACE:-/work/.hermes-ci-workspace}"

mkdir -p "$WS"

# 1. 删除已知源码目录（不碰 .build / releases）
for d in Sources Resources tests Vendor xtool scripts ci; do
  rm -rf "$WS/$d"
done

# 2. 删除根级文件（只删源码类，保留 .build 等目录）
find "$WS" -maxdepth 1 -type f \
  \( -name '*.swift' -o -name '*.json' -o -name '*.yml' -o -name '*.md' \) \
  -delete 2>/dev/null || true

# 3. 复制本次 commit 的全部内容（排除缓存、git、历史产物）
tar -C "$SRC" \
  --exclude='./.build' \
  --exclude='./.git' \
  --exclude='./releases' \
  -cf - . | tar -C "$WS" -xf -

echo "=== 同步后工作区 ==="
ls "$WS"

# 4. 校验构建必需文件都在
missing=0
for f in release.json xtool.yml Package.swift \
         tests/verify_source.py tests/verify_ipa.py \
         tests/run_container.sh Resources/Info.plist \
         scripts/release-local.sh ci/ci-build.sh; do
  if [ ! -e "$WS/$f" ]; then
    echo "::error::工作区缺少 $f"
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

echo "SYNC_OK"
