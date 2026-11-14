#!/usr/bin/env bash
set -euo pipefail
: "${HERMES_TEST_TARGET:?Set HERMES_TEST_TARGET to your SSH user@host}"
[[ "$HERMES_TEST_TARGET" =~ ^[A-Za-z0-9_.@:-]+$ ]] || { echo "Invalid SSH target" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LABEL="${1:-latest}"
[[ "$LABEL" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 2
cd "$ROOT"
FILES=(Sources/HermesShell/AttachmentModels.swift Sources/HermesShell/AttachmentHistory.swift tests/attachments/iOSContracts.swift)
if [[ -f Sources/HermesShell/AttachmentViews.swift ]]; then FILES+=(Sources/HermesShell/AttachmentViews.swift); fi
if [[ -f Sources/HermesShell/AttachmentStrip.swift ]]; then FILES+=(Sources/HermesShell/AttachmentStrip.swift); fi
REMOTE=/work/AttachmentTests
ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec -i ios-build mkdir -p $REMOTE"
tar -cf - "${FILES[@]}" | ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec -i ios-build tar -xf - -C $REMOTE"
ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec -i ios-build bash -lc 'cd $REMOTE; SDK=/root/.swiftpm/swift-sdks/darwin.artifactbundle/Developer; sources=(Sources/HermesShell/AttachmentModels.swift Sources/HermesShell/AttachmentHistory.swift tests/attachments/iOSContracts.swift); if [[ -f Sources/HermesShell/AttachmentViews.swift ]]; then sources+=(Sources/HermesShell/AttachmentViews.swift); fi; if [[ -f Sources/HermesShell/AttachmentStrip.swift ]]; then sources+=(Sources/HermesShell/AttachmentStrip.swift); fi; swiftc -typecheck -swift-version 6 -warnings-as-errors -target arm64-apple-ios18.0 -sdk \"\$SDK/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk\" -resource-dir \"\$SDK/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift\" -module-cache-path /work/AttachmentTests/module-cache \"\${sources[@]}\" && printf \"PASS: isolated iOS18 Attachment UI typecheck\n\"'" 2>&1 | tee "tests/attachments/evidence-ios-$LABEL.txt"
