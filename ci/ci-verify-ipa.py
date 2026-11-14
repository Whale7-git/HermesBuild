#!/usr/bin/env python3
"""CI 侧的补充校验：确认 IPA 元数据与资源完整，但**不改写**标准报告。

分工（重要，别搞混）：
  - tests/verify_ipa.py 是发布门禁，release-local.sh 已调用它生成
    releases/validation.json，字段为 bundle/arch/unsigned/... 发布脚本依赖这份。
  - 本脚本只做额外断言（PrivacyInfo、无 Frameworks、可执行文件存在），
    结果写到 releases/ci-validation.json，绝不覆盖 validation.json。

为什么不能覆盖：ci/publish-direct-release.sh 断言 validation.json 里
有 bundle/arch/unsigned 字段；覆盖成别的字段名会让发布在最后一刻失败。
"""
from __future__ import annotations

import glob
import hashlib
import json
import os
import plistlib
import sys
import zipfile

EXPECTED_BUNDLE = "com.whale7.hermes"
EXPECTED_MIN_OS = "18.0"
REPORT = "releases/ci-validation.json"


def main() -> int:
    ipas = sorted(glob.glob("releases/*.ipa"))
    if len(ipas) != 1:
        print(f"::error::期望 releases/ 下恰好 1 个 IPA，实际 {len(ipas)}: {ipas}", file=sys.stderr)
        return 1
    ipa = ipas[0]

    with open("release.json", encoding="utf-8") as fh:
        rel = json.load(fh)

    zf = zipfile.ZipFile(ipa)
    names = zf.namelist()

    info_path = "Payload/HermesShell.app/Info.plist"
    if info_path not in names:
        print(f"::error::IPA 缺少 {info_path}", file=sys.stderr)
        return 1
    info = plistlib.loads(zf.read(info_path))

    exe = info.get("CFBundleExecutable", "HermesShell")
    checks = [
        ("bundle_id", info.get("CFBundleIdentifier"), EXPECTED_BUNDLE),
        ("version", info.get("CFBundleShortVersionString"), rel["version"]),
        ("build", info.get("CFBundleVersion"), rel["build"]),
        ("min_os", info.get("MinimumOSVersion"), EXPECTED_MIN_OS),
        ("privacy_manifest", any("PrivacyInfo.xcprivacy" in n for n in names), True),
        ("no_frameworks", not any("/Frameworks/" in n for n in names), True),
        ("has_executable", f"Payload/HermesShell.app/{exe}" in names, True),
    ]

    failures = []
    for key, got, want in checks:
        ok = got == want
        print(f"  {key}: got={got!r} want={want!r} {'OK' if ok else 'MISMATCH'}")
        if not ok:
            failures.append(key)

    size = os.path.getsize(ipa)
    with open(ipa, "rb") as fh:
        sha = hashlib.sha256(fh.read()).hexdigest()
    print(f"  size_bytes: {size}")
    print(f"  sha256: {sha}")

    if failures:
        print(f"::error::IPA 校验失败: {failures}", file=sys.stderr)
        return 1

    # 只写补充报告，不碰 releases/validation.json（发布脚本依赖它的字段）
    report = {
        "status": "PASS",
        "ipa": os.path.basename(ipa),
        "size_bytes": size,
        "sha256": sha,
        "bundle": info.get("CFBundleIdentifier"),
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "min_os": info.get("MinimumOSVersion"),
        "checks": [c[0] for c in checks],
        "note": "supplementary CI report; canonical gate is tests/verify_ipa.py -> validation.json",
    }
    with open(REPORT, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
    print("IPA_METADATA_OK")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
