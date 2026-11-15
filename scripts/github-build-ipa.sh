#!/usr/bin/env bash
# CI: create a real iphoneos application and package a SideStore-compatible unsigned IPA.
# This is intentionally separate from the Linux xtool build chain.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: checkout must be clean before generating an Xcode project" >&2
  git status --short >&2
  exit 1
fi
: "${RUNNER_TEMP:?RUNNER_TEMP must be set on the macOS runner}"
for executable in xcodegen xcodebuild python3 zip shasum; do
  command -v "$executable" >/dev/null || { echo "Missing $executable" >&2; exit 1; }
done
# macOS ships Bash 3.2 (no readarray/mapfile).
version="$(python3 -c 'import json; print(json.load(open("release.json"))["version"])')"
build="$(python3 -c 'import json; print(json.load(open("release.json"))["build"])')"
name="Hermes-${version}-build${build}-unsigned"
sha="$(git rev-parse HEAD)"
mkdir -p release
if [[ -n "${HERMES_SOURCE_VERIFIED_SHA:-}" ]]; then
  [[ "$HERMES_SOURCE_VERIFIED_SHA" == "$sha" ]] || { echo 'Source verification SHA mismatch' >&2; exit 1; }
  echo "SOURCE_GATE_ALREADY_VERIFIED_SHA=$sha"
else
  python3 tests/verify_source.py
fi

# A SwiftPM library build is not a device .app. Generate an app target from the
# exact existing iOS sources; do not replace HermesShellApp or copy sample code.
xcodegen generate --spec ios-ci-project.yml

# SwiftPM-only source Info.plist is intentionally sparse. The Xcode app target
# must supply the CFBundle* keys that xtool normally synthesizes. Do this only
# in the runner temp directory, leaving the checked-in plist and release scope
# untouched.
ci_plist="$RUNNER_TEMP/HermesCI-Info.plist"
python3 - "$ci_plist" "$version" "$build" <<'PY'
import pathlib, plistlib, sys
destination, version, build = sys.argv[1:]
with open("Resources/Info.plist", "rb") as source:
    info = plistlib.load(source)
if info.get("CFBundleShortVersionString") != version or info.get("CFBundleVersion") != build:
    raise SystemExit("Info.plist release metadata differs from release.json")
info.update({
    "CFBundleIdentifier": "com.whale7.hermes",
    "CFBundleExecutable": "HermesShell",
    "CFBundlePackageType": "APPL",
    "CFBundleInfoDictionaryVersion": "6.0",
    "MinimumOSVersion": "18.0",
})
with open(destination, "wb") as target:
    plistlib.dump(info, target, sort_keys=False)
PY
derived="$RUNNER_TEMP/hermes-ipa-derived"
xcodebuild \
  "INFOPLIST_FILE=$ci_plist" \
  -project HermesShellCI.xcodeproj \
  -scheme HermesShell \
  -destination 'generic/platform=iOS' \
  -sdk iphoneos \
  -configuration Release \
  -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  'CODE_SIGN_IDENTITY=' \
  STRIP_INSTALLED_PRODUCT=NO \
  COPY_PHASE_STRIP=NO \
  SWIFT_COMPILATION_MODE=incremental \
  SWIFT_OPTIMIZATION_LEVEL=-O \
  build 2>&1 | tee "$RUNNER_TEMP/hermes-ios-release.log"

app="$derived/Build/Products/Release-iphoneos/HermesShell.app"
if [[ ! -d "$app" || ! -f "$app/HermesShell" ]]; then
  echo "ERROR: iPhoneOS .app and executable not found at $app" >&2
  exit 1
fi

stage="$(mktemp -d "$RUNNER_TEMP/hermes-payload.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload"
cp -R "$app" "$stage/Payload/HermesShell.app"
( cd "$stage" && zip -qry "$GITHUB_WORKSPACE/release/$name.ipa" Payload )

# The original project verifier inspects arm64, Mach-O signing, bundle ID,
# version/build, resources, dependencies and the gateway SSE decoder symbol.
python3 - "$version" "$build" "$sha" <<'PY'
import datetime, json, os, pathlib, sys
version, build, commit = sys.argv[1:]
info = {
    "version": version, "build": build, "working_tree": "clean",
    "head_commit": commit,
    "source_head_commit": os.environ.get("PR_HEAD_SHA", commit),
    "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "builder": "github-actions-macos-15-xcode-26.3"
}
pathlib.Path("release/build-info.json").write_text(
    json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
python3 tests/verify_ipa.py "release/$name.ipa" "$version" "$build" \
  release/build-info.json --label "$name.ipa" > release/validation.json
( cd release && shasum -a 256 "$name.ipa" build-info.json validation.json > SHA256SUMS.txt )
echo "RELEASE_IPA_READY release/$name.ipa"
ls -lh "release/$name.ipa"
