#!/usr/bin/env bash
# Actual Vendor helpers only. No SwiftUI substitutes, network or production data.
set -euo pipefail
cd "$(dirname "$0")/../.."
BUILD=$(mktemp -d /tmp/hermes-textual-primitives-XXXXXXXX)
trap 'rm -rf "$BUILD"' EXIT
H=Vendor/Textual/Sources/Textual/Internal/Helpers
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$H/BlockMeasurementCache.swift" "$H/TokenizationWork.swift" \
  tests/textualprimitives/main.swift -o "$BUILD/test"
"$BUILD/test"
