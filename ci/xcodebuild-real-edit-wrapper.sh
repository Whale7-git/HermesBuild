#!/usr/bin/env bash
# Isolated Xcode build wrapper for the build162 Release compilation experiment.
# It changes only SWIFT_COMPILATION_MODE; optimization remains controlled by
# the pinned XcodeGen Release preset (-O), which is verified from build settings.
set -euo pipefail

REAL_XCODEBUILD="/usr/bin/xcodebuild"
MODE="${HERMES_EXPERIMENT_MODE:?wholemodule|incremental required}"
PHASE="${HERMES_EXPERIMENT_PHASE:?cold|changed required}"
DERIVED="${HERMES_EXPERIMENT_DERIVED:?DerivedData path required}"
RESULT="$RUNNER_TEMP/hermes-exp-$MODE-$PHASE.xcresult"
SETTINGS="$RUNNER_TEMP/hermes-exp-$MODE-$PHASE-settings.txt"
BUILD_JSON="$RUNNER_TEMP/hermes-exp-$MODE-$PHASE-build-log.json"
BUILD_TEXT="$RUNNER_TEMP/hermes-exp-$MODE-$PHASE-xcodebuild.log"
METRICS="$RUNNER_TEMP/hermes-exp-$MODE-$PHASE.json"
XCRESULT_ERROR="$RUNNER_TEMP/hermes-exp-$MODE-$PHASE-xcresulttool.stderr"

case "$MODE" in
  wholemodule|incremental) ;;
  *) echo "::error::Unsupported compilation mode: $MODE"; exit 2 ;;
esac
case "$PHASE" in
  cold|changed) ;;
  *) echo "::error::Unsupported phase: $PHASE"; exit 2 ;;
esac

base_args=()
skip_next=0
found_derived=0
found_build=0
for arg in "$@"; do
  if [[ "$skip_next" == "1" ]]; then
    base_args+=("$DERIVED")
    skip_next=0
    found_derived=1
    continue
  fi
  case "$arg" in
    -derivedDataPath)
      base_args+=("$arg")
      skip_next=1
      ;;
    build)
      found_build=1
      ;;
    *)
      base_args+=("$arg")
      ;;
  esac
done
[[ "$skip_next" == "0" && "$found_derived" == "1" && "$found_build" == "1" ]] || {
  echo "::error::Expected xcodebuild build with -derivedDataPath"
  exit 2
}

mkdir -p "$DERIVED"
rm -rf "$RESULT" "$BUILD_JSON" "$BUILD_TEXT" "$METRICS" "$SETTINGS" "$XCRESULT_ERROR"

# Verify the effective settings before spending time on the build.
"$REAL_XCODEBUILD" "${base_args[@]}" "SWIFT_COMPILATION_MODE=$MODE" -showBuildSettings >"$SETTINGS" 2>&1

started="$(python3 -c 'import time; print(time.monotonic_ns())')"
set +e
"$REAL_XCODEBUILD" "${base_args[@]}" \
  "SWIFT_COMPILATION_MODE=$MODE" \
  -showBuildTimingSummary \
  -resultBundlePath "$RESULT" \
  build 2>&1 | tee "$BUILD_TEXT"
status=${PIPESTATUS[0]}
set -e
finished="$(python3 -c 'import time; print(time.monotonic_ns())')"
wall_seconds="$(python3 - "$started" "$finished" <<'PY'
import sys
print(f"{(int(sys.argv[2])-int(sys.argv[1]))/1e9:.3f}")
PY
)"
echo "XCODEBUILD_WALL_SECONDS=$wall_seconds"

if [[ "$status" -ne 0 ]]; then
  echo "::error::Xcode build failed in mode=$MODE phase=$PHASE"
  exit "$status"
fi

[[ -d "$RESULT" ]] || { echo "::error::Xcode result bundle missing"; exit 1; }
xcrun xcresulttool get log --path "$RESULT" --type build --compact >"$BUILD_JSON" 2>"$XCRESULT_ERROR" || {
  echo "::error::Unable to extract Xcode build activity log"
  cat "$XCRESULT_ERROR"
  exit 1
}

python3 "$HERMES_TOOLING_DIR/ci/summarize-incremental-release-experiment.py" \
  "$MODE" "$PHASE" "$SETTINGS" "$BUILD_JSON" "$wall_seconds" "$METRICS"

python3 "$HERMES_TOOLING_DIR/ci/count-swift-compile-tasks.py" "$BUILD_TEXT" "$METRICS"

rm -rf "$RESULT"
rm -f "$SETTINGS" "$BUILD_JSON" "$BUILD_TEXT" "$XCRESULT_ERROR"
