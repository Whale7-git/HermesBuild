#!/usr/bin/env bash
# Measure cold, same-runner warm, and restored-runner warm Xcode builds.
# This script never publishes an IPA or bypasses compilation/IPA verification.
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-}"
case "$mode" in
  cold|same|warm) ;;
  *) echo "usage: cache-benchmark.sh cold|same|warm" >&2; exit 2 ;;
esac

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"
: "${EXPECTED_SHA:?EXPECTED_SHA must be set}"

actual_sha="$(git rev-parse HEAD)"
[[ "$actual_sha" == "$EXPECTED_SHA" ]] || {
  echo "benchmark checkout is $actual_sha instead of expected $EXPECTED_SHA" >&2
  exit 1
}

now() {
  python3 -c 'import time; print(time.monotonic_ns())'
}

elapsed() {
  python3 - "$1" "$2" <<'PY'
import sys
print(f"{(int(sys.argv[2]) - int(sys.argv[1])) / 1e9:.3f}")
PY
}

output() {
  printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"
}

derived="$RUNNER_TEMP/hermes-ipa-derived"
benchmark_dir="$RUNNER_TEMP/hermes-cache-benchmark-$mode"
mkdir -p "$benchmark_dir"
benchmark_started_ns="$(now)"
phase_file="$benchmark_dir/github-build-phases.env"
rm -f "$phase_file"

version="$(python3 -c 'import json; print(json.load(open("release.json"))["version"])')"
build="$(python3 -c 'import json; print(json.load(open("release.json"))["build"])')"
name="Hermes-${version}-build${build}-unsigned"

# The caller prepares and normalizes inputs before every measured build.
# DerivedData remains untouched so the build database is the subject under test.
rm -rf release

build_start="$(now)"
env -u HERMES_SOURCE_VERIFIED_SHA \
  PR_HEAD_SHA="$actual_sha" \
  HERMES_BUILD_PHASE_TIMINGS_FILE="$phase_file" \
  HERMES_REUSE_GENERATED_PROJECT=1 \
  HERMES_CI_INFO_PLIST="$RUNNER_TEMP/HermesCI-Info.plist" \
  bash scripts/github-build-ipa.sh
build_end="$(now)"
build_seconds="$(elapsed "$build_start" "$build_end")"

ipa="release/${name}.ipa"
validation="release/validation.json"
test -f "$ipa"
test -f "$validation"
independent_verification_started_ns="$(now)"
python3 tests/verify_ipa.py \
  "$ipa" "$version" "$build" release/build-info.json --label "$name.ipa" \
  > "$benchmark_dir/independent-validation.json"
independent_verification_seconds="$(
  elapsed "$independent_verification_started_ns" "$(now)"
)"
cmp release/validation.json "$benchmark_dir/independent-validation.json"

payload_extract_started_ns="$(now)"
payload="$benchmark_dir/payload"
rm -rf "$payload"
unzip -q "$ipa" -d "$payload"
payload_extract_seconds="$(elapsed "$payload_extract_started_ns" "$(now)")"
resource_hash_started_ns="$(now)"
resource_sha="$(
  python3 - "$payload" "$benchmark_dir/resource-manifest.json" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
apps = list(root.glob("Payload/*.app"))
if len(apps) != 1:
    raise SystemExit(f"expected one app payload, got {apps}")
app = apps[0]

# Xcode embeds changing build metadata and Mach-O UUIDs in compiled products.
# Compare stable packaged resources; package verification remains authoritative.
digest = hashlib.sha256()
entries = []
for path in sorted(
    p for p in app.rglob("*") if p.is_file() and p.name != "HermesShell"
):
    relative = path.relative_to(app).as_posix().encode("utf-8")
    data = path.read_bytes()
    entries.append(
        {"path": relative.decode("utf-8"), "sha256": hashlib.sha256(data).hexdigest()}
    )
    digest.update(len(relative).to_bytes(8, "big"))
    digest.update(relative)
    digest.update(len(data).to_bytes(8, "big"))
    digest.update(data)
manifest_path.write_text(
    json.dumps({"sha256": digest.hexdigest(), "files": entries}, indent=2) + "\n",
    encoding="utf-8",
)
print(digest.hexdigest())
PY
)"
resource_hash_seconds="$(elapsed "$resource_hash_started_ns" "$(now)")"

metadata_started_ns="$(now)"
ipa_sha="$(shasum -a 256 "$ipa" | awk '{print $1}')"
ipa_bytes="$(stat -f %z "$ipa")"
derived_kib="$(du -sk "$derived" | awk '{print $1}')"
derived_bytes="$((derived_kib * 1024))"
toolchain="$(xcodebuild -version | tr '\n' ' ')"
sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
input_sha="$(tr -d '\n' < "$RUNNER_TEMP/hermes-cache-input-sha256.txt")"
compiled_hermes="$(
  grep -Ec 'SwiftCompile normal arm64 .*/Sources/HermesShell/' \
    "$RUNNER_TEMP/hermes-ios-release.log" || true
)"
compiled_textual="$(
  grep -Ec 'SwiftCompile normal arm64 .*/Vendor/Textual/' \
    "$RUNNER_TEMP/hermes-ios-release.log" || true
)"
base_directory_regenerated="$(
  grep -Fc 'Base directory status changed. Regenerating...' \
    "$RUNNER_TEMP/hermes-ios-release.log" || true
)"
metadata_seconds="$(elapsed "$metadata_started_ns" "$(now)")"

phase_json="$(
  python3 - "$phase_file" \
    "$build_seconds" \
    "$independent_verification_seconds" \
    "$payload_extract_seconds" \
    "$resource_hash_seconds" \
    "$metadata_seconds" \
    "$benchmark_started_ns" <<'PY'
import json
import pathlib
import sys
import time

(
    phase_file,
    build_seconds,
    independent_ipa_verification,
    payload_extract,
    resource_hash,
    metadata,
    benchmark_started_ns,
) = sys.argv[1:]

phases = {}
path = pathlib.Path(phase_file)
if not path.is_file():
    raise SystemExit(f"missing GitHub build phase timings: {phase_file}")
for line in path.read_text(encoding="utf-8").splitlines():
    if not line:
        continue
    name, raw = line.split("=", 1)
    if name in phases:
        raise SystemExit(f"duplicate build phase timing: {name}")
    phases[name] = float(raw)

phases["benchmark_build_wrapper"] = float(build_seconds)
phases["independent_ipa_verification"] = float(independent_ipa_verification)
phases["payload_extract"] = float(payload_extract)
phases["resource_hash"] = float(resource_hash)
phases["metadata"] = float(metadata)
phases["benchmark_total"] = (
    time.monotonic_ns() - int(benchmark_started_ns)
) / 1e9
print(json.dumps(phases, sort_keys=True, separators=(",", ":")))
PY
)"
python3 - "$phase_json" <<'PY'
import json
import sys

phases = json.loads(sys.argv[1])
if not phases or any(
    not isinstance(name, str)
    or not name
    or not isinstance(seconds, (int, float))
    or seconds < 0
    for name, seconds in phases.items()
):
    raise SystemExit("invalid phase timing map")
PY

python3 - "$benchmark_dir/result.json" <<PY
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
result = {
    "mode": "$mode",
    "source_sha": "$actual_sha",
    "version": "$version",
    "build": "$build",
    "toolchain": "$toolchain",
    "iphoneos_sdk": "$sdk",
    "input_manifest_sha256": "$input_sha",
    "compiled_hermes_sources": $compiled_hermes,
    "compiled_textual_sources": $compiled_textual,
    "base_directory_regenerated": $base_directory_regenerated,
    "build_seconds": $build_seconds,
    "phase_seconds": json.loads("""$phase_json"""),
    "ipa_sha256": "$ipa_sha",
    "payload_sha256": "$resource_sha",
    "ipa_bytes": $ipa_bytes,
    "deriveddata_kib": $derived_kib,
    "deriveddata_bytes": $derived_bytes,
}
path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
PY

cp "$RUNNER_TEMP/hermes-cache-inputs.tsv" "$benchmark_dir/input-manifest.tsv"
cp "$RUNNER_TEMP/hermes-ios-release.log" "$benchmark_dir/xcodebuild.log"
cp release/build-info.json "$benchmark_dir/build-info.json"
cp release/validation.json "$benchmark_dir/validation.json"
cp release/SHA256SUMS.txt "$benchmark_dir/SHA256SUMS.txt"
cp "$ipa" "$benchmark_dir/$name.ipa"

output build_seconds "$build_seconds"
output source_sha "$actual_sha"
output toolchain "$toolchain"
output iphoneos_sdk "$sdk"
output input_sha "$input_sha"
output compiled_hermes "$compiled_hermes"
output compiled_textual "$compiled_textual"
output base_directory_regenerated "$base_directory_regenerated"
output ipa_sha "$ipa_sha"
output payload_sha "$resource_sha"
output ipa_bytes "$ipa_bytes"
output deriveddata_kib "$derived_kib"
output deriveddata_bytes "$derived_bytes"
output phases_json "$phase_json"
output result_path "$benchmark_dir/result.json"

{
  echo "### Cache benchmark: $mode"
  echo
  echo "| Measurement | Value |"
  echo "|---|---:|"
  echo "| Build + package + IPA verification | ${build_seconds}s |"
  echo "| HermesShell SwiftCompile tasks | ${compiled_hermes} |"
  echo "| Textual SwiftCompile tasks | ${compiled_textual} |"
  echo "| Base directory regenerated | ${base_directory_regenerated} |"
  echo "| Input manifest SHA-256 | \`${input_sha}\` |"
  echo "| DerivedData | ${derived_kib} KiB |"
  echo "| IPA | ${ipa_bytes} bytes |"
  echo "| Xcode | ${toolchain} |"
  echo "| iPhoneOS SDK | ${sdk} |"
  echo "| IPA SHA-256 | \`${ipa_sha}\` |"
  echo "| Bundled resource SHA-256 | \`${resource_sha}\` |"
} >> "$GITHUB_STEP_SUMMARY"

mode_upper="$(printf '%s' "$mode" | tr '[:lower:]' '[:upper:]')"
echo "CACHE_BENCHMARK_${mode_upper}_OK build_seconds=$build_seconds deriveddata_kib=$derived_kib ipa_sha=$ipa_sha"
