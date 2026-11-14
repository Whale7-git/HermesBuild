#!/usr/bin/env bash
# Compile the production document, row state and scheduler against small headless
# UI/publisher modules. This is a state-machine test, never a UIKit acceptance test.
set -euo pipefail
cd "$(dirname "$0")/../.."
BUILD=$(mktemp -d /tmp/hermes-render-pipeline-XXXXXXXX)
trap 'rm -rf "$BUILD"' EXIT
T=tests/renderpipeline
S=Sources/HermesShell
swiftc -swift-version 5 -warnings-as-errors -emit-module -emit-library -module-name Combine "$T/Combine.swift" -o "$BUILD/libCombine.so"
swiftc -swift-version 5 -warnings-as-errors -emit-module -emit-library -module-name SwiftUI -I "$BUILD" -L "$BUILD" -lCombine "$T/SwiftUI.swift" -o "$BUILD/libSwiftUI.so"
swiftc -swift-version 5 -warnings-as-errors -emit-module -emit-library -module-name UIKit "$T/UIKit.swift" -o "$BUILD/libUIKit.so"
swiftc -swift-version 5 -warnings-as-errors -parse-as-library -I "$BUILD" -L "$BUILD" -lCombine -lSwiftUI -lUIKit \
  "$S/ChatRenderScheduler.swift" "$S/ChatStreamPacing.swift" "$S/ChatRenderEnvironment.swift" \
  "$S/MarkdownBlockPlan.swift" "$S/ChatMarkdownDocument.swift" "$S/ChatPerformanceStatistics.swift" \
  "$T/WorkerDouble.swift" "$T/main.swift" -o "$BUILD/test"
LD_LIBRARY_PATH="$BUILD${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$BUILD/test"
