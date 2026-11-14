#!/usr/bin/env bash
# Diagnostic wrapper for the pinned HermesShell Xcode benchmark.
# It emits only aggregate metrics and hashed Swift file identifiers to public logs.
set -euo pipefail
REAL_XCODEBUILD="/usr/bin/xcodebuild"
PHASE="${HERMES_BENCH_PHASE:?HERMES_BENCH_PHASE is required}"
RESULT="$RUNNER_TEMP/hermes-$PHASE.xcresult"
SETTINGS="$RUNNER_TEMP/hermes-$PHASE-build-settings.txt"
BUILD_LOG="$RUNNER_TEMP/hermes-$PHASE-build-log.json"

args=("$@")
show_args=()
for arg in "${args[@]}"; do
  [[ "$arg" == "build" ]] || show_args+=("$arg")
done

settings_start="$(python3 -c 'import time; print(time.monotonic_ns())')"
"$REAL_XCODEBUILD" "${show_args[@]}" -showBuildSettings >"$SETTINGS" 2>&1 || {
  echo "XCODE_SETTINGS_CAPTURE=unavailable"
}
settings_end="$(python3 -c 'import time; print(time.monotonic_ns())')"
python3 - "$settings_start" "$settings_end" <<'PY'
import sys
print("XCODE_SETTINGS_QUERY_SECONDS=" + f"{(int(sys.argv[2])-int(sys.argv[1]))/1e9:.3f}")
PY

build_args=()
inserted=0
for arg in "${args[@]}"; do
  if [[ "$arg" == "build" && "$inserted" == "0" ]]; then
    build_args+=("-showBuildTimingSummary" "-resultBundlePath" "$RESULT")
    inserted=1
  fi
  build_args+=("$arg")
done
[[ "$inserted" == "1" ]] || { echo "::error::Expected xcodebuild build action"; exit 2; }

started="$(python3 -c 'import time; print(time.monotonic_ns())')"
set +e
"$REAL_XCODEBUILD" "${build_args[@]}"
status=$?
set -e
finished="$(python3 -c 'import time; print(time.monotonic_ns())')"
python3 - "$started" "$finished" <<'PY'
import sys
print("XCODEBUILD_WALL_SECONDS=" + f"{(int(sys.argv[2])-int(sys.argv[1]))/1e9:.3f}")
PY

if [[ -d "$RESULT" ]]; then
  xcrun xcresulttool get log --path "$RESULT" --type build --compact >"$BUILD_LOG" 2>"$RUNNER_TEMP/hermes-$PHASE-xcresulttool.stderr" || {
    echo "XCODE_RESULT_LOG_CAPTURE=unavailable"
    rm -f "$BUILD_LOG"
  }
fi
exit "$status"
