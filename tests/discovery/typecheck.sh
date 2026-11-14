#!/usr/bin/env bash
set -euo pipefail
: "${HERMES_TEST_TARGET:?Set HERMES_TEST_TARGET to your SSH user@host}"
[[ "$HERMES_TEST_TARGET" =~ ^[A-Za-z0-9_.@:-]+$ ]] || { echo "Invalid SSH target" >&2; exit 2; }
cd "$(dirname "$0")/../.."
tar czf - Sources/HermesShell/{Models,ChatRequests,AppTheme,SessionSearch,SessionListService,SessionSearchView,SessionDrawer}.swift tests/discovery/UIShims.swift |
  ssh -o BatchMode=yes "$HERMES_TEST_TARGET" 'docker exec -i ios-build tar xzf - -C /work/DiscoveryTests'
ssh -o BatchMode=yes "$HERMES_TEST_TARGET" 'docker exec ios-build bash -c '\''set -e; cd /work/DiscoveryTests; sdk=/root/.swiftpm/swift-sdks/darwin.artifactbundle/Developer; swiftc -swift-version 5 -typecheck -target arm64-apple-ios18.0 -sdk "$sdk/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk" -resource-dir "$sdk/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift" -module-cache-path /work/DiscoveryTests/module-cache Sources/HermesShell/{Models,ChatRequests,AppTheme,SessionSearch,SessionListService,SessionSearchView,SessionDrawer}.swift tests/discovery/UIShims.swift; printf "PASS: discovery views + API adapter typechecked against iOS 18 target / iOS 27.1 SDK\n"'\'''
