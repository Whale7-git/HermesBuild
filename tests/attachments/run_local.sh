#!/usr/bin/env bash
# Offline container/Linux entry point. Uses an exclusive temporary build and
# loopback fixture directory; never SSHs, uploads or calls the deployed service.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD=$(mktemp -d /tmp/hermes-attachments-build-XXXXXXXX)
trap 'rm -rf "$BUILD"' EXIT
cd "$ROOT"
swiftc -swift-version 6 -warnings-as-errors \
  Sources/HermesShell/ChatCore.swift \
  Sources/HermesShell/AttachmentModels.swift \
  Sources/HermesShell/AttachmentHistory.swift \
  tests/attachments/main.swift tests/attachments/PreviewTests.swift \
  tests/attachments/DownloadTests.swift tests/attachments/ReliabilityTests.swift \
  -o "$BUILD/attachments-tests"
ATTACHMENT_TEST_BINARY="$BUILD/attachments-tests" python3 tests/attachments/fixture_server.py
