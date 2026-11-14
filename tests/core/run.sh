#!/usr/bin/env bash
set -euo pipefail
: "${HERMES_TEST_TARGET:?Set HERMES_TEST_TARGET to your SSH user@host}"
[[ "$HERMES_TEST_TARGET" =~ ^[A-Za-z0-9_.@:-]+$ ]] || { echo "Invalid SSH target" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LABEL="${1:-latest}"
GROUP="${2:-all}"
[[ "$LABEL" =~ ^[a-zA-Z0-9_-]+$ && "$GROUP" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 2
cd "$ROOT"
FILES=(tests/core/main.swift)
if [[ -d tests/core/fixtures ]]; then FILES+=(tests/core/fixtures); fi
if [[ -f Sources/HermesShell/AttachmentHistory.swift ]]; then FILES+=(Sources/HermesShell/AttachmentHistory.swift); fi
if [[ -f Sources/HermesShell/ChatCore.swift ]]; then FILES+=(Sources/HermesShell/ChatCore.swift); fi
REMOTE=/work/hermes-chatcore-tests
ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec -i ios-build mkdir -p $REMOTE"
tar -cf - "${FILES[@]}" | ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec -i ios-build tar -xf - -C $REMOTE"
ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec -i ios-build bash -lc 'cd $REMOTE; sources=(); if [[ -f Sources/HermesShell/AttachmentHistory.swift ]]; then sources+=(Sources/HermesShell/AttachmentHistory.swift); fi; if [[ -f Sources/HermesShell/ChatCore.swift ]]; then sources+=(Sources/HermesShell/ChatCore.swift); fi; swiftc -warnings-as-errors \"\${sources[@]}\" tests/core/main.swift -o core-tests && ./core-tests $GROUP'" 2>&1 | tee "tests/core/evidence-$LABEL.txt"
