#!/usr/bin/env bash
# 记录源码身份：checkout 的 SHA 必须与 GITHUB_SHA 一致，工作树必须干净。
# CI 不 bump 版本，只核对 release.json 是否可用。
set -euo pipefail

SRC="${1:-src}"
cd "$SRC"

HEAD_SHA=$(git rev-parse HEAD)
DIRTY=$(git status --porcelain | wc -l)

echo "GITHUB_SHA=$GITHUB_SHA"
echo "checked_out=$HEAD_SHA"
echo "dirty_files=$DIRTY"
echo "branch=${GITHUB_REF_NAME:-}"

if [ "$HEAD_SHA" != "$GITHUB_SHA" ]; then
  echo "::error::checkout SHA ($HEAD_SHA) 与 GITHUB_SHA ($GITHUB_SHA) 不一致"
  exit 1
fi
if [ "$DIRTY" -ne 0 ]; then
  echo "::error::工作树不干净（$DIRTY 个文件被修改），拒绝构建"
  git status --porcelain
  exit 1
fi

echo "=== release.json（版本唯一来源，CI 只核对不修改）==="
cat release.json

python3 - <<'PY'
import json
import sys

with open('release.json', encoding='utf-8') as fh:
    data = json.load(fh)

for key in ('version', 'build'):
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        print(f'::error::release.json 的 "{key}" 必须是非空字符串', file=sys.stderr)
        raise SystemExit(1)

print(f'RELEASE_VERSION={data["version"]}')
print(f'RELEASE_BUILD={data["build"]}')
PY

echo "=== Info.plist 版本一致性（与 release.json 对照）==="
python3 - <<'PY'
import json
import plistlib
import sys

rel = json.load(open('release.json', encoding='utf-8'))
with open('Resources/Info.plist', 'rb') as fh:
    info = plistlib.load(fh)

pairs = [
    ('CFBundleShortVersionString', rel['version']),
    ('CFBundleVersion', rel['build']),
]
bad = []
for key, want in pairs:
    got = info.get(key)
    ok = got == want
    print(f'  {key}: got={got!r} want={want!r} {"OK" if ok else "MISMATCH"}')
    if not ok:
        bad.append(key)
if bad:
    print(f'::error::Info.plist 与 release.json 不一致: {bad}', file=sys.stderr)
    raise SystemExit(1)
print('IDENTITY_OK')
PY
