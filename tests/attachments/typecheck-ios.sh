#!/usr/bin/env bash
set -euo pipefail
: "${HERMES_TEST_TARGET:?Set HERMES_TEST_TARGET to your SSH user@host}"
[[ "$HERMES_TEST_TARGET" =~ ^[A-Za-z0-9_.@:-]+$ ]] || { echo "Invalid SSH target" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LABEL="${1:-latest}"
[[ "$LABEL" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 2
cd "$ROOT"
FILES=(
  Sources/HermesShell/AttachmentHistory.swift
  Sources/HermesShell/ChatCore.swift
  Sources/HermesShell/Models.swift
  Sources/HermesShell/ChatRequests.swift
  Sources/HermesShell/NativeChatService.swift
  Sources/HermesShell/BackendCapabilities.swift
  Sources/HermesShell/HermesBackend.swift
  Sources/HermesShell/AttachmentModels.swift
  Sources/HermesShell/AttachmentInteractionState.swift
  Sources/HermesShell/ImageRatioStore.swift
  Sources/HermesShell/ImageEditPlan.swift
  Sources/HermesShell/ImageGallerySelection.swift
  Sources/HermesShell/AttachmentImageEditor.swift
  Sources/HermesShell/ImagePreviewActions.swift
  Sources/HermesShell/AppTheme.swift
  Sources/HermesShell/AttachmentProgressPresentation.swift
  Sources/HermesShell/RuntimeLogStorage.swift
  Sources/HermesShell/RuntimeLogRecorder.swift
  Sources/HermesShell/ZoomableImagePage.swift
  Sources/HermesShell/ImageRefKind.swift
  Sources/HermesShell/AttachmentImageLayout.swift
  Sources/HermesShell/AttachmentCatalog.swift
  Sources/HermesShell/ExternalLinkPolicy.swift
  Sources/HermesShell/SharedAsyncResourcePool.swift
  Sources/HermesShell/InlineImages.swift
)
if [[ -f Sources/HermesShell/AttachmentViews.swift ]]; then FILES+=(Sources/HermesShell/AttachmentViews.swift); fi
if [[ -f Sources/HermesShell/AttachmentStrip.swift ]]; then FILES+=(Sources/HermesShell/AttachmentStrip.swift); fi
FILES+=(tests/attachments/iOSContracts.swift)
REMOTE=/work/AttachmentTests
ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec -i ios-build mkdir -p $REMOTE"
tar -cf - "${FILES[@]}" | ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec -i ios-build tar -xf - -C $REMOTE"
ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec -i ios-build bash -lc 'cd $REMOTE; SDK=/root/.swiftpm/swift-sdks/darwin.artifactbundle/Developer; sources=(Sources/HermesShell/AttachmentHistory.swift Sources/HermesShell/ChatCore.swift Sources/HermesShell/Models.swift Sources/HermesShell/ChatRequests.swift Sources/HermesShell/NativeChatService.swift Sources/HermesShell/BackendCapabilities.swift Sources/HermesShell/HermesBackend.swift Sources/HermesShell/AttachmentModels.swift Sources/HermesShell/AttachmentInteractionState.swift Sources/HermesShell/ImageRatioStore.swift Sources/HermesShell/ImageEditPlan.swift Sources/HermesShell/ImageGallerySelection.swift Sources/HermesShell/AttachmentImageEditor.swift Sources/HermesShell/ImagePreviewActions.swift Sources/HermesShell/AppTheme.swift Sources/HermesShell/AttachmentProgressPresentation.swift Sources/HermesShell/RuntimeLogStorage.swift Sources/HermesShell/RuntimeLogRecorder.swift Sources/HermesShell/ZoomableImagePage.swift Sources/HermesShell/ImageRefKind.swift Sources/HermesShell/AttachmentImageLayout.swift Sources/HermesShell/AttachmentCatalog.swift Sources/HermesShell/ExternalLinkPolicy.swift Sources/HermesShell/SharedAsyncResourcePool.swift Sources/HermesShell/InlineImages.swift); if [[ -f Sources/HermesShell/AttachmentViews.swift ]]; then sources+=(Sources/HermesShell/AttachmentViews.swift); fi; if [[ -f Sources/HermesShell/AttachmentStrip.swift ]]; then sources+=(Sources/HermesShell/AttachmentStrip.swift); fi; sources+=(tests/attachments/iOSContracts.swift); swiftc -typecheck -swift-version 5 -warnings-as-errors -target arm64-apple-ios18.0 -sdk \"\$SDK/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk\" -resource-dir \"\$SDK/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift\" -module-cache-path /work/AttachmentTests/module-cache \"\${sources[@]}\" && printf \"PASS: isolated iOS18 Attachment UI typecheck\n\"'" 2>&1 | tee "tests/attachments/evidence-ios-$LABEL.txt"
