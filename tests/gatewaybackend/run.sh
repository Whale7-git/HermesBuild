#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
build=$(mktemp -d /tmp/hermes-gateway-tests-XXXXXXXX)
trap 'rm -rf "$build"' EXIT
s=Sources/HermesShell
swiftc -warnings-as-errors -swift-version 6 -parse-as-library \
  "$s/AttachmentHistory.swift" "$s/ChatCore.swift" "$s/Models.swift" "$s/ChatRequests.swift" \
  "$s/NativeChatService.swift" "$s/HermesBackend.swift" "$s/BackendCapabilities.swift" "$s/SessionListService.swift" "$s/SessionSearch.swift" \
  "$s/GatewayRequests.swift" "$s/GatewayDecode.swift" "$s/GatewayEventMap.swift" \
  "$s/GatewayAttachmentPaths.swift" "$s/GatewaySessionFilter.swift" "$s/GatewayModelCatalog.swift" \
  "$s/SSEFrameBudget.swift" "$s/GatewayTransport.swift" "$s/GatewayRunStore.swift" "$s/GatewayHistoryReader.swift" \
  "$s/GatewaySessionReader.swift" "$s/GatewayBackend.swift" \
  tests/gatewaybackend/Shims.swift tests/gatewaybackend/main.swift -o "$build/test"
"$build/test"
