#!/usr/bin/env bash
# Check the GitHub macOS toolchain before producing an iPhoneOS IPA.
# Only validates compatibility and records drift; does not install SDKs/caches.
set -euo pipefail
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
mkdir -p "$RUNNER_TEMP/gpt-cloud"
for executable in sw_vers xcodebuild xcodegen xcrun python3; do
  command -v "$executable" >/dev/null || {
    echo "ERROR: toolchain missing $executable" >&2; exit 2;
  }
done
macos="$(sw_vers -productVersion)"
xcode="$(xcodebuild -version)"
xcodegen="$(xcodegen --version)"
sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
swift="$(xcrun swift --version)"
{
  printf 'macOS: %s\n' "$macos"
  printf 'Xcode: %s\n' "$xcode"
  printf 'XcodeGen: %s\n' "$xcodegen"
  printf 'iPhoneOS SDK: %s\n' "$sdk"
  printf 'Swift: %s\n' "$swift"
} | tee "$RUNNER_TEMP/gpt-cloud/toolchain.log"
python3 - "$RUNNER_TEMP/gpt-cloud/toolchain.json" "$macos" "$xcode" "$xcodegen" "$sdk" "$swift" <<'PY'
import json
import pathlib
import re
import sys

path, macos, xcode, xcodegen, sdk, swift = sys.argv[1:]
def version(value, label):
    match = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", value)
    if not match:
        raise SystemExit(f"ERROR: cannot parse {label} version: {value!r}")
    return tuple(int(v or 0) for v in match.groups())

xcode_version = version(xcode, "Xcode")
sdk_version = version(sdk, "iPhoneOS SDK")
gen_version = version(xcodegen, "XcodeGen")
if xcode_version[0] != 26 or sdk_version[0] != 26:
    raise SystemExit("ERROR: GPT branch expects tested Xcode/iPhoneOS SDK major 26")
if gen_version < (2, 42, 0):
    raise SystemExit("ERROR: GPT branch requires XcodeGen >= 2.42.0")
data = {
    "macos": macos,
    "xcode": xcode.strip(),
    "xcodegen": xcodegen.strip(),
    "swift": swift.strip(),
    "iphoneos_sdk": sdk,
    "tested_xcode": "26.6",
    "tested_xcodegen": "2.46.0",
    "compatible": True,
}
pathlib.Path(path).write_text(json.dumps(data, indent=2) + "\n")
if xcode_version[:2] != (26, 6) or gen_version != (2, 46, 0):
    print("::warning::GPT toolchain differs from last verified Xcode 26.6 / XcodeGen 2.46.0; verify IPA result")
print("GPT_TOOLCHAIN_VALIDATED")
PY
