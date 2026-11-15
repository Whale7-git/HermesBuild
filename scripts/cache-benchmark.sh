#!/usr/bin/env bash
# Measure whether restoring Xcode DerivedData saves net wall time.
# This script never publishes an IPA or bypasses compilation/IPA verification.
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-}"
case "$mode" in
  cold|warm) ;;
  *) echo "usage: cache-benchmark.sh cold|warm" >&2; exit 2 ;;
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
benchmark_dir="$RUNNER_TEMP/hermes-cache-benchmark"
mkdir -p "$benchmark_dir"

version="$(python3 -c 'import json; print(json.load(open("release.json"))["version"])')"
build="$(python3 -c 'import json; print(json.load(open("release.json"))["build"])')"
name="Hermes-${version}-build${build}-unsigned"

# The warm job restores DerivedData before entering this script. Only remove
# packaging output so the restored build database and intermediates stay intact.
rm -rf release

build_start="$(now)"
env -u HERMES_SOURCE_VERIFIED_SHA \
  PR_HEAD_SHA="$actual_sha" \
  bash scripts/github-build-ipa.sh
build_end="$(now)"
build_seconds="$(elapsed "$build_start" "$build_end")"

ipa="release/${name}.ipa"
validation="release/validation.json"
test -f "$ipa"
test -f "$validation"
python3 tests/verify_ipa.py \
  "$ipa" "$version" "$build" release/build-info.json --label "$name.ipa" \
  > "$benchmark_dir/independent-validation.json"
cmp release/validation.json "$benchmark_dir/independent-validation.json"

payload="$benchmark_dir/payload"
rm -rf "$payload"
unzip -q "$ipa" -d "$payload"
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
# Compare the source-controlled resources that must remain byte-identical.
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
ipa_sha="$(shasum -a 256 "$ipa" | awk '{print $1}')"
ipa_bytes="$(stat -f %z "$ipa")"
derived_kib="$(du -sk "$derived" | awk '{print $1}')"
derived_bytes="$((derived_kib * 1024))"
toolchain="$(xcodebuild -version | tr '\n' ' ')"
sdk="$(xcrun --sdk iphoneos --show-sdk-version)"

cat > "$benchmark_dir/result.json" <<EOF
{
  "mode": "$mode",
  "source_sha": "$actual_sha",
  "version": "$version",
  "build": "$build",
  "toolchain": "$toolchain",
  "iphoneos_sdk": "$sdk",
  "build_seconds": $build_seconds,
  "ipa_sha256": "$ipa_sha",
  "payload_sha256": "$resource_sha",
  "ipa_bytes": $ipa_bytes,
  "deriveddata_kib": $derived_kib,
  "deriveddata_bytes": $derived_bytes
}
EOF

output build_seconds "$build_seconds"
output source_sha "$actual_sha"
output toolchain "$toolchain"
output iphoneos_sdk "$sdk"
output ipa_sha "$ipa_sha"
output payload_sha "$resource_sha"
output ipa_bytes "$ipa_bytes"
output deriveddata_kib "$derived_kib"
output deriveddata_bytes "$derived_bytes"

{
  echo "### Cache benchmark: $mode"
  echo
  echo "| Measurement | Value |"
  echo "|---|---:|"
  echo "| Build + package + IPA verification | ${build_seconds}s |"
  echo "| DerivedData | ${derived_kib} KiB |"
  echo "| IPA | ${ipa_bytes} bytes |"
  echo "| Xcode | ${toolchain} |"
  echo "| iPhoneOS SDK | ${sdk} |"
  echo "| IPA SHA-256 | \`${ipa_sha}\` |"
  echo "| Bundled resource SHA-256 | \`${resource_sha}\` |"
} >> "$GITHUB_STEP_SUMMARY"

if [[ "$mode" == cold ]]; then
  mode_upper=COLD
else
  mode_upper=WARM
fi
echo "CACHE_BENCHMARK_${mode_upper}_OK build_seconds=$build_seconds deriveddata_kib=$derived_kib ipa_sha=$ipa_sha"
