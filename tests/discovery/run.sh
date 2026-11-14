#!/usr/bin/env bash
set -euo pipefail
: "${HERMES_TEST_TARGET:?Set HERMES_TEST_TARGET to your SSH user@host}"
[[ "$HERMES_TEST_TARGET" =~ ^[A-Za-z0-9_.@:-]+$ ]] || { echo "Invalid SSH target" >&2; exit 2; }
cd "$(dirname "$0")/../.."
files=(Sources/HermesShell/AttachmentHistory.swift Sources/HermesShell/Models.swift Sources/HermesShell/ChatRequests.swift tests/discovery/main.swift)
for f in Sources/HermesShell/SessionSearch.swift Sources/HermesShell/SessionListService.swift tests/discovery/Shims.swift; do
  [[ ! -f "$f" ]] || files+=("$f")
done
tar czf - "${files[@]}" | ssh -o BatchMode=yes "$HERMES_TEST_TARGET" 'docker exec -i ios-build bash -c "mkdir -p /work/DiscoveryTests && tar xzf - -C /work/DiscoveryTests"'
ssh -o BatchMode=yes "$HERMES_TEST_TARGET" 'docker exec ios-build bash -c '\''set -e; cd /work/DiscoveryTests; sources="Sources/HermesShell/AttachmentHistory.swift Sources/HermesShell/Models.swift Sources/HermesShell/ChatRequests.swift"; for f in Sources/HermesShell/SessionSearch.swift Sources/HermesShell/SessionListService.swift tests/discovery/Shims.swift; do test ! -f "$f" || sources="$sources $f"; done; swiftc -swift-version 5 -parse-as-library $sources tests/discovery/main.swift -o discovery-tests && ./discovery-tests'\'''
