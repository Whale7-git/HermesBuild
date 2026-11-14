#!/usr/bin/env bash
# 校验产物：大小、SHA256、元数据、架构，写出 build-info.json，并用官方
# tests/verify_ipa.py 做一次完整门禁复核（与发布脚本同一套断言）。
#
# 重要：不覆盖 releases/validation.json。
# release-local.sh 已用 verify_ipa.py 生成该文件，字段为
# bundle/arch/unsigned/...，ci/publish-direct-release.sh 依赖这些字段名。
# 本步骤的补充结论写到 releases/ci-validation.json。
set -euo pipefail

WS="${CI_WORKSPACE:-/work/.hermes-ci-workspace}"
LOGDIR="${RUNNER_LOGDIR:-/root/runner-home/logs}"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/build.log"
cd "$WS"

VERSION=$(python3 -c "import json;print(json.load(open('release.json'))['version'])")
BUILD=$(python3 -c "import json;print(json.load(open('release.json'))['build'])")
NAME="Hermes-${VERSION}-build${BUILD}-unsigned"
IPA="releases/${NAME}.ipa"

if [ ! -f "$IPA" ]; then
  echo "::error::找不到 $IPA"
  ls -l releases 2>/dev/null || true
  exit 1
fi

SIZE=$(stat -c%s "$IPA")
SHA=$(sha256sum "$IPA" | awk '{print $1}')
echo "IPA_NAME=${NAME}.ipa" | tee -a "$LOG"
echo "IPA_SIZE=$SIZE" | tee -a "$LOG"
echo "IPA_SHA256=$SHA" | tee -a "$LOG"

echo "=== 生成 build-info.json（固化产物与 commit 的对应关系）==="
python3 ci/write-build-info.py "$VERSION" "$BUILD" "$SIZE" "$SHA"

echo "=== 官方 IPA 门禁复核（tests/verify_ipa.py，与发布脚本同源）==="
# 此时 build-info.json 已存在，因此不再传 --no-build-info：
# 这会额外校验 working_tree=clean 与 head_commit 一致性。
# 结果必须写回 releases/validation.json —— 发布脚本依赖其中的
# bundle/arch/unsigned 字段；仅打印不写回会导致发布断言失败。
python3 tests/verify_ipa.py "$IPA" "$VERSION" "$BUILD" releases/build-info.json \
  --delivery "$IPA" --label "${NAME}.ipa" > "$LOGDIR/reverify.json"
cp "$LOGDIR/reverify.json" releases/validation.json
cat releases/validation.json
echo

echo "=== 元数据与资源补充校验（写 ci-validation.json）==="
python3 ci/ci-verify-ipa.py

echo "=== 二进制架构 ==="
rm -rf "$LOGDIR/ipax" && mkdir -p "$LOGDIR/ipax"
unzip -qo "$IPA" -d "$LOGDIR/ipax"
EXE="$LOGDIR/ipax/Payload/HermesShell.app/HermesShell"
if [ ! -f "$EXE" ]; then
  echo "::error::找不到可执行文件 $EXE"
  ls -l "$LOGDIR/ipax/Payload/HermesShell.app" | head -20
  exit 1
fi
# 容器内没有 file 命令，直接解析 Mach-O 头判断架构
python3 ci/check-arch.py "$EXE"

# SHA256SUMS 必须与最终产物一致（发布脚本会 sha256sum -c 校验）
# release-local.sh 在 RELEASE_IPA_READY 时算过一次，但那之后我们又写了
# build-info.json 与 ci-validation.json，所以这里必须重算，否则清单过期。
echo "=== 重算 SHA256SUMS（含新增的 build-info.json / ci-validation.json）==="
(
  cd releases
  files=()
  for path in *; do
    [ -f "$path" ] || continue
    case "$path" in
      SHA256SUMS.txt|FAILED.txt) continue ;;
    esac
    files+=("$path")
  done
  sha256sum "${files[@]}" > SHA256SUMS.txt
  cat SHA256SUMS.txt
  sha256sum -c SHA256SUMS.txt
)

echo "VERIFY_OK"
