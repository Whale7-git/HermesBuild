#!/usr/bin/env bash
# Exercise the actual message-level selection observer with a headless Combine
# declaration. UIKit menu gestures and viewport motion still require a device.
set -euo pipefail
cd "$(dirname "$0")/../.."
BUILD=$(mktemp -d /tmp/hermes-selection-activity-XXXXXXXX)
trap 'rm -rf "$BUILD"' EXIT
swiftc -swift-version 6 -warnings-as-errors -emit-module -emit-library \
  -module-name Combine tests/selectionactivity/Combine.swift -o "$BUILD/libCombine.so"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -I "$BUILD" -L "$BUILD" -lCombine \
  Vendor/Textual/Sources/Textual/Internal/TextFragment/TextualSelectionActivity.swift \
  tests/selectionactivity/main.swift -o "$BUILD/test"
LD_LIBRARY_PATH="$BUILD${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$BUILD/test"
