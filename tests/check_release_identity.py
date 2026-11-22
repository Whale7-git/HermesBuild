#!/usr/bin/env python3
"""Check release identity only. No historical source inventory or hash allowlist."""
import json
import plistlib
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
release = json.loads((root / "release.json").read_text(encoding="utf-8"))
version = release.get("version")
build = release.get("build")
if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit("INVALID_RELEASE_VERSION")
if not isinstance(build, str) or not re.fullmatch(r"[1-9]\d*", build):
    raise SystemExit("INVALID_RELEASE_BUILD")
info = plistlib.loads((root / "Resources/Info.plist").read_bytes())
if info.get("CFBundleShortVersionString") != version or info.get("CFBundleVersion") != build:
    raise SystemExit("INFO_PLIST_RELEASE_MISMATCH")
first_line = (root / "README.md").read_text(encoding="utf-8").splitlines()[0]
if first_line != f"# Hermes {version} / build{build}":
    raise SystemExit("README_RELEASE_MISMATCH")
project = (root / "ios-ci-project.yml").read_text(encoding="utf-8")
if "PRODUCT_BUNDLE_IDENTIFIER: com.whale7.hermes" not in project:
    raise SystemExit("BUNDLE_IDENTIFIER_MISMATCH")
print(f"RELEASE_IDENTITY_PASS {version} build{build}")
