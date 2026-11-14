#!/usr/bin/env bash
# 校验下载回来的构建 artifact 确实属于要发布的那个 commit。
# 核心断言：build-info.json 的 head_commit == 请求的 SHA。
# 这一步挡住「拿旧 IPA 发新版本」——产物与源码不一致是最危险的发布事故。
set -euo pipefail

ART="${1:-release}"
WANT="${2:-}"

echo "=== artifact 内容 ==="
ls -la "$ART"

if [ ! -f "$ART/build-info.json" ]; then
  echo "::error::artifact 里没有 build-info.json，无法证明产物来源"
  exit 1
fi

echo "=== build-info.json ==="
cat "$ART/build-info.json"

python3 - "$ART" "$WANT" <<'PY'
import json
import pathlib
import sys

art = pathlib.Path(sys.argv[1])
want = sys.argv[2]
info = json.loads((art / "build-info.json").read_text(encoding="utf-8"))

bad = []

def check(name, got, expect):
    ok = got == expect
    print(f"  {name}: {'OK' if ok else 'FAIL'}  got={got!r} want={expect!r}")
    if not ok:
        bad.append(name)

check("head_commit", info.get("head_commit"), want)
# 发布脚本还会比对 source_head_commit，这里先自查
check("source_head_commit", info.get("source_head_commit"), want)
check("working_tree", info.get("working_tree"), "clean")

if bad:
    print(f"::error::artifact 与目标 commit 不匹配: {bad}", file=sys.stderr)
    raise SystemExit(1)

# 发布脚本要求 release/ 下有这三个文件
for name in ("build-info.json", "validation.json", "SHA256SUMS.txt"):
    path = art / name
    if not path.is_file() or path.stat().st_size == 0:
        print(f"::error::缺少或为空的 {name}", file=sys.stderr)
        raise SystemExit(1)
    print(f"  {name}: present ({path.stat().st_size} bytes)")

print("ARTIFACT_OK")
PY

echo "=== SHA256SUMS 校验 ==="
(cd "$ART" && sha256sum -c SHA256SUMS.txt)

echo "ARTIFACT_VERIFIED"
