#!/usr/bin/env bash
# Build one immutable HermesBuild candidate for PR verification.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${RUNNER_TEMP:?RUNNER_TEMP must be set on the macOS runner}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set on the macOS runner}"

for executable in xcodegen xcodebuild python3 zip shasum git; do
  command -v "$executable" >/dev/null || {
    echo "Missing required executable: $executable" >&2
    exit 1
  }
done

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: checkout must be clean before building a candidate" >&2
  git status --short >&2
  exit 1
fi

version="$(python3 -c 'import json; print(json.load(open("release.json"))["version"])')"
build="$(python3 -c 'import json; print(json.load(open("release.json"))["build"])')"
name="Hermes-${version}-build${build}-unsigned"
sha="$(git rev-parse HEAD)"
tree="$(git rev-parse 'HEAD^{tree}')"
repository="${GITHUB_REPOSITORY:-Whale7-git/HermesBuild}"
event_name="${HERMES_EVENT_NAME:-workflow_dispatch}"
run_id="${HERMES_RUN_ID:-0}"
run_attempt="${HERMES_RUN_ATTEMPT:-1}"
workflow_path="${HERMES_WORKFLOW_PATH:-.github/workflows/hermesshell-single-build.yml}"
workflow_blob_sha="${HERMES_WORKFLOW_BLOB_SHA:-}"
candidate_dir="${HERMES_CANDIDATE_DIR:-$RUNNER_TEMP/hermes-candidate-release}"

case "$candidate_dir" in
  ""|"/"|"$GITHUB_WORKSPACE"|"$GITHUB_WORKSPACE/")
    echo "Refusing unsafe candidate output directory: $candidate_dir" >&2
    exit 1
    ;;
esac
rm -rf "$candidate_dir"
mkdir -p "$candidate_dir"

echo "CANDIDATE_SOURCE commit=$sha tree=$tree version=$version build=$build"
python3 tests/verify_source.py

xcodegen generate --spec ios-ci-project.yml

ci_plist="$RUNNER_TEMP/HermesMainCI-Info.plist"
python3 - "$ci_plist" "$version" "$build" <<'PY'
import pathlib
import plistlib
import sys

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

derived="${HERMES_DERIVED_DATA:-$RUNNER_TEMP/hermes-main-ipa-derived}"
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
  build 2>&1 | tee "$RUNNER_TEMP/hermes-main-ios-release.log"

app="$derived/Build/Products/Release-iphoneos/HermesShell.app"
if [[ ! -d "$app" || ! -f "$app/HermesShell" ]]; then
  echo "ERROR: iPhoneOS app not found at $app" >&2
  exit 1
fi

stage="$(mktemp -d "$RUNNER_TEMP/hermes-main-payload.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload"
cp -R "$app" "$stage/Payload/HermesShell.app"
(cd "$stage" && zip -qry "$candidate_dir/$name.ipa" Payload)

python3 - "$candidate_dir/build-info.json" "$version" "$build" "$sha" "$tree" \
  "$repository" "$event_name" "$run_id" "$run_attempt" "$workflow_path" \
  "$workflow_blob_sha" <<'PY'
import datetime
import json
import os
import pathlib
import subprocess
import sys

(destination, version, build, commit, tree, repository, event_name,
 run_id, run_attempt, workflow_path, workflow_blob_sha) = sys.argv[1:]

info = {
    "schema_version": 1,
    "version": version,
    "build": build,
    "working_tree": "clean",
    "head_commit": commit,
    "head_tree": tree,
    "source_head_commit": commit,
    "source_tree": tree,
    "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "builder": "github-actions-macos-single-build",
    "macos_version": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
    "xcode_version": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    "swift_version": subprocess.check_output(["xcrun", "swift", "--version"], text=True).strip(),
    "iphoneos_sdk_version": subprocess.check_output(
        ["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], text=True
    ).strip(),
    "producer": {
        "repository": repository,
        "event": event_name,
        "run_id": run_id,
        "run_attempt": run_attempt,
        "workflow_path": workflow_path,
        "workflow_blob_sha": workflow_blob_sha or None,
    },
}
pathlib.Path(destination).write_text(
    json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
PY

python3 tests/verify_ipa.py "$candidate_dir/$name.ipa" "$version" "$build" \
  "$candidate_dir/build-info.json" --label "$name.ipa" > "$candidate_dir/validation.json"

python3 - "$candidate_dir" "$name" "$version" "$build" "$sha" "$tree" \
  "$repository" "$event_name" "$run_id" "$run_attempt" "$workflow_path" \
  "$workflow_blob_sha" <<'PY'
import hashlib
import json
import pathlib
import sys

(directory, ipa_name, version, build, commit, tree, repository, event_name,
 run_id, run_attempt, workflow_path, workflow_blob_sha) = sys.argv[1:]
root = pathlib.Path(directory)

def digest(name):
    return hashlib.sha256((root / name).read_bytes()).hexdigest()

manifest = {
    "schema_version": 1,
    "repository": repository,
    "producer": {
        "event": event_name,
        "run_id": run_id,
        "run_attempt": run_attempt,
        "workflow_path": workflow_path,
        "workflow_blob_sha": workflow_blob_sha or None,
    },
    "source": {
        "commit": commit,
        "tree": tree,
        "working_tree": "clean",
    },
    "release": {
        "version": version,
        "build": build,
        "tag": f"release-{version}-build{build}",
        "ipa": ipa_name + ".ipa",
    },
    "files": {
        ipa_name + ".ipa": digest(ipa_name + ".ipa"),
        "build-info.json": digest("build-info.json"),
        "validation.json": digest("validation.json"),
    },
}
(root / "candidate-manifest.json").write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
PY

(
  cd "$candidate_dir"
  shasum -a 256 "$name.ipa" build-info.json validation.json candidate-manifest.json \
    > SHA256SUMS.txt
)
python3 scripts/verify-candidate.py "$candidate_dir" --expected-tree "$tree"

echo "CANDIDATE_READY directory=$candidate_dir commit=$sha tree=$tree"
ls -lh "$candidate_dir"
