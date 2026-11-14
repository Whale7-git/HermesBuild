#!/usr/bin/env bash
set -euo pipefail
: "${HERMES_TEST_TARGET:?Set HERMES_TEST_TARGET to your SSH user@host}"
[[ "$HERMES_TEST_TARGET" =~ ^[A-Za-z0-9_.@:-]+$ ]] || { echo "Invalid SSH target" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LABEL="${1:-latest}"
[[ "$LABEL" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 2
cd "$ROOT"
FILES=(tests/attachments/main.swift tests/attachments/PreviewTests.swift tests/attachments/DownloadTests.swift tests/attachments/ReliabilityTests.swift tests/attachments/fixture_server.py)
if [[ -f Sources/HermesShell/AttachmentModels.swift ]]; then FILES+=(Sources/HermesShell/ChatCore.swift); FILES+=(Sources/HermesShell/AttachmentModels.swift); fi
if [[ -f Sources/HermesShell/AttachmentHistory.swift ]]; then FILES+=(Sources/HermesShell/AttachmentHistory.swift); fi
REMOTE=/work/AttachmentTests
ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec -i ios-build mkdir -p $REMOTE"
tar -cf - "${FILES[@]}" | ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec -i ios-build tar -xf - -C $REMOTE"
ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec -i ios-build bash -lc 'cd $REMOTE; sources=(); if [[ -f Sources/HermesShell/AttachmentModels.swift ]]; then sources+=(Sources/HermesShell/ChatCore.swift); sources+=(Sources/HermesShell/AttachmentModels.swift); fi; if [[ -f Sources/HermesShell/AttachmentHistory.swift ]]; then sources+=(Sources/HermesShell/AttachmentHistory.swift); fi; swiftc -swift-version 6 -warnings-as-errors \"\${sources[@]}\" tests/attachments/main.swift tests/attachments/PreviewTests.swift tests/attachments/DownloadTests.swift tests/attachments/ReliabilityTests.swift -o attachments-tests && timeout 30 python3 tests/attachments/fixture_server.py'" 2>&1 | tee "tests/attachments/evidence-$LABEL.txt"
